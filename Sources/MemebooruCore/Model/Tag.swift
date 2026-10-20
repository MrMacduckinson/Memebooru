public enum TagKind: String, Codable, Sendable, CaseIterable {
    /// Describes content: `stalin`, `glasses`, `ussr_flag`.
    case normal
    /// Describes circumstances: `2022`, `source_unknown`, `picture`, `telegram_message`.
    case meta
}

public struct Tag: Hashable, Sendable {
    public let id: Int64
    public let name: String
    public let kind: TagKind
    public let createdAt: Int64
    public init(id: Int64, name: String, kind: TagKind, createdAt: Int64) {
        self.id = id; self.name = name; self.kind = kind; self.createdAt = createdAt
    }
}

public struct TagAlias: Hashable, Sendable {
    public let name: String
    public let tagID: Int64
}

/// Autocomplete row: either a tag itself or an alias pointing to one.
public struct TagSuggestion: Hashable, Sendable {
    public let text: String        // what user typed against
    public let tag: Tag            // canonical
    public let isAlias: Bool
    public let usage: Int
}
