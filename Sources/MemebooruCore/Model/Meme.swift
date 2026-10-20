import Foundation

public struct MemeID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init() { self.rawValue = UUID().uuidString.lowercased() }
    public var description: String { rawValue }
}

/// How a tweet is shown (see `TweetPayload.display`).
public enum TweetDisplay: String, Codable, Sendable { case card, media }

public struct TweetPayload: Codable, Sendable, Equatable {
    public var tweetID: String
    public var url: String
    public var authorName: String
    public var handle: String
    public var postedAt: Int64?          // unix ms
    public var replyToTweetID: String?
    public var replyToHandle: String?
    public var quotedTweetID: String?
    public var waybackURL: String?
    /// Orders of the media that are x.com "GIFs" (silent looping MP4s): played like GIFs, not videos.
    public var animatedMedia: [Int]?
    /// How to show it: as a tweet (frame, author, date) or just its media. nil = automatic, see `showsAsMedia`.
    public var display: TweetDisplay?
    /// Pixel sizes of the media by order, as x.com reports them — so cards get their final shape before
    /// any file is opened (staged media has no analysed width/height).
    public var mediaSizes: [MediaSize]?

    public struct MediaSize: Codable, Sendable, Equatable {
        public var order: Int, width: Int, height: Int
        public init(order: Int, width: Int, height: Int) { self.order = order; self.width = width; self.height = height }
    }
    public func mediaSize(order: Int) -> MediaSize? { mediaSizes?.first { $0.order == order } }

    /// Shown as bare media: chosen so, or (automatic) a tweet that is only media — no text, not a reply,
    /// not a quote. The tweet's details are kept either way.
    public func showsAsMedia(text: String?, mediaCount: Int) -> Bool {
        guard mediaCount > 0 else { return false }
        switch display {
        case .media: return true
        case .card: return false
        case nil:
            return (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && replyToTweetID == nil && quotedTweetID == nil
        }
    }
    public init(tweetID: String, url: String, authorName: String, handle: String,
                postedAt: Int64? = nil, replyToTweetID: String? = nil, replyToHandle: String? = nil,
                quotedTweetID: String? = nil, waybackURL: String? = nil, animatedMedia: [Int]? = nil) {
        self.tweetID = tweetID; self.url = url; self.authorName = authorName; self.handle = handle
        self.postedAt = postedAt; self.replyToTweetID = replyToTweetID; self.replyToHandle = replyToHandle
        self.quotedTweetID = quotedTweetID; self.waybackURL = waybackURL; self.animatedMedia = animatedMedia
    }
}

public struct ArticlePayload: Codable, Sendable, Equatable {
    public var url: String
    public var title: String
    public var description: String?
    public var site: String?
    public init(url: String, title: String, description: String? = nil, site: String? = nil) {
        self.url = url; self.title = title; self.description = description; self.site = site
    }
}

public enum MemePayload: Sendable, Equatable, Codable {
    public var composite: CompositePayload? { if case .composite(let p) = self { return p } else { return nil } }

    case none
    case tweet(TweetPayload)
    case article(ArticlePayload)
    /// Several pictures kept as one meme (see `CompositeLayout`).
    case composite(CompositePayload)

    private enum CodingKeys: String, CodingKey { case kind, tweet, article, composite }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "tweet": self = .tweet(try c.decode(TweetPayload.self, forKey: .tweet))
        case "article": self = .article(try c.decode(ArticlePayload.self, forKey: .article))
        case "composite": self = .composite(try c.decode(CompositePayload.self, forKey: .composite))
        default: self = .none
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none: try c.encode("none", forKey: .kind)
        case .tweet(let p): try c.encode("tweet", forKey: .kind); try c.encode(p, forKey: .tweet)
        case .article(let p): try c.encode("article", forKey: .kind); try c.encode(p, forKey: .article)
        case .composite(let p): try c.encode("composite", forKey: .kind); try c.encode(p, forKey: .composite)
        }
    }

    public func encodeJSON() throws -> String? {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        switch self {
        case .none: return nil
        case .tweet(let p): return String(decoding: try enc.encode(p), as: UTF8.self)
        case .article(let p): return String(decoding: try enc.encode(p), as: UTF8.self)
        case .composite(let p): return String(decoding: try enc.encode(p), as: UTF8.self)
        }
    }

    public static func decode(kind: MemeKind, json: String?) throws -> MemePayload {
        guard let json, let data = json.data(using: .utf8) else { return .none }
        switch kind {
        case .tweet: return .tweet(try JSONDecoder().decode(TweetPayload.self, from: data))
        case .article: return .article(try JSONDecoder().decode(ArticlePayload.self, from: data))
        case .image: return (try? JSONDecoder().decode(CompositePayload.self, from: data)).map { .composite($0) } ?? .none
        default: return .none
        }
    }
}

public struct Meme: Sendable, Equatable {
    public var id: MemeID
    public var kind: MemeKind
    public var presentation: Presentation
    public var createdAt: Int64        // unix ms
    public var updatedAt: Int64
    public var textExact: String?      // text as it should be spelled
    public var textVerbatim: String?   // text exactly as in the meme, typos included
    public var context: String?        // explanation / history
    public var payload: MemePayload
    public var deletedAt: Int64?

    public init(id: MemeID = MemeID(), kind: MemeKind, presentation: Presentation = .native,
                createdAt: Int64 = Clock.nowMillis(), updatedAt: Int64? = nil,
                textExact: String? = nil, textVerbatim: String? = nil, context: String? = nil,
                payload: MemePayload = .none, deletedAt: Int64? = nil) {
        self.id = id; self.kind = kind; self.presentation = presentation
        self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt
        self.textExact = textExact; self.textVerbatim = textVerbatim; self.context = context
        self.payload = payload; self.deletedAt = deletedAt
    }
}

public enum Clock {
    public static func nowMillis() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}
