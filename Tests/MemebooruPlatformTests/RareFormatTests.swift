import Foundation
import Testing
import MemebooruCore

/// One format through the whole pipeline: detect → analyze/probe → thumbnail → compatibility →
/// import with the default conversion → the stored file really is the popular target.
struct FormatCase: Sendable, CustomTestStringConvertible {
    enum Source: Sendable {
        case ffmpeg([String])
        case fixture(String)
    }
    var file: String
    var source: Source
    var kind: MemeKind
    var compat: Compatibility
    /// The popular format an uncommon file converts to by default.
    var target: MediaFormat? = nil
    /// MediaType knows the extension; otherwise it's imported with an explicit kind (as the importers do for unknown files).
    var detected = true
    /// Display size (images/video).
    var size: (Int, Int)? = nil
    /// Expected duration (video/audio).
    var seconds: Double? = nil
    /// Transparency as probed; nil = decoder-dependent (ffmpeg decodes every GIF as BGRA).
    var alpha: Bool? = false
    /// Codecs of the converted file: (video, audio).
    var after: (String?, String?)? = nil
    /// ffmpeg encoders needed to make the sample.
    var needs: [String] = []
    /// Only where the OS decoder reads it (ImageIO): HEIC, animated WebP… Linux's stb + distro ffmpeg can't.
    var appleOnly = false
    /// A defect of the Linux media stack (stb + Ubuntu's ffmpeg 6.1): recorded there as a known issue.
    var linuxIssue: String? = nil

    var testDescription: String { file }
    var ext: String { MediaStore.normalizeExt((file as NSString).pathExtension) }
    var visual: Bool { kind == .image || kind == .gif || kind == .video }

    var available: Bool {
        guard MT.hasFFmpeg, needs.allSatisfy(MT.has) else { return false }
        return !appleOnly || MT.isApple
    }

    func make() throws -> URL {
        switch source {
        case .ffmpeg(let args): return try MT.make("rare-" + file, args)
        case .fixture(let name):
            let url = MT.fixture(name)
            try #require(FileManager.default.fileExists(atPath: url.path), "missing fixture \(name)")
            return url.lastPathComponent == file ? url : try MT.copy(url, as: file)
        }
    }

    /// Size after conversion: H.264 4:2:0 needs even sides (rounded down, never below 2).
    var sizeAfter: (Int, Int)? {
        guard let (w, h) = size else { return nil }
        guard kind == .video else { return (w, h) }
        return (max(2, w / 2 * 2), max(2, h / 2 * 2))
    }
}

extension FormatCase {
    static let h264 = MT.h264 ?? "libx264"
    static let av1 = MT.av1 ?? "libsvtav1"
    static let v1s = MT.pattern("192x108")
    static let a1s = MT.tone()
    static let still160 = ["-f", "lavfi", "-i", "testsrc2=s=160x90", "-frames:v", "1"]

    static let all: [FormatCase] = images + animations + videos + audio

