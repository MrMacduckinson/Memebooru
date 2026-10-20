import Foundation
import Testing
@testable import MemebooruCore

@Suite struct StagingEdgeTests {
    private func stagingEntries(_ c: Collection) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: c.stagingURL.path).filter { !$0.hasPrefix(".") })
    }

    // MARK: Add

    @Test func sameFileStagedTwiceIsTwoItemsThatKnowEachOther() throws {
        let t = try TempCollection()
        let s = t.collection.staging
        let src = try t.file("a.jpg", "same bytes")
        let a = try s.add(file: src, source: "test"), b = try s.add(file: src, source: "test")
        #expect(a.id != b.id && a.sha256 == b.sha256)
        #expect(try s.count() == 2 && Set(s.list().map(\.id)) == [a.id, b.id])
        #expect(try s.duplicates(of: a) == [DuplicateHit(memeID: nil, match: .stagedExact(id: b.id))])
        #expect(try s.duplicates(of: b) == [DuplicateHit(memeID: nil, match: .stagedExact(id: a.id))])
        #expect(FileManager.default.fileExists(atPath: src.path))                 // the source is copied, not moved
        let m = try s.commit(a.id)
        #expect(try s.duplicates(of: b) == [DuplicateHit(memeID: m.id, match: .exact)])
        // Committing the second copy anyway: a second meme, one file on disk.
        let m2 = try s.commit(b.id)
        #expect(m.id != m2.id)
        #expect(try t.collection.memes.memes(withSHA256: a.sha256).count == 2)
        #expect(try t.collection.memes.primaryAsset(of: m2.id)?.sha256 == a.sha256)
    }

    @Test func aDeletedMemeIsNotADuplicate() throws {
        let t = try TempCollection()
        let s = t.collection.staging
        let src = try t.file("a.png", "bytes")
        let m = try s.commit(try s.add(file: src, source: "test").id)
        _ = try t.collection.deleteMemes([m.id])
        let again = try s.add(file: src, source: "test")
        #expect(try s.duplicates(of: again).isEmpty)
        _ = try t.collection.undoLast()
        #expect(try s.duplicates(of: again) == [DuplicateHit(memeID: m.id, match: .exact)])
    }

    @Test func nearDuplicatesByPerceptualHash() throws {
        let t = try TempCollection()
        let s = StagingArea(collection: t.collection, analyzer: FakePlatform.analyzer)
        let committed = try s.commit(try s.add(file: try t.file("orig.png", FakePictures.data("h", salt: "1")), source: "test").id)
        let near = try s.add(file: try t.file("copy.png", FakePictures.data("h", salt: "2")), source: "test")
        let other = try s.add(file: try t.file("other.png", FakePictures.data("c")), source: "test")
        let nearStaged = try s.add(file: try t.file("copy2.png", FakePictures.data("h", salt: "3")), source: "test")
        let ph = try #require(near.info.phash), oh = try #require(other.info.phash)
        try #require(PerceptualHash.hamming(.init(bitPattern: ph), .init(bitPattern: oh)) > StagingArea.similarThreshold)

        let hits = try s.duplicates(of: near)
        #expect(hits.contains(DuplicateHit(memeID: committed.id, match: .similar(distance: 0))))
        #expect(hits.contains(DuplicateHit(memeID: nil, match: .stagedSimilar(id: nearStaged.id, distance: 0))))
        #expect(!hits.contains { $0.match == .exact })
        #expect(hits.count == 2)
        #expect(try s.duplicates(of: other).isEmpty)
        // An exact copy is reported as exact, not also as similar.
        let exact = try s.add(file: try t.file("orig2.png", FakePictures.data("h", salt: "1")), source: "test")
        let exactHits = try s.duplicates(of: exact)
        #expect(exactHits.filter { $0.memeID == committed.id } == [DuplicateHit(memeID: committed.id, match: .exact)])
    }

    @Test func zeroByteFiles() throws {
        let t = try TempCollection()
        let s = t.collection.staging
        let img = try s.add(file: try t.file("empty.png", Data()), source: "test")
        #expect(img.bytes == 0)
        #expect(img.sha256 == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        let txt = try s.add(file: try t.file("empty.txt", Data()), source: "test")
        #expect(txt.kind == .text && txt.textVerbatim == "")
        let m = try s.commit(img.id)
        #expect(try t.collection.memes.primaryAsset(of: m.id)?.bytes == 0)
        #expect(t.collection.media.exists(sha256: img.sha256, ext: "png"))
        let mt = try s.commit(txt.id)
        #expect(try t.collection.memes.get(mt.id)?.textVerbatim == "")
        // Same (empty) bytes, different extension: still the same content.
        #expect(try t.collection.memes.memes(withSHA256: img.sha256).count == 2)
    }

    @Test func missingSourceFileFailsCleanly() throws {
        let t = try TempCollection()
        let c = t.collection
        let before = try stagingEntries(c)
        let ghost = t.url.appendingPathComponent("does-not-exist.jpg")
        #expect(throws: (any Error).self) { try c.staging.add(file: ghost, source: "test") }
        #expect(try c.db.scalarInt("SELECT count(*) FROM staged") == 0)
        #expect(try stagingEntries(c) == before)                       // no half-made staging folder left behind
    }

    @Test func missingExtraFileFailsCleanly() throws {
        let t = try TempCollection()
        let c = t.collection
        let before = try stagingEntries(c)
        let src = try t.file("a.jpg", "x")
        let extra = StagedExtra(role: .media, order: 0, url: t.url.appendingPathComponent("gone.jpg"))
        #expect(throws: (any Error).self) { try c.staging.add(file: src, source: "test", extras: [extra]) }
        #expect(try c.staging.count() == 0)
        #expect(try stagingEntries(c) == before)
    }

    @Test func unsupportedTypesAreRejected() throws {
        let t = try TempCollection()
        let c = t.collection
        for name in ["virus.exe", "noext", "archive.zip", ".hidden"] {
            #expect(throws: CollectionError.self) { try c.staging.add(file: try t.file(name, "x"), source: "test") }
        }
        #expect(try c.staging.count() == 0)
        // With an explicit kind anything goes (tweets arrive as .json).
        let j = try c.staging.add(file: try t.file("t.json", "{}"), source: "x", kind: .tweet)
        #expect(j.kind == .tweet && j.mime == "application/json")
    }

    @Test func extensionsAndNamesAreNormalizedButNamesKept() throws {
        let t = try TempCollection()
        let s = t.collection.staging
        let a = try s.add(file: try t.file("Мем 😀 (1).JPEG", "x"), source: "test")
        #expect(a.ext == "jpg" && a.kind == .image && a.mime == "image/jpeg")
        #expect(a.originalName == "Мем 😀 (1).JPEG")
        #expect(FileManager.default.fileExists(atPath: s.fileURL(a).path))
        let m = try s.commit(a.id)
        #expect(try t.collection.memes.primaryAsset(of: m.id)?.originalName == "Мем 😀 (1).JPEG")
        let named = try s.add(file: try t.file("x.gif", "y"), source: "test", originalName: "custom.gif")
        #expect(named.kind == .gif && named.originalName == "custom.gif")
    }

    @Test func yearTagComesFromTheGivenDate() throws {
        let t = try TempCollection()
        let s = t.collection.staging
        let old = try s.add(file: try t.file("a.mp4", "v"), source: "test", date: Date(timeIntervalSince1970: 0))
        #expect(old.suggestedTags == ["1970", "video"])
        let dup = try s.add(file: try t.file("b.mp3", "v"), source: "test", date: Date(timeIntervalSince1970: 0), extraTags: ["audio", "1970", "x"])
        #expect(dup.suggestedTags == ["1970", "audio", "x"])                    // no duplicates
    }

    @Test func textItemsFromStrings() throws {
        let t = try TempCollection()
        let s = t.collection.staging
        let a = try s.add(text: "Штирлиц 🕵️ шёл по коридору", source: "paste")
        let b = try s.add(text: "Штирлиц 🕵️ шёл по коридору!", source: "paste")
        #expect(a.kind == .text && a.ext == "txt" && a.textVerbatim == "Штирлиц 🕵️ шёл по коридору")
        #expect(try s.duplicates(of: b).contains { if case .stagedSimilar(let id, _) = $0.match { return id == a.id } else { return false } })
        let m = try s.commit(a.id)
        #expect(try t.collection.ids("\"коридору\"") == [m.id])
    }

    // MARK: Update

    @Test func updatePersistsEveryEditableField() throws {
        let t = try TempCollection()
        let s = t.collection.staging
        let item = try s.add(file: try t.file("a.bmp", "x"), source: "src", extraTags: ["source_unknown"])
        var e = item
        e.textExact = "Точно"; e.textVerbatim = "Тчно"; e.context = "контекст 🐸"
        e.suggestedTags = ["picture"]; e.userTags = ["Сталин", "@durov", "2022"]
        e.kind = .gif; e.convert = false; e.keepOriginal = true
        e.payload = .article(ArticlePayload(url: "https://e.com", title: "T"))
        try s.update(e)
        var stored = try #require(try s.get(item.id))
        #expect(stored.textExact == "Точно" && stored.textVerbatim == "Тчно" && stored.context == "контекст 🐸")
        #expect(stored.suggestedTags == ["picture"] && stored.userTags == ["Сталин", "@durov", "2022"])
        #expect(stored.kind == .gif && stored.convert == false && stored.keepOriginal == true)
        #expect(stored.payload == .none)        // payload is decoded by kind: an article payload on a gif is dropped

        e.kind = .article
        try s.update(e)
        stored = try #require(try s.get(item.id))
        #expect(stored.payload == e.payload)

        // Back to "nothing": nils and empty lists stick too.
        e.textExact = nil; e.textVerbatim = nil; e.context = nil; e.userTags = []; e.suggestedTags = []
        e.convert = nil; e.keepOriginal = nil; e.payload = .none; e.kind = .image
        try s.update(e)
        stored = try #require(try s.get(item.id))
        #expect(stored.textExact == nil && stored.textVerbatim == nil && stored.context == nil)
        #expect(stored.userTags.isEmpty && stored.suggestedTags.isEmpty && stored.convert == nil && stored.keepOriginal == nil)
        #expect(stored.payload == .none && stored.kind == .image)
        // Identity fields are not editable: file, hash, size, source and order stay as staged.
        #expect(stored.sha256 == item.sha256 && stored.ext == item.ext && stored.bytes == item.bytes && stored.source == item.source)
        #expect(stored.addedAt == item.addedAt && stored.originalName == item.originalName && stored.parentID == nil)
    }

    @Test func updateSurvivesReopen() throws {
        let t = try TempCollection()
        let item = try t.collection.staging.add(file: try t.file("a.jpg", "x"), source: "test")
        var e = item; e.userTags = ["persisted"]; e.textExact = "сохранено"
        try t.collection.staging.update(e)
        let reopened = try Collection.open(at: t.url)
        let got = try #require(try reopened.staging.get(item.id))
        #expect(got.userTags == ["persisted"] && got.textExact == "сохранено")
        #expect(got == e)
    }

    @Test func updateOfAMissingItemIsHarmless() throws {
        let t = try TempCollection()
        let item = try t.collection.staging.add(file: try t.file("a.jpg", "x"), source: "test")
        try t.collection.staging.discard(item.id)
        try t.collection.staging.update(item)
        #expect(try t.collection.staging.get(item.id) == nil)
    }

    // MARK: Commit

    @Test func commitAppliesTagsAndKinds() throws {
        let t = try TempCollection()
        let c = t.collection
        var item = try c.staging.add(file: try t.file("a.jpg", "x"), source: "test", date: Date(timeIntervalSince1970: 1_650_000_000))
        item.userTags = ["Stalin", "1945", "@handle"]
        try c.staging.update(item)
        let m = try c.staging.commit(item.id)
        let tags = try c.memes.tags(of: m.id)
        #expect(tags.filter { $0.kind == .meta }.map(\.name) == ["1945", "2022", "picture"])   // numbers are meta
        #expect(tags.filter { $0.kind == .normal }.map(\.name) == ["@handle", "stalin"])
        // Override tags replace the item's own.
        let other = try c.staging.add(file: try t.file("b.jpg", "y"), source: "test")
        let m2 = try c.staging.commit(other.id, tags: ["only_this"], defaultKind: .meta)
        #expect(try c.memes.tags(of: m2.id).map(\.name) == ["only_this"])
        #expect(try c.tags.get(name: "only_this")?.kind == .meta)
    }

    @Test func commitOfUnknownIdThrows() throws {
        let t = try TempCollection()
        #expect(throws: CollectionError.self) { try t.collection.staging.commit("nope") }
        #expect(try t.collection.memes.count() == 0)
    }

    @Test func failedCommitRollsBackAndTheItemCanBeFixedAndRetried() throws {
        let t = try TempCollection()
        let c = t.collection
        var item = try c.staging.add(file: try t.file("t.json", "{}"), source: "x", kind: .tweet,
                                     extras: [StagedExtra(role: .media, order: 0, url: try t.file("m.jpg", "media"))])
        item.userTags = ["ok", "-bad"]
        try c.staging.update(item)
        let ops = try c.oplog.count()
        #expect(throws: TagError.self) { try c.staging.commit(item.id) }
        #expect(try c.db.scalarInt("SELECT count(*) FROM meme") == 0)
        #expect(try c.oplog.count() == ops)
        #expect(try c.staging.get(item.id) != nil)
        #expect(FileManager.default.fileExists(atPath: c.staging.fileURL(item).path))   // files stay in staging
        #expect(c.staging.extras(item).count == 1)
        // Fix the tag and retry: everything goes in.
        item.userTags = ["ok"]
        try c.staging.update(item)
        let m = try c.staging.commit(item.id)
        #expect(try c.memes.tags(of: m.id).map(\.name).contains("ok"))
        #expect(try c.memes.assets(of: m.id).count == 2)
        #expect(try c.memes.assets(of: m.id).allSatisfy { c.media.exists(sha256: $0.sha256, ext: $0.ext) })
    }

    @Test func vanishedStagedFileErrorsCleanly() throws {
        let t = try TempCollection()
        let c = t.collection
        let item = try c.staging.add(file: try t.file("a.jpg", "x"), source: "test")
        try FileManager.default.removeItem(at: c.staging.fileURL(item))
        let ops = try c.oplog.count()
        #expect(throws: (any Error).self) { try c.staging.commit(item.id) }
        #expect(try c.memes.count() == 0 && c.oplog.count() == ops)
        #expect(try c.staging.get(item.id) != nil)                          // still there to discard
        try c.staging.discard(item.id)
        #expect(try c.staging.count() == 0)
    }

    @Test func bulkCommitStopsAtAVanishedFileAndKeepsAnHonestUndoStep() throws {
        let t = try TempCollection()
        let c = t.collection
        let good = try c.staging.add(file: try t.file("a.jpg", "a"), source: "test")
        let bad = try c.staging.add(file: try t.file("b.jpg", "b"), source: "test")
        try FileManager.default.removeItem(at: c.staging.fileURL(bad))
        #expect(throws: (any Error).self) { try c.commitStaged([good, bad]) }
        #expect(try c.memes.count() == 1)
        let batch = try #require(try c.undo.lastUndoable())
        #expect(batch.count == 1 && batch.kind == "commit")                 // what was done is undoable, and says so
        _ = try c.undoLast()
        #expect(try c.memes.count() == 0)

        // Nothing committed at all → no phantom undo step.
        #expect(throws: (any Error).self) { try c.commitStaged([bad]) }
        #expect(try c.undo.lastUndoable() == nil)
    }

    @Test func bulkCommitReportsProgressAndCanBeCancelled() throws {
        let t = try TempCollection()
        let c = t.collection
        let items = try (0..<5).map { try c.staging.add(file: try t.file("\($0).jpg", "\($0)"), source: "test") }
        let progress = Locked<[Int]>([])
        let summary = try c.commitStaged(items, onProgress: { n in progress.mutate { $0.append(n) } },
                                         isCancelled: { progress.value.count >= 3 })
        #expect(progress.value == [1, 2, 3])
        #expect(summary == "Committed 3 items")
        #expect(try c.memes.count() == 3 && c.staging.count() == 2)
        #expect(try c.undo.lastUndoable()?.count == 3)
        #expect(try c.commitStaged([]) == "Nothing to commit")
        #expect(try c.discardStaged([]) == "Nothing to discard")
        #expect(try c.deleteMemes([]) == "Nothing to delete")
        #expect(try c.undo.allBatches().count == 1)
    }

    @Test func discardUndoRecommit() throws {
        let t = try TempCollection()
        let c = t.collection
        var item = try c.staging.add(file: try t.file("a.jpg", "abc"), source: "test")
        item.userTags = ["kept"]
        try c.staging.update(item)
        try c.discardStaged([item])
        #expect(try c.staging.count() == 0)
        _ = try c.undoLast()
        let back = try #require(try c.staging.get(item.id))
        #expect(back == item)
        let m = try c.staging.commit(back.id)
        #expect(try c.memes.tags(of: m.id).map(\.name).contains("kept"))
        #expect(c.media.exists(sha256: item.sha256, ext: "jpg"))
        // Undoing the discard again is not possible: the batch is spent.
        #expect(try c.undo.lastUndoable() == nil)
    }

    @Test func pruneTrashByAge() throws {
        let t = try TempCollection()
        let c = t.collection
        let a = try c.staging.add(file: try t.file("a.jpg", "a"), source: "test")
        let b = try c.staging.add(file: try t.file("b.jpg", "b"), source: "test")
        try c.discardStaged([a])
        let oldBatch = try #require(try c.undo.lastUndoable()).id
        try c.discardStaged([b])
        let newBatch = try #require(try c.undo.lastUndoable()).id
        let trash = c.stagingURL.appendingPathComponent(".trash")
        let oldDir = trash.appendingPathComponent(String(oldBatch)), newDir = trash.appendingPathComponent(String(newBatch))
        #expect(FileManager.default.fileExists(atPath: oldDir.path) && FileManager.default.fileExists(atPath: newDir.path))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-30 * 86400)], ofItemAtPath: oldDir.path)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-13 * 86400)], ofItemAtPath: newDir.path)

        c.staging.pruneTrash(olderThanDays: 14)
        #expect(!FileManager.default.fileExists(atPath: oldDir.path))
        #expect(FileManager.default.fileExists(atPath: newDir.path))
        c.staging.pruneTrash(olderThanDays: 14)                               // idempotent

        _ = try c.undoLast()                                                  // the recent discard: file comes back
        #expect(FileManager.default.fileExists(atPath: c.staging.fileURL(b).path))
        #expect(try c.staging.commit(b.id).kind == .image)

        // Debatable (reported): undoing a discard whose trash was pruned brings the row back without
        // its file. It must at least fail cleanly on commit and be discardable.
        _ = try c.undoLast()
        if try c.staging.get(a.id) != nil {
            #expect(throws: (any Error).self) { try c.staging.commit(a.id) }
            try c.staging.discard(a.id)
        }
        #expect(try c.staging.count() == 0)
    }

    @Test func pruneTrashWithNoTrashIsANoOp() throws {
        let t = try TempCollection()
        t.collection.staging.pruneTrash(olderThanDays: 0)
        t.collection.staging.pruneTrash(olderThanDays: -5)
    }

    // MARK: Extras

    @Test func extrasAreStagedListedAndCommitted() throws {
        let t = try TempCollection()
        let c = t.collection
        let e1 = try t.file("p1.JPEG", "photo1"), e0 = try t.file("p0.png", "photo0"), av = try t.file("av.jpg", "avatar")
        let item = try c.staging.add(file: try t.file("t.json", "{}"), source: "x", kind: .tweet,
                                     extras: [StagedExtra(role: .media, order: 1, url: e1), StagedExtra(role: .media, order: 0, url: e0),
                                              StagedExtra(role: .avatar, order: 0, url: av)])
        // A stray file in the item's folder is not an extra.
        try Data("junk".utf8).write(to: c.stagingURL.appendingPathComponent(item.id).appendingPathComponent("notes.txt"))
        let extras = c.staging.extras(item)
        #expect(extras.map { "\($0.role.rawValue)_\($0.order)" } == ["avatar_0", "media_0", "media_1"])
        #expect(extras[2].url.pathExtension == "jpg")
        let m = try c.staging.commit(item.id)
        let assets = try c.memes.assets(of: m.id)
        #expect(Set(assets.map { "\($0.role.rawValue):\($0.order)" }) == ["primary:0", "media:0", "media:1", "avatar:0"])
        #expect(assets.allSatisfy { c.media.exists(sha256: $0.sha256, ext: $0.ext) })
        #expect(!FileManager.default.fileExists(atPath: c.stagingURL.appendingPathComponent(item.id).path))
    }

    // MARK: Conversion (fake platform: no ImageIO / ffmpeg needed)

    @Test func uncommonStillIsConvertedByDefaultWithoutKeepingTheOriginal() throws {
        let t = try TempCollection()
        let c = t.collection
        let s = StagingArea(collection: c, analyzer: FakePlatform.analyzer)
        let item = try s.add(file: try t.file("pic.bmp", FakePictures.data("h")), source: "test")
        #expect(item.compatibility == .uncommon && item.willConvert && !item.willKeepOriginal)
        #expect(item.info.width == 64 && item.info.phash != nil)
        let m = try s.commit(item.id)
        let (primary, original) = try c.formats(of: m.id)
        let p = try #require(primary)
        #expect(p.ext == "png" && p.mime == "image/png")
        #expect(p.sourceSHA256 == item.sha256 && p.sourceExt == "bmp")
        #expect(p.originalName == "pic.png")
        #expect(original == nil)
        #expect(c.media.exists(sha256: p.sha256, ext: "png"))
        #expect(!c.media.exists(sha256: item.sha256, ext: "bmp"))
        #expect(FileManager.default.fileExists(atPath: c.media.thumbURL(sha256: p.sha256).path))
        // Re-importing the same .bmp is still recognised as already in the collection.
        let again = try s.add(file: try t.file("pic.bmp", FakePictures.data("h")), source: "test")
        #expect(try s.duplicates(of: again).contains(DuplicateHit(memeID: m.id, match: .exact)))
    }

    @Test func keepOriginalStoresBothFiles() throws {
        let t = try TempCollection()
        let c = t.collection
        let s = StagingArea(collection: c, analyzer: FakePlatform.analyzer)
        var item = try s.add(file: try t.file("pic.tiff", FakePictures.data("v")), source: "test")
        item.keepOriginal = true
        try s.update(item)
        let m = try s.commit(item.id)
        let (primary, original) = try c.formats(of: m.id)
        #expect(primary?.ext == "png")
        let o = try #require(original)
        #expect(o.sha256 == item.sha256 && o.ext == "tiff" && o.originalName == "pic.tiff")
        #expect(c.media.exists(sha256: o.sha256, ext: "tiff"))
    }

    @Test func commitParametersOverrideTheItemsChoice() throws {
        let t = try TempCollection()
        let c = t.collection
        let s = StagingArea(collection: c, analyzer: FakePlatform.analyzer)
        var item = try s.add(file: try t.file("pic.bmp", FakePictures.data("c")), source: "test")
        item.convert = true; item.keepOriginal = false
        try s.update(item)
        let m = try s.commit(item.id, convert: false)
        #expect(try c.formats(of: m.id).primary?.ext == "bmp")
        #expect(try c.formats(of: m.id).original == nil)

        let item2 = try s.add(file: try t.file("pic2.bmp", FakePictures.data("v")), source: "test")
        let m2 = try s.commit(item2.id, convert: true, keepOriginal: true)
        #expect(try c.formats(of: m2.id).primary?.ext == "png")
        #expect(try c.formats(of: m2.id).original?.ext == "bmp")
    }

    @Test func svgKeepsItsOriginalByDefault() throws {
        let t = try TempCollection()
        let c = t.collection
        let s = StagingArea(collection: c, analyzer: FakePlatform.analyzer)
        let item = try s.add(file: try t.file("logo.svg", FakePictures.data("h")), source: "test")
        #expect(item.willConvert && item.willKeepOriginal)
        let m = try s.commit(item.id)
        #expect(try c.formats(of: m.id).primary?.ext == "png")
        #expect(try c.formats(of: m.id).original?.ext == "svg")
    }

    @Test func popularFormatsAreNeverConverted() throws {
        let t = try TempCollection()
        let c = t.collection
        let s = StagingArea(collection: c, analyzer: FakePlatform.analyzer)
        let item = try s.add(file: try t.file("pic.png", FakePictures.data("h")), source: "test")
        #expect(!item.willConvert)
        let m = try s.commit(item.id, convert: true, keepOriginal: true)
        #expect(try c.formats(of: m.id).primary?.sha256 == item.sha256)
        #expect(try c.formats(of: m.id).original == nil)
    }

    @Test func withoutAnAnalyzerFilesAreStoredAsIs() throws {
        let t = try TempCollection()
        let c = t.collection
        let item = try c.staging.add(file: try t.file("pic.bmp", FakePictures.data("h")), source: "test")
        #expect(item.willConvert)
        let m = try c.staging.commit(item.id)
        #expect(try c.formats(of: m.id).primary?.sha256 == item.sha256)
        #expect(try c.formats(of: m.id).primary?.ext == "bmp")
    }

    @Test func undecodablePictureFailsConversionCleanly() throws {
        let t = try TempCollection()
        let c = t.collection
        let s = StagingArea(collection: c, analyzer: FakePlatform.analyzer)
        let item = try s.add(file: try t.file("broken.bmp", "not a picture"), source: "test")
        #expect(item.info.phash == nil && item.info.width == nil)
        #expect(throws: (any Error).self) { try s.commit(item.id) }
        #expect(try c.memes.count() == 0)
        #expect(try s.get(item.id) != nil)
        // Storing it as is still works.
        let m = try s.commit(item.id, convert: false)
        #expect(try c.formats(of: m.id).primary?.ext == "bmp")
    }
}

