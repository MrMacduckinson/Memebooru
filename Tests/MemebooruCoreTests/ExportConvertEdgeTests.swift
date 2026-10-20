import Foundation
import Testing
@testable import MemebooruCore

/// Export / convert with the fake platform (pictures only; video/audio need ffmpeg — see FormatTests).
@Suite struct ExportConvertEdgeTests {
    private func imageMeme(_ t: TempCollection, _ name: String, _ data: Data, text: String? = nil) throws -> Meme {
        let s = t.collection.staging
        var item = try s.add(file: try t.file(name, data), source: "test")
        item.textExact = text
        try s.update(item)
        return try s.commit(item.id)           // no analyzer: stored as is
    }

    private func outDir() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("mb-out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @Test func exportStoredIntoAFolderUsesTheOriginalName() throws {
        let t = try TempCollection()
        let m = try imageMeme(t, "Мой мем.png", FakePictures.data("h"))
        let out = try outDir()
        defer { try? FileManager.default.removeItem(at: out) }
        let f = try t.collection.export(m.id, as: .stored, to: out)
        #expect(f.lastPathComponent == "Мой мем.png")
        #expect(try Data(contentsOf: f) == FakePictures.data("h"))
        // Exporting again overwrites instead of failing.
        #expect(try t.collection.export(m.id, as: .stored, to: out) == f)
    }

    @Test func exportToAFilePathFixesTheExtension() throws {
        let t = try TempCollection()
        let m = try imageMeme(t, "a.png", FakePictures.data("h"))
        let out = try outDir()
        defer { try? FileManager.default.removeItem(at: out) }
        let f = try t.collection.export(m.id, as: .stored, to: out.appendingPathComponent("wrong.jpg"))
        #expect(f.lastPathComponent == "wrong.png")
    }

    @Test func exportNameFallsBackToTextAndIsSanitized() throws {
        let t = try TempCollection()
        let c = t.collection
        let m = Meme(kind: .image, textExact: "a/b " + String(repeating: "x", count: 100))
        try c.memes.insert(m)
        let st = try c.media.put(data: FakePictures.data("v"), ext: "png")
        try c.memes.addAsset(Asset(memeID: m.id, role: .primary, sha256: st.sha256, ext: "png", mime: "image/png", bytes: st.bytes))
        let out = try outDir()
        defer { try? FileManager.default.removeItem(at: out) }
        let f = try c.export(m.id, as: .stored, to: out)
        #expect(f.deletingLastPathComponent().standardizedFileURL == out.standardizedFileURL)   // a "/" can't escape the folder
        #expect(f.lastPathComponent.hasPrefix("a_b x") && f.lastPathComponent.count == 40 + 4)
    }

    @Test func exportErrors() throws {
        let t = try TempCollection()
        let c = t.collection
        let out = try outDir()
        defer { try? FileManager.default.removeItem(at: out) }
        #expect(throws: CollectionError.self) { try c.export(MemeID("nope"), as: .stored, to: out) }
        let bare = Meme(kind: .text, textVerbatim: "no file")
        try c.memes.insert(bare)
        #expect(throws: CollectionError.self) { try c.export(bare.id, as: .stored, to: out) }
        let m = try imageMeme(t, "a.png", FakePictures.data("h"))
        #expect(throws: CollectionError.self) { try c.export(m.id, as: .original, to: out) }
        #expect(throws: CollectionError.self) { try c.export(m.id, as: .format(.jpeg), to: out) }  // conversion needs an analyzer
        #expect(try c.export(m.id, as: .format(.png), to: out).pathExtension == "png")            // same format: plain copy
    }

    @Test func exportConvertsWithoutStoring() throws {
        let t = try TempCollection()
        let c = t.collection
        let m = try imageMeme(t, "a.png", FakePictures.data("c"))
        let out = try outDir()
        defer { try? FileManager.default.removeItem(at: out) }
        let assetsBefore = try c.memes.assets(of: m.id)
        let f = try c.export(m.id, as: .format(.jpeg), to: out, analyzer: FakePlatform.analyzer)
        #expect(f.pathExtension == "jpg")
        #expect(FakePictures.decode(try Data(contentsOf: f)) != nil)
        #expect(try c.memes.assets(of: m.id) == assetsBefore)
        #expect(throws: (any Error).self) { try c.export(m.id, as: .format(.webp), to: out, analyzer: FakePlatform.analyzer) }  // no encoder, no ffmpeg
    }