    static let images: [FormatCase] = [
        FormatCase(file: "pic.avif", source: .ffmpeg(still160 + ["-c:v", av1]), kind: .image, compat: .uncommon, target: .jpeg,
                   size: (160, 90), needs: [av1]),
        // Alpha lives in a second (auxiliary) AV1 stream: it must still be seen, so the picture stays lossless PNG.
        FormatCase(file: "alpha.avif", source: .fixture("alpha.avif"), kind: .image, compat: .uncommon, target: .png,
                   size: (64, 48), alpha: true,
                   linuxIssue: "ffmpeg 6.1 doesn't read AVIF's alpha item: transparency lost, converted onto black"),
        FormatCase(file: "pic.heic", source: .fixture("pic.heic"), kind: .image, compat: .uncommon, target: .jpeg,
                   size: (64, 48), appleOnly: true),
        FormatCase(file: "alpha.heic", source: .fixture("alpha.heic"), kind: .image, compat: .uncommon, target: .png,
                   size: (64, 48), alpha: true, appleOnly: true),
        FormatCase(file: "pic.heif", source: .fixture("pic.heic"), kind: .image, compat: .uncommon, target: .jpeg,
                   size: (64, 48), appleOnly: true),
        FormatCase(file: "pic.jxl", source: .fixture("pic.jxl"), kind: .image, compat: .uncommon, target: .jpeg,
                   size: (64, 48), appleOnly: true),
        FormatCase(file: "alpha.webp", source: .fixture("alpha.webp"), kind: .image, compat: .popular, size: (64, 48), alpha: true),
        FormatCase(file: "pic.bmp", source: .ffmpeg(still160 + ["-pix_fmt", "bgr24"]), kind: .image, compat: .uncommon, target: .png,
                   size: (160, 90)),
        FormatCase(file: "pic.tiff", source: .ffmpeg(still160 + ["-c:v", "tiff"]), kind: .image, compat: .uncommon, target: .png,
                   size: (160, 90)),
        FormatCase(file: "pic.tif", source: .ffmpeg(still160 + ["-c:v", "tiff", "-f", "image2"]), kind: .image, compat: .uncommon,
                   target: .png, size: (160, 90)),
        // ICO/TGA/PPM aren't in MediaType's table: imported only with an explicit kind. Not in the
        // lossless list either, so they become JPEG (unless transparent).
        FormatCase(file: "pic.ico", source: .ffmpeg(["-f", "lavfi", "-i", "testsrc2=s=64x48", "-frames:v", "1"]), kind: .image,
                   compat: .uncommon, target: .jpeg, detected: false, size: (64, 48)),
        FormatCase(file: "alpha.ico", source: .ffmpeg(MT.alphaStill(64, 64) + ["-c:v", "png"]), kind: .image, compat: .uncommon,
                   target: .png, detected: false, size: (64, 64), alpha: true),
        FormatCase(file: "pic.tga", source: .ffmpeg(still160 + ["-c:v", "targa"]), kind: .image, compat: .uncommon, target: .jpeg,
                   detected: false, size: (160, 90)),
        FormatCase(file: "pic.ppm", source: .ffmpeg(still160 + ["-c:v", "ppm"]), kind: .image, compat: .uncommon, target: .jpeg,
                   detected: false, size: (160, 90)),
        FormatCase(file: "deep.png", source: .ffmpeg(still160 + ["-pix_fmt", "rgb48be"]), kind: .image, compat: .popular, size: (160, 90)),
        FormatCase(file: "deepalpha.png", source: .ffmpeg(MT.alphaStill(64, 48) + ["-pix_fmt", "rgba64be"]), kind: .image,
                   compat: .popular, size: (64, 48), alpha: true),
        FormatCase(file: "alpha.png", source: .ffmpeg(MT.alphaStill(64, 48)), kind: .image, compat: .popular, size: (64, 48), alpha: true),
        FormatCase(file: "gray.jpg", source: .fixture("gray.jpg"), kind: .image, compat: .popular, size: (64, 48)),
        // ffmpeg decodes CMYK JPEG as "yuva444p" — that is not transparency.
        FormatCase(file: "cmyk.jpg", source: .fixture("cmyk.jpg"), kind: .image, compat: .popular, size: (64, 48)),
        FormatCase(file: "progressive.jpg", source: .fixture("progressive.jpg"), kind: .image, compat: .popular, size: (64, 48)),
        FormatCase(file: "progressive.JPEG", source: .fixture("progressive.jpg"), kind: .image, compat: .popular, size: (64, 48)),
    ]

    static let animations: [FormatCase] = [
        FormatCase(file: "anim.webp", source: .fixture("anim.webp"), kind: .image, compat: .popular, size: (64, 48), appleOnly: true),
        FormatCase(file: "apng.png", source: .ffmpeg(MT.pattern("96x64", seconds: 0.5, rate: 10) + ["-plays", "0", "-f", "apng"]),
                   kind: .image, compat: .popular, size: (96, 64)),
        FormatCase(file: "single.gif", source: .ffmpeg(MT.pattern("120x80") + ["-frames:v", "1"]), kind: .gif, compat: .popular,
                   size: (120, 80), alpha: nil),
        FormatCase(file: "anim.gif", source: .ffmpeg(MT.pattern("120x80", seconds: 0.5, rate: 10)), kind: .gif, compat: .popular,
                   size: (120, 80), alpha: nil),
    ]

