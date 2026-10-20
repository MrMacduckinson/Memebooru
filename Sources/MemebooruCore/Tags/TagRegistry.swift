import Foundation

/// Tags + aliases. Every lookup accepts either a canonical name or an alias.
public final class TagRegistry: @unchecked Sendable {
    private let db: Database
    private let oplog: OpLog

    init(db: Database, oplog: OpLog) { self.db = db; self.oplog = oplog }
    func dbRun(_ sql: String, _ params: [SQLBindable]) throws { try db.run(sql, params) }

    private static let cols = "id, name, kind, created_at"
    private static func tag(_ r: Row) -> Tag {
        Tag(id: r.int64("id"), name: r.string("name"),
            kind: TagKind(rawValue: r.string("kind")) ?? .normal, createdAt: r.int64("created_at"))
    }

    // MARK: - Lookup

    public func get(id: Int64) throws -> Tag? {
        try db.first("SELECT \(Self.cols) FROM tag WHERE id = ?", [id], Self.tag)
    }

    public func get(name: String) throws -> Tag? {
        try db.first("SELECT \(Self.cols) FROM tag WHERE name = ?", [name], Self.tag)
    }

    /// Canonical tag for a name *or* alias. `nil` if unknown.
    public func resolve(_ raw: String) throws -> Tag? {
        let name = try TagName.normalize(raw)
        if let t = try get(name: name) { return t }
        return try db.first(
            "SELECT t.id, t.name, t.kind, t.created_at FROM tag t JOIN tag_alias a ON a.tag_id = t.id WHERE a.name = ?",
            [name], Self.tag)
    }

    public func all() throws -> [Tag] {
        try db.query("SELECT \(Self.cols) FROM tag ORDER BY name", [], Self.tag)
    }

    public func usage(of tag: Tag) throws -> Int {
        Int(try db.scalarInt(
            "SELECT count(*) FROM meme_tag mt JOIN meme m ON m.id = mt.meme_id WHERE mt.tag_id = ? AND m.deleted_at IS NULL",
            [tag.id]))
    }

    /// Usage count including soft-deleted memes (for the "include deleted" toggle in the tag index).
    public func rawUsage(of tag: Tag) throws -> Int {
        Int(try db.scalarInt("SELECT count(*) FROM meme_tag mt WHERE mt.tag_id = ?", [tag.id]))
    }

    // MARK: - Create / edit

    /// Returns the existing tag (via name or alias) or creates a new one with `kind`.
    @discardableResult
    public func ensure(_ raw: String, kind: TagKind = .normal) throws -> Tag {
        if let t = try resolve(raw) { return t }
        return try create(raw, kind: kind)
    }

    @discardableResult
    public func create(_ raw: String, kind: TagKind) throws -> Tag {
        let name = try TagName.normalize(raw)
        return try db.transaction {
            if let existing = try resolve(name) {
                throw TagError("'\(name)' already exists (tag or alias of '\(existing.name)')")
            }
            let now = Clock.nowMillis()
            try db.run("INSERT INTO tag(name, kind, created_at) VALUES (?, ?, ?)", [name, kind.rawValue, now])
            let id = db.lastInsertRowID
            try oplog.record(entity: "tag", id: name, field: "kind", value: kind.rawValue)
            return Tag(id: id, name: name, kind: kind, createdAt: now)
        }
    }

    public func setKind(_ tag: Tag, _ kind: TagKind) throws {
        try db.transaction {
            try db.run("UPDATE tag SET kind = ? WHERE id = ?", [kind.rawValue, tag.id])
            try oplog.record(entity: "tag", id: tag.name, field: "kind", value: kind.rawValue)
        }
    }

    public func rename(_ tag: Tag, to raw: String) throws -> Tag {
        let name = try TagName.normalize(raw)
        return try db.transaction {
            if let clash = try resolve(name), clash.id != tag.id {
                throw TagError("'\(name)' already used by '\(clash.name)'")
            }
            try db.run("DELETE FROM tag_alias WHERE name = ?", [name])
            try db.run("UPDATE tag SET name = ? WHERE id = ?", [name, tag.id])
            try oplog.record(entity: "tag", id: tag.name, field: "rename", value: name)
            return Tag(id: tag.id, name: name, kind: tag.kind, createdAt: tag.createdAt)
        }
    }

