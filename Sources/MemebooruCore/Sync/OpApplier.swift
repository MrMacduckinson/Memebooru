import Foundation

/// Applies ops received from peers. Idempotent; last-writer-wins per field via `field_clock`.
/// Every accepted op is also stored in the local oplog so it propagates to other peers.
public final class OpApplier: @unchecked Sendable {
    public struct Report: Sendable {
        public var received = 0, applied = 0, stale = 0, duplicate = 0, failed = 0
    }

    private let collection: Collection
    private var db: Database { collection.db }
    private var oplog: OpLog { collection.oplog }

    public init(collection: Collection) { self.collection = collection }

    public func apply(_ ops: [Op]) throws -> Report {
        var r = Report()
        for op in ops.sorted(by: { $0.hlc < $1.hlc }) {
            r.received += 1
            try db.transaction {
                guard try oplog.insertRemote(op) else { r.duplicate += 1; return }
                collection.clock.observe(op.hlc)
                if let current = try oplog.fieldClock(op.entity, op.entityID, op.field), current >= op.hlc {
                    r.stale += 1; return
                }
                do {
                    try applyOne(op)
                    try oplog.setFieldClock(op.entity, op.entityID, op.field, op.hlc)
                    r.applied += 1
                } catch {
                    r.failed += 1
                }
            }
        }
        return r
    }

    private func applyOne(_ op: Op) throws {
        switch op.entity {
        case "meme": try applyMeme(op)
        case "meme_tag": try applyMemeTag(op)
        case "tag": try applyTag(op)
        case "asset": try applyAsset(op)
        case "relation": try applyRelation(op)
        default: break
        }
    }

    // MARK: meme

    private func applyMeme(_ op: Op) throws {
        let id = op.entityID
        switch op.field {
        case "create":
            let parts = (op.value ?? "").split(separator: ":").map(String.init)
            let kind = parts.first ?? "image", pres = parts.count > 1 ? parts[1] : "native"
            let created = parts.count > 2 ? Int64(parts[2]) ?? op.hlc.wall : op.hlc.wall
            try db.run("INSERT OR IGNORE INTO meme(id, kind, presentation, created_at, updated_at) VALUES (?,?,?,?,?)",
                       [id, kind, pres, created, created])
        case "kind", "presentation", "text_exact", "text_verbatim", "context", "payload":
            try ensureMeme(id, at: op.hlc)
            try db.run("UPDATE meme SET \(op.field) = ?, updated_at = ? WHERE id = ?", [op.value, op.hlc.wall, id])
            if ["text_exact", "text_verbatim", "context"].contains(op.field) { try refreshFTS(id) }
        case "deleted_at":
            try ensureMeme(id, at: op.hlc)
            try db.run("UPDATE meme SET deleted_at = ?, updated_at = ? WHERE id = ?", [op.value.flatMap(Int64.init), op.hlc.wall, id])
            try refreshFTS(id)
        default: break
        }
    }

    private func ensureMeme(_ id: String, at hlc: HLC) throws {
        try db.run("INSERT OR IGNORE INTO meme(id, kind, presentation, created_at, updated_at) VALUES (?,?,?,?,?)",
                   [id, "image", "native", hlc.wall, hlc.wall])
    }

    private func refreshFTS(_ id: String) throws {
        guard let m = try collection.memes.get(MemeID(id)) else { return }
        try db.run("DELETE FROM meme_fts WHERE meme_id = ?", [id])
        if m.deletedAt == nil, m.textExact != nil || m.textVerbatim != nil || m.context != nil {
            try db.run("INSERT INTO meme_fts(meme_id, text_exact, text_verbatim, context) VALUES (?,?,?,?)",
                       [id, m.textExact, m.textVerbatim, m.context])
        }
    }

    // MARK: meme_tag

    private func applyMemeTag(_ op: Op) throws {
        try ensureMeme(op.entityID, at: op.hlc)
        let tag = try collection.tags.resolve(op.field) ?? (try collection.tags.createSilently(op.field, kind: .normal))
        if op.value == "add" {
            try db.run("INSERT OR IGNORE INTO meme_tag(meme_id, tag_id) VALUES (?, ?)", [op.entityID, tag.id])
        } else {
            try db.run("DELETE FROM meme_tag WHERE meme_id = ? AND tag_id = ?", [op.entityID, tag.id])
        }
    }

    // MARK: tag

