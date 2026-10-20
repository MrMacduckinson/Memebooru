import Foundation
import Testing
@testable import MemebooruCore

/// A tweet graph by id: `replies[id]` is what it replies to, `quotes[id]` what it quotes. Ids in
/// `missing` can't be fetched. Counts every fetch; yields between steps so concurrent loaders interleave.
private final class Graph: TweetSource, HTTPClient, @unchecked Sendable {
    let replies: [String: String]
    let quotes: [String: String]
    let embedded: Set<String>
    let missing: Set<String>
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    init(replies: [String: String] = [:], quotes: [String: String] = [:], embedded: Set<String> = [], missing: Set<String> = []) {
        self.replies = replies; self.quotes = quotes; self.embedded = embedded; self.missing = missing
    }

    func fetches(_ id: String) -> Int { lock.withLock { counts[id] ?? 0 } }
    var totalFetches: Int { lock.withLock { counts.values.reduce(0, +) } }

    /// `id` as its own response would carry it (quote embedded when the id is in `embedded`).
    func tweet(_ id: String) -> FetchedTweet {
        let q = quotes[id]
        return FetchedTweet(id: id, url: "https://x.com/u/status/\(id)", text: "tweet \(id)", authorName: "U", handle: "u",
                            replyToHandle: replies[id] == nil ? nil : "u", replyToTweetID: replies[id], quotedTweetID: q,
                            quoted: q.flatMap { embedded.contains(id) ? [tweet($0)] : nil } ?? [])
    }

    func fetch(tweetID id: String) async throws -> FetchedTweet {
        lock.withLock { counts[id, default: 0] += 1 }
        for _ in 0..<3 { await Task.yield() }
        if missing.contains(id) { throw CollectionError("gone") }
        return tweet(id)
    }

    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        HTTPResponse(status: 200, headers: [:], body: Data("bytes".utf8))
    }
}

@Suite struct TweetChainEdgeTests {
    @Test func aReplyCycleTerminates() async {
        // a → b → a (impossible on x.com, possible with stale or hostile data)
        let g = Graph(replies: ["a": "b", "b": "a"])
        let r = await TweetChainLoader(source: g).collect(for: g.tweet("a"), known: KnownTweets(["a"]))
        #expect(r.links.map(\.tweet.id) == ["b"] && r.missing == 0)
        #expect(g.totalFetches == 1)
        // Even when the caller forgot to mark the root known, it stops.
        let g2 = Graph(replies: ["a": "b", "b": "a"])
        let r2 = await TweetChainLoader(source: g2).collect(for: g2.tweet("a"), known: KnownTweets())
        #expect(r2.links.map(\.tweet.id) == ["b", "a"] && g2.totalFetches == 2)
    }

    @Test func aSelfReplyAndAQuoteCycleTerminate() async {
        let selfReply = Graph(replies: ["a": "a"])
        #expect(await TweetChainLoader(source: selfReply).collect(for: selfReply.tweet("a"), known: KnownTweets(["a"])).links.isEmpty)
        // a quotes b, b replies to a: the quote isn't followed, so nothing loops.
        let g = Graph(replies: ["b": "a"], quotes: ["a": "b"])
        let r = await TweetChainLoader(source: g).collect(for: g.tweet("a"), known: KnownTweets(["a"]))
        #expect(r.links.map(\.tweet.id) == ["b"] && r.links.first?.role == .quote)
    }

    @Test func veryDeepThreadsAreCapped() async {
        var replies: [String: String] = [:]
        for i in 1...200 { replies["t\(i)"] = "t\(i + 1)" }
        let g = Graph(replies: replies)
        let r = await TweetChainLoader(source: g).collect(for: g.tweet("t1"), known: KnownTweets(["t1"]))
        #expect(r.links.count == 40 && r.links.allSatisfy { $0.role == .parent })
        #expect(r.links.first?.tweet.id == "t2" && r.links.last?.tweet.id == "t41")
        #expect(g.totalFetches == 40 && r.missing == 0)

        var shallow = TweetChainLoader(source: g)
        shallow.maxDepth = 3
        #expect(await shallow.collect(for: g.tweet("t100"), known: KnownTweets(["t100"])).links.map(\.tweet.id) == ["t101", "t102", "t103"])
        shallow.maxDepth = 0
        #expect(await shallow.collect(for: g.tweet("t150"), known: KnownTweets()).links.isEmpty)
    }

    @Test func quotesAreOneLevelDeep() async {
        // r quotes q1, which quotes q2 and replies to p: only q1 belongs to r's chain.
        let g = Graph(replies: ["q1": "p"], quotes: ["r": "q1", "q1": "q2"])
        let r = await TweetChainLoader(source: g).collect(for: g.tweet("r"), known: KnownTweets(["r"]))
        #expect(r.links.map(\.tweet.id) == ["q1"] && r.links.first?.role == .quote)
        #expect(g.fetches("q2") == 0 && g.fetches("p") == 0)
    }