    public func delete(_ tag: Tag) throws {
        try db.transaction {
            try db.run("DELETE FROM tag WHERE id = ?", [tag.id])
            try oplog.record(entity: "tag", id: tag.name, field: "deleted", value: "1")
        }
    }

    // MARK: - Aliases

    public func addAlias(_ raw: String, to tag: Tag) throws {
        let alias = try TagName.normalize(raw)
        try db.transaction {
            if let clash = try resolve(alias) {
                if clash.id == tag.id { return }
                throw TagError("'\(alias)' already used by '\(clash.name)'")
            }
            try db.run("INSERT INTO tag_alias(name, tag_id) VALUES (?, ?)", [alias, tag.id])
            try oplog.record(entity: "tag", id: tag.name, field: "alias:\(alias)", value: "add")
        }
    }

    public func removeAlias(_ raw: String) throws {
        let alias = try TagName.normalize(raw)
        try db.transaction {
            guard let tag = try db.first(
                "SELECT t.id, t.name, t.kind, t.created_at FROM tag t JOIN tag_alias a ON a.tag_id = t.id WHERE a.name = ?",
                [alias], Self.tag) else { return }
            try db.run("DELETE FROM tag_alias WHERE name = ?", [alias])
            try oplog.record(entity: "tag", id: tag.name, field: "alias:\(alias)", value: "remove")
        }
    }

    public func aliases(of tag: Tag) throws -> [String] {
        try db.query("SELECT name FROM tag_alias WHERE tag_id = ? ORDER BY name", [tag.id]) { $0.string(0) }
    }

    /// Moves every usage and alias of `source` onto `target`, then keeps `source`'s name as an alias.
    public func merge(_ source: Tag, into target: Tag) throws {
        guard source.id != target.id else { return }
        try db.transaction {
            try db.run("INSERT OR IGNORE INTO meme_tag(meme_id, tag_id) SELECT meme_id, ? FROM meme_tag WHERE tag_id = ?",
                       [target.id, source.id])
            try db.run("DELETE FROM meme_tag WHERE tag_id = ?", [source.id])
            try db.run("UPDATE tag_alias SET tag_id = ? WHERE tag_id = ?", [target.id, source.id])
            try db.run("DELETE FROM tag WHERE id = ?", [source.id])
            try db.run("INSERT INTO tag_alias(name, tag_id) VALUES (?, ?)", [source.name, target.id])
            try oplog.record(entity: "tag", id: source.name, field: "merge", value: target.name)
        }
    }

    // MARK: - Autocomplete

    /// Prefix suggestions over tag names and aliases, most-used first.
    public func suggest(prefix raw: String, limit: Int = 20) throws -> [TagSuggestion] {
        let p = raw.trimmingCharacters(in: .whitespaces).lowercased()
        // The escape character itself first, so a `\` in the prefix stays literal too.
        let like = p.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
        let sql = """
        WITH usage AS (
            SELECT mt.tag_id, count(*) AS n FROM meme_tag mt
            JOIN meme m ON m.id = mt.meme_id WHERE m.deleted_at IS NULL GROUP BY mt.tag_id
        )
        SELECT t.id, t.name, t.kind, t.created_at, t.name AS text, 0 AS is_alias, coalesce(u.n, 0) AS n
          FROM tag t LEFT JOIN usage u ON u.tag_id = t.id WHERE t.name LIKE ? ESCAPE '\\'
        UNION ALL
        SELECT t.id, t.name, t.kind, t.created_at, a.name AS text, 1 AS is_alias, coalesce(u.n, 0) AS n
          FROM tag_alias a JOIN tag t ON t.id = a.tag_id LEFT JOIN usage u ON u.tag_id = t.id
          WHERE a.name LIKE ? ESCAPE '\\'
        ORDER BY n DESC, text ASC LIMIT ?
        """
        return try db.query(sql, [like, like, limit]) { r in
            TagSuggestion(text: r.string("text"), tag: Self.tag(r), isAlias: r.bool("is_alias"), usage: r.int("n"))
        }
    }
}
