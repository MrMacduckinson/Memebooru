import Foundation
import Testing
@testable import MemebooruCore
#if canImport(ImageIO)
import MemebooruPlatformApple
#endif
#if os(Linux)
import MemebooruPlatformLinux
#endif

private let platform: Platform = {
    let vendor = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Vendor/ffmpeg/bin")
    #if canImport(ImageIO)
    return PlatformApple.make(ffmpegDirs: [vendor])
    #else
    return PlatformLinux.make()
    #endif
}()
private let analyzer = MediaAnalyzer(platform: platform)

private final class Temp: @unchecked Sendable {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mb-comp-\(UUID().uuidString)", isDirectory: true)
    let collection: Collection
    let staging: StagingArea
    init() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        collection = try Collection.create(at: dir.appendingPathComponent("C.memebooru"))
        staging = StagingArea(collection: collection, analyzer: analyzer)
    }
    deinit { try? FileManager.default.removeItem(at: dir) }

    /// A solid picture of one colour.
    func picture(_ name: String, _ w: Int, _ h: Int, rgb: (UInt8, UInt8, UInt8)) throws -> URL {
        var px = Data(count: w * h * 4)
        for i in 0..<(w * h) { px[i * 4] = rgb.0; px[i * 4 + 1] = rgb.1; px[i * 4 + 2] = rgb.2; px[i * 4 + 3] = 255 }
        let ext = (name as NSString).pathExtension
        let data = try #require(try platform.thumbs.encode(Bitmap(width: w, height: h, rgba: px), as: ext == "png" ? .png : .jpeg, quality: 0.95))
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func stage(_ name: String, _ w: Int, _ h: Int, rgb: (UInt8, UInt8, UInt8), tags: [String] = [], text: String? = nil) throws -> StagedItem {
        var i = try staging.add(file: try picture(name, w, h, rgb: rgb), source: "telegram", textExact: text)
        i.userTags = tags
        try staging.update(i)
        return i
    }
}

