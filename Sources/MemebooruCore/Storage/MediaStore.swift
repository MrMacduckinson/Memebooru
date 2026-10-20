import Crypto
import Foundation

public struct StoredFile: Sendable, Equatable {
    public let sha256: String
    public let ext: String
    public let bytes: Int64
    public let url: URL
    public let wasNew: Bool
}

/// Content-addressed file store: `media/ab/abcdef….ext`. Same bytes ⇒ same path, dedup for free.
public struct MediaStore: Sendable {
    public let root: URL
    public let thumbs: URL

    public init(root: URL, thumbs: URL) { self.root = root; self.thumbs = thumbs }

    public static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public func url(sha256: String, ext: String) -> URL {
        root.appendingPathComponent(String(sha256.prefix(2)), isDirectory: true)
            .appendingPathComponent("\(sha256).\(ext)")
    }

    public func thumbURL(sha256: String) -> URL {
        thumbs.appendingPathComponent("\(sha256).jpg")
    }

    public func exists(sha256: String, ext: String) -> Bool {
        FileManager.default.fileExists(atPath: url(sha256: sha256, ext: ext).path)
    }

    /// Copies (or moves) `source` into the store. Idempotent.
    public func put(_ source: URL, ext explicitExt: String? = nil, move: Bool = false) throws -> StoredFile {
        let fm = FileManager.default
        let sha = try Self.sha256(of: source)
        let ext = Self.normalizeExt(explicitExt ?? source.pathExtension)
        let dest = url(sha256: sha, ext: ext)
        let size = (try fm.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value ?? 0
        if fm.fileExists(atPath: dest.path) {
            if move { try? fm.removeItem(at: source) }
            return StoredFile(sha256: sha, ext: ext, bytes: size, url: dest, wasNew: false)
        }
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Copies land beside the destination and are renamed into place: nobody sees a half-written
        // file, and a racing writer of the same bytes simply finds it there.
        let incoming = move ? source : dest.deletingLastPathComponent().appendingPathComponent(".\(sha).\(UUID().uuidString).part")
        if !move { try fm.copyItem(at: source, to: incoming) }
        do {
            try fm.moveItem(at: incoming, to: dest)
        } catch {
            guard fm.fileExists(atPath: dest.path) else {
                if !move { try? fm.removeItem(at: incoming) }
                throw error
            }
            try? fm.removeItem(at: incoming)                                  // same content already stored
            return StoredFile(sha256: sha, ext: ext, bytes: size, url: dest, wasNew: false)
        }
        return StoredFile(sha256: sha, ext: ext, bytes: size, url: dest, wasNew: true)
    }

    public func put(data: Data, ext: String) throws -> StoredFile {
        let sha = Self.sha256(of: data)
        let ext = Self.normalizeExt(ext)
        let dest = url(sha256: sha, ext: ext)
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            return StoredFile(sha256: sha, ext: ext, bytes: Int64(data.count), url: dest, wasNew: false)
        }
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: dest, options: .atomic)
        return StoredFile(sha256: sha, ext: ext, bytes: Int64(data.count), url: dest, wasNew: true)
    }

    public func remove(sha256: String, ext: String) throws {
        let fm = FileManager.default
        let u = url(sha256: sha256, ext: ext)
        if fm.fileExists(atPath: u.path) { try fm.removeItem(at: u) }
        let t = thumbURL(sha256: sha256)
        if fm.fileExists(atPath: t.path) { try fm.removeItem(at: t) }
    }

    /// `base.ext`, `base` shortened at a character boundary so the name fits NAME_MAX (255 bytes).
    static func fileName(_ base: String, ext: String) -> String {
        let budget = 255 - (ext.isEmpty ? 0 : ext.utf8.count + 1)
        var b = Substring(base)
        while b.utf8.count > budget { b = b.dropLast() }
        return ext.isEmpty ? String(b) : "\(b).\(ext)"
    }

    public static func normalizeExt(_ ext: String) -> String {
        let e = ext.lowercased()
        switch e {
        case "jpeg": return "jpg"
        case "": return "bin"
        default: return e
        }
    }
}