    @Test func eachParentsQuoteIsCollected() async {
        // r → p1 → p2, p1 quotes q (fetched), r quotes rq (embedded in r's response).
        let g = Graph(replies: ["r": "p1", "p1": "p2"], quotes: ["r": "rq", "p1": "q"], embedded: ["r"])
        let r = await TweetChainLoader(source: g).collect(for: g.tweet("r"), known: KnownTweets(["r"]))
        #expect(r.links.map(\.tweet.id) == ["rq", "p1", "q", "p2"])
        #expect(r.links.map(\.role) == [.quote, .parent, .quote, .parent])
        #expect(g.fetches("rq") == 0 && g.fetches("q") == 1)
    }

    @Test func missingParentsAndQuotesAreCounted() async {
        let g = Graph(replies: ["r": "p1", "p1": "gone-parent"], quotes: ["r": "gone-quote", "p1": "q"], missing: ["gone-parent", "gone-quote"])
        let r = await TweetChainLoader(source: g).collect(for: g.tweet("r"), known: KnownTweets(["r"]))
        #expect(r.links.map(\.tweet.id) == ["p1", "q"] && r.missing == 2)
        // A missing tweet is claimed: a second loader doesn't try it again.
        let known = KnownTweets(["r"])
        _ = await TweetChainLoader(source: g).collect(for: g.tweet("r"), known: known)
        let again = await TweetChainLoader(source: g).collect(for: g.tweet("r"), known: known)
        #expect(again.links.isEmpty && again.missing == 0)
    }

    @Test func anEmbeddedQuoteWithTheWrongIDIsFetchedInstead() async {
        let g = Graph(quotes: ["r": "q"])
        var root = g.tweet("r")
        root.quoted = [g.tweet("other")]
        let r = await TweetChainLoader(source: g).collect(for: root, known: KnownTweets(["r"]))
        #expect(r.links.map(\.tweet.id) == ["q"] && g.fetches("q") == 1)
    }

    @Test func concurrentLoadersFetchASharedThreadOnce() async {
        // 30 replies to p, which replies to gp, which quotes q.
        var replies = ["p": "gp"]
        for i in 0..<30 { replies["r\(i)"] = "p" }
        let g = Graph(replies: replies, quotes: ["gp": "q"])
        let known = KnownTweets(Set((0..<30).map { "r\($0)" }))
        let loader = TweetChainLoader(source: g)
        let all = await withTaskGroup(of: [String].self) { group in
            for i in 0..<30 { group.addTask { await loader.collect(for: g.tweet("r\(i)"), known: known).links.map(\.tweet.id) } }
            var out: [String] = []
            for await ids in group { out += ids }
            return out
        }
        #expect(all.sorted() == ["gp", "p", "q"])                     // each chain tweet belongs to exactly one loader
        #expect(g.fetches("p") == 1 && g.fetches("gp") == 1 && g.fetches("q") == 1)
    }

