import Foundation

/// Tweet ids already taken care of (in the collection, staged, or claimed by a chain being fetched),
/// shared by concurrent imports so no tweet is fetched or staged twice.
public final class KnownTweets: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<String>
    public init(_ ids: Set<String> = []) { self.ids = ids }
    public func contains(_ id: String) -> Bool { lock.withLock { ids.contains(id) } }
    /// True when `id` wasn't known yet (and now is).
    public func claim(_ id: String) -> Bool { lock.withLock { ids.insert(id).inserted } }
}

/// What a tweet needs around it to make sense as a meme: the tweets it replies to, up the thread to
/// where it starts, and the tweets it (or any of those) quotes — one level, as x.com shows them.
/// Other people's replies under it are not part of it.
public struct TweetChainLoader: Sendable {
    public enum Role: Sendable { case parent, quote }
    public struct Link: Sendable { public let tweet: FetchedTweet; public let role: Role }

    public let source: any TweetSource
    public var maxDepth = 40
    public init(source: any TweetSource) { self.source = source }

    /// The chain tweets of `root` that aren't `known` yet (they become known). Quotes come from the
    /// response when it carried them; parents are fetched. A tweet that can't be fetched (deleted,
    /// protected, suspended) ends its branch and is counted in `missing`.
    public func collect(for root: FetchedTweet, known: KnownTweets) async -> (links: [Link], missing: Int) {
        var links: [Link] = []
        var missing = 0
        var current: FetchedTweet? = root
        var depth = 0
        while let t = current {
            current = nil
            if let qid = t.quotedTweetID, known.claim(qid) {
                var q = t.quoted.first { $0.id == qid }
                if q == nil { q = try? await source.fetch(tweetID: qid) }
                if let q { links.append(Link(tweet: q, role: .quote)) } else { missing += 1 }
            }
            if let pid = t.replyToTweetID, depth < maxDepth, known.claim(pid) {
                if let parent = try? await source.fetch(tweetID: pid) {
                    links.append(Link(tweet: parent, role: .parent))
                    current = parent; depth += 1
                } else { missing += 1 }
            }
        }
        return (links, missing)
    }
}

extension Collection {
    /// Tweet ids of every live tweet meme.
    public func tweetIDs() throws -> Set<String> {
        let rows = try db.query("SELECT payload FROM meme WHERE kind = 'tweet' AND deleted_at IS NULL", []) { $0.optString(0) }
        return Set(rows.compactMap { json in
            guard case .tweet(let p)? = try? MemePayload.decode(kind: .tweet, json: json) else { return nil }
            return p.tweetID
        })
    }

    /// A tweet that was only kept as part of a chain becomes a post of its own (it was liked itself):
    /// the chain tag goes, `tags` and the usual tweet/year tags come. False if there's no such tweet.
    @discardableResult
    public func promoteChainTweet(_ tweetID: String, tags: [String]) throws -> Bool {
        guard let id = try memes.memeForTweet(tweetID), let meme = try memes.get(id),
              try memes.tags(of: id).contains(where: { $0.name == Self.chainTag }) else { return false }
        try memes.removeTag(id, Self.chainTag)
        let year = Calendar(identifier: .gregorian).component(.year, from: Date(timeIntervalSince1970: Double(meme.createdAt) / 1000))
        for t in ["tweet", String(year)] { _ = try memes.addTag(id, t, kind: .meta) }
        for t in tags { _ = try memes.addTag(id, t) }
        return true
    }
}

extension StagingArea {
    /// A chain tweet staged under another tweet becomes an item of its own (it was liked itself).
    @discardableResult
    public func promoteChainItem(_ tweetID: String, tags: [String]) throws -> Bool {
        guard let item = try db.query("SELECT * FROM staged WHERE kind = 'tweet' AND parent_id IS NOT NULL AND payload LIKE ?",
                                      ["%\"tweetID\":\"" + tweetID + "\"%"], StagingArea.row).first else { return false }
        var promoted = item
        promoted.parentID = nil
        promoted.suggestedTags = promoted.suggestedTags.filter { $0 != Collection.chainTag } + ["tweet"]
        promoted.userTags = Array(Set(promoted.userTags + tags)).sorted()
        try update(promoted)
        try db.run("UPDATE staged SET parent_id = NULL WHERE id = ?", [item.id])
        return true
    }

    /// Stages `root`'s chain under the staged item `parentID`, downloading their media.
    /// Returns (staged, missing).
    public func stageChain(of root: FetchedTweet, under parentID: String, loader: TweetChainLoader,
                           importer: TweetImporter, known: KnownTweets) async -> (staged: Int, missing: Int) {
        let (links, missing) = await loader.collect(for: root, known: known)
        var staged = 0
        for l in links {
            let tags = [Collection.chainTag, l.role == .parent ? "thread" : "quoted"]
            if (try? await importer.stage(l.tweet, parentID: parentID, extraTags: tags)) != nil { staged += 1 }
        }
        return (staged, missing)
    }
}
