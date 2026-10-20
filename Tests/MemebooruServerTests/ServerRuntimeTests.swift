import Foundation
import Testing
@testable import MemebooruBot
import MemebooruCore
import MemebooruNet
@testable import memebooru_server

// The server's running parts in-process: sync listener on an ephemeral localhost port, Wayback worker
// and the Telegram bot against fakes. No network beyond loopback; api.telegram.org is never contacted.

final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock(); private var v: T
    init(_ v: T) { self.v = v }
    var value: T { lock.withLock { v } }
    func mutate(_ f: (inout T) -> Void) { lock.withLock { f(&v) } }
}

final class TempCollection: @unchecked Sendable {
    let url: URL
    let collection: Collection
    init(_ name: String = "server") throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("mb-\(name) \(UUID().uuidString).memebooru")
        collection = try Collection.create(at: url)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

/// Scripted HTTP: answers by URL prefix, records everything, and fails anything unscripted.
final class FakeHTTP: HTTPClient, @unchecked Sendable {
    struct Unscripted: Error { let url: URL }
    let requests = Locked<[URL]>([])
    let routes: [(prefix: String, response: HTTPResponse)]
    init(_ routes: [(String, HTTPResponse)] = []) { self.routes = routes.map { (prefix: $0.0, response: $0.1) } }
    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        requests.mutate { $0.append(url) }
        guard let r = routes.first(where: { url.absoluteString.hasPrefix($0.prefix) }) else { throw Unscripted(url: url) }
        return r.response
    }
}

struct NoMedia: ImageDecoder, VideoProbe, ThumbnailEncoder {
    struct Unsupported: Error {}
    func decode(_ url: URL, maxSide: Int) throws -> Bitmap { throw Unsupported() }
    func imageSize(_ url: URL) throws -> (width: Int, height: Int) { throw Unsupported() }
    func durationMs(_ url: URL) throws -> Int64 { throw Unsupported() }
    func frame(_ url: URL, at fraction: Double, maxSide: Int) throws -> Bitmap { throw Unsupported() }
    func jpeg(_ bitmap: Bitmap, quality: Double) throws -> Data { throw Unsupported() }
    func encode(_ bitmap: Bitmap, as format: MediaFormat, quality: Double) throws -> Data? { nil }
}

func fakePlatform(_ http: any HTTPClient) -> Platform {
    Platform(images: NoMedia(), video: NoMedia(), thumbs: NoMedia(), http: http)
}

/// Telegram double: serves queued updates once, then idles like an empty long poll.
final class FakeTelegram: TelegramAPI, @unchecked Sendable {
    let pending: Locked<[TGUpdate]>
    let sent = Locked<[(chat: Int64, text: String)]>([])
    let commands = Locked<[TGCommand]>([])
    let polls = Locked(0)
    init(_ updates: [TGUpdate]) { pending = Locked(updates) }

    func getUpdates(offset: Int64?, timeout: Int) async throws -> [TGUpdate] {
        polls.mutate { $0 += 1 }
        var batch: [TGUpdate] = []
        pending.mutate { batch = $0.filter { offset == nil || $0.updateId >= offset! }; $0 = [] }
        if batch.isEmpty { try? await Task.sleep(for: .milliseconds(20)) }
        return batch
    }
    func sendMessage(chatID: Int64, text: String, replyTo: Int?) async throws -> TGMessage {
        sent.mutate { $0.append((chatID, text)) }
        return TGMessage(messageId: Int.random(in: 1...1_000_000), from: nil, chat: TGChat(id: chatID, type: "private", title: nil, username: nil), date: 0, text: text)
    }
    func sendMedia(_ kind: TGMediaKind, chatID: Int64, file: URL, silent: Bool) async throws -> TGMessage { throw TelegramError("no uploads in tests") }
    func deleteMessage(chatID: Int64, messageID: Int) async throws {}
    func answerInlineQuery(id: String, results: [TGInlineResult], nextOffset: String?, cacheTime: Int, emptyButton: String?) async throws {}
    func setCommands(_ commands: [TGCommand]) async throws { self.commands.mutate { $0 = commands } }
    func getFile(fileID: String) async throws -> TGFile { throw TelegramError("no files") }
    func download(filePath: String) async throws -> Data { throw TelegramError("no files") }
}

