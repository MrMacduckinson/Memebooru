import Foundation

/// Keyset cursor for the infinite gallery: `(created_at, id)` of the last row shown.
public struct MemeCursor: Sendable, Equatable {
    public let createdAt: Int64
    public let id: MemeID
    public init(createdAt: Int64, id: MemeID) { self.createdAt = createdAt; self.id = id }
}

public final class MemeStore: @unchecked Sendable {
    private let db: Database
    private let oplog: OpLog
    private let tags: TagRegistry

    init(db: Database, oplog: OpLog, tags: TagRegistry) { self.db = db; self.oplog = oplog; self.tags = tags }

    private static let cols = "id, kind, presentation, created_at, updated_at, text_exact, text_verbatim, context, payload, deleted_at"

    static func meme(_ r: Row) throws -> Meme {
        let kind = MemeKind(rawValue: r.string("kind")) ?? .image
        return Meme(id: MemeID(r.string("id")), kind: kind,
                    presentation: Presentation(rawValue: r.string("presentation")) ?? .native,
                    createdAt: r.int64("created_at"), updatedAt: r.int64("updated_at"),
                    textExact: r.optString("text_exact"), textVerbatim: r.optString("text_verbatim"),
                    context: r.optString("context"),
                    payload: try MemePayload.decode(kind: kind, json: r.optString("payload")),
                    deletedAt: r.optInt64("deleted_at"))
    }

    // MARK: - CRUD

    public func insert(_ meme: Meme, tags tagNames: [String] = []) throws {
        try db.transaction {
            let payload = try meme.payload.encodeJSON()
            try db.run(
                "INSERT INTO meme(\(Self.cols)) VALUES (?,?,?,?,?,?,?,?,?,?)",
                [meme.id.rawValue, meme.kind.rawValue, meme.presentation.rawValue, meme.createdAt, meme.updatedAt,
                 meme.textExact, meme.textVerbatim, meme.context, payload, meme.deletedAt])
            try syncFTS(meme)
            try oplog.record(entity: "meme", id: meme.id.rawValue, field: "create",
                             value: "\(meme.kind.rawValue):\(meme.presentation.rawValue):\(meme.createdAt)")
            for f in [("text_exact", meme.textExact), ("text_verbatim", meme.textVerbatim), ("context", meme.context), ("payload", payload)] where f.1 != nil {
                try oplog.record(entity: "meme", id: meme.id.rawValue, field: f.0, value: f.1)
            }
            for t in tagNames { try addTag(meme.id, t) }
        }
    }

    public func get(_ id: MemeID) throws -> Meme? {
        try db.first("SELECT \(Self.cols) FROM meme WHERE id = ?", [id.rawValue], Self.meme)
    }

    /// Writes changed scalar fields only; each becomes one op (LWW granularity).
    public func update(_ meme: Meme) throws {
        try db.transaction {
            guard let old = try get(meme.id) else { throw TagError("meme \(meme.id) not found") }
            var new = meme
            new.updatedAt = Clock.nowMillis()
            let payload = try new.payload.encodeJSON()
            let oldPayload = try old.payload.encodeJSON()
            try db.run(
                "UPDATE meme SET kind=?, presentation=?, updated_at=?, text_exact=?, text_verbatim=?, context=?, payload=? WHERE id=?",
                [new.kind.rawValue, new.presentation.rawValue, new.updatedAt, new.textExact, new.textVerbatim,
                 new.context, payload, new.id.rawValue])
            try syncFTS(new)
            let id = new.id.rawValue
            if old.kind != new.kind { try oplog.record(entity: "meme", id: id, field: "kind", value: new.kind.rawValue) }
            if old.presentation != new.presentation { try oplog.record(entity: "meme", id: id, field: "presentation", value: new.presentation.rawValue) }
            if old.textExact != new.textExact { try oplog.record(entity: "meme", id: id, field: "text_exact", value: new.textExact) }
            if old.textVerbatim != new.textVerbatim { try oplog.record(entity: "meme", id: id, field: "text_verbatim", value: new.textVerbatim) }
            if old.context != new.context { try oplog.record(entity: "meme", id: id, field: "context", value: new.context) }
            if oldPayload != payload { try oplog.record(entity: "meme", id: id, field: "payload", value: payload) }
        }
    }

