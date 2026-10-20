import ArgumentParser
import Foundation
import MemebooruCore

/// Stores the x.com session per-device (never inside the collection folder — it must not sync).
enum XSessionStore {
    /// Test seam: keep the session files in this folder instead of the user's Application Support.
    @TaskLocal static var directoryOverride: URL?

    static var fileURL: URL {
        let dir = directoryOverride ?? (
            (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
                ?? FileManager.default.homeDirectoryForCurrentUser
        ).appendingPathComponent("Memebooru", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("x-session.json")
    }

    static func save(_ s: XSession) throws {
        try JSONEncoder().encode(s).write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
    static func load() -> XSession? {
        (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode(XSession.self, from: $0) }
    }
    static func clear() { try? FileManager.default.removeItem(at: fileURL) }

    static var endpointsURL: URL { fileURL.deletingLastPathComponent().appendingPathComponent("x-endpoints.json") }
    static func saveEndpoints(_ o: XEndpointOverride) {
        // merge with existing so a partial discovery keeps earlier ids
        var merged = loadEndpoints() ?? XEndpointOverride()
        if let v = o.likes { merged.likes = v }
        if let v = o.bookmarks { merged.bookmarks = v }
        if let v = o.userByScreenName { merged.userByScreenName = v }
        merged.updatedAt = o.updatedAt
        try? JSONEncoder().encode(merged).write(to: endpointsURL, options: .atomic)
    }
    static func loadEndpoints() -> XEndpointOverride? {
        (try? Data(contentsOf: endpointsURL)).flatMap { try? JSONDecoder().decode(XEndpointOverride.self, from: $0) }
    }
    static func endpoints() -> XEndpoints {
        var e = XEndpoints.standard()
        if let o = loadEndpoints() { e.apply(o) }
        return e
    }

    /// Resolution order: explicit cookie header → env → saved file.
    static func resolve(cookieHeader: String?) -> XSession? {
        if let h = cookieHeader, let s = XSession.fromCookieHeader(h) { return s }
        let env = ProcessInfo.processInfo.environment
        if let h = env["X_COOKIES"], let s = XSession.fromCookieHeader(h) { return s }
        if let a = env["X_AUTH_TOKEN"], let c = env["X_CSRF"] { return XSession(authToken: a, csrf: c, userID: env["X_USER_ID"]) }
        return load()
    }
}

struct X: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "x", abstract: "x.com session for importing your likes and bookmarks.",
        subcommands: [Login.self, Logout.self, Whoami.self, Qid.self, Dump.self, Restage.self, Chains.self, Reparse.self])

    struct Restage: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Move tweets from the collection back to staging (files copied, nothing downloaded; one undo step).")
        @OptionGroup var collection: CollectionOption
        @Option(name: .long, help: "Only tweets with this tag (e.g. liked).") var tag: String

        func run() throws {
            let c = try collection.open()
            let area = Host.staging(c)
            let ids = try c.search.search(tag, limit: 1_000_000).memes.filter { $0.kind == .tweet }.map(\.id)
            print("moving \(ids.count) tweets tagged \(tag) to staging…")
            let staged = try c.restageTweets(ids, into: area) { n in if n % 500 == 0 { print("  \(n)") } }
            print("staged \(staged.count). Undo: memebooru undo")
        }
    }

    struct Chains: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Fetch the chains (what they reply to and quote) of staged tweets that don't have them yet.")
        @OptionGroup var collection: CollectionOption

