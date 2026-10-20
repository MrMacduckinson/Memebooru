import Foundation

/// What to export: the displayed file, the kept original, or a conversion made just for this export.
public enum ExportChoice: Sendable, Equatable {
    case stored
    case original
    case format(MediaFormat)
}

extension Collection {
    /// The meme's files: what is shown (primary) and, when kept, the uncommon original it was made from.
    public func formats(of id: MemeID) throws -> (primary: Asset?, original: Asset?) {
        (try memes.primaryAsset(of: id), try memes.asset(of: id, role: .original))
    }

    /// Converts a meme stored only in an uncommon format to its popular format. The old file becomes the
    /// kept original (`keepOriginal`), or is dropped from the meme. Synced like any asset change.
    @discardableResult
    public func convertMeme(_ id: MemeID, keepOriginal: Bool, analyzer: MediaAnalyzer) throws -> Asset {
        guard let meme = try memes.get(id), let old = try memes.primaryAsset(of: id) else { throw CollectionError("no such meme") }
        guard old.compatibility(kind: meme.kind) == .uncommon,
              let target = FormatPolicy.popularTarget(kind: meme.kind, ext: old.ext, codecs: old.codecs) else {
            throw CollectionError("already in a popular format")
        }
        let src = media.url(sha256: old.sha256, ext: old.ext)
        let base = old.originalName.map { ($0 as NSString).deletingPathExtension } ?? "converted"
        let converted = try analyzer.converter.convertToTemporary(src, kind: meme.kind, to: target, name: base)
        defer { try? FileManager.default.removeItem(at: converted.deletingLastPathComponent()) }
        let info = analyzer.analyze(converted, kind: meme.kind)
        let stored = try media.put(converted, ext: target.ext, move: true)
        let primary = Asset(memeID: id, role: .primary, sha256: stored.sha256, ext: stored.ext,
                            mime: MediaType.detect(ext: stored.ext)?.mime ?? old.mime,
                            width: info.width, height: info.height, durationMs: info.durationMs, bytes: stored.bytes,
                            dhash: info.dhash, phash: info.phash, originalName: converted.lastPathComponent, codecs: info.codecs,
                            sourceSHA256: old.sha256, sourceExt: old.ext, sourceCodecs: old.codecs)
        try db.transaction {
            try memes.putAsset(primary)
            if keepOriginal {
                var o = old; o.role = .original; o.order = 0
                try memes.putAsset(o)
            }
        }
        try? analyzer.ensureThumbnail(for: stored.url, sha256: stored.sha256, kind: meme.kind, in: media)
        return primary
    }

    /// Writes the meme to `dest` (a file, or a folder to name it in). Conversions are made for the export
    /// only and never stored. Converting starts from the kept original when there is one (best quality).
    @discardableResult
    public func export(_ id: MemeID, as choice: ExportChoice, to dest: URL, analyzer: MediaAnalyzer? = nil) throws -> URL {
        guard let meme = try memes.get(id) else { throw CollectionError("no such meme") }
        let (primary, original) = try formats(of: id)
        func file(_ a: Asset) -> URL { media.url(sha256: a.sha256, ext: a.ext) }
        func target(ext: String, name: String?) -> URL {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dest.path, isDirectory: &isDir), isDir.boolValue else {
                // A file path: its extension must say what's inside.
                return dest.pathExtension.lowercased() == ext ? dest : dest.deletingPathExtension().appendingPathExtension(ext)
            }
            let base = name.map { ($0 as NSString).deletingPathExtension }.flatMap { $0.isEmpty ? nil : $0 }
                ?? meme.textExact.map { String($0.prefix(40)) } ?? id.rawValue
            return dest.appendingPathComponent(MediaStore.fileName(base.replacingOccurrences(of: "/", with: "_"), ext: ext))
        }

        switch choice {
        case .stored, .original:
            guard let a = choice == .original ? original : primary else {
                throw CollectionError(choice == .original ? "no original kept for this meme" : "this meme has no file")
            }
            let out = target(ext: a.ext, name: a.originalName)
            try? FileManager.default.removeItem(at: out)
            try FileManager.default.copyItem(at: file(a), to: out)
            return out
        case .format(let format):
            // A cropped / trimmed meme exports what it shows; otherwise the best-quality file is the start.
            let edited = primary?.edit != nil
            guard let source = edited ? primary : (original ?? primary) else { throw CollectionError("this meme has no file") }
            let out = target(ext: format.ext, name: primary?.originalName ?? source.originalName)
            // One of the stored files already is that format → a plain copy, no re-encode.
            if let same = (edited ? [primary] : [primary, original]).compactMap({ $0 }).first(where: { format.matches(ext: $0.ext, codecs: $0.codecs) }) {
                try? FileManager.default.removeItem(at: out)
                try FileManager.default.copyItem(at: file(same), to: out)
                return out
            }
            guard let analyzer else { throw CollectionError("converting needs the media tools") }
            try analyzer.converter.convert(file(source), kind: meme.kind, to: format, dest: out)
            return out
        }
    }
}
