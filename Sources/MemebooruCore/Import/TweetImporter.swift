import Foundation

/// Where tweet data comes from. Default backend: fxtwitter (no auth). Swappable when X breaks it.
public protocol TweetSource: Sendable {
    func fetch(tweetID: String) async throws -> FetchedTweet
}

public struct FetchedTweet: Sendable, Equatable {
    public struct Media: Sendable, Equatable {
        public enum Kind: String, Sendable { case photo, video, gif }
        public var kind: Kind
        public var url: String
        public var thumbnailURL: String?
        public var width: Int?
        public var height: Int?
        public init(kind: Kind, url: String, thumbnailURL: String? = nil, width: Int? = nil, height: Int? = nil) {
            self.kind = kind; self.url = url; self.thumbnailURL = thumbnailURL; self.width = width; self.height = height
        }
    }
    public var id: String
    public var url: String
    public var text: String
    public var authorName: String
    public var handle: String
    public var avatarURL: String?
    public var postedAt: Int64?
    public var replyToHandle: String?
    public var replyToTweetID: String?
    public var quotedTweetID: String?
    public var media: [Media]
    public var raw: Data
    /// The quoted tweet when the response carried it whole (x.com and fxtwitter both do) — saves a fetch.
    public var quoted: [FetchedTweet]

    public init(id: String, url: String, text: String, authorName: String, handle: String, avatarURL: String? = nil,
                postedAt: Int64? = nil, replyToHandle: String? = nil, replyToTweetID: String? = nil, quotedTweetID: String? = nil,
                media: [Media] = [], raw: Data = Data("{}".utf8), quoted: [FetchedTweet] = []) {
        self.id = id; self.url = url; self.text = text; self.authorName = authorName; self.handle = handle
        self.avatarURL = avatarURL; self.postedAt = postedAt; self.replyToHandle = replyToHandle
        self.replyToTweetID = replyToTweetID; self.quotedTweetID = quotedTweetID; self.media = media; self.raw = raw
        self.quoted = quoted
    }

    /// Orders of the looping-GIF media (see `TweetPayload.animatedMedia`); nil when there are none.
    public var animatedMedia: [Int]? {
        let orders = media.enumerated().filter { $0.element.kind == .gif }.map(\.offset)
        return orders.isEmpty ? nil : orders
    }

    /// Re-reads a saved tweet JSON (the `tweet.json` stored with every tweet meme): an x.com GraphQL tweet
    /// result or an fxtwitter response.
    /// Media sizes by order, for `TweetPayload.mediaSizes` (nil when x.com gave none).
    public var mediaSizes: [TweetPayload.MediaSize]? {
        let sizes = media.enumerated().compactMap { i, m -> TweetPayload.MediaSize? in
            guard let w = m.width, let h = m.height, w > 0, h > 0 else { return nil }
            return .init(order: i, width: w, height: h)
        }
        return sizes.isEmpty ? nil : sizes
    }

    public static func parse(raw: Data) -> FetchedTweet? {
        guard let root = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { return nil }
        if let fx = root["tweet"] as? [String: Any] { return FxTwitterSource.tweet(from: fx, raw: raw) }
        return XTimelineParser.tweet(from: root)
    }

    /// x.com hands out text with HTML entities (`&amp;`, `&lt;`, `&gt;`).
    public static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

public struct FxTwitterSource: TweetSource {
    let http: any HTTPClient
    public init(http: any HTTPClient) { self.http = http }

    public func fetch(tweetID: String) async throws -> FetchedTweet {
        let url = URL(string: "https://api.fxtwitter.com/status/\(tweetID)")!
        let resp = try await http.get(url, headers: ["User-Agent": "Memebooru/0.1"])
        guard resp.status == 200 else { throw CollectionError("fxtwitter HTTP \(resp.status) for \(tweetID)") }
        guard let root = try JSONSerialization.jsonObject(with: resp.body) as? [String: Any],
              let t = root["tweet"] as? [String: Any] else { throw CollectionError("fxtwitter: unexpected JSON") }
        return Self.tweet(from: t, raw: resp.body)
    }

