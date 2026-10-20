#if canImport(ImageIO)
import AVFoundation
import CNanoSVG
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#endif
import CoreGraphics
import Foundation
import ImageIO
import MemebooruCore
import UniformTypeIdentifiers

public enum PlatformApple {
    /// `ffmpegDirs`: where to look for the bundled ffmpeg/ffprobe first (the app's Helpers folder).
    public static func make(ffmpegDirs: [URL] = []) -> Platform {
        #if os(macOS)
        let transcoder: (any MediaTranscoder)? = FFmpegTranscoder.locate(in: ffmpegDirs)
        #else
        let transcoder: (any MediaTranscoder)? = nil
        #endif
        return Platform(images: AppleImageDecoder(), video: AppleVideoProbe(), thumbs: AppleJPEGEncoder(), http: URLSessionHTTPClient(),
                        transcoder: transcoder, text: CoreTextRenderer())
    }
}

struct PlatformAppleError: Error, CustomStringConvertible { let description: String }

extension CGImage {
    /// Straight RGBA8, no padding.
    func toBitmap() throws -> Bitmap {
        let w = width, h = height
        var data = Data(count: w * h * 4)
        try data.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { throw PlatformAppleError(description: "CGContext failed") }
            ctx.draw(self, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return Bitmap(width: w, height: h, rgba: data)
    }
}

public struct AppleImageDecoder: ImageDecoder {
    public init() {}

    public func decode(_ url: URL, maxSide: Int) throws -> Bitmap {
        if url.pathExtension.lowercased() == "svg" { return try SVGRasterizer.render(url, maxSide: maxSide).toBitmap() }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw PlatformAppleError(description: "cannot open \(url.lastPathComponent)") }
        // Always through the thumbnail call, which applies the EXIF orientation (a phone's portrait photo
        // is stored sideways); full size = a "thumbnail" as large as the picture itself.
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let fullSide = max(props?[kCGImagePropertyPixelWidth] as? Int ?? 0, props?[kCGImagePropertyPixelHeight] as? Int ?? 0)
        let image: CGImage?
        if maxSide > 0 || fullSide > 0 {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxSide > 0 ? maxSide : fullSide,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCache: false,
            ]
            image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        }
        guard let image else { throw PlatformAppleError(description: "decode failed \(url.lastPathComponent)") }
        return try image.toBitmap()
    }

    public func imageSize(_ url: URL) throws -> (width: Int, height: Int) {
        if url.pathExtension.lowercased() == "svg" { return try SVGRasterizer.size(url) }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { throw PlatformAppleError(description: "no image properties \(url.lastPathComponent)") }
        let orientation = (props[kCGImagePropertyOrientation] as? UInt32) ?? 1
        return orientation >= 5 ? (h, w) : (w, h)
    }
}

/// SVG through AppKit: ImageIO can't read SVG, but NSImage can (macOS 14+). Rendered onto white, since
/// thumbnails are JPEG and a transparent SVG would otherwise come out black.
public enum SVGRasterizer {
    /// The SVG's own size (its width/height or viewBox), in points.
    public static func size(_ url: URL) throws -> (width: Int, height: Int) {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        guard let img = NSImage(contentsOf: url), img.size.width > 0, img.size.height > 0 else {
            throw PlatformAppleError(description: "cannot read SVG \(url.lastPathComponent)")
        }
        return (Int(img.size.width.rounded()), Int(img.size.height.rounded()))
        #else
        var w: Float = 0, h: Float = 0
        guard cnanosvg_size(url.path, &w, &h) == 0 else {
            throw PlatformAppleError(description: "cannot read SVG \(url.lastPathComponent)")
        }
        return (Int(w.rounded()), Int(h.rounded()))
        #endif
    }

