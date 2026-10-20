import Foundation
import Testing
@testable import MemebooruCore

/// A scripted x.com (plus fxtwitter and the media CDN). Never touches the network.
/// Feed pages are keyed by the cursor they answer ("" = the first page).
final class FakeXServer: HTTPClient, @unchecked Sendable {
    struct Request: @unchecked Sendable {
        let url: URL
        let headers: [String: String]
        var host: String { url.host ?? "" }
        /// GraphQL operation and query id (`/i/api/graphql/<qid>/<op>`).
        var operation: String? { url.path.contains("/graphql/") ? url.lastPathComponent : nil }
        var queryID: String? { url.path.contains("/graphql/") ? url.deletingLastPathComponent().lastPathComponent : nil }
        var variables: [String: Any] {
            let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "variables" }?.value
            return v.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
        }
        var cursor: String? { variables["cursor"] as? String }
    }

    private let lock = NSLock()
    private var log: [Request] = []
    var requests: [Request] { lock.withLock { log } }
    var feedRequests: [Request] { requests.filter { $0.operation == "Likes" || $0.operation == "Bookmarks" } }

    var pages: [String: (tweets: [[String: Any]], next: String?)] = [:]
    /// Answers the nth (1-based) feed request instead of `pages` when it returns non-nil.
    var override: (@Sendable (_ n: Int, _ req: Request) -> HTTPResponse?)?
    /// Bookmarks answer with the old `bookmark_timeline` key / Likes with `timeline` instead of `timeline_v2`.
    var legacyKeys = false
    var fx: [String: [String: Any]] = [:]
    var failingMedia: Set<String> = []
    var serviceWorker: String?
    var homeHTML: String?
    var bundles: [String: String] = [:]
    var screenName: String? = "me"
    var restID = "777"
    private var feedCount = 0

    static func json(_ obj: Any, status: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
        HTTPResponse(status: status, headers: headers, body: try! JSONSerialization.data(withJSONObject: obj))
    }

    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        let req = Request(url: url, headers: headers)
        lock.withLock { log.append(req) }
        let s = url.absoluteString
        switch req.operation {
        case "Likes", "Bookmarks":
            let n = lock.withLock { feedCount += 1; return feedCount }
            if let r = override?(n, req) { return r }
            let page = pages[req.cursor ?? ""] ?? (tweets: [], next: nil)
            let instr = XFix.instructions(page.tweets, cursor: page.next)
            let tl: [String: Any] = ["timeline": ["instructions": instr]]
            if req.operation == "Likes" {
                return Self.json(["data": ["user": ["result": [legacyKeys ? "timeline" : "timeline_v2": tl]]]])
            }
            return Self.json(["data": [legacyKeys ? "bookmark_timeline" : "bookmark_timeline_v2": tl]])
        case "UserByScreenName":
            return Self.json(["data": ["user": ["result": ["rest_id": restID]]]])
        default: break
        }
        if s.hasPrefix("https://api.x.com/1.1/account/settings.json") {
            guard let screenName else { return HTTPResponse(status: 401, headers: [:], body: Data()) }
            return Self.json(["screen_name": screenName])
        }
        if s.hasPrefix("https://api.fxtwitter.com/status/") {
            guard let t = fx[url.lastPathComponent] else { return Self.json(["code": 404, "message": "NOT_FOUND"], status: 404) }
            return Self.json(["code": 200, "tweet": t])
        }
        if s == "https://x.com/responsive-web/client-web/sw.js" {
            return serviceWorker.map { HTTPResponse(status: 200, headers: [:], body: Data($0.utf8)) } ?? HTTPResponse(status: 404, headers: [:], body: Data())
        }
        if s == "https://x.com/home" {
            return homeHTML.map { HTTPResponse(status: 200, headers: [:], body: Data($0.utf8)) } ?? HTTPResponse(status: 404, headers: [:], body: Data())
        }
        if let js = bundles[s] { return HTTPResponse(status: 200, headers: [:], body: Data(js.utf8)) }
        if req.host.hasSuffix("twimg.com") {
            if failingMedia.contains(s) { return HTTPResponse(status: 404, headers: [:], body: Data()) }
            return HTTPResponse(status: 200, headers: [:], body: Data("media-bytes-\(s)".utf8))
        }
        return HTTPResponse(status: 404, headers: [:], body: Data())
    }

    /// fxtwitter JSON for a plain tweet.
    static func fxTweet(_ id: String, replyTo: String? = nil, quote: String? = nil) -> [String: Any] {
        var t: [String: Any] = ["id": id, "url": "https://x.com/u/status/\(id)", "text": "fx \(id)",
                                "author": ["name": "U", "screen_name": "u"], "created_timestamp": 1_665_000_800]
        if let replyTo { t["replying_to_status"] = replyTo; t["replying_to"] = "u" }
        if let quote { t["quote"] = ["id": quote, "text": "fx \(quote)", "author": ["name": "Q", "screen_name": "q"]] }
        return t
    }
}

/// Feed results with ids only.
private func tweets(_ ids: String...) -> [[String: Any]] { ids.map { XFix.tweet($0, text: "tweet \($0)") } }

