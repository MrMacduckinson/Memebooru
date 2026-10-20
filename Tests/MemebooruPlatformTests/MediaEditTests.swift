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
private var ffmpeg: FFmpegTranscoder? { platform.transcoder as? FFmpegTranscoder }

private final class Temp: @unchecked Sendable {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mb-edit-\(UUID().uuidString)", isDirectory: true)
    let collection: Collection
    let staging: StagingArea
    init() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        collection = try Collection.create(at: dir.appendingPathComponent("C.memebooru"))
        staging = StagingArea(collection: collection, analyzer: analyzer)
    }
    deinit { try? FileManager.default.removeItem(at: dir) }

    /// A picture with a `border`-coloured frame round a red/blue checkerboard.
    func framed(_ name: String, _ w: Int, _ h: Int, inner: PixelRect, border: (UInt8, UInt8, UInt8)) throws -> URL {
        var px = Data(count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4
            let inside = x >= inner.x && x < inner.x + inner.width && y >= inner.y && y < inner.y + inner.height
            let c: (UInt8, UInt8, UInt8) = inside ? (((x / 4 + y / 4) % 2 == 0) ? (220, 30, 30) : (30, 30, 220)) : border
            px[i] = c.0; px[i + 1] = c.1; px[i + 2] = c.2; px[i + 3] = 255
        } }
        let ext = (name as NSString).pathExtension
        let data = try #require(try platform.thumbs.encode(Bitmap(width: w, height: h, rgba: px), as: ext == "png" ? .png : .jpeg, quality: 0.95))
        let url = dir.appendingPathComponent(name); try data.write(to: url); return url
    }

    func ff(_ name: String, _ args: [String]) throws -> URL {
        let out = dir.appendingPathComponent(name)
        try ffmpeg!.runFFmpeg(["-v", "error", "-y"] + args + [out.path])
        return out
    }
}

@Suite(.serialized) struct MediaEditTests {
    @Test func pictureBordersAreFoundCutAndUndone() throws {
        let t = try Temp()
        let inner = PixelRect(x: 24, y: 16, width: 200, height: 120)
        let item = try t.staging.add(file: try t.framed("framed.png", 248, 152, inner: inner, border: (250, 250, 250)), source: "test")
        let editor = MediaEditor(analyzer: analyzer)
        #expect(try editor.detectBorders(t.staging.fileURL(item), kind: .image) == inner)

        let cut = try t.staging.applyEdit(item.id, MediaEdit(crop: inner))
        #expect(cut.info.width == 200 && cut.info.height == 120 && cut.ext == "png" && cut.edit?.crop == inner)
        #expect(t.staging.original(cut) != nil && cut.sha256 != item.sha256)
        #expect(try editor.detectBorders(t.staging.fileURL(cut), kind: .image) == nil)          // nothing left to cut
        // Edits always start from the original: a second crop isn't a crop of the crop.
        let wider = try t.staging.applyEdit(item.id, MediaEdit(crop: PixelRect(x: 0, y: 0, width: 248, height: 100)))
        #expect(wider.info.width == 248 && wider.info.height == 100)
        // Undone: the original is the item again, byte for byte.
        let back = try t.staging.applyEdit(item.id, nil)
        #expect(back.sha256 == item.sha256 && back.edit == nil && t.staging.original(back) == nil)
        #expect(try t.staging.applyEdit(item.id, MediaEdit()).sha256 == item.sha256)              // empty edit: nothing happens
    }

    @Test func photosStayJPEGAndKeepRotation() throws {
        let t = try Temp()
        let item = try t.staging.add(file: try t.framed("photo.jpg", 160, 100, inner: PixelRect(x: 10, y: 10, width: 140, height: 80), border: (0, 0, 0)), source: "test")
        let cut = try t.staging.applyEdit(item.id, MediaEdit(crop: PixelRect(x: 10, y: 10, width: 140, height: 80)))
        #expect(cut.ext == "jpg" && cut.info.width == 140)
    }

    @Test func committedEditKeepsTheOriginalAndCanChangeLater() throws {
        let t = try Temp()
        let inner = PixelRect(x: 20, y: 20, width: 100, height: 60)
        let item = try t.staging.add(file: try t.framed("p.png", 140, 100, inner: inner, border: (0, 0, 0)), source: "test")
        _ = try t.staging.applyEdit(item.id, MediaEdit(crop: inner))
        let meme = try t.staging.commit(item.id)
        let (primary, original) = try t.collection.formats(of: meme.id)
        #expect(primary?.edit?.crop == inner && primary?.width == 100)
        #expect(original?.sha256 == item.sha256 && primary?.sourceSHA256 == item.sha256)
        #expect(primary?.sourceLabel == nil)                                                   // same format: not "converted"

        // Re-crop the saved post from its original; then undo the crop entirely.
        let p2 = try t.collection.applyEdit(meme.id, MediaEdit(crop: PixelRect(x: 0, y: 0, width: 70, height: 100)), analyzer: analyzer)
        #expect(p2.width == 70 && p2.height == 100)
        let p3 = try t.collection.applyEdit(meme.id, nil, analyzer: analyzer)
        #expect(p3.sha256 == item.sha256 && p3.edit == nil)
        #expect(try t.collection.formats(of: meme.id).original?.sha256 == item.sha256)         // still kept

        // Export shows what's shown: an edited post exports cropped, not from the original.
        _ = try t.collection.applyEdit(meme.id, MediaEdit(crop: inner), analyzer: analyzer)
        let out = try t.collection.export(meme.id, as: .format(.jpeg), to: t.dir.appendingPathComponent("e.jpg"), analyzer: analyzer)
        #expect(try platform.images.imageSize(out) == (100, 60))
    }

