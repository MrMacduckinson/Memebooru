import Foundation

/// Extension → (kind, mime). Kind detection by extension is enough for import; real decode happens later.
public enum MediaType {
    public static let table: [String: (MemeKind, String)] = [
        "jpg": (.image, "image/jpeg"), "jpeg": (.image, "image/jpeg"), "png": (.image, "image/png"),
        "webp": (.image, "image/webp"), "heic": (.image, "image/heic"), "heif": (.image, "image/heif"),
        "bmp": (.image, "image/bmp"), "tif": (.image, "image/tiff"), "tiff": (.image, "image/tiff"),
        "avif": (.image, "image/avif"), "jxl": (.image, "image/jxl"),
        "svg": (.image, "image/svg+xml"),   // vector: rasterised for thumbnails/hashes, drawn as vector in the viewer
        "gif": (.gif, "image/gif"),
        "mp4": (.video, "video/mp4"), "mov": (.video, "video/quicktime"), "webm": (.video, "video/webm"),
        "mkv": (.video, "video/x-matroska"), "m4v": (.video, "video/x-m4v"), "avi": (.video, "video/x-msvideo"),
        "flv": (.video, "video/x-flv"), "3gp": (.video, "video/3gpp"), "3g2": (.video, "video/3gpp2"),
        "mp3": (.audio, "audio/mpeg"), "m4a": (.audio, "audio/mp4"), "ogg": (.audio, "audio/ogg"),
        "oga": (.audio, "audio/ogg"), "opus": (.audio, "audio/opus"), "wav": (.audio, "audio/wav"),
        "flac": (.audio, "audio/flac"), "aac": (.audio, "audio/aac"),
        "txt": (.text, "text/plain"), "md": (.text, "text/markdown"),
    ]

    public static func detect(ext rawExt: String) -> (kind: MemeKind, mime: String)? {
        table[MediaStore.normalizeExt(rawExt)]
    }

    public static func detect(url: URL) -> (kind: MemeKind, mime: String)? { detect(ext: url.pathExtension) }

    public static var supportedExtensions: Set<String> { Set(table.keys) }

    public static func ext(forMime mime: String) -> String? {
        table.first { $0.value.1 == mime }?.key
    }
}
