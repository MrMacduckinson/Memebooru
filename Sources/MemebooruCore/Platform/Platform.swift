import Foundation

/// 8-bit RGBA bitmap, row-major, no padding.
public struct Bitmap: Sendable {
    public let width: Int
    public let height: Int
    public let rgba: Data
    public init(width: Int, height: Int, rgba: Data) { self.width = width; self.height = height; self.rgba = rgba }
}

public protocol ImageDecoder: Sendable {
    /// Decode, downscaling so the longer side ≤ `maxSide` (0 = full size). Animated → first frame.
    func decode(_ url: URL, maxSide: Int) throws -> Bitmap
    func imageSize(_ url: URL) throws -> (width: Int, height: Int)
}

public protocol VideoProbe: Sendable {
    func durationMs(_ url: URL) throws -> Int64
    /// Frame at `fraction` (0…1) of the duration, downscaled to ≤ `maxSide`.
    func frame(_ url: URL, at fraction: Double, maxSide: Int) throws -> Bitmap
}

public protocol ThumbnailEncoder: Sendable {
    /// JPEG bytes for a bitmap.
    func jpeg(_ bitmap: Bitmap, quality: Double) throws -> Data
    /// A still picture in `format` with the system encoder, or nil when this platform can't write it
    /// natively (the converter then goes through ffmpeg). Formats without alpha are flattened onto white.
    func encode(_ bitmap: Bitmap, as format: MediaFormat, quality: Double) throws -> Data?
}

extension ThumbnailEncoder {
    public func encode(_ bitmap: Bitmap, as format: MediaFormat, quality: Double) throws -> Data? {
        format == .jpeg ? try jpeg(bitmap, quality: quality) : nil
    }
}

/// How a block of text is drawn by `TextRenderer`. Sizes are pixels.
public struct TextStyle: Sendable, Hashable {
    public var size: Double
    public var bold: Bool
    /// 0xRRGGBB.
    public var color: UInt32
    /// 0 = as many lines as the text needs; otherwise the last one ends in "…".
    public var maxLines: Int
    public init(size: Double, bold: Bool = false, color: UInt32, maxLines: Int = 0) {
        self.size = size; self.bold = bold; self.color = color; self.maxLines = maxLines
    }
}

/// Wrapped, shaped text (any script, colour emoji) — the one thing the tweet renderer can't draw itself.
public protocol TextRenderer: Sendable {
    /// `text` wrapped at word boundaries to at most `width` px, straight-alpha RGBA on transparent.
    /// As tall as the text; nil for empty text.
    func render(_ text: String, style: TextStyle, width: Int) throws -> Bitmap?
}

public struct HTTPResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data
    public init(status: Int, headers: [String: String], body: Data) { self.status = status; self.headers = headers; self.body = body }
}

public protocol HTTPClient: Sendable {
    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse
}

/// Everything the core needs from the host OS. Injected once per process.
public struct Platform: Sendable {
    public var images: any ImageDecoder
    public var video: any VideoProbe
    public var thumbs: any ThumbnailEncoder
    public var http: any HTTPClient
    /// ffmpeg when available: probing codecs, converting, and decoding what the OS can't.
    public var transcoder: (any MediaTranscoder)?
    /// Text drawing for rendered tweets (CoreText / pango); nil = tweets stay text-only in the bot.
    public var text: (any TextRenderer)?
    public init(images: any ImageDecoder, video: any VideoProbe, thumbs: any ThumbnailEncoder, http: any HTTPClient,
                transcoder: (any MediaTranscoder)? = nil, text: (any TextRenderer)? = nil) {
        self.images = images; self.video = video; self.thumbs = thumbs; self.http = http; self.transcoder = transcoder
        self.text = text
    }
}