    /// Longer side = `maxSide` (vectors scale up cleanly); 0 = the SVG's own size.
    public static func render(_ url: URL, maxSide: Int) throws -> CGImage {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        guard let img = NSImage(contentsOf: url), img.size.width > 0, img.size.height > 0 else {
            throw PlatformAppleError(description: "cannot read SVG \(url.lastPathComponent)")
        }
        let longer = max(img.size.width, img.size.height)
        let scale = maxSide > 0 ? CGFloat(maxSide) / longer : 1
        let w = max(1, Int((img.size.width * scale).rounded())), h = max(1, Int((img.size.height * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw PlatformAppleError(description: "CGContext failed") }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        img.draw(in: NSRect(x: 0, y: 0, width: w, height: h), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.current = previous
        guard let out = ctx.makeImage() else { throw PlatformAppleError(description: "SVG render failed") }
        return out
        #else
        // No public SVG reader in UIKit: nanosvg (no text/filters — enough for icons, stickers, diagrams).
        var w: Int32 = 0, h: Int32 = 0
        guard let pixels = cnanosvg_render(url.path, Int32(maxSide), &w, &h) else {
            throw PlatformAppleError(description: "cannot read SVG \(url.lastPathComponent)")
        }
        defer { free(pixels) }
        let width = Int(w), height = Int(h)
        guard let provider = CGDataProvider(data: Data(bytes: pixels, count: width * height * 4) as CFData),
              let straight = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                     provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw PlatformAppleError(description: "SVG render failed") }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.draw(straight, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let out = ctx.makeImage() else { throw PlatformAppleError(description: "SVG render failed") }
        return out
        #endif
    }
}

public struct AppleVideoProbe: VideoProbe {
    public init() {}

    /// Callers are synchronous and often already on Swift concurrency's thread pool (thumbnail jobs).
    /// Bridging through `Task { await … }` + a semaphore there deadlocks once every pool thread is
    /// waiting for a task that needs a pool thread. So: AVFoundation's callback APIs only, which
    /// answer on AVFoundation's own queues.
    private static let timeout: DispatchTimeInterval = .seconds(60)

    private func duration(_ asset: AVURLAsset) throws -> CMTime {
        let sem = DispatchSemaphore(value: 0)
        asset.loadValuesAsynchronously(forKeys: ["duration"]) { sem.signal() }
        guard sem.wait(timeout: .now() + Self.timeout) == .success else {
            asset.cancelLoading()
            throw PlatformAppleError(description: "timed out reading \(asset.url.lastPathComponent)")
        }
        var error: NSError?
        guard asset.statusOfValue(forKey: "duration", error: &error) == .loaded else {
            throw error ?? PlatformAppleError(description: "cannot read \(asset.url.lastPathComponent)")
        }
        return asset.duration
    }

    public func durationMs(_ url: URL) throws -> Int64 {
        let d = try duration(AVURLAsset(url: url))
        return Int64(CMTimeGetSeconds(d) * 1000)
    }

    public func frame(_ url: URL, at fraction: Double, maxSide: Int) throws -> Bitmap {
        let asset = AVURLAsset(url: url)
        let d = try duration(asset)
        let seconds = CMTimeGetSeconds(d)
        let t = CMTime(seconds: seconds.isFinite ? seconds * fraction : 0, preferredTimescale: 600)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        if maxSide > 0 { gen.maximumSize = CGSize(width: maxSide, height: maxSide) }
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        let box = ResultBox<CGImage>()
        let sem = DispatchSemaphore(value: 0)
        gen.generateCGImageAsynchronously(for: t) { image, _, error in
            if let image { box.set(.success(image)) }
            else { box.set(.failure(error ?? PlatformAppleError(description: "no frame in \(url.lastPathComponent)"))) }
            sem.signal()
        }
        guard sem.wait(timeout: .now() + Self.timeout) == .success else {
            gen.cancelAllCGImageGeneration()
            throw PlatformAppleError(description: "timed out reading a frame of \(url.lastPathComponent)")
        }
        return try box.get().toBitmap()
    }
}

private final class ResultBox<T>: @unchecked Sendable {
    private var result: Result<T, Error>?
    private let lock = NSLock()
    func set(_ r: Result<T, Error>) { lock.lock(); result = r; lock.unlock() }
    func get() throws -> T { lock.lock(); defer { lock.unlock() }; return try result!.get() }
}

public struct AppleJPEGEncoder: ThumbnailEncoder {
    public init() {}

    public func jpeg(_ bitmap: Bitmap, quality: Double) throws -> Data {
        try write(bitmap, type: .jpeg, quality: quality, opaque: true)
    }

    public func encode(_ bitmap: Bitmap, as format: MediaFormat, quality: Double) throws -> Data? {
        switch format {
        case .jpeg: return try write(bitmap, type: .jpeg, quality: quality, opaque: true)
        case .png: return try write(bitmap, type: .png, quality: 1, opaque: false)
        case .heic: return try write(bitmap, type: .heic, quality: quality, opaque: false)
        case .tiff: return try write(bitmap, type: .tiff, quality: 1, opaque: false)
        case .bmp: return try write(bitmap, type: .bmp, quality: 1, opaque: true)
        default: return nil
        }
    }

    private func cgImage(_ bitmap: Bitmap, opaque: Bool) throws -> CGImage {
        let provider = CGDataProvider(data: bitmap.rgba as CFData)!
        guard let cg = CGImage(width: bitmap.width, height: bitmap.height, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: bitmap.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw PlatformAppleError(description: "CGImage from bitmap failed") }
        guard opaque else { return cg }
        // Formats without alpha: composite onto white, or transparent areas would turn black.
        guard let ctx = CGContext(data: nil, width: bitmap.width, height: bitmap.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw PlatformAppleError(description: "CGContext failed") }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
        return ctx.makeImage() ?? cg
    }

    private func write(_ bitmap: Bitmap, type: UTType, quality: Double, opaque: Bool) throws -> Data {
        let cg = try cgImage(bitmap, opaque: opaque)
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)
        else { throw PlatformAppleError(description: "this Mac can't write \(type.identifier)") }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw PlatformAppleError(description: "\(type.identifier) encode failed") }
        return out as Data
    }
}

public struct URLSessionHTTPClient: HTTPClient {
    public init() {}
    public func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = resp as? HTTPURLResponse
        var hs: [String: String] = [:]
        for (k, v) in http?.allHeaderFields ?? [:] { hs[String(describing: k).lowercased()] = String(describing: v) }
        return HTTPResponse(status: http?.statusCode ?? 0, headers: hs, body: data)
    }
}
#endif
