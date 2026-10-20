import Foundation

public struct StagedItem: Sendable, Equatable, Codable {
    public var id: String
    public var kind: MemeKind
    public var source: String
    public var originalName: String?
    public var sha256: String
    public var ext: String
    public var mime: String
    public var bytes: Int64
    public var info: MediaInfo
    public var textExact: String?
    public var textVerbatim: String?
    public var context: String?
    public var payload: MemePayload
    public var suggestedTags: [String]
    public var userTags: [String]
    public var addedAt: Int64
    /// For uncommon formats: convert to the popular one on commit (nil = the default, yes), and whether
    /// to keep the original file too (nil = the default, see `keepsOriginalByDefault`).
    public var convert: Bool? = nil
    public var keepOriginal: Bool? = nil
    /// Set on a tweet staged as part of another staged tweet's chain (what it replies to or quotes):
    /// that tweet's id. Such items aren't listed on their own and go wherever their tweet goes.
    public var parentID: String? = nil
    /// Cropped / trimmed: the file is the edited one, the original rides along (extra `original_0`).
    public var edit: MediaEdit? = nil

    /// Tags that will be applied on commit.
    public var effectiveTags: [String] { Array(Set(suggestedTags + userTags)).sorted() }

    public var compatibility: Compatibility { FormatPolicy.compatibility(kind: kind, ext: ext, codecs: info.codecs) }
    public var popularTarget: MediaFormat? { FormatPolicy.popularTarget(kind: kind, ext: ext, codecs: info.codecs) }
    public var formatLabel: String { FormatPolicy.label(ext: ext, codecs: info.codecs) }
    /// Converting a vector to pixels loses something real — keep SVG originals unless told otherwise.
    public var keepsOriginalByDefault: Bool { ext == "svg" }
    public var willConvert: Bool { compatibility == .uncommon && popularTarget != nil && (convert ?? true) }
    public var willKeepOriginal: Bool { keepOriginal ?? keepsOriginalByDefault }
}

/// Additional file staged next to the primary one (tweet media, avatar). Committed as its own asset.
public struct StagedExtra: Sendable, Equatable {
    public var role: Asset.Role
    public var order: Int
    public var url: URL
    public init(role: Asset.Role, order: Int, url: URL) { self.role = role; self.order = order; self.url = url }
}

public struct DuplicateHit: Sendable, Equatable {
    public enum Match: Sendable, Equatable { case exact, similar(distance: Int), stagedExact(id: String), stagedSimilar(id: String, distance: Int) }
    public let memeID: MemeID?
    public let match: Match
}

/// Buffer zone: files land here first, get tags, then move into the collection.
public final class StagingArea: @unchecked Sendable {
    public static let similarThreshold = 10

    let collection: Collection
    var db: Database { collection.db }
    public let analyzer: MediaAnalyzer?

    public init(collection: Collection, analyzer: MediaAnalyzer?) {
        self.collection = collection; self.analyzer = analyzer
    }

    public var directory: URL { collection.stagingURL }
    private var trashRoot: URL { collection.stagingURL.appendingPathComponent(".trash", isDirectory: true) }

    // MARK: - Add