        func run() async throws {
            #if canImport(ImageIO)
            let c = try collection.open()
            let area = Host.staging(c)
            let http = Host.platform().http
            let items = try area.list().filter { $0.kind == .tweet }
            print("loading chains for \(items.count) staged tweets…")
            let r = try await area.loadChains(for: items, source: FxTwitterSource(http: http), http: http) { done, chain, missing in
                if done % 60 == 0 { print("  \(done) checked: +\(chain) chain tweets, \(missing) unavailable") }
            }
            print("staged \(r.chain) chain tweets; \(r.missing) unavailable (deleted or protected)")
            #else
            throw ValidationError("not supported on this platform")
            #endif
        }
    }

    struct Reparse: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Re-read staged tweets' saved JSON with the current text rules.")
        @OptionGroup var collection: CollectionOption
        func run() throws {
            let c = try collection.open()
            print("updated \(try Host.staging(c).reparseTweets()) staged tweets")
        }
    }

    struct Login: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Save cookies from a logged-in x.com session.",
            discussion: "In your browser: DevTools → Application → Cookies → x.com. Copy auth_token and ct0.")
        @Option(name: .long, help: "Full Cookie header (auth_token=…; ct0=…; twid=…).") var cookies: String?
        @Option(name: .long) var authToken: String?
        @Option(name: .long, help: "ct0 cookie value.") var csrf: String?
        @Option(name: .long) var userID: String?
        func run() throws {
            let session: XSession?
            if let cookies { session = XSession.fromCookieHeader(cookies) }
            else if let authToken, let csrf { session = XSession(authToken: authToken, csrf: csrf, userID: userID) }
            else { throw ValidationError("pass --cookies \"auth_token=…; ct0=…\" or --auth-token … --csrf …") }
            guard let session else { throw ValidationError("could not find auth_token and ct0 in the input") }
            try XSessionStore.save(session)
            print("saved x.com session\(session.userID.map { " (user \($0))" } ?? "")")
        }
    }

    struct Qid: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Set/inspect GraphQL query ids (from the browser Network tab).",
            discussion: "In the browser, open your Likes/Bookmarks, find the request .../graphql/<ID>/Likes and copy <ID>.")
        @Option(name: .long) var likes: String?
        @Option(name: .long) var bookmarks: String?
        @Option(name: .long) var user: String?
        @Flag(name: .long, help: "Discover automatically from x.com (needs a saved session).") var discover = false
        func run() throws {
            if likes != nil || bookmarks != nil || user != nil {
                XSessionStore.saveEndpoints(XEndpointOverride(likes: likes, bookmarks: bookmarks, userByScreenName: user, updatedAt: Int64(Date().timeIntervalSince1970 * 1000)))
            }
            if discover { throw CleanExit.message("run `memebooru x whoami` — discovery happens automatically on the next import") }
            let e = XSessionStore.endpoints()
            print("Likes:            \(e.likes)\nBookmarks:        \(e.bookmarks)\nUserByScreenName: \(e.userByScreenName)")
        }
    }

    struct Logout: ParsableCommand {
        func run() throws { XSessionStore.clear(); print("cleared") }
    }

    struct Dump: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Write the raw first page of likes/bookmarks JSON to a file (debug).")
        @Argument(help: "likes | bookmarks") var feed: String
        @Option(name: .long) var out: String = "x-dump.json"
        func run() async throws {
            #if canImport(ImageIO)
            guard let s = XSessionStore.load() else { throw ValidationError("run `memebooru x login` first") }
            guard let f = XImporter.Feed(rawValue: feed) else { throw ValidationError("feed must be likes or bookmarks") }
            var client = XClient(http: Host.platform().http, session: s, endpoints: XSessionStore.endpoints())
            client.onEndpointsDiscovered = { XSessionStore.saveEndpoints($0) }
            let data = try await client.rawPage(f)
            try data.write(to: URL(fileURLWithPath: out))
            print("wrote \(data.count) bytes to \(out)")
            #else
            throw ValidationError("unsupported")
            #endif
        }
    }

    struct Whoami: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Check the saved session.")
        func run() async throws {
            #if canImport(ImageIO)
            guard let s = XSessionStore.load() else { print("no saved session — run `memebooru x login`"); return }
            var client = XClient(http: Host.platform().http, session: s, endpoints: XSessionStore.endpoints())
            client.onEndpointsDiscovered = { XSessionStore.saveEndpoints($0) }
            let id: String
            do { id = try await client.resolveUserID() }
            catch is XQueryOutdated { _ = try? await client.discoverEndpoints(); id = try await client.resolveUserID() }
            print("logged in, user id \(id)")
            #else
            print("not supported on this platform")
            #endif
        }
    }
}

