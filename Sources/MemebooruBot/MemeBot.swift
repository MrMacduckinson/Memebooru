import Foundation
import MemebooruCore

public struct BotConfig: Sendable {
    /// Telegram user ids allowed to use the bot. Everyone else gets nothing (inline) or their own id (chat).
    public var allowedUsers: Set<Int64>
    /// Chat the bot uploads files to, to obtain reusable `file_id`s for inline answers. A private channel
    /// is best; nil = the first allowed user's own chat (uploads are silent and deleted right away).
    public var cacheChat: Int64?
    public var pageSize = 20
    /// New uploads per inline query (keeps the answer inside Telegram's patience); the rest arrive on
    /// the next keystroke once cached.
    public var uploadsPerQuery = 6
    /// Seconds an album waits after its latest message before it's saved (Telegram delivers an album's
    /// messages one by one, normally well within a second). 0 = saved after the batch of updates it came in.
    public var albumWait: TimeInterval = 1.5
    public init(allowedUsers: Set<Int64>, cacheChat: Int64? = nil) { self.allowedUsers = allowedUsers; self.cacheChat = cacheChat }
}

/// A file as Telegram knows it: `fileID` to send it, `uniqueID` to recognise it again, `kind` to answer with it.
public struct TGStoredFile: Sendable, Equatable {
    public var fileID: String
    public var uniqueID: String?
    public var kind: TGMediaKind
}

/// The bot's server-local tables (never synced):
/// `tg_file_cache` sha256 → file_id, `tg_file_ref` file_unique_id → sha256, `tg_usage` inline picks.
public final class FileIDCache: @unchecked Sendable {
    private let db: Database
    public init(db: Database) { self.db = db }

    public func get(_ sha: String) throws -> (fileID: String, kind: TGMediaKind)? {
        try db.first("SELECT file_id, kind FROM tg_file_cache WHERE sha256 = ?", [sha]) { r in
            (r.string(0), TGMediaKind(rawValue: r.string(1)) ?? .document)
        }
    }
    public func put(_ sha: String, fileID: String, kind: TGMediaKind) throws {
        try db.run("INSERT INTO tg_file_cache(sha256, file_id, kind) VALUES (?,?,?) ON CONFLICT(sha256) DO UPDATE SET file_id = excluded.file_id, kind = excluded.kind",
                   [sha, fileID, kind.rawValue])
    }
    public func count() throws -> Int { Int(try db.scalarInt("SELECT count(*) FROM tg_file_cache")) }

    public func remember(uniqueID: String, sha: String) throws {
        try db.run("INSERT INTO tg_file_ref(file_unique_id, sha256) VALUES (?,?) ON CONFLICT(file_unique_id) DO UPDATE SET sha256 = excluded.sha256",
                   [uniqueID, sha])
    }
    public func sha(forUniqueID id: String) throws -> String? {
        try db.scalarString("SELECT sha256 FROM tg_file_ref WHERE file_unique_id = ?", [id])
    }

    public func markUsed(_ meme: MemeID) throws {
        try db.run("INSERT INTO tg_usage(meme_id, uses, last_used) VALUES (?, 1, ?) ON CONFLICT(meme_id) DO UPDATE SET uses = uses + 1, last_used = excluded.last_used",
                   [meme.rawValue, Clock.nowMillis()])
    }
    public func recentlyUsed(limit: Int) throws -> [MemeID] {
        try db.query("SELECT meme_id FROM tg_usage ORDER BY last_used DESC LIMIT ?", [limit]) { MemeID($0.string(0)) }
    }
}

/// The Telegram side of the server: inline search over the collection, saving memes (forward them, send
/// them with tags as the caption, or reply `/add` to one in any chat), and tag editing by reply.
/// Updates are handled one at a time (a personal bot never sees real concurrency).
public final class MemeBot: @unchecked Sendable {
    private let api: any TelegramAPI
    private let collection: Collection
    private let analyzer: MediaAnalyzer?
    /// Where tweets sent as links are fetched from (fxtwitter on the server); nil = links aren't saved.
    private let tweetSource: (any TweetSource)?
    private let http: (any HTTPClient)?
    private let config: BotConfig
    private let cache: FileIDCache
    /// Current pairing code of the sync server, for `/code`.
    private let pairingInfo: @Sendable () -> String?
    public var log: @Sendable (String) -> Void = { print($0) }
    /// The time, for the album wait (tests set it).
    public var now: @Sendable () -> Date = { Date() }

    /// Bot reply message id → meme it talks about, so replying to "Saved" with words tags that meme.
    private var savedReplies: [Int: MemeID] = [:]
    private var savedOrder: [Int] = []

    /// The messages of an album seen so far (one chat, one `media_group_id`).
    struct AlbumKey: Hashable { let chat: Int64; let group: String }
    struct Album {
        var messages: [TGMessage]
        var last: Date
        /// Sent to the bot: saved once complete. Otherwise (an album posted in a group) only remembered
        /// for a while, so that `/add` on one of its messages saves the whole album.
        var autoSave: Bool
    }
    private var albums: [AlbumKey: Album] = [:]
    /// How long an album seen in a group is remembered for `/add`, and how many.
    static let albumMemory: TimeInterval = 600
    static let albumMemoryCount = 100

    public init(api: any TelegramAPI, collection: Collection, analyzer: MediaAnalyzer?, config: BotConfig,
                tweetSource: (any TweetSource)? = nil, http: (any HTTPClient)? = nil,
                pairingInfo: @escaping @Sendable () -> String? = { nil }) {
        self.api = api; self.collection = collection; self.analyzer = analyzer; self.config = config
        self.tweetSource = tweetSource; self.http = http ?? analyzer?.platform.http
        self.cache = FileIDCache(db: collection.db); self.pairingInfo = pairingInfo
    }