    /// Copies `file` into `staging/<id>/`, analyses it, records a row. `date` seeds the year meta tag.
    @discardableResult
    public func add(file: URL, source: String, originalName: String? = nil, kind explicitKind: MemeKind? = nil,
                    date: Date? = nil, textExact: String? = nil, textVerbatim: String? = nil, context: String? = nil,
                    payload: MemePayload = .none, extraTags: [String] = [], extras: [StagedExtra] = [],
                    parentID: String? = nil) throws -> StagedItem {
        let fm = FileManager.default
        guard let detected = MediaType.detect(url: file) ?? explicitKind.map({ ($0, "application/octet-stream") }) else {
            throw CollectionError("unsupported file type: \(file.lastPathComponent)")
        }
        let kind = explicitKind ?? detected.0
        let ext = MediaStore.normalizeExt(file.pathExtension)
        let mime = MediaType.detect(url: file)?.mime ?? (ext == "json" ? "application/json" : detected.1)
        let id = UUID().uuidString.lowercased()
        let dir = directory.appendingPathComponent(id, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // A file that can't be read (vanished, unreadable extra…) leaves no half-made item folder behind.
        var added = false
        defer { if !added { try? fm.removeItem(at: dir) } }
        let dest = dir.appendingPathComponent("file.\(ext)")
        // A symlink is copied as the file it points to: a link in `media/` would dangle once the original goes.
        let real = file.resolvingSymlinksInPath()
        try fm.copyItem(at: real, to: dest)
        for e in extras {
            try fm.copyItem(at: e.url.resolvingSymlinksInPath(), to: dir.appendingPathComponent("\(e.role.rawValue)_\(e.order).\(MediaStore.normalizeExt(e.url.pathExtension))"))
        }
        let attrs = try fm.attributesOfItem(atPath: real.path)
        let bytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let fileDate = date ?? [attrs[.creationDate] as? Date, attrs[.modificationDate] as? Date].compactMap { $0 }.min() ?? Date()
        let sha = try MediaStore.sha256(of: dest)

        var verbatim = textVerbatim
        if kind == .text, verbatim == nil, let s = try? String(contentsOf: dest, encoding: .utf8) { verbatim = s }

        var info = analyzer?.analyze(dest, kind: kind) ?? MediaInfo()
        if kind == .text, info.phash == nil, let verbatim { info.phash = PerceptualHash.toInt64(TextHash.simhash(verbatim)) }
        let year = Calendar(identifier: .gregorian).component(.year, from: fileDate)
        // A chain tweet isn't a post of its own: no type/year tags (they'd count it in Tweets).
        let suggested = Array(Set((parentID == nil ? [kind.metaTag, String(year)] : []) + extraTags)).sorted()

        var item = StagedItem(id: id, kind: kind, source: source, originalName: originalName ?? file.lastPathComponent,
                              sha256: sha, ext: ext, mime: mime, bytes: bytes, info: info,
                              textExact: textExact, textVerbatim: verbatim, context: context, payload: payload,
                              suggestedTags: suggested, userTags: [], addedAt: Clock.nowMillis())
        item.parentID = parentID
        try insert(item)
        added = true
        return item
    }

    /// Stage a text meme from a string (copypasta, joke).
    @discardableResult
    public func add(text: String, source: String, date: Date? = nil, context: String? = nil, extraTags: [String] = []) throws -> StagedItem {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mb-\(UUID().uuidString).txt")
        try text.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        return try add(file: tmp, source: source, originalName: nil, kind: .text, date: date,
                       textVerbatim: text, context: context, extraTags: extraTags)
    }

    // MARK: - Query

    /// Items to review — chain tweets are left out (see `chain(of:)`).
    public func list() throws -> [StagedItem] {
        try db.query("SELECT * FROM staged WHERE parent_id IS NULL ORDER BY added_at, id", [], Self.item)
    }

    /// The tweets staged along with `id` (what it replies to, up the thread, and what it quotes).
    public func chain(of id: String) throws -> [StagedItem] {
        try db.query("SELECT * FROM staged WHERE parent_id = ? ORDER BY added_at, id", [id], Self.item)
    }

    public func get(_ id: String) throws -> StagedItem? {
        try db.first("SELECT * FROM staged WHERE id = ?", [id], Self.item)
    }

    public func count() throws -> Int { Int(try db.scalarInt("SELECT count(*) FROM staged WHERE parent_id IS NULL")) }

    /// Tweet ids currently in staging (from tweet payloads).
    public func stagedTweetIDs() throws -> Set<String> {
        let payloads = try db.query("SELECT payload FROM staged WHERE kind = 'tweet' AND payload IS NOT NULL", []) { $0.string(0) }
        return Set(payloads.compactMap { (try? MemePayload.decode(kind: .tweet, json: $0)).flatMap { if case .tweet(let p) = $0 { return p.tweetID } else { return nil } } })
    }

    /// True if the collection already holds this tweet.
    public func collectionHasTweet(_ tweetID: String) throws -> Bool { try collection.memes.tweetExists(tweetID) }

    public func fileURL(_ item: StagedItem) -> URL {
        directory.appendingPathComponent(item.id, isDirectory: true).appendingPathComponent("file.\(item.ext)")
    }

    /// Extra files staged alongside the primary (`<role>_<n>.<ext>`).
    public func extras(_ item: StagedItem) -> [StagedExtra] {
        let dir = directory.appendingPathComponent(item.id, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.compactMap { name in
            let stem = (name as NSString).deletingPathExtension
            let parts = stem.split(separator: "_", maxSplits: 1)
            guard parts.count == 2, let role = Asset.Role(rawValue: String(parts[0])), let n = Int(parts[1]) else { return nil }
            return StagedExtra(role: role, order: n, url: dir.appendingPathComponent(name))
        }.sorted { ($0.role.rawValue, $0.order) < ($1.role.rawValue, $1.order) }
    }

    public func update(_ item: StagedItem) throws {
        try db.run(
            "UPDATE staged SET text_exact=?, text_verbatim=?, context=?, payload=?, suggested_tags=?, user_tags=?, kind=?, convert=?, keep_original=? WHERE id=?",
            [item.textExact, item.textVerbatim, item.context, try item.payload.encodeJSON(),
             Self.json(item.suggestedTags), Self.json(item.userTags), item.kind.rawValue,
             item.convert.map { $0 ? 1 : 0 }, item.keepOriginal.map { $0 ? 1 : 0 }, item.id])
    }

    // MARK: - Duplicates

    /// Exact (same bytes) and near (pHash within threshold) matches in the collection and among other staged items.
    public func duplicates(of item: StagedItem) throws -> [DuplicateHit] {
        var hits: [DuplicateHit] = []
        for id in try collection.memes.memes(withSHA256: item.sha256) { hits.append(DuplicateHit(memeID: id, match: .exact)) }
        for other in try db.query("SELECT id FROM staged WHERE sha256 = ? AND id != ?", [item.sha256, item.id], { $0.string(0) }) {
            hits.append(DuplicateHit(memeID: nil, match: .stagedExact(id: other)))
        }
        guard let ph = item.info.phash else { return hits }
        let mine = PerceptualHash.fromInt64(ph)
        let exactIDs = Set(hits.compactMap(\.memeID))
        let rows = try db.query(
            "SELECT DISTINCT a.meme_id, a.phash FROM asset a JOIN meme m ON m.id = a.meme_id WHERE a.phash IS NOT NULL AND m.deleted_at IS NULL AND a.role = 'primary'",
            []) { (MemeID($0.string(0)), PerceptualHash.fromInt64($0.int64(1))) }
        for (id, h) in rows where !exactIDs.contains(id) {
            let d = PerceptualHash.hamming(mine, h)
            if d <= Self.similarThreshold { hits.append(DuplicateHit(memeID: id, match: .similar(distance: d))) }
        }
        let staged = try db.query("SELECT id, phash FROM staged WHERE phash IS NOT NULL AND id != ? AND sha256 != ?", [item.id, item.sha256]) {
            ($0.string(0), PerceptualHash.fromInt64($0.int64(1)))
        }
        for (id, h) in staged {
            let d = PerceptualHash.hamming(mine, h)
            if d <= Self.similarThreshold { hits.append(DuplicateHit(memeID: nil, match: .stagedSimilar(id: id, distance: d))) }
        }
        return hits
    }

    /// Copy an existing collection file (e.g. a tweet's photo/video) into staging as a plain meme,
    /// carrying over some tags. Returns nil for kinds without a real media file.
    @discardableResult
    public func addFromCollectionFile(_ url: URL, source: String, date: Date? = nil, extraTags: [String] = []) throws -> StagedItem? {
        guard MediaType.detect(url: url) != nil else { return nil }
        return try add(file: url, source: source, originalName: url.lastPathComponent, date: date, extraTags: extraTags)
    }

    // MARK: - Commit / discard

    /// Moves the file into `media/`, creates the meme with its tags, drops the staged row.
    @discardableResult
    /// - Parameters:
    ///   - convert / keepOriginal: override the item's own choice for an uncommon format (nil = use it).
    ///     Conversion needs a transcoder (the analyzer's platform); without one the file is stored as is.
    public func commit(_ id: String, tags overrideTags: [String]? = nil, defaultKind: TagKind = .normal, undoBatch: Int64? = nil,
                       convert: Bool? = nil, keepOriginal: Bool? = nil) throws -> Meme {
        let chain = try self.chain(of: id)
        let meme = try commitOne(id, tags: overrideTags, defaultKind: defaultKind, undoBatch: undoBatch, convert: convert, keepOriginal: keepOriginal)
        guard meme.kind == .tweet else { return meme }
        // Its chain goes in with it; a chain tweet the collection got meanwhile is just linked.
        var committed: Set<MemeID> = [meme.id]
        for c in chain {
            if case .tweet(let p) = c.payload, let existing = try collection.memes.memeForTweet(p.tweetID) {
                committed.insert(existing); try discard(c.id); continue
            }
            committed.insert(try commitOne(c.id, defaultKind: .meta, undoBatch: undoBatch).id)
        }
        try collection.linkTweets(committed)
        return meme
    }

    private func commitOne(_ id: String, tags overrideTags: [String]? = nil, defaultKind: TagKind = .normal, undoBatch: Int64? = nil,
                           convert: Bool? = nil, keepOriginal: Bool? = nil) throws -> Meme {
        guard var item = try get(id) else { throw CollectionError("no staged item \(id)") }
        if let convert { item.convert = convert }
        if let keepOriginal { item.keepOriginal = keepOriginal }
        let src = fileURL(item)
        let meme = Meme(kind: item.kind, presentation: .native, textExact: item.textExact,
                        textVerbatim: item.textVerbatim, context: item.context, payload: item.payload)
        let tagNames = overrideTags ?? item.effectiveTags

        // Uncommon format → popular one (the original kept alongside on request).
        var primary: Asset
        var original: Asset?
        var stored: StoredFile
        // Staged files moved into media so far: (where they are now, where they were) — put back if the commit fails.
        var moved: [(URL, URL)] = []
        if item.willConvert, let target = item.popularTarget, let analyzer, analyzer.converter.canTranscode || target.group == .still {
            let base = item.originalName.map { ($0 as NSString).deletingPathExtension } ?? "converted"
            let converted = try analyzer.converter.convertToTemporary(src, kind: item.kind, to: target, name: base)
            defer { try? FileManager.default.removeItem(at: converted.deletingLastPathComponent()) }
            let info = analyzer.analyze(converted, kind: item.kind)
            stored = try collection.media.put(converted, ext: target.ext, move: true)
            primary = Asset(memeID: meme.id, role: .primary, sha256: stored.sha256, ext: stored.ext,
                            mime: MediaType.detect(ext: stored.ext)?.mime ?? item.mime,
                            width: info.width, height: info.height, durationMs: info.durationMs, bytes: stored.bytes,
                            dhash: info.dhash, phash: info.phash, originalName: converted.lastPathComponent, codecs: info.codecs,
                            sourceSHA256: item.sha256, sourceExt: item.ext, sourceCodecs: item.info.codecs)
            if item.willKeepOriginal {
                let orig = try collection.media.put(src, ext: item.ext, move: true)
                moved.append((orig.url, src))
                original = Asset(memeID: meme.id, role: .original, sha256: orig.sha256, ext: orig.ext, mime: item.mime,
                                 width: item.info.width, height: item.info.height, durationMs: item.info.durationMs,
                                 bytes: orig.bytes, dhash: item.info.dhash, phash: item.info.phash,
                                 originalName: item.originalName, codecs: item.info.codecs)
            }
        } else {
            // An edited item: its original rides along as an extra; the file says what it was made from.
            let source = item.edit == nil ? nil : self.original(item)
            let sourceSHA = try source.map { try MediaStore.sha256(of: $0) }
            let sourceExt = source.map { MediaStore.normalizeExt($0.pathExtension) }.flatMap { $0 == item.ext ? nil : $0 }
            stored = try collection.media.put(src, ext: item.ext, move: true)
            moved.append((stored.url, src))
            primary = Asset(memeID: meme.id, role: .primary, sha256: stored.sha256, ext: stored.ext, mime: item.mime,
                            width: item.info.width, height: item.info.height, durationMs: item.info.durationMs,
                            bytes: stored.bytes, dhash: item.info.dhash, phash: item.info.phash, originalName: item.originalName,
                            codecs: item.info.codecs, sourceSHA256: sourceSHA, sourceExt: sourceExt, edit: item.edit)
        }
        let extraFiles = extras(item)
        do { try db.transaction {
            try collection.memes.insert(meme)
            for t in tagNames {
                // meta kind for auto-suggested type/year tags, `defaultKind` for the rest
                let isMeta = item.suggestedTags.contains(t) || t.allSatisfy(\.isNumber)
                try collection.memes.addTag(meme.id, t, kind: isMeta ? .meta : defaultKind)
            }
            try collection.memes.addAsset(primary)
            if let original { try collection.memes.addAsset(original) }
            for e in extraFiles {
                let st = try collection.media.put(e.url, move: true)
                moved.append((st.url, e.url))
                let mime = MediaType.detect(ext: st.ext)?.mime ?? "application/octet-stream"
                var info = MediaInfo()
                if let kind = MediaType.detect(ext: st.ext)?.kind { info = analyzer?.analyze(st.url, kind: kind) ?? MediaInfo() }
                try collection.memes.addAsset(Asset(memeID: meme.id, role: e.role, sha256: st.sha256, ext: st.ext, mime: mime,
                                                    width: info.width, height: info.height, durationMs: info.durationMs,
                                                    bytes: st.bytes, dhash: info.dhash, phash: info.phash, order: e.order))
            }
            try db.run("DELETE FROM staged WHERE id = ?", [id])
            if let undoBatch { try collection.undo.record(undoBatch, op: "create_meme", data: meme.id.rawValue) }
            // Background Wayback snapshot for tweets kept as tweets (non-blocking).
            if item.kind == .tweet, item.parentID == nil, case .tweet(let p) = meme.payload, p.waybackURL == nil, !p.url.isEmpty {
                try collection.wayback.enqueue(meme.id, url: p.url)
            }
        } } catch {
            // Nothing was committed: copy the files back (media files may be shared) so the item can be fixed and retried.
            for (now, was) in moved where !FileManager.default.fileExists(atPath: was.path) {
                try? FileManager.default.copyItem(at: now, to: was)
            }
            throw error
        }
        try? analyzer?.ensureThumbnail(for: stored.url, sha256: stored.sha256, kind: item.kind, in: collection.media)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(id, isDirectory: true))
        return meme
    }

    public func discard(_ id: String) throws {
        for c in try chain(of: id) { try discard(c.id) }
        try db.run("DELETE FROM staged WHERE id = ?", [id])
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(id, isDirectory: true))
    }

