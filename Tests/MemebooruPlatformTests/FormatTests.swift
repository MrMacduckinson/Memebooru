import Foundation
import Testing
import MemebooruCore
#if canImport(ImageIO)
import MemebooruPlatformApple
#endif
#if os(Linux)
import MemebooruPlatformLinux
#endif

/// Real ffmpeg: the repo's own macOS build when present (Vendor/ffmpeg/bin), else whatever is installed.
private func makePlatform() -> Platform {
    let vendor = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Vendor/ffmpeg/bin")
    #if canImport(ImageIO)
    return PlatformApple.make(ffmpegDirs: [vendor])
    #else
    return PlatformLinux.make()
    #endif
}

private let platform = makePlatform()
private let analyzer = MediaAnalyzer(platform: platform)
private var ffmpeg: FFmpegTranscoder? { platform.transcoder as? FFmpegTranscoder }

/// Samples made on the fly with the same ffmpeg (lavfi test sources).
private enum Samples {
    static let dir: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("mb-formats-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static func make(_ name: String, _ args: [String]) throws -> URL {
        let out = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: out.path) { return out }
        try ffmpeg!.runFFmpeg(["-v", "error", "-y"] + args + [out.path])
        return out
    }

    static let video = ["-f", "lavfi", "-i", "testsrc2=s=320x240:d=2:r=25", "-f", "lavfi", "-i", "sine=d=2"]
    static func webm() throws -> URL { try make("clip.webm", video + ["-c:v", "libvpx-vp9", "-b:v", "300k", "-c:a", "libopus", "-shortest"]) }
    static func mkv() throws -> URL { try make("clip.mkv", video + ["-c:v", "libvpx-vp9", "-b:v", "300k", "-c:a", "flac", "-shortest"]) }
    static func avi() throws -> URL { try make("clip.avi", video + ["-c:v", "mpeg4", "-c:a", "pcm_s16le", "-shortest"]) }
    static func movH264() throws -> URL {
        let enc = ffmpeg!.encoders.contains("libx264") ? "libx264" : "h264_videotoolbox"
        return try make("clip.mov", video + ["-c:v", enc, "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest"])
    }
    static func flac() throws -> URL { try make("tone.flac", ["-f", "lavfi", "-i", "sine=d=2", "-c:a", "flac"]) }
    /// 64×64 PNG, fully transparent except a red square in the middle.
    static func alphaPNG() throws -> URL {
        try make("alpha.png", ["-f", "lavfi", "-i", "color=c=black@0.0:s=64x64,format=rgba", "-f", "lavfi", "-i", "color=c=red:s=32x32",
                              "-filter_complex", "[0][1]overlay=16:16,format=rgba", "-frames:v", "1"])
    }
    static func bmp() throws -> URL { try make("pic.bmp", ["-f", "lavfi", "-i", "testsrc2=s=200x100", "-frames:v", "1", "-pix_fmt", "bgr24"]) }
}

private func tempCollection() throws -> Collection {
    try Collection.create(at: FileManager.default.temporaryDirectory.appendingPathComponent("mb-fmt-\(UUID().uuidString).memebooru"))
}

private func commit(_ c: Collection, _ file: URL, convert: Bool? = nil, keep: Bool? = nil, tag: String = "t") throws -> Meme {
    let s = StagingArea(collection: c, analyzer: analyzer)
    let item = try s.add(file: file, source: "test", extraTags: [tag])
    return try s.commit(item.id, convert: convert, keepOriginal: keep)
}