    static func tweet(from t: [String: Any], raw: Data) -> FetchedTweet {
        let author = t["author"] as? [String: Any] ?? [:]
        var media: [FetchedTweet.Media] = []
        if let all = (t["media"] as? [String: Any])?["all"] as? [[String: Any]] {
            for m in all {
                guard let type = m["type"] as? String, let u = m["url"] as? String else { continue }
                media.append(.init(kind: FetchedTweet.Media.Kind(rawValue: type) ?? .photo, url: u,
                                   thumbnailURL: m["thumbnail_url"] as? String, width: m["width"] as? Int, height: m["height"] as? Int))
            }
        }
        let id = (t["id"] as? String) ?? ""
        let quote = t["quote"] as? [String: Any]
        return FetchedTweet(
            id: id, url: (t["url"] as? String) ?? "https://x.com/i/status/\(id)",
            text: FetchedTweet.decodeEntities((t["text"] as? String) ?? ""), authorName: (author["name"] as? String) ?? "",
            handle: (author["screen_name"] as? String) ?? "", avatarURL: author["avatar_url"] as? String,
            postedAt: (t["created_timestamp"] as? Int).map { Int64($0) * 1000 },
            replyToHandle: t["replying_to"] as? String, replyToTweetID: t["replying_to_status"] as? String,
            quotedTweetID: quote?["id"] as? String, media: media, raw: raw,
            quoted: quote.map { q in [Self.tweet(from: q, raw: (try? JSONSerialization.data(withJSONObject: ["tweet": q])) ?? Data())] } ?? [])
    }
}

public struct TweetImporter: Sendable {
    public let staging: StagingArea
    public let source: any TweetSource
    public let http: any HTTPClient
    public var archive = true

    public init(staging: StagingArea, source: any TweetSource, http: any HTTPClient, archive: Bool = true) {
        self.staging = staging; self.source = source; self.http = http; self.archive = archive
    }