    /// Reversible discard: move the item's files to a per-batch trash folder and drop the row.
    func discardToTrash(_ item: StagedItem, batch: Int64) throws {
        for c in try chain(of: item.id) { try discardToTrash(c, batch: batch) }
        let fm = FileManager.default
        let src = directory.appendingPathComponent(item.id, isDirectory: true)
        let dst = trashRoot.appendingPathComponent(String(batch), isDirectory: true).appendingPathComponent(item.id, isDirectory: true)
        if fm.fileExists(atPath: src.path) {
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: dst)
            try fm.moveItem(at: src, to: dst)
        }
        let json = String(decoding: try JSONEncoder().encode(StagedItemDTO(item: item)), as: UTF8.self)
        try collection.undo.record(batch, op: "stage_removed", data: json)
        try db.run("DELETE FROM staged WHERE id = ?", [item.id])
    }

    /// Undo of a discard: move files back and re-insert the row.
    func restore(_ item: StagedItem, fromTrash batch: Int64) throws {
        let fm = FileManager.default
        let src = trashRoot.appendingPathComponent(String(batch), isDirectory: true).appendingPathComponent(item.id, isDirectory: true)
        let dst = directory.appendingPathComponent(item.id, isDirectory: true)
        if fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) { try fm.moveItem(at: src, to: dst) }
        try insert(item)
    }

    /// Remove trash folders older than `days` (called on launch).
    public func pruneTrash(olderThanDays days: Int = 14) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: trashRoot, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        for u in entries {
            if let d = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, d < cutoff {
                try? fm.removeItem(at: u)
            }
        }
    }

    // MARK: - Row mapping

    private func insert(_ i: StagedItem) throws {
        try db.run("""
            INSERT INTO staged(id, kind, source, original_name, sha256, ext, mime, bytes, width, height, duration_ms, dhash, phash,
                               text_exact, text_verbatim, context, payload, suggested_tags, user_tags, added_at, codecs, convert, keep_original,
                               parent_id, edit)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [i.id, i.kind.rawValue, i.source, i.originalName, i.sha256, i.ext, i.mime, i.bytes,
                  i.info.width, i.info.height, i.info.durationMs, i.info.dhash, i.info.phash,
                  i.textExact, i.textVerbatim, i.context, try i.payload.encodeJSON(),
                  Self.json(i.suggestedTags), Self.json(i.userTags), i.addedAt, i.info.codecs,
                  i.convert.map { $0 ? 1 : 0 }, i.keepOriginal.map { $0 ? 1 : 0 }, i.parentID, i.edit?.json])
    }

    static func row(_ r: Row) throws -> StagedItem { try item(r) }

    private static func item(_ r: Row) throws -> StagedItem {
        let kind = MemeKind(rawValue: r.string("kind")) ?? .image
        var item = StagedItem(
            id: r.string("id"), kind: kind, source: r.string("source"), originalName: r.optString("original_name"),
            sha256: r.string("sha256"), ext: r.string("ext"), mime: r.string("mime"), bytes: r.int64("bytes"),
            info: MediaInfo(width: r.optInt("width"), height: r.optInt("height"), durationMs: r.optInt64("duration_ms"),
                            dhash: r.optInt64("dhash"), phash: r.optInt64("phash"), codecs: r.optString("codecs")),
            textExact: r.optString("text_exact"), textVerbatim: r.optString("text_verbatim"), context: r.optString("context"),
            payload: try MemePayload.decode(kind: kind, json: r.optString("payload")),
            suggestedTags: unjson(r.optString("suggested_tags")), userTags: unjson(r.optString("user_tags")),
            addedAt: r.int64("added_at"), convert: r.optInt("convert").map { $0 != 0 }, keepOriginal: r.optInt("keep_original").map { $0 != 0 })
        item.parentID = r.optString("parent_id")
        item.edit = MediaEdit.decode(r.optString("edit"))
        return item
    }

    private static func json(_ a: [String]) -> String {
        String(decoding: try! JSONEncoder().encode(a), as: UTF8.self)
    }
    private static func unjson(_ s: String?) -> [String] {
        guard let s, let d = s.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: d)) ?? []
    }
}