    private func applyTag(_ op: Op) throws {
        let name = op.entityID
        switch op.field {
        case "kind":
            let kind = TagKind(rawValue: op.value ?? "") ?? .normal
            if let t = try collection.tags.get(name: name) {
                try db.run("UPDATE tag SET kind = ? WHERE id = ?", [kind.rawValue, t.id])
            } else if try collection.tags.resolve(name) == nil {
                try collection.tags.createSilently(name, kind: kind)
            }
        case let f where f.hasPrefix("alias:"):
            let alias = String(f.dropFirst(6))
            guard let t = try collection.tags.get(name: name) else { return }
            if op.value == "add" {
                if try collection.tags.resolve(alias) == nil {
                    try db.run("INSERT OR IGNORE INTO tag_alias(name, tag_id) VALUES (?, ?)", [alias, t.id])
                }
            } else {
                try db.run("DELETE FROM tag_alias WHERE name = ? AND tag_id = ?", [alias, t.id])
            }
        case "rename":
            guard let t = try collection.tags.get(name: name), let new = op.value, try collection.tags.resolve(new) == nil else { return }
            try db.run("UPDATE tag SET name = ? WHERE id = ?", [new, t.id])
        case "merge":
            guard let source = try collection.tags.get(name: name), let targetName = op.value else { return }
            let target = try collection.tags.resolve(targetName) ?? (try collection.tags.createSilently(targetName, kind: source.kind))
            try collection.tags.mergeSilently(source, into: target)
        case "deleted":
            try db.run("DELETE FROM tag WHERE name = ?", [name])
        default: break
        }
    }

    // MARK: asset

    private func applyAsset(_ op: Op) throws {
        guard let a = AssetOp.parse(op.value) else { return }
        try ensureMeme(op.entityID, at: op.hlc)
        let exists = try db.scalarInt("SELECT count(*) FROM asset WHERE meme_id = ? AND role = ? AND ord = ? AND sha256 = ?",
                                      [op.entityID, a.role, a.order, a.sha256]) > 0
        if exists { return }
        try db.run("DELETE FROM asset WHERE meme_id = ? AND role = ? AND ord = ?", [op.entityID, a.role, a.order])
        let asset = a.asset(memeID: MemeID(op.entityID))
        try db.run("INSERT INTO asset(\(MemeStore.assetColumns)) VALUES (\(MemeStore.assetPlaceholders))", MemeStore.assetValues(asset))
    }

    // MARK: relation

    private func applyRelation(_ op: Op) throws {
        let parts = op.entityID.split(separator: "|").map(String.init)
        guard parts.count == 3, let v = op.value else { return }
        try ensureMeme(parts[0], at: op.hlc); try ensureMeme(parts[1], at: op.hlc)
        if v.hasPrefix("add") {
            let note = v.hasPrefix("add:") ? String(v.dropFirst(4)) : nil
            try db.run(
                "INSERT INTO relation(from_id, to_id, kind, note, created_at, deleted_at) VALUES (?,?,?,?,?,NULL) ON CONFLICT(from_id, to_id, kind) DO UPDATE SET note = excluded.note, deleted_at = NULL",
                [parts[0], parts[1], parts[2], note, op.hlc.wall])
        } else {
            try db.run("UPDATE relation SET deleted_at = ? WHERE from_id = ? AND to_id = ? AND kind = ?", [op.hlc.wall, parts[0], parts[1], parts[2]])
        }
    }

    /// Media files referenced by assets that are not in the store yet.
    public func missingMedia() throws -> [(sha256: String, ext: String)] {
        let rows = try db.query("SELECT DISTINCT sha256, ext FROM asset", []) { ($0.string(0), $0.string(1)) }
        return rows.filter { !collection.media.exists(sha256: $0.0, ext: $0.1) }
    }
}

extension TagRegistry {
    /// Create without writing an op (used when replaying a peer's ops).
    @discardableResult
    func createSilently(_ raw: String, kind: TagKind) throws -> Tag {
        let name = try TagName.normalize(raw)
        let now = Clock.nowMillis()
        try dbRun("INSERT OR IGNORE INTO tag(name, kind, created_at) VALUES (?, ?, ?)", [name, kind.rawValue, now])
        guard let t = try get(name: name) else { throw TagError("cannot create \(name)") }
        return t
    }

    func mergeSilently(_ source: Tag, into target: Tag) throws {
        guard source.id != target.id else { return }
        try dbRun("INSERT OR IGNORE INTO meme_tag(meme_id, tag_id) SELECT meme_id, ? FROM meme_tag WHERE tag_id = ?", [target.id, source.id])
        try dbRun("DELETE FROM meme_tag WHERE tag_id = ?", [source.id])
        try dbRun("UPDATE tag_alias SET tag_id = ? WHERE tag_id = ?", [target.id, source.id])
        try dbRun("DELETE FROM tag WHERE id = ?", [source.id])
        try dbRun("INSERT OR IGNORE INTO tag_alias(name, tag_id) VALUES (?, ?)", [source.name, target.id])
    }
}