    /// Soft delete: row stays (tombstone for sync), disappears from queries.
    public func delete(_ id: MemeID) throws {
        try db.transaction {
            let now = Clock.nowMillis()
            try db.run("UPDATE meme SET deleted_at = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL", [now, now, id.rawValue])
            try db.run("DELETE FROM meme_fts WHERE meme_id = ?", [id.rawValue])
            try oplog.record(entity: "meme", id: id.rawValue, field: "deleted_at", value: String(now))
        }
    }

    /// Restore a soft-deleted meme (undo of delete).
    public func undelete(_ id: MemeID) throws {
        try db.transaction {
            let now = Clock.nowMillis()
            try db.run("UPDATE meme SET deleted_at = NULL, updated_at = ? WHERE id = ?", [now, id.rawValue])
            if let m = try get(id) { try syncFTS(m) }
            try oplog.record(entity: "meme", id: id.rawValue, field: "deleted_at", value: nil)
        }
    }

    public func count() throws -> Int {
        Int(try db.scalarInt("SELECT count(*) FROM meme WHERE deleted_at IS NULL"))
    }

    /// Newest first, keyset-paginated.
    public func recent(limit: Int = 60, before cursor: MemeCursor? = nil) throws -> [Meme] {
        if let c = cursor {
            return try db.query(
                "SELECT \(Self.cols) FROM meme WHERE deleted_at IS NULL AND (created_at < ? OR (created_at = ? AND id < ?)) ORDER BY created_at DESC, id DESC LIMIT ?",
                [c.createdAt, c.createdAt, c.id.rawValue, limit], Self.meme)
        }
        return try db.query(
            "SELECT \(Self.cols) FROM meme WHERE deleted_at IS NULL ORDER BY created_at DESC, id DESC LIMIT ?",
            [limit], Self.meme)
    }

    private func syncFTS(_ m: Meme) throws {
        try db.run("DELETE FROM meme_fts WHERE meme_id = ?", [m.id.rawValue])
        if m.deletedAt == nil, m.textExact != nil || m.textVerbatim != nil || m.context != nil {
            try db.run("INSERT INTO meme_fts(meme_id, text_exact, text_verbatim, context) VALUES (?,?,?,?)",
                       [m.id.rawValue, m.textExact, m.textVerbatim, m.context])
        }
    }

    // MARK: - Tags

    public func tags(of id: MemeID) throws -> [Tag] {
        try db.query(
            "SELECT t.id, t.name, t.kind, t.created_at FROM tag t JOIN meme_tag mt ON mt.tag_id = t.id WHERE mt.meme_id = ? ORDER BY t.kind, t.name",
            [id.rawValue]) { r in
            Tag(id: r.int64("id"), name: r.string("name"), kind: TagKind(rawValue: r.string("kind")) ?? .normal, createdAt: r.int64("created_at"))
        }
    }

    /// Resolves aliases; creates the tag (with `kind`) if unknown.
    @discardableResult
    public func addTag(_ id: MemeID, _ raw: String, kind: TagKind = .normal) throws -> Tag {
        try db.transaction {
            let tag = try tags.ensure(raw, kind: kind)
            try db.run("INSERT OR IGNORE INTO meme_tag(meme_id, tag_id) VALUES (?, ?)", [id.rawValue, tag.id])
            if db.changes > 0 {
                try oplog.record(entity: "meme_tag", id: id.rawValue, field: tag.name, value: "add")
            }
            return tag
        }
    }

    public func removeTag(_ id: MemeID, _ raw: String) throws {
        try db.transaction {
            guard let tag = try tags.resolve(raw) else { return }
            try db.run("DELETE FROM meme_tag WHERE meme_id = ? AND tag_id = ?", [id.rawValue, tag.id])
            if db.changes > 0 {
                try oplog.record(entity: "meme_tag", id: id.rawValue, field: tag.name, value: "remove")
            }
        }
    }

    /// Replace the full tag set. New tags get `defaultKind`.
    public func setTags(_ id: MemeID, _ raws: [String], defaultKind: TagKind = .normal) throws {
        try db.transaction {
            let wanted = try raws.map { try tags.ensure($0, kind: defaultKind) }
            let wantedIDs = Set(wanted.map(\.id))
            for t in try tags(of: id) where !wantedIDs.contains(t.id) { try removeTag(id, t.name) }
            for t in wanted { try addTag(id, t.name, kind: t.kind) }
        }
    }

