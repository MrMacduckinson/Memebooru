import Foundation
import Testing
@testable import MemebooruCore

/// A small conversation: `r` replies to `p1`, which replies to `p2` (the thread's start); `r` quotes `q`
/// (carried in `r`'s response) and `p1` quotes `q2` (fetched). `gone` can't be fetched.
private struct Conversation: TweetSource, HTTPClient {
    final class Log: @unchecked Sendable {
        private let lock = NSLock(); private var all: [String] = []
        var fetched: [String] { lock.withLock { all } }
        func add(_ id: String) { lock.withLock { all.append(id) } }
    }
    let log = Log()

    static func tweet(_ id: String, replyTo: String? = nil, quote: String? = nil, embedQuote: Bool = false, media: Int = 0) -> FetchedTweet {
        FetchedTweet(id: id, url: "https://x.com/u/status/\(id)", text: "tweet \(id)", authorName: "U", handle: "u",
                     replyToHandle: replyTo == nil ? nil : "u", replyToTweetID: replyTo, quotedTweetID: quote,
                     media: (0..<media).map { .init(kind: .photo, url: "https://pbs.twimg.com/\(id)-\($0).jpg") },
                     quoted: embedQuote && quote != nil ? [tweet(quote!)] : [])
    }
    static let root = tweet("r", replyTo: "p1", quote: "q", embedQuote: true, media: 1)

    func fetch(tweetID id: String) async throws -> FetchedTweet {
        log.add(id)
        switch id {
        case "p1": return Self.tweet("p1", replyTo: "p2", quote: "q2")
        case "p2": return Self.tweet("p2", media: 2)
        case "q", "q2": return Self.tweet(id)
        default: throw CollectionError("not found")
        }
    }
    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        HTTPResponse(status: 200, headers: [:], body: Data("bytes-\(url.lastPathComponent)".utf8))
    }
}

@Suite struct TweetChainTests {
    @Test func collectsParentsUpTheThreadAndQuotesOnce() async {
        let src = Conversation()
        let known = KnownTweets()
        let (links, missing) = await TweetChainLoader(source: src).collect(for: Conversation.root, known: known)
        #expect(Set(links.map(\.tweet.id)) == ["q", "p1", "q2", "p2"] && missing == 0)
        #expect(!src.log.fetched.contains("q"))                       // carried in the response, not fetched
        #expect(links.first { $0.tweet.id == "p2" }?.role == .parent && links.first { $0.tweet.id == "q2" }?.role == .quote)
        // Everything is known now: a second tweet in the same thread fetches nothing.
        let again = await TweetChainLoader(source: src).collect(for: Conversation.tweet("r2", replyTo: "p1"), known: known)
        #expect(again.links.isEmpty)
        // A deleted parent ends the branch.
        let lost = await TweetChainLoader(source: src).collect(for: Conversation.tweet("x", replyTo: "gone"), known: KnownTweets())
        #expect(lost.links.isEmpty && lost.missing == 1)
    }

