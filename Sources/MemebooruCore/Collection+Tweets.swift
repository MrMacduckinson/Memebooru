import Foundation

extension Collection {
    /// The tag on tweets kept only as part of another tweet's chain (what it replies to or quotes).
    /// They're shown inside that tweet, not as posts: searches leave them out unless asked for
    /// (`chain`, `thread` or `quoted` in the query).
    public static let chainTag = "chain"

    /// Links tweets to the tweets they reply to and quote, by tweet id, whichever came first —
    /// for `ids` (both directions), or every tweet when nil. Returns how many links were added.
    @discardableResult
    public func linkTweets(_ ids: Set<MemeID>? = nil) throws -> Int {
        let rows = try db.query("SELECT id, payload FROM meme WHERE kind = 'tweet' AND deleted_at IS NULL", []) {
            (MemeID($0.string(0)), $0.optString(1))
        }
        var byTweet: [String: MemeID] = [:]
        var payloads: [MemeID: TweetPayload] = [:]
        for (id, json) in rows {
            guard case .tweet(let p)? = try? MemePayload.decode(kind: .tweet, json: json) else { continue }
            byTweet[p.tweetID] = id; payloads[id] = p
        }
        let existing = Set(try db.query("SELECT from_id, to_id, kind FROM relation WHERE deleted_at IS NULL", []) {
            "\($0.string(0))|\($0.string(1))|\($0.string(2))"
        })
        var added = 0
        func link(_ from: MemeID, _ to: MemeID?, _ kind: Relation.Kind) throws {
            guard let to, to != from, !existing.contains("\(from.rawValue)|\(to.rawValue)|\(kind.rawValue)") else { return }
            try memes.addRelation(Relation(from: from, to: to, kind: kind)); added += 1
        }
        try db.transaction {
            for (id, p) in payloads {
                // Only pairs that touch `ids` (when given): a tweet's own links and links pointing at it.
                let parent = p.replyToTweetID.flatMap { byTweet[$0] }, quoted = p.quotedTweetID.flatMap { byTweet[$0] }
                if let ids, !ids.contains(id), !(parent.map(ids.contains) ?? false), !(quoted.map(ids.contains) ?? false) { continue }
                try link(id, parent, .replyTo)
                try link(id, quoted, .quote)
            }
        }
        return added
    }
}

extension Collection {
    /// Puts tweet memes back into staging for review: files are copied from the collection (nothing
    /// is downloaded again), the text is re-read from the saved tweet JSON (current parsing rules),
    /// tags carry over (meta ones as suggested, the rest as the user's), then the memes are deleted
    /// from the collection as one undo step. Returns the staged items.
    @discardableResult
    public func restageTweets(_ ids: [MemeID], into area: StagingArea, onProgress: ((Int) -> Void)? = nil) throws -> [StagedItem] {
        var staged: [StagedItem] = []
        var moved: [MemeID] = []
        for id in ids {
            guard let meme = try memes.get(id), meme.kind == .tweet, meme.deletedAt == nil,
                  case .tweet(var payload) = meme.payload else { continue }
            let assets = try memes.assets(of: id)
            guard let primary = assets.first(where: { $0.role == .primary }) else { continue }
            let json = media.url(sha256: primary.sha256, ext: primary.ext)
            let parsed = (try? Data(contentsOf: json)).flatMap(FetchedTweet.parse(raw:))
            if let parsed { payload.animatedMedia = parsed.animatedMedia }
            let extras = assets.filter { $0.role == .media || $0.role == .avatar }
                .map { StagedExtra(role: $0.role, order: $0.order, url: media.url(sha256: $0.sha256, ext: $0.ext)) }
                .filter { FileManager.default.fileExists(atPath: $0.url.path) }
            let tags = try memes.tags(of: id)
            var item = try area.add(file: json, source: "x:\(payload.handle)", originalName: primary.originalName, kind: .tweet,
                                    date: Date(timeIntervalSince1970: Double(meme.createdAt) / 1000),
                                    textExact: meme.textExact, textVerbatim: parsed.map { $0.text.isEmpty ? nil : $0.text } ?? meme.textVerbatim,
                                    context: meme.context, payload: .tweet(payload),
                                    extraTags: tags.filter { $0.kind == .meta }.map(\.name), extras: extras)
            let own = tags.filter { $0.kind != .meta }.map(\.name)
            if !own.isEmpty { item.userTags = own; try area.update(item) }
            staged.append(item); moved.append(id)
            onProgress?(staged.count)
        }
        if !moved.isEmpty {
            try deleteMemes(moved, label: "Moved \(moved.count) tweets back to staging")
            try wayback.purgeDeleted()       // archived again when committed
        }
        return staged
    }
}

