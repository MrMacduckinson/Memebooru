/// Parsed search line. Syntax:
///   `stalin child`      — all tags must be present (aliases resolve)
///   `-ussr`             — tag must be absent
///   `stal*`             — glob over tag names/aliases, any match
///   `"обед"`            — phrase over text_exact / text_verbatim / context (FTS5)
/// A bare word that is not a known tag falls back to full-text search.
public struct Query: Equatable, Sendable {
    public enum Term: Equatable, Sendable {
        case tag(String)      // normalized name or alias
        case glob(String)     // contains `*`
    }
    public var include: [Term] = []
    public var exclude: [Term] = []
    public var phrases: [String] = []

    public init() {}

    public var isEmpty: Bool { include.isEmpty && exclude.isEmpty && phrases.isEmpty }

    public static func parse(_ line: String) -> Query {
        // SQLite reads bound text up to a NUL: one inside a term would cut its FTS quoting short.
        let line = line.replacingOccurrences(of: "\0", with: " ")
        var q = Query()
        var i = line.startIndex
        func skipSpaces() { while i < line.endIndex, line[i].isWhitespace { i = line.index(after: i) } }
        while true {
            skipSpaces()
            guard i < line.endIndex else { break }
            var negate = false
            if line[i] == "-" {
                negate = true
                i = line.index(after: i)
                guard i < line.endIndex, !line[i].isWhitespace else { continue }
            }
            if line[i] == "\"" {
                i = line.index(after: i)
                let start = i
                while i < line.endIndex, line[i] != "\"" { i = line.index(after: i) }
                let phrase = String(line[start..<i]).trimmingCharacters(in: .whitespaces)
                if i < line.endIndex { i = line.index(after: i) }
                if !phrase.isEmpty { q.phrases.append(phrase) }
                continue
            }
            let start = i
            while i < line.endIndex, !line[i].isWhitespace { i = line.index(after: i) }
            let word = String(line[start..<i]).lowercased()
            guard !word.isEmpty else { continue }
            let term: Term = word.contains("*") ? .glob(word) : .tag(word)
            if negate { q.exclude.append(term) } else { q.include.append(term) }
        }
        return q
    }
}
