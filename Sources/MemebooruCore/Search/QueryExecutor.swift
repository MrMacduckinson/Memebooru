import Foundation

public struct SearchPage: Sendable {
    public let memes: [Meme]
    public let next: MemeCursor?
}

/// Turns a `Query` into one SQL statement over `meme` / `meme_tag` / `meme_fts`.
public final class QueryExecutor: @unchecked Sendable {
    private let db: Database
    private let tags: TagRegistry

    init(db: Database, tags: TagRegistry) { self.db = db; self.tags = tags }

    public func search(_ line: String, limit: Int = 60, after cursor: MemeCursor? = nil) throws -> SearchPage {
        try search(Query.parse(line), limit: limit, after: cursor)
    }

    public func search(_ q: Query, limit: Int = 60, after cursor: MemeCursor? = nil) throws -> SearchPage {
        var wheres: [String] = ["m.deleted_at IS NULL"]
        var params: [SQLBindable] = []
        var ftsWords: [String] = q.phrases.map { "\"\(Self.escapeFTS($0))\"" }
        // A word that can't be a tag name (`a"b`, `--x`) is plain text, not an error.
        func resolve(_ name: String) throws -> Tag? { TagName.isValid(name) ? try tags.resolve(name) : nil }
        // Each distinct term once: repeating a tag must not grow the SQL (SQLite caps expression depth at 1000).
        var seen = Set<String>()
        func firstTime(_ key: String) -> Bool { seen.insert(key).inserted }
        let chainTag = try tags.resolve(Collection.chainTag)
        var includesChainTag = false

        for term in q.include {
            switch term {
            case .tag(let name):
                if let t = try resolve(name) {
                    if t.id == chainTag?.id { includesChainTag = true }
                    guard firstTime("+t\(t.id)") else { continue }
                    wheres.append("EXISTS (SELECT 1 FROM meme_tag mt WHERE mt.meme_id = m.id AND mt.tag_id = ?)")
                    params.append(t.id)
                } else {
                    // unknown word → full-text prefix match
                    guard firstTime("+w\(name)") else { continue }
                    ftsWords.append("\"\(Self.escapeFTS(name))\"*")
                }
            case .glob(let pattern):
                guard firstTime("+g\(pattern)") else { continue }
                wheres.append("EXISTS (SELECT 1 FROM meme_tag mt WHERE mt.meme_id = m.id AND mt.tag_id IN (\(Self.globTagIDs)))")
                params.append(pattern); params.append(pattern)
            }
        }
        for term in q.exclude {
            switch term {
            case .tag(let name):
                guard let t = try resolve(name), firstTime("-t\(t.id)") else { continue }
                wheres.append("NOT EXISTS (SELECT 1 FROM meme_tag mt WHERE mt.meme_id = m.id AND mt.tag_id = ?)")
                params.append(t.id)
            case .glob(let pattern):
                guard firstTime("-g\(pattern)") else { continue }
                wheres.append("NOT EXISTS (SELECT 1 FROM meme_tag mt WHERE mt.meme_id = m.id AND mt.tag_id IN (\(Self.globTagIDs)))")
                params.append(pattern); params.append(pattern)
            }
        }
        // Chain tweets live inside the tweet that replies to / quotes them — not as results of their own,
        // unless the query asks for them (by name, or by an alias of the chain tag).
        let asksForChain = includesChainTag || q.include.contains { if case .tag(let n) = $0 { return ["chain", "thread", "quoted"].contains(n.lowercased()) } else { return false } }
        if !asksForChain, let chain = chainTag {
            wheres.append("NOT EXISTS (SELECT 1 FROM meme_tag mt WHERE mt.meme_id = m.id AND mt.tag_id = ?)")
            params.append(chain.id)
        }
        if !ftsWords.isEmpty {
            wheres.append("m.id IN (SELECT meme_id FROM meme_fts WHERE meme_fts MATCH ?)")
            params.append(ftsWords.joined(separator: " AND "))
        }
        if let c = cursor {
            wheres.append("(m.created_at < ? OR (m.created_at = ? AND m.id < ?))")
            params.append(c.createdAt); params.append(c.createdAt); params.append(c.id.rawValue)
        }
        params.append(limit + 1)
        let sql = """
        SELECT m.id, m.kind, m.presentation, m.created_at, m.updated_at, m.text_exact, m.text_verbatim, m.context, m.payload, m.deleted_at
          FROM meme m WHERE \(wheres.joined(separator: " AND "))
         ORDER BY m.created_at DESC, m.id DESC LIMIT ?
        """
        var rows = try db.query(sql, params, MemeStore.meme)
        var next: MemeCursor? = nil
        if rows.count > limit {
            rows.removeLast()
            if let last = rows.last { next = MemeCursor(createdAt: last.createdAt, id: last.id) }
        }
        return SearchPage(memes: rows, next: next)
    }

    public func count(_ q: Query) throws -> Int {
        // Cheap path: reuse search with a huge limit only for small collections; else count via SQL later.
        try search(q, limit: 1_000_000).memes.count
    }

    private static let globTagIDs =
        "SELECT id FROM tag WHERE name GLOB ? UNION SELECT tag_id FROM tag_alias WHERE name GLOB ?"

    private static func escapeFTS(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "\"\"")
    }
}
