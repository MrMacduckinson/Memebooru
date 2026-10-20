import Foundation

extension StagingArea {
    /// The untouched file of an edited staged item (nil when it isn't edited).
    public func original(_ item: StagedItem) -> URL? {
        extras(item).first { $0.role == .original }?.url
    }

    /// The file edits start from: the kept original, or the item's own file.
    public func editSource(_ item: StagedItem) -> URL { original(item) ?? fileURL(item) }

    /// Crops / trims a staged item now, so everything that shows it shows the result; the original
    /// stays beside it (and goes into the collection with it). nil or an empty edit puts the original back.
    @discardableResult
    public func applyEdit(_ id: String, _ edit: MediaEdit?) throws -> StagedItem {
        guard let analyzer else { throw CollectionError("editing needs the media tools") }
        guard var item = try get(id) else { throw CollectionError("no staged item \(id)") }
        guard MediaEditor.canCrop(item.kind) || MediaEditor.canTrim(item.kind) else { throw CollectionError("\(item.kind.rawValue) can't be cropped or trimmed") }
        if let c = edit?.crop, !MediaEditor.canCrop(item.kind) || c.width < 1 || c.height < 1 { throw CollectionError("can't crop that") }
        if let t = edit?.trim, !MediaEditor.canTrim(item.kind) || t.startMs < 0 || t.endMs <= t.startMs { throw CollectionError("can't trim that") }
        let fm = FileManager.default
        let dir = directory.appendingPathComponent(item.id, isDirectory: true)
        let edit = edit?.isEmpty == true ? nil : edit
        var original = self.original(item)
        if original == nil {
            guard edit != nil else { return item }                       // nothing done, nothing to undo
            let kept = dir.appendingPathComponent("\(Asset.Role.original.rawValue)_0.\(item.ext)")
            try fm.moveItem(at: fileURL(item), to: kept)
            original = kept
        }
        let base = original!
        let newFile: URL
        if let edit {
            let made = try MediaEditor(analyzer: analyzer).apply(base, kind: item.kind, edit: edit)
            defer { try? fm.removeItem(at: made.deletingLastPathComponent()) }
            if fm.fileExists(atPath: fileURL(item).path) { try fm.removeItem(at: fileURL(item)) }
            newFile = dir.appendingPathComponent("file.\(made.pathExtension)")
            try fm.moveItem(at: made, to: newFile)
        } else {
            // Back to the original: it becomes the item's file again.
            if fm.fileExists(atPath: fileURL(item).path) { try fm.removeItem(at: fileURL(item)) }
            newFile = dir.appendingPathComponent("file.\(base.pathExtension)")
            try fm.moveItem(at: base, to: newFile)
        }
        let ext = MediaStore.normalizeExt(newFile.pathExtension)
        item.ext = ext
        item.mime = MediaType.detect(ext: ext)?.mime ?? item.mime
        item.sha256 = try MediaStore.sha256(of: newFile)
        item.bytes = Int64((try? fm.attributesOfItem(atPath: newFile.path)[.size] as? NSNumber)??.int64Value ?? 0)
        item.info = analyzer.analyze(newFile, kind: item.kind)
        if let n = item.originalName { item.originalName = MediaStore.fileName((n as NSString).deletingPathExtension, ext: ext) }
        item.edit = edit
        try replaceFile(item)
        return item
    }
}