    private var uploadChat: Int64? { config.cacheChat ?? config.allowedUsers.sorted().first }
    private func allowed(_ user: TGUser?) -> Bool { user.map { config.allowedUsers.contains($0.id) } ?? false }

    public static let commands: [TGCommand] = [
        TGCommand("help", "How to save and find memes"),
        TGCommand("add", "Reply to a meme: save it, optionally with tags"),
        TGCommand("info", "Reply to a meme: kind, date, tags"),
        TGCommand("tags", "Reply to a meme: replace its tags"),
        TGCommand("addtag", "Reply to a meme: add tags"),
        TGCommand("deltag", "Reply to a meme: remove tags"),
        TGCommand("delete", "Reply to a meme: delete it"),
        TGCommand("split", "Reply to a combined meme: separate memes again"),
        TGCommand("edittag", "Rename a tag everywhere: /edittag old new"),
        TGCommand("stats", "Collection summary"),
        TGCommand("code", "Pairing code for a new device"),
    ]

    // MARK: - Polling loop

    /// Long-polls forever. Network errors back off and retry; a single bad update never stops the loop.
    public func run() async {
        do { try await api.setCommands(Self.commands) } catch { log("telegram: setMyCommands failed: \(Self.describe(error))") }
        var offset: Int64?
        var backoff: UInt64 = 1
        while !Task.isCancelled {
            do {
                // While an album is waiting for the rest of its messages, poll briefly so it's saved on time.
                let timeout = albumDue().map { max(1, Int($0.timeIntervalSince(now()).rounded(.up))) } ?? 50
                let updates = try await api.getUpdates(offset: offset, timeout: min(timeout, 50))
                backoff = 1
                for u in updates {
                    offset = u.updateId + 1
                    await handle(u)
                }
            } catch {
                let wait = (error as? TelegramError)?.retryAfter.map(UInt64.init) ?? backoff
                log("telegram: \(Self.describe(error)) — retrying in \(wait)s")
                try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
                backoff = min(backoff * 2, 60)
            }
            await flushDueAlbums()
        }
        await flushAlbums()     // stopping: what has arrived is saved
    }

    public func handle(_ update: TGUpdate) async {
        do {
            if let q = update.inlineQuery { try await inline(q) }
            else if let m = update.message { try await message(m) }
            else if let m = update.editedMessage { try await edited(m) }
            else if let c = update.chosenInlineResult, allowed(c.from) { try cache.markUsed(MemeID(c.resultId)) }
        } catch {
            log("telegram: update \(update.updateId) failed: \(Self.describe(error))")
        }
    }

    // MARK: - Inline search

    func inline(_ q: TGInlineQuery) async throws {
        guard allowed(q.from) else {
            try await api.answerInlineQuery(id: q.id, results: [], nextOffset: nil, cacheTime: 300, emptyButton: nil); return
        }
        let query = q.query.trimmingCharacters(in: .whitespaces)
        let page = try collection.search.search(query, limit: config.pageSize, after: Self.decodeCursor(q.offset))
        var memes = page.memes
        // Empty query, first page: what you sent last comes first (tgbooru's "last used").
        if query.isEmpty, q.offset.isEmpty {
            let recent = try cache.recentlyUsed(limit: config.pageSize).compactMap { try collection.memes.get($0) }.filter { $0.deletedAt == nil }
            let ids = Set(recent.map(\.id))
            memes = Array((recent + memes.filter { !ids.contains($0.id) }).prefix(config.pageSize))
        }
        var results: [TGInlineResult] = []
        var uploads = 0
        for meme in memes {
            // One file Telegram refuses (too big, bad dimensions…) mustn't sink the whole answer.
            do { if let r = try await result(for: meme, uploads: &uploads) { results.append(r) } }
            catch { log("telegram: inline result \(meme.id.rawValue) failed: \(Self.describe(error))") }
        }
        let nothing = results.isEmpty && q.offset.isEmpty
        try await api.answerInlineQuery(id: q.id, results: results, nextOffset: page.next.map(Self.encodeCursor) ?? "",
                                        cacheTime: 5, emptyButton: nothing ? "Nothing found — send me memes to save" : nil)
    }

    /// Inline answer for one meme, uploading its file once if Telegram doesn't know it yet.
    func result(for meme: Meme, uploads: inout Int) async throws -> TGInlineResult? {
        let id = meme.id.rawValue
        switch meme.kind {
        case .text, .article:
            return Self.article(id: id, text: meme.textVerbatim ?? meme.textExact ?? "")
        case .tweet:
            guard case .tweet(let p) = meme.payload else { return nil }
            // A tweet shown as bare media goes out as that photo / video, with the link.
            let media = try collection.memes.assets(of: meme.id).filter { $0.role == .media }.sorted { $0.order < $1.order }
            if p.showsAsMedia(text: meme.textVerbatim, mediaCount: media.count), let first = media.first,
               let cached = try await fileID(for: first, uploads: &uploads) {
                var r = Self.media(id: id, cached.fileID, cached.kind, title: "@\(p.handle)")
                r.caption = p.url
                return r
            }
            // The tweet as a picture (drawn here when missing or out of date, within the upload budget),
            // with its link as the caption; text + link when it can't be drawn or sent yet.
            if let analyzer,
               let render = try? collection.tweetRender(meme, analyzer: analyzer, render: uploads < config.uploadsPerQuery),
               let cached = try await fileID(for: render, uploads: &uploads) {
                var r = Self.media(id: id, cached.fileID, cached.kind, title: "@\(p.handle)")
                r.caption = p.url
                return r
            }
            return Self.article(id: id, text: [meme.textVerbatim, p.url].compactMap { $0 }.joined(separator: "\n\n"),
                                title: "@\(p.handle)")
        case .image, .gif, .video, .audio:
            guard let asset = try collection.memes.primaryAsset(of: meme.id),
                  let cached = try await fileID(for: asset, uploads: &uploads) else { return nil }
            return Self.media(id: id, cached.fileID, cached.kind, title: asset.originalName ?? meme.kind.rawValue)
        }
    }