    public static func tweetID(from string: String) -> String? {
        if !string.isEmpty, string.allSatisfy({ $0.isASCII && $0.isNumber }) { return string }
        guard let r = string.range(of: #"status(?:es)?/(\d+)"#, options: .regularExpression) else { return nil }
        return String(string[r]).split(separator: "/").last.map(String.init)
    }

    /// Fetches the tweet, downloads media + avatar, archives on Wayback, stages a `tweet` item.
    public func importTweet(_ urlOrID: String) async throws -> StagedItem {
        guard let id = Self.tweetID(from: urlOrID) else { throw CollectionError("not a tweet URL: \(urlOrID)") }
        return try await stage(try await source.fetch(tweetID: id))
    }

    /// Stage an already-fetched tweet: downloads media + avatar, archives on Wayback.
    /// `parentID`: stage it as part of that staged tweet's chain (see `StagedItem.parentID`).
    @discardableResult
    public func stage(_ tw: FetchedTweet, parentID: String? = nil, extraTags: [String] = []) async throws -> StagedItem {
        let id = tw.id
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mb-tweet-\(id)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let json = tmp.appendingPathComponent("tweet.json")
        try tw.raw.write(to: json)
        var extras: [StagedExtra] = []
        for (i, m) in tw.media.enumerated() {
            if let data = try? await download(m.url) {
                let ext = Self.fileExt(m.url, fallback: m.kind == .photo ? "jpg" : "mp4")
                let f = tmp.appendingPathComponent("media_\(i).\(ext)")
                try data.write(to: f)
                extras.append(StagedExtra(role: .media, order: i, url: f))
            }
        }
        if let av = tw.avatarURL, let data = try? await download(av) {
            let f = tmp.appendingPathComponent("avatar.\(Self.fileExt(av, fallback: "jpg"))")
            try data.write(to: f)
            extras.append(StagedExtra(role: .avatar, order: 0, url: f))
        }
        let wayback = archive && parentID == nil ? try? await WaybackArchiver(http: http).archive(tw.url) : nil

        var payload = TweetPayload(tweetID: tw.id, url: tw.url, authorName: tw.authorName, handle: tw.handle,
                                   postedAt: tw.postedAt, replyToTweetID: tw.replyToTweetID, replyToHandle: tw.replyToHandle,
                                   quotedTweetID: tw.quotedTweetID, waybackURL: wayback, animatedMedia: tw.animatedMedia)
        payload.mediaSizes = tw.mediaSizes
        var ctx: [String] = []
        if let r = tw.replyToHandle { ctx.append("reply to @\(r)") }
        if tw.quotedTweetID != nil { ctx.append("quote tweet") }
        let date = tw.postedAt.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        var tags = ["x"] + extraTags
        if !tw.handle.isEmpty { tags.append("@\(tw.handle.lowercased())") }
        return try staging.add(file: json, source: "x:\(tw.handle)", originalName: "tweet-\(tw.id).json", kind: .tweet,
                               date: date, textVerbatim: tw.text.isEmpty ? nil : tw.text,
                               context: ctx.isEmpty ? nil : ctx.joined(separator: ", "),
                               payload: .tweet(payload), extraTags: tags, extras: extras, parentID: parentID)
    }

    /// A tweet with its media already downloaded to a temp folder — ready to insert directly.
    public struct PreparedMedia: Sendable { public let url: URL; public let width: Int?; public let height: Int? }
    public struct PreparedTweet: Sendable {
        public let tweet: FetchedTweet
        public let jsonURL: URL
        public let media: [PreparedMedia]      // order preserved
        public let avatarURL: URL?
        let tempDir: URL
    }

    /// Download a tweet's media to a temp folder (does the slow network work; no DB writes, no Wayback).
    public func prepare(_ tw: FetchedTweet) async throws -> PreparedTweet {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mb-tw-\(tw.id)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let json = tmp.appendingPathComponent("tweet.json")
        try tw.raw.write(to: json)
        var media: [PreparedMedia] = []
        for (i, m) in tw.media.enumerated() {
            guard let data = try? await download(m.url) else { continue }
            let ext = Self.fileExt(m.url, fallback: m.kind == .photo ? "jpg" : "mp4")
            let f = tmp.appendingPathComponent("media_\(i).\(ext)")
            try data.write(to: f); media.append(PreparedMedia(url: f, width: m.width, height: m.height))
        }
        var avatar: URL? = nil
        if let av = tw.avatarURL, let data = try? await download(av) {
            let f = tmp.appendingPathComponent("avatar.\(Self.fileExt(av, fallback: "jpg"))")
            try data.write(to: f); avatar = f
        }
        return PreparedTweet(tweet: tw, jsonURL: json, media: media, avatarURL: avatar, tempDir: tmp)
    }

    /// Insert a prepared tweet straight into the collection as a `tweet` meme (no staging round-trip).
    /// Enqueues a background Wayback snapshot. Records `create_meme` in `undoBatch` if given.
    @discardableResult
    /// `asChain`: kept only as part of another tweet's chain — tagged `chain`, no tweet/year tags, no Wayback.
    public func commitPrepared(_ p: PreparedTweet, into collection: Collection, extraTags: [String] = [], undoBatch: Int64? = nil,
                               asChain: Bool = false) throws -> Meme {
        defer { try? FileManager.default.removeItem(at: p.tempDir) }
        let tw = p.tweet
        var payload = TweetPayload(tweetID: tw.id, url: tw.url, authorName: tw.authorName, handle: tw.handle,
                                   postedAt: tw.postedAt, replyToTweetID: tw.replyToTweetID, replyToHandle: tw.replyToHandle,
                                   quotedTweetID: tw.quotedTweetID, waybackURL: nil, animatedMedia: tw.animatedMedia)
        payload.mediaSizes = tw.mediaSizes
        var ctx: [String] = []
        if let r = tw.replyToHandle { ctx.append("reply to @\(r)") }
        if tw.quotedTweetID != nil { ctx.append("quote tweet") }
        let created = tw.postedAt ?? Clock.nowMillis()
        let year = Calendar(identifier: .gregorian).component(.year, from: Date(timeIntervalSince1970: Double(created) / 1000))
        let meme = Meme(kind: .tweet, presentation: .native, createdAt: created,
                        textVerbatim: tw.text.isEmpty ? nil : tw.text, context: ctx.isEmpty ? nil : ctx.joined(separator: ", "),
                        payload: .tweet(payload))

        return try collection.db.transaction {
            try collection.memes.insert(meme)
            // primary = tweet.json
            let primary = try collection.media.put(p.jsonURL, ext: "json", move: true)
            try collection.memes.addAsset(Asset(memeID: meme.id, role: .primary, sha256: primary.sha256, ext: "json", mime: "application/json", bytes: primary.bytes, originalName: "tweet-\(tw.id).json"))
            if let av = p.avatarURL {
                let st = try collection.media.put(av, move: true)
                try collection.memes.addAsset(Asset(memeID: meme.id, role: .avatar, sha256: st.sha256, ext: st.ext, mime: MediaType.detect(ext: st.ext)?.mime ?? "image/jpeg", bytes: st.bytes))
            }
            for (i, pm) in p.media.enumerated() {
                let st = try collection.media.put(pm.url, move: true)
                let mime = MediaType.detect(ext: st.ext)?.mime ?? "application/octet-stream"
                try collection.memes.addAsset(Asset(memeID: meme.id, role: .media, sha256: st.sha256, ext: st.ext, mime: mime,
                                                    width: pm.width, height: pm.height, bytes: st.bytes, order: i))
            }
            // tags
            for t in (asChain ? [Collection.chainTag, "x"] : ["tweet", String(year), "x"]) { try collection.memes.addTag(meme.id, t, kind: .meta) }
            if !tw.handle.isEmpty { try collection.memes.addTag(meme.id, "@\(tw.handle.lowercased())", kind: .meta) }
            for t in extraTags { try collection.memes.addTag(meme.id, t, kind: .normal) }
            if let undoBatch { try collection.undo.record(undoBatch, op: "create_meme", data: meme.id.rawValue) }
            if !asChain { try collection.wayback.enqueue(meme.id, url: tw.url) }
            return meme
        }
    }

    /// The file extension a downloaded media URL's file gets: its path's own (query ignored) when it is a
    /// known media type, else `fallback` (e.g. `…/media/abc?format=jpg`).
    static func fileExt(_ url: String, fallback: String) -> String {
        let ext = MediaStore.normalizeExt(URL(string: url)?.pathExtension ?? "")
        return MediaType.detect(ext: ext) != nil ? ext : fallback
    }

    private func download(_ s: String) async throws -> Data {
        guard let u = URL(string: s) else { throw CollectionError("bad media url") }
        let r = try await http.get(u, headers: ["User-Agent": "Memebooru/0.1"])
        guard r.status == 200 else { throw CollectionError("HTTP \(r.status) for \(s)") }
        return r.body
    }
}

/// Wayback Machine: reuse an existing snapshot or request a new one.
public struct WaybackArchiver: Sendable {
    let http: any HTTPClient
    public init(http: any HTTPClient) { self.http = http }

    public func existing(_ url: String) async throws -> String? {
        let q = URL(string: "https://archive.org/wayback/available?url=\(url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url)")!
        let r = try await http.get(q, headers: [:])
        guard r.status == 200, let root = try JSONSerialization.jsonObject(with: r.body) as? [String: Any],
              let closest = (root["archived_snapshots"] as? [String: Any])?["closest"] as? [String: Any],
              let u = closest["url"] as? String else { return nil }
        return u
    }

    public func archive(_ url: String) async throws -> String? {
        if let e = try await existing(url) { return e }
        let r = try await http.get(URL(string: "https://web.archive.org/save/\(url)")!, headers: ["User-Agent": "Memebooru/0.1"])
        if let loc = r.headers["content-location"] ?? r.headers["location"] {
            return loc.hasPrefix("http") ? loc : "https://web.archive.org" + loc
        }
        return nil
    }
}
