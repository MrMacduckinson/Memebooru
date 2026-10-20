import Foundation
import Testing
@testable import MemebooruCore

@Suite struct XSourceTests {
    @Test func parsesCookies() {
        let s = XSession.fromCookieHeader("guest_id=v1; auth_token=AAA; ct0=BBB; twid=u%3D12345")
        #expect(s?.authToken == "AAA" && s?.csrf == "BBB" && s?.userID == "12345")
        #expect(XSession.fromCookieHeader("ct0=BBB") == nil)      // no auth_token
        #expect(XSession.from(cookies: ["auth_token": "A", "ct0": "C"])?.userID == nil)
    }

    final class FakeX: HTTPClient, @unchecked Sendable {
        var pages = 0
        func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
            let s = url.absoluteString
            func json(_ obj: [String: Any]) -> HTTPResponse {
                HTTPResponse(status: 200, headers: [:], body: try! JSONSerialization.data(withJSONObject: ["data": obj]))
            }
            if s.contains("/Likes?") {
                pages += 1
                // first page has 2 tweets + cursor "P2"; second page is empty + no cursor → stops
                return pages == 1
                    ? json(XSourceTestsTimeline.likes(next: "P2"))
                    : json(["user": ["result": ["timeline_v2": ["timeline": ["instructions": [["type": "TimelineAddEntries", "entries": []]]]]]]])
            }
            if s.contains("account/settings.json") { return HTTPResponse(status: 200, headers: [:], body: Data(#"{"screen_name":"me"}"#.utf8)) }
            if s.contains("wayback/available") { return HTTPResponse(status: 200, headers: [:], body: Data(#"{"archived_snapshots":{}}"#.utf8)) }
            if s.contains("web.archive.org/save/") { return HTTPResponse(status: 200, headers: ["content-location": "/web/1/x"], body: Data()) }
            return HTTPResponse(status: 200, headers: [:], body: Data("bytes-\(url.lastPathComponent)".utf8))   // media
        }
    }

    @Test func importsLikesWithMediaAndDedup() async throws {
        let t = try TempCollection()
        let staging = StagingArea(collection: t.collection, analyzer: nil)
        let http = FakeX()
        let session = XSession(authToken: "A", csrf: "C", userID: "999")
        let client = XClient(http: http, session: session)
        var importer = XImporter(staging: staging, client: client, http: http)

        let p = try await importer.importFeed(.likes, limit: 100, extraTags: ["liked"], commitDirectly: false, sleep: { _ in })
        #expect(p.staged == 2 && p.skipped == 0)
        let items = try staging.list()
        #expect(items.count == 2)
        let alice = items.first { ($0.originalName ?? "").contains("111") }!
        #expect(alice.kind == .tweet)
        guard case .tweet(let payload) = alice.payload else { Issue.record("no payload"); return }
        #expect(payload.handle == "alice")
        #expect(payload.waybackURL == nil)   // bulk import skips Wayback for speed
        #expect(alice.userTags.contains("liked") && alice.suggestedTags.contains("@alice"))
        // photo tweet has a media asset staged; video tweet picked the higher-bitrate mp4
        #expect(staging.extras(alice).contains { $0.role == .media })

        // commit both, re-import → both skipped (already in the collection)
        for i in try staging.list() { _ = try staging.commit(i.id) }
        http.pages = 0
        let p2 = try await importer.importFeed(.likes, limit: 100, commitDirectly: false, sleep: { _ in })
        #expect(p2.staged == 0 && p2.skipped == 2)
    }

    @Test func directCommitLandsInCollectionNotStaging() async throws {
        let t = try TempCollection()
        let c = t.collection
        let staging = c.staging
        let http = FakeX()
        var importer = XImporter(staging: staging, client: XClient(http: http, session: XSession(authToken: "A", csrf: "C", userID: "9")), http: http)
        let p = try await importer.importFeed(.likes, limit: 100, extraTags: ["liked"], commitDirectly: true, sleep: { _ in })
        #expect(p.staged == 2)
        #expect(try c.staging.count() == 0)                 // no staging churn left behind
        #expect(try c.memes.count() == 2)                   // straight into the collection
        let tweets = try c.search.search("tweet").memes
        #expect(tweets.count == 2 && tweets.allSatisfy { $0.kind == .tweet })
        let alice = tweets.first { if case .tweet(let pl) = $0.payload { return pl.handle == "alice" } else { return false } }!
        #expect(try c.memes.assets(of: alice.id).contains { $0.role == .media })
        #expect(try c.memes.tags(of: alice.id).map(\.name).contains("liked"))
        #expect(try c.wayback.pendingCount() == 2)          // wayback queued in background
        // undoable
        let ids = tweets.map(\.id)
        _ = try c.deleteMemes(ids)
        #expect(try c.memes.count() == 0)
        _ = try c.undoLast()
        #expect(try c.memes.count() == 2)
    }

    @Test func timelineParserExtractsCursorAndVideoVariant() {
        let root = XSourceTestsTimeline.likes(next: "NEXT")
        let tl = (((root["user"] as! [String: Any])["result"] as! [String: Any])["timeline_v2"] as! [String: Any])["timeline"] as! [String: Any]
        let page = XTimelineParser.parse(instructions: tl["instructions"] as! [[String: Any]])
        #expect(page.cursor == "NEXT")
        #expect(page.tweets.map(\.id) == ["111", "222"])
        let video = page.tweets[1]
        #expect(video.media.first?.kind == .video && video.media.first?.url == "https://video.twimg.com/hi.mp4")
    }
}

/// Shared timeline fixture.
enum XSourceTestsTimeline {
    static func likes(next: String) -> [String: Any] {
        func tweetEntry(_ id: String, handle: String, name: String, text: String, media: [[String: Any]]) -> [String: Any] {
            ["entryId": "tweet-\(id)", "content": ["itemContent": ["tweet_results": ["result": [
                "__typename": "Tweet", "rest_id": id,
                "core": ["user_results": ["result": ["legacy": [
                    "screen_name": handle, "name": name, "profile_image_url_https": "https://pbs.twimg.com/\(handle).jpg"]]]],
                "legacy": ["full_text": text, "created_at": "Wed Oct 05 20:00:00 +0000 2022",
                           "extended_entities": ["media": media]]]]]]]
        }
        let photo = tweetEntry("111", handle: "alice", name: "Alice", text: "hello photo",
                               media: [["type": "photo", "media_url_https": "https://pbs.twimg.com/media/p.jpg", "original_info": ["width": 1200, "height": 800]]])
        let video = tweetEntry("222", handle: "bob", name: "Bob", text: "hello video",
                               media: [["type": "video", "media_url_https": "https://pbs.twimg.com/thumb.jpg",
                                        "video_info": ["variants": [
                                            ["content_type": "video/mp4", "bitrate": 256000, "url": "https://video.twimg.com/lo.mp4"],
                                            ["content_type": "video/mp4", "bitrate": 832000, "url": "https://video.twimg.com/hi.mp4"]]]]])
        let cursor: [String: Any] = ["entryId": "cursor-bottom-0", "content": ["cursorType": "Bottom", "value": next]]
        return ["user": ["result": ["timeline_v2": ["timeline": ["instructions": [["type": "TimelineAddEntries", "entries": [photo, video, cursor]]]]]]]]
    }
}

@Suite struct XDiscoveryTests {
    @Test func extractsQueryIDsFromBundleText() {
        let js = """
        ...,{queryId:"aBcDeFgHiJkLmNoPqRsT01",operationName:"Likes",operationType:"query"},...
        e.exports={operationName:"Bookmarks",queryId:"ZyXwVuTsRqPoNmLkJiHg23"};
        var u={"UserByScreenName","queryId":"1VOOyvKkiI3FMmkeDNxM9A"};
        """
        #expect(XTimelineParser_queryID("Likes", js) == "aBcDeFgHiJkLmNoPqRsT01")
        #expect(XTimelineParser_queryID("Bookmarks", js) == "ZyXwVuTsRqPoNmLkJiHg23")
        #expect(XTimelineParser_queryID("UserByScreenName", js) == "1VOOyvKkiI3FMmkeDNxM9A")
        #expect(XTimelineParser_queryID("Retweets", js) == nil)
    }

    @Test func findsBundleURLsInHTML() {
        let html = #"<link href="https://abs.twimg.com/responsive-web/client-web/main.abc123.js"/><script src="https://abs.twimg.com/responsive-web/client-web/api.def456.js"></script><img src="https://x.com/a.png">"#
        let urls = XClient_bundleURLs(html)
        #expect(urls.count == 2)
        #expect(urls.contains { $0.hasSuffix("main.abc123.js") } && urls.contains { $0.hasSuffix("api.def456.js") })
    }

    @Test func overrideApplies() {
        var e = XEndpoints.standard()
        e.apply(XEndpointOverride(likes: "NEWLIKES", bookmarks: nil))
        #expect(e.likes == "NEWLIKES")
        #expect(!e.bookmarks.isEmpty)   // untouched
    }
}

// Bridges to the internal static helpers.
func XTimelineParser_queryID(_ op: String, _ js: String) -> String? { XClient.queryID(operation: op, in: js) }
func XClient_bundleURLs(_ html: String) -> [String] { XClient.bundleURLs(in: html) }

@Suite struct TweetThreadTests {
    /// Source returning a 3-tweet reply chain (c → b → a) where b also quotes q.
    struct ChainSource: TweetSource {
        func fetch(tweetID id: String) async throws -> FetchedTweet {
            func t(_ id: String, text: String, reply: String? = nil, quote: String? = nil) -> FetchedTweet {
                FetchedTweet(id: id, url: "https://x.com/u/status/\(id)", text: text, authorName: "U", handle: "u",
                             replyToHandle: reply != nil ? "u" : nil, replyToTweetID: reply, quotedTweetID: quote, media: [], raw: Data("{}".utf8))
            }
            switch id {
            case "a": return t("a", text: "root")
            case "b": return t("b", text: "middle", reply: "a", quote: "q")
            case "q": return t("q", text: "quoted")
            default: return t(id, text: id)
            }
        }
    }

    @Test func loadsReplyChainAndQuote() async throws {
        let tc = try TempCollection()
        let c = tc.collection
        let http = XSourceTests.FakeX()   // serves media/wayback dummies
        let importer = TweetImporter(staging: c.staging, source: ChainSource(), http: http)
        let loader = TweetThreadLoader(collection: c, importer: importer)

        // start with tweet c (reply to b)
        let cTweet = FetchedTweet(id: "c", url: "https://x.com/u/status/c", text: "leaf", authorName: "U", handle: "u",
                                  replyToHandle: "u", replyToTweetID: "b", quotedTweetID: nil, media: [], raw: Data("{}".utf8))
        let prepared = try await importer.prepare(cTweet)
        let leaf = try importer.commitPrepared(prepared, into: c)

        #expect(try loader.pending(for: leaf.id).replyParent == true)
        let chain = try await loader.loadReplyChain(of: leaf.id)
        #expect(chain.count == 2)                                   // b, then a
        // relations: c→b, b→a
        let hasB = try c.memes.memeForTweet("b") != nil, hasA = try c.memes.memeForTweet("a") != nil
        #expect(hasB && hasA)
        let bID = try c.memes.memeForTweet("b")!
        #expect(try loader.pending(for: leaf.id).replyParent == false)   // parent now linked
        // b quotes q → load it
        #expect(try loader.pending(for: bID).quoted == true)
        let q = try await loader.loadQuoted(of: bID)
        let qm = try c.memes.memeForTweet("q")
        #expect(q != nil && qm == q)
        let rels = try c.memes.relations(of: bID)
        #expect(rels.contains { $0.kind == .quote } && rels.contains { $0.kind == .replyTo })
        // idempotent: loading again doesn't duplicate
        _ = try await loader.loadReplyChain(of: leaf.id)
        #expect(try c.memes.count() == 4)                           // c, b, a, q
    }
}

/// A likes feed of fixed pages (`P0`, `P1`, … cursors); can answer 429 on chosen requests.
final class PagedX: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    var pages: [[String]]
    var rateLimitOn: Set<Int> = []          // 1-based Likes request numbers that get a 429
    var resetIn: TimeInterval? = 100
    private(set) var likeRequests = 0
    init(_ pages: [[String]]) { self.pages = pages }

    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        let s = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        if s.contains("/Likes?") {
            let n = lock.withLock { likeRequests += 1; return likeRequests }
            if rateLimitOn.contains(n) {
                let reset = resetIn.map { ["x-rate-limit-reset": String(Int(Date().timeIntervalSince1970 + $0))] } ?? [:]
                return HTTPResponse(status: 429, headers: reset, body: Data("Rate limit exceeded".utf8))
            }
            var index = 0
            if let r = s.range(of: #""cursor":"P(\d+)""#, options: .regularExpression) {
                index = Int(s[r].filter(\.isNumber)) ?? 0
            }
            let ids = index < pages.count ? pages[index] : []
            var entries: [[String: Any]] = ids.map { id in
                ["entryId": "tweet-\(id)", "content": ["itemContent": ["tweet_results": ["result": [
                    "__typename": "Tweet", "rest_id": id,
                    "core": ["user_results": ["result": ["legacy": ["screen_name": "u", "name": "U"]]]],
                    "legacy": ["full_text": "tweet \(id)", "created_at": "Wed Oct 05 20:00:00 +0000 2022"]]]]]]
            }
            if index < pages.count { entries.append(["entryId": "cursor-bottom-0", "content": ["cursorType": "Bottom", "value": "P\(index + 1)"]]) }
            let body: [String: Any] = ["data": ["user": ["result": ["timeline_v2": ["timeline": ["instructions": [["type": "TimelineAddEntries", "entries": entries]]]]]]]]
            return HTTPResponse(status: 200, headers: [:], body: try JSONSerialization.data(withJSONObject: body))
        }
        return HTTPResponse(status: 200, headers: [:], body: Data("bytes".utf8))
    }
}

final class Sleeps: @unchecked Sendable {
    private let lock = NSLock(); private var all: [Duration] = []
    var list: [Duration] { lock.withLock { all } }
    var record: @Sendable (Duration) async throws -> Void { { d in self.lock.withLock { self.all.append(d) } } }
}

@Suite struct XPacingTests {
    private func importer(_ c: Collection, _ http: PagedX) -> XImporter {
        XImporter(staging: c.staging, client: XClient(http: http, session: XSession(authToken: "A", csrf: "C", userID: "9")), http: http)
    }

    @Test func pagesArePacedAndA429IsWaitedOut() async throws {
        let t = try TempCollection()
        let http = PagedX([["1", "2"], ["3", "4"], ["5", "6"]])
        http.rateLimitOn = [2]
        let sleeps = Sleeps()
        let waited = Sleeps()
        var x = importer(t.collection, http)
        let p = try await x.importFeed(.likes, sleep: sleeps.record, onProgress: { pr in
            if pr.waitingUntil != nil { Task { try await waited.record(.zero) } }
        })
        #expect(p.staged == 6)
        let seconds = sleeps.list.map { Double($0.components.seconds) }
        #expect(seconds.contains { $0 >= 100 })                         // waited until x-rate-limit-reset
        #expect(seconds.filter { $0 >= 2 && $0 < 4 }.count >= 2)        // ~2 s (+ jitter) between pages
        try await Task.sleep(for: .milliseconds(50))
        #expect(!waited.list.isEmpty)                                    // progress said it was waiting
    }

    @Test func tooMany429sStopWithTheCheckpointKept() async throws {
        let t = try TempCollection()
        let http = PagedX([["1", "2"], ["3", "4"]])
        http.rateLimitOn = Set(2...20)
        var pace = XImporter.Pace(); pace.maxRateLimitWaits = 2
        var x = importer(t.collection, http)
        await #expect(throws: XRateLimited.self) { try await x.importFeed(.likes, pace: pace, sleep: { _ in }) }
        #expect(try t.collection.staging.count() == 2)
        #expect(try t.collection.xCursor("likes") == "P1")              // a later run resumes at page 2
    }

    @Test func updateRunsStopAtKnownPagesOnlyAfterAFullWalk() async throws {
        let t = try TempCollection()
        let c = t.collection
        let http = PagedX([["1", "2"], ["3", "4"], ["5", "6"], ["7", "8"]])
        var x = importer(c, http)

        // Only the newest two first (like the app's old 100-limit) — history not complete.
        _ = try await x.importFeed(.likes, limit: 2, sleep: { _ in })
        // Full run: page 1 is known but there's no full walk yet, so it keeps going to the end.
        let full = try await x.importFeed(.likes, sleep: { _ in })
        #expect(full.staged == 6 && !full.caughtUp)
        #expect(try c.staging.count() == 8 && c.xCursor("likes-complete") == "1")

        // New likes on top: an update run takes them and stops after two known pages.
        http.pages.insert(["9", "10"], at: 0)
        let before = http.likeRequests
        let update = try await x.importFeed(.likes, sleep: { _ in })
        #expect(update.staged == 2 && update.caughtUp)
        #expect(http.likeRequests - before == 3)                        // new page + 2 known, not all 5
        #expect(try c.xCursor("likes") == nil)                          // next update starts from the top
    }
}
