import Foundation
import Testing
@testable import MemebooruCore

/// Replica convergence: what users see (live memes, text, tags) is equal on both sides after an exchange.
private func exchange(_ a: Collection, _ b: Collection) throws {
    _ = try OpApplier(collection: b).apply(try a.oplog.ops(missingFrom: try b.oplog.vector(), limit: .max))
    _ = try OpApplier(collection: a).apply(try b.oplog.ops(missingFrom: try a.oplog.vector(), limit: .max))
}

private func visible(_ c: Collection) throws -> [MemeSnapshot] {
    try c.snapshot().map { var s = $0; s.assets = []; return s }
}

private func sync(_ a: Collection, _ b: Collection, code: String = "1") async throws -> (SyncReport, SyncReport) {
    let (ta, tb) = PipeTransport.pair()
    async let ra = SyncSession(collection: a, transport: ta, role: .initiator, pairingCode: code).run()
    async let rb = SyncSession(collection: b, transport: tb, role: .responder, acceptCode: code).run()
    return try await (ra, rb)
}

@Suite struct SyncConflictTests {
    @Test func removeThenLaterReAddOfATagKeepsIt() throws {
        let a = try TempCollection(), b = try TempCollection()
        let m = Meme(kind: .image)
        try a.collection.memes.insert(m, tags: ["x"])
        try exchange(a.collection, b.collection)
        try a.collection.memes.removeTag(m.id, "x")
        Thread.sleep(forTimeInterval: 0.003)
        try b.collection.memes.removeTag(m.id, "x")
        try b.collection.memes.addTag(m.id, "x")                 // the latest word: x is on
        try exchange(a.collection, b.collection)
        #expect(try a.collection.memes.tags(of: m.id).map(\.name) == ["x"])
        #expect(try b.collection.memes.tags(of: m.id).map(\.name) == ["x"])
    }

    @Test func addThenLaterRemoveOfATagDropsIt() throws {
        let a = try TempCollection(), b = try TempCollection()
        let m = Meme(kind: .image)
        try a.collection.memes.insert(m)
        try exchange(a.collection, b.collection)
        try a.collection.memes.addTag(m.id, "y")
        try exchange(a.collection, b.collection)
        try a.collection.memes.addTag(m.id, "z")
        Thread.sleep(forTimeInterval: 0.003)
        try b.collection.memes.removeTag(m.id, "y")
        try b.collection.memes.removeTag(m.id, "z")               // z isn't on B yet: nothing to remove, no op
        try exchange(a.collection, b.collection)
        #expect(try a.collection.memes.tags(of: m.id).map(\.name) == ["z"])
        #expect(try b.collection.memes.tags(of: m.id).map(\.name) == ["z"])
    }

    @Test func concurrentEditsOfDifferentFieldsBothSurvive() throws {
        let a = try TempCollection(), b = try TempCollection()
        let m = Meme(kind: .image, textExact: "t0")
        try a.collection.memes.insert(m)
        try exchange(a.collection, b.collection)
        var ma = try #require(try a.collection.memes.get(m.id)); ma.textExact = "from A"
        try a.collection.memes.update(ma)
        var mb = try #require(try b.collection.memes.get(m.id)); mb.context = "from B"
        try b.collection.memes.update(mb)
        try exchange(a.collection, b.collection)
        for c in [a.collection, b.collection] {
            let got = try #require(try c.memes.get(m.id))
            #expect(got.textExact == "from A" && got.context == "from B")
            #expect(try c.ids("\"from a\"") == [m.id] && c.ids("\"from b\"") == [m.id])
        }
    }