    @Test func chainRidesAlongInStagingAndIsLinkedOnCommit() async throws {
        let t = try TempCollection()
        let c = t.collection
        let src = Conversation()
        let importer = TweetImporter(staging: c.staging, source: src, http: src, archive: false)
        let item = try await importer.stage(Conversation.root)
        let r = await c.staging.stageChain(of: Conversation.root, under: item.id, loader: TweetChainLoader(source: src),
                                           importer: importer, known: KnownTweets([Conversation.root.id]))
        #expect(r.staged == 4)
        #expect(try c.staging.list().map(\.id) == [item.id])           // only the tweet itself is up for review
        #expect(try c.staging.count() == 1 && c.staging.chain(of: item.id).count == 4)
        let p2 = try #require(try c.staging.chain(of: item.id).first { $0.payloadTweetID == "p2" })
        #expect(c.staging.extras(p2).filter { $0.role == .media }.count == 2)
        #expect(p2.suggestedTags.contains("chain") && p2.suggestedTags.contains("thread") && !p2.suggestedTags.contains("tweet"))

        let meme = try c.staging.commit(item.id)
        #expect(try c.staging.count() == 0 && c.staging.chain(of: item.id).isEmpty)
        #expect(try c.memes.count() == 5)
        let id = { (tweet: String) in try #require(try c.memes.memeForTweet(tweet)) }
        let rels = try c.memes.relations(of: meme.id)
        #expect(rels.contains { $0.kind == .replyTo && $0.to == (try? id("p1")) })
        #expect(rels.contains { $0.kind == .quote && $0.to == (try? id("q")) })
        #expect(try c.memes.relations(of: id("p1")).contains { $0.kind == .replyTo && $0.from == (try? id("p1")) && $0.to == (try? id("p2")) })
        #expect(try c.memes.relations(of: id("p1")).contains { $0.kind == .quote && $0.to == (try? id("q2")) })
        #expect(try c.wayback.pendingCount() == 1)                      // only the meme itself is archived

        // Posts: the meme only; asking for the thread finds the chain.
        #expect(try c.search.search("").memes.map(\.id) == [meme.id])
        #expect(try c.search.search("tweet").memes.map(\.id) == [meme.id])
        #expect(try c.search.search("thread").memes.count == 2)
        #expect(try c.search.search("chain").memes.count == 4)
    }

    @Test func discardTakesTheChainAlong() async throws {
        let t = try TempCollection()
        let c = t.collection
        let src = Conversation()
        let importer = TweetImporter(staging: c.staging, source: src, http: src, archive: false)
        let item = try await importer.stage(Conversation.root)
        _ = await c.staging.stageChain(of: Conversation.root, under: item.id, loader: TweetChainLoader(source: src),
                                       importer: importer, known: KnownTweets([Conversation.root.id]))
        try c.discardStaged([item])
        #expect(try c.db.scalarInt("SELECT count(*) FROM staged") == 0)
        _ = try c.undoLast()
        #expect(try c.staging.count() == 1 && c.staging.chain(of: item.id).count == 4)   // undo brings them all back
    }

    @Test func likedChainTweetBecomesAPost() async throws {
        let t = try TempCollection()
        let c = t.collection
        let src = Conversation()
        let importer = TweetImporter(staging: c.staging, source: src, http: src)
        _ = try importer.commitPrepared(try await importer.prepare(Conversation.tweet("p2")), into: c, asChain: true)
        #expect(try c.search.search("").memes.isEmpty)
        #expect(try c.promoteChainTweet("p2", tags: ["liked"]))
        let names = try c.memes.tags(of: try #require(try c.memes.memeForTweet("p2"))).map(\.name)
        #expect(names.contains("liked") && names.contains("tweet") && !names.contains("chain"))
        #expect(try c.search.search("").memes.count == 1)
    }

    @Test func restageMovesTweetsBackWithFilesAndTags() async throws {
        let t = try TempCollection()
        let c = t.collection
        let src = Conversation()
        let importer = TweetImporter(staging: c.staging, source: src, http: src)
        let meme = try importer.commitPrepared(try await importer.prepare(Conversation.tweet("m", media: 2)), into: c, extraTags: ["liked"])
        let mediaBefore = try c.memes.assets(of: meme.id).filter { $0.role == .media }.map(\.sha256).sorted()

        let staged = try c.restageTweets([meme.id], into: c.staging)
        #expect(staged.count == 1)
        #expect(try c.memes.get(meme.id)?.deletedAt != nil)
        let item = try #require(try c.staging.list().first)
        #expect(item.userTags == ["liked"] && item.suggestedTags.contains("tweet") && item.suggestedTags.contains("@u"))
        #expect(c.staging.extras(item).filter { $0.role == .media }.count == 2)
        // Back in: same files, same tags.
        let again = try c.staging.commit(item.id)
        #expect(try c.memes.assets(of: again.id).filter { $0.role == .media }.map(\.sha256).sorted() == mediaBefore)
        #expect(try c.memes.tags(of: again.id).map(\.name).contains("liked"))
        _ = try c.undo.lastUndoable()
    }

    @Test func mediaOnlyTweetsShowAsMediaUnlessChosenOtherwise() {
        var p = TweetPayload(tweetID: "1", url: "u", authorName: "A", handle: "a")
        #expect(p.showsAsMedia(text: nil, mediaCount: 1))
        #expect(!p.showsAsMedia(text: "words", mediaCount: 1))
        #expect(!p.showsAsMedia(text: "  ", mediaCount: 0))                  // nothing to show but the card
        p.replyToTweetID = "0"
        #expect(!p.showsAsMedia(text: nil, mediaCount: 1))                   // a reply needs its context
        p.display = .media
        #expect(p.showsAsMedia(text: "words", mediaCount: 2))
        p.display = .card
        p.replyToTweetID = nil
        #expect(!p.showsAsMedia(text: nil, mediaCount: 1))
    }

    @Test func replyMentionsAreHiddenAsOnX() throws {
        let json: [String: Any] = ["rest_id": "1", "legacy": ["full_text": "@a @b Привет 👋 мир", "display_text_range": [6, 18],
                                                             "created_at": "Wed Oct 05 20:00:00 +0000 2022"]]
        let tw = try #require(FetchedTweet.parse(raw: try JSONSerialization.data(withJSONObject: json)))
        #expect(tw.text == "Привет 👋 мир")
    }

    @Test func textIsCleanedOfEntitiesAndTheQuoteLink() throws {
        let json: [String: Any] = [
            "rest_id": "1",
            "legacy": ["full_text": "white &amp; went &lt;3 https://t.co/abc", "created_at": "Wed Oct 05 20:00:00 +0000 2022",
                       "quoted_status_id_str": "2",
                       "entities": ["urls": [["url": "https://t.co/abc", "display_url": "x.com/a/status/2", "expanded_url": "https://x.com/a/status/2"]]],
                       "quoted_status_permalink": ["url": "https://t.co/abc", "display": "x.com/a/status/2", "expanded": "https://x.com/a/status/2"]],
            "quoted_status_result": ["result": ["rest_id": "2", "legacy": ["full_text": "the quote", "created_at": "Wed Oct 05 20:00:00 +0000 2022"]]],
        ]
        let tw = try #require(FetchedTweet.parse(raw: try JSONSerialization.data(withJSONObject: json)))
        #expect(tw.text == "white & went <3")
        #expect(tw.quoted.first?.id == "2" && tw.quoted.first?.text == "the quote")
    }
}
