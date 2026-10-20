public struct Relation: Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case duplicate   // same meme, different file
        case variant     // same template, different caption
        case contains    // `from` contains `to` (partially or wholly)
        case replyTo     // tweet reply chain
        case quote       // tweet quotes another
        case partOf      // part of a series
    }
    public var from: MemeID
    public var to: MemeID
    public var kind: Kind
    public var note: String?
    public var createdAt: Int64
    public var deletedAt: Int64?
    public init(from: MemeID, to: MemeID, kind: Kind, note: String? = nil,
                createdAt: Int64 = Clock.nowMillis(), deletedAt: Int64? = nil) {
        self.from = from; self.to = to; self.kind = kind; self.note = note
        self.createdAt = createdAt; self.deletedAt = deletedAt
    }
}
