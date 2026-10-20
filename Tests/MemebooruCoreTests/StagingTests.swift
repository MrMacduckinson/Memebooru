import Foundation
import Testing
@testable import MemebooruCore

@Suite struct StagingTests {
    @Test func stageCommitFlow() throws {
        let t = try TempCollection()
        let c = t.collection
        let staging = StagingArea(collection: c, analyzer: nil)
        let src = t.url.appendingPathComponent("obed.jpg")
        try Data("not really a jpeg".utf8).write(to: src)

        let item = try staging.add(file: src, source: "test", date: Date(timeIntervalSince1970: 1_650_000_000), extraTags: ["source_unknown"])
        #expect(item.kind == .image && item.ext == "jpg")
        #expect(item.suggestedTags == ["2022", "picture", "source_unknown"])
        #expect(try staging.count() == 1)
        #expect(FileManager.default.fileExists(atPath: staging.fileURL(item).path))

        var edited = item
        edited.userTags = ["stalin", "child"]
        edited.textExact = "обед"
        try staging.update(edited)

        let meme = try staging.commit(item.id)
        #expect(try staging.count() == 0)
        #expect(!FileManager.default.fileExists(atPath: staging.fileURL(item).path))
        let tags = try c.memes.tags(of: meme.id)
        #expect(tags.map(\.name) == ["2022", "picture", "source_unknown", "child", "stalin"])
        #expect(tags.filter { $0.kind == .meta }.map(\.name) == ["2022", "picture", "source_unknown"])
        #expect(try c.memes.get(meme.id)?.textExact == "обед")
        let asset = try c.memes.primaryAsset(of: meme.id)
        #expect(asset?.sha256 == item.sha256)
        #expect(c.media.exists(sha256: item.sha256, ext: "jpg"))
    }

    @Test func detectsExactDuplicateOfCommittedMeme() throws {
        let t = try TempCollection()
        let staging = StagingArea(collection: t.collection, analyzer: nil)
        let src = t.url.appendingPathComponent("a.png")
        try Data("same bytes".utf8).write(to: src)
        let first = try staging.add(file: src, source: "test")
        let meme = try staging.commit(first.id)
        let again = try staging.add(file: src, source: "test")
        #expect(try staging.duplicates(of: again) == [DuplicateHit(memeID: meme.id, match: .exact)])
        let third = try staging.add(file: src, source: "test")
        #expect(try staging.duplicates(of: third).contains { $0.match == .stagedExact(id: again.id) })
        try staging.discard(again.id); try staging.discard(third.id)
        #expect(try staging.count() == 0)
    }

    @Test func textMemeFromString() throws {
        let t = try TempCollection()
        let staging = StagingArea(collection: t.collection, analyzer: nil)
        let item = try staging.add(text: "Анекдот про Штирлица", source: "paste")
        #expect(item.kind == .text && item.textVerbatim == "Анекдот про Штирлица" && item.info.phash != nil)
        let m = try staging.commit(item.id, tags: ["stirlitz", "text"])
        #expect(try t.collection.search.search("\"штирлица\"").memes.map(\.id) == [m.id])
    }

    @Test func folderImportSkipsUnsupported() throws {
        let t = try TempCollection()
        let dir = t.url.appendingPathComponent("in")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent("a.jpg"))
        try Data("y".utf8).write(to: dir.appendingPathComponent("sub/b.mp4"))
        try Data("z".utf8).write(to: dir.appendingPathComponent("c.exe"))
        let staging = StagingArea(collection: t.collection, analyzer: nil)
        let r = try FolderImporter(staging: staging).importFiles([dir])
        #expect(r.staged.map(\.kind) == [.image, .video])
        #expect(r.skipped.count == 1)
        #expect(r.staged.allSatisfy { $0.suggestedTags.contains("source_unknown") })
    }
}