@Suite(.serialized, .enabled(if: platform.transcoder != nil)) struct FormatTests {
    @Test func policyClassifiesByContainerAndCodec() {
        #expect(FormatPolicy.compatibility(kind: .video, ext: "mp4", codecs: "mp4/h264/aac") == .popular)
        #expect(FormatPolicy.compatibility(kind: .video, ext: "mp4", codecs: "mp4/av1/aac") == .uncommon)
        #expect(FormatPolicy.compatibility(kind: .video, ext: "mp4", codecs: "mp4/h264/opus") == .uncommon)
        #expect(FormatPolicy.compatibility(kind: .video, ext: "mov", codecs: "mov/h264/aac") == .uncommon)
        #expect(FormatPolicy.compatibility(kind: .video, ext: "webm", codecs: nil) == .uncommon)
        #expect(FormatPolicy.compatibility(kind: .image, ext: "heic", codecs: nil) == .uncommon)
        #expect(FormatPolicy.compatibility(kind: .image, ext: "webp", codecs: nil) == .popular)
        #expect(FormatPolicy.compatibility(kind: .audio, ext: "flac", codecs: nil) == .uncommon)
        #expect(FormatPolicy.popularTarget(kind: .image, ext: "heic", codecs: "heic/hevc/-") == .jpeg)
        #expect(FormatPolicy.popularTarget(kind: .image, ext: "heic", codecs: "heic/hevc/-+a") == .png)
        #expect(FormatPolicy.popularTarget(kind: .image, ext: "bmp", codecs: nil) == .png)
        #expect(FormatPolicy.label(ext: "mkv", codecs: "mkv/av1/opus") == "MKV · AV1 · Opus")
        #expect(FormatPolicy.label(ext: "heic", codecs: "heic/hevc/-") == "HEIC")
        #expect(MediaProbe(codecs: "webm/vp9/opus+a")?.hasAlpha == true)
    }

    @Test func probeReadsContainersAndCodecs() throws {
        let t = try #require(platform.transcoder)
        let w = try t.probe(Samples.webm())
        #expect(w.video == "vp9" && w.audio == "opus" && w.width == 320 && (w.durationMs ?? 0) > 1500)
        #expect(try t.probe(Samples.avi()).video == "mpeg4")
        #expect(try t.probe(Samples.alphaPNG()).hasAlpha)
    }

    /// WebM (VP9 + Opus) → MP4 (H.264 + AAC), original kept, thumbnail + hashes + real size and length.
    @Test func importConvertsAndKeepsOriginal() throws {
        let c = try tempCollection()
        let meme = try commit(c, Samples.webm(), keep: true)
        let (primary, original) = try c.formats(of: meme.id)
        let p = try #require(primary), o = try #require(original)
        #expect(meme.kind == .video && p.ext == "mp4" && p.codecs?.hasPrefix("mp4/h264/aac") == true)
        #expect(p.compatibility(kind: .video) == .popular && p.sourceLabel == "WebM · VP9 · Opus")
        #expect(o.ext == "webm" && o.compatibility(kind: .video) == .uncommon && p.sourceSHA256 == o.sha256)
        #expect(p.width == 320 && p.height == 240 && (p.durationMs ?? 0) > 1500 && p.phash != nil)
        #expect(FileManager.default.fileExists(atPath: c.media.thumbURL(sha256: p.sha256).path))
        #expect(c.media.exists(sha256: o.sha256, ext: "webm"))

        // Re-importing the same WebM is caught as an exact duplicate (via the converted file's source).
        let again = try StagingArea(collection: c, analyzer: analyzer).add(file: Samples.webm(), source: "test")
        #expect(try StagingArea(collection: c, analyzer: analyzer).duplicates(of: again).contains { $0.memeID == meme.id })
    }

    @Test func importConvertsWithoutKeepingOriginal() throws {
        let c = try tempCollection()
        let meme = try commit(c, Samples.avi())
        let (p, o) = try c.formats(of: meme.id)
        #expect(o == nil && p?.ext == "mp4" && p?.sourceLabel == "AVI · MPEG-4 · PCM")
    }

    /// Declining conversion stores the uncommon file — and it still gets a thumbnail, size and hashes.
    @Test func keepAsIsStillGetsThumbnailAndMetadata() throws {
        let c = try tempCollection()
        let meme = try commit(c, Samples.mkv(), convert: false)
        let p = try #require(try c.formats(of: meme.id).primary)
        #expect(p.ext == "mkv" && p.compatibility(kind: .video) == .uncommon && p.formatLabel == "MKV · VP9 · FLAC")
        #expect(p.width == 320 && (p.durationMs ?? 0) > 1500 && p.phash != nil)
        #expect(FileManager.default.fileExists(atPath: c.media.thumbURL(sha256: p.sha256).path))

        // Later: convert the stored meme, keeping the MKV as its original.
        let converted = try c.convertMeme(meme.id, keepOriginal: true, analyzer: analyzer)
        let (p2, o2) = try c.formats(of: meme.id)
        #expect(p2?.sha256 == converted.sha256 && p2?.ext == "mp4" && o2?.sha256 == p.sha256 && p2?.sourceLabel == "MKV · VP9 · FLAC")
    }

    @Test func movWithH264IsRemuxedNotReencoded() throws {
        let c = try tempCollection()
        let src = try Samples.movH264()
        let srcVideoBytes = try #require(try FileManager.default.attributesOfItem(atPath: src.path)[.size] as? Int)
        let meme = try commit(c, src)
        let p = try #require(try c.formats(of: meme.id).primary)
        #expect(p.ext == "mp4" && p.codecs?.hasPrefix("mp4/h264") == true)
        // A stream copy stays within a few KB of the source; a re-encode wouldn't.
        #expect(abs(Int(p.bytes) - srcVideoBytes) < 20_000)
    }

    @Test func picturesAndAudioConvertToPopularFormats() throws {
        let c = try tempCollection()
        let bmp = try commit(c, Samples.bmp())
        #expect(try c.formats(of: bmp.id).primary?.ext == "png")            // lossless source stays lossless
        let flac = try commit(c, Samples.flac())
        let a = try #require(try c.formats(of: flac.id).primary)
        #expect(a.ext == "mp3" && (a.durationMs ?? 0) > 1500 && a.sourceLabel == "FLAC")
        let png = try commit(c, Samples.alphaPNG())
        #expect(try c.formats(of: png.id).primary?.ext == "png")            // already popular: untouched
    }

    /// Export never stores anything: the meme keeps exactly its files.
    @Test func exportToAnyFormatWithoutStoring() throws {
        let c = try tempCollection()
        let meme = try commit(c, Samples.webm(), keep: true)
        let before = try c.memes.assets(of: meme.id)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("mb-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let t = try #require(platform.transcoder)

        let stored = try c.export(meme.id, as: .stored, to: out, analyzer: analyzer)
        #expect(stored.pathExtension == "mp4")
        let orig = try c.export(meme.id, as: .original, to: out, analyzer: analyzer)
        #expect(orig.pathExtension == "webm")
        for (format, video, audio) in [(MediaFormat.gif, "gif", nil), (.webmVP9, "vp9", "opus"), (.mp4HEVC, "hevc", "aac"),
                                       (.mkvH264, "h264", "opus"), (.mp3, nil, "mp3"), (.m4a, nil, "aac")] as [(MediaFormat, String?, String?)] {
            let f = try c.export(meme.id, as: .format(format), to: out.appendingPathComponent("x-\(format.rawValue).\(format.ext)"), analyzer: analyzer)
            let p = try t.probe(f)
            #expect(p.video == video && p.audio == audio, "\(format.label): got \(p.codecs)")
        }
        #expect(try c.memes.assets(of: meme.id) == before)
    }

    /// Transparency → a format without alpha is composited onto white, not black.
    @Test func alphaFlattensOntoWhite() throws {
        let c = try tempCollection()
        let meme = try commit(c, Samples.alphaPNG())
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("mb-alpha-\(UUID().uuidString).jpg")
        try c.export(meme.id, as: .format(.jpeg), to: out, analyzer: analyzer)
        let b = try platform.images.decode(out, maxSide: 0)
        let corner = (Int(b.rgba[0]), Int(b.rgba[1]), Int(b.rgba[2]))
        let centre = ((32 * b.width + 32) * 4)
        #expect(corner.0 > 240 && corner.1 > 240 && corner.2 > 240)
        #expect(b.rgba[centre] > 200 && b.rgba[centre + 1] < 60)
    }

    @Test func exportFormatsPerKind() {
        #expect(FormatPolicy.exportFormats(kind: .video).contains(.gif))
        #expect(FormatPolicy.exportFormats(kind: .video, hasAudio: false).contains(.mp3) == false)
        #expect(FormatPolicy.exportFormats(kind: .image).contains(.webp))
        #expect(FormatPolicy.exportFormats(kind: .text).isEmpty)
        #expect(MediaFormat.mp4H264.matches(ext: "mp4", codecs: "mp4/h264/aac"))
        #expect(!MediaFormat.mp4H264.matches(ext: "mp4", codecs: "mp4/av1/aac"))
    }
}