private func makeImporter(_ c: Collection, _ x: FakeXServer, userID: String? = "9", qid: String? = nil) -> XImporter {
    var e = XEndpoints.standard(env: [:])
    if let qid { e.likes = qid; e.bookmarks = qid }
    return XImporter(staging: c.staging, client: XClient(http: x, session: XSession(authToken: "AUTH", csrf: "CSRF", userID: userID), endpoints: e), http: x)
}

private let noSleep: @Sendable (Duration) async throws -> Void = { _ in }

@Suite struct XImporterPagingTests {
    @Test func walksEveryCursorAndStagesWithoutCommitting() async throws {
        let t = try TempCollection(), c = t.collection
        let x = FakeXServer()
        x.pages = ["": (tweets("1", "2"), "C1"), "C1": (tweets("3", "4"), "C2"), "C2": (tweets("5", "6"), nil)]
        var imp = makeImporter(c, x)
        let p = try await imp.importFeed(.likes, extraTags: ["liked"], sleep: noSleep)

        #expect(x.feedRequests.map(\.cursor) == [nil, "C1", "C2"])
        #expect(p.staged == 6 && p.pages == 3 && p.tweetsSeen == 6 && p.skipped == 0 && !p.caughtUp)
        // Product rule: imports land in staging, never in the collection.
        #expect(try c.memes.count() == 0)
        let items = try c.staging.list()
        #expect(items.count == 6 && items.allSatisfy { $0.kind == .tweet && $0.parentID == nil })
        #expect(items.allSatisfy { $0.userTags == ["liked"] && $0.suggestedTags.contains("tweet") && $0.suggestedTags.contains("@u") })
        #expect(Set(items.compactMap(\.payloadTweetID)) == ["1", "2", "3", "4", "5", "6"])
        // Walked to the end: the checkpoint goes, the history is marked complete.
        #expect(try c.xCursor("likes") == nil && c.xCursor("likes-complete") == "1")
    }

    @Test func requestsCarryTheSessionAndOnlyGoToX() async throws {
        let t = try TempCollection()
        let x = FakeXServer()
        x.pages = ["": (tweets("1"), nil)]
        var imp = makeImporter(t.collection, x)
        _ = try await imp.importFeed(.likes, sleep: noSleep)
        let r = try #require(x.feedRequests.first)
        #expect(r.host == "x.com" && r.url.path.hasPrefix("/i/api/graphql/"))
        #expect(r.headers["x-csrf-token"] == "CSRF" && r.headers["cookie"] == "auth_token=AUTH; ct0=CSRF")
        #expect(r.headers["authorization"]?.hasPrefix("Bearer ") == true)
        #expect(r.variables["userId"] as? String == "9" && r.variables["count"] as? Int == 40)
        #expect(r.variables["includePromotedContent"] as? Bool == false && r.variables["cursor"] == nil)
        // The session never leaves x.com (media downloads go without cookies).
        #expect(x.requests.filter { $0.host != "x.com" }.allSatisfy { $0.headers["cookie"] == nil && $0.headers["x-csrf-token"] == nil })
    }

    @Test func anEmptyPageMidFeedDoesNotEndTheWalkButTwoInARowDo() async throws {
        let t = try TempCollection(), c = t.collection
        let x = FakeXServer()
        x.pages = ["": (tweets("1", "2"), "C1"), "C1": ([], "C2"), "C2": (tweets("3"), "C3"), "C3": ([], "C4"), "C4": ([], "C5"),
                   "C5": (tweets("never"), nil)]
        var imp = makeImporter(c, x)
        let p = try await imp.importFeed(.likes, sleep: noSleep)
        #expect(p.staged == 3 && p.pages == 5)
        #expect(x.feedRequests.map(\.cursor) == [nil, "C1", "C2", "C3", "C4"])
        #expect(try c.xCursor("likes") == nil && c.xCursor("likes-complete") == "1")
    }

    @Test func aCompletelyEmptyFeedEndsAfterOnePage() async throws {
        let t = try TempCollection(), c = t.collection
        let x = FakeXServer()      // no pages: an empty first page without a cursor
        var imp = makeImporter(c, x)
        let p = try await imp.importFeed(.likes, sleep: noSleep)
        #expect(p.staged == 0 && p.pages == 1 && x.feedRequests.count == 1)
        #expect(try c.staging.count() == 0)
    }

    @Test func duplicatesWithinAndAcrossPagesAreStagedOnce() async throws {
        let t = try TempCollection(), c = t.collection
        let x = FakeXServer()
        x.pages = ["": (tweets("1", "2", "2"), "C1"), "C1": (tweets("2", "3", "1"), nil)]
        var imp = makeImporter(c, x)
        let p = try await imp.importFeed(.likes, sleep: noSleep)
        #expect(p.staged == 3 && p.skipped == 3 && p.tweetsSeen == 6)
        #expect(try c.staging.list().compactMap(\.payloadTweetID).sorted() == ["1", "2", "3"])
    }

