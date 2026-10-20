import Foundation
import Testing
@testable import MemebooruCore

/// Note: the undo log has no redo; "ordering" here is strict LIFO over batches, with per-entry restores.
@Suite struct UndoEdgeTests {
    private func stage(_ t: TempCollection, _ name: String) throws -> StagedItem {
        try t.collection.staging.add(file: try t.file(name, name), source: "test")
    }

    @Test func multiStepUndoIsStrictlyLIFOAcrossKinds() throws {
        let t = try TempCollection()
        let c = t.collection
        let m1 = Meme(kind: .image, createdAt: 1), m2 = Meme(kind: .image, createdAt: 2)
        try c.memes.insert(m1, tags: ["a"]); try c.memes.insert(m2, tags: ["b"])
        let x = try stage(t, "x.jpg"), y = try stage(t, "y.jpg")

        var states = [try c.snapshot()]
        var stagedCounts = [try c.staging.count()]
        _ = try c.deleteMemes([m1.id], label: "step1");           states.append(try c.snapshot()); stagedCounts.append(try c.staging.count())
        _ = try c.commitStaged([x]);                               states.append(try c.snapshot()); stagedCounts.append(try c.staging.count())
        _ = try c.discardStaged([y]);                              states.append(try c.snapshot()); stagedCounts.append(try c.staging.count())
        _ = try c.deleteMemes([m2.id], label: "step4")

        #expect(try c.undoLast() == "step4")
        #expect(try c.snapshot() == states[3] && c.staging.count() == stagedCounts[3])
        #expect(try c.undoLast() == "Discarded 1 item")
        #expect(try c.snapshot() == states[2] && c.staging.count() == stagedCounts[2])
        #expect(try c.undoLast() == "Committed 1 item")
        // Undoing a commit soft-deletes what it created (the staged item isn't put back).
        let afterCommitUndo = try c.snapshot()
        #expect(afterCommitUndo.filter(\.live).map(\.id) == states[1].filter(\.live).map(\.id))
        #expect(try c.undoLast() == "step1")
        #expect(try c.snapshot().filter(\.live) == states[0].filter(\.live))
        #expect(try c.undoLast() == nil)
        #expect(try c.undo.allBatches().allSatisfy(\.undone))
        #expect(try c.undo.allBatches().count == 4)
    }

    @Test func aNewActionAfterUndoIsTheNextToUndo() throws {
        let t = try TempCollection()
        let c = t.collection
        let ms = (0..<3).map { Meme(kind: .image, createdAt: Int64($0)) }
        for m in ms { try c.memes.insert(m) }
        _ = try c.deleteMemes([ms[0].id], label: "d0")
        _ = try c.deleteMemes([ms[1].id], label: "d1")
        _ = try c.undoLast()                                      // d1
        _ = try c.deleteMemes([ms[2].id], label: "d2")
        #expect(try c.undo.lastUndoable()?.summary == "d2")
        _ = try c.undoLast()
        #expect(try c.undo.lastUndoable()?.summary == "d0")
        #expect(try c.memes.count() == 2)
    }