    @Test func knownTweetsClaimIsAtomic() async {
        let known = KnownTweets()
        let wins = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<500 { group.addTask { known.claim("same") } }
            var n = 0
            for await w in group where w { n += 1 }
            return n
        }
        #expect(wins == 1 && known.contains("same") && !known.contains("other"))
    }

    @Test func concurrentStageChainsShareTheParent() async throws {
        let t = try TempCollection(), c = t.collection
        let g = Graph(replies: ["a": "p", "b": "p", "p": "gp"])
        let importer = TweetImporter(staging: c.staging, source: g, http: g, archive: false)
        let ia = try await importer.stage(g.tweet("a")), ib = try await importer.stage(g.tweet("b"))
        let known = KnownTweets(["a", "b"])
        let loader = TweetChainLoader(source: g)
        async let ra = c.staging.stageChain(of: g.tweet("a"), under: ia.id, loader: loader, importer: importer, known: known)
        async let rb = c.staging.stageChain(of: g.tweet("b"), under: ib.id, loader: loader, importer: importer, known: known)
        let (x, y) = await (ra, rb)
        #expect(x.staged + y.staged == 2)
        #expect(try c.staging.chain(of: ia.id).count + c.staging.chain(of: ib.id).count == 2)
        #expect(try c.db.scalarInt("SELECT count(*) FROM staged") == 4)
        // Whichever got p, both are linked to it once committed.
        let ma = try c.staging.commit(ia.id), mb = try c.staging.commit(ib.id)
        let p = try #require(try c.memes.memeForTweet("p"))
        #expect(try c.memes.relations(of: ma.id).contains { $0.kind == .replyTo && $0.to == p })
        #expect(try c.memes.relations(of: mb.id).contains { $0.kind == .replyTo && $0.to == p })
        #expect(try c.search.search("").memes.count == 2)
    }

    @Test func loadChainOfASavedTweetSurvivesACycle() async throws {
        let t = try TempCollection(), c = t.collection
        let g = Graph(replies: ["a": "b", "b": "a"])
        let importer = TweetImporter(staging: c.staging, source: g, http: g, archive: false)
        let meme = try importer.commitPrepared(try await importer.prepare(g.tweet("a")), into: c)
        let r = try await TweetThreadLoader(collection: c, importer: importer).loadChain(of: meme.id)
        #expect(try r.saved == 1 && r.missing == 0 && c.memes.count() == 2)
        // Loading again finds everything known.
        let again = try await TweetThreadLoader(collection: c, importer: importer).loadChain(of: meme.id)
        #expect(again.saved == 0 && g.totalFetches == 1)
    }

    @Test func loadReplyChainStopsAtTheDepthLimitOnACycle() async throws {
        let t = try TempCollection(), c = t.collection
        let g = Graph(replies: ["a": "b", "b": "a"])
        let importer = TweetImporter(staging: c.staging, source: g, http: g, archive: false)
        let meme = try importer.commitPrepared(try await importer.prepare(g.tweet("a")), into: c)
        let loaded = try await TweetThreadLoader(collection: c, importer: importer).loadReplyChain(of: meme.id, maxDepth: 5)
        #expect(loaded.count == 5)                          // bounded, and…
        #expect(try c.memes.count() == 2)                   // …no duplicate memes for the same tweets
    }
}

@Suite struct StagedTweetMaintenanceTests {
    /// A staged tweet whose saved JSON is an x.com result (as bulk imports save it).
    private func stage(_ c: Collection, _ result: [String: Any], source: any TweetSource, http: any HTTPClient) async throws -> StagedItem {
        var tw = try XFix.parse(result)
        tw.raw = try JSONSerialization.data(withJSONObject: result)
        return try await TweetImporter(staging: c.staging, source: source, http: http, archive: false).stage(tw)
    }

    @Test func loadChainsFetchesOnlyWhatIsMissing() async throws {
        let t = try TempCollection(), c = t.collection
        let g = Graph(replies: ["p": "gp"], missing: ["gone"])
        let reply = try await stage(c, XFix.tweet("r", text: "reply", legacy: ["in_reply_to_status_id_str": "p"]), source: g, http: g)
        let lone = try await stage(c, XFix.tweet("l", text: "no chain"), source: g, http: g)
        let broken = try await stage(c, XFix.tweet("b", text: "reply to gone", legacy: ["in_reply_to_status_id_str": "gone"]), source: g, http: g)
        let progress = Holder<Int>()
        let r = try await c.staging.loadChains(for: [reply, lone, broken], source: g, http: g, concurrency: 2) { done, _, _ in progress.set(done) }
        #expect(r.chain == 2 && r.missing == 1 && progress.value == 2)       // `lone` isn't even looked at
        #expect(try c.staging.chain(of: reply.id).compactMap(\.payloadTweetID).sorted() == ["gp", "p"])
        #expect(try c.staging.chain(of: lone.id).isEmpty && c.staging.count() == 3)
        // Running again stages nothing twice.
        let again = try await c.staging.loadChains(for: try c.staging.list(), source: g, http: g)
        #expect(again.chain == 0 && g.fetches("p") == 1)
    }

    @Test func reparseRereadsTheSavedJSON() async throws {
        let t = try TempCollection(), c = t.collection
        let g = Graph()
        var item = try await stage(c, XFix.tweet("1", text: "@a Tom &amp; Jerry", legacy: [
            "display_text_range": [3, 14],
            "extended_entities": ["media": [XFix.video([["content_type": "video/mp4", "bitrate": 1, "url": "https://video.twimg.com/g.mp4"]], type: "animated_gif")]]]),
            source: g, http: g)
        #expect(item.textVerbatim == "Tom & Jerry")
        // Pretend it was staged by an older parser.
        item.textVerbatim = "@a Tom &amp; Jerry"
        if case .tweet(var p) = item.payload { p.animatedMedia = nil; item.payload = .tweet(p) }
        try c.staging.update(item)
        #expect(try c.staging.reparseTweets() == 1)
        let fixed = try #require(try c.staging.get(item.id))
        #expect(fixed.textVerbatim == "Tom & Jerry")
        if case .tweet(let p) = fixed.payload { #expect(p.animatedMedia == [0]) } else { Issue.record("payload") }
        #expect(try c.staging.reparseTweets() == 0)                           // idempotent
    }
}
