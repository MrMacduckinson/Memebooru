import Foundation
import Testing
@testable import MemebooruCore

/// A saved combined meme taken apart again (`Collection.splitComposite`), on the fake platform.
@Suite struct CompositeSplitTests {
    let analyzer = FakePlatform.analyzer

    /// A committed combined meme of `patterns.count` pictures, with tags, words and context.
    private func combined(_ t: TempCollection, _ patterns: [Character] = ["h", "v", "c"]) throws -> (meme: Meme, parts: [String]) {
        let staging = StagingArea(collection: t.collection, analyzer: analyzer)
        var ids: [String] = [], shas: [String] = []
        for (i, p) in patterns.enumerated() {
            var item = try staging.add(file: try t.file("joke \(i).png", FakePictures.data(p, salt: "\(i)")), source: "test",
                                       date: Date(timeIntervalSince1970: 1_600_000_000))
            item.userTags = ["cat"]
            try staging.update(item)
            ids.append(item.id); shas.append(item.sha256)
        }
        var c = try staging.combine(ids)
        c.textVerbatim = "top text"; c.context = "from a friend"; c.userTags = ["cat", "funny"]
        try staging.update(c)
        return (try staging.commit(c.id), shas)
    }

    private func live(_ c: Collection) throws -> [MemeSnapshot] { try c.snapshot().filter(\.live) }

    @Test func eachPictureBecomesItsOwnMemeWithTheCombinedMemesWordsAndTags() throws {
        let t = try TempCollection(), c = t.collection
        let (meme, shas) = try combined(t)
        let tagsBefore = try c.memes.tags(of: meme.id)
        #expect(tagsBefore.contains { $0.name == compositeTag })

        let ids = try c.splitComposite(meme.id, analyzer: analyzer)
        #expect(ids.count == 3)
        #expect(try c.memes.get(meme.id)?.deletedAt != nil)                         // the combined one is in the trash
        #expect(try c.ids(compositeTag).isEmpty)
        for (i, id) in ids.enumerated() {
            let m = try #require(try c.memes.get(id))
            #expect(m.kind == .image && m.payload == .none && m.deletedAt == nil)
            #expect(m.textVerbatim == "top text" && m.context == "from a friend" && m.createdAt == meme.createdAt)
            let primary = try #require(try c.memes.primaryAsset(of: id))
            #expect(primary.sha256 == shas[i] && primary.originalName == "joke 0 \(i + 1).png")
            #expect(try c.memes.assets(of: id).count == 1)
            // Same tags (with the same kinds), but not "combined".
            let tags = try c.memes.tags(of: id)
            #expect(Set(tags.map(\.name)) == Set(tagsBefore.map(\.name)).subtracting([compositeTag]))
            #expect(tags.first { $0.name == "2020" }?.kind == .meta && tags.first { $0.name == "funny" }?.kind == .normal)
            #expect(FileManager.default.fileExists(atPath: c.media.thumbURL(sha256: shas[i]).path))
        }
        #expect(Set(try c.ids("cat funny")) == Set(ids))
    }

    @Test func oneUndoStepPutsTheCombinedMemeBack() throws {
        let t = try TempCollection(), c = t.collection
        let (meme, _) = try combined(t, ["h", "v"])
        let before = try live(c)
        let ids = try c.splitComposite(meme.id, analyzer: analyzer)
        #expect(try c.undo.lastUndoable()?.summary == "Split into 2 pictures")
        #expect(try c.undoLast() == "Split into 2 pictures")
        #expect(try live(c) == before)
        #expect(try ids.allSatisfy { try c.memes.get($0)?.deletedAt != nil })
        #expect(try c.ids(compositeTag) == [meme.id])
    }

    @Test func onlyALiveCombinedMemeCanBeSplit() throws {
        let t = try TempCollection(), c = t.collection
        let plain = Meme(kind: .image)
        try c.memes.insert(plain, tags: ["x"])
        let (meme, _) = try combined(t, ["h", "v"])
        try c.deleteMemes([meme.id])
        let steps = try c.undo.allBatches().count
        #expect(throws: (any Error).self) { try c.splitComposite(plain.id, analyzer: analyzer) }
        #expect(throws: (any Error).self) { try c.splitComposite(MemeID("missing"), analyzer: analyzer) }
        #expect(throws: (any Error).self) { try c.splitComposite(meme.id, analyzer: analyzer) }
        #expect(try c.undo.allBatches().count == steps)                              // no empty split steps
        #expect(try c.memes.count() == 1)
    }

    @Test func aCombineThatIsNotUndoableLeavesNoStepAndNoParts() throws {
        let t = try TempCollection(), c = t.collection
        let staging = StagingArea(collection: c, analyzer: analyzer)
        let a = try staging.add(file: try t.file("a.png", FakePictures.data("h")), source: "test")
        let b = try staging.add(file: try t.file("b.png", FakePictures.data("v")), source: "test")
        let item = try staging.combine([a.id, b.id], undoable: false)
        #expect(try staging.list().map(\.id) == [item.id])
        #expect(staging.parts(item).count == 2)
        #expect(try c.undo.lastUndoable() == nil)
        let meme = try staging.commit(item.id)
        #expect(try c.parts(of: meme.id).map(\.sha256) == [a.sha256, b.sha256])
    }
}