func message(_ id: Int64, from user: Int64, _ text: String) -> TGUpdate {
    TGUpdate(updateId: id, message: TGMessage(messageId: Int(id), from: TGUser(id: user, firstName: "U\(user)", username: nil),
                                              chat: TGChat(id: user, type: "private", title: nil, username: nil), date: 0, text: text))
}

func eventually(_ timeout: Duration = .seconds(5), _ condition: () throws -> Bool) async rethrows -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return try condition()
}

func settings(_ path: URL, token: String? = nil, allowed: Set<Int64> = [], wayback: Bool = false) -> ServerSettings {
    ServerSettings(collectionPath: path.path, syncPort: 0, deviceName: "test-server", wayback: wayback, botToken: token,
                   allowedUsers: allowed, cacheChat: nil, apiBase: URL(string: "http://127.0.0.1:9/never-used")!, warm: false)
}

@Suite(.serialized) struct ServerRuntimeTests {
    static let fakeToken = "000000:TEST-not-a-real-token"

    @Test func syncOnlyServerSyncsTwoCollectionsAndShutsDown() async throws {
        let server = try TempCollection("srv"), mac = try TempCollection("mac"), phone = try TempCollection("phone")
        let log = Locked<[String]>([])
        let http = FakeHTTP()
        let rt = try ServerRuntime.start(settings(server.url), collection: server.collection, platform: fakePlatform(http),
                                         telegram: { _, _ in Issue.record("no token, no bot"); return FakeTelegram([]) },
                                         log: { l in log.mutate { $0.append(l) } })
        #expect(rt.bot == nil)
        let port = rt.sync.port
        #expect(port != 0 && port != 7300)
        #expect(log.value.contains { $0.contains("sync: listening on port \(port); pairing code \(rt.sync.pairingCode)") })
        #expect(log.value.contains("telegram: no TELEGRAM_BOT_TOKEN — running sync only"))
        #expect(log.value.contains { $0.hasPrefix("collection \(server.url.path) — 0 posts") })

        let serving = Task { await rt.serve() }

        // The Mac pairs and uploads a meme…
        let fromMac = Meme(kind: .text, textVerbatim: "from the mac")
        try mac.collection.memes.insert(fromMac, tags: ["мак"])
        let t1 = try await SocketTransport.connect(host: "127.0.0.1", port: port)
        let r1 = try await SyncSession(collection: mac.collection, transport: t1, role: .initiator, pairingCode: rt.sync.pairingCode).run()
        #expect(r1.paired && r1.sent > 0)
        #expect(await eventually { (try? server.collection.search.search("мак").memes.count) == 1 })

        // …the phone pairs with the rotated code, gets it, and adds its own…
        let fromPhone = Meme(kind: .text, textVerbatim: "from the phone")
        try phone.collection.memes.insert(fromPhone, tags: ["phone"])
        let t2 = try await SocketTransport.connect(host: "localhost", port: port)
        let r2 = try await SyncSession(collection: phone.collection, transport: t2, role: .initiator, pairingCode: rt.sync.pairingCode).run()
        #expect(r2.paired && r2.applied > 0)
        #expect(try phone.collection.search.search("мак").memes.map(\.id) == [fromMac.id])

        // …and the Mac, already paired, syncs again without a code and receives it.
        let t3 = try await SocketTransport.connect(host: "127.0.0.1", port: port)
        let r3 = try await SyncSession(collection: mac.collection, transport: t3, role: .initiator).run()
        #expect(!r3.paired && r3.applied > 0)
        #expect(try mac.collection.search.search("phone").memes.map(\.id) == [fromPhone.id])
        #expect(try Set(server.collection.peers.all().map(\.id)) == [mac.collection.deviceID, phone.collection.deviceID])
        #expect(await eventually { log.value.filter { $0.hasPrefix("sync: ✓") }.count == 3 })

        // Shutdown: the serve task ends on cancel, the port stops accepting.
        serving.cancel()
        await serving.value
        rt.stop()
        await #expect(throws: (any Error).self) {
            let t = try await SocketTransport.connect(host: "127.0.0.1", port: port)
            _ = try await SyncSession(collection: mac.collection, transport: t, role: .initiator).run()
        }
        #expect(http.requests.value.isEmpty, "wayback is off: no HTTP at all")
    }

    @Test func wrongPairingCodeIsLoggedAndRejected() async throws {
        let server = try TempCollection("srv"), stranger = try TempCollection("x")
        let log = Locked<[String]>([])
        let rt = try ServerRuntime.start(settings(server.url), collection: server.collection, platform: fakePlatform(FakeHTTP()),
                                         log: { l in log.mutate { $0.append(l) } })
        defer { rt.stop() }
        let wrong = rt.sync.pairingCode == "000000" ? "111111" : "000000"
        let t = try await SocketTransport.connect(host: "127.0.0.1", port: rt.sync.port)
        await #expect(throws: (any Error).self) {
            _ = try await SyncSession(collection: stranger.collection, transport: t, role: .initiator, pairingCode: wrong).run()
        }
        #expect(await eventually { log.value.contains { $0.hasPrefix("sync: ✗") } })
        #expect(try server.collection.peers.all().isEmpty)
    }

    @Test func twoServersCannotShareAPort() async throws {
        let a = try TempCollection("a"), b = try TempCollection("b")
        let rt = try ServerRuntime.start(settings(a.url), collection: a.collection, platform: fakePlatform(FakeHTTP()), log: { _ in })
        defer { rt.stop() }
        var s = settings(b.url)
        s.syncPort = rt.sync.port
        #expect(throws: (any Error).self) {
            _ = try ServerRuntime.start(s, collection: b.collection, platform: fakePlatform(FakeHTTP()), log: { _ in })
        }
    }

    @Test func botAnswersThroughTheInjectedTelegramAPI() async throws {
        let server = try TempCollection("bot")
        try server.collection.memes.insert(Meme(kind: .text, textVerbatim: "hello"), tags: ["greeting"])
        let tg = FakeTelegram([
            message(1, from: 42, "/code"),
            message(2, from: 99, "hi, who are you?"),       // a stranger
            message(3, from: 42, "/stats"),
        ])
        let made = Locked<[(String, URL)]>([])
        let log = Locked<[String]>([])
        let rt = try ServerRuntime.start(settings(server.url, token: Self.fakeToken, allowed: [42]), collection: server.collection,
                                         platform: fakePlatform(FakeHTTP()),
                                         telegram: { token, base in made.mutate { $0.append((token, base)) }; return tg },
                                         log: { l in log.mutate { $0.append(l) } })
        #expect(rt.bot != nil)
        #expect(made.value.count == 1 && made.value.first?.0 == Self.fakeToken && made.value.first?.1.host == "127.0.0.1")
        #expect(log.value.contains("telegram: bot running for 1 user(s)"))
        #expect(!log.value.contains { $0.contains("TELEGRAM_ALLOWED_USERS is empty") })

        let serving = Task { await rt.serve() }
        #expect(await eventually { tg.sent.value.count >= 3 }, "\(tg.sent.value)")
        serving.cancel()
        await serving.value
        rt.stop()

        #expect(tg.commands.value == MemeBot.commands)
        let sent = tg.sent.value
        let code = try #require(sent.first { $0.chat == 42 })
        #expect(code.text.contains("(port \(rt.sync.port))"), "\(code.text)")
        #expect(sent.contains { $0.chat == 99 && $0.text == "This bot is private. Your Telegram id is 99." })
        #expect(sent.filter { $0.chat == 42 }.count == 2)
        #expect(!sent.contains { $0.text.contains(Self.fakeToken) })
    }

    @Test func botWithNoAllowedUsersWarnsAndAnswersNobody() async throws {
        let server = try TempCollection("bot")
        let tg = FakeTelegram([message(1, from: 42, "/stats")])
        let log = Locked<[String]>([])
        let rt = try ServerRuntime.start(settings(server.url, token: Self.fakeToken), collection: server.collection,
                                         platform: fakePlatform(FakeHTTP()), telegram: { _, _ in tg },
                                         log: { l in log.mutate { $0.append(l) } })
        #expect(log.value.contains { $0.contains("TELEGRAM_ALLOWED_USERS is empty") })
        #expect(log.value.contains("telegram: bot running for 0 user(s)"))
        let serving = Task { await rt.serve() }
        #expect(await eventually { !tg.sent.value.isEmpty })
        serving.cancel(); await serving.value; rt.stop()
        #expect(tg.sent.value.map(\.text) == ["This bot is private. Your Telegram id is 42."])
    }

    @Test func botSurvivesTelegramErrorsUntilCancelled() async throws {
        final class Flaky: TelegramAPI, @unchecked Sendable {
            let calls = Locked(0)
            func getUpdates(offset: Int64?, timeout: Int) async throws -> [TGUpdate] {
                calls.mutate { $0 += 1 }
                throw TelegramError("Unauthorized", retryAfter: 0)
            }
            func sendMessage(chatID: Int64, text: String, replyTo: Int?) async throws -> TGMessage { throw TelegramError("no") }
            func sendMedia(_ kind: TGMediaKind, chatID: Int64, file: URL, silent: Bool) async throws -> TGMessage { throw TelegramError("no") }
            func deleteMessage(chatID: Int64, messageID: Int) async throws {}
            func answerInlineQuery(id: String, results: [TGInlineResult], nextOffset: String?, cacheTime: Int, emptyButton: String?) async throws {}
            func setCommands(_ commands: [TGCommand]) async throws { throw TelegramError("Unauthorized") }
            func getFile(fileID: String) async throws -> TGFile { throw TelegramError("no") }
            func download(filePath: String) async throws -> Data { throw TelegramError("no") }
        }
        let server = try TempCollection("bot")
        let api = Flaky()
        let log = Locked<[String]>([])
        let rt = try ServerRuntime.start(settings(server.url, token: Self.fakeToken, allowed: [1]), collection: server.collection,
                                         platform: fakePlatform(FakeHTTP()), telegram: { _, _ in api },
                                         log: { l in log.mutate { $0.append(l) } })
        let serving = Task { await rt.serve() }
        #expect(await eventually { api.calls.value >= 3 })
        serving.cancel(); await serving.value; rt.stop()
        #expect(log.value.contains { $0.contains("setMyCommands failed") })
        #expect(log.value.contains { $0.contains("Unauthorized — retrying in 0s") })
        // The sync side kept working all along.
        #expect(rt.sync.port != 0)
    }

    @Test func waybackWorkerArchivesQueuedTweetsThroughThePlatformHTTP() async throws {
        let server = try TempCollection("wb")
        let tweetURL = "https://x.com/u/status/123"
        let meme = Meme(kind: .tweet, payload: .tweet(TweetPayload(tweetID: "123", url: tweetURL, authorName: "U", handle: "u")))
        try server.collection.memes.insert(meme, tags: ["t"])
        try server.collection.wayback.enqueue(meme.id, url: tweetURL)
        let snapshot = "https://web.archive.org/web/2024/\(tweetURL)"
        let http = FakeHTTP([("https://archive.org/wayback/available",
                              HTTPResponse(status: 200, headers: [:], body: try JSONSerialization.data(withJSONObject:
                                ["archived_snapshots": ["closest": ["url": snapshot]]])))])
        let log = Locked<[String]>([])
        let rt = try ServerRuntime.start(settings(server.url, wayback: true), collection: server.collection,
                                         platform: fakePlatform(http), log: { l in log.mutate { $0.append(l) } })
        defer { rt.stop() }
        #expect(log.value.contains("wayback: 1 tweet(s) queued") || log.value.contains("wayback: \(meme.id) \(snapshot)"))
        #expect(await eventually { log.value.contains("wayback: \(meme.id) \(snapshot)") }, "\(log.value)")
        guard case .tweet(let p) = try #require(try server.collection.memes.get(meme.id)).payload else { Issue.record("not a tweet"); return }
        #expect(p.waybackURL == snapshot)
        #expect(try server.collection.wayback.pendingCount() == 0)
        #expect(http.requests.value.allSatisfy { $0.host == "archive.org" })
    }

    @Test func waybackOffLeavesTheQueueAlone() async throws {
        let server = try TempCollection("wb")
        let meme = Meme(kind: .tweet, payload: .tweet(TweetPayload(tweetID: "5", url: "https://x.com/u/status/5", authorName: "U", handle: "u")))
        try server.collection.memes.insert(meme, tags: [])
        try server.collection.wayback.enqueue(meme.id, url: "https://x.com/u/status/5")
        let http = FakeHTTP()
        let rt = try ServerRuntime.start(settings(server.url, wayback: false), collection: server.collection, platform: fakePlatform(http), log: { _ in })
        try await Task.sleep(for: .milliseconds(200))
        rt.stop()
        #expect(http.requests.value.isEmpty)
        #expect(try server.collection.wayback.pendingCount() == 1)
    }

}