    // MARK: - Assets

    private static func asset(_ r: Row) -> Asset {
        Asset(id: r.int64("id"), memeID: MemeID(r.string("meme_id")),
              role: Asset.Role(rawValue: r.string("role")) ?? .primary,
              sha256: r.string("sha256"), ext: r.string("ext"), mime: r.string("mime"),
              width: r.optInt("width"), height: r.optInt("height"), durationMs: r.optInt64("duration_ms"),
              bytes: r.int64("bytes"), dhash: r.optInt64("dhash"), phash: r.optInt64("phash"), order: r.int("ord"),
              originalName: r.optString("original_name"), codecs: r.optString("codecs"),
              sourceSHA256: r.optString("source_sha256"), sourceExt: r.optString("source_ext"), sourceCodecs: r.optString("source_codecs"),
              edit: MediaEdit.decode(r.optString("edit")))
    }

    static let assetColumns = "meme_id, role, sha256, ext, mime, width, height, duration_ms, bytes, dhash, phash, ord, original_name, codecs, source_sha256, source_ext, source_codecs, edit"
    /// "?,?,…" — one per column, so a new column can't be forgotten in an INSERT.
    static let assetPlaceholders = Array(repeating: "?", count: assetColumns.split(separator: ",").count).joined(separator: ",")
    static func assetValues(_ a: Asset) -> [SQLBindable] {
        [a.memeID.rawValue, a.role.rawValue, a.sha256, a.ext, a.mime, a.width, a.height, a.durationMs, a.bytes, a.dhash, a.phash,
         a.order, a.originalName, a.codecs, a.sourceSHA256, a.sourceExt, a.sourceCodecs, a.edit?.json]
    }

    @discardableResult
    public func addAsset(_ a: Asset) throws -> Asset {
        try db.transaction {
            try db.run("INSERT INTO asset(\(Self.assetColumns)) VALUES (\(Self.assetPlaceholders))", Self.assetValues(a))
            var stored = a
            stored.id = db.lastInsertRowID
            try oplog.record(entity: "asset", id: a.memeID.rawValue, field: "\(a.role.rawValue):\(a.order)",
                             value: AssetOp(a).json)
            return stored
        }
    }

    /// Replaces whatever sits in this asset's (role, order) slot — synced like `addAsset`.
    @discardableResult
    public func putAsset(_ a: Asset) throws -> Asset {
        try db.transaction {
            try db.run("DELETE FROM asset WHERE meme_id = ? AND role = ? AND ord = ?", [a.memeID.rawValue, a.role.rawValue, a.order])
            return try addAsset(a)
        }
    }

    public func asset(of id: MemeID, role: Asset.Role) throws -> Asset? {
        try db.first("SELECT * FROM asset WHERE meme_id = ? AND role = ? ORDER BY ord LIMIT 1", [id.rawValue, role.rawValue], Self.asset)
    }

    public func assets(of id: MemeID) throws -> [Asset] {
        try db.query("SELECT * FROM asset WHERE meme_id = ? ORDER BY role, ord", [id.rawValue], Self.asset)
    }

    public func primaryAsset(of id: MemeID) throws -> Asset? {
        try db.first("SELECT * FROM asset WHERE meme_id = ? AND role = 'primary' ORDER BY ord LIMIT 1", [id.rawValue], Self.asset)
    }

    /// MemeID of a live tweet meme with this tweet id, if any.
    public func memeForTweet(_ tweetID: String) throws -> MemeID? {
        try db.first("SELECT id FROM meme WHERE kind = 'tweet' AND deleted_at IS NULL AND payload LIKE ? ESCAPE '\\' LIMIT 1",
                     [Self.tweetIDPattern(tweetID)]) { MemeID($0.string(0)) }
    }

    /// Live tweet meme with this tweet id, if any (payload holds `"tweetID":"<id>"`).
    public func tweetExists(_ tweetID: String) throws -> Bool {
        try db.scalarInt(
            "SELECT count(*) FROM meme WHERE kind = 'tweet' AND deleted_at IS NULL AND payload LIKE ? ESCAPE '\\'",
            [Self.tweetIDPattern(tweetID)]) > 0
    }

