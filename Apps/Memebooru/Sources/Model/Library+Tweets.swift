import SwiftUI
import MemebooruCore

/// One tweet as the cards draw it — from a saved meme or a staged item (with its staged chain).
struct TweetCardModel: Identifiable {
    struct Media: Identifiable {
        enum Kind { case photo, video, gif }
        let url: URL
        let kind: Kind
        var width: Int?
        var height: Int?
        var id: String { url.path }
        /// Width / height when known from x.com.
        var aspect: CGFloat? {
            guard let width, let height, width > 0, height > 0 else { return nil }
            return CGFloat(width) / CGFloat(height)
        }
    }

    let id: String
    var memeID: MemeID?
    var authorName = ""
    var handle = ""
    var avatar: URL?
    var text = ""
    var replyTo: String?
    var media: [Media] = []
    var quoted: [TweetCardModel] = []
    /// Quotes a tweet that isn't here (yet).
    var quoteMissing = false
    var postedAt: Int64?
    var url: String?
    /// Shown as bare media (no frame, author, date) — see `TweetPayload.showsAsMedia`.
    var mediaOnly = false
}

extension Library {
    func tweetModel(_ meme: Meme, withQuote: Bool = true) -> TweetCardModel {
        _ = threadVersion
        var m = TweetCardModel(id: meme.id.rawValue, memeID: meme.id)
        m.text = FetchedTweet.decodeEntities((meme.textVerbatim ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        guard case .tweet(let p) = meme.payload else { return m }
        m.authorName = p.authorName; m.handle = p.handle; m.replyTo = p.replyToHandle; m.postedAt = p.postedAt; m.url = p.url
        let assets = assets(of: meme.id)
        m.avatar = assets.first { $0.role == .avatar }.flatMap { fileURL($0) }
        let animated = Set(p.animatedMedia ?? [])
        m.media = assets.filter { $0.role == .media }.sorted { $0.order < $1.order }.compactMap { a in
            guard let url = fileURL(a) else { return nil }
            let size = p.mediaSize(order: a.order)
            var item = TweetCardModel.Media(url: url, kind: Self.mediaKind(ext: a.ext, animated: animated.contains(a.order)),
                                            width: a.width ?? size?.width, height: a.height ?? size?.height)
            Self.measureIfNeeded(&item)
            return item
        }
        if withQuote, p.quotedTweetID != nil {
            if let q = quotedTweet(of: meme.id) { m.quoted = [tweetModel(q, withQuote: false)] } else { m.quoteMissing = true }
        }
        m.mediaOnly = p.showsAsMedia(text: m.text, mediaCount: m.media.count)
        return m
    }

    /// A staged tweet; its quote comes from `chain` (its staged chain) or the collection.
    func tweetModel(staged item: StagedItem, chain: [StagedItem] = [], withQuote: Bool = true) -> TweetCardModel {
        var m = TweetCardModel(id: item.id)
        m.text = FetchedTweet.decodeEntities((item.textVerbatim ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        guard case .tweet(let p) = item.payload else { return m }
        m.authorName = p.authorName; m.handle = p.handle; m.replyTo = p.replyToHandle; m.postedAt = p.postedAt; m.url = p.url
        let extras = stagedExtras(item)
        m.avatar = extras.first { $0.role == .avatar }?.url
        let animated = Set(p.animatedMedia ?? [])
        m.media = extras.filter { $0.role == .media }.map {
            let size = p.mediaSize(order: $0.order)
            var item = TweetCardModel.Media(url: $0.url, kind: Self.mediaKind(ext: $0.url.pathExtension, animated: animated.contains($0.order)),
                                            width: size?.width, height: size?.height)
            Self.measureIfNeeded(&item)
            return item
        }
        if withQuote, let qid = p.quotedTweetID {
            if let q = chain.first(where: { $0.payloadTweetID == qid }) {
                m.quoted = [tweetModel(staged: q, withQuote: false)]
            } else if let id = try? collection?.memes.memeForTweet(qid), let q = meme(id) {
                m.quoted = [tweetModel(q, withQuote: false)]
            } else { m.quoteMissing = true }
        }
        m.mediaOnly = p.showsAsMedia(text: m.text, mediaCount: m.media.count)
        return m
    }

    /// Flip a tweet between the tweet card and bare media (saved with the tweet, so it syncs).
    func toggleTweetDisplay(_ id: MemeID) {
        guard var meme = meme(id), case .tweet(var p) = meme.payload else { return }
        p.display = tweetModel(meme, withQuote: false).mediaOnly ? .card : .media
        meme.payload = .tweet(p)
        update(meme)
        threadVersion += 1
    }

    func toggleTweetDisplay(staged item: StagedItem) {
        guard case .tweet(var p) = item.payload else { return }
        var i = item
        p.display = tweetModel(staged: item, withQuote: false).mediaOnly ? .card : .media
        i.payload = .tweet(p)
        updateStaged(i)
    }

    /// The staged chain's thread above `item`: what it replies to, nearest first.
    func stagedAncestors(of item: StagedItem, chain: [StagedItem]) -> [StagedItem] {
        var out: [StagedItem] = []
        var parent: String? = { if case .tweet(let p) = item.payload { return p.replyToTweetID } else { return nil } }()
        while let pid = parent, let next = chain.first(where: { $0.payloadTweetID == pid }), out.count < 50 {
            out.append(next)
            if case .tweet(let p) = next.payload { parent = p.replyToTweetID } else { parent = nil }
        }
        return out
    }

    static func mediaKind(ext: String, animated: Bool) -> TweetCardModel.Media.Kind {
        switch MediaType.detect(ext: ext)?.kind {
        case .video: return animated ? .gif : .video
        case .gif: return .gif
        default: return .photo
        }
    }

    /// Pictures whose size x.com didn't give: read it from the file's header (no decoding), so the card
    /// has its final shape on the first frame instead of jumping when the picture loads.
    static func measureIfNeeded(_ m: inout TweetCardModel.Media) {
        guard m.aspect == nil, m.kind == .photo || m.url.pathExtension.lowercased() == "gif",
              let size = MediaLoader.pixelSize(m.url) else { return }
        m.width = Int(size.width); m.height = Int(size.height)
    }

    /// An avatar: small files, read straight away (and kept).
    func avatarImage(_ url: URL) -> PlatformImage? {
        let key = "avatar:" + url.path
        if let img = loader.cached(key) { return img }
        guard let img = PlatformImage(contentsOfFile: url.path) else { return nil }
        loader.store(img, for: key)
        return img
    }

    /// A card-sized still for any picture or video file, if already made.
    func cachedPoster(_ url: URL) -> PlatformImage? { loader.cached("poster:" + url.path) }

    /// A card-sized still for any picture or video file, made on the media pool. Collection files keep
    /// theirs on disk (thumbs/<sha>.jpg); staged ones only in memory.
    func loadPoster(_ url: URL) async -> PlatformImage? {
        let analyzer = analyzer
        let media = collection?.media
        return await loader.image("poster:" + url.path) {
            let kind = MediaType.detect(url: url)?.kind ?? .image
            if let media, url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == media.root.standardizedFileURL,
               let made = try? analyzer.ensureThumbnail(for: url, sha256: url.deletingPathExtension().lastPathComponent, kind: kind, in: media) {
                return PlatformImage(contentsOfFile: made.path)
            }
            return (try? analyzer.thumbnail(url, kind: kind)).flatMap { $0 }.flatMap { PlatformImage(data: $0) }
        }
    }
}

extension Library {
    /// The tweet's picture (as the bot sends it), drawn now if missing or out of date.
    func tweetRender(_ meme: Meme) -> Asset? {
        guard let c = collection else { return nil }
        do { return try c.tweetRender(meme, analyzer: analyzer) } catch { errorMessage = "\(error)"; return nil }
    }
}

extension Library {
    /// The tweets staged along with `item` (its thread and quotes).
    func stagedChain(_ item: StagedItem) -> [StagedItem] {
        _ = stagingVersion
        return (try? staging?.chain(of: item.id)) ?? []
    }

    /// A staged item's extra files (media, avatar), listed once per staging reload.
    func stagedExtras(_ item: StagedItem) -> [StagedExtra] {
        _ = stagingVersion
        if let e = extrasCache[item.id] { return e }
        let e = staging?.extras(item) ?? []
        extrasCache[item.id] = e
        return e
    }
}

extension Library {
    /// Width / height of a tweet shown as bare media (its first item), nil when it's shown as a tweet.
    func mediaOnlyAspect(_ meme: Meme) -> CGFloat? {
        guard meme.kind == .tweet else { return nil }
        let m = tweetModel(meme, withQuote: false)
        guard m.mediaOnly, let first = m.media.first else { return nil }
        if m.media.count > 1 { return 1 }                       // a grid: square
        return first.aspect ?? cachedPoster(first.url).map { $0.size.width / max(1, $0.size.height) } ?? 1
    }

    /// What Share hands over for a tweet: its media when shown as media, else its picture (as the bot sends it).
    func tweetShareURL(_ meme: Meme) -> URL? {
        let m = tweetModel(meme, withQuote: false)
        if m.mediaOnly, let first = m.media.first { return first.url }
        return tweetRender(meme).flatMap { fileURL($0) }
    }
}