    static let videos: [FormatCase] = [
        FormatCase(file: "vp8.webm", source: .ffmpeg(v1s + a1s + ["-c:v", "libvpx", "-b:v", "300k", "-c:a", "libopus", "-shortest"]),
                   kind: .video, compat: .uncommon, target: .mp4H264, size: (192, 108), seconds: 1, after: ("h264", "aac"),
                   needs: ["libvpx", "libopus"]),
        FormatCase(file: "vp9.webm", source: .ffmpeg(v1s + a1s + ["-c:v", "libvpx-vp9", "-b:v", "300k", "-c:a", "libopus", "-shortest"]),
                   kind: .video, compat: .uncommon, target: .mp4H264, size: (192, 108), seconds: 1, after: ("h264", "aac"),
                   needs: ["libvpx-vp9", "libopus"]),
        // Transparent VP9 (alpha in a side channel): flattened onto white when it becomes H.264.
        FormatCase(file: "vp9alpha.webm",
                   source: .ffmpeg(["-f", "lavfi", "-i", "color=c=black@0.0:s=192x108:d=1:r=25,format=yuva420p",
                                    "-f", "lavfi", "-i", "color=c=red:s=96x54:d=1:r=25",
                                    "-filter_complex", "[0][1]overlay=48:27,format=yuva420p",
                                    "-c:v", "libvpx-vp9", "-auto-alt-ref", "0", "-b:v", "300k"]),
                   kind: .video, compat: .uncommon, target: .mp4H264, size: (192, 108), seconds: 1, alpha: true, after: ("h264", nil),
                   needs: ["libvpx-vp9"],
                   linuxIssue: "FFmpegVideoProbe.frame decodes VP9 without libvpx: alpha lost, thumbnail on black"),
        FormatCase(file: "av1.mp4", source: .ffmpeg(v1s + a1s + ["-c:v", av1, "-c:a", "aac", "-shortest"]), kind: .video,
                   compat: .uncommon, target: .mp4H264, size: (192, 108), seconds: 1, after: ("h264", "aac"), needs: [av1]),
        FormatCase(file: "av1.webm", source: .ffmpeg(v1s + a1s + ["-c:v", av1, "-c:a", "libopus", "-shortest"]), kind: .video,
                   compat: .uncommon, target: .mp4H264, size: (192, 108), seconds: 1, after: ("h264", "aac"), needs: [av1, "libopus"]),
        FormatCase(file: "h264.mkv", source: .ffmpeg(v1s + a1s + ["-c:v", h264, "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest"]),
                   kind: .video, compat: .uncommon, target: .mp4H264, size: (192, 108), seconds: 1, after: ("h264", "aac"), needs: [h264]),
        FormatCase(file: "prores.mov", source: .ffmpeg(v1s + a1s + ["-c:v", "prores_ks", "-profile:v", "0", "-c:a", "pcm_s16le", "-shortest"]),
                   kind: .video, compat: .uncommon, target: .mp4H264, size: (192, 108), seconds: 1, after: ("h264", "aac"),
                   needs: ["prores_ks", h264]),
        FormatCase(file: "mpeg4.avi", source: .ffmpeg(v1s + a1s + ["-c:v", "mpeg4", "-c:a", "pcm_s16le", "-shortest"]),
                   kind: .video, compat: .uncommon, target: .mp4H264, size: (192, 108), seconds: 1, after: ("h264", "aac"), needs: [h264]),
        // FLV and 3GP are recognised by their extension; MPEG-TS isn't (".ts" is also TypeScript), so it
        // comes in only with an explicit kind.
        // (MP3 audio is copied into the MP4 as is: MP4 · H.264 · MP3 counts as popular.)
        FormatCase(file: "clip.flv", source: .ffmpeg(v1s + a1s + ["-c:v", "flv", "-c:a", "libmp3lame", "-ar", "44100", "-shortest"]),
                   kind: .video, compat: .uncommon, target: .mp4H264, size: (192, 108), seconds: 1,
                   after: ("h264", "mp3"), needs: ["libmp3lame", h264]),
        FormatCase(file: "clip.3gp", source: .ffmpeg(MT.pattern("176x144", rate: 15) + a1s + ["-c:v", "h263", "-c:a", "aac", "-ar", "8000", "-ac", "1", "-shortest"]),
                   kind: .video, compat: .uncommon, target: .mp4H264, size: (176, 144), seconds: 1,
                   after: ("h264", "aac"), needs: ["h263", h264]),
        FormatCase(file: "clip.ts", source: .ffmpeg(v1s + a1s + ["-c:v", "mpeg2video", "-c:a", "mp2", "-shortest"]),
                   kind: .video, compat: .uncommon, target: .mp4H264, detected: false, size: (192, 108), seconds: 1,
                   after: ("h264", "aac"), needs: ["mpeg2video", "mp2", h264]),
        FormatCase(file: "silent.mp4", source: .ffmpeg(v1s + ["-c:v", h264, "-pix_fmt", "yuv420p"]), kind: .video, compat: .popular,
                   size: (192, 108), seconds: 1, needs: [h264]),
        FormatCase(file: "h264aac.m4v", source: .ffmpeg(v1s + a1s + ["-c:v", h264, "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", "-f", "mp4"]),
                   kind: .video, compat: .popular, size: (192, 108), seconds: 1, needs: [h264]),
        FormatCase(file: "oneframe.mp4", source: .ffmpeg(v1s + ["-frames:v", "1", "-c:v", h264, "-pix_fmt", "yuv420p"]), kind: .video,
                   compat: .popular, size: (192, 108), seconds: 0.04, needs: [h264]),
        // H.264 4:2:0 can't have odd sides, and 1×1 can't be "rounded down to even".
        FormatCase(file: "odd.webm", source: .ffmpeg(["-f", "lavfi", "-i", "testsrc=s=101x57:d=1:r=25", "-pix_fmt", "yuv420p", "-c:v", "libvpx-vp9", "-b:v", "200k"]), kind: .video,
                   compat: .uncommon, target: .mp4H264, size: (101, 57), seconds: 1, after: ("h264", nil), needs: ["libvpx-vp9", h264]),
        FormatCase(file: "dot.webm", source: .ffmpeg(["-f", "lavfi", "-i", "color=c=red:s=2x2:d=1:r=25,format=rgb24,crop=1:1", "-pix_fmt", "yuv420p", "-c:v", "libvpx-vp9"]),
                   kind: .video, compat: .uncommon, target: .mp4H264, size: (1, 1), seconds: 1, after: ("h264", nil),
                   needs: ["libvpx-vp9", h264]),
    ]

