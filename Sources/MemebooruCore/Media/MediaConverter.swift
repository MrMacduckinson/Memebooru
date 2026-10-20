import Foundation

/// Converts a file into another `MediaFormat`. Pictures are decoded by the platform (EXIF orientation,
/// SVG, HEIC, JPEG XL…) and written by the system encoder when it can, by ffmpeg otherwise; animations,
/// video and audio always go through the transcoder.
public struct MediaConverter: Sendable {
    public let platform: Platform
    public init(platform: Platform) { self.platform = platform }

    public var canTranscode: Bool { platform.transcoder != nil }

    /// Whether converting to `format` is possible on this machine at all.
    public func supports(_ format: MediaFormat) -> Bool {
        switch format.group {
        case .still:
            if format == .heic { return (try? platform.thumbs.encode(Bitmap(width: 1, height: 1, rgba: Data(count: 4)), as: .heic, quality: 0.9)) != nil }
            return true
        default: return canTranscode
        }
    }

    public func convert(_ src: URL, kind: MemeKind, to format: MediaFormat, dest: URL) throws {
        try? FileManager.default.removeItem(at: dest)
        switch format.group {
        case .still:
            let bmp = try raster(src, maxSide: fullSide(src))
            if let data = try platform.thumbs.encode(bmp, as: format, quality: 0.92) { try data.write(to: dest); return }
            guard let t = platform.transcoder, let png = try platform.thumbs.encode(bmp, as: .png, quality: 1) else {
                throw TranscodeError("\(format.label) needs ffmpeg")
            }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mb-\(UUID().uuidString).png")
            try png.write(to: tmp)
            defer { try? FileManager.default.removeItem(at: tmp) }
            try t.convert(tmp, to: format, dest: dest, probe: nil)
        case .animation, .video, .audio:
            guard let t = platform.transcoder else { throw TranscodeError("converting to \(format.label) needs ffmpeg") }
            try t.convert(src, to: format, dest: dest, probe: nil)
        }
    }

    /// Vectors are drawn at their declared size, which can be anything (a 100000-px SVG would need
    /// gigabytes): longer side capped at `maxVectorSide`. Rasters always at full size (0).
    public static let maxVectorSide = 8192
    private func fullSide(_ src: URL) -> Int {
        guard src.pathExtension.lowercased() == "svg", let (w, h) = try? platform.images.imageSize(src),
              max(w, h) > Self.maxVectorSide else { return 0 }
        return Self.maxVectorSide
    }

    /// Converts into a temporary file named after `name`; the caller moves or deletes it.
    public func convertToTemporary(_ src: URL, kind: MemeKind, to format: MediaFormat, name: String = "converted") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mb-conv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(MediaStore.fileName(name, ext: format.ext))
        do { try convert(src, kind: kind, to: format, dest: dest) } catch { try? FileManager.default.removeItem(at: dir); throw error }
        return dest
    }

    /// A still picture (first frame) as a bitmap: the OS decoder first, ffmpeg for what it can't read.
    public func raster(_ url: URL, maxSide: Int) throws -> Bitmap {
        do { return try platform.images.decode(url, maxSide: maxSide) } catch {
            guard let t = platform.transcoder else { throw error }
            let png = try t.stillPNG(url)
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mb-\(UUID().uuidString).png")
            try png.write(to: tmp)
            defer { try? FileManager.default.removeItem(at: tmp) }
            return try platform.images.decode(tmp, maxSide: maxSide)
        }
    }

    func decodePNG(_ png: Data) throws -> Bitmap {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mb-\(UUID().uuidString).png")
        try png.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        return try platform.images.decode(tmp, maxSide: 0)
    }
}
