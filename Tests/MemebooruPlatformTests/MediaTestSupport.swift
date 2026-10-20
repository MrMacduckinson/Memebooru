import Foundation
import Testing
import MemebooruCore
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
import MemebooruPlatformApple
import UniformTypeIdentifiers
#endif
#if os(Linux)
import MemebooruPlatformLinux
#endif

/// Shared plumbing for the media pipeline tests (RareFormatTests, MediaEdgeCaseTests, MediaConcurrencyTests):
/// one platform with real ffmpeg, samples generated on the fly, committed tiny fixtures, pixel helpers.
enum MT {
    static let platform: Platform = {
        #if canImport(ImageIO)
        let vendor = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Vendor/ffmpeg/bin")
        return PlatformApple.make(ffmpegDirs: [vendor])
        #else
        return PlatformLinux.make()
        #endif
    }()
    static let analyzer = MediaAnalyzer(platform: platform)
    static var ffmpeg: FFmpegTranscoder? { platform.transcoder as? FFmpegTranscoder }
    static var hasFFmpeg: Bool { ffmpeg != nil }
    static func has(_ encoder: String) -> Bool { ffmpeg?.encoders.contains(encoder) ?? false }
    static var h264: String? { has("libx264") ? "libx264" : has("h264_videotoolbox") ? "h264_videotoolbox" : nil }
    static var av1: String? { has("libsvtav1") ? "libsvtav1" : has("libaom-av1") ? "libaom-av1" : has("librav1e") ? "librav1e" : nil }
    static var isApple: Bool {
        #if canImport(ImageIO)
        true
        #else
        false
        #endif
    }

    // MARK: Files

    /// One scratch folder per test process.
    static let dir: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("mb-media-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// A fresh empty folder (for files whose exact name matters).
    static func freshDir() throws -> URL {
        let d = dir.appendingPathComponent("d-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// An ffmpeg-made sample, cached by name. Written to a temporary name first, then moved, so tests
    /// running in parallel never see a half-written file.
    static func make(_ name: String, _ args: [String]) throws -> URL {
        let out = dir.appendingPathComponent(name)
        let fm = FileManager.default
        if fm.fileExists(atPath: out.path) { return out }
        let ff = try #require(ffmpeg, "no ffmpeg")
        let ext = out.pathExtension
        let tmp = dir.appendingPathComponent("tmp-\(UUID().uuidString)" + (ext.isEmpty ? "" : ".\(ext)"))
        try ff.runFFmpeg(["-v", "error", "-y"] + args + [tmp.path])
        do { try fm.moveItem(at: tmp, to: out) } catch { try? fm.removeItem(at: tmp) }
        return out
    }

    /// Copies `src` under an exact file name (unicode, no extension, wrong extension…) in a fresh folder.
    static func copy(_ src: URL, as name: String) throws -> URL {
        let out = try freshDir().appendingPathComponent(name)
        try FileManager.default.copyItem(at: src, to: out)
        return out
    }

    static func write(_ data: Data, as name: String) throws -> URL {
        let out = try freshDir().appendingPathComponent(name)
        try data.write(to: out)
        return out
    }

    /// Small binaries committed under Tests/MemebooruCoreTests/Fixtures/media (made with img2webp, cjxl,
    /// avifenc, heif-enc and ImageMagick from a 64×48 picture: left half red, right half blue; the
    /// `alpha.*` ones have a transparent border around a red|blue 32×24 block).
    static func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MemebooruCoreTests/Fixtures/media/\(name)")
    }

    // MARK: Lavfi sources

    /// `seconds` of the ffmpeg test pattern at `size`, as input arguments.
    static func pattern(_ size: String, seconds: Double = 1, rate: Int = 25) -> [String] {
        ["-f", "lavfi", "-i", "testsrc2=s=\(size):d=\(seconds):r=\(rate)"]
    }
    static func tone(seconds: Double = 1, rate: Int = 44100) -> [String] {
        ["-f", "lavfi", "-i", "sine=f=440:d=\(seconds):sample_rate=\(rate)"]
    }
    /// A still: transparent `size` canvas with an opaque red square in the middle (half the size).
    static func alphaStill(_ w: Int, _ h: Int) -> [String] {
        ["-f", "lavfi", "-i", "color=c=black@0.0:s=\(w)x\(h),format=rgba", "-f", "lavfi", "-i", "color=c=red:s=\(w / 2)x\(h / 2)",
         "-filter_complex", "[0][1]overlay=\(w / 4):\(h / 4),format=rgba", "-frames:v", "1"]
    }

    // MARK: Collections

    static func collection() throws -> Collection {
        try Collection.create(at: dir.appendingPathComponent("c-\(UUID().uuidString).memebooru"))
    }

    /// Stage + commit like the import UI does (defaults: convert uncommon formats, keep only SVG originals).
    static func commit(_ c: Collection, _ file: URL, kind: MemeKind? = nil, convert: Bool? = nil, keep: Bool? = nil) throws -> Meme {
        let s = StagingArea(collection: c, analyzer: analyzer)
        let item = try s.add(file: file, source: "test", kind: kind, extraTags: ["t"])
        return try s.commit(item.id, convert: convert, keepOriginal: keep)
    }

    // MARK: Pictures

    static func decode(_ data: Data, ext: String = "jpg") throws -> Bitmap {
        let tmp = dir.appendingPathComponent("dec-\(UUID().uuidString).\(ext)")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        return try platform.images.decode(tmp, maxSide: 0)
    }

    static func pixel(_ b: Bitmap, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        let i = (y * b.width + x) * 4
        return (Int(b.rgba[i]), Int(b.rgba[i + 1]), Int(b.rgba[i + 2]))
    }
    static func isWhite(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.r > 225 && p.g > 225 && p.b > 225 }
    static func isRed(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.r > 170 && p.g < 90 && p.b < 90 }
    static func isBlue(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.b > 170 && p.r < 90 && p.g < 90 }

    /// Checks a thumbnail is a real JPEG, fits the thumbnail box and keeps the picture's proportions.
    @discardableResult
    static func checkThumbnail(_ data: Data?, displaySize: (Int, Int)?, _ what: String,
                               sourceLocation: SourceLocation = #_sourceLocation) throws -> Bitmap {
        let jpeg = try #require(data, "\(what): no thumbnail", sourceLocation: sourceLocation)
        #expect(jpeg.starts(with: [0xFF, 0xD8, 0xFF]), "\(what): thumbnail isn't a JPEG", sourceLocation: sourceLocation)
        let b = try decode(jpeg)
        #expect(b.width >= 1 && b.height >= 1, "\(what): empty thumbnail", sourceLocation: sourceLocation)
        #expect(max(b.width, b.height) <= MediaAnalyzer.thumbSide, "\(what): thumbnail \(b.width)×\(b.height) exceeds \(MediaAnalyzer.thumbSide)", sourceLocation: sourceLocation)
        if let (w, h) = displaySize, w > 0, h > 0 {
            // Same orientation, and the short side is what the long side implies (±2 px of rounding).
            let landscape = w >= h
            let long = Double(landscape ? b.width : b.height), short = Double(landscape ? b.height : b.width)
            let ratio = Double(min(w, h)) / Double(max(w, h))
            #expect((b.width >= b.height) == landscape || abs(b.width - b.height) <= 1,
                    "\(what): thumbnail \(b.width)×\(b.height) turned vs source \(w)×\(h)", sourceLocation: sourceLocation)
            #expect(abs(short - max(1, long * ratio)) <= 2.0 + long * ratio * 0.03,
                    "\(what): thumbnail \(b.width)×\(b.height) vs source \(w)×\(h)", sourceLocation: sourceLocation)
        }
        return b
    }

