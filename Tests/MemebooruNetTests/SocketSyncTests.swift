import Foundation
import Testing
import MemebooruCore
@testable import MemebooruNet
#if canImport(Network)
import MemebooruPlatformApple
#endif

final class TempCollection: @unchecked Sendable {
    let url: URL
    let collection: Collection
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("memebooru-net-\(UUID().uuidString).memebooru")
        collection = try Collection.create(at: url)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

@Suite(.serialized) struct SocketSyncTests {
    @Test func framesRoundTripOverLoopback() async throws {
        let listener = SocketListener()
        let received = AsyncStream<Data>.makeStream()
        try listener.start(port: 0) { t in
            while let d = try? await t.receive() { received.continuation.yield(d); try? await t.send(d + Data("!".utf8)) }
            received.continuation.finish()
        }
        defer { listener.stop() }
        #expect(listener.port != 0)

        let client = try await SocketTransport.connect(host: "127.0.0.1", port: listener.port)
        let big = Data((0..<300_000).map { UInt8($0 & 0xFF) })   // several TCP segments
        for payload in [Data("hello".utf8), Data(), big] {
            try await client.send(payload)
            #expect(try await client.receive() == payload + Data("!".utf8))
        }
        await client.close()
    }

    @Test func connectingToAClosedPortFails() async throws {
        let l = SocketListener()
        try l.start(port: 0) { _ in }
        let port = l.port
        l.stop()
        await #expect(throws: (any Error).self) { _ = try await SocketTransport.connect(host: "127.0.0.1", port: port) }
    }

    /// The real server path: pair over TCP with the displayed code, then sync again with the stored secret.
    @Test func pairAndSyncWithServerOverTCP() async throws {
        let server = try TempCollection(), phone = try TempCollection()
        let m = Meme(kind: .text, textVerbatim: "on the server")
        try server.collection.memes.insert(m, tags: ["vps"])

        let sync = SyncServer(collection: server.collection)
        try sync.start(port: 0)
        defer { sync.stop() }

        let code = sync.pairingCode
        let t1 = try await SocketTransport.connect(host: "localhost", port: sync.port)
        let r1 = try await SyncSession(collection: phone.collection, transport: t1, role: .initiator, pairingCode: code).run()
        #expect(r1.paired && r1.applied > 0)
        #expect(try phone.collection.search.search("vps").memes.map(\.id) == [m.id])
        // Rotates after a successful pairing — once the server side of the session has finished too.
        for _ in 0..<100 where sync.pairingCode == code { try await Task.sleep(for: .milliseconds(10)) }
        #expect(sync.pairingCode != code)

        let t2 = try await SocketTransport.connect(host: "127.0.0.1", port: sync.port)
        let r2 = try await SyncSession(collection: phone.collection, transport: t2, role: .initiator).run()
        #expect(!r2.paired && r2.received == 0)
    }

    @Test func serverLocksPairingAfterWrongCodes() async throws {
        let server = try TempCollection(), attacker = try TempCollection()
        let sync = SyncServer(collection: server.collection)
        try sync.start(port: 0)
        defer { sync.stop() }
        for guess in 0..<sync.pairingGuard.maxFailures {
            let t = try await SocketTransport.connect(host: "127.0.0.1", port: sync.port)
            _ = try? await SyncSession(collection: attacker.collection, transport: t, role: .initiator,
                                       pairingCode: String(format: "%06d", guess)).run()
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(sync.pairingGuard.isLocked)
        // Even the right code is refused while locked.
        let t = try await SocketTransport.connect(host: "127.0.0.1", port: sync.port)
        await #expect(throws: (any Error).self) {
            _ = try await SyncSession(collection: attacker.collection, transport: t, role: .initiator, pairingCode: sync.pairingCode).run()
        }
        #expect(try server.collection.peers.all().isEmpty)
    }

    #if canImport(Network)
    /// The Mac/iPhone app connects with Network.framework; the VPS answers with POSIX sockets.
    @Test func appleClientTalksToPosixServer() async throws {
        let server = try TempCollection(), mac = try TempCollection()
        try server.collection.memes.insert(Meme(kind: .text, textVerbatim: "hi"), tags: ["interop"])
        let sync = SyncServer(collection: server.collection)
        try sync.start(port: 0)
        defer { sync.stop() }
        let r = try await NetworkSync.sync(mac.collection, host: "127.0.0.1", port: sync.port, code: sync.pairingCode)
        #expect(r.paired)
        #expect(try mac.collection.search.search("interop").memes.count == 1)
    }
    #endif
}
