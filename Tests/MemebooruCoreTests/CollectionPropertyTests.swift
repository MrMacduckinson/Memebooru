import Foundation
import Testing
@testable import MemebooruCore

/// Seeded random sequences of add / tag / untag / edit / delete / commit / undo / restore against a
/// plain in-memory model. After every step the collection must agree with the model.
@Suite struct CollectionPropertyTests {
    static let tagPool = ["stalin", "сталин", "🐸", "@durov", "2022", "source_unknown", "cat", "ussr_flag", "a_b", "100%", "chain"]
    /// What users type → the canonical tag (case folding, aliases).
    static let spellings: [String: String] = ["STALIN": "stalin", "Кот": "cat", "neko": "cat", "Сталин": "сталин", "@DUROV": "@durov"]
    static let words = ["обед", "ужин", "штирлиц", "plan", "мем", "zebra", "ёж"]

    struct M {
        var live = true
        var tags: Set<String> = []
        var textExact: String?
        var textVerbatim: String?
        var createdAt: Int64
        var words: Set<String> {
            Set([textExact, textVerbatim].compactMap { $0 }.flatMap { $0.split(separator: " ").map(String.init) })
        }
    }
    struct Batch { var isDelete: Bool; var ids: [MemeID]; var restored: Set<Int> = []; var undone = false }

    struct Model {
        var memes: [MemeID: M] = [:]
        var order: [MemeID] = []
        var batches: [Batch] = []
        var visibleByDefault: [MemeID] {                    // newest first, chain hidden
            order.filter { memes[$0]!.live && !memes[$0]!.tags.contains("chain") }
                .sorted { (memes[$0]!.createdAt, $0.rawValue) > (memes[$1]!.createdAt, $1.rawValue) }
        }
    }

