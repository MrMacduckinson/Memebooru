import Foundation

/// Finds what to cut (plain borders, quiet ends) and makes the cropped / trimmed file.
public struct MediaEditor: Sendable {
    public let analyzer: MediaAnalyzer
    public init(analyzer: MediaAnalyzer) { self.analyzer = analyzer }

    /// What can be edited: pictures, GIFs and videos are cropped; videos and sounds trimmed.
    public static func canCrop(_ kind: MemeKind) -> Bool { [.image, .gif, .video].contains(kind) }
    public static func canTrim(_ kind: MemeKind) -> Bool { [.video, .audio].contains(kind) }

    /// The shown size of a picture or video (after EXIF / phone rotation).
    public func size(_ url: URL, kind: MemeKind) throws -> PixelSize {
        if kind == .image, let (w, h) = try? analyzer.platform.images.imageSize(url) { return PixelSize(width: w, height: h) }
        let b = try frames(url, kind: kind, count: 1)[0]
        return PixelSize(width: b.width, height: b.height)
    }

    /// The content rectangle (in the file's pixels), or nil when there are no plain borders.
    public func detectBorders(_ url: URL, kind: MemeKind) throws -> PixelRect? {
        switch kind {
        case .image:
            let full = try size(url, kind: kind)
            // Pixel-exact up to 16 MP; larger pictures are looked at smaller and the result scaled back.
            let big = full.width * full.height > 16_000_000
            let b = try analyzer.converter.raster(url, maxSide: big ? 4000 : 0)
            guard let r = BorderDetector.contentRect(b) else { return nil }
            return big ? r.scaled(Double(full.width) / Double(b.width)).clamped(width: full.width, height: full.height) : r
        case .gif, .video:
            // Like a video player's crop detection, over several moments, not one frame.
            return BorderDetector.contentRect(frames: try frames(url, kind: kind, count: 7))
        default:
            return nil
        }
    }

    /// Frames spread over a video / GIF (or the picture itself), full size.
    public func frames(_ url: URL, kind: MemeKind, count: Int) throws -> [Bitmap] {
        if kind == .image { return [try analyzer.converter.raster(url, maxSide: 0)] }
        let fractions = count == 1 ? [0.1] : (0..<count).map { 0.08 + 0.84 * Double($0) / Double(count - 1) }
        let got = fractions.compactMap { try? analyzer.videoFrame(url, at: $0, maxSide: 0) }
        guard !got.isEmpty else { throw CollectionError("no frames in \(url.lastPathComponent)") }
        return got
    }

    /// One frame at `fraction` of the way through (for the crop editor's picture).
    public func frame(_ url: URL, kind: MemeKind, at fraction: Double) throws -> Bitmap {
        kind == .image ? try analyzer.converter.raster(url, maxSide: 0) : try analyzer.videoFrame(url, at: fraction, maxSide: 0)
    }

    /// The sound's stretch worth keeping (quiet ends cut), or nil.
    public func detectSilence(_ url: URL) throws -> TimeRange? {
        guard let t = analyzer.platform.transcoder else { throw TranscodeError("reading sound needs ffmpeg") }
        return SilenceDetector.soundRange(try t.pcm(url, rate: 8000), rate: 8000)
    }

    /// A waveform to draw: `count` peaks (0…1) and the length.
    public func waveform(_ url: URL, count: Int) throws -> (peaks: [Float], durationMs: Int64) {
        guard let t = analyzer.platform.transcoder else { throw TranscodeError("reading sound needs ffmpeg") }
        let s = try t.pcm(url, rate: 8000)
        return (SilenceDetector.peaks(s, count: count), Int64(s.count) * 1000 / 8000)
    }

    /// The edited file in a temporary folder (the caller moves it and removes the folder). Pictures stay
    /// lossless when they were; everything comes out in a popular format.
    public func apply(_ src: URL, kind: MemeKind, edit: MediaEdit, name: String = "edited") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mb-edit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            let ext = src.pathExtension.lowercased()
            switch kind {
            case .image:
                var b = try analyzer.converter.raster(src, maxSide: 0)
                if let c = edit.crop { b = b.cropped(to: c) }
                let lossless = ["png", "gif", "bmp", "tif", "tiff", "svg", "webp"].contains(ext) || Self.hasAlpha(b)
                let format: MediaFormat = lossless ? .png : .jpeg
                guard let data = try analyzer.platform.thumbs.encode(b, as: format, quality: 0.95) else {
                    throw CollectionError("can't write \(format.label) here")
                }
                let out = dir.appendingPathComponent(MediaStore.fileName(name, ext: format.ext))
                try data.write(to: out)
                return out
            case .gif, .video, .audio:
                guard let t = analyzer.platform.transcoder else { throw TranscodeError("cropping and trimming need ffmpeg") }
                let format: MediaFormat = kind == .audio ? (["m4a", "aac"].contains(ext) ? .m4a : .mp3)
                    : kind == .gif && ext == "gif" ? .gif : .mp4H264
                let crop = kind == .audio ? nil : (format == .mp4H264 ? edit.crop?.evened : edit.crop)
                let trim = kind == .gif ? nil : edit.trim
                let out = dir.appendingPathComponent(MediaStore.fileName(name, ext: format.ext))
                try t.edit(src, crop: crop, trim: trim, to: format, dest: out)
                return out
            default:
                throw CollectionError("\(kind.rawValue) can't be cropped or trimmed")
            }
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    static func hasAlpha(_ b: Bitmap) -> Bool {
        b.rgba.withUnsafeBytes { p in stride(from: 3, to: p.count, by: 4).contains { p[$0] < 255 } }
    }
}
