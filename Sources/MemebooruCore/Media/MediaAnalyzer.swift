import Foundation

public struct MediaInfo: Sendable, Equatable, Codable {
    public var width: Int?
    public var height: Int?
    public var durationMs: Int64?
    public var dhash: Int64?
    public var phash: Int64?
    /// `MediaProbe.codecs` when ffprobe is available.
    public var codecs: String?
    public init(width: Int? = nil, height: Int? = nil, durationMs: Int64? = nil, dhash: Int64? = nil, phash: Int64? = nil, codecs: String? = nil) {
        self.width = width; self.height = height; self.durationMs = durationMs; self.dhash = dhash; self.phash = phash; self.codecs = codecs
    }
}

/// Dimensions + perceptual hashes + thumbnails, via the injected `Platform`. Whatever the OS can't
/// decode (WebM, MKV, AVI, AV1 on older Macs, HEIC on Linux…) goes through the transcoder instead.
public struct MediaAnalyzer: Sendable {
    public let platform: Platform
    public static let hashSide = 64
    public static let thumbSide = 512

    public init(platform: Platform) { self.platform = platform }

    public var converter: MediaConverter { MediaConverter(platform: platform) }

    public func analyze(_ url: URL, kind: MemeKind) -> MediaInfo {
        var info = MediaInfo()
        let probe = kind == .text || kind == .article || kind == .tweet ? nil : (try? platform.transcoder?.probe(url))
        info.codecs = probe?.codecs
        switch kind {
        case .image, .gif:
            if let (w, h) = try? platform.images.imageSize(url) { info.width = w; info.height = h }
            else if let w = probe?.width, let h = probe?.height { info.width = w; info.height = h }
            if let bmp = try? converter.raster(url, maxSide: Self.hashSide) { fill(&info, bmp) }
        case .video:
            info.durationMs = (try? platform.video.durationMs(url)) ?? probe?.durationMs
            info.width = probe?.width; info.height = probe?.height   // real size; frames below are downscaled
            if let bmp = try? videoFrame(url, maxSide: Self.hashSide) { fill(&info, bmp) }
        case .text:
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                info.phash = PerceptualHash.toInt64(TextHash.simhash(text))
            }
        case .audio:
            info.durationMs = (try? platform.video.durationMs(url)) ?? probe?.durationMs
        case .article, .tweet:
            break
        }
        return info
    }

    private func fill(_ info: inout MediaInfo, _ bmp: Bitmap) {
        let gray = GrayImage(bmp)
        info.dhash = PerceptualHash.toInt64(PerceptualHash.dHash(gray))
        info.phash = PerceptualHash.toInt64(PerceptualHash.pHash(gray))
    }

    /// A frame 10% in — the OS decoder first, ffmpeg when the OS can't read the file.
    func videoFrame(_ url: URL, maxSide: Int) throws -> Bitmap { try videoFrame(url, at: 0.1, maxSide: maxSide) }

    /// A frame `fraction` of the way through — the OS decoder first, ffmpeg when the OS can't read the file.
    public func videoFrame(_ url: URL, at fraction: Double, maxSide: Int) throws -> Bitmap {
        do { return try platform.video.frame(url, at: fraction, maxSide: maxSide) } catch {
            guard let t = platform.transcoder else { throw error }
            return try converter.decodePNG(t.frame(url, at: fraction, maxSide: maxSide))
        }
    }

    /// JPEG thumbnail bytes, or nil for kinds the UI renders as cards (text/audio/tweet/article).
    public func thumbnail(_ url: URL, kind: MemeKind) throws -> Data? {
        let bmp: Bitmap
        switch kind {
        case .image, .gif: bmp = try converter.raster(url, maxSide: Self.thumbSide)
        case .video: bmp = try videoFrame(url, maxSide: Self.thumbSide)
        default: return nil
        }
        return try platform.thumbs.jpeg(bmp, quality: 0.82)
    }

    /// A still picture as JPEG, longer side ≤ `maxSide` — e.g. an SVG for places that only take rasters (Telegram).
    public func rasterJPEG(_ url: URL, maxSide: Int, quality: Double = 0.9) throws -> Data {
        try platform.thumbs.jpeg(converter.raster(url, maxSide: maxSide), quality: quality)
    }

    /// Writes `thumbs/<sha>.jpg` if missing. Returns the URL or nil when the kind has no thumbnail.
    @discardableResult
    public func ensureThumbnail(for url: URL, sha256: String, kind: MemeKind, in media: MediaStore) throws -> URL? {
        let dest = media.thumbURL(sha256: sha256)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        guard let data = try thumbnail(url, kind: kind) else { return nil }
        try FileManager.default.createDirectory(at: media.thumbs, withIntermediateDirectories: true)
        try data.write(to: dest, options: .atomic)
        return dest
    }
}