/// The colour in the middle of `r` in a decoded picture.
private func colour(_ b: Bitmap, at r: PixelRect) -> (Int, Int, Int) {
    let x = r.x + r.width / 2, y = r.y + r.height / 2
    let i = (y * b.width + x) * 4
    return (Int(b.rgba[i]), Int(b.rgba[i + 1]), Int(b.rgba[i + 2]))
}
private func near(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Bool { abs(a.0 - b.0) < 24 && abs(a.1 - b.1) < 24 && abs(a.2 - b.2) < 24 }

@Suite(.serialized) struct CompositeTests {
    @Test func combinedPictureHasEveryPartInItsPlace() throws {
        let t = try Temp()
        let red = try t.picture("a.png", 300, 600, rgb: (220, 20, 20))
        let blue = try t.picture("b.png", 600, 300, rgb: (20, 20, 220))
        let layout = CompositeLayout(.row, gap: 8)
        let made = try CompositeRenderer(converter: analyzer.converter).render([red, blue], layout: layout)
        #expect(made.ext == "png")
        let out = t.dir.appendingPathComponent("out.png"); try made.data.write(to: out)
        let b = try platform.images.decode(out, maxSide: 0)
        let geo = layout.geometry(for: [PixelSize(width: 300, height: 600), PixelSize(width: 600, height: 300)])
        #expect(b.width == geo.width && b.height == geo.height && b.height == 600)
        #expect(near(colour(b, at: geo.frames[0]), (220, 20, 20)))
        #expect(near(colour(b, at: geo.frames[1]), (20, 20, 220)))
        #expect(near(colour(b, at: PixelRect(x: geo.frames[0].width + 2, y: 290, width: 2, height: 2)), (255, 255, 255)))   // the gap is white
    }

    @Test func photosMakeAJPEG() throws {
        let t = try Temp()
        let made = try CompositeRenderer(converter: analyzer.converter).render(
            [try t.picture("a.jpg", 200, 200, rgb: (10, 200, 10)), try t.picture("b.jpg", 200, 200, rgb: (10, 10, 200))],
            layout: CompositeLayout(.column))
        #expect(made.ext == "jpg" && made.width == 200 && made.height == 400)
    }

    @Test func combineMergesTagsAndTextAndUndoSplitsAgain() throws {
        let t = try Temp()
        let a = try t.stage("part one.jpg", 400, 800, rgb: (200, 0, 0), tags: ["cat", "funny"], text: "first")
        let b = try t.stage("part two.jpg", 400, 800, rgb: (0, 0, 200), tags: ["funny", "dog"], text: "second")
        let c = try t.staging.combine([a.id, b.id])
        #expect(try t.staging.list().map(\.id) == [c.id])                           // the parts are inside it now
        #expect(c.kind == .image && c.payload.composite?.layout.arrangement == .row)  // two tall pictures: side by side
        #expect(c.userTags == ["cat", "funny", "dog"])
        #expect(c.suggestedTags.contains(compositeTag) && c.suggestedTags.contains("picture"))
        #expect(c.textExact == "first\nsecond")
        #expect(c.info.width == 800 && c.info.height == 800)
        #expect(t.staging.parts(c).count == 2)
        #expect(c.originalName == "part one +1.jpg")

        _ = try t.collection.undoLast()
        #expect(Set(try t.staging.list().map(\.id)) == [a.id, b.id])                  // one undo: separate again
    }

    @Test func layoutAndOrderCanChangeAfterwards() throws {
        let t = try Temp()
        let a = try t.stage("a.png", 300, 300, rgb: (200, 0, 0))
        let b = try t.stage("b.png", 300, 300, rgb: (0, 0, 200))
        let c = try t.staging.combine([a.id, b.id], layout: CompositeLayout(.row))
        let r = try t.staging.recombine(c.id, layout: CompositeLayout(.column, size: 200), order: [1, 0])
        #expect(r.info.width == 200 && r.info.height == 400 && r.sha256 != c.sha256)
        let saved = try #require(try t.staging.get(c.id))
        #expect(saved.sha256 == r.sha256 && saved.payload.composite?.layout == CompositeLayout(.column, size: 200))
        // Blue is on top now.
        let b2 = try platform.images.decode(t.staging.fileURL(saved), maxSide: 0)
        #expect(near(colour(b2, at: PixelRect(x: 0, y: 0, width: 200, height: 200)), (0, 0, 200)))
        #expect(throws: (any Error).self) { try t.staging.recombine(c.id, layout: CompositeLayout(.row), order: [0, 0]) }
    }

    @Test func splitGivesTheSeparatePicturesBack() throws {
        let t = try Temp()
        let a = try t.stage("joke.png", 300, 300, rgb: (200, 0, 0), tags: ["meme"])
        let b = try t.stage("joke-2.png", 300, 300, rgb: (0, 0, 200))
        let c = try t.staging.combine([a.id, b.id])
        let parts = try t.staging.split(c.id)
        #expect(parts.count == 2)
        #expect(parts.map(\.originalName) == ["joke 1.png", "joke 2.png"])
        #expect(parts.allSatisfy { $0.userTags == ["meme"] && !$0.suggestedTags.contains(compositeTag) })
        #expect(parts.map(\.sha256) == [a.sha256, b.sha256])                        // untouched originals
        _ = try t.collection.undoLast()
        #expect(try t.staging.list().map(\.id) == [c.id])
    }

    @Test func onlyPicturesCanBeCombined() throws {
        let t = try Temp()
        let a = try t.stage("a.png", 10, 10, rgb: (0, 0, 0))
        let text = try t.staging.add(text: "not a picture", source: "paste")
        #expect(throws: (any Error).self) { try t.staging.combine([a.id, text.id]) }
        #expect(throws: (any Error).self) { try t.staging.combine([a.id]) }
        #expect(throws: (any Error).self) { try t.staging.combine([a.id, a.id]) }
        #expect(throws: (any Error).self) { try t.staging.combine([a.id, "missing"]) }
        #expect(try t.staging.list().count == 2)                                     // nothing changed
    }

    @Test func committedCombinedMemeKeepsItsPartsAndCanBeRelaidOut() throws {
        let t = try Temp()
        let a = try t.stage("a.png", 300, 600, rgb: (200, 0, 0))
        let b = try t.stage("b.png", 300, 600, rgb: (0, 0, 200))
        let c = try t.staging.combine([a.id, b.id])
        let meme = try t.staging.commit(c.id)
        let parts = try t.collection.parts(of: meme.id)
        #expect(parts.count == 2 && parts.map(\.sha256) == [a.sha256, b.sha256] && parts.allSatisfy { $0.phash != nil })
        #expect(try t.collection.memes.tags(of: meme.id).map(\.name).contains(compositeTag))
        #expect(try t.collection.search.search(compositeTag).memes.map(\.id) == [meme.id])

        let primary = try t.collection.recombine(meme.id, layout: CompositeLayout(.column), order: [1, 0], analyzer: analyzer)
        #expect(primary.width == 300 && primary.height == 1200)
        #expect(try t.collection.memes.primaryAsset(of: meme.id)?.sha256 == primary.sha256)
        #expect(try t.collection.parts(of: meme.id).map(\.sha256) == [b.sha256, a.sha256])
        #expect(try t.collection.memes.get(meme.id)?.payload.composite?.layout.arrangement == .column)
        #expect(FileManager.default.fileExists(atPath: t.collection.media.thumbURL(sha256: primary.sha256).path))
    }

    @Test func manyPicturesInAGrid() throws {
        let t = try Temp()
        var ids: [String] = []
        for i in 0..<9 { ids.append(try t.stage("p\(i).jpg", 100 + i * 20, 120, rgb: (UInt8(i * 25), 100, 100)).id) }
        let c = try t.staging.combine(ids)
        #expect(c.payload.composite?.layout == CompositeLayout(.grid, columns: 3))
        #expect(t.staging.parts(c).count == 9)
    }
}