    @Test func undoRestoresTheExactState() throws {
        let t = try TempCollection()
        let c = t.collection
        let a = Meme(kind: .text, createdAt: 1, textExact: "Обед", textVerbatim: "обед!!", context: "ctx")
        let b = Meme(kind: .image, createdAt: 2)
        try c.memes.insert(a, tags: ["x", "y", "🐸"])
        try c.memes.insert(b, tags: ["x"])
        let st = try c.media.put(data: Data("f".utf8), ext: "jpg")
        try c.memes.addAsset(Asset(memeID: b.id, role: .primary, sha256: st.sha256, ext: "jpg", mime: "image/jpeg", bytes: st.bytes))
        let before = try c.snapshot()
        let searches = ["", "x", "🐸", "\"обед\"", "ctx", "-y"].map { (try? c.ids($0)) ?? [] }
        let usage = try c.tags.usage(of: try #require(try c.tags.get(name: "x")))

        _ = try c.deleteMemes([a.id, b.id])
        #expect(try c.ids("").isEmpty && c.ids("\"обед\"").isEmpty)
        _ = try c.undoLast()

        #expect(try c.snapshot() == before)
        #expect(["", "x", "🐸", "\"обед\"", "ctx", "-y"].map { (try? c.ids($0)) ?? [] } == searches)
        #expect(try c.tags.usage(of: try #require(try c.tags.get(name: "x"))) == usage)
    }

    @Test func restoreOneEntryOfABatch() throws {
        let t = try TempCollection()
        let c = t.collection
        let ms = (0..<3).map { Meme(kind: .image, createdAt: Int64($0)) }
        for m in ms { try c.memes.insert(m) }
        _ = try c.deleteMemes(ms.map(\.id))
        let batch = try #require(try c.undo.lastUndoable())
        let entries = try c.undo.entries(of: batch.id)
        #expect(entries.map(\.memeID) == ms.map(\.id.rawValue))
        #expect(entries.allSatisfy { $0.op == "delete_meme" && !$0.undone })

        try c.undo.restoreEntry(entries[1].id)
        #expect(try c.ids("") == [ms[1].id])
        #expect(try c.undo.lastUndoable()?.id == batch.id)          // the rest is still undoable
        try c.undo.restoreEntry(entries[1].id)                        // again: no-op
        try c.undo.restoreEntry(999_999)                              // unknown: no-op
        #expect(try c.ids("") == [ms[1].id])
        #expect(try c.undo.entries(of: batch.id).map(\.undone) == [false, true, false])

        _ = try c.undoLast()                                          // the remaining two
        #expect(Set(try c.ids("")) == Set(ms.map(\.id)))
        #expect(try c.undo.lastUndoable() == nil)
        #expect(try c.undo.entries(of: batch.id).allSatisfy(\.undone))
        // Restoring an entry of an undone batch changes nothing.
        try c.undo.restoreEntry(entries[0].id)
        #expect(try c.memes.count() == 3)
    }

    @Test func restoringEveryEntryOneByOneClosesTheBatch() throws {
        let t = try TempCollection()
        let c = t.collection
        let ms = (0..<2).map { _ in Meme(kind: .image) }
        for m in ms { try c.memes.insert(m) }
        _ = try c.deleteMemes(ms.map(\.id))
        let batch = try #require(try c.undo.lastUndoable())
        for e in try c.undo.entries(of: batch.id) { try c.undo.restoreEntry(e.id) }
        #expect(try c.undo.lastUndoable() == nil)
        #expect(try c.undo.allBatches().first?.undone == true)
        #expect(try c.memes.count() == 2)
    }

    @Test func restoreOneDiscardedStagedItem() throws {
        let t = try TempCollection()
        let c = t.collection
        let x = try stage(t, "x.jpg"), y = try stage(t, "y.jpg")
        _ = try c.discardStaged([x, y])
        let batch = try #require(try c.undo.lastUndoable())
        let entries = try c.undo.entries(of: batch.id)
        #expect(entries.map(\.op) == ["stage_removed", "stage_removed"] && entries.allSatisfy { $0.memeID == nil })
        try c.undo.restoreEntry(entries[1].id)
        #expect(try c.staging.list().map(\.id) == [y.id])
        #expect(FileManager.default.fileExists(atPath: c.staging.fileURL(y).path))
        #expect(!FileManager.default.fileExists(atPath: c.staging.fileURL(x).path))
        _ = try c.undoLast()
        #expect(Set(try c.staging.list().map(\.id)) == [x.id, y.id])
    }

    @Test func undoSurvivesRestart() throws {
        let t = try TempCollection()
        let m = Meme(kind: .image, textExact: "persist")
        try t.collection.memes.insert(m, tags: ["p"])
        let x = try stage(t, "x.jpg")
        _ = try t.collection.discardStaged([x])
        _ = try t.collection.deleteMemes([m.id])
        let batches = try t.collection.undo.allBatches()

        let reopened = try Collection.open(at: t.url)
        #expect(try reopened.undo.allBatches() == batches)
        #expect(try reopened.undoLast() == "Deleted 1 meme")
        #expect(try reopened.ids("p") == [m.id])
        #expect(try reopened.ids("\"persist\"") == [m.id])

        let again = try Collection.open(at: t.url)                    // and once more, a step further back
        #expect(try again.undoLast() == "Discarded 1 item")
        #expect(try again.staging.get(x.id) == x)
        #expect(FileManager.default.fileExists(atPath: again.staging.fileURL(x).path))
        #expect(try again.undo.lastUndoable() == nil)
    }

    @Test func undoingADeleteTwiceOrOfAnUndeletedMemeIsHarmless() throws {
        let t = try TempCollection()
        let c = t.collection
        let m = Meme(kind: .image)
        try c.memes.insert(m)
        _ = try c.deleteMemes([m.id])
        let batch = try #require(try c.undo.lastUndoable())
        try c.memes.undelete(m.id)                                    // restored by other means first
        try c.undo.undo(batch.id)
        try c.undo.undo(batch.id)
        #expect(try c.memes.count() == 1)
        #expect(try c.undo.lastUndoable() == nil)
    }

    @Test func undoDeleteAfterAnEditKeepsTheEdit() throws {
        let t = try TempCollection()
        let c = t.collection
        var m = Meme(kind: .image, textExact: "v1")
        try c.memes.insert(m)
        _ = try c.deleteMemes([m.id])
        m.textExact = "v2"
        try c.memes.update(m)                                         // edited while in the bin
        _ = try c.undoLast()
        #expect(try c.memes.get(m.id)?.textExact == "v2")
        #expect(try c.ids("\"v2\"") == [m.id])
    }

    @Test func deleteMemesWithDuplicateIdsUndoesCleanly() throws {
        let t = try TempCollection()
        let c = t.collection
        let m = Meme(kind: .image)
        try c.memes.insert(m)
        _ = try c.deleteMemes([m.id, m.id, MemeID("no-such-meme")])
        #expect(try c.memes.count() == 0)
        _ = try c.undoLast()
        #expect(try c.memes.count() == 1)
        #expect(try c.memes.get(MemeID("no-such-meme")) == nil)
    }
}
