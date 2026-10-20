import Foundation

public struct Op: Sendable, Equatable, Codable {
    public let seq: Int64
    public let opID: String
    public let deviceID: String
    public let hlc: HLC
    public let entity: String     // meme | meme_tag | tag | asset | relation
    public let entityID: String
    public let field: String
    public let value: String?
    public init(seq: Int64 = 0, opID: String, deviceID: String, hlc: HLC, entity: String, entityID: String, field: String, value: String?) {
        self.seq = seq; self.opID = opID; self.deviceID = deviceID; self.hlc = hlc
        self.entity = entity; self.entityID = entityID; self.field = field; self.value = value
    }
}

/// Append-only log of local changes; replayed to peers during sync.
public final class OpLog: @unchecked Sendable {
    private let db: Database
    public let clock: HLCClock
    public var deviceID: String { clock.device }

    init(db: Database, clock: HLCClock) { self.db = db; self.clock = clock }

    @discardableResult
    public func record(entity: String, id: String, field: String, value: String?) throws -> HLC {
        let hlc = clock.now()
        try db.run(
            "INSERT INTO oplog(op_id, device_id, hlc, entity, entity_id, field, value, applied_at) VALUES (?,?,?,?,?,?,?,?)",
            [UUID().uuidString.lowercased(), deviceID, hlc.description, entity, id, field, value, Clock.nowMillis()])
        try db.run("INSERT OR REPLACE INTO field_clock(entity, entity_id, field, hlc) VALUES (?,?,?,?)", [entity, id, field, hlc.description])
        return hlc
    }

    /// Store an op received from a peer (so it propagates further). Returns false if already known.
    func insertRemote(_ op: Op) throws -> Bool {
        try db.run(
            "INSERT OR IGNORE INTO oplog(op_id, device_id, hlc, entity, entity_id, field, value, applied_at) VALUES (?,?,?,?,?,?,?,?)",
            [op.opID, op.deviceID, op.hlc.description, op.entity, op.entityID, op.field, op.value, Clock.nowMillis()])
        return db.changes > 0
    }

    public func contains(opID: String) throws -> Bool {
        try db.scalarInt("SELECT count(*) FROM oplog WHERE op_id = ?", [opID]) > 0
    }

    /// Latest clock we hold per device — what we tell a peer we already have.
    public func vector() throws -> [String: HLC] {
        var v: [String: HLC] = [:]
        for (d, h) in try db.query("SELECT device_id, max(hlc) FROM oplog GROUP BY device_id", [], { ($0.string(0), $0.string(1)) }) {
            if let hlc = HLC(string: h) { v[d] = hlc }
        }
        return v
    }

    /// Ops the peer lacks, given the peer's vector. Ordered by HLC.
    public func ops(missingFrom vector: [String: HLC], limit: Int = 5000) throws -> [Op] {
        var out: [Op] = []
        for op in try allOps() {
            if let seen = vector[op.deviceID], op.hlc <= seen { continue }
            out.append(op)
            if out.count >= limit { break }
        }
        return out
    }

    func allOps() throws -> [Op] {
        try db.query("SELECT seq, op_id, device_id, hlc, entity, entity_id, field, value FROM oplog ORDER BY hlc", []) { r in
            Op(seq: r.int64("seq"), opID: r.string("op_id"), deviceID: r.string("device_id"),
               hlc: HLC(string: r.string("hlc"))!, entity: r.string("entity"), entityID: r.string("entity_id"),
               field: r.string("field"), value: r.optString("value"))
        }
    }

    func fieldClock(_ entity: String, _ id: String, _ field: String) throws -> HLC? {
        guard let s = try db.scalarString("SELECT hlc FROM field_clock WHERE entity = ? AND entity_id = ? AND field = ?", [entity, id, field]) else { return nil }
        return HLC(string: s)
    }

    func setFieldClock(_ entity: String, _ id: String, _ field: String, _ hlc: HLC) throws {
        try db.run("INSERT OR REPLACE INTO field_clock(entity, entity_id, field, hlc) VALUES (?,?,?,?)", [entity, id, field, hlc.description])
    }

    public func count() throws -> Int { Int(try db.scalarInt("SELECT count(*) FROM oplog")) }

    public func ops(after hlc: HLC?, limit: Int = 1000) throws -> [Op] {
        try db.query(
            "SELECT seq, op_id, device_id, hlc, entity, entity_id, field, value FROM oplog WHERE hlc > ? ORDER BY hlc LIMIT ?",
            [hlc?.description ?? "", limit]) { r in
            Op(seq: r.int64("seq"), opID: r.string("op_id"), deviceID: r.string("device_id"),
               hlc: HLC(string: r.string("hlc"))!, entity: r.string("entity"), entityID: r.string("entity_id"),
               field: r.string("field"), value: r.optString("value"))
        }
    }

    public func latestHLC() throws -> HLC? {
        guard let s = try db.scalarString("SELECT max(hlc) FROM oplog") else { return nil }
        return HLC(string: s)
    }
}
