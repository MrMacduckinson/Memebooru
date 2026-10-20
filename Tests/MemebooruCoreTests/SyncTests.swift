import Foundation
import Testing
@testable import MemebooruCore

@Suite struct OpApplierTests {
    /// Replay A's whole log into B: B ends up with the same memes, tags, assets, relations.
    @Test func replayConverges() throws {
        let a = try TempCollection(), b = try TempCollection()
        let ca = a.collection, cb = b.collection
        let tg = try ca.tags.create("telegram_message", kind: .meta)
        try ca.tags.addAlias("tg_message", to: tg)
        let m1 = Meme(kind: .image, textExact: "обед"), m2 = Meme(kind: .text, textVerbatim: "анекдот")
        try ca.memes.insert(m1, tags: ["stalin", "child", "2022", "tg_message"])
        try ca.memes.insert(m2, tags: ["text"])
        let st = try ca.media.put(data: Data("img".utf8), ext: "jpg")
        try ca.memes.addAsset(Asset(memeID: m1.id, role: .primary, sha256: st.sha256, ext: "jpg", mime: "image/jpeg", width: 10, height: 5, bytes: 3, originalName: "Обед.jpg"))
        try ca.memes.addRelation(Relation(from: m2.id, to: m1.id, kind: .contains, note: "n"))
        try ca.memes.removeTag(m1.id, "child")
        try ca.memes.delete(m2.id)

        let ops = try ca.oplog.ops(missingFrom: [:])
        let r = try OpApplier(collection: cb).apply(ops)
        #expect(r.applied == ops.count && r.failed == 0)

        #expect(try cb.memes.count() == 1)
        #expect(try cb.memes.get(m1.id)?.textExact == "обед")
        let tagsA = try ca.memes.tags(of: m1.id).map(\.name), tagsB = try cb.memes.tags(of: m1.id).map(\.name)
        #expect(tagsA == tagsB && tagsB.sorted() == ["2022", "stalin", "telegram_message"])
        #expect(try cb.tags.resolve("tg_message")?.name == "telegram_message")
        #expect(try cb.tags.get(name: "telegram_message")?.kind == .meta)
        #expect(try cb.memes.get(m2.id)?.deletedAt != nil)
        let asset = try cb.memes.primaryAsset(of: m1.id)
        #expect(asset?.sha256 == st.sha256)
        #expect(asset?.originalName == "Обед.jpg")
        #expect(asset?.width == 10)
        #expect(try cb.memes.relations(of: m1.id).map(\.kind) == [.contains])
        #expect(try OpApplier(collection: cb).missingMedia().map(\.sha256) == [st.sha256])
        #expect(try cb.search.search("stalin").memes.map(\.id) == [m1.id])
        #expect(try cb.search.search("\"обед\"").memes.map(\.id) == [m1.id])

        // idempotent: applying again changes nothing
        let r2 = try OpApplier(collection: cb).apply(ops)
        #expect(r2.duplicate == ops.count && r2.applied == 0)
        // B now holds A's ops → vector knows A's device
        #expect(try cb.oplog.vector()[ca.deviceID] == ops.last?.hlc)
    }

    /// Concurrent edits on both sides; exchange both ways; both converge to the same state.
    @Test func concurrentEditsConverge() throws {
        let a = try TempCollection(), b = try TempCollection()
        let ca = a.collection, cb = b.collection
        let m = Meme(kind: .image, textExact: "v0")
        try ca.memes.insert(m, tags: ["x"])
        _ = try OpApplier(collection: cb).apply(try ca.oplog.ops(missingFrom: [:]))

        // A edits text, adds tag y; B (later) edits text too, removes x, adds z
        var ma = try ca.memes.get(m.id)!; ma.textExact = "from A"; try ca.memes.update(ma)
        try ca.memes.addTag(m.id, "y")
        Thread.sleep(forTimeInterval: 0.002)
        var mb = try cb.memes.get(m.id)!; mb.textExact = "from B"; try cb.memes.update(mb)
        try cb.memes.removeTag(m.id, "x")
        try cb.memes.addTag(m.id, "z")

        // exchange
        _ = try OpApplier(collection: cb).apply(try ca.oplog.ops(missingFrom: try cb.oplog.vector()))
        _ = try OpApplier(collection: ca).apply(try cb.oplog.ops(missingFrom: try ca.oplog.vector()))

        #expect(try ca.memes.get(m.id)?.textExact == "from B")   // later write wins
        #expect(try cb.memes.get(m.id)?.textExact == "from B")
        #expect(try ca.memes.tags(of: m.id).map(\.name) == ["y", "z"])
        #expect(try cb.memes.tags(of: m.id).map(\.name) == ["y", "z"])
        let va = try ca.oplog.vector(), vb = try cb.oplog.vector()
        #expect(va == vb)

        // a stale op arriving late does not undo the newer value
        let stale = Op(opID: UUID().uuidString, deviceID: "ghost", hlc: HLC(wall: 1, counter: 0, device: "ghost"),
                       entity: "meme", entityID: m.id.rawValue, field: "text_exact", value: "old")
        let r = try OpApplier(collection: ca).apply([stale])
        let txt = try ca.memes.get(m.id)?.textExact
        #expect(r.stale == 1 && txt == "from B")
    }

