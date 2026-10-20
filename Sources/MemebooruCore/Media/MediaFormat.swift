import Foundation

/// What a media file actually contains: container + codecs (from ffprobe when available).
public struct MediaProbe: Sendable, Equatable, Codable {
    public var container: String?
    public var video: String?
    public var audio: String?
    public var width: Int?
    public var height: Int?
    public var durationMs: Int64?
    public var hasAlpha = false
    public init(container: String? = nil, video: String? = nil, audio: String? = nil, width: Int? = nil, height: Int? = nil,
                durationMs: Int64? = nil, hasAlpha: Bool = false) {
        self.container = container; self.video = video; self.audio = audio; self.width = width; self.height = height
        self.durationMs = durationMs; self.hasAlpha = hasAlpha
    }

    /// Compact form stored on assets: `container/video/audio`, `-` for a missing stream, `+a` when the
    /// picture has an alpha channel. E.g. `matroska/av1/opus`, `mp4/h264/aac`, `png/png/-+a`.
    public var codecs: String {
        "\(container ?? "?")/\(video ?? "-")/\(audio ?? "-")" + (hasAlpha ? "+a" : "")
    }

    public init?(codecs: String?) {
        guard var s = codecs, !s.isEmpty else { return nil }
        if s.hasSuffix("+a") { hasAlpha = true; s.removeLast(2) }
        let p = s.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard p.count == 3 else { return nil }
        container = p[0] == "?" ? nil : p[0]
        video = p[1] == "-" ? nil : p[1]
        audio = p[2] == "-" ? nil : p[2]
    }
}

/// Formats a meme can be converted to (on import, when storing, or just for an export).
public enum MediaFormat: String, CaseIterable, Sendable, Codable {
    // still pictures
    case jpeg, png, webp, heic, tiff, bmp
    // animations
    case gif, webpAnimated
    // video
    case mp4H264, mp4HEVC, movH264, webmVP9, mkvH264
    // audio
    case mp3, m4a, opus, flac, wav

    public enum Group: Sendable { case still, animation, video, audio }

    public var group: Group {
        switch self {
        case .jpeg, .png, .webp, .heic, .tiff, .bmp: .still
        case .gif, .webpAnimated: .animation
        case .mp4H264, .mp4HEVC, .movH264, .webmVP9, .mkvH264: .video
        case .mp3, .m4a, .opus, .flac, .wav: .audio
        }
    }

    public var ext: String {
        switch self {
        case .jpeg: "jpg"; case .png: "png"; case .webp, .webpAnimated: "webp"; case .heic: "heic"
        case .tiff: "tiff"; case .bmp: "bmp"; case .gif: "gif"
        case .mp4H264, .mp4HEVC: "mp4"; case .movH264: "mov"; case .webmVP9: "webm"; case .mkvH264: "mkv"
        case .mp3: "mp3"; case .m4a: "m4a"; case .opus: "ogg"; case .flac: "flac"; case .wav: "wav"
        }
    }

    public var label: String {
        switch self {
        case .jpeg: "JPEG"; case .png: "PNG"; case .webp: "WebP"; case .heic: "HEIC"; case .tiff: "TIFF"; case .bmp: "BMP"
        case .gif: "GIF"; case .webpAnimated: "WebP (animated)"
        case .mp4H264: "MP4 · H.264"; case .mp4HEVC: "MP4 · HEVC"; case .movH264: "MOV · H.264"
        case .webmVP9: "WebM · VP9"; case .mkvH264: "MKV · H.264"
        case .mp3: "MP3"; case .m4a: "M4A · AAC"; case .opus: "Ogg · Opus"; case .flac: "FLAC"; case .wav: "WAV"
        }
    }