    @Test func convertMemeKeepsOrDropsTheOriginal() throws {
        let t = try TempCollection()
        let c = t.collection
        let keep = try imageMeme(t, "k.bmp", FakePictures.data("h"))
        let drop = try imageMeme(t, "d.bmp", FakePictures.data("v"))
        let oldDrop = try #require(try c.memes.primaryAsset(of: drop.id))
        let ops = try c.oplog.count()

        let p = try c.convertMeme(keep.id, keepOriginal: true, analyzer: FakePlatform.analyzer)
        #expect(p.ext == "png" && p.sourceExt == "bmp")
        #expect(try c.formats(of: keep.id).original?.ext == "bmp")
        #expect(try c.formats(of: keep.id).primary == c.memes.primaryAsset(of: keep.id))

        _ = try c.convertMeme(drop.id, keepOriginal: false, analyzer: FakePlatform.analyzer)
        #expect(try c.formats(of: drop.id).original == nil)
        #expect(try c.memes.assets(of: drop.id).count == 1)
        #expect(try c.memes.memes(withSHA256: oldDrop.sha256) == [drop.id])   // still found by the old file's hash
        #expect(try c.oplog.count() > ops)                                     // synced like any asset change

        #expect(throws: CollectionError.self) { try c.convertMeme(keep.id, keepOriginal: true, analyzer: FakePlatform.analyzer) }
        #expect(throws: CollectionError.self) { try c.convertMeme(MemeID("nope"), keepOriginal: true, analyzer: FakePlatform.analyzer) }
        // Exporting the original of a converted meme hands back the untouched .bmp.
        let out = try outDir()
        defer { try? FileManager.default.removeItem(at: out) }
        let f = try c.export(keep.id, as: .original, to: out)
        #expect(try Data(contentsOf: f) == FakePictures.data("h") && f.pathExtension == "bmp")
    }
}

@Suite struct ScannerEdgeTests {
    private func meme(_ c: Collection, _ bytes: String, phash: UInt64?, role: Asset.Role = .primary, kind: MemeKind = .image) throws -> MemeID {
        let m = Meme(kind: kind); try c.memes.insert(m)
        let st = try c.media.put(data: Data(bytes.utf8), ext: "jpg")
        try c.memes.addAsset(Asset(memeID: m.id, role: role, sha256: st.sha256, ext: "jpg", mime: "image/jpeg", bytes: st.bytes,
                                   phash: phash.map(PerceptualHash.toInt64)))
        return m.id
    }

    @Test func duplicateScanIgnoresDeletedMemesAndNonPrimaryFiles() throws {
        let t = try TempCollection()
        let c = t.collection
        let a = try meme(c, "same", phash: 1)
        let gone = try meme(c, "same", phash: 1)
        _ = try meme(c, "same", phash: 1, role: .avatar)
        try c.memes.delete(gone)
        #expect(try DuplicateScanner(collection: c).scan().isEmpty)
        try c.memes.undelete(gone)
        let pairs = try DuplicateScanner(collection: c).scan()
        #expect(pairs.count == 1 && Set([pairs[0].a, pairs[0].b]) == [a, gone] && pairs[0].match == .exact)
    }

    @Test func thresholdBoundaryAndDismissIsOrderInsensitive() throws {
        let t = try TempCollection()
        let c = t.collection
        let base: UInt64 = 0xF0F0_F0F0_F0F0_F0F0
        let a = try meme(c, "a", phash: base)
        let atLimit = try meme(c, "b", phash: base ^ 0x3FF)          // 10 bits
        _ = try meme(c, "c", phash: base ^ 0x7FF << 20)              // 11 bits
        let s = DuplicateScanner(collection: c)
        let pairs = try s.scan()
        #expect(pairs.count == 1 && pairs[0].match == .similar(distance: 10))
        #expect(try s.scan(threshold: 0).isEmpty)
        try s.dismiss(atLimit, a)                                     // reversed order
        try s.dismiss(a, atLimit)                                     // and again
        #expect(try s.scan().isEmpty)
    }

    @Test func containmentScanSkipsUndecodableDeletedAndNonImages() throws {
        let t = try TempCollection()
        let c = t.collection
        _ = try meme(c, "x", phash: nil)
        _ = try meme(c, "v", phash: nil, kind: .video)
        let decoded = Locked(0)
        let results = try ContainmentScanner(collection: c) { _ in decoded.value += 1; return nil }.scan()
        #expect(results.isEmpty)
        #expect(decoded.value == 1)                                   // only the image was even tried
        let progress = Locked<[Int]>([])
        _ = try ContainmentScanner(collection: c) { _ in nil }.scan(maxImages: 0) { done, _ in progress.mutate { $0.append(done) } }
        #expect(progress.value == [0])
    }
}
