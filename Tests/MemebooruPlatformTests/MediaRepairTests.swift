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
private var ffmpeg: FFmpegTranscoder? { platform.transcoder as? FFmpegTranscoder }

/// A throwaway collection, removed when done.
private final class TempCollection: @unchecked Sendable {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("mb-repair-\(UUID().uuidString).memebooru")
    let collection: Collection
    init() throws { collection = try Collection.create(at: url) }
    deinit { try? FileManager.default.removeItem(at: url) }
}

@Suite(.serialized) struct MediaRepairTests {
    private static let dir: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("mb-repair-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private static func video(_ name: String, size: String, extra: [String] = []) throws -> URL {
        let out = dir.appendingPathComponent(name)
        try ffmpeg!.runFFmpeg(["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=\(size):rate=10", "-t", "1",
                               "-pix_fmt", "yuv420p"] + extra + [out.path])
        return out
    }

    @Test func phoneVideosHeldUprightReportTheirShownSize() throws {
        guard let ffmpeg else { return }
        let plain = try Self.video("plain.mp4", size: "320x180")
        let turned = Self.dir.appendingPathComponent("turned.mp4")
        try ffmpeg.runFFmpeg(["-v", "error", "-y", "-display_rotation", "90", "-i", plain.path, "-c", "copy", turned.path])
        let p = try ffmpeg.probe(plain), r = try ffmpeg.probe(turned)
        #expect(p.width == 320 && p.height == 180)
        #expect(r.width == 180 && r.height == 320)                   // as it plays, not as it's stored
        let upside = Self.dir.appendingPathComponent("upside.mp4")
        try ffmpeg.runFFmpeg(["-v", "error", "-y", "-display_rotation", "180", "-i", plain.path, "-c", "copy", upside.path])
        #expect(try ffmpeg.probe(upside).width == 320)                 // a half turn keeps the shape
    }

    @Test func postsSavedWithoutASizeAreMeasuredOnce() throws {
        guard ffmpeg != nil else { return }
        let t = try TempCollection()
        let c = t.collection
        let analyzer = MediaAnalyzer(platform: platform)
        let item = try c.staging.add(file: try Self.video("v.mp4", size: "640x360"), source: "test")
        let meme = try c.staging.commit(item.id)
        // As an older version saved it: no size, no codecs.
        try c.db.run("UPDATE asset SET width = NULL, height = NULL, codecs = NULL WHERE meme_id = ?", [meme.id.rawValue])
        // And a file that can't be read at all.
        let broken = Meme(kind: .video, presentation: .native)
        try c.memes.insert(broken)
        let junk = Self.dir.appendingPathComponent("junk.mp4")
        try Data("not a video".utf8).write(to: junk)
        let st = try c.media.put(junk, ext: "mp4", move: false)
        try c.memes.addAsset(Asset(memeID: broken.id, role: .primary, sha256: st.sha256, ext: "mp4", mime: "video/mp4", bytes: st.bytes))

        #expect(try c.fillMissingMediaSizes(analyzer: analyzer) == 1)
        let a = try #require(try c.memes.primaryAsset(of: meme.id))
        #expect(a.width == 640 && a.height == 360 && a.codecs != nil)
        let b = try #require(try c.memes.primaryAsset(of: broken.id))
        #expect(b.width == 0 && b.height == 0)                         // tried; not tried again
        #expect(try c.fillMissingMediaSizes(analyzer: analyzer) == 0)
        #expect(try c.db.scalarInt("SELECT count(*) FROM asset WHERE width IS NULL AND role = 'primary' AND ext = 'mp4'") == 0)
    }

    @Test func stoppingEarlyLeavesTheRestForNextTime() throws {
        let t = try TempCollection()
        let c = t.collection
        for i in 0..<3 {
            let f = Self.dir.appendingPathComponent("p\(i).ppm")
            try Data("P6\n2 1\n255\n\u{0}\u{0}\u{0}\u{FF}\u{FF}\u{FF}".utf8).write(to: f)
            let m = Meme(kind: .image, presentation: .native)
            try c.memes.insert(m)
            let st = try c.media.put(f, ext: "png", move: false)
            try c.memes.addAsset(Asset(memeID: m.id, role: .primary, sha256: st.sha256, ext: "png", mime: "image/png", bytes: st.bytes))
        }
        #expect(try c.fillMissingMediaSizes(analyzer: MediaAnalyzer(platform: platform), isCancelled: { true }) == 0)
        #expect(try c.db.scalarInt("SELECT count(*) FROM asset WHERE width IS NULL") == 3)
    }
}