    /// A JPEG with an EXIF APP1 segment carrying `orientation` (1…8), inserted after SOI/APP0.
    static func withEXIFOrientation(_ jpeg: Data, _ orientation: UInt16) -> Data {
        var tiff: [UInt8] = [0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08]              // "MM", 42, IFD at 8
        tiff += [0x00, 0x01]                                                                // one entry
        tiff += [0x01, 0x12, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01]                            // Orientation, SHORT, 1
        tiff += [UInt8(orientation >> 8), UInt8(orientation & 0xFF), 0x00, 0x00]
        tiff += [0x00, 0x00, 0x00, 0x00]                                                    // no next IFD
        let payload: [UInt8] = Array("Exif".utf8) + [0, 0] + tiff
        let len = payload.count + 2
        let app1: [UInt8] = [0xFF, 0xE1, UInt8(len >> 8), UInt8(len & 0xFF)] + payload
        var bytes = [UInt8](jpeg)
        var at = 2                                                                          // after SOI
        if bytes.count > 6, bytes[2] == 0xFF, bytes[3] == 0xE0 { at = 4 + (Int(bytes[4]) << 8 | Int(bytes[5])) }
        bytes.insert(contentsOf: app1, at: at)
        return Data(bytes)
    }

    /// `bytes` of a picture, solid colour halves: left red, right blue (any size), as PNG via the system encoder.
    static func redBluePNG(_ w: Int, _ h: Int) throws -> Data {
        var px = Data(count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let red = x < w / 2
                px[i] = red ? 255 : 0; px[i + 1] = 0; px[i + 2] = red ? 0 : 255; px[i + 3] = 255
            }
        }
        return try #require(try platform.thumbs.encode(Bitmap(width: w, height: h, rgba: px), as: .png, quality: 1))
    }
}

#if canImport(ImageIO)
extension MT {
    /// A still written by ImageIO (HEIC, JPEG…) with optional EXIF orientation — what an iPhone produces.
    static func imageIO(_ png: Data, type: UTType, orientation: Int? = nil, extra: [CFString: Any] = [:]) throws -> Data {
        let src = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let img = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil))
        var props = extra
        if let orientation { props[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }
}
#endif

/// Runs `body`; on Linux, when `issue` is set, its failures are recorded as that known issue instead.
func linuxKnownIssue(_ issue: String?, _ body: () throws -> Void) rethrows {
    #if os(Linux)
    if let issue {
        withKnownIssue(Comment(rawValue: issue), isIntermittent: true) { try body() }
        return
    }
    #endif
    try body()
}

/// Mutable box for collecting results from concurrent tasks.
final class Locked<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ v: T) { value = v }
    func with<R>(_ body: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(&value) }
    var get: T { with { $0 } }
}