    @Test func deleteWinsOverConcurrentEdit() throws {
        let a = try TempCollection(), b = try TempCollection()
        let m = Meme(kind: .image)
        try a.collection.memes.insert(m)
        _ = try OpApplier(collection: b.collection).apply(try a.collection.oplog.ops(missingFrom: [:]))
        try a.collection.memes.delete(m.id)
        var mb = try b.collection.memes.get(m.id)!; mb.context = "edited after"; try b.collection.memes.update(mb)
        _ = try OpApplier(collection: b.collection).apply(try a.collection.oplog.ops(missingFrom: try b.collection.oplog.vector()))
        _ = try OpApplier(collection: a.collection).apply(try b.collection.oplog.ops(missingFrom: try a.collection.oplog.vector()))
        let na = try a.collection.memes.count(), nb = try b.collection.memes.count()
        #expect(na == 0 && nb == 0)
        #expect(try a.collection.memes.get(m.id)?.context == "edited after") // field kept on the tombstone
    }
}

@Suite struct SyncSessionTests {
    private func seed(_ c: Collection, _ text: String) throws -> MemeID {
        let m = Meme(kind: .image, textExact: text)
        try c.memes.insert(m, tags: [text])
        let st = try c.media.put(data: Data("file-\(text)".utf8), ext: "jpg")
        try c.memes.addAsset(Asset(memeID: m.id, role: .primary, sha256: st.sha256, ext: "jpg", mime: "image/jpeg", bytes: st.bytes))
        return m.id
    }

    @Test func pairThenSyncBothWaysWithMedia() async throws {
        let a = try TempCollection(), b = try TempCollection()
        let ma = try seed(a.collection, "from_a"), mb = try seed(b.collection, "from_b")

        // pairing run: A initiates with the code B displays
        let (ta, tb) = PipeTransport.pair()
        async let ra = SyncSession(collection: a.collection, transport: ta, role: .initiator, pairingCode: "123456").run()
        async let rb = SyncSession(collection: b.collection, transport: tb, role: .responder, acceptCode: "123456").run()
        let (reportA, reportB) = try await (ra, rb)
        #expect(reportA.paired && reportB.paired)
        #expect(reportA.sent > 0 && reportA.received > 0 && reportA.mediaReceived == 1 && reportA.mediaSent == 1)
        let sa = try a.collection.peers.secret(for: b.collection.deviceID), sb = try b.collection.peers.secret(for: a.collection.deviceID)
        #expect(sa != nil && sa == sb)

        for c in [a.collection, b.collection] {
            #expect(try c.memes.count() == 2)
            #expect(try c.search.search("from_a").memes.map(\.id) == [ma])
            #expect(try c.search.search("from_b").memes.map(\.id) == [mb])
            let asset = try c.memes.primaryAsset(of: c === a.collection ? mb : ma)!
            #expect(c.media.exists(sha256: asset.sha256, ext: asset.ext))
            #expect(try OpApplier(collection: c).missingMedia().isEmpty)
        }

        // second run: authenticated with stored secret, nothing new to send
        let (ta2, tb2) = PipeTransport.pair()
        async let ra2 = SyncSession(collection: a.collection, transport: ta2, role: .initiator).run()
        async let rb2 = SyncSession(collection: b.collection, transport: tb2, role: .responder).run()
        let (r2a, r2b) = try await (ra2, rb2)
        #expect(!r2a.paired && r2a.sent == 0 && r2a.received == 0 && r2b.sent == 0)
    }

    @Test func wrongCodeIsRejected() async throws {
        let a = try TempCollection(), b = try TempCollection()
        let (ta, tb) = PipeTransport.pair()
        async let ra: () = { _ = try? await SyncSession(collection: a.collection, transport: ta, role: .initiator, pairingCode: "000000").run() }()
        async let rb: () = { _ = try? await SyncSession(collection: b.collection, transport: tb, role: .responder, acceptCode: "123456").run() }()
        _ = await (ra, rb)
        let pa = try a.collection.peers.all(), pb = try b.collection.peers.all()
        #expect(pa.isEmpty && pb.isEmpty)
    }

    @Test func wrongCodeThrowsTypedErrorForTheGuard() async throws {
        let a = try TempCollection(), b = try TempCollection()
        let (ta, tb) = PipeTransport.pair()
        async let ra: () = { _ = try? await SyncSession(collection: a.collection, transport: ta, role: .initiator, pairingCode: "000000").run() }()
        var responderError: Error?
        do { _ = try await SyncSession(collection: b.collection, transport: tb, role: .responder, acceptCode: "123456").run() }
        catch { responderError = error }
        _ = await ra
        #expect(responderError is WrongPairingCode)
    }

