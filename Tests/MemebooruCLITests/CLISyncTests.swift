import Foundation
import Testing
import MemebooruCore
import MemebooruNet
@testable import memebooru

/// `memebooru sync …` against an in-process sync server on an ephemeral loopback port.
@Suite(.serialized) struct CLISyncTests {
    @Test func connectPairsSyncsListsAndForgetsPeers() async throws {
        let serverDir = try TempDir()
        let server = try Collection.create(at: serverDir.url.appendingPathComponent("server.memebooru"))
        try server.renameDevice("VPS сервер")
        let onServer = Meme(kind: .text, textVerbatim: "from the server")
        try server.memes.insert(onServer, tags: ["vps"])
        let sync = SyncServer(collection: server)
        try sync.start(port: 0)
        defer { sync.stop() }

        let c = try await CLICollection()
        let target = "127.0.0.1:\(sync.port)"

        // Unpaired and without a code: refused.
        var r = await c.run("sync", "connect", target)
        #expect(r.code == 1 && !r.err.isEmpty, "\(r)")

        // Wrong code: refused, nothing synced.
        let wrong = sync.pairingCode == "000000" ? "111111" : "000000"
        r = await c.run("sync", "connect", target, "--code", wrong)
        #expect(r.code == 1, "\(r)")
        #expect(try c.open().memes.count() == 0)

        // A meme made with the CLI goes up, the server's comes down.
        let inc = try TempDir()
        try inc.write("a.png", try Samples.png(.vertical))
        _ = await c.run("add", inc.url.path, "-t", "from_cli")
        _ = await c.run("stage", "commit", "all")
        r = await c.run("sync", "connect", target, "--code", sync.pairingCode)
        #expect(r.ok && r.out.hasPrefix("✓ VPS сервер: received ") && r.out.contains("[paired]"), "\(r)")
        r = await c.run("search", "vps")
        #expect(r.out.contains(onServer.id.rawValue), "\(r)")
        #expect(await eventually { (try? server.search.search("from_cli").memes.count) == 1 })
        let synced = try #require(try server.search.search("from_cli").memes.first)
        let media = try #require(try server.memes.primaryAsset(of: synced.id))
        #expect(FileManager.default.fileExists(atPath: server.media.url(sha256: media.sha256, ext: media.ext).path), "media synced too")

        // Paired now: no code needed.
        r = await c.run("sync", "connect", target)
        #expect(r.ok && !r.out.contains("[paired]"), "\(r)")

        r = await c.run("sync", "peers")
        #expect(r.ok && r.out.contains("VPS сервер  [\(server.deviceID)]  last sync: "), "\(r)")
        r = await c.run("sync", "forget", server.deviceID)
        #expect(r.ok && r.out == "forgotten\n", "\(r)")
        r = await c.run("sync", "peers")
        #expect(r.out.isEmpty, "\(r)")
        // Forgotten on this side: the server no longer accepts it without a fresh code.
        r = await c.run("sync", "connect", target)
        #expect(r.code == 1, "\(r)")
    }

    @Test func connectToAClosedPortFails() async throws {
        let l = SocketListener()
        try l.start(port: 0) { _ in }
        let port = l.port
        l.stop()
        let c = try await CLICollection()
        let r = await c.run("sync", "connect", "127.0.0.1:\(port)", "--code", "123456")
        #expect(r.code != 0 && r.out.isEmpty, "\(r)")
    }

    #if !canImport(Network)
    @Test func linuxNeedsHostPort() async throws {
        let c = try await CLICollection()
        let r = await c.run("sync", "connect", "Some Mac")
        #expect(r.code == 64 && r.err.contains("use host:port"), "\(r)")
    }
    #endif

    #if canImport(Network)
    /// `sync listen` until cancelled: prints its port and code, accepts a pairing, then shuts down.
    @Test func listenAcceptsAPairingAndStopsOnCancel() async throws {
        let c = try await CLICollection()
        let live = Locked("")
        let listening = Task { await CLI.run(CLICollection.inject(["sync", "listen", "--no-bonjour"], c.path), live: live) }
        #expect(await eventually { live.value.contains("listening on port") }, "\(live.value)")
        let text = live.value
        let port = try #require(text.firstMatch(of: /listening on port (\d+)/).flatMap { UInt16($0.1) })
        let code = try #require(text.firstMatch(of: /pairing code: (\d{6})/).map { String($0.1) })
        #expect(port != 0)

        let phoneDir = try TempDir()
        let phone = try Collection.create(at: phoneDir.url.appendingPathComponent("phone.memebooru"))
        try phone.memes.insert(Meme(kind: .text, textVerbatim: "from the phone"), tags: ["phone"])
        let t = try await SocketTransport.connect(host: "127.0.0.1", port: port)
        let rep = try await SyncSession(collection: phone, transport: t, role: .initiator, pairingCode: code).run()
        #expect(rep.paired)
        #expect(await eventually { live.value.contains("[paired]") && live.value.components(separatedBy: "pairing code:").count >= 3 }, "\(live.value)")
        #expect(try c.open().ids("phone").count == 1)

        listening.cancel()
        let r = await listening.value
        #expect(r.code != 0, "ends only by cancellation (Ctrl-C): \(r)")
        // The listener is closed once the command returns.
        try await Task.sleep(for: .milliseconds(200))
        await #expect(throws: (any Error).self) {
            let t2 = try await SocketTransport.connect(host: "127.0.0.1", port: port)
            _ = try await SyncSession(collection: phone, transport: t2, role: .initiator).run()
        }
    }
    #endif
}
