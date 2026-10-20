public struct TagError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ d: String) { description = d }
}

public enum TagName {
    /// Lowercase, trimmed, internal whitespace → `_`. Throws on characters that clash with
    /// query syntax (`"`, `*`, leading `-`) or on empty input.
    public static func normalize(_ raw: String) throws -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        s = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: "_")
        guard !s.isEmpty else { throw TagError("empty tag") }
        guard !s.hasPrefix("-") else { throw TagError("tag cannot start with '-': \(raw)") }
        guard !s.contains("\""), !s.contains("*") else { throw TagError("tag cannot contain '\"' or '*': \(raw)") }
        return s
    }

    public static func isValid(_ raw: String) -> Bool { (try? normalize(raw)) != nil }
}