    @Test func savedPostsWithoutAnOriginalGetOneOnFirstEdit() throws {
        let t = try Temp()
        let item = try t.staging.add(file: try t.framed("p.png", 80, 80, inner: PixelRect(x: 8, y: 8, width: 64, height: 64), border: (255, 255, 255)), source: "test")
        let meme = try t.staging.commit(item.id)
        #expect(try t.collection.formats(of: meme.id).original == nil)
        #expect(try t.collection.applyEdit(meme.id, nil, analyzer: analyzer).sha256 == item.sha256)   // nothing to undo
        _ = try t.collection.applyEdit(meme.id, MediaEdit(crop: PixelRect(x: 8, y: 8, width: 64, height: 64)), analyzer: analyzer)
        #expect(try t.collection.formats(of: meme.id).original?.sha256 == item.sha256)
    }

    @Test func videoBarsAreCutAndEndsTrimmed() throws {
        guard let ff = ffmpeg else { return }
        let h264 = ff.encoders.contains("libx264") ? "libx264" : "h264_videotoolbox"
        let t = try Temp()
        // 320×240 with a 320×160 picture: 40-px black bars top and bottom, 3 s long, with sound.
        let src = try t.ff("bars.mp4", ["-f", "lavfi", "-i", "testsrc=size=320x160:rate=15", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100",
                                       "-t", "3", "-vf", "pad=320:240:0:40:black", "-c:v", h264, "-b:v", "1M", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest"])
        let item = try t.staging.add(file: src, source: "test")
        let editor = MediaEditor(analyzer: analyzer)
        let found = try #require(try editor.detectBorders(t.staging.fileURL(item), kind: .video))
        #expect(abs(found.y - 40) <= 2 && abs(found.height - 160) <= 4 && found.width == 320)

        let cut = try t.staging.applyEdit(item.id, MediaEdit(crop: PixelRect(x: 3, y: 41, width: 315, height: 157), trim: TimeRange(startMs: 500, endMs: 2000)))
        let p = try ffmpeg!.probe(t.staging.fileURL(cut))
        #expect(p.width == 314 && p.height == 156)                                         // evened for H.264
        #expect(p.video == "h264" && p.audio == "aac")
        #expect(abs((p.durationMs ?? 0) - 1500) <= 120)
    }

    @Test func gifsAreCroppedFrameByFrame() throws {
        guard ffmpeg != nil else { return }
        let t = try Temp()
        let src = try t.ff("a.gif", ["-f", "lavfi", "-i", "testsrc=size=120x80:rate=10", "-t", "1", "-vf", "pad=160:120:20:20:white"])
        let item = try t.staging.add(file: src, source: "test")
        let found = try #require(try MediaEditor(analyzer: analyzer).detectBorders(t.staging.fileURL(item), kind: .gif))
        #expect(abs(found.x - 20) <= 1 && abs(found.width - 120) <= 2)
        let cut = try t.staging.applyEdit(item.id, MediaEdit(crop: found))
        #expect(cut.ext == "gif" && cut.kind == .gif)
        let p = try ffmpeg!.probe(t.staging.fileURL(cut))
        #expect(p.width == found.width && p.height == found.height)
        #expect((p.durationMs ?? 0) >= 800)                                               // still animated, same length
    }

    @Test func soundsLoseTheirQuietEnds() throws {
        guard ffmpeg != nil else { return }
        let t = try Temp()
        // 1 s of nothing, 1.5 s of tone, 1 s of nothing.
        let src = try t.ff("s.mp3", ["-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono", "-f", "lavfi", "-i", "sine=frequency=330:sample_rate=44100",
                                    "-filter_complex", "[0]atrim=0:1[a];[1]atrim=0:1.5[b];[0]atrim=0:1[c];[a][b][c]concat=n=3:v=0:a=1",
                                    "-c:a", "libmp3lame", "-q:a", "4"])
        let item = try t.staging.add(file: src, source: "test")
        let editor = MediaEditor(analyzer: analyzer)
        let r = try #require(try editor.detectSilence(t.staging.fileURL(item)))
        #expect(abs(r.startMs - 1000) <= 150 && abs(r.endMs - 2500) <= 250)
        let wave = try editor.waveform(t.staging.fileURL(item), count: 100)
        #expect(wave.peaks.count == 100 && abs(wave.durationMs - 3500) <= 200)

        let cut = try t.staging.applyEdit(item.id, MediaEdit(trim: r))
        #expect(cut.ext == "mp3" && abs((cut.info.durationMs ?? 0) - r.durationMs) <= 150)
        #expect(try editor.detectSilence(t.staging.fileURL(cut)) == nil)                    // nothing quiet left
    }

    @Test func whatCantBeEdited() throws {
        let t = try Temp()
        let text = try t.staging.add(text: "words", source: "test")
        #expect(throws: (any Error).self) { try t.staging.applyEdit(text.id, MediaEdit(crop: PixelRect(x: 0, y: 0, width: 1, height: 1))) }
        let pic = try t.staging.add(file: try t.framed("p.png", 40, 40, inner: PixelRect(x: 4, y: 4, width: 32, height: 32), border: (0, 0, 0)), source: "test")
        #expect(throws: (any Error).self) { try t.staging.applyEdit(pic.id, MediaEdit(trim: TimeRange(startMs: 0, endMs: 100))) }   // pictures have no time
        #expect(throws: (any Error).self) { try t.staging.applyEdit(pic.id, MediaEdit(crop: PixelRect(x: 0, y: 0, width: 0, height: 5))) }
        #expect(try t.staging.get(pic.id)?.sha256 == pic.sha256)                                // untouched after errors
    }
}