    /// Whether a stored file already is this format (container and codecs), so exporting can copy it.
    /// Unknown codecs only match formats defined by the container alone.
    public func matches(ext rawExt: String, codecs: String?) -> Bool {
        let ext = rawExt.lowercased() == "jpeg" ? "jpg" : rawExt.lowercased() == "tif" ? "tiff" : rawExt.lowercased()
        let p = MediaProbe(codecs: codecs)
        func video(_ c: String) -> Bool { p?.video == c }
        switch self {
        case .jpeg, .png, .heic, .tiff, .bmp, .gif, .mp3, .flac, .wav: return ext == self.ext
        case .webp, .webpAnimated: return ext == "webp"
        case .mp4H264: return (ext == "mp4" || ext == "m4v") && video("h264") && (p?.audio == nil || p?.audio == "aac")
        case .mp4HEVC: return ext == "mp4" && video("hevc")
        case .movH264: return ext == "mov" && video("h264")
        case .webmVP9: return ext == "webm" && video("vp9")
        case .mkvH264: return ext == "mkv" && video("h264")
        case .m4a: return ext == "m4a" && p?.audio == "aac"
        case .opus: return (ext == "ogg" || ext == "opus") && p?.audio == "opus"
        }
    }

    /// Opens everywhere that matters for memes: Telegram, browsers, every phone.
    public var isPopular: Bool { [.jpeg, .png, .webp, .gif, .mp4H264, .mp3, .m4a].contains(self) }
}

public enum Compatibility: Sendable, Equatable { case popular, uncommon }

/// Which stored files count as "popular", what they convert to, and what they can be exported as.
public enum FormatPolicy {
    static let popularStill: Set<String> = ["jpg", "jpeg", "png", "webp"]
    static let popularVideoCodecs: Set<String> = ["h264"]
    static let popularAudioInVideo: Set<String> = ["aac", "mp3"]

    public static func compatibility(kind: MemeKind, ext rawExt: String, codecs: String?) -> Compatibility {
        let ext = rawExt.lowercased()
        let p = MediaProbe(codecs: codecs)
        switch kind {
        case .image: return popularStill.contains(ext) ? .popular : .uncommon
        case .gif: return ext == "gif" ? .popular : (ext == "mp4" && p?.video.map(popularVideoCodecs.contains) != false ? .popular : .uncommon)
        case .video:
            guard ext == "mp4" || ext == "m4v" else { return .uncommon }
            if let v = p?.video, !popularVideoCodecs.contains(v) { return .uncommon }
            if let a = p?.audio, !popularAudioInVideo.contains(a) { return .uncommon }
            return .popular
        case .audio:
            if ext == "mp3" { return .popular }
            if ext == "m4a" || ext == "aac" { return (p?.audio).map { $0 == "aac" } == false ? .uncommon : .popular }
            return .uncommon
        case .text, .article, .tweet: return .popular
        }
    }

    /// The popular format an uncommon file converts to. Pictures with transparency or from lossless
    /// sources stay lossless (PNG); photos become JPEG.
    public static func popularTarget(kind: MemeKind, ext rawExt: String, codecs: String?) -> MediaFormat? {
        let ext = rawExt.lowercased()
        switch kind {
        case .image:
            let alpha = MediaProbe(codecs: codecs)?.hasAlpha ?? false
            return alpha || ["png", "bmp", "tif", "tiff", "svg", "gif"].contains(ext) ? .png : .jpeg
        case .gif: return .gif
        case .video: return .mp4H264
        case .audio: return .mp3
        case .text, .article, .tweet: return nil
        }
    }

    /// Everything a meme of this kind can be exported as.
    public static func exportFormats(kind: MemeKind, hasAudio: Bool = true) -> [MediaFormat] {
        switch kind {
        case .image: return [.jpeg, .png, .webp, .heic, .tiff, .bmp]
        case .gif: return [.gif, .webpAnimated, .mp4H264, .webmVP9]
        case .video: return [.mp4H264, .mp4HEVC, .movH264, .webmVP9, .mkvH264, .gif, .webpAnimated] + (hasAudio ? [.mp3, .m4a] : [])
        case .audio: return [.mp3, .m4a, .opus, .flac, .wav]
        case .text, .article, .tweet: return []
        }
    }

