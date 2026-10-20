import Foundation
import CoreGraphics
import ImageIO
import Testing
import MemebooruCore
@testable import Memebooru

/// Cropping the way the editor sheet does it.
@MainActor
@Suite(.serialized) struct EditAppTests {
    /// A picture with a plain 10-px margin round a checkerboard.
    private func framed(_ f: AppFixture) throws -> StagedItem {
        let w = 80, h = 60
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        for y in 0..<40 { for x in 0..<60 where (x / 5 + y / 5) % 2 == 0 {
            ctx.setFillColor(CGColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1)); ctx.fill(CGRect(x: 10 + x, y: 10 + y, width: 1, height: 1))
        } }
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); CGImageDestinationFinalize(dest)
        let url = f.dir.deletingLastPathComponent().appendingPathComponent("framed.png")
        try (data as Data).write(to: url)
        return try f.staging.add(file: url, source: "test")
    }

    @Test func detectApplyAndUndoOnAStagedPicture() async throws {
        let f = try AppFixture(); defer { f.tearDown() }
        let item = try framed(f)
        f.library.reloadStaging()
        let src = try #require(f.library.editSource(.staged(item.id)))
        #expect(src.kind == .image && src.edit == nil)
        let found = try #require(await f.library.detectBorders(src))
        #expect(found == PixelRect(x: 10, y: 10, width: 60, height: 40))
        let frame = try #require(await f.library.editFrame(src, at: 0.1))
        #expect(frame.size == PixelSize(width: 80, height: 60))

        f.library.editTarget = .staged(item.id)
        f.library.applyEdit(.staged(item.id), MediaEdit(crop: found))
        #expect(f.library.editTarget == nil)                                        // the sheet closes at once
        try await f.eventually("the crop") { f.library.stagedItems.first?.info.width == 60 }
        let edited = try #require(f.library.stagedItems.first)
        #expect(edited.edit?.crop == found)
        // Opened again, the editor starts from the original, with the crop shown.
        let again = try #require(f.library.editSource(.staged(item.id)))
        #expect(again.edit?.crop == found && again.url != f.staging.fileURL(edited))

        f.library.applyEdit(.staged(item.id), nil)
        try await f.eventually("the original back") { f.library.stagedItems.first?.sha256 == item.sha256 }
    }

    @Test func savedPostsToo() async throws {
        let f = try AppFixture(); defer { f.tearDown() }
        let item = try framed(f)
        let meme = try f.staging.commit(item.id)
        f.library.runSearch(reset: true)
        let src = try #require(f.library.editSource(.meme(meme.id)))
        #expect(src.edit == nil)
        f.library.applyEdit(.meme(meme.id), MediaEdit(crop: PixelRect(x: 10, y: 10, width: 60, height: 40)))
        try await f.eventually("the crop") { (try f.collection.memes.primaryAsset(of: meme.id))?.width == 60 }
        #expect(f.library.aspect(for: try #require(f.library.meme(meme.id))) == 1.5)
        #expect(f.library.editSource(.meme(meme.id))?.edit != nil)
    }

    @Test func timeFields() {
        #expect(TimeField.format(0) == "0:00.000" && TimeField.format(62_345) == "1:02.345")
        #expect(TimeField.parse("1:02.345") == 62_345 && TimeField.parse("2.5") == 2500 && TimeField.parse("0,25") == 250)
        #expect(TimeField.parse("abc") == nil && TimeField.parse("-1") == nil && TimeField.parse("1:2:3") == nil)
    }
}