// MARK: - Tweet chains in staging

@Suite struct StagingChainEdgeTests {
    private func tweet(_ t: TempCollection, _ id: String, replyTo: String? = nil, quote: String? = nil,
                       parent: String? = nil, tags: [String] = []) throws -> StagedItem {
        let p = TweetPayload(tweetID: id, url: "https://x.com/u/status/\(id)", authorName: "U", handle: "u",
                             replyToTweetID: replyTo, quotedTweetID: quote)
        return try t.collection.staging.add(file: try t.file("\(id).json", "{\"id\":\"\(id)\"}"), source: "x", kind: .tweet,
                                            textVerbatim: "tweet \(id)", payload: .tweet(p), extraTags: tags, parentID: parent)
    }

    @Test func chainItemsAreNeverRoots() throws {
        let t = try TempCollection()
        let s = t.collection.staging
        let root = try tweet(t, "r", replyTo: "p", quote: "q")
        let p = try tweet(t, "p", parent: root.id, tags: ["chain", "thread"])
        let q = try tweet(t, "q", parent: root.id, tags: ["chain", "quoted"])
        let lone = try tweet(t, "lone")
        #expect(Set(try s.list().map(\.id)) == [root.id, lone.id])
        #expect(try s.count() == 2)
        #expect(Set(try s.chain(of: root.id).map(\.id)) == [p.id, q.id])
        #expect(try s.chain(of: lone.id).isEmpty)
        #expect(try s.chain(of: p.id).isEmpty)
        #expect(p.suggestedTags == ["chain", "thread"])                           // no type/year tags for chain tweets
        #expect(try s.stagedTweetIDs() == ["r", "p", "q", "lone"])
        #expect(try s.get(p.id)?.parentID == root.id)
    }