    private func fileID(for asset: Asset, uploads: inout Int) async throws -> (fileID: String, kind: TGMediaKind)? {
        if let hit = try cache.get(asset.sha256) { return hit }
        guard uploads < config.uploadsPerQuery, let chat = uploadChat else { return nil }
        let url = collection.media.url(sha256: asset.sha256, ext: asset.ext)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }   // media not synced to the server yet
        uploads += 1
        var file = url
        var kind = Self.uploadKind(ext: asset.ext, bytes: asset.bytes, width: asset.width, height: asset.height)
        // Telegram only shows popular formats: an uncommon file (SVG, HEIC, WebM, MKV, AV1…) is sent as a
        // popular conversion made just for the upload — the collection keeps what it has.
        var tmp: URL?
        let memeKind = MediaType.detect(ext: asset.ext)?.kind ?? .image
        if asset.compatibility(kind: memeKind) == .uncommon, let analyzer,
           let target = FormatPolicy.popularTarget(kind: memeKind, ext: asset.ext, codecs: asset.codecs),
           let converted = try? analyzer.converter.convertToTemporary(url, kind: memeKind, to: target, name: String(asset.sha256.prefix(12))) {
            tmp = converted.deletingLastPathComponent(); file = converted
            kind = Self.uploadKind(ext: target.ext, bytes: (try? converted.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0,
                                   width: asset.width, height: asset.height)
        }
        defer { if let tmp { try? FileManager.default.removeItem(at: tmp) } }
        let sent = try await api.sendMedia(kind, chatID: chat, file: file, silent: true)
        try? await api.deleteMessage(chatID: chat, messageID: sent.messageId)   // file_id outlives the message
        guard let got = Self.fileRef(in: sent) else { return nil }
        try cache.put(asset.sha256, fileID: got.fileID, kind: got.kind)
        if let u = got.uniqueID { try cache.remember(uniqueID: u, sha: asset.sha256) }
        return (got.fileID, got.kind)
    }

    /// Upload everything not yet known to Telegram, gently. Returns how many files were uploaded.
    @discardableResult
    public func warmCache(limit: Int = .max) async -> Int {
        var done = 0
        var cursor: MemeCursor?
        repeat {
            guard let page = try? collection.search.search("", limit: 100, after: cursor) else { break }
            for meme in page.memes where done < limit {
                var budget = 0
                let before = (try? cache.count()) ?? 0
                _ = try? await result(for: meme, uploads: &budget)
                if ((try? cache.count()) ?? 0) > before { done += 1; try? await Task.sleep(nanoseconds: 1_100_000_000) }
            }
            cursor = page.next
        } while cursor != nil && done < limit
        return done
    }

    // MARK: - Chat

    static let help = """
        Save a meme:
        • forward it to me — its caption becomes the meme's text;
        • send it yourself with tags as the caption (edit the caption later to change them);
        • send me an x.com / twitter.com link — the tweet is saved (words next to the link become its tags);
        • in any chat, reply to it with /add and optional tags.
        Several photos sent as one album are saved as one combined meme; reply "split" to my answer to keep them separate.
        Reply to my "Saved" message with words to add tags.

        Find a meme: type my @username and tags in any chat. With no tags you get the ones you sent last.

        Reply to a meme with /info, /tags a b c, /addtag, /deltag, /delete or /split.
        /edittag old new — rename a tag everywhere
        /stats — collection summary
        /code — pairing code for syncing a new device with this server
        """