    /// "MKV · AV1 · Opus", "HEIC", "MP4 · H.264 · AAC".
    public static func label(ext rawExt: String, codecs: String?) -> String {
        let ext = rawExt.lowercased()
        let container = containerNames[ext] ?? ext.uppercased()
        guard let p = MediaProbe(codecs: codecs) else { return container }
        let parts = [p.video, p.audio].compactMap { $0 }.filter { $0 != ext && !($0 == "mjpeg" && ext.hasPrefix("jp")) }
            .map { codecNames[$0] ?? $0.uppercased() }
        let still = ["jpg", "jpeg", "png", "webp", "heic", "heif", "avif", "jxl", "bmp", "tif", "tiff", "svg", "gif"].contains(ext)
        return still || parts.isEmpty ? container : ([container] + parts).joined(separator: " · ")
    }

    static let containerNames: [String: String] = [
        "mp4": "MP4", "m4v": "M4V", "mov": "MOV", "mkv": "MKV", "webm": "WebM", "avi": "AVI",
        "flv": "FLV", "3gp": "3GP", "3g2": "3G2",
        "jpg": "JPEG", "jpeg": "JPEG", "png": "PNG", "webp": "WebP", "heic": "HEIC", "heif": "HEIF", "avif": "AVIF",
        "jxl": "JPEG XL", "bmp": "BMP", "tif": "TIFF", "tiff": "TIFF", "svg": "SVG", "gif": "GIF",
        "mp3": "MP3", "m4a": "M4A", "aac": "AAC", "ogg": "Ogg", "oga": "Ogg", "opus": "Opus", "wav": "WAV", "flac": "FLAC",
    ]
    static let codecNames: [String: String] = [
        "h264": "H.264", "hevc": "HEVC", "av1": "AV1", "vp9": "VP9", "vp8": "VP8", "mpeg4": "MPEG-4", "prores": "ProRes",
        "flv1": "Sorenson H.263", "h263": "H.263", "amr_nb": "AMR", "amr_wb": "AMR-WB",
        "aac": "AAC", "mp3": "MP3", "opus": "Opus", "vorbis": "Vorbis", "flac": "FLAC", "pcm_s16le": "PCM", "alac": "ALAC",
    ]
}

/// Probes and converts media (ffmpeg on macOS/Linux). Optional: without it the app still works with
/// the formats the OS handles natively.
public protocol MediaTranscoder: Sendable {
    func probe(_ url: URL) throws -> MediaProbe
    /// Convert `src` into `format`, writing `dest`. Pictures arrive here already rasterised to PNG.
    func convert(_ src: URL, to format: MediaFormat, dest: URL, probe: MediaProbe?) throws
    /// A frame at `fraction` of the duration as PNG bytes, longer side ≤ maxSide.
    func frame(_ url: URL, at fraction: Double, maxSide: Int) throws -> Data
    /// A still picture decoded to PNG bytes (for pictures the OS decoder can't read).
    func stillPNG(_ url: URL) throws -> Data
    /// `src` cropped and/or trimmed, written as `format` (same size and frame rate otherwise).
    func edit(_ src: URL, crop: PixelRect?, trim: TimeRange?, to format: MediaFormat, dest: URL) throws
    /// The sound as 16-bit mono samples at `rate` Hz.
    func pcm(_ url: URL, rate: Int) throws -> [Int16]
}

extension MediaTranscoder {
    public func edit(_ src: URL, crop: PixelRect?, trim: TimeRange?, to format: MediaFormat, dest: URL) throws {
        throw TranscodeError("cropping and trimming need ffmpeg")
    }
    public func pcm(_ url: URL, rate: Int) throws -> [Int16] { throw TranscodeError("reading sound needs ffmpeg") }
}