    @Test func closedPairingRejectsEvenTheRightCode() async throws {
        let a = try TempCollection(), b = try TempCollection()
        let (ta, tb) = PipeTransport.pair()
        async let ra: () = { _ = try? await SyncSession(collection: a.collection, transport: ta, role: .initiator, pairingCode: "123456").run() }()
        async let rb: () = { _ = try? await SyncSession(collection: b.collection, transport: tb, role: .responder, acceptCode: nil).run() }()
        _ = await (ra, rb)
        #expect(try b.collection.peers.all().isEmpty)
    }

    @Test func pairingGuardLocksAfterRepeatedFailures() {
        let g = PairingGuard(maxFailures: 3, window: 60)
        #expect(!g.isLocked)
        g.recordFailure(); g.recordFailure()
        #expect(!g.isLocked)
        g.recordFailure()
        #expect(g.isLocked)
        g.reset()
        #expect(!g.isLocked)
    }

    /// Nothing after `hello` is readable on the wire: not the tags, not the pairing code, not the secret.
    @Test func wireIsEncryptedAfterHello() async throws {
        let a = try TempCollection(), b = try TempCollection()
        _ = try seed(a.collection, "very_secret_tag")
        let (ta, tb) = PipeTransport.pair()
        let tap = TapTransport(ta)
        async let ra = SyncSession(collection: a.collection, transport: tap, role: .initiator, pairingCode: "424242").run()
        async let rb = SyncSession(collection: b.collection, transport: tb, role: .responder, acceptCode: "424242").run()
        _ = try await (ra, rb)
        let secret = try #require(try a.collection.peers.secret(for: b.collection.deviceID))
        let wire = tap.frames.dropFirst()          // frame 0 is our hello
        #expect(wire.count > 3)
        for f in wire {
            let text = String(decoding: f, as: UTF8.self)
            #expect(!text.contains("very_secret_tag") && !text.contains("424242") && !text.contains(secret))
        }
        #expect(try b.collection.search.search("very_secret_tag").memes.count == 1)
    }

    @Test func tamperedFrameIsRejected() async throws {
        let a = try TempCollection(), b = try TempCollection()
        _ = try seed(a.collection, "x")
        let (ta, tb) = PipeTransport.pair()
        let evil = TapTransport(ta, corruptFrame: 2)   // flips a bit in our 3rd outgoing frame (after hello)
        async let ra: () = { _ = try? await SyncSession(collection: a.collection, transport: evil, role: .initiator, pairingCode: "1").run() }()
        var responderError: Error?
        do { _ = try await SyncSession(collection: b.collection, transport: tb, role: .responder, acceptCode: "1").run() }
        catch { responderError = error }
        _ = await ra
        #expect(responderError != nil)
        #expect(try b.collection.memes.count() == 0)
    }

    /// Three replicas: A↔B, then B↔C — C gets A's data through B (ops carry their origin).
    @Test func transitiveThroughMiddlePeer() async throws {
        let a = try TempCollection(), b = try TempCollection(), c = try TempCollection()
        let ma = try seed(a.collection, "from_a")
        func sync(_ x: Collection, _ y: Collection) async throws {
            let (tx, ty) = PipeTransport.pair()
            async let rx = SyncSession(collection: x, transport: tx, role: .initiator, pairingCode: "1").run()
            async let ry = SyncSession(collection: y, transport: ty, role: .responder, acceptCode: "1").run()
            _ = try await (rx, ry)
        }
        try await sync(a.collection, b.collection)
        try await sync(b.collection, c.collection)
        #expect(try c.collection.search.search("from_a").memes.map(\.id) == [ma])
        let asset = try c.collection.memes.primaryAsset(of: ma)!
        #expect(c.collection.media.exists(sha256: asset.sha256, ext: asset.ext))
        let va = try a.collection.oplog.vector(), vc = try c.collection.oplog.vector()
        #expect(vc[a.collection.deviceID] == va[a.collection.deviceID])
    }
}

/// Records outgoing frames; optionally corrupts one.
final class TapTransport: PeerTransport, @unchecked Sendable {
    private let inner: PipeTransport
    private let corruptFrame: Int?
    private let lock = NSLock()
    private(set) var frames: [Data] = []
    init(_ inner: PipeTransport, corruptFrame: Int? = nil) { self.inner = inner; self.corruptFrame = corruptFrame }
    func send(_ data: Data) async throws {
        var d = data
        let i = lock.withLock { () -> Int in frames.append(data); return frames.count - 1 }
        if i == corruptFrame, !d.isEmpty { d[d.startIndex] ^= 0x01 }
        try await inner.send(d)
    }
    func receive() async throws -> Data { try await inner.receive() }
    func close() async { await inner.close() }
}