    @Test func committingTheRootCommitsAndLinksItsChain() throws {
        let t = try TempCollection()
        let c = t.collection
        let root = try tweet(t, "r", replyTo: "p", quote: "q")
        _ = try tweet(t, "p", replyTo: "pp", parent: root.id, tags: ["chain", "thread"])
        _ = try tweet(t, "q", parent: root.id, tags: ["chain", "quoted"])
        _ = try tweet(t, "pp", parent: root.id, tags: ["chain", "thread"])
        _ = try c.commitStaged([root])
        #expect(try c.memes.count() == 4)
        #expect(try c.db.scalarInt("SELECT count(*) FROM staged") == 0)
        let id = { (tw: String) in try #require(try c.memes.memeForTweet(tw)) }
        let rootMeme = try id("r")
        #expect(try c.memes.relations(of: rootMeme).contains { $0.kind == .replyTo && $0.to == (try? id("p")) })
        #expect(try c.memes.relations(of: rootMeme).contains { $0.kind == .quote && $0.to == (try? id("q")) })
        #expect(try c.memes.relations(of: id("pp")).contains { $0.kind == .replyTo && $0.from == (try? id("p")) })
        #expect(try c.ids("") == [rootMeme])
        #expect(try c.wayback.pendingCount() == 1)
        #expect(try c.tags(ofTweet: "p").contains("chain"))
        #expect(try !c.tags(ofTweet: "p").contains("tweet"))

        // One undo step takes the whole chain out again.
        #expect(try c.undo.lastUndoable()?.count == 4)
        _ = try c.undoLast()
        #expect(try c.memes.count() == 0)
    }

    @Test func chainTweetAlreadyInTheCollectionIsLinkedNotDuplicated() throws {
        let t = try TempCollection()
        let c = t.collection
        let existing = Meme(kind: .tweet, payload: .tweet(TweetPayload(tweetID: "p", url: "https://x.com/u/status/p", authorName: "U", handle: "u")))
        try c.memes.insert(existing, tags: ["tweet"])
        let root = try tweet(t, "r", replyTo: "p")
        _ = try tweet(t, "p", parent: root.id, tags: ["chain"])
        let m = try c.staging.commit(root.id)
        #expect(try c.memes.count() == 2)
        #expect(try c.memes.relations(of: m.id) .contains { $0.kind == .replyTo && $0.to == existing.id })
        #expect(try c.db.scalarInt("SELECT count(*) FROM staged") == 0)
    }

    @Test func discardTakesTheChainAndUndoBringsItBack() throws {
        let t = try TempCollection()
        let c = t.collection
        let root = try tweet(t, "r", replyTo: "p")
        let p = try tweet(t, "p", parent: root.id, tags: ["chain"])
        try c.staging.discard(root.id)                                        // the non-undoable discard
        #expect(try c.db.scalarInt("SELECT count(*) FROM staged") == 0)
        #expect(!FileManager.default.fileExists(atPath: c.staging.fileURL(p).path))

        let root2 = try tweet(t, "r2", replyTo: "p2")
        let p2 = try tweet(t, "p2", parent: root2.id, tags: ["chain"])
        try c.discardStaged([root2])
        _ = try c.undoLast()
        #expect(try c.staging.list().map(\.id) == [root2.id])
        #expect(try c.staging.chain(of: root2.id).map(\.id) == [p2.id])
        #expect(FileManager.default.fileExists(atPath: c.staging.fileURL(p2).path))
    }

    @Test func nonTweetRootDoesNotCascade() throws {
        // Only tweets carry chains; an image with (bogus) children commits alone.
        let t = try TempCollection()
        let c = t.collection
        let img = try c.staging.add(file: try t.file("a.jpg", "x"), source: "test")
        _ = try tweet(t, "orphan", parent: img.id, tags: ["chain"])
        _ = try c.staging.commit(img.id)
        #expect(try c.memes.count() == 1)
        #expect(try c.db.scalarInt("SELECT count(*) FROM staged WHERE parent_id = ?", [img.id]) == 1)
    }
}

@Suite struct TweetLookupTests {
    @Test func tweetIdsMatchExactlyNotAsPatterns() throws {
        let t = try TempCollection()
        let c = t.collection
        let m = Meme(kind: .tweet, payload: .tweet(TweetPayload(tweetID: "123", url: "https://x.com/a/status/123", authorName: "A", handle: "a")))
        try c.memes.insert(m)
        #expect(try c.memes.tweetExists("123") && c.memes.memeForTweet("123") == m.id)
        for probe in ["12", "1234", "%", "1_3", "_23", "%3", "1%", ""] {
            #expect(try !c.memes.tweetExists(probe), "probe \(probe)")
            #expect(try c.memes.memeForTweet(probe) == nil, "probe \(probe)")
        }
        try c.memes.delete(m.id)
        #expect(try !c.memes.tweetExists("123"))
    }
}

private extension Collection {
    func tags(ofTweet tw: String) throws -> [String] {
        guard let id = try memes.memeForTweet(tw) else { return [] }
        return try memes.tags(of: id).map(\.name)
    }
}