    @Test(arguments: [1, 7, 42, 1337, 20_261_009] as [UInt64])
    func randomOperationsKeepInvariants(seed: UInt64) throws {
        var rng = SeededRNG(seed: seed)
        let t = try TempCollection()
        let c = t.collection
        for name in Self.tagPool { try c.tags.ensure(name) }
        try c.tags.addAlias("Кот", to: try #require(try c.tags.resolve("cat")))
        try c.tags.addAlias("neko", to: try #require(try c.tags.resolve("cat")))
        var model = Model()
        var clock: Int64 = 1_000
        var lastBatchSnapshot: (batch: Int, snapshot: [MemeSnapshot])?

        func randomText() -> String? {
            Bool.random(using: &rng) ? nil : (0..<Int.random(in: 1...3, using: &rng)).map { _ in Self.words.randomElement(using: &rng)! }.joined(separator: " ")
        }
        func randomSpelling() -> (typed: String, canonical: String) {
            if Int.random(in: 0..<4, using: &rng) == 0, let s = Self.spellings.randomElement(using: &rng) { return (s.key, s.value) }
            let n = Self.tagPool.randomElement(using: &rng)!
            return (n, n)
        }
        func anyMeme() -> MemeID? { model.order.randomElement(using: &rng) }

        for step in 0..<300 {
            let roll = Int.random(in: 0..<100, using: &rng)
            var mutatedWithoutBatch = true
            switch roll {
            case 0..<22:                                                     // insert
                clock += Int64.random(in: 0...2, using: &rng)               // ties happen on purpose
                let picks = (0..<Int.random(in: 0...3, using: &rng)).map { _ in randomSpelling() }
                let m = Meme(kind: .image, createdAt: clock, textExact: randomText())
                try c.memes.insert(m, tags: picks.map(\.typed))
                model.memes[m.id] = M(tags: Set(picks.map(\.canonical)), textExact: m.textExact, createdAt: clock)
                model.order.append(m.id)
            case 22..<36:                                                    // tag
                guard let id = anyMeme() else { continue }
                let s = randomSpelling()
                try c.memes.addTag(id, s.typed)
                model.memes[id]!.tags.insert(s.canonical)
            case 36..<46:                                                    // untag
                guard let id = anyMeme() else { continue }
                let s = randomSpelling()
                try c.memes.removeTag(id, s.typed)
                model.memes[id]!.tags.remove(s.canonical)
            case 46..<52:                                                    // edit text
                guard let id = anyMeme(), var m = try c.memes.get(id) else { continue }
                m.textExact = randomText()
                try c.memes.update(m)
                model.memes[id]!.textExact = m.textExact
            case 52..<66:                                                    // delete 1–3 live memes, one undo step
                let live = model.order.filter { model.memes[$0]!.live }
                guard !live.isEmpty else { continue }
                var picked: [MemeID] = []
                for _ in 0..<Int.random(in: 1...3, using: &rng) {
                    if let id = live.randomElement(using: &rng), !picked.contains(id) { picked.append(id) }
                }
                let before = try c.snapshot()
                _ = try c.deleteMemes(picked)
                for id in picked { model.memes[id]!.live = false }
                model.batches.append(Batch(isDelete: true, ids: picked))
                lastBatchSnapshot = (model.batches.count - 1, before)
                mutatedWithoutBatch = false
            case 66..<74:                                                    // stage a text and commit it
                let text = randomText() ?? "мем"
                clock += 1
                let item = try c.staging.add(text: text, source: "fuzz", date: Date(timeIntervalSince1970: 1_650_000_000))
                _ = try c.commitStaged([item])
                let id = try #require(try c.db.first("SELECT data FROM undo_entry ORDER BY id DESC LIMIT 1", []) { MemeID($0.string(0)) })
                let created = try #require(try c.memes.get(id))
                model.memes[id] = M(tags: Set(try c.memes.tags(of: id).map(\.name)), textVerbatim: text, createdAt: created.createdAt)
                model.order.append(id)
                #expect(model.memes[id]!.tags == ["text", "2022"])
                model.batches.append(Batch(isDelete: false, ids: [id]))
                lastBatchSnapshot = nil
                mutatedWithoutBatch = false
            case 74..<92:                                                    // undo the last step
                let summary = try c.undoLast()
                guard let bi = model.batches.lastIndex(where: { !$0.undone }) else {
                    #expect(summary == nil, "step \(step): undo with nothing to undo")
                    continue
                }
                #expect(summary != nil, "step \(step)")
                let b = model.batches[bi]
                for (i, id) in b.ids.enumerated() where !b.restored.contains(i) { model.memes[id]!.live = b.isDelete }
                model.batches[bi].undone = true
                if let snap = lastBatchSnapshot, snap.batch == bi {
                    #expect(try c.snapshot() == snap.snapshot, "step \(step): undo didn't restore the exact state")
                }
                lastBatchSnapshot = nil
                mutatedWithoutBatch = false
            default:                                                         // restore one entry of some open batch
                let open = model.batches.indices.filter { !model.batches[$0].undone }
                guard let bi = open.randomElement(using: &rng) else { continue }
                let b = model.batches[bi]
                guard let ei = b.ids.indices.filter({ !b.restored.contains($0) }).randomElement(using: &rng) else { continue }
                let rows = try c.db.query("SELECT e.id FROM undo_entry e WHERE e.batch_id = (SELECT id FROM undo_batch ORDER BY id LIMIT 1 OFFSET ?) ORDER BY e.id", [bi]) { $0.int64(0) }
                try c.undo.restoreEntry(rows[ei])
                model.memes[b.ids[ei]]!.live = b.isDelete
                model.batches[bi].restored.insert(ei)
                if model.batches[bi].restored.count == b.ids.count { model.batches[bi].undone = true }
                lastBatchSnapshot = nil
                mutatedWithoutBatch = false
            }
            if mutatedWithoutBatch { lastBatchSnapshot = nil }
            if ProcessInfo.processInfo.environment["FUZZ_DEBUG"] != nil {     // FUZZ_DEBUG=1 swift test --filter CollectionPropertyTests
                let batches = model.batches.map { "\($0.isDelete ? "D" : "C")\($0.ids.count)\($0.undone ? "u" : "")" }
                print("FUZZ seed=\(seed) step=\(step) roll=\(roll) live=\(model.order.filter { model.memes[$0]!.live }.count) batches=\(batches)")
            }
            try check(c, model, step: step, full: step % 5 == 0 || step == 299)
        }
    }

    private func check(_ c: Collection, _ model: Model, step: Int, full: Bool) throws {
        let live = model.order.filter { model.memes[$0]!.live }
        #expect(try c.memes.count() == live.count, "step \(step): count")
        #expect(try c.ids("") == model.visibleByDefault, "step \(step): default listing")
        guard full else { return }
        let liveSet = Set(live)
        for name in Self.tagPool {
            let has = model.order.filter { model.memes[$0]!.tags.contains(name) }
            let tag = try #require(try c.tags.get(name: name))
            #expect(try c.tags.usage(of: tag) == has.filter(liveSet.contains).count, "step \(step): usage \(name)")
            #expect(try c.tags.rawUsage(of: tag) == has.count, "step \(step): raw usage \(name)")
            let expected = Set(has.filter { liveSet.contains($0) && (name == "chain" || !model.memes[$0]!.tags.contains("chain")) })
            let got = try c.ids(name)
            #expect(Set(got) == expected && got.count == expected.count, "step \(step): search \(name)")
        }
        for (typed, canonical) in Self.spellings {
            #expect(Set(try c.ids(typed)) == Set(try c.ids(canonical)), "step \(step): \(typed)")
        }
        for w in Self.words {
            let expected = Set(live.filter { model.memes[$0]!.words.contains(w) && !model.memes[$0]!.tags.contains("chain") })
            #expect(Set(try c.ids("\"\(w)\"")) == expected, "step \(step): text \(w)")
        }
        for id in model.order {
            #expect(Set(try c.memes.tags(of: id).map(\.name)) == model.memes[id]!.tags, "step \(step): tags of \(id)")
            #expect((try c.memes.get(id)?.deletedAt == nil) == model.memes[id]!.live, "step \(step): liveness of \(id)")
        }
        // Deleted memes leave the full-text index.
        let ftsRows = Set(try c.db.query("SELECT meme_id FROM meme_fts", []) { MemeID($0.string(0)) })
        #expect(ftsRows.isSubset(of: liveSet), "step \(step): FTS holds deleted memes")
    }
}
