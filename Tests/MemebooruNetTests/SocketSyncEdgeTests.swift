import Foundation
import Testing
import MemebooruCore
@testable import MemebooruNet

/// Real TCP against the POSIX server: repeated syncs, deletes both ways, edits racing on two clients.
@Suite(.serialized) struct SocketSyncEdgeTests {
    private func run(_ c: Collection, _ server: SyncServer, code: String? = nil) async throws -> SyncReport {
        let t = try await SocketTransport.connect(host: "127.0.0.1", port: server.port)
        return try await SyncSession(collection: c, transport: t, role: .initiator, pairingCode: code).run()
    }

    private func pair(_ c: Collection, _ server: SyncServer) async throws {
        let code = server.pairingCode
        let r = try await run(c, server, code: code)
        #expect(r.paired)
        for _ in 0..<100 where server.pairingCode == code { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func repeatedSyncsAreIdempotent() async throws {
        let server = try TempCollection(), phone = try TempCollection()
        let m = Meme(kind: .text, textVerbatim: "один раз")
        try server.collection.memes.insert(m, tags: ["once"])
        let st = try server.collection.media.put(data: Data("bytes".utf8), ext: "txt")
        try server.collection.memes.addAsset(Asset(memeID: m.id, role: .primary, sha256: st.sha256, ext: "txt", mime: "text/plain", bytes: st.bytes))
        let sync = SyncServer(collection: server.collection)
        try sync.start(port: 0)
        defer { sync.stop() }
        try await pair(phone.collection, sync)
        let ops = try phone.collection.oplog.count()
        for _ in 0..<3 {
            let r = try await run(phone.collection, sync)
            #expect(r.sent == 0 && r.received == 0 && r.mediaReceived == 0 && r.mediaSent == 0)
        }
        #expect(try phone.collection.oplog.count() == ops)
        #expect(try phone.collection.search.search("once").memes.map(\.id) == [m.id])
        #expect(try phone.collection.peers.all().count == 1)
    }

    @Test func deletesPropagateThroughTheServerToAThirdDevice() async throws {
        let server = try TempCollection(), phone = try TempCollection(), mac = try TempCollection()
        let sync = SyncServer(collection: server.collection)
        try sync.start(port: 0)
        defer { sync.stop() }
        try await pair(phone.collection, sync)
        try await pair(mac.collection, sync)

        let m = Meme(kind: .text, textVerbatim: "удалить меня")
        try phone.collection.memes.insert(m, tags: ["temp"])
        _ = try await run(phone.collection, sync)
        _ = try await run(mac.collection, sync)
        #expect(try mac.collection.search.search("temp").memes.map(\.id) == [m.id])

        _ = try mac.collection.deleteMemes([m.id])
        _ = try await run(mac.collection, sync)
        _ = try await run(phone.collection, sync)
        for c in [server.collection, phone.collection, mac.collection] {
            #expect(try c.memes.count() == 0)
            #expect(try c.search.search("\"удалить\"").memes.isEmpty)
        }
    }

    @Test func twoClientsEditingTheSameMemeConverge() async throws {
        let server = try TempCollection(), phone = try TempCollection(), mac = try TempCollection()
        let sync = SyncServer(collection: server.collection)
        try sync.start(port: 0)
        defer { sync.stop() }
        try await pair(phone.collection, sync)
        try await pair(mac.collection, sync)
        let m = Meme(kind: .image, textExact: "v0")
        try server.collection.memes.insert(m, tags: ["shared"])
        _ = try await run(phone.collection, sync)
        _ = try await run(mac.collection, sync)

        var p = try #require(try phone.collection.memes.get(m.id)); p.textExact = "phone"; try phone.collection.memes.update(p)
        try phone.collection.memes.addTag(m.id, "from_phone")
        try await Task.sleep(for: .milliseconds(3))
        var x = try #require(try mac.collection.memes.get(m.id)); x.textExact = "mac"; try mac.collection.memes.update(x)
        try mac.collection.memes.removeTag(m.id, "shared")
        async let r1 = run(phone.collection, sync)
        async let r2 = run(mac.collection, sync)
        _ = try await (r1, r2)
        _ = try await run(phone.collection, sync)
        _ = try await run(mac.collection, sync)
        for c in [server.collection, phone.collection, mac.collection] {
            #expect(try c.memes.get(m.id)?.textExact == "mac")
            #expect(try c.memes.tags(of: m.id).map(\.name) == ["from_phone"])
        }
    }
}
