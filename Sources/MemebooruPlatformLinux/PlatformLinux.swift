#if os(Linux)
import CStbImage
import Foundation
import FoundationNetworking
import MemebooruCore

public enum PlatformLinux {
    public static func make() -> Platform {
        Platform(images: StbImageDecoder(), video: FFmpegVideoProbe(), thumbs: StbJPEGEncoder(), http: LinuxHTTPClient(),
                 transcoder: FFmpegTranscoder.locate(), text: PangoTextRenderer.locate())
    }
}

struct PlatformLinuxError: Error, CustomStringConvertible { let description: String }

public struct StbImageDecoder: ImageDecoder {
    public init() {}

    public func decode(_ url: URL, maxSide: Int) throws -> Bitmap {
        if url.pathExtension.lowercased() == "svg" {
            let png = try Self.rasterizeSVG(url, maxSide: maxSide)
            defer { try? FileManager.default.removeItem(at: png) }
            return try decode(png, maxSide: 0)
        }
        var w: Int32 = 0, h: Int32 = 0, n: Int32 = 0
        guard let px = stbi_load(url.path, &w, &h, &n, 4) else {
            throw PlatformLinuxError(description: "stbi_load failed: \(String(cString: stbi_failure_reason()))")
        }
        defer { stbi_image_free(px) }
        let full = Data(bytes: px, count: Int(w * h * 4))
        guard maxSide > 0, Int(max(w, h)) > maxSide else { return Bitmap(width: Int(w), height: Int(h), rgba: full) }
        let scale = Double(maxSide) / Double(max(w, h))
        let ow = max(1, Int32(Double(w) * scale)), oh = max(1, Int32(Double(h) * scale))
        var out = Data(count: Int(ow * oh * 4))
        out.withUnsafeMutableBytes { buf in
            _ = stbir_resize_uint8_srgb(px, w, h, 0, buf.baseAddress!.assumingMemoryBound(to: UInt8.self), ow, oh, 0, STBIR_RGBA)
        }
        return Bitmap(width: Int(ow), height: Int(oh), rgba: out)
    }

    public func imageSize(_ url: URL) throws -> (width: Int, height: Int) {
        if url.pathExtension.lowercased() == "svg" {
            let png = try Self.rasterizeSVG(url, maxSide: 0)
            defer { try? FileManager.default.removeItem(at: png) }
            return try imageSize(png)
        }
        var w: Int32 = 0, h: Int32 = 0, n: Int32 = 0
        guard stbi_info(url.path, &w, &h, &n) != 0 else { throw PlatformLinuxError(description: "stbi_info failed") }
        return (Int(w), Int(h))
    }
}

extension StbImageDecoder {
    /// SVG → PNG on white via `rsvg-convert` (librsvg2-bin), fitted into maxSide×maxSide (0 = own size).
    static func rasterizeSVG(_ url: URL, maxSide: Int) throws -> URL {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("svg-\(UUID().uuidString).png")
        var args = ["rsvg-convert", "--background-color=white", "--format=png", "--output=\(out.path)"]
        if maxSide > 0 { args += ["--keep-aspect-ratio", "--width=\(maxSide)", "--height=\(maxSide)"] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args + [url.path]
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw PlatformLinuxError(description: "rsvg-convert exited \(p.terminationStatus) (is librsvg2-bin installed?)") }
        return out
    }
}

/// Shells out to ffprobe/ffmpeg (must be on PATH).
public struct FFmpegVideoProbe: VideoProbe {
    public init() {}

    private func run(_ exe: String, _ args: [String]) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [exe] + args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        try? pipe.fileHandleForReading.close()   // see FFmpegTranscoder.run: don't leak one descriptor per call
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw PlatformLinuxError(description: "\(exe) exited \(p.terminationStatus)") }
        return data
    }

    public func durationMs(_ url: URL) throws -> Int64 {
        let out = try run("ffprobe", ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", url.path])
        let s = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let d = Double(s) else { throw PlatformLinuxError(description: "no duration") }
        return Int64(d * 1000)
    }

    public func frame(_ url: URL, at fraction: Double, maxSide: Int) throws -> Bitmap {
        let ms = try durationMs(url)
        let t = Double(ms) / 1000 * fraction
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mb-frame-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmp) }
        var args = ["-v", "error", "-ss", String(format: "%.3f", t), "-i", url.path, "-frames:v", "1"]
        if maxSide > 0 { args += ["-vf", "scale='min(\(maxSide),iw)':'min(\(maxSide),ih)':force_original_aspect_ratio=decrease"] }
        args += ["-y", tmp.path]
        _ = try run("ffmpeg", args)
        return try StbImageDecoder().decode(tmp, maxSide: 0)
    }
}

