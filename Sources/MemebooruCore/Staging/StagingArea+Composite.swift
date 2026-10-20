import Foundation

/// The meta tag every combined meme carries.
public let compositeTag = "combined"

extension StagingArea {
    /// The pictures a combined staged item is made of, in order.
    public func parts(_ item: StagedItem) -> [URL] {
        extras(item).filter { $0.role == .part }.sorted { $0.order < $1.order }.map(\.url)
    }

    /// Pixel sizes of the pictures a combined staged item (or the given staged pictures) is made of.
    public func partSizes(_ urls: [URL]) -> [PixelSize] {
        urls.map { url in
            let s = analyzer.flatMap { try? $0.platform.images.imageSize(url) }
                ?? analyzer.flatMap { a in (try? a.converter.raster(url, maxSide: 0)).map { ($0.width, $0.height) } }
            return PixelSize(width: s?.0 ?? 1, height: s?.1 ?? 1)
        }
    }

    /// Several staged pictures become one staged meme: the combined picture is drawn from them, and the
    /// pictures themselves go inside it (kept at full quality, so the layout can be changed any time).
    /// Their tags and words are merged. One undo step brings the separate pictures back — unless
    /// `undoable` is false: then the pictures are simply dropped (for a combine committed straight away, as
    /// the Telegram bot does with albums, where an undo would bring back items nobody ever saw staged).
    @discardableResult
    public func combine(_ ids: [String], layout: CompositeLayout? = nil, undoable: Bool = true) throws -> StagedItem {
        guard let analyzer else { throw CollectionError("combining needs the media tools") }
        let items = try ids.map { id -> StagedItem in
            guard let i = try get(id) else { throw CollectionError("no staged item \(id)") }
            guard i.kind == .image else { throw CollectionError("only pictures can be combined (\(i.originalName ?? i.id) is a \(i.kind.rawValue))") }
            return i
        }
        guard items.count >= 2 else { throw CollectionError("combining needs at least two pictures") }
        guard Set(ids).count == ids.count else { throw CollectionError("a picture can be in a combined meme only once") }
        let files = items.map { fileURL($0) }
        let layout = layout ?? .suggested(for: partSizes(files))
        let made = try CompositeRenderer(converter: analyzer.converter).render(files, layout: layout)

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mb-combine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let stem = items[0].originalName.map { ($0 as NSString).deletingPathExtension } ?? "combined"
        let out = tmp.appendingPathComponent(MediaStore.fileName("\(stem) +\(items.count - 1)", ext: made.ext))
        try made.data.write(to: out)

        func joined(_ k: KeyPath<StagedItem, String?>) -> String? {
            let parts = items.compactMap { $0[keyPath: k]?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        }
        let extras = files.enumerated().map { StagedExtra(role: .part, order: $0.offset, url: $0.element) }
        var item = try add(file: out, source: items[0].source, originalName: out.lastPathComponent, kind: .image,
                           textExact: joined(\.textExact), textVerbatim: joined(\.textVerbatim), context: joined(\.context),
                           payload: .composite(CompositePayload(layout: layout)), extras: extras)
        // The parts' own tags (their year, not today's), plus "combined".
        item.suggestedTags = Array(Set(items.flatMap { $0.suggestedTags } + [MemeKind.image.metaTag, compositeTag])).sorted()
        item.userTags = Self.ordered(items.flatMap { $0.userTags })
        try update(item)

        guard undoable else {
            for i in items { try discard(i.id) }
            return item
        }
        let batch = try collection.undo.begin(kind: "combine", summary: "Combine \(items.count) pictures")
        for i in items { try discardToTrash(i, batch: batch) }
        try collection.undo.record(batch, op: "stage_created", data: item.id)
        try collection.undo.finish(batch, summary: "Combined \(items.count) pictures")
        return item
    }

    /// Draws a combined staged item again with another layout (or other parts order).
    @discardableResult
    public func recombine(_ id: String, layout: CompositeLayout, order: [Int]? = nil) throws -> StagedItem {
        guard let analyzer else { throw CollectionError("combining needs the media tools") }
        guard var item = try get(id), item.payload.composite != nil else { throw CollectionError("not a combined picture") }
        var files = parts(item)
        guard files.count >= 2 else { throw CollectionError("this combined picture has lost its parts") }
        let dir = directory.appendingPathComponent(item.id, isDirectory: true)
        let fm = FileManager.default
        if let order {
            guard order.sorted() == Array(files.indices) else { throw CollectionError("the new order must use every picture once") }
            // Rename to the new order through temporary names (part_0 ↔ part_1 would collide).
            let reordered = order.map { files[$0] }
            var temps: [URL] = []
            for (i, f) in reordered.enumerated() {
                let t = dir.appendingPathComponent("reorder-\(i).\(f.pathExtension)")
                try fm.moveItem(at: f, to: t); temps.append(t)
            }
            files = []
            for (i, t) in temps.enumerated() {
                let f = dir.appendingPathComponent("\(Asset.Role.part.rawValue)_\(i).\(t.pathExtension)")
                try fm.moveItem(at: t, to: f); files.append(f)
            }
        }
        let made = try CompositeRenderer(converter: analyzer.converter).render(files, layout: layout)
        let old = fileURL(item)
        let new = dir.appendingPathComponent("file.\(made.ext)")
        try? fm.removeItem(at: old)
        try made.data.write(to: new, options: .atomic)
        item.ext = made.ext
        item.mime = MediaType.detect(ext: made.ext)?.mime ?? item.mime
        item.sha256 = try MediaStore.sha256(of: new)
        item.bytes = Int64(made.data.count)
        item.info = analyzer.analyze(new, kind: .image)
        if let n = item.originalName { item.originalName = MediaStore.fileName((n as NSString).deletingPathExtension, ext: made.ext) }
        item.payload = .composite(CompositePayload(layout: layout))
        try replaceFile(item)
        return item
    }

    /// A combined staged item back into its separate pictures (each with the combined item's tags and
    /// words). One undo step makes it combined again.
    @discardableResult
    public func split(_ id: String) throws -> [StagedItem] {
        guard let item = try get(id), item.payload.composite != nil else { throw CollectionError("not a combined picture") }
        let files = parts(item)
        guard !files.isEmpty else { throw CollectionError("this combined picture has lost its parts") }
        let stem = item.originalName.map { ($0 as NSString).deletingPathExtension.replacingOccurrences(of: #" \+\d+$"#, with: "", options: .regularExpression) } ?? "part"
        let batch = try collection.undo.begin(kind: "split", summary: "Split a combined picture")
        var out: [StagedItem] = []
        for (i, f) in files.enumerated() {
            var p = try add(file: f, source: item.source, originalName: MediaStore.fileName("\(stem) \(i + 1)", ext: f.pathExtension), kind: .image,
                            textExact: item.textExact, textVerbatim: item.textVerbatim, context: item.context)
            p.suggestedTags = item.suggestedTags.filter { $0 != compositeTag }
            p.userTags = item.userTags
            try update(p)
            try collection.undo.record(batch, op: "stage_created", data: p.id)
            out.append(p)
        }
        try discardToTrash(item, batch: batch)
        try collection.undo.finish(batch, summary: "Split into \(files.count) pictures")
        return out
    }

    /// After the primary file changed: its name, hash, size and measurements.
    func replaceFile(_ i: StagedItem) throws {
        try db.run("""
            UPDATE staged SET sha256=?, ext=?, mime=?, bytes=?, width=?, height=?, duration_ms=?, dhash=?, phash=?, codecs=?,
                              original_name=?, payload=?, edit=? WHERE id=?
            """, [i.sha256, i.ext, i.mime, i.bytes, i.info.width, i.info.height, i.info.durationMs, i.info.dhash, i.info.phash,
                  i.info.codecs, i.originalName, try i.payload.encodeJSON(), i.edit?.json, i.id])
    }

    static func ordered(_ a: [String]) -> [String] {
        var seen: Set<String> = []
        return a.filter { seen.insert($0).inserted }
    }
}

extension Collection {
    /// The pictures a combined meme is made of, in order.
    public func parts(of id: MemeID) throws -> [Asset] {
        try memes.assets(of: id).filter { $0.role == .part }.sorted { $0.order < $1.order }
    }

    /// A combined meme back into separate memes, one per picture, in order: each an image meme with the
    /// picture as its file and the combined meme's tags (but "combined"), words, context and created date.
    /// The combined meme goes to the trash. One undo step brings it back and removes the separate ones.
    @discardableResult
    public func splitComposite(_ id: MemeID, analyzer: MediaAnalyzer?) throws -> [MemeID] {
        guard let meme = try memes.get(id), meme.deletedAt == nil, meme.payload.composite != nil else {
            throw CollectionError("not a combined picture")
        }
        let parts = try parts(of: id)
        guard !parts.isEmpty else { throw CollectionError("this combined picture has lost its parts") }
        let tags = try memes.tags(of: id).filter { $0.name != compositeTag }
        let stem = try memes.primaryAsset(of: id)?.originalName.map {
            ($0 as NSString).deletingPathExtension.replacingOccurrences(of: #" \+\d+$"#, with: "", options: .regularExpression)
        } ?? "part"
        let batch = try undo.begin(kind: "split", summary: "Split a combined meme")
        var made: [MemeID] = []
        do {
            try db.transaction {
                for (i, p) in parts.enumerated() {
                    let m = Meme(kind: .image, presentation: meme.presentation, createdAt: meme.createdAt,
                                 textExact: meme.textExact, textVerbatim: meme.textVerbatim, context: meme.context)
                    try memes.insert(m)
                    for t in tags { try memes.addTag(m.id, t.name, kind: t.kind) }
                    try memes.addAsset(Asset(memeID: m.id, role: .primary, sha256: p.sha256, ext: p.ext, mime: p.mime,
                                             width: p.width, height: p.height, bytes: p.bytes, dhash: p.dhash, phash: p.phash,
                                             originalName: MediaStore.fileName("\(stem) \(i + 1)", ext: p.ext), codecs: p.codecs))
                    try undo.record(batch, op: "create_meme", data: m.id.rawValue)
                    made.append(m.id)
                }
                try memes.delete(id)
                try undo.record(batch, op: "delete_meme", data: id.rawValue)
            }
        } catch {
            try? undo.finish(batch)          // the transaction took its entries with it: no empty step is left
            throw error
        }
        try undo.finish(batch, summary: "Split into \(parts.count) pictures")
        for p in parts {
            try? analyzer?.ensureThumbnail(for: media.url(sha256: p.sha256, ext: p.ext), sha256: p.sha256, kind: .image, in: media)
        }
        return made
    }

    /// Draws a combined meme again with another layout or order of its pictures. The new picture
    /// replaces the old one (both stay in the media store; the change syncs like any edit).
    @discardableResult
    public func recombine(_ id: MemeID, layout: CompositeLayout, order: [Int]? = nil, analyzer: MediaAnalyzer) throws -> Asset {
        guard var meme = try memes.get(id), meme.payload.composite != nil else { throw CollectionError("not a combined picture") }
        var parts = try parts(of: id)
        guard parts.count >= 2 else { throw CollectionError("this combined picture has lost its parts") }
        if let order {
            guard order.sorted() == Array(parts.indices) else { throw CollectionError("the new order must use every picture once") }
            parts = order.map { parts[$0] }
        }
        let made = try CompositeRenderer(converter: analyzer.converter).render(parts.map { media.url(sha256: $0.sha256, ext: $0.ext) }, layout: layout)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mb-recombine-\(UUID().uuidString).\(made.ext)")
        try made.data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let info = analyzer.analyze(tmp, kind: .image)
        let old = try memes.primaryAsset(of: id)
        let stored = try media.put(tmp, ext: made.ext, move: false)
        let primary = Asset(memeID: id, role: .primary, sha256: stored.sha256, ext: stored.ext,
                            mime: MediaType.detect(ext: stored.ext)?.mime ?? "image/png",
                            width: info.width, height: info.height, bytes: stored.bytes, dhash: info.dhash, phash: info.phash,
                            originalName: old?.originalName.map { MediaStore.fileName(($0 as NSString).deletingPathExtension, ext: made.ext) })
        meme.payload = .composite(CompositePayload(layout: layout))
        try db.transaction {
            try memes.putAsset(primary)
            if order != nil {
                for (i, var p) in parts.enumerated() { p.order = i; try memes.putAsset(p) }
            }
            try memes.update(meme)
        }
        try? analyzer.ensureThumbnail(for: stored.url, sha256: stored.sha256, kind: .image, in: media)
        return primary
    }
}