extension StagingArea {
    /// Fetches and stages the chains of staged tweets (what they reply to, up the thread, and quote),
    /// skipping tweets already in the collection or staging. For tweets staged without them.
    public func loadChains(for items: [StagedItem], source: any TweetSource, http: any HTTPClient, concurrency: Int = 6,
                           onProgress: (@Sendable (_ done: Int, _ chain: Int, _ missing: Int) -> Void)? = nil) async throws -> (chain: Int, missing: Int) {
        let known = KnownTweets(try stagedTweetIDs().union(collection.tweetIDs()))
        let importer = TweetImporter(staging: self, source: source, http: http, archive: false)
        let loader = TweetChainLoader(source: source)
        let roots: [(String, FetchedTweet)] = items.compactMap { item in
            guard item.kind == .tweet, item.parentID == nil,
                  let tw = (try? Data(contentsOf: fileURL(item))).flatMap(FetchedTweet.parse(raw:)),
                  tw.replyToTweetID != nil || tw.quotedTweetID != nil else { return nil }
            return (item.id, tw)
        }
        var done = 0, chain = 0, missing = 0
        var index = 0
        while index < roots.count {
            try Task.checkCancellation()
            let batch = roots[index..<min(index + concurrency, roots.count)]
            index += batch.count
            let results = await withTaskGroup(of: (Int, Int).self) { group in
                for (id, tw) in batch {
                    group.addTask { await self.stageChain(of: tw, under: id, loader: loader, importer: importer, known: known) }
                }
                var out: [(Int, Int)] = []
                for await r in group { out.append(r) }
                return out
            }
            for r in results { chain += r.0; missing += r.1 }
            done += batch.count
            onProgress?(done, chain, missing)
        }
        return (chain, missing)
    }
}

extension StagingArea {
    /// Re-reads every staged tweet's saved JSON and updates its text and GIF marks to the current
    /// parsing rules. Returns how many changed.
    @discardableResult
    public func reparseTweets() throws -> Int {
        let all = try db.query("SELECT * FROM staged WHERE kind = 'tweet'", [], StagingArea.row)
        var changed = 0
        for var item in all {
            guard let tw = (try? Data(contentsOf: fileURL(item))).flatMap(FetchedTweet.parse(raw:)),
                  case .tweet(var p) = item.payload else { continue }
            let text = tw.text.isEmpty ? nil : tw.text
            guard text != item.textVerbatim || p.animatedMedia != tw.animatedMedia || p.mediaSizes != tw.mediaSizes else { continue }
            item.textVerbatim = text
            p.animatedMedia = tw.animatedMedia
            p.mediaSizes = tw.mediaSizes
            item.payload = .tweet(p)
            try update(item)
            changed += 1
        }
        return changed
    }
}

extension StagingArea {
    /// Gives staged tweets saved before `TweetPayload.mediaSizes` existed their media sizes, read from
    /// the tweet's saved JSON (an empty list when it gives none, so each tweet is read once). Returns how many changed.
    @discardableResult
    public func fillMediaSizes() throws -> Int {
        let all = try db.query("SELECT * FROM staged WHERE kind = 'tweet'", [], StagingArea.row)
        var changed = 0
        for var item in all {
            guard case .tweet(var p) = item.payload, p.mediaSizes == nil,
                  let tw = (try? Data(contentsOf: fileURL(item))).flatMap(FetchedTweet.parse(raw:)) else { continue }
            p.mediaSizes = tw.mediaSizes ?? []
            item.payload = .tweet(p)
            try update(item)
            changed += 1
        }
        return changed
    }
}