struct ImportX: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "likes", abstract: "Import your x.com likes straight into the collection.")
    @OptionGroup var options: XImportOptions
    func run() async throws { try await runImport(.likes, options) }
}

struct ImportBookmarks: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "bookmarks", abstract: "Import your x.com bookmarks straight into the collection.")
    @OptionGroup var options: XImportOptions
    func run() async throws { try await runImport(.bookmarks, options) }
}

struct XImportOptions: ParsableArguments {
    @OptionGroup var collection: CollectionOption
    @Option(name: .shortAndLong, help: "Max new tweets to import (0 = all).") var limit: Int = 100
    @Option(name: .long, parsing: .upToNextOption, help: "Extra tags for each imported tweet.") var tags: [String] = []
    @Option(name: .long, help: "Cookie header override (else env or saved session).") var cookies: String?
    @Flag(name: .long, help: "Start from the newest instead of resuming an interrupted import.") var fresh = false
    @Option(name: .long, help: "Seconds between timeline pages (default 2).") var pageDelay: Int = 2
}

private func runImport(_ feed: XImporter.Feed, _ o: XImportOptions) async throws {
    #if canImport(ImageIO)
    guard let session = XSessionStore.resolve(cookieHeader: o.cookies) else {
        throw ValidationError("no x.com session — run `memebooru x login --cookies \"auth_token=…; ct0=…\"`")
    }
    let c = try o.collection.open()
    let staging = Host.staging(c)
    let http = Host.platform().http
    var client = XClient(http: http, session: session, endpoints: XSessionStore.endpoints())
    client.onEndpointsDiscovered = { XSessionStore.saveEndpoints($0) }
    var importer = XImporter(staging: staging, client: client, http: http)
    let extra = o.tags + [feed == .likes ? "liked" : "bookmarked"]
    var pace = XImporter.Pace()
    pace.pageDelay = .seconds(max(0, o.pageDelay))
    if let resume = try c.xCursor(feed.rawValue), !o.fresh, !resume.isEmpty { print("resuming the interrupted import (--fresh to start over)") }
    let result = await Result {
        try await importer.importFeed(feed, limit: o.limit, extraTags: extra, resume: !o.fresh, pace: pace, onProgress: { p in
            if let until = p.waitingUntil {
                print("  x.com rate limit — waiting until \(until.formatted(date: .omitted, time: .standard))")
            } else {
                print("  page \(p.pages): \(p.staged) staged, +\(p.chain) chain, \(p.skipped) already here, \(megabytes(p.bytes))")
            }
        })
    }
    switch result {
    case .success(let p):
        var line = "\(feed.rawValue): \(p.staged) staged (+\(p.chain) chain tweets), \(p.skipped) already here, \(p.pages) pages, \(megabytes(p.bytes))"
        if p.chainMissing > 0 { line += "; \(p.chainMissing) chain tweets unavailable (deleted or protected)" }
        if p.promoted > 0 { line += "; \(p.promoted) chain tweets became posts" }
        if p.mediaMissing > 0 { line += "; \(p.mediaMissing) without some media (download failed)" }
        if p.caughtUp { line += " — up to date" }
        print(line)
        if p.staged > 0 { print("Review them: memebooru stage ls") }
    case .failure(let e):
        print("stopped: \(e)")
        if try c.xCursor(feed.rawValue) != nil { print("Run the same command again to continue where it stopped.") }
        throw ExitCode.failure
    }
    #else
    throw ValidationError("x.com import is not supported on this platform")
    #endif
}

private func megabytes(_ b: Int64) -> String { String(format: "%.1f MB", Double(b) / 1_048_576) }