    @Test func aCursorThatDoesNotMoveEndsTheWalk() async throws {
        let t = try TempCollection()
        let x = FakeXServer()
        x.pages = ["": (tweets("1"), "C1"), "C1": (tweets("2"), "C1")]
        var imp = makeImporter(t.collection, x)
        let p = try await imp.importFeed(.likes, sleep: noSleep)
        #expect(p.staged == 2 && x.feedRequests.count == 2)
    }

    @Test func limitStopsExactlyAndTheRestComesNextRun() async throws {
        let t = try TempCollection(), c = t.collection
        let x = FakeXServer()
        x.pages = ["": (tweets("1", "2", "3", "4"), "C1"), "C1": (tweets("5", "6"), nil)]
        var imp = makeImporter(c, x)
        let first = try await imp.importFeed(.likes, limit: 3, concurrency: 2, sleep: noSleep)
        #expect(first.staged == 3 && x.feedRequests.count == 1)
        #expect(try c.xCursor("likes") == nil)                      // stopped mid-page: that page is fetched again
        let second = try await imp.importFeed(.likes, sleep: noSleep)
        #expect(second.staged == 3 && second.skipped == 3)
        #expect(try c.staging.list().compactMap(\.payloadTweetID).sorted() == ["1", "2", "3", "4", "5", "6"])
    }

    @Test func limitOfOneWithManyPerPage() async throws {
        let t = try TempCollection()
        let x = FakeXServer()
        x.pages = ["": (tweets("1", "2", "3"), "C1")]
        var imp = makeImporter(t.collection, x)
        let p = try await imp.importFeed(.likes, limit: 1, sleep: noSleep)
        #expect(try p.staged == 1 && t.collection.staging.count() == 1)
    }

    @Test func freshStartsAtTheTopAndResumeAtTheCheckpoint() async throws {
        let t = try TempCollection(), c = t.collection
        let x = FakeXServer()
        x.pages = ["": (tweets("1"), "C1"), "C1": (tweets("2"), "C2"), "C2": (tweets("3"), nil)]
        try c.setXCursor("likes", "C2")
        var imp = makeImporter(c, x)
        _ = try await imp.importFeed(.likes, resume: true, sleep: noSleep)
        #expect(x.feedRequests.first?.cursor == "C2")
        #expect(try c.staging.list().compactMap(\.payloadTweetID) == ["3"])

        try c.setXCursor("likes", "C2")
        let before = x.feedRequests.count
        let fresh = try await imp.importFeed(.likes, resume: false, sleep: noSleep)
        #expect(x.feedRequests[before].cursor == nil)
        #expect(fresh.staged == 2 && fresh.skipped == 1)
    }

    @Test func bookmarksNeedNoUserAndReadBothShapes() async throws {
        for legacy in [false, true] {
            let t = try TempCollection()
            let x = FakeXServer()
            x.legacyKeys = legacy
            x.pages = ["": (tweets("1", "2"), "C1"), "C1": (tweets("3"), nil)]
            var imp = makeImporter(t.collection, x, userID: nil)
            let p = try await imp.importFeed(.bookmarks, extraTags: ["bookmarked"], sleep: noSleep)
            #expect(p.staged == 3, "legacy keys: \(legacy)")
            #expect(x.feedRequests.allSatisfy { $0.operation == "Bookmarks" })
            #expect(!x.requests.contains { $0.url.absoluteString.contains("settings.json") || $0.operation == "UserByScreenName" })
            #expect(try t.collection.xCursor("bookmarks-complete") == "1" && t.collection.xCursor("likes-complete") == nil)
        }
    }

    @Test func likesReadTheLegacyTimelineKey() async throws {
        let t = try TempCollection()
        let x = FakeXServer()
        x.legacyKeys = true
        x.pages = ["": (tweets("1"), nil)]
        var imp = makeImporter(t.collection, x)
        #expect(try await imp.importFeed(.likes, sleep: noSleep).staged == 1)
    }

    @Test func userIDIsResolvedWhenTheSessionHasNone() async throws {
        let t = try TempCollection()
        let x = FakeXServer()
        x.pages = ["": (tweets("1"), nil)]
        var imp = makeImporter(t.collection, x, userID: nil)
        _ = try await imp.importFeed(.likes, sleep: noSleep)
        #expect(x.feedRequests.first?.variables["userId"] as? String == "777")
        let lookup = try #require(x.requests.first { $0.operation == "UserByScreenName" })
        #expect(lookup.variables["screen_name"] as? String == "me")
    }

    @Test func anUnreadableAccountFailsBeforeAnyFeedRequest() async throws {
        let t = try TempCollection()
        let x = FakeXServer()
        x.screenName = nil
        var imp = makeImporter(t.collection, x, userID: nil)
        await #expect(throws: XError.self) { try await imp.importFeed(.likes, sleep: noSleep) }
        #expect(x.feedRequests.isEmpty)
    }