    static let audio: [FormatCase] = [
        FormatCase(file: "tone.mp3", source: .ffmpeg(a1s + ["-c:a", "libmp3lame"]), kind: .audio, compat: .popular, seconds: 1,
                   needs: ["libmp3lame"]),
        FormatCase(file: "tone.m4a", source: .ffmpeg(a1s + ["-c:a", "aac"]), kind: .audio, compat: .popular, seconds: 1),
        FormatCase(file: "tone.aac", source: .ffmpeg(a1s + ["-c:a", "aac"]), kind: .audio, compat: .popular, seconds: 1),
        FormatCase(file: "alac.m4a", source: .ffmpeg(a1s + ["-c:a", "alac"]), kind: .audio, compat: .uncommon, target: .mp3,
                   seconds: 1, after: (nil, "mp3"), needs: ["alac", "libmp3lame"]),
        FormatCase(file: "vorbis.ogg", source: .ffmpeg(a1s + (MT.has("libvorbis") ? ["-c:a", "libvorbis"] : ["-c:a", "vorbis", "-strict", "-2", "-ac", "2"])),
                   kind: .audio, compat: .uncommon, target: .mp3, seconds: 1, after: (nil, "mp3"), needs: ["libmp3lame"]),
        FormatCase(file: "tone.opus", source: .ffmpeg(a1s + ["-c:a", "libopus"]), kind: .audio, compat: .uncommon, target: .mp3,
                   seconds: 1, after: (nil, "mp3"), needs: ["libopus", "libmp3lame"]),
        FormatCase(file: "opus.ogg", source: .ffmpeg(a1s + ["-c:a", "libopus"]), kind: .audio, compat: .uncommon, target: .mp3,
                   seconds: 1, after: (nil, "mp3"), needs: ["libopus", "libmp3lame"]),
        FormatCase(file: "tone.flac", source: .ffmpeg(a1s + ["-c:a", "flac"]), kind: .audio, compat: .uncommon, target: .mp3,
                   seconds: 1, after: (nil, "mp3"), needs: ["libmp3lame"]),
        FormatCase(file: "u8.wav", source: .ffmpeg(a1s + ["-c:a", "pcm_u8"]), kind: .audio, compat: .uncommon, target: .mp3,
                   seconds: 1, after: (nil, "mp3"), needs: ["libmp3lame"]),
        FormatCase(file: "s24.wav", source: .ffmpeg(a1s + ["-c:a", "pcm_s24le"]), kind: .audio, compat: .uncommon, target: .mp3,
                   seconds: 1, after: (nil, "mp3"), needs: ["libmp3lame"]),
        // AIFF / AMR: not in MediaType's table — explicit kind.
        FormatCase(file: "tone.aiff", source: .ffmpeg(a1s + ["-c:a", "pcm_s16be"]), kind: .audio, compat: .uncommon, target: .mp3,
                   detected: false, seconds: 1, after: (nil, "mp3"), needs: ["libmp3lame"]),
        FormatCase(file: "tone.amr", source: .ffmpeg(MT.tone(rate: 8000) + ["-c:a", "libopencore_amrnb", "-ac", "1"]), kind: .audio,
                   compat: .uncommon, target: .mp3, detected: false, seconds: 1, after: (nil, "mp3"),
                   needs: ["libopencore_amrnb", "libmp3lame"]),
    ]
}

