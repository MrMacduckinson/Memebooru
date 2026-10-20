/// A file belonging to a meme. Content-addressed by SHA-256.
public struct Asset: Sendable, Equatable {
    public enum Role: String, Codable, Sendable {
        case primary      // the meme file itself
        case media        // tweet/article attached media (may be several)
        case avatar
        case render       // PNG rendering of native tweet/article (for bot / sharing)
        case cover        // user-chosen gallery cover
        case original     // the uncommon-format file a converted primary was made from (kept on request)
        case part         // one picture of a combined meme (in order); the primary is drawn from them
    }
    public var id: Int64
    public var memeID: MemeID
    public var role: Role
    public var sha256: String
    public var ext: String
    public var mime: String
    public var width: Int?
    public var height: Int?
    public var durationMs: Int64?
    public var bytes: Int64
    public var dhash: Int64?
    public var phash: Int64?
    public var order: Int
    public var originalName: String?
    /// `container/video/audio` from ffprobe (see `MediaProbe.codecs`); nil when not probed.
    public var codecs: String?
    /// Set on a converted file: the file it was made from (whether or not that one was kept).
    public var sourceSHA256: String?
    public var sourceExt: String?
    public var sourceCodecs: String?
    /// Set on a file made by cropping / trimming another (the kept original, `sourceSHA256`): what was done.
    public var edit: MediaEdit?

    public init(id: Int64 = 0, memeID: MemeID, role: Role, sha256: String, ext: String, mime: String,
                width: Int? = nil, height: Int? = nil, durationMs: Int64? = nil, bytes: Int64,
                dhash: Int64? = nil, phash: Int64? = nil, order: Int = 0, originalName: String? = nil,
                codecs: String? = nil, sourceSHA256: String? = nil, sourceExt: String? = nil, sourceCodecs: String? = nil,
                edit: MediaEdit? = nil) {
        self.id = id; self.memeID = memeID; self.role = role; self.sha256 = sha256; self.ext = ext
        self.mime = mime; self.width = width; self.height = height; self.durationMs = durationMs
        self.bytes = bytes; self.dhash = dhash; self.phash = phash; self.order = order; self.originalName = originalName
        self.codecs = codecs; self.sourceSHA256 = sourceSHA256; self.sourceExt = sourceExt; self.sourceCodecs = sourceCodecs
        self.edit = edit
    }

    /// "MKV · AV1 · Opus".
    public var formatLabel: String { FormatPolicy.label(ext: ext, codecs: codecs) }
    public func compatibility(kind: MemeKind) -> Compatibility { FormatPolicy.compatibility(kind: kind, ext: ext, codecs: codecs) }
    /// Where a converted file came from, e.g. "MKV · AV1 · Opus".
    public var sourceLabel: String? { sourceExt.map { FormatPolicy.label(ext: $0, codecs: sourceCodecs) } }
}