    @Test func modulesAndNonTweetEntriesInATimeline() {
        let module: [String: Any] = ["entryId": "profile-conversation-1", "content": ["items": [
            ["entryId": "profile-conversation-1-tweet-1", "item": ["itemContent": ["tweet_results": ["result": XFix.tweet("1", text: "a")]]]],
            ["entryId": "profile-conversation-1-tweet-2", "item": ["itemContent": ["tweet_results": ["result": XFix.tweet("2", text: "b")]]]],
        ]]]
        let instructions: [[String: Any]] = [
            ["type": "TimelineClearCache"],
            ["type": "TimelineAddEntries", "entries": [
                ["entryId": "cursor-top-1", "content": ["cursorType": "Top", "value": "TOP"]],
                module,
                ["entryId": "who-to-follow-1", "content": ["items": [["entryId": "user-1", "item": ["itemContent": ["user_results": [:]]]]]]],
                ["entryId": "cursor-bottom-1", "content": ["cursorType": "Bottom", "value": "BOTTOM"]],
            ]],
            ["type": "TimelineAddToModule", "moduleItems": [
                ["entryId": "m-tweet-3", "item": ["itemContent": ["tweet_results": ["result": XFix.tweet("3", text: "c")]]]]]],
            ["type": "TimelineTerminateTimeline", "direction": "Top"],
        ]
        let page = XTimelineParser.parse(instructions: instructions)
        #expect(page.tweets.map(\.id) == ["1", "2", "3"] && page.cursor == "BOTTOM")
        #expect(XTimelineParser.parse(instructions: []).tweets.isEmpty)
    }
}

@Suite struct XImporterFailureTests {
    @Test func rateLimitWaitsUntilTheResetHeader() async throws {
        let t = try TempCollection()
        let x = FakeXServer()
        x.pages = ["": (tweets("1"), nil)]
        x.override = { n, _ in
            n == 1 ? HTTPResponse(status: 429, headers: ["x-rate-limit-reset": String(Int(Date().timeIntervalSince1970) + 600)], body: Data()) : nil
        }
        let sleeps = Sleeps()
        let waiting = Flags()
        var imp = makeImporter(t.collection, x)
        let p = try await imp.importFeed(.likes, sleep: sleeps.record, onProgress: { pr in waiting.add(pr.waitingUntil != nil) })
        #expect(p.staged == 1)
        let first = try #require(sleeps.list.first?.components.seconds)
        #expect((598...606).contains(first))
        #expect(waiting.all.first == true && waiting.all.last == false)       // said it was waiting, then stopped saying so
    }

    @Test(arguments: [
        (nil as String?, 77 as Int64),             // no header → the default wait
        ("garbage", 77),
        ("nan", 77),
        ("inf", 77),
        ("-1e300", 30),                            // in the past → the 30 s floor
        ("0", 30),
        ("1e300", 86_405),                         // absurdly far → capped at a day
    ])
    func rateLimitWaitIsSaneWhateverTheHeaderSays(header: String?, seconds: Int64) async throws {
        let t = try TempCollection()
        let x = FakeXServer()
        x.pages = ["": (tweets("1"), nil)]
        x.override = { n, _ in
            n == 1 ? HTTPResponse(status: 429, headers: header.map { ["x-rate-limit-reset": $0] } ?? [:], body: Data()) : nil
        }
        var pace = XImporter.Pace(); pace.defaultRateLimitWait = .seconds(77)
        let sleeps = Sleeps()
        var imp = makeImporter(t.collection, x)
        let p = try await imp.importFeed(.likes, pace: pace, sleep: sleeps.record)
        #expect(p.staged == 1)
        #expect(sleeps.list.first?.components.seconds == seconds)
    }