// Serialized: video cases block a pool thread each while AVFoundation/ffmpeg work; with many in flight a
// starving bridge (see MediaConcurrencyTests) would hang the run instead of failing one test.
@Suite(.serialized, .enabled(if: MT.hasFFmpeg)) struct RareFormatTests {
    @Test(arguments: FormatCase.all.filter(\.available))
    func endToEnd(_ fc: FormatCase) throws {
        try linuxKnownIssue(fc.linuxIssue) { try endToEndBody(fc) }
    }

    private func endToEndBody(_ fc: FormatCase) throws {
        let src = try fc.make()
        let t = try #require(MT.platform.transcoder)

        // Detect
        let detected = MediaType.detect(url: src)
        if fc.detected { #expect(detected?.kind == fc.kind, "detected as \(String(describing: detected))") }
        else { #expect(detected == nil, "now detected as \(String(describing: detected)) — update the case") }

        // Analyze / probe
        let info = MT.analyzer.analyze(src, kind: fc.kind)
        let probe = try #require(MediaProbe(codecs: info.codecs), "no probe")
        #expect(probe.container == fc.ext)
        if let alpha = fc.alpha { #expect(probe.hasAlpha == alpha, "alpha: probed \(info.codecs ?? "nil")") }
        if let (w, h) = fc.size { #expect(info.width == w && info.height == h, "size \(String(describing: info.width))×\(String(describing: info.height))") }
        if let s = fc.seconds {
            let ms = try #require(info.durationMs, "no duration")
            #expect(abs(Double(ms) / 1000 - s) <= max(0.06, s * 0.15), "duration \(ms) ms, want ≈\(s) s")
        }
        if fc.visual { #expect(info.phash != nil && info.dhash != nil, "no perceptual hashes") }

        // Thumbnail
        let thumb = try MT.analyzer.thumbnail(src, kind: fc.kind)
        if fc.visual { try MT.checkThumbnail(thumb, displaySize: fc.size, fc.file) } else { #expect(thumb == nil) }

        // Compatibility / target
        #expect(FormatPolicy.compatibility(kind: fc.kind, ext: fc.ext, codecs: info.codecs) == fc.compat)
        if fc.compat == .uncommon {
            #expect(FormatPolicy.popularTarget(kind: fc.kind, ext: fc.ext, codecs: info.codecs) == fc.target)
        }
        #expect(!FormatPolicy.label(ext: fc.ext, codecs: info.codecs).isEmpty)

        // Import with the defaults
        let c = try MT.collection()
        defer { try? FileManager.default.removeItem(at: c.url) }
        let meme = try MT.commit(c, src, kind: fc.detected ? nil : fc.kind)
        #expect(meme.kind == fc.kind)
        let (primary, original) = try c.formats(of: meme.id)
        let p = try #require(primary)
        let stored = c.media.url(sha256: p.sha256, ext: p.ext)
        #expect(FileManager.default.fileExists(atPath: stored.path))
        #expect(p.compatibility(kind: fc.kind) == .popular, "stored as \(p.ext) \(p.codecs ?? "nil")")
        #expect(original == nil)
        if fc.visual { #expect(FileManager.default.fileExists(atPath: c.media.thumbURL(sha256: p.sha256).path), "no stored thumbnail") }

        let srcSHA = try MediaStore.sha256(of: src)
        if fc.compat == .popular {
            #expect(p.ext == fc.ext && p.sourceSHA256 == nil && p.sha256 == srcSHA)
        } else {
            let target = try #require(fc.target)
            #expect(p.ext == target.ext && p.sourceExt == fc.ext && p.sourceSHA256 == srcSHA)
            #expect(p.sourceLabel == FormatPolicy.label(ext: fc.ext, codecs: info.codecs))
            let out = try t.probe(stored)
            // Transparency survives into PNG. (An opaque source may still come out as RGBA PNG: not checked.)
            if fc.alpha == true, target == .png { #expect(out.hasAlpha, "converted alpha: \(out.codecs)") }
            if let (v, a) = fc.after { #expect(out.video == v && out.audio == a, "converted to \(out.codecs)") }
            if let (w, h) = fc.sizeAfter { #expect(p.width == w && p.height == h, "converted size \(String(describing: p.width))×\(String(describing: p.height))") }
            if let s = fc.seconds {
                let ms = try #require(p.durationMs, "converted file has no duration")
                #expect(abs(Double(ms) / 1000 - s) <= max(0.1, s * 0.15), "converted duration \(ms) ms")
            }
            if fc.visual { #expect(p.phash != nil) }
            if target.group == .still { #expect(target.matches(ext: p.ext, codecs: p.codecs)) }
        }
    }

    /// Transparent pictures/video: thumbnails (JPEG) and flattened conversions put white, not black, behind them.
    @Test(arguments: FormatCase.all.filter { $0.alpha == true && $0.available })
    func transparencyBecomesWhite(_ fc: FormatCase) throws {
        let src = try fc.make()
        try linuxKnownIssue(fc.linuxIssue) {
            let b = try MT.checkThumbnail(MT.analyzer.thumbnail(src, kind: fc.kind), displaySize: fc.size, fc.file)
            #expect(MT.isWhite(MT.pixel(b, 1, 1)), "thumbnail corner \(MT.pixel(b, 1, 1))")
            #expect(MT.isRed(MT.pixel(b, b.width / 2 - 2, b.height / 2)), "thumbnail centre \(MT.pixel(b, b.width / 2 - 2, b.height / 2))")
        }

        guard fc.kind == .video else { return }
        let c = try MT.collection()
        defer { try? FileManager.default.removeItem(at: c.url) }
        let p = try #require(try c.formats(of: MT.commit(c, src).id).primary)
        let frame = try MT.analyzer.thumbnail(c.media.url(sha256: p.sha256, ext: p.ext), kind: .video)
        let fb = try MT.checkThumbnail(frame, displaySize: fc.size, "converted " + fc.file)
        #expect(MT.isWhite(MT.pixel(fb, 2, 2)), "converted corner \(MT.pixel(fb, 2, 2))")
        #expect(MT.isRed(MT.pixel(fb, fb.width / 2, fb.height / 2)))
    }

    /// The red|blue fixtures: decoders keep colour and orientation (CMYK and grayscale included).
    @Test(arguments: ["cmyk.jpg", "progressive.jpg", "pic.jxl", "pic.heic", "alpha.avif", "anim.webp", "alpha.webp"])
    func fixtureColoursSurvive(_ name: String) throws {
        let fc = try #require(FormatCase.all.first { $0.file == name })
        guard fc.available else { return }                                      // HEIC, JPEG XL, animated WebP: Apple only
        let b = try MT.analyzer.converter.raster(try fc.make(), maxSide: 0)
        #expect(b.width == 64 && b.height == 48)
        // Hue, not exact values: CMYK goes through a colour profile (pure C+M renders as navy).
        let l = MT.pixel(b, 22, 24), r = MT.pixel(b, 42, 24)
        #expect(l.r > l.g + 60 && l.r > l.b + 60, "\(name) left \(l)")
        #expect(r.b > r.r + 50 && r.b > r.g + 50, "\(name) right \(r)")
    }

    @Test func grayscaleJPEGDecodesAsGray() throws {
        let b = try MT.analyzer.converter.raster(MT.fixture("gray.jpg"), maxSide: 0)
        #expect(b.width == 64 && b.height == 48)
        let l = MT.pixel(b, 10, 24), r = MT.pixel(b, 54, 24)
        #expect(abs(l.r - l.g) < 8 && abs(l.g - l.b) < 8 && abs(r.r - r.b) < 8)
        #expect(l.r != r.r)                                                     // red and blue map to different greys
    }

    /// Every popular format the import converts to is something ffmpeg probes back as exactly that.
    @Test func everyExportFormatProbesAsItself() throws {
        let t = try #require(MT.platform.transcoder)
        let video = try MT.make("exp-src.webm", FormatCase.v1s + FormatCase.a1s + ["-c:v", "libvpx-vp9", "-b:v", "300k", "-c:a", "libopus", "-shortest"])
        let still = try MT.make("exp-src.png", FormatCase.still160)
        let c = MT.analyzer.converter
        var checked = 0
        for format in MediaFormat.allCases where c.supports(format) {
            if (format == .webp && !MT.has("libwebp")) || (format == .webpAnimated && !MT.has("libwebp_anim")) { continue }
            let src = format.group == .still ? still : video
            let kind: MemeKind = format.group == .still ? .image : format.group == .audio ? .audio : .video
            let out = try c.convertToTemporary(src, kind: kind, to: format, name: "x")
            defer { try? FileManager.default.removeItem(at: out.deletingLastPathComponent()) }
            let p = try t.probe(out)
            #expect(format.matches(ext: out.pathExtension, codecs: p.codecs), "\(format.label) probed as \(p.codecs)")
            switch format.group {
            case .still:
                let info = MT.analyzer.analyze(out, kind: .image)
                #expect(info.width == 160 && info.height == 90, "\(format.label) \(p.codecs)")
            case .animation where format == .webpAnimated:
                #expect(p.video == "webp")                                      // ffprobe can't read animated WebP's length
            case .video, .animation: #expect(p.video != nil && (p.durationMs ?? 0) > 500, "\(format.label) \(p.codecs)")
            case .audio: #expect(p.video == nil && p.audio != nil && (p.durationMs ?? 0) > 500, "\(format.label) \(p.codecs)")
            }
            checked += 1
        }
        #expect(checked >= 15)
    }
}