extension Collection {
    /// Crops / trims a saved post. The file it's made from — the kept original, or the current file,
    /// which is kept as the original from now on — is never touched, so the edit can be changed or
    /// undone (nil / empty) any time. Synced like any change of files.
    @discardableResult
    public func applyEdit(_ id: MemeID, _ edit: MediaEdit?, analyzer: MediaAnalyzer) throws -> Asset {
        guard let meme = try memes.get(id), let primary = try memes.primaryAsset(of: id) else { throw CollectionError("no such meme") }
        guard MediaEditor.canCrop(meme.kind) || MediaEditor.canTrim(meme.kind) else { throw CollectionError("\(meme.kind.rawValue) can't be cropped or trimmed") }
        let original = try memes.asset(of: id, role: .original)
        let edit = edit?.isEmpty == true ? nil : edit
        guard edit != nil || primary.edit != nil else { return primary }        // not edited, nothing to undo
        let base = original ?? primary
        let baseURL = media.url(sha256: base.sha256, ext: base.ext)
        var made: URL?
        defer { if let made { try? FileManager.default.removeItem(at: made.deletingLastPathComponent()) } }
        let new: Asset
        if let edit {
            let out = try MediaEditor(analyzer: analyzer).apply(baseURL, kind: meme.kind, edit: edit,
                                                                name: (primary.originalName as NSString?)?.deletingPathExtension ?? "edited")
            made = out
            let info = analyzer.analyze(out, kind: meme.kind)
            let stored = try media.put(out, move: false)
            new = Asset(memeID: id, role: .primary, sha256: stored.sha256, ext: stored.ext,
                        mime: MediaType.detect(ext: stored.ext)?.mime ?? primary.mime,
                        width: info.width, height: info.height, durationMs: info.durationMs, bytes: stored.bytes,
                        dhash: info.dhash, phash: info.phash, originalName: out.lastPathComponent, codecs: info.codecs,
                        sourceSHA256: base.sha256, sourceExt: base.ext == stored.ext ? nil : base.ext,
                        sourceCodecs: base.ext == stored.ext ? nil : base.codecs, edit: edit)
        } else if base.compatibility(kind: meme.kind) == .popular {
            // Undone: the original is shown again as it is.
            var b = base; b.role = .primary; b.order = 0; b.edit = nil
            if original != nil { b.sourceSHA256 = nil; b.sourceExt = nil; b.sourceCodecs = nil }
            new = b
        } else {
            // Undone, but the original is in an uncommon format: shown converted, as before the edit.
            try convertBack(id, from: base, analyzer: analyzer)
            return try memes.primaryAsset(of: id)!
        }
        try db.transaction {
            if original == nil { var o = primary; o.role = .original; o.order = 0; try memes.putAsset(o) }
            try memes.putAsset(new)
        }
        try? analyzer.ensureThumbnail(for: media.url(sha256: new.sha256, ext: new.ext), sha256: new.sha256, kind: meme.kind, in: media)
        return new
    }

    private func convertBack(_ id: MemeID, from base: Asset, analyzer: MediaAnalyzer) throws {
        guard let meme = try memes.get(id), let target = FormatPolicy.popularTarget(kind: meme.kind, ext: base.ext, codecs: base.codecs) else { return }
        let src = media.url(sha256: base.sha256, ext: base.ext)
        let converted = try analyzer.converter.convertToTemporary(src, kind: meme.kind, to: target,
                                                                  name: base.originalName.map { ($0 as NSString).deletingPathExtension } ?? "converted")
        defer { try? FileManager.default.removeItem(at: converted.deletingLastPathComponent()) }
        let info = analyzer.analyze(converted, kind: meme.kind)
        let stored = try media.put(converted, ext: target.ext, move: true)
        try memes.putAsset(Asset(memeID: id, role: .primary, sha256: stored.sha256, ext: stored.ext,
                                 mime: MediaType.detect(ext: stored.ext)?.mime ?? base.mime,
                                 width: info.width, height: info.height, durationMs: info.durationMs, bytes: stored.bytes,
                                 dhash: info.dhash, phash: info.phash, originalName: converted.lastPathComponent, codecs: info.codecs,
                                 sourceSHA256: base.sha256, sourceExt: base.ext, sourceCodecs: base.codecs))
        try? analyzer.ensureThumbnail(for: stored.url, sha256: stored.sha256, kind: meme.kind, in: media)
    }
}