    @Test func tagKindConflictIsLastWriterWins() throws {
        let a = try TempCollection(), b = try TempCollection()
        try a.collection.memes.insert(Meme(kind: .image), tags: ["k"])
        try exchange(a.collection, b.collection)
        try a.collection.tags.setKind(try #require(try a.collection.tags.get(name: "k")), .meta)
        Thread.sleep(forTimeInterval: 0.003)
        try b.collection.tags.setKind(try #require(try b.collection.tags.get(name: "k")), .normal)
        try exchange(a.collection, b.collection)
        #expect(try a.collection.tags.get(name: "k")?.kind == .normal)
        #expect(try b.collection.tags.get(name: "k")?.kind == .normal)
    }

    @Test func mergeOnOneSideAbsorbsConcurrentUseOfTheOldNameOnTheOther() throws {
        let a = try TempCollection(), b = try TempCollection()
        let m1 = Meme(kind: .image), m2 = Meme(kind: .image)
        try a.collection.memes.insert(m1, tags: ["iosif", "stalin"])
        try a.collection.memes.insert(m2)
        try exchange(a.collection, b.collection)
        try a.collection.tags.merge(try #require(try a.collection.tags.get(name: "iosif")),
                                    into: try #require(try a.collection.tags.get(name: "stalin")))
        try b.collection.memes.addTag(m2.id, "iosif")             // offline, still the old name
        try exchange(a.collection, b.collection)
        for c in [a.collection, b.collection] {
            #expect(try c.tags.resolve("iosif")?.name == "stalin")
            #expect(try c.memes.tags(of: m2.id).map(\.name) == ["stalin"])
            #expect(Set(try c.ids("iosif")) == [m1.id, m2.id])
        }
        #expect(try visible(a.collection) == visible(b.collection))
    }

    @Test func aliasesSync() throws {
        let a = try TempCollection(), b = try TempCollection()
        let m = Meme(kind: .image)
        try a.collection.memes.insert(m, tags: ["cat"])
        try a.collection.tags.addAlias("кот", to: try #require(try a.collection.tags.get(name: "cat")))
        try exchange(a.collection, b.collection)
        #expect(try b.collection.ids("кот") == [m.id])
        try a.collection.tags.removeAlias("кот")
        try exchange(a.collection, b.collection)
        #expect(try b.collection.tags.resolve("кот") == nil)
    }

    @Test func renameWhileTheOtherSideStillUsesTheOldName() throws {
        let a = try TempCollection(), b = try TempCollection()
        let m1 = Meme(kind: .image), m2 = Meme(kind: .image)
        try a.collection.memes.insert(m1, tags: ["kot"])
        try a.collection.memes.insert(m2)
        try exchange(a.collection, b.collection)
        _ = try a.collection.tags.rename(try #require(try a.collection.tags.get(name: "kot")), to: "cat")
        try b.collection.memes.addTag(m2.id, "kot")               // offline, old name
        try exchange(a.collection, b.collection)
        #expect(try b.collection.memes.tags(of: m1.id).map(\.name) == ["cat"])
        // Known divergence (reported, not fixed: needs tag identity in ops): A has no tag "kot" any more,
        // so B's late "kot" op re-creates it there, while B renamed the tag m2 points at to "cat".
        let va = try visible(a.collection), vb = try visible(b.collection)
        withKnownIssue("rename vs concurrent use of the old name diverges") {
            #expect(va == vb)
        }
    }

    @Test func deleteWinsOverAConcurrentTagAndUndoBringsItBackEverywhere() throws {
        let a = try TempCollection(), b = try TempCollection()
        let m = Meme(kind: .text, textVerbatim: "привет мир")
        try a.collection.memes.insert(m, tags: ["x"])
        try exchange(a.collection, b.collection)
        _ = try a.collection.deleteMemes([m.id])
        try b.collection.memes.addTag(m.id, "y")
        try exchange(a.collection, b.collection)
        for c in [a.collection, b.collection] {
            #expect(try c.memes.count() == 0)
            #expect(try c.ids("x").isEmpty && c.ids("\"привет\"").isEmpty)
            #expect(try c.tags.usage(of: try #require(try c.tags.get(name: "x"))) == 0)
            #expect(try c.tags.rawUsage(of: try #require(try c.tags.get(name: "x"))) == 1)
        }
        _ = try a.collection.undoLast()
        try exchange(a.collection, b.collection)
        for c in [a.collection, b.collection] {
            #expect(try c.ids("\"привет\"") == [m.id])
            #expect(try c.memes.tags(of: m.id).map(\.name) == ["x", "y"])
        }
    }

    @Test func outOfOrderBatchesStillConverge() throws {
        // Ops of one exchange delivered in reverse halves: each batch is sorted, but the later half lands first.
        let a = try TempCollection(), b = try TempCollection(), ref = try TempCollection()
        let m = Meme(kind: .image, textExact: "v1")
        try a.collection.memes.insert(m, tags: ["p"])
        try exchange(a.collection, b.collection)
        try exchange(a.collection, ref.collection)
        var x = try #require(try a.collection.memes.get(m.id))
        for i in 2...6 { x.textExact = "v\(i)"; try a.collection.memes.update(x); try a.collection.memes.addTag(m.id, "t\(i)") }
        try a.collection.memes.removeTag(m.id, "t3")
        let ops = try a.collection.oplog.ops(missingFrom: try b.collection.oplog.vector(), limit: .max)
        let half = ops.count / 2
        _ = try OpApplier(collection: b.collection).apply(Array(ops[half...]))
        _ = try OpApplier(collection: b.collection).apply(Array(ops[..<half]))
        _ = try OpApplier(collection: ref.collection).apply(ops)
        #expect(try visible(b.collection) == visible(ref.collection))
        #expect(try b.collection.memes.get(m.id)?.textExact == "v6")
        #expect(!(try b.collection.memes.tags(of: m.id).map(\.name).contains("t3")))
    }

    @Test(arguments: [3, 99, 2026] as [UInt64])
    func randomConcurrentEditsConverge(seed: UInt64) throws {
        var rng = SeededRNG(seed: seed)
        let a = try TempCollection(), b = try TempCollection()
        var ids: [MemeID] = []
        for i in 0..<8 {
            let m = Meme(kind: .image, createdAt: Int64(i), textExact: "base \(i)")
            try a.collection.memes.insert(m, tags: ["seed"]); ids.append(m.id)
        }
        try exchange(a.collection, b.collection)
        let pool = ["x", "y", "z", "сталин", "🐸"]
        for round in 0..<6 {
            for side in [a.collection, b.collection] {
                for _ in 0..<15 {
                    let known = try ids.filter { try side.memes.get($0) != nil }   // a side only edits what it has
                    let id = known.randomElement(using: &rng)!
                    switch Int.random(in: 0..<6, using: &rng) {
                    case 0: try side.memes.addTag(id, pool.randomElement(using: &rng)!)
                    case 1: try side.memes.removeTag(id, pool.randomElement(using: &rng)!)
                    case 2:
                        var m = try #require(try side.memes.get(id))
                        m.textExact = "r\(round) \(Int.random(in: 0..<100, using: &rng))"
                        try side.memes.update(m)
                    case 3: if try side.memes.get(id)?.deletedAt == nil { try side.memes.delete(id) }
                    case 4: if try side.memes.get(id)?.deletedAt != nil { try side.memes.undelete(id) }
                    default:
                        let m = Meme(kind: .text, textVerbatim: "new r\(round)")
                        try side.memes.insert(m, tags: [pool.randomElement(using: &rng)!]); ids.append(m.id)
                    }
                }
            }
            if Bool.random(using: &rng) { try exchange(a.collection, b.collection) } else { try exchange(b.collection, a.collection) }
            #expect(try visible(a.collection) == visible(b.collection), "round \(round)")
            for q in ["", "x", "-y", "сталин", "🐸 z", "\"base\"", "new"] {
                #expect(try a.collection.ids(q) == b.collection.ids(q), "round \(round) query \(q)")
            }
            #expect(try a.collection.oplog.vector() == b.collection.oplog.vector())
        }
    }
}

@Suite struct SyncSessionEdgeTests {
    @Test func reSyncIsIdempotent() async throws {
        let a = try TempCollection(), b = try TempCollection()
        let m = Meme(kind: .image, textExact: "once")
        try a.collection.memes.insert(m, tags: ["one"])
        let st = try a.collection.media.put(data: Data("pixels".utf8), ext: "png")
        try a.collection.memes.addAsset(Asset(memeID: m.id, role: .primary, sha256: st.sha256, ext: "png", mime: "image/png", bytes: st.bytes))
        let (first, _) = try await sync(a.collection, b.collection)
        #expect(first.sent > 0 && first.mediaSent == 1)
        let opsA = try a.collection.oplog.count(), opsB = try b.collection.oplog.count()
        let snapB = try b.collection.snapshot()
        for _ in 0..<3 {
            let (ta, tb) = PipeTransport.pair()
            async let ra = SyncSession(collection: a.collection, transport: ta, role: .initiator).run()
            async let rb = SyncSession(collection: b.collection, transport: tb, role: .responder).run()
            let (x, y) = try await (ra, rb)
            #expect(x.sent == 0 && x.received == 0 && y.sent == 0 && y.received == 0)
            #expect(x.mediaSent == 0 && x.mediaReceived == 0 && y.mediaSent == 0 && y.mediaReceived == 0)
        }
        #expect(try a.collection.oplog.count() == opsA && b.collection.oplog.count() == opsB)
        #expect(try b.collection.snapshot() == snapB)
        #expect(try a.collection.snapshot() == snapB)
        // Re-applying everything by hand is a no-op too.
        let r = try OpApplier(collection: b.collection).apply(try a.collection.oplog.ops(missingFrom: [:], limit: .max))
        #expect(r.applied == 0 && r.duplicate == r.received)
    }

    @Test func deletesAndUndeletesPropagateOverASession() async throws {
        let a = try TempCollection(), b = try TempCollection()
        let keep = Meme(kind: .text, textVerbatim: "keep me"), drop = Meme(kind: .text, textVerbatim: "drop me")
        try a.collection.memes.insert(keep, tags: ["k"])
        try a.collection.memes.insert(drop, tags: ["k"])
        _ = try await sync(a.collection, b.collection)
        #expect(try b.collection.memes.count() == 2)

        _ = try a.collection.deleteMemes([drop.id])
        let (ta, tb) = PipeTransport.pair()
        async let ra = SyncSession(collection: a.collection, transport: ta, role: .initiator).run()
        async let rb = SyncSession(collection: b.collection, transport: tb, role: .responder).run()
        _ = try await (ra, rb)
        #expect(try b.collection.ids("k") == [keep.id])
        #expect(try b.collection.ids("\"drop\"").isEmpty)
        #expect(try b.collection.memes.get(drop.id)?.deletedAt != nil)

        // B restores it (e.g. from "Recently deleted") — and A follows.
        try b.collection.memes.undelete(drop.id)
        let (ta2, tb2) = PipeTransport.pair()
        async let rb2 = SyncSession(collection: b.collection, transport: tb2, role: .initiator).run()
        async let ra2 = SyncSession(collection: a.collection, transport: ta2, role: .responder).run()
        _ = try await (rb2, ra2)
        #expect(Set(try a.collection.ids("k")) == [keep.id, drop.id])
        #expect(try a.collection.ids("\"drop\"") == [drop.id])
    }

    @Test func manyOpsGoInSeveralChunks() async throws {
        let a = try TempCollection(), b = try TempCollection()
        try a.collection.db.transaction {
            for i in 0..<400 { try a.collection.memes.insert(Meme(kind: .text, createdAt: Int64(i), textVerbatim: "n\(i)"), tags: ["bulk"]) }
        }
        let total = try a.collection.oplog.count()
        #expect(total > 1_000)
        let (ra, rb) = try await sync(a.collection, b.collection)
        #expect(ra.sent == total && rb.received == total && rb.applied == total)
        #expect(try b.collection.ids("bulk").count == 400)
        #expect(try b.collection.ids("bulk") == a.collection.ids("bulk"))
    }

    @Test func conflictingOfflineEditsConvergeAfterOneSession() async throws {
        let a = try TempCollection(), b = try TempCollection()
        let m = Meme(kind: .image, textExact: "v0")
        try a.collection.memes.insert(m, tags: ["shared"])
        _ = try await sync(a.collection, b.collection)
        var ma = try #require(try a.collection.memes.get(m.id)); ma.textExact = "A"; try a.collection.memes.update(ma)
        try a.collection.memes.addTag(m.id, "from_a")
        try await Task.sleep(for: .milliseconds(3))
        var mb = try #require(try b.collection.memes.get(m.id)); mb.textExact = "B"; try b.collection.memes.update(mb)
        try b.collection.memes.removeTag(m.id, "shared")
        let (ta, tb) = PipeTransport.pair()
        async let ra = SyncSession(collection: a.collection, transport: ta, role: .initiator).run()
        async let rb = SyncSession(collection: b.collection, transport: tb, role: .responder).run()
        _ = try await (ra, rb)
        #expect(try visible(a.collection) == visible(b.collection))
        #expect(try a.collection.memes.get(m.id)?.textExact == "B")
        #expect(try a.collection.memes.tags(of: m.id).map(\.name) == ["from_a"])
    }
}

@Suite struct EditSyncTests {
    /// A cropped file and what was done to it reach the other device.
    @Test func editsTravelWithTheirFile() throws {
        let a = try TempCollection(), b = try TempCollection()
        let meme = Meme(kind: .image, presentation: .native)
        try a.collection.memes.insert(meme)
        let edit = MediaEdit(crop: PixelRect(x: 1, y: 2, width: 30, height: 40))
        try a.collection.memes.addAsset(Asset(memeID: meme.id, role: .primary, sha256: String(repeating: "a", count: 64), ext: "png",
                                             mime: "image/png", width: 30, height: 40, bytes: 10, sourceSHA256: String(repeating: "b", count: 64), edit: edit))
        let ops = try a.collection.oplog.ops(missingFrom: [:])
        let r = try OpApplier(collection: b.collection).apply(ops)
        #expect(r.failed == 0)
        #expect(try b.collection.memes.primaryAsset(of: meme.id)?.edit == edit)
    }
}
