import Foundation
import Testing
import MemebooruCore
@testable import memebooru

/// A scripted x.com + fxtwitter + media CDN. Records every request; anything unscripted is a 404.
/// The session used against it is made up ("FAKE-…"); real cookies are never read.
final class FakeX: HTTPClient, @unchecked Sendable {
    struct Request: Sendable { let url: URL; let headers: [String: String] }
    let log = Locked<[Request]>([])
    var requests: [Request] { log.value }
    /// Feed pages keyed by the cursor they answer ("" = first page).
    var pages: [String: (tweets: [[String: Any]], next: String?)] = [:]
    var feedStatus = 200
    var fx: [String: [String: Any]] = [:]
    var screenName: String? = "me"
    let png: Data

    init() throws { png = try Samples.png(.rings) }

    static func json(_ obj: Any, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: [:], body: try! JSONSerialization.data(withJSONObject: obj))
    }

    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        log.mutate { $0.append(Request(url: url, headers: headers)) }
        let s = url.absoluteString
        if url.path.contains("/graphql/") {
            let op = url.lastPathComponent
            if op == "UserByScreenName" { return Self.json(["data": ["user": ["result": ["rest_id": "777"]]]]) }
            guard op == "Likes" || op == "Bookmarks" else { return Self.json([:], status: 404) }
            guard feedStatus == 200 else { return Self.json(["errors": [["message": "nope"]]], status: feedStatus) }
            let vars = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "variables" }?.value
            let cursor = vars.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }?["cursor"] as? String
            let page = pages[cursor ?? ""] ?? (tweets: [], next: nil)
            var entries: [[String: Any]] = page.tweets.map { r in
                ["entryId": "tweet-\(r["rest_id"] as? String ?? "?")", "content": ["itemContent": ["tweet_results": ["result": r]]]]
            }
            if let next = page.next { entries.append(["entryId": "cursor-bottom-1", "content": ["cursorType": "Bottom", "value": next]]) }
            let tl: [String: Any] = ["timeline": ["instructions": [["type": "TimelineAddEntries", "entries": entries]]]]
            return op == "Likes" ? Self.json(["data": ["user": ["result": ["timeline_v2": tl]]]])
                                 : Self.json(["data": ["bookmark_timeline_v2": tl]])
        }
        if s.hasPrefix("https://api.x.com/1.1/account/settings.json") {
            guard let screenName else { return HTTPResponse(status: 401, headers: [:], body: Data()) }
            return Self.json(["screen_name": screenName])
        }
        if s.hasPrefix("https://api.fxtwitter.com/status/") {
            guard let t = fx[url.lastPathComponent] else { return Self.json(["code": 404, "message": "NOT_FOUND"], status: 404) }
            return Self.json(["code": 200, "tweet": t])
        }
        if url.host?.hasSuffix("twimg.com") == true { return HTTPResponse(status: 200, headers: [:], body: png) }
        return HTTPResponse(status: 404, headers: [:], body: Data())
    }

    /// A GraphQL `Tweet` result with one photo.
    static func tweet(_ id: String, text: String, photo: Bool = true) -> [String: Any] {
        var legacy: [String: Any] = ["full_text": text, "created_at": "Wed Oct 05 20:00:00 +0000 2022"]
        if photo {
            let m: [String: Any] = ["type": "photo", "media_url_https": "https://pbs.twimg.com/media/p\(id).jpg",
                                    "original_info": ["width": 64, "height": 64]]
            legacy["extended_entities"] = ["media": [m]]
            legacy["entities"] = ["media": [m]]
        }
        return ["__typename": "Tweet", "rest_id": id, "legacy": legacy,
                "core": ["user_results": ["result": ["legacy": ["screen_name": "author", "name": "Автор",
                                                                 "profile_image_url_https": "https://pbs.twimg.com/profile_images/1/a_normal.jpg"]]]]]
    }

    /// fxtwitter JSON for a tweet, optionally replying to another.
    static func fxTweet(_ id: String, text: String, replyTo: String? = nil) -> [String: Any] {
        var t: [String: Any] = ["id": id, "url": "https://x.com/u/status/\(id)", "text": text,
                                "author": ["name": "U", "screen_name": "u"], "created_timestamp": 1_665_000_800]
        if let replyTo { t["replying_to_status"] = replyTo; t["replying_to"] = "u" }
        return t
    }
}

/// `x` and `import likes/bookmarks/tweet` with a fake HTTP client and a sandboxed session folder.
@Suite struct CLIXCommandTests {
    static let fakeCookies = "auth_token=FAKE-auth-0000; ct0=FAKE-csrf-0000; twid=u%3D4242"

    /// Fresh, empty session folder (never the user's Application Support).
    private func sandbox() throws -> TempDir { try TempDir("mb x session") }