    @Test(arguments: [401, 403, 500])
    func sessionErrorsSurfaceAndKeepTheCheckpoint(status: Int) async throws {
        let t = try TempCollection(), c = t.collection
        let x = FakeXServer()
        x.pages = ["": (tweets("1", "2"), "C1"), "C1": (tweets("3"), nil)]
        x.override = { n, _ in n == 2 ? HTTPResponse(status: status, headers: [:], body: Data(#"{"errors":[{"code":32}]}"#.utf8)) : nil }
        var imp = makeImporter(c, x)
        do {
            _ = try await imp.importFeed(.likes, sleep: noSleep)
            Issue.record("expected an error")
        } catch let e as XError {
            #expect(e.description.contains("HTTP \(status)"))
            if status != 500 { #expect(e.description.contains("Session expired")) }
        }
        #expect(try c.staging.count() == 2 && c.memes.count() == 0)
        #expect(try c.xCursor("likes") == "C1" && c.xCursor("likes-complete") == nil)
        #expect(x.feedRequests.count == 2)                                    // no retry loop on auth errors
    }

    @Test func graphQLErrorsInA200Surface() async throws {
        let t = try TempCollection()
        let x = FakeXServer()
        x.override = { _, _ in FakeXServer.json(["errors": [["message": "Authorization: Denied by access control"]]]) }
        var imp = makeImporter(t.collection, x)
        do { _ = try await imp.importFeed(.likes, sleep: noSleep); Issue.record("expected an error") }
        catch let e as XError { #expect(e.description.contains("Denied by access control")) }
    }

    @Test func aResponseWithoutDataOrJSONFails() async throws {
        for body in [Data(#"{"nothing":1}"#.utf8), Data("<html>".utf8)] {
            let t = try TempCollection()
            let x = FakeXServer()
            x.override = { _, _ in HTTPResponse(status: 200, headers: [:], body: body) }
            var imp = makeImporter(t.collection, x)
            await #expect(throws: (any Error).self) { try await imp.importFeed(.likes, sleep: noSleep) }
            #expect(try t.collection.staging.count() == 0)
        }
    }
}

@Suite struct XEndpointRotationTests {
    static let bundle = "https://abs.twimg.com/responsive-web/client-web/main.abc123.js"

    private func server(newID: String) -> FakeXServer {
        let x = FakeXServer()
        x.pages = ["": (tweets("1", "2"), nil)]
        x.serviceWorker = #"self.assets=["\#(Self.bundle)"];"#
        x.bundles[Self.bundle] = #"e.exports={queryId:"\#(newID)",operationName:"Likes",operationType:"query"};"#
            + #"{queryId:"BOOKMARKSqid00000001",operationName:"Bookmarks"}"#
        x.override = { _, req in req.queryID == "OLDLIKESqid000000001" ? HTTPResponse(status: 404, headers: [:], body: Data()) : nil }
        return x
    }

    @Test(arguments: [404, 400])
    func outdatedQueryIDIsRediscoveredUsedAndPersisted(status: Int) async throws {
        let t = try TempCollection()
        let x = server(newID: "NEWLIKESqid000000001")
        x.override = { _, req in req.queryID == "OLDLIKESqid000000001" ? HTTPResponse(status: status, headers: [:], body: Data()) : nil }
        let saved = Holder<XEndpointOverride>()
        var imp = makeImporter(t.collection, x, qid: "OLDLIKESqid000000001")
        imp.client.onEndpointsDiscovered = { saved.set($0) }
        let p = try await imp.importFeed(.likes, sleep: noSleep)
        #expect(p.staged == 2)
        #expect(x.feedRequests.map(\.queryID) == ["OLDLIKESqid000000001", "NEWLIKESqid000000001"])
        #expect(saved.value?.likes == "NEWLIKESqid000000001" && saved.value?.bookmarks == "BOOKMARKSqid00000001")
        #expect(saved.value?.updatedAt != nil)
        #expect(imp.client.endpoints.likes == "NEWLIKESqid000000001")     // later pages and runs use the new id
        // Bundles are fetched without the session cookie.
        #expect(x.requests.filter { $0.host == "abs.twimg.com" || $0.url.lastPathComponent == "sw.js" }.allSatisfy { $0.headers["cookie"] == nil })
    }

    @Test func rediscoveringTheSameStaleIDFailsInsteadOfLooping() async throws {
        let t = try TempCollection()
        let x = server(newID: "OLDLIKESqid000000001")
        var imp = makeImporter(t.collection, x, qid: "OLDLIKESqid000000001")
        await #expect(throws: XQueryOutdated.self) { try await imp.importFeed(.likes, sleep: noSleep) }
        #expect(x.feedRequests.count == 2)
    }

    @Test func unreachableBundlesAreAClearError() async throws {
        let t = try TempCollection()
        let x = server(newID: "NEWLIKESqid000000001")
        x.serviceWorker = nil                                          // sw.js and /home both 404
        var imp = makeImporter(t.collection, x, qid: "OLDLIKESqid000000001")
        do { _ = try await imp.importFeed(.likes, sleep: noSleep); Issue.record("expected an error") }
        catch let e as XError { #expect(e.description.contains("could not reach x.com JS bundles")) }
    }

    @Test func bundlesWithoutQueryIDsAreAClearError() async throws {
        let t = try TempCollection()
        let x = server(newID: "NEWLIKESqid000000001")
        x.bundles[Self.bundle] = "console.log('nothing here')"
        var imp = makeImporter(t.collection, x, qid: "OLDLIKESqid000000001")
        do { _ = try await imp.importFeed(.likes, sleep: noSleep); Issue.record("expected an error") }
        catch let e as XError { #expect(e.description.contains("could not find query ids")) }
    }

    @Test func homePageBundlesAreFollowedWithTheSession() async throws {
        let t = try TempCollection()
        let x = server(newID: "NEWLIKESqid000000001")
        x.serviceWorker = nil
        x.homeHTML = #"<script src="\#(Self.bundle)"></script>"#
        var imp = makeImporter(t.collection, x, qid: "OLDLIKESqid000000001")
        #expect(try await imp.importFeed(.likes, sleep: noSleep).staged == 2)
        #expect(x.requests.first { $0.url.absoluteString == "https://x.com/home" }?.headers["cookie"] == "auth_token=AUTH; ct0=CSRF")
    }

    @Test func queryIDExtractionEdgeCases() {
        #expect(XClient.queryID(operation: "Likes", in: #"{queryId:'single-quoted_ID01',operationName:'Likes'}"#) == "single-quoted_ID01")
        #expect(XClient.queryID(operation: "Likes", in: #"{"queryId" : "spaced0000000000001" , "operationName" : "Likes"}"#) == "spaced0000000000001")
        #expect(XClient.queryID(operation: "Likes", in: #"{queryId:"short",operationName:"Likes"}"#) == nil)          // too short to be an id
        // "LikesTimeline" must not be taken for "Likes".
        #expect(XClient.queryID(operation: "Likes", in: #"{queryId:"WRONGwrongWRONG0001",operationName:"LikesTimeline"}"#) == nil)
        #expect(XClient.bundleURLs(in: "no scripts here").isEmpty)
    }
}

@Suite struct XImporterResumeTests {
    @Test func cancellingBetweenPagesResumesAtTheCheckpoint() async throws {
        let t = try TempCollection(), c = t.collection
        let x = FakeXServer()
        x.pages = ["": (tweets("1", "2"), "C1"), "C1": (tweets("3", "4"), "C2"), "C2": (tweets("5"), nil)]
        let imp = makeImporter(c, x)
        // Cancel while pausing after the first page.
        let first = try await Task {
            var i = imp
            return try await i.importFeed(.likes, sleep: { _ in withUnsafeCurrentTask { $0?.cancel() } })
        }.value
        #expect(first.staged == 2 && first.pages == 1)
        #expect(try c.xCursor("likes") == "C1")

        let second = try await Task { var i = imp; return try await i.importFeed(.likes, sleep: noSleep) }.value
        #expect(x.feedRequests.map(\.cursor) == [nil, "C1", "C2"])
        #expect(second.staged == 3 && second.skipped == 0)
        #expect(try c.staging.list().compactMap(\.payloadTweetID).sorted() == ["1", "2", "3", "4", "5"])
    }

    @Test func cancellingMidPageLosesAndDuplicatesNothing() async throws {
        let t = try TempCollection(), c = t.collection
        let x = FakeXServer()
        x.pages = ["": (tweets("1", "2", "3"), "C1"), "C1": (tweets("4"), nil)]
        let imp = makeImporter(c, x)
        let first = try await Task {
            var i = imp
            return try await i.importFeed(.likes, concurrency: 1, sleep: noSleep, onItem: { _ in withUnsafeCurrentTask { $0?.cancel() } })
        }.value
        #expect(first.staged == 1)
        #expect(try c.xCursor("likes") == nil)                             // the page wasn't finished: no checkpoint past it

        let second = try await Task { var i = imp; return try await i.importFeed(.likes, sleep: noSleep) }.value
        #expect(second.staged == 3 && second.skipped == 1)
        let ids = try c.staging.list().compactMap(\.payloadTweetID)
        #expect(ids.sorted() == ["1", "2", "3", "4"] && Set(ids).count == ids.count)
    }

    @Test func alreadyCancelledDoesNothing() async throws {
        let t = try TempCollection()
        let x = FakeXServer()
        x.pages = ["": (tweets("1"), nil)]
        let imp = makeImporter(t.collection, x)
        let task = Task { () throws -> XImporter.Progress in
            withUnsafeCurrentTask { $0?.cancel() }
            var i = imp
            return try await i.importFeed(.likes, sleep: noSleep)
        }
        let p = try await task.value
        #expect(p.staged == 0 && x.feedRequests.isEmpty)
    }
}

@Suite struct XImporterUpdateRunTests {
    @Test func knownPagesStopOnlyUpdateRunsAndMixedPagesResetTheStreak() async throws {
        let t = try TempCollection(), c = t.collection
        let x = FakeXServer()
        x.pages = ["": (tweets("1", "2"), "C1"), "C1": (tweets("3", "4"), "C2"), "C2": (tweets("5", "6"), nil)]
        var imp = makeImporter(c, x)
        _ = try await imp.importFeed(.likes, sleep: noSleep)                        // full walk → complete
        #expect(try c.xCursor("likes-complete") == "1")

        // New ones on top, mixed with known ones on the first page.
        x.pages = ["": (tweets("8", "1"), "C1"), "C1": (tweets("2", "7"), "C2"), "C2": (tweets("3", "4"), "C3"),
                   "C3": (tweets("5", "6"), nil)]
        var pace = XImporter.Pace(); pace.knownPagesToStop = 1
        let before = x.feedRequests.count
        let p = try await imp.importFeed(.likes, pace: pace, sleep: noSleep)
        #expect(p.staged == 2 && p.caughtUp && p.skipped == 4)
        #expect(x.feedRequests.count - before == 3)                                // stops at the first all-known page
        #expect(try c.xCursor("likes") == nil)
    }

    @Test func withoutACompleteWalkKnownPagesKeepGoing() async throws {
        let t = try TempCollection(), c = t.collection
        let x = FakeXServer()
        x.pages = ["": (tweets("1"), "C1"), "C1": (tweets("2"), "C2"), "C2": (tweets("3"), "C3"), "C3": (tweets("4"), nil)]
        var imp = makeImporter(c, x)
        _ = try await imp.importFeed(.likes, limit: 2, sleep: noSleep)
        try c.clearXCursor("likes")
        let p = try await imp.importFeed(.likes, resume: false, sleep: noSleep)
        #expect(p.staged == 2 && p.skipped == 2 && !p.caughtUp)
    }
}

@Suite struct XImporterChainTests {
    /// Liked tweet 10 replies to 9 (fetched from fxtwitter; 9 replies to 8, which is gone) and quotes 7
    /// (carried in the timeline).
    private func server() -> FakeXServer {
        let x = FakeXServer()
        let root = XFix.tweet("10", text: "the punchline", legacy: [
            "in_reply_to_status_id_str": "9", "in_reply_to_screen_name": "u", "quoted_status_id_str": "7"],
            result: ["quoted_status_result": ["result": XFix.tweet("7", text: "quoted one", handle: "q")]])
        x.pages = ["": ([root], nil)]
        x.fx["9"] = FakeXServer.fxTweet("9", replyTo: "8")
        return x
    }

    @Test func chainIsStagedUnderItsTweetAndHiddenAfterCommit() async throws {
        let t = try TempCollection(), c = t.collection
        let x = server()
        var imp = makeImporter(c, x)
        let p = try await imp.importFeed(.likes, extraTags: ["liked"], sleep: noSleep)
        #expect(p.staged == 1 && p.chain == 2 && p.chainMissing == 1)
        #expect(try c.memes.count() == 0)                                         // still nothing committed
        let root = try #require(try c.staging.list().first)
        #expect(try c.staging.list().count == 1 && c.staging.count() == 1)
        let chain = try c.staging.chain(of: root.id)
        #expect(Set(chain.compactMap(\.payloadTweetID)) == ["9", "7"] && chain.allSatisfy { $0.parentID == root.id })
        #expect(chain.allSatisfy { $0.suggestedTags.contains("chain") && !$0.suggestedTags.contains("tweet") && $0.userTags.isEmpty })
        #expect(chain.first { $0.payloadTweetID == "9" }?.suggestedTags.contains("thread") == true)
        #expect(chain.first { $0.payloadTweetID == "7" }?.suggestedTags.contains("quoted") == true)
        #expect(!x.requests.contains { $0.url.absoluteString.hasSuffix("/status/7") })   // the quote came with the page

        let meme = try c.staging.commit(root.id)
        #expect(try c.memes.count() == 3 && c.staging.chain(of: root.id).isEmpty)
        #expect(try c.search.search("").memes.map(\.id) == [meme.id])                // chain hidden from Posts
        #expect(try c.search.search("liked").memes.map(\.id) == [meme.id])
        #expect(try c.search.search("chain").memes.count == 2)
    }

    @Test func chainsOffStagesOnlyTheTweet() async throws {
        let t = try TempCollection(), c = t.collection
        let x = server()
        var imp = makeImporter(c, x)
        let p = try await imp.importFeed(.likes, chains: false, sleep: noSleep)
        #expect(p.staged == 1 && p.chain == 0)
        #expect(try c.db.scalarInt("SELECT count(*) FROM staged") == 1)
        #expect(!x.requests.contains { $0.host == "api.fxtwitter.com" })
    }

    @Test func aStagedChainTweetThatIsLikedItselfBecomesAnItem() async throws {
        let t = try TempCollection(), c = t.collection
        let x = server()
        var imp = makeImporter(c, x)
        _ = try await imp.importFeed(.likes, sleep: noSleep)
        // Later, 9 itself shows up in the likes (newest first).
        x.pages = ["": ([XFix.tweet("9", text: "fx 9")] + [x.pages[""]!.tweets[0]], nil)]
        let p = try await imp.importFeed(.likes, extraTags: ["liked"], resume: false, sleep: noSleep)
        #expect(p.promoted == 1 && p.staged == 0 && p.skipped == 1)
        let nine = try #require(try c.staging.list().first { $0.payloadTweetID == "9" })
        #expect(nine.parentID == nil && nine.userTags.contains("liked") && nine.suggestedTags.contains("tweet") && !nine.suggestedTags.contains("chain"))
        #expect(try c.staging.count() == 2)
    }

    @Test func aCommittedChainTweetThatIsLikedItselfBecomesAPost() async throws {
        let t = try TempCollection(), c = t.collection
        let x = server()
        var imp = makeImporter(c, x)
        _ = try await imp.importFeed(.likes, sleep: noSleep)
        _ = try c.staging.commit(try #require(try c.staging.list().first).id)
        #expect(try c.search.search("").memes.count == 1)
        x.pages = ["": ([XFix.tweet("7", text: "quoted one", handle: "q")], nil)]
        let p = try await imp.importFeed(.likes, extraTags: ["liked"], resume: false, sleep: noSleep)
        #expect(p.promoted == 1 && p.staged == 0)
        #expect(try c.search.search("").memes.count == 2 && c.staging.count() == 0)
    }

    @Test func twoLikedRepliesToOneParentStageItOnce() async throws {
        let t = try TempCollection(), c = t.collection
        let x = FakeXServer()
        x.pages = ["": ((1...6).map { XFix.tweet("r\($0)", text: "reply \($0)", legacy: ["in_reply_to_status_id_str": "p", "in_reply_to_screen_name": "u"]) }, nil)]
        x.fx["p"] = FakeXServer.fxTweet("p")
        var imp = makeImporter(c, x)
        let p = try await imp.importFeed(.likes, concurrency: 6, sleep: noSleep)
        #expect(p.staged == 6 && p.chain == 1)
        #expect(x.requests.filter { $0.url.absoluteString == "https://api.fxtwitter.com/status/p" }.count == 1)
        #expect(try c.db.scalarInt("SELECT count(*) FROM staged WHERE parent_id IS NOT NULL") == 1)
    }
}

@Suite struct XImporterMediaTests {
    private func server() -> FakeXServer {
        let x = FakeXServer()
        x.pages = ["": ([XFix.tweet("1", text: "two pics", legacy: ["extended_entities": ["media": [XFix.photo("ok"), XFix.photo("gone")]]]),
                         XFix.tweet("2", text: "one pic", legacy: ["extended_entities": ["media": [XFix.photo("fine")]]])], nil)]
        x.failingMedia = ["https://pbs.twimg.com/media/gone.jpg?name=orig"]
        return x
    }

    @Test func missingMediaAndBytesAreCountedWhenStaging() async throws {
        let t = try TempCollection()
        var imp = makeImporter(t.collection, server())
        let p = try await imp.importFeed(.likes, sleep: noSleep)
        #expect(p.staged == 2 && p.mediaMissing == 1 && p.bytes > 0)
        let one = try #require(try t.collection.staging.list().first { $0.payloadTweetID == "1" })
        #expect(t.collection.staging.extras(one).filter { $0.role == .media }.count == 1)
    }

    @Test func missingMediaAndBytesAreCountedWhenCommittingDirectly() async throws {
        let t = try TempCollection()
        var imp = makeImporter(t.collection, server())
        let p = try await imp.importFeed(.likes, commitDirectly: true, sleep: noSleep)
        #expect(p.staged == 2 && p.mediaMissing == 1 && p.bytes > 0)
    }
}

@Suite struct XSessionConfigTests {
    @Test(arguments: [
        ("auth_token=A; ct0=C; twid=u%3D12345", "12345"),
        ("auth_token=A; ct0=C; twid=\"u=12345\"", "12345"),           // browsers often show twid quoted
        ("auth_token=A; ct0=C; twid=\"u%3D12345\"", "12345"),
        ("auth_token=A; ct0=C; twid=garbage", nil),
        ("auth_token=A; ct0=C; twid=u%3D", nil),
        ("auth_token=A; ct0=C", nil),
    ] as [(String, String?)])
    func userIDComesFromTwidWhenItIsAnID(header: String, id: String?) throws {
        let s = try #require(XSession.fromCookieHeader(header))
        #expect(s.authToken == "A" && s.csrf == "C" && s.userID == id)
    }

    @Test func essentialsAreRequired() {
        #expect(XSession.fromCookieHeader("") == nil)
        #expect(XSession.fromCookieHeader("auth_token=; ct0=C") == nil)
        #expect(XSession.fromCookieHeader("auth_token=A") == nil)
        #expect(XSession.fromCookieHeader(";;;  ; =;") == nil)
        let spaced = XSession.fromCookieHeader("  guest_id=v1%3A1 ;auth_token = A==;ct0=C  ")
        #expect(spaced?.authToken == "A==" && spaced?.csrf == "C")          // values may contain "="
    }

    @Test func sessionRoundTripsThroughJSON() throws {
        let s = XSession(authToken: "A", csrf: "C", userID: "1")
        #expect(try JSONDecoder().decode(XSession.self, from: JSONEncoder().encode(s)) == s)
    }

    @Test func endpointsComeFromTheEnvironmentWhenSet() {
        let e = XEndpoints.standard(env: ["X_QID_LIKES": "L", "X_QID_BOOKMARKS": "B", "X_QID_USER": "U", "X_FEATURES": #"{"a":true}"#])
        #expect(e.likes == "L" && e.bookmarks == "B" && e.userByScreenName == "U" && e.features == ["a": true])
        let bad = XEndpoints.standard(env: ["X_FEATURES": "not json"])
        #expect(bad.features == XEndpoints.defaultFeatures && !bad.likes.isEmpty)
        var o = XEndpointOverride()
        #expect(o.isEmpty)
        o.userByScreenName = "X"
        var applied = XEndpoints.standard(env: [:]); applied.apply(o)
        #expect(!o.isEmpty && applied.userByScreenName == "X" && applied.likes == XEndpoints.standard(env: [:]).likes)
    }
}

final class Flags: @unchecked Sendable {
    private let lock = NSLock(); private var list: [Bool] = []
    var all: [Bool] { lock.withLock { list } }
    func add(_ b: Bool) { lock.withLock { list.append(b) } }
}

final class Holder<T>: @unchecked Sendable {
    private let lock = NSLock(); private var v: T?
    var value: T? { lock.withLock { v } }
    func set(_ new: T) { lock.withLock { v = new } }
}