final class StbSink { var data = Data() }

/// C callback for stb's `*_to_func` writers: appends the bytes to the `StbSink` passed as context.
private func stbSink(_ ctx: UnsafeMutableRawPointer?, _ data: UnsafeMutableRawPointer?, _ size: Int32) {
    let s = Unmanaged<StbSink>.fromOpaque(ctx!).takeUnretainedValue()
    s.data.append(data!.assumingMemoryBound(to: UInt8.self), count: Int(size))
}

public struct StbJPEGEncoder: ThumbnailEncoder {
    public init() {}

    public func encode(_ bitmap: Bitmap, as format: MediaFormat, quality: Double) throws -> Data? {
        switch format {
        case .jpeg: return try jpeg(bitmap, quality: quality)
        case .png:
            return try Self.collect(bitmap) { ctx, buf in
                stbi_write_png_to_func(stbSink, ctx, Int32(bitmap.width), Int32(bitmap.height), 4, buf, Int32(bitmap.width * 4))
            }
        case .bmp:
            let flat = Self.onWhite(bitmap)
            return try Self.collect(flat) { ctx, buf in
                stbi_write_bmp_to_func(stbSink, ctx, Int32(flat.width), Int32(flat.height), 4, buf)
            }
        default: return nil
        }
    }

    /// stb keeps straight alpha; formats without alpha get it composited onto white.
    static func onWhite(_ b: Bitmap) -> Bitmap {
        var px = [UInt8](b.rgba)
        var i = 0
        while i + 3 < px.count {
            let a = Int(px[i + 3])
            if a < 255 {
                for k in 0..<3 { px[i + k] = UInt8((Int(px[i + k]) * a + 255 * (255 - a)) / 255) }
                px[i + 3] = 255
            }
            i += 4
        }
        return Bitmap(width: b.width, height: b.height, rgba: Data(px))
    }

    /// Runs an stb `*_to_func` writer and gathers what it emits.
    private static func collect(_ bitmap: Bitmap, _ write: (UnsafeMutableRawPointer, UnsafeRawPointer?) -> Int32) throws -> Data {
        let sink = StbSink()
        let ok = bitmap.rgba.withUnsafeBytes { buf in
            withExtendedLifetime(sink) { write(Unmanaged.passUnretained(sink).toOpaque(), buf.baseAddress) }
        }
        guard ok != 0 else { throw PlatformLinuxError(description: "image encode failed") }
        return sink.data
    }

    public func jpeg(_ bitmap: Bitmap, quality: Double) throws -> Data {
        let bitmap = Self.onWhite(bitmap)
        final class Sink { var data = Data() }
        let sink = Sink()
        let ok = bitmap.rgba.withUnsafeBytes { buf -> Int32 in
            withExtendedLifetime(sink) {
                stbi_write_jpg_to_func({ ctx, data, size in
                    let s = Unmanaged<Sink>.fromOpaque(ctx!).takeUnretainedValue()
                    s.data.append(data!.assumingMemoryBound(to: UInt8.self), count: Int(size))
                }, Unmanaged.passUnretained(sink).toOpaque(), Int32(bitmap.width), Int32(bitmap.height), 4, buf.baseAddress, Int32(quality * 100))
            }
        }
        guard ok != 0 else { throw PlatformLinuxError(description: "jpeg encode failed") }
        return sink.data
    }
}

public struct LinuxHTTPClient: HTTPClient {
    public init() {}
    public func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp): (Data, URLResponse) = try await withCheckedThrowingContinuation { cont in
            URLSession.shared.dataTask(with: req) { d, r, e in
                if let e { cont.resume(throwing: e) } else { cont.resume(returning: (d ?? Data(), r!)) }
            }.resume()
        }
        let http = resp as? HTTPURLResponse
        var hs: [String: String] = [:]
        for (k, v) in http?.allHeaderFields ?? [:] { hs[String(describing: k).lowercased()] = String(describing: v) }
        return HTTPResponse(status: http?.statusCode ?? 0, headers: hs, body: data)
    }
}
#endif