    /// `%"tweetID":"<id>"%` with the id's own `%` / `_` taken literally.
    private static func tweetIDPattern(_ tweetID: String) -> String {
        let id = tweetID.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        return "%\"tweetID\":\"" + id + "\"%"
    }

    public func memes(withSHA256 sha: String) throws -> [MemeID] {
        // A converted file remembers its source, so re-importing the original is still caught.
        try db.query("SELECT DISTINCT a.meme_id FROM asset a JOIN meme m ON m.id = a.meme_id WHERE (a.sha256 = ? OR a.source_sha256 = ?) AND m.deleted_at IS NULL", [sha, sha]) {
            MemeID($0.string(0))
        }
    }

    // MARK: - Relations

    public func addRelation(_ r: Relation) throws {
        try db.transaction {
            try db.run(
                "INSERT INTO relation(from_id, to_id, kind, note, created_at, deleted_at) VALUES (?,?,?,?,?,NULL) ON CONFLICT(from_id, to_id, kind) DO UPDATE SET note = excluded.note, deleted_at = NULL",
                [r.from.rawValue, r.to.rawValue, r.kind.rawValue, r.note, r.createdAt])
            try oplog.record(entity: "relation", id: "\(r.from.rawValue)|\(r.to.rawValue)|\(r.kind.rawValue)", field: "state", value: "add" + (r.note.map { ":" + $0 } ?? ""))
        }
    }

    public func removeRelation(from: MemeID, to: MemeID, kind: Relation.Kind) throws {
        try db.transaction {
            try db.run("UPDATE relation SET deleted_at = ? WHERE from_id = ? AND to_id = ? AND kind = ?",
                       [Clock.nowMillis(), from.rawValue, to.rawValue, kind.rawValue])
            try oplog.record(entity: "relation", id: "\(from.rawValue)|\(to.rawValue)|\(kind.rawValue)", field: "state", value: "remove")
        }
    }

    /// Relations in either direction.
    public func relations(of id: MemeID) throws -> [Relation] {
        try db.query(
            "SELECT from_id, to_id, kind, note, created_at, deleted_at FROM relation WHERE (from_id = ? OR to_id = ?) AND deleted_at IS NULL",
            [id.rawValue, id.rawValue]) { r in
            Relation(from: MemeID(r.string("from_id")), to: MemeID(r.string("to_id")),
                     kind: Relation.Kind(rawValue: r.string("kind")) ?? .variant, note: r.optString("note"),
                     createdAt: r.int64("created_at"), deletedAt: r.optInt64("deleted_at"))
        }
    }
}


/// Wire form of an asset inside an op (everything but the local row id).
struct AssetOp: Codable {
    var role: String; var sha256: String; var ext: String; var mime: String
    var width: Int?; var height: Int?; var durationMs: Int64?; var bytes: Int64
    var dhash: Int64?; var phash: Int64?; var order: Int; var originalName: String?
    var codecs: String?; var sourceSHA256: String?; var sourceExt: String?; var sourceCodecs: String?
    var edit: MediaEdit?
    init(_ a: Asset) {
        role = a.role.rawValue; sha256 = a.sha256; ext = a.ext; mime = a.mime; width = a.width; height = a.height
        durationMs = a.durationMs; bytes = a.bytes; dhash = a.dhash; phash = a.phash; order = a.order; originalName = a.originalName
        codecs = a.codecs; sourceSHA256 = a.sourceSHA256; sourceExt = a.sourceExt; sourceCodecs = a.sourceCodecs
        edit = a.edit
    }
    var json: String { String(decoding: try! JSONEncoder().encode(self), as: UTF8.self) }
    static func parse(_ s: String?) -> AssetOp? { s.flatMap { try? JSONDecoder().decode(AssetOp.self, from: Data($0.utf8)) } }
    func asset(memeID: MemeID) -> Asset {
        Asset(memeID: memeID, role: Asset.Role(rawValue: role) ?? .primary, sha256: sha256, ext: ext, mime: mime, width: width, height: height,
              durationMs: durationMs, bytes: bytes, dhash: dhash, phash: phash, order: order, originalName: originalName,
              codecs: codecs, sourceSHA256: sourceSHA256, sourceExt: sourceExt, sourceCodecs: sourceCodecs, edit: edit)
    }
}