    func message(_ m: TGMessage) async throws {
        // An album posted in a group is remembered (whoever posted it), so `/add` to one of its photos saves all of it.
        if m.mediaGroupId != nil, !Self.isPrivate(m.chat), Self.fileRef(in: m) != nil { collect(m, autoSave: false) }
        guard allowed(m.from) else {
            // Tell a stranger their id (private chat only): that is how the owner learns what to allow.
            if m.chat.type == "private" {
                _ = try await api.sendMessage(chatID: m.chat.id, text: "This bot is private. Your Telegram id is \(m.from?.id ?? 0).", replyTo: nil)
            }
            return
        }
        let text = (m.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("/") { try await command(text, in: m); return }
        guard Self.isPrivate(m.chat) else { return }   // in groups: commands only
        if let reply = m.replyToMessage, let meme = savedReplies[reply.messageId], !text.isEmpty, m.forwardOrigin == nil {
            if text.lowercased() == "split", try isCombined(meme) { try await split(meme, in: m); return }
            try await addTags(Self.words(text), to: meme, in: m); return
        }
        if m.mediaGroupId != nil, Self.fileRef(in: m) != nil {
            // One message of an album: saved with the rest of it once they've all arrived (see `flushDueAlbums`).
            collect(m, autoSave: true); return
        }
        if Self.fileRef(in: m) != nil || m.sticker != nil || m.videoNote != nil {
            // Forwarded: the caption is the meme's own text. Sent by you: the caption is its tags.
            let own = m.forwardOrigin == nil
            try await saveMedia(from: m, answer: m, tags: own ? Self.words(m.caption ?? "") : [], keepCaption: !own); return
        }
        let tweets = Self.tweetIDs(in: text)
        if !tweets.isEmpty {
            // A tweet link: the tweet itself is saved. Your own words around the link are its tags.
            try await saveTweets(tweets, tags: m.forwardOrigin == nil ? Self.words(Self.withoutLinks(text)) : [], answer: m); return
        }
        if !text.isEmpty {
            if m.forwardOrigin != nil { try await saveText(text, from: m, answer: m, tags: []) }
            else { try await say("Forward a meme to save it, or search inline: type my @username and tags in any chat.", in: m) }
        }
    }

    /// Editing the caption of a meme you sent re-tags it.
    func edited(_ m: TGMessage) async throws {
        guard allowed(m.from), m.forwardOrigin == nil, let caption = m.caption,
              let meme = try knownMeme(in: m) else { return }
        try replaceTags(Self.words(caption), of: meme)
        try await say("Tags updated: \(try tagLine(meme))", in: m)
    }

    private func command(_ text: String, in m: TGMessage) async throws {
        let parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let cmd = parts.first.map { String($0.dropFirst().split(separator: "@").first ?? "") }?.lowercased() ?? ""
        let args = Array(parts.dropFirst())
        let target = m.replyToMessage

        switch cmd {
        case "start", "help": try await say(Self.help, in: m, reply: false)
        case "code":
            try await say(pairingInfo().map { "Pairing code: \($0)\nOn the new device: Sync → By address, enter the server address and this code. The code changes after each pairing." } ?? "Sync server is not running.", in: m, reply: false)
        case "stats": try await say(try stats(), in: m, reply: false)
        case "edittag":
            guard args.count == 2 else { try await say("Usage: /edittag old new", in: m); return }
            try await say(try renameTag(args[0], to: args[1]), in: m)
        case "add":
            guard let target else { try await say("Reply to a meme with /add (and optional tags).", in: m); return }
            if let meme = try knownMeme(in: target) {
                try await addTags(args, to: meme, in: m, prefix: "Already saved.")
            } else if let group = target.mediaGroupId, Self.fileRef(in: target) != nil {
                // One photo of an album: the whole album, as far as I've seen it (all of it when it was sent
                // to me or I can read the group; otherwise just this one).
                let key = AlbumKey(chat: target.chat.id, group: group)
                var messages = albums.removeValue(forKey: key)?.messages ?? []
                if !messages.contains(where: { $0.messageId == target.messageId }) { messages.append(target) }
                try await saveAlbum(messages, add: (m, args))
            } else if Self.fileRef(in: target) != nil || target.sticker != nil || target.videoNote != nil {
                try await saveMedia(from: target, answer: m, tags: args, keepCaption: true)
            } else if let t = target.text, !Self.tweetIDs(in: t).isEmpty {
                try await saveTweets(Self.tweetIDs(in: t), tags: args, answer: m)
            } else if let t = target.text, !t.isEmpty {
                try await saveText(t, from: target, answer: m, tags: args)
            } else {
                try await say("There is nothing I can save in that message.", in: m)
            }
        case "split":
            guard let target else { try await say("Reply /split to a combined meme (or to my answer when I saved it).", in: m); return }
            guard let meme = try knownMeme(in: target), try isCombined(meme) else {
                try await say("That isn't a combined meme.", in: m); return
            }
            try await split(meme, in: m)
        case "info", "tags", "addtag", "deltag", "delete":
            guard let target else { try await say("Reply to a meme with /\(cmd).", in: m); return }
            guard let meme = try knownMeme(in: target) else { try await say("That meme isn't in the collection. Reply /add to save it.", in: m); return }
            switch cmd {
            case "info": try await say(try info(meme), in: m)
            case "tags":
                guard !args.isEmpty else { try await say("Usage: reply /tags tag1 tag2 …", in: m); return }
                try replaceTags(args, of: meme)
                try await say("Tags: \(try tagLine(meme))", in: m, remember: meme)
            case "addtag":
                guard !args.isEmpty else { try await say("Usage: reply /addtag tag1 tag2 …", in: m); return }
                try await addTags(args, to: meme, in: m)
            case "deltag":
                guard !args.isEmpty else { try await say("Usage: reply /deltag tag1 tag2 …", in: m); return }
                for a in args { try? collection.memes.removeTag(meme, a) }
                try await say("Tags: \(try tagLine(meme))", in: m, remember: meme)
            default:
                try collection.deleteMemes([meme], label: "Deleted via Telegram")
                try await say("Deleted. It can be restored from History in the app.", in: m)
            }
        default: try await say("Unknown command. /help", in: m)
        }
    }

    // MARK: - Tags

    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init).filter { !$0.isEmpty && !$0.hasPrefix("/") }
    }

    private func tagLine(_ meme: MemeID) throws -> String {
        let t = try collection.memes.tags(of: meme)
        return t.isEmpty ? "(none)" : t.map(\.name).joined(separator: " ")
    }

    private func addTags(_ words: [String], to meme: MemeID, in m: TGMessage, prefix: String? = nil) async throws {
        for w in words { _ = try? collection.memes.addTag(meme, w) }
        let head = prefix.map { $0 + " " } ?? ""
        try await say(head + "Tags: \(try tagLine(meme))", in: m, remember: meme)
    }

    /// Replaces the general tags; meta tags (kind, year, source) stay.
    private func replaceTags(_ words: [String], of meme: MemeID) throws {
        let wanted = Set(try words.map { try collection.tags.resolve($0)?.name ?? TagName.normalize($0) })
        for t in try collection.memes.tags(of: meme) where t.kind == .normal && !wanted.contains(t.name) {
            try collection.memes.removeTag(meme, t.name)
        }
        for w in words { _ = try? collection.memes.addTag(meme, w) }
    }

    private func renameTag(_ old: String, to new: String) throws -> String {
        guard let tag = try collection.tags.resolve(old) else { return "No tag \(old)." }
        if let existing = try collection.tags.resolve(new), existing.id != tag.id {
            try collection.tags.merge(tag, into: existing)
            return "Merged \(tag.name) into \(existing.name)."
        }
        let renamed = try collection.tags.rename(tag, to: new)
        return "Renamed \(tag.name) → \(renamed.name)."
    }

    private func info(_ meme: MemeID) throws -> String {
        guard let m = try collection.memes.get(meme) else { return "Gone." }
        let date = Date(timeIntervalSince1970: TimeInterval(m.createdAt) / 1000).formatted(date: .abbreviated, time: .shortened)
        var lines = ["\(m.kind.rawValue.capitalized), saved \(date)", "Tags: \(try tagLine(meme))"]
        if let c = m.context, !c.isEmpty { lines.append("Context: \(c)") }
        if let t = m.textVerbatim ?? m.textExact, !t.isEmpty, m.kind != .text { lines.append("Text: \(t.prefix(300))") }
        return lines.joined(separator: "\n")
    }

    private func stats() throws -> String {
        let db = collection.db
        let byKind = try db.query("SELECT kind, count(*) FROM meme WHERE deleted_at IS NULL GROUP BY kind ORDER BY count(*) DESC", []) {
            "\($0.string(0)) \($0.int(1))"
        }
        let total = try collection.memes.count()
        let tagCount = try db.scalarInt("SELECT count(DISTINCT mt.tag_id) FROM meme_tag mt JOIN meme m ON m.id = mt.meme_id WHERE m.deleted_at IS NULL")
        let links = try db.scalarInt("SELECT count(*) FROM meme_tag mt JOIN tag t ON t.id = mt.tag_id JOIN meme m ON m.id = mt.meme_id WHERE m.deleted_at IS NULL AND t.kind = 'normal'")
        let top = try db.query("""
            SELECT t.name, count(*) AS n FROM meme_tag mt JOIN tag t ON t.id = mt.tag_id JOIN meme m ON m.id = mt.meme_id
            WHERE m.deleted_at IS NULL AND t.kind = 'normal' GROUP BY t.id ORDER BY n DESC, t.name LIMIT 10
            """, []) { "\($0.string(0)) \($0.int(1))" }
        let first = try db.first("SELECT min(created_at) FROM meme WHERE deleted_at IS NULL", []) { $0.optInt64(0) } ?? nil
        var lines = ["\(total) posts: " + (byKind.isEmpty ? "none" : byKind.joined(separator: ", ")),
                     "\(tagCount) tags, \(total == 0 ? "0" : String(format: "%.1f", Double(links) / Double(total))) own tags per post"]
        if let first { lines.append("Since \(Date(timeIntervalSince1970: TimeInterval(first) / 1000).formatted(date: .abbreviated, time: .omitted))") }
        if !top.isEmpty { lines.append("Top tags: " + top.joined(separator: ", ")) }
        lines.append("\(try cache.count()) files known to Telegram")
        return lines.joined(separator: "\n")
    }

    // MARK: - Saving

    /// The meme a Telegram message shows, if the collection has it — by the file's unique id, by the
    /// text's hash, or because it's one of our own "Saved" replies.
    private func knownMeme(in m: TGMessage) throws -> MemeID? {
        if let meme = savedReplies[m.messageId] { return meme }
        if let u = Self.fileRef(in: m)?.uniqueID ?? m.sticker?.fileUniqueId ?? m.videoNote?.fileUniqueId,
           let sha = try cache.sha(forUniqueID: u), let id = try collection.memes.memes(withSHA256: sha).first { return id }
        if Self.fileRef(in: m) == nil, let t = m.text, !t.isEmpty,
           let id = try collection.memes.memes(withSHA256: MediaStore.sha256(of: Data(t.utf8))).first { return id }
        return nil
    }

    /// Download the file in `m` and save it. `answer` is the message the bot replies to (the /add command,
    /// or `m` itself when it was sent to the bot).
    /// `caption`: the words that go with it (the album's, for a message of an album).
    private func saveMedia(from m: TGMessage, answer: TGMessage, tags: [String], keepCaption: Bool, caption: String? = nil) async throws {
        let staging = StagingArea(collection: collection, analyzer: analyzer)
        guard let s = try await stage(m, in: staging, answer: answer, text: keepCaption ? caption ?? m.caption : nil,
                                      context: Self.context(of: m)) else { return }
        try await finishSave(s.item, staging: staging, file: s.file, tags: tags, answer: answer)
    }

    /// Downloads the file in `m` into staging. nil (after telling `answer` why) when it can't be had.
    private func stage(_ m: TGMessage, in staging: StagingArea, answer: TGMessage, text: String?, context: String?) async throws -> (item: StagedItem, file: TGStoredFile)? {
        let extra: TGStoredFile? =
            m.sticker.map { TGStoredFile(fileID: $0.fileId, uniqueID: $0.fileUniqueId, kind: .document) }
            ?? m.videoNote.map { TGStoredFile(fileID: $0.fileId, uniqueID: $0.fileUniqueId, kind: .video) }
        guard let ref = Self.fileRef(in: m) ?? extra else { return nil }
        let file = try await api.getFile(fileID: ref.fileID)
        guard let path = file.filePath else {
            try await say("Telegram won't give me that file (bots can only download files up to 20 MB).", in: answer); return nil
        }
        let data = try await api.download(filePath: path)
        var ext = (path as NSString).pathExtension.lowercased()
        if ext.isEmpty || MediaType.detect(ext: ext) == nil {
            ext = [m.document?.fileName, m.audio?.fileName].compactMap { $0.map { ($0 as NSString).pathExtension.lowercased() } }.first { MediaType.detect(ext: $0) != nil }
                ?? (ref.kind == .photo ? "jpg" : ref.kind == .voice ? "ogg" : "mp4")
        }
        guard MediaType.detect(ext: ext) != nil else { try await say("I can't store .\(ext) files.", in: answer); return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Photos have no file name on Telegram; name them after where they came from.
        let fallback = "telegram \(ISO8601DateFormatter.string(from: Self.date(of: m), timeZone: .current, formatOptions: [.withFullDate])) \(m.messageId).\(ext)"
        let tmp = dir.appendingPathComponent(fallback)
        try data.write(to: tmp)

        let name = m.document?.fileName ?? m.video?.fileName ?? m.audio?.fileName ?? m.animation?.fileName
        let item = try staging.add(file: tmp, source: "telegram", originalName: name, date: Self.date(of: m),
                                   textVerbatim: text, context: context,
                                   extraTags: ["telegram_message"] + (ref.kind == .animation ? ["animation"] : []))
        return (item, ref)
    }

    // MARK: - Albums

    /// Keeps one message of an album until the album is saved (or, from a group, for a while).
    private func collect(_ m: TGMessage, autoSave: Bool) {
        guard let group = m.mediaGroupId else { return }
        let key = AlbumKey(chat: m.chat.id, group: group)
        var album = albums[key] ?? Album(messages: [], last: now(), autoSave: autoSave)
        if let i = album.messages.firstIndex(where: { $0.messageId == m.messageId }) { album.messages[i] = m }
        else { album.messages.append(m) }
        album.last = now()
        album.autoSave = album.autoSave || autoSave
        albums[key] = album
        // Albums seen in groups are forgotten after a while.
        let old = now().addingTimeInterval(-Self.albumMemory)
        albums = albums.filter { $0.value.autoSave || $0.value.last > old }
        let remembered = albums.filter { !$0.value.autoSave }.sorted { $0.value.last < $1.value.last }
        for (k, _) in remembered.prefix(max(0, remembered.count - Self.albumMemoryCount)) { albums[k] = nil }
    }

    /// When the next album sent to the bot is due to be saved; nil = none is waiting.
    func albumDue() -> Date? {
        albums.values.filter(\.autoSave).map { $0.last.addingTimeInterval(config.albumWait) }.min()
    }

    /// Saves every album sent to the bot whose last message came `albumWait` ago or longer. An album
    /// message arriving after its album was saved starts a new album (saved as a single photo, if alone).
    public func flushDueAlbums() async {
        await flush { [now = now(), wait = config.albumWait] in now.timeIntervalSince($0.last) >= wait }
    }

    /// Saves every album sent to the bot now, complete or not.
    public func flushAlbums() async { await flush { _ in true } }

    private func flush(_ due: (Album) -> Bool) async {
        let ready = albums.filter { $0.value.autoSave && due($0.value) }
            .sorted { ($0.value.messages.map(\.messageId).min() ?? 0) < ($1.value.messages.map(\.messageId).min() ?? 0) }
        for (key, album) in ready {
            albums[key] = nil
            do { try await saveAlbum(album.messages, add: nil) }
            catch { log("telegram: album \(key.group) failed: \(Self.describe(error))") }
        }
    }

    /// Saves an album: its photos (two or more) as one combined meme, in message order; its videos and
    /// files (and a lone photo) each on their own, as if sent singly. The album's caption goes with all of
    /// it: tags when you sent it to me yourself, the meme's text when it's forwarded or from a group.
    /// `add`: the `/add` command that asked for it, with its tags (and it gets the answers).
    private func saveAlbum(_ messages: [TGMessage], add: (command: TGMessage, tags: [String])?) async throws {
        let messages = messages.sorted { $0.messageId < $1.messageId }
        guard let first = messages.first else { return }
        var seen = Set<String>()
        let captions = messages.compactMap { $0.caption?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        let caption = captions.isEmpty ? nil : captions.joined(separator: "\n")
        let captionIsTags = first.forwardOrigin == nil && Self.isPrivate(first.chat)
        let tags = (captionIsTags ? Self.words(caption ?? "") : []) + (add?.tags ?? [])
        let text = captionIsTags ? nil : caption

        let photos = messages.filter { $0.photo != nil }
        let combine = photos.count >= 2 && analyzer != nil
        var combined = false
        for m in messages {
            if combine, m.photo != nil {
                if !combined { combined = true; try await saveCombined(photos, answer: add?.command ?? m, tags: tags, text: text) }
                continue
            }
            try await saveMedia(from: m, answer: add?.command ?? m, tags: tags, keepCaption: !captionIsTags, caption: caption)
        }
    }

    /// Photos of one album as one combined meme. Already saved (the same pictures, all inside one combined
    /// meme, or the same combined picture): only the tags are added.
    private func saveCombined(_ photos: [TGMessage], answer: TGMessage, tags: [String], text: String?) async throws {
        let staging = StagingArea(collection: collection, analyzer: analyzer)
        var staged: [(item: StagedItem, file: TGStoredFile)] = []
        do {
            for p in photos {
                if let s = try await stage(p, in: staging, answer: answer, text: nil, context: nil) { staged.append(s) }
            }
        } catch {
            for s in staged { try? staging.discard(s.item.id) }
            throw error
        }
        for s in staged {
            // Telegram's ids of the pictures: replies to them find the meme; split parts answer inline with no upload.
            if let u = s.file.uniqueID { try cache.remember(uniqueID: u, sha: s.item.sha256) }
            if s.file.kind != .document { try? cache.put(s.item.sha256, fileID: s.file.fileID, kind: s.file.kind) }
        }
        let context = Self.context(of: photos[0])
        func single(_ s: (item: StagedItem, file: TGStoredFile)) async throws {
            var item = s.item
            item.textVerbatim = text; item.context = context
            try staging.update(item)
            try await finishSave(item, staging: staging, file: s.file, tags: tags, answer: answer)
        }
        guard staged.count >= 2 else {
            if let s = staged.first { try await single(s) }
            return
        }
        if let existing = try combinedMeme(containing: staged.map(\.item.sha256)) {
            for s in staged { try staging.discard(s.item.id) }
            try await addTags(tags, to: existing, in: answer, prefix: "Already in the collection.")
            return
        }
        let item: StagedItem
        do {
            // Committed straight away, so not an undo step of its own (no other save here is one either).
            var c = try staging.combine(staged.map(\.item.id), undoable: false)
            c.textVerbatim = text; c.context = context
            try staging.update(c)
            item = c
        } catch {
            // Can't be drawn (a picture the server can't read…): each one is saved on its own instead.
            log("telegram: couldn't combine \(staged.count) photos (\(Self.describe(error))) — saving them separately")
            for s in staged { try await single(s) }
            return
        }
        try await finishSave(item, staging: staging, file: nil, tags: tags, answer: answer, pictures: staged.count)
    }

    /// A live combined meme that already holds every one of these pictures.
    private func combinedMeme(containing shas: [String]) throws -> MemeID? {
        guard let first = shas.first else { return nil }
        for id in try collection.memes.memes(withSHA256: first) where try isCombined(id) {
            if Set(try collection.parts(of: id).map(\.sha256)).isSuperset(of: shas) { return id }
        }
        return nil
    }

    private func isCombined(_ meme: MemeID) throws -> Bool {
        guard let m = try collection.memes.get(meme) else { return false }
        return m.deletedAt == nil && m.payload.composite != nil
    }

    private func split(_ meme: MemeID, in m: TGMessage) async throws {
        let ids = try collection.splitComposite(meme, analyzer: analyzer)
        try await say("Split into \(ids.count) memes. Undo it from History in the app.", in: m)
        log("telegram: split \(meme) into \(ids.count)")
    }

    private func saveText(_ text: String, from m: TGMessage, answer: TGMessage, tags: [String]) async throws {
        let staging = StagingArea(collection: collection, analyzer: analyzer)
        let item = try staging.add(text: text, source: "telegram", date: Self.date(of: m), context: Self.context(of: m),
                                   extraTags: ["telegram_message"])
        try await finishSave(item, staging: staging, file: nil, tags: tags, answer: answer)
    }

    /// Tweet ids in x.com / twitter.com links (also the fx/vx/fixup mirrors), in order, without repeats.
    static func tweetIDs(in text: String) -> [String] {
        // Not inside another host name ("linux.com"); `/i/web/status/` is x.com's own share form.
        let pattern = #"(?<![A-Za-z0-9_-])(?:https?://)?(?:www\.|mobile\.)?(?:x|twitter|fxtwitter|vxtwitter|fixupx|fixvx)\.com/(?:i/web/|[A-Za-z0-9_]+/)status(?:es)?/(\d+)"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        var seen = Set<String>()
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let r = Range(match.range(at: 1), in: text) else { return nil }
            let id = String(text[r])
            return seen.insert(id).inserted ? id : nil
        }
    }

    static func withoutLinks(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).filter { !$0.contains("/") || !$0.contains(".") }.joined(separator: " ")
    }

    /// Saves each tweet (with its media, avatar and the tweet it quotes), draws its picture for inline
    /// answers, and says what it got. Tweets already saved just get the tags.
    private func saveTweets(_ ids: [String], tags: [String], answer: TGMessage) async throws {
        guard let source = tweetSource, let http else {
            try await say("Saving tweets by link isn't set up on this server.", in: answer); return
        }
        let importer = TweetImporter(staging: StagingArea(collection: collection, analyzer: analyzer), source: source, http: http, archive: false)
        for id in ids {
            if let existing = try collection.memes.memeForTweet(id) {
                try await addTags(tags, to: existing, in: answer, prefix: "Already in the collection."); continue
            }
            do {
                let tweet = try await source.fetch(tweetID: id)
                let meme = try importer.commitPrepared(try await importer.prepare(tweet), into: collection, extraTags: tags)
                // Its chain (what it replies to and quotes) belongs to the meme; a failure only loses that part.
                _ = try? await TweetThreadLoader(collection: collection, importer: importer).loadChain(of: meme.id)
                if let analyzer { _ = try? collection.tweetRender(meme, analyzer: analyzer) }
                let media = tweet.media.isEmpty ? "" : ", \(tweet.media.count) media"
                try await say("Saved tweet by @\(tweet.handle)\(media): \(try tagLine(meme.id))\nReply with words to add tags.",
                              in: answer, remember: meme.id)
                log("telegram: saved tweet \(id) as \(meme.id)")
            } catch {
                try await say("Couldn't get tweet \(id): \(Self.describe(error))", in: answer)
            }
        }
    }

    /// `pictures`: how many photos `item` combines (nil = not a combined meme).
    private func finishSave(_ item: StagedItem, staging: StagingArea, file: TGStoredFile?, tags: [String], answer: TGMessage,
                            pictures: Int? = nil) async throws {
        if let u = file?.uniqueID { try cache.remember(uniqueID: u, sha: item.sha256) }
        if let existing = try collection.memes.memes(withSHA256: item.sha256).first {
            try staging.discard(item.id)
            try await addTags(tags, to: existing, in: answer, prefix: "Already in the collection.")
            return
        }
        // Uncommon formats (e.g. WebM video stickers) are stored converted, with the original kept —
        // there's nobody to ask in a chat, so nothing is thrown away.
        let meme = try staging.commit(item.id, keepOriginal: item.compatibility == .uncommon ? true : nil)
        for t in tags { _ = try? collection.memes.addTag(meme.id, t) }
        // The file_id Telegram gave us for the incoming file is reusable for inline answers — no upload needed.
        // (Documents are skipped: a picture sent "as file" answers better as a photo, uploaded on demand.)
        if let file, file.kind != .document { try? cache.put(item.sha256, fileID: file.fileID, kind: file.kind) }
        if let pictures {
            try await say("Saved \(pictures) pictures combined into one meme: \(try tagLine(meme.id))\nReply with words to add tags, or \"split\" to keep them as separate memes.",
                          in: answer, remember: meme.id)
            log("telegram: saved \(pictures) pictures combined as \(meme.id)")
            return
        }
        try await say("Saved (\(meme.kind.rawValue)): \(try tagLine(meme.id))\nReply with words to add tags.", in: answer, remember: meme.id)
        log("telegram: saved \(meme.kind.rawValue) \(meme.id)")
    }

    private func say(_ text: String, in m: TGMessage, reply: Bool = true, remember meme: MemeID? = nil) async throws {
        let sent = try await api.sendMessage(chatID: m.chat.id, text: text, replyTo: reply ? m.messageId : nil)
        if let meme { remember(sent.messageId, meme) }
    }

    private func remember(_ messageID: Int, _ meme: MemeID) {
        savedReplies[messageID] = meme
        savedOrder.append(messageID)
        if savedOrder.count > 500 { savedReplies[savedOrder.removeFirst()] = nil }
    }

    // MARK: - Helpers

    /// One line per error in the log, not a dump of NSError's userInfo.
    static func describe(_ error: Error) -> String {
        if let t = error as? TelegramError { return t.description }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain ? "network: \(ns.localizedDescription)" : "\(error)"
    }

    /// Telegram takes a photo only up to 10 MB, width + height ≤ 10 000 and 1:20 at most; a larger
    /// picture (several screenshots combined, say) goes as a file instead.
    static func uploadKind(ext: String, bytes: Int64, width: Int? = nil, height: Int? = nil) -> TGMediaKind {
        switch ext.lowercased() {
        case "jpg", "jpeg", "png", "webp":
            let w = width ?? 0, h = height ?? 0
            let fits = w + h <= 10_000 && (w == 0 || h == 0 || max(w, h) <= 20 * min(w, h))
            return bytes <= 10_000_000 && fits ? .photo : .document
        case "gif": return .animation
        case "mp4", "mov", "m4v": return .video
        case "mp3", "m4a", "aac", "flac", "wav": return .audio
        case "ogg", "oga", "opus": return .voice
        default: return .document
        }
    }

    /// The file Telegram stored for a message we sent or received, and what kind it is.
    static func fileRef(in m: TGMessage) -> TGStoredFile? {
        func f(_ r: TGFileRef, _ k: TGMediaKind) -> TGStoredFile { TGStoredFile(fileID: r.fileId, uniqueID: r.fileUniqueId, kind: k) }
        if let p = m.photo?.max(by: { ($0.width ?? 0) * ($0.height ?? 0) < ($1.width ?? 0) * ($1.height ?? 0) }) { return f(p, .photo) }
        if let a = m.animation { return f(a, .animation) }
        if let v = m.video { return f(v, .video) }
        if let a = m.audio { return f(a, .audio) }
        if let v = m.voice { return f(v, .voice) }
        if let d = m.document { return f(d, .document) }
        return nil
    }

    static func media(id: String, _ fileID: String, _ kind: TGMediaKind, title: String) -> TGInlineResult {
        switch kind {
        case .photo: var r = TGInlineResult(type: "photo", id: id); r.photoFileId = fileID; return r
        case .animation: var r = TGInlineResult(type: "gif", id: id); r.gifFileId = fileID; return r
        case .video: var r = TGInlineResult(type: "video", id: id); r.videoFileId = fileID; r.title = title; return r
        case .audio: var r = TGInlineResult(type: "audio", id: id); r.audioFileId = fileID; return r
        case .voice: var r = TGInlineResult(type: "voice", id: id); r.voiceFileId = fileID; r.title = title; return r
        case .document: var r = TGInlineResult(type: "document", id: id); r.documentFileId = fileID; r.title = title; return r
        }
    }

    static func article(id: String, text: String, title: String? = nil) -> TGInlineResult? {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        let lines = body.split(whereSeparator: \.isNewline).map(String.init)
        var r = TGInlineResult(type: "article", id: id)
        r.title = String((title ?? lines[0]).prefix(64))
        let rest = lines.dropFirst(title == nil ? 1 : 0).joined(separator: " ")
        r.description = rest.isEmpty ? nil : String(rest.prefix(120))
        r.inputMessageContent = .init(messageText: String(body.prefix(4096)))
        return r
    }

    static func encodeCursor(_ c: MemeCursor) -> String { "\(c.createdAt)_\(c.id.rawValue)" }
    static func decodeCursor(_ s: String) -> MemeCursor? {
        guard let us = s.firstIndex(of: "_"), let t = Int64(s[..<us]) else { return nil }
        return MemeCursor(createdAt: t, id: MemeID(String(s[s.index(after: us)...])))
    }

    /// A chat with one person (the bot's own chat with them). Updates without a chat type are taken as private.
    static func isPrivate(_ chat: TGChat) -> Bool { chat.type == "private" || chat.type == nil }

    static func date(of m: TGMessage) -> Date {
        Date(timeIntervalSince1970: TimeInterval(m.forwardOrigin?.date ?? m.date))
    }

    /// "forwarded from Channel @name" / "from Group" — kept as the meme's context.
    static func context(of m: TGMessage) -> String? {
        guard let o = m.forwardOrigin else {
            if m.chat.type == "group" || m.chat.type == "supergroup", let title = m.chat.title {
                let who = m.from.map { [$0.firstName, $0.username.map { "@\($0)" }].compactMap { $0 }.joined(separator: " ") }
                return "posted in \(title)" + (who.map { $0.isEmpty ? "" : " by \($0)" } ?? "")
            }
            return nil
        }
        let who: String? = switch o.type {
        case "user": [o.senderUser?.firstName, o.senderUser?.username.map { "@\($0)" }].compactMap { $0 }.joined(separator: " ")
        case "hidden_user": o.senderUserName
        default: [o.chat?.title, o.chat?.username.map { "@\($0)" }].compactMap { $0 }.joined(separator: " ")
        }
        guard let who, !who.isEmpty else { return "forwarded from Telegram" }
        return "forwarded from \(who)"
    }
}
