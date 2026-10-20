import Foundation

/// Loads reply chains and quoted tweets around a saved tweet, on demand.
/// Fetches referenced tweets by id (via the injected source) and links them with relations.
public struct TweetThreadLoader: Sendable {
    public let collection: Collection
    public let importer: TweetImporter    // provides the source + media download/insert

    public init(collection: Collection, importer: TweetImporter) {
        self.collection = collection; self.importer = importer
    }

    /// Insert a fetched tweet as a meme (or return the existing one). Media + avatar saved.
    private func insert(_ tw: FetchedTweet, tags: [String]) async throws -> MemeID {
        if let existing = try collection.memes.memeForTweet(tw.id) { return existing }
        let prepared = try await importer.prepare(tw)
        let meme = try importer.commitPrepared(prepared, into: collection, extraTags: tags, asChain: true)
        return meme.id
    }

    /// The whole chain of a saved tweet — what it replies to, up the thread, and what it (or those)
    /// quotes — saved and linked. Returns (saved, missing).
    @discardableResult
    public func loadChain(of id: MemeID) async throws -> (saved: Int, missing: Int) {
        guard let p = try payload(id), let primary = try collection.memes.asset(of: id, role: .primary) else { return (0, 0) }
        let raw = try? Data(contentsOf: collection.media.url(sha256: primary.sha256, ext: primary.ext))
        let root = raw.flatMap(FetchedTweet.parse(raw:))
            ?? FetchedTweet(id: p.tweetID, url: p.url, text: "", authorName: p.authorName, handle: p.handle,
                            replyToTweetID: p.replyToTweetID, quotedTweetID: p.quotedTweetID)
        let known = KnownTweets(try collection.tweetIDs())
        let (links, missing) = await TweetChainLoader(source: importer.source).collect(for: root, known: known)
        var saved: Set<MemeID> = [id]
        for l in links {
            saved.insert(try await insert(l.tweet, tags: [l.role == .parent ? "thread" : "quoted"]))
        }
        try collection.linkTweets(saved)
        return (saved.count - 1, missing)
    }

    private func payload(_ id: MemeID) throws -> TweetPayload? {
        if case .tweet(let p)? = try collection.memes.get(id)?.payload { return p }
        return nil
    }

    public struct Step: Sendable { public let loaded: MemeID; public let hasMore: Bool }

    /// Load the single tweet this one replies to, link it, and report whether that one is itself a reply.
    @discardableResult
    public func loadReplyParent(of id: MemeID) async throws -> Step? {
        guard let p = try payload(id), let parentID = p.replyToTweetID else { return nil }
        let tw = try await importer.source.fetch(tweetID: parentID)
        let parentMeme = try await insert(tw, tags: ["thread"])
        try collection.memes.addRelation(Relation(from: id, to: parentMeme, kind: .replyTo))
        let more = tw.replyToTweetID != nil
        return Step(loaded: parentMeme, hasMore: more)
    }

    /// Walk up the reply chain up to `maxDepth` parents. Returns the memes loaded (nearest first).
    @discardableResult
    public func loadReplyChain(of id: MemeID, maxDepth: Int = 20) async throws -> [MemeID] {
        var loaded: [MemeID] = []
        var current = id
        for _ in 0..<maxDepth {
            guard let step = try await loadReplyParent(of: current) else { break }
            loaded.append(step.loaded)
            if !step.hasMore { break }
            current = step.loaded
        }
        return loaded
    }

    /// Load the tweet this one quotes and link it.
    @discardableResult
    public func loadQuoted(of id: MemeID) async throws -> MemeID? {
        guard let p = try payload(id), let quotedID = p.quotedTweetID else { return nil }
        let tw = try await importer.source.fetch(tweetID: quotedID)
        let quotedMeme = try await insert(tw, tags: ["quoted"])
        try collection.memes.addRelation(Relation(from: id, to: quotedMeme, kind: .quote))
        return quotedMeme
    }

    /// How many chain/quote links are still unresolved for this tweet (for the UI to show buttons).
    public func pending(for id: MemeID) throws -> (replyParent: Bool, quoted: Bool) {
        guard let p = try payload(id) else { return (false, false) }
        let rels = try collection.memes.relations(of: id)
        let hasParent = (p.replyToTweetID != nil) && !rels.contains { $0.from == id && $0.kind == .replyTo }
        let hasQuote = (p.quotedTweetID != nil) && !rels.contains { $0.from == id && $0.kind == .quote }
        return (hasParent, hasQuote)
    }
}