    // MARK: Session management (all platforms)

    @Test func loginSavesToTheSandboxOnlyAndLogoutClears() async throws {
        let box = try sandbox()
        var r = await CLI.run(["x", "login", "--cookies", Self.fakeCookies], xDir: box.url)
        #expect(r.ok && r.out == "saved x.com session (user 4242)\n", "\(r)")
        let file = box.url.appendingPathComponent("x-session.json")
        let saved = try JSONDecoder().decode(XSession.self, from: Data(contentsOf: file))
        #expect(saved == XSession(authToken: "FAKE-auth-0000", csrf: "FAKE-csrf-0000", userID: "4242"))
        let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)

        r = await CLI.run(["x", "login", "--auth-token", "FAKE-2", "--csrf", "FAKE-c2"], xDir: box.url)
        #expect(r.ok && r.out == "saved x.com session\n", "\(r)")
        #expect(try JSONDecoder().decode(XSession.self, from: Data(contentsOf: file)).authToken == "FAKE-2")

        r = await CLI.run(["x", "logout"], xDir: box.url)
        #expect(r.ok && r.out == "cleared\n" && !FileManager.default.fileExists(atPath: file.path), "\(r)")
        r = await CLI.run(["x", "logout"], xDir: box.url)        // nothing to clear is fine
        #expect(r.ok, "\(r)")
    }

    @Test(arguments: [
        (["x", "login"], "pass --cookies"),
        (["x", "login", "--auth-token", "only"], "pass --cookies"),
        (["x", "login", "--cookies", "garbage; no=cookies"], "could not find auth_token and ct0"),
        (["x", "login", "--cookies", "auth_token=; ct0=x"], "could not find auth_token and ct0"),
    ])
    func loginRejectsIncompleteInput(_ args: [String], _ message: String) async throws {
        let box = try sandbox()
        let r = await CLI.run(args, xDir: box.url)
        #expect(r.code == 64 && r.err.contains(message), "\(r)")
        #expect(!FileManager.default.fileExists(atPath: box.url.appendingPathComponent("x-session.json").path))
    }

    @Test func qidOverridesMergeAndPrint() async throws {
        let box = try sandbox()
        var r = await CLI.run(["x", "qid", "--likes", "LIKES-1", "--bookmarks", "BM-1"], xDir: box.url)
        #expect(r.ok && r.out.contains("Likes:            LIKES-1") && r.out.contains("Bookmarks:        BM-1"), "\(r)")
        r = await CLI.run(["x", "qid", "--user", "USER-1"], xDir: box.url)
        #expect(r.out.contains("LIKES-1") && r.out.contains("BM-1") && r.out.contains("UserByScreenName: USER-1"), "earlier ids kept: \(r)")
        r = await CLI.run(["x", "qid", "--discover"], xDir: box.url)
        #expect(r.ok && r.out.contains("discovery happens automatically"), "\(r)")
        // A fresh sandbox shows the built-in defaults, untouched by the runs above.
        let other = try sandbox()
        r = await CLI.run(["x", "qid"], xDir: other.url)
        #expect(r.ok && !r.out.contains("LIKES-1"), "\(r)")
    }

    @Test func noNetworkWithoutASession() async throws {
        let box = try sandbox()
        let net = NoNetwork()
        let r = await CLI.run(["x", "whoami"], http: net, xDir: box.url)
        #if canImport(ImageIO)
        #expect(r.ok && r.out == "no saved session — run `memebooru x login`\n", "\(r)")
        #else
        #expect(r.ok && r.out == "not supported on this platform\n", "\(r)")
        #endif
        let d = await CLI.run(["x", "dump", "likes"], http: net, xDir: box.url)
        #expect(d.code == 64, "\(d)")
        #expect(net.requests.value.isEmpty)
    }

    @Test func importWithoutSessionFailsBeforeAnyRequest() async throws {
        let env = ProcessInfo.processInfo.environment
        try #require(env["X_COOKIES"] == nil && env["X_AUTH_TOKEN"] == nil, "x.com env vars set in this environment")
        let c = try await CLICollection()
        let net = NoNetwork()
        for feed in ["likes", "bookmarks"] {
            let r = await CLI.run(CLICollection.inject(["import", feed], c.path), http: net, xDir: try sandbox().url)
            #if canImport(ImageIO)
            #expect(r.code == 64 && r.err.contains("no x.com session"), "\(r)")
            #else
            #expect(r.code == 64 && r.err.contains("not supported on this platform"), "\(r)")
            #endif
        }
        #expect(net.requests.value.isEmpty)
    }

    #if canImport(ImageIO)
    // MARK: Against the fake x.com (the x import commands are Apple-only)

    @Test func whoamiUsesTheSavedSessionAgainstTheFake() async throws {
        let box = try sandbox(), x = try FakeX()
        _ = await CLI.run(["x", "login", "--auth-token", "FAKE-a", "--csrf", "FAKE-c"], xDir: box.url)   // no twid → resolved
        let r = await CLI.run(["x", "whoami"], http: x, xDir: box.url)
        #expect(r.ok && r.out == "logged in, user id 777\n", "\(r)")
        #expect(x.requests.contains { $0.url.absoluteString.hasPrefix("https://api.x.com/1.1/account/settings.json") })
        #expect(x.requests.allSatisfy { $0.headers["cookie"] == "auth_token=FAKE-a; ct0=FAKE-c" && $0.headers["x-csrf-token"] == "FAKE-c" })

        x.screenName = nil   // expired session
        let bad = await CLI.run(["x", "whoami"], http: x, xDir: box.url)
        #expect(bad.code == 1 && bad.err.contains("session likely invalid"), "\(bad)")
    }

    @Test func dumpWritesTheRawFirstPage() async throws {
        let box = try sandbox(), x = try FakeX(), out = try TempDir()
        x.pages = ["": ([FakeX.tweet("1", text: "one")], nil)]
        _ = await CLI.run(["x", "login", "--cookies", Self.fakeCookies], xDir: box.url)
        let file = out.path("дамп likes.json")
        var r = await CLI.run(["x", "dump", "likes", "--out", file], http: x, xDir: box.url)
        #expect(r.ok && r.out.hasPrefix("wrote ") && r.out.contains(file), "\(r)")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: file))) as? [String: Any]
        #expect(json?["data"] != nil)
        r = await CLI.run(["x", "dump", "follows"], http: x, xDir: box.url)
        #expect(r.code == 64 && r.err.contains("feed must be likes or bookmarks"), "\(r)")
    }

    @Test func importLikesStagesEverythingAndCommitsNothing() async throws {
        let c = try await CLICollection()
        let x = try FakeX()
        x.pages = ["": ([FakeX.tweet("101", text: "первый твит"), FakeX.tweet("102", text: "second", photo: false)], "C1"),
                   "C1": ([], nil)]
        var r = await c.run(["import", "likes", "--cookies", Self.fakeCookies, "--page-delay", "0", "-l", "0", "--tags", "мои"], http: x)
        #expect(r.ok, "\(r)")
        #expect(r.out.contains("likes: 2 staged") && r.out.contains("Review them: memebooru stage ls"), "\(r)")

        // HARD RULE: staged, not committed.
        #expect(try c.open().memes.count() == 0)
        r = await c.run("stage", "ls")
        #expect(r.out.contains("2 staged") && r.lines.filter { $0.contains("tweet") && $0.contains("liked") && $0.contains("мои") }.count == 2, "\(r)")

        // Requests: only the fake hosts, always with the fake session — never anything real.
        #expect(!x.requests.isEmpty)
        #expect(x.requests.allSatisfy { ["x.com", "api.x.com", "pbs.twimg.com", "video.twimg.com", "api.fxtwitter.com"].contains($0.url.host ?? "") }, "\(x.requests.map(\.url))")
        #expect(x.requests.filter { $0.url.path.contains("/graphql/") }.allSatisfy { $0.headers["cookie"] == "auth_token=FAKE-auth-0000; ct0=FAKE-csrf-0000" })
        let likes = x.requests.filter { $0.url.lastPathComponent == "Likes" }
        #expect(likes.count == 2 && likes.allSatisfy { $0.url.absoluteString.contains("4242") })

        // Running again: nothing new, already here.
        r = await c.run(["import", "likes", "--cookies", Self.fakeCookies, "--page-delay", "0", "--fresh"], http: x)
        #expect(r.ok && r.out.contains("likes: 0 staged") && r.out.contains("2 already here"), "\(r)")

        // Commit them, then move them back to staging with `x restage` and undo that.
        r = await c.run("stage", "commit", "all")
        #expect(r.lines.filter { $0.hasPrefix("✓") }.count == 2, "\(r)")
        r = await c.run("search", "liked")
        #expect(r.out.contains("2 result(s)"), "\(r)")
        r = await c.run("x", "restage", "--tag", "liked")
        #expect(r.ok && r.out.contains("moving 2 tweets tagged liked to staging…") && r.out.contains("staged 2. Undo: memebooru undo"), "\(r)")
        #expect(try c.open().ids("liked").isEmpty)
        r = await c.run("x", "reparse")
        #expect(r.ok && r.out.hasPrefix("updated "), "\(r)")
        r = await c.run("undo")
        #expect(r.ok && r.out == "undone: Moved 2 tweets back to staging\n", "\(r)")
        #expect(try c.open().ids("liked").count == 2)

        // delete-tweets is one undoable step too.
        r = await c.run("delete-tweets")
        #expect(r.ok && r.out.contains("Delete 2 tweets — reversible: `memebooru undo`"), "\(r)")
        #expect(try c.open().ids("liked").isEmpty)
        r = await c.run("undo")
        #expect(r.ok && r.out == "undone: Delete 2 tweets\n", "\(r)")
        #expect(try c.open().ids("liked").count == 2)
    }

    @Test func importBookmarksUsesTheBookmarksFeed() async throws {
        let c = try await CLICollection()
        let x = try FakeX()
        x.pages = ["": ([FakeX.tweet("201", text: "bookmarked one", photo: false)], nil)]
        let r = await c.run(["import", "bookmarks", "--cookies", Self.fakeCookies, "--page-delay", "0"], http: x)
        #expect(r.ok && r.out.contains("bookmarks: 1 staged"), "\(r)")
        #expect(x.requests.contains { $0.url.lastPathComponent == "Bookmarks" } && !x.requests.contains { $0.url.lastPathComponent == "Likes" })
        #expect(try c.open().memes.count() == 0)
        #expect(await c.run("stage", "ls").out.contains("bookmarked"))
    }

    @Test func importFailureExitsWithOneAndKeepsTheCheckpoint() async throws {
        let c = try await CLICollection()
        let x = try FakeX()
        x.feedStatus = 403
        let r = await c.run(["import", "likes", "--cookies", Self.fakeCookies, "--page-delay", "0"], http: x)
        #expect(r.code == 1, "\(r)")
        #expect(r.out.contains("stopped: ") && r.out.contains("HTTP 403"), "\(r)")
        #expect(try c.open().memes.count() == 0)
        #expect(try Host.staging(c.open()).count() == 0)
    }

    @Test func cookieFlagBeatsTheSavedSession() async throws {
        let c = try await CLICollection()
        let box = try sandbox(), x = try FakeX()
        _ = await CLI.run(["x", "login", "--cookies", "auth_token=FAKE-saved; ct0=FAKE-saved-csrf; twid=u%3D1"], xDir: box.url)
        x.pages = ["": ([], nil)]
        let r = await CLI.run(CLICollection.inject(["import", "likes", "--cookies", Self.fakeCookies, "--page-delay", "0"], c.path), http: x, xDir: box.url)
        #expect(r.ok, "\(r)")
        #expect(x.requests.filter { $0.url.path.contains("/graphql/") }.allSatisfy { $0.headers["cookie"]?.contains("FAKE-auth-0000") == true })
        // …and the saved session is used when no flag is given.
        let r2 = await CLI.run(CLICollection.inject(["import", "likes", "--page-delay", "0", "--fresh"], c.path), http: x, xDir: box.url)
        #expect(r2.ok, "\(r2)")
        #expect(x.requests.last { $0.url.path.contains("/graphql/") }?.headers["cookie"] == "auth_token=FAKE-saved; ct0=FAKE-saved-csrf")
    }

    @Test func importTweetByURLAndLoadItsChain() async throws {
        let c = try await CLICollection()
        let x = try FakeX()
        x.fx = ["11": FakeX.fxTweet("11", text: "the parent"),
                "12": FakeX.fxTweet("12", text: "a reply", replyTo: "11")]
        var r = await c.run(["import", "tweet", "https://x.com/u/status/12", "not-a-tweet", "https://x.com/u/status/99", "--no-archive"], http: x)
        #expect(r.ok, "\(r)")
        #expect(r.out.contains("@u: «a reply»") && r.out.contains("wayback=-"), "\(r)")
        #expect(r.out.contains("✗ not-a-tweet: not a tweet URL") && r.out.contains("✗ https://x.com/u/status/99:"), "\(r)")
        #expect(!x.requests.contains { ($0.url.host ?? "").contains("archive.org") }, "--no-archive")
        #expect(try c.open().memes.count() == 0)

        r = await c.run(["x", "chains"], http: x)
        #expect(r.ok && r.out.contains("loading chains for 1 staged tweets…"), "\(r)")
        #expect(r.out.contains("staged 1 chain tweets; 0 unavailable"), "\(r)")
        #expect(x.requests.contains { $0.url.absoluteString == "https://api.fxtwitter.com/status/11" })
        #expect(try c.open().memes.count() == 0, "chains go to staging too")
        // Chain tweets are hidden from the staging list's top level but committed with their post.
        r = await c.run("stage", "commit", "all")
        #expect(r.ok, "\(r)")
        #expect(try c.open().memes.count() == 2)
    }
    #endif
}
