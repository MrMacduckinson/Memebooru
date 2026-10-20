import Foundation

/// Persistent queue of tweets awaiting a Wayback Machine snapshot. Drained by a background worker,
/// so committing tweets never blocks on archive.org. Survives restarts.
public final class WaybackQueue: @unchecked Sendable {
    /// Waits after the 1st, 2nd… failure. archive.org answers 429 for minutes to hours at a time,
    /// so quick retries would only burn the attempts; after the last one the tweet is left alone.
    public static let backoff: [Int64] = [300_000, 1_800_000, 7_200_000, 43_200_000, 86_400_000]   // 5 min, 30 min, 2 h, 12 h, 24 h
    public static var maxTries: Int { backoff.count + 1 }
    private let db: Database
    /// Unix ms; injectable so tests can step past the waits.
    var now: @Sendable () -> Int64 = { Clock.nowMillis() }
    init(db: Database) { self.db = db }

    public func enqueue(_ memeID: MemeID, url: String) throws {
        guard !url.isEmpty else { return }
        try db.run("INSERT OR IGNORE INTO wayback_queue(meme_id, url, added_at) VALUES (?,?,?)", [memeID.rawValue, url, Clock.nowMillis()])
    }

    public func pendingCount() throws -> Int {
        Int(try db.scalarInt("SELECT count(*) FROM wayback_queue WHERE done = 0 AND tries < ?", [Self.maxTries]))
    }

    /// When the earliest queued tweet may be tried again (unix ms); nil when nothing is waiting out a backoff.
    public func nextRetryAt() throws -> Int64? {
        let t = try db.scalarInt("SELECT coalesce(min(next_try_at), 0) FROM wayback_queue WHERE done = 0 AND tries < ?", [Self.maxTries])
        return t > now() ? t : nil
    }

    public func next(limit: Int = 1) throws -> [(memeID: MemeID, url: String, tries: Int)] {
        // Due ones only, fewest tries first: a tweet archive.org keeps refusing doesn't hold up the rest.
        try db.query("""
            SELECT meme_id, url, tries FROM wayback_queue WHERE done = 0 AND tries < ? AND next_try_at <= ?
            ORDER BY tries, added_at, rowid LIMIT ?
            """, [Self.maxTries, now(), limit]) { (MemeID($0.string(0)), $0.string(1), $0.int(2)) }
    }

    public func markDone(_ memeID: MemeID) throws {
        try db.run("UPDATE wayback_queue SET done = 1 WHERE meme_id = ?", [memeID.rawValue])
    }
    /// A failed attempt: counted, and the next one waits per `backoff`.
    public func bump(_ memeID: MemeID) throws {
        let tries = try db.scalarInt("SELECT tries FROM wayback_queue WHERE meme_id = ?", [memeID.rawValue])
        let wait = Self.backoff[min(Int(tries), Self.backoff.count - 1)]
        try db.run("UPDATE wayback_queue SET tries = tries + 1, next_try_at = ? WHERE meme_id = ?", [now() + wait, memeID.rawValue])
    }
    /// Forget tweets that have been deleted (or moved back to staging) since they were queued.
    public func purgeDeleted() throws {
        try db.run("DELETE FROM wayback_queue WHERE done = 0 AND meme_id IN (SELECT id FROM meme WHERE deleted_at IS NOT NULL)", [])
    }
    /// Drop all queued snapshots (e.g. user paused archiving).
    public func clear() throws { try db.run("DELETE FROM wayback_queue", []) }
}

/// Drains the Wayback queue in the background: one tweet at a time, a pause between requests to be
/// gentle on archive.org. The snapshot link goes into the tweet's payload, so it syncs to every device.
/// Runs in the app and on the server alike.
public final class WaybackWorker: @unchecked Sendable {
    let collection: Collection
    let archive: @Sendable (String) async throws -> String?
    let pause: Duration
    let idle: Duration
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    /// Checked before each job; false = paused (the queue is kept).
    public var isEnabled: @Sendable () -> Bool = { true }
    /// After each job: the tweet and its snapshot link (nil = failed, will retry up to `maxTries`).
    public var onJob: @Sendable (MemeID, String?) -> Void = { _, _ in }

    public convenience init(collection: Collection, http: any HTTPClient) {
        let archiver = WaybackArchiver(http: http)
        self.init(collection: collection, pause: .seconds(3), idle: .seconds(20)) { try await archiver.archive($0) }
    }

    public init(collection: Collection, pause: Duration, idle: Duration, archive: @escaping @Sendable (String) async throws -> String?) {
        self.collection = collection; self.pause = pause; self.idle = idle; self.archive = archive
    }

    /// Archives the oldest queued tweet. False when there was nothing to do.
    @discardableResult
    public func step() async -> Bool {
        guard let job = (try? collection.wayback.next(limit: 1))?.first else { return false }
        let meme = (try? collection.memes.get(job.memeID)) ?? nil
        guard let meme, meme.deletedAt == nil else {
            try? collection.wayback.markDone(job.memeID)      // meme gone: nothing to archive for
            onJob(job.memeID, nil)
            return true
        }
        let link = try? await archive(job.url)
        if let link, case .tweet(var p) = meme.payload {
            var meme = meme
            p.waybackURL = link
            meme.payload = .tweet(p)
            try? collection.memes.update(meme)
            try? collection.wayback.markDone(job.memeID)
        } else {
            try? collection.wayback.bump(job.memeID)
        }
        onJob(job.memeID, link)
        return true
    }

    public func start() {
        lock.withLock {
            guard task == nil else { return }
            try? collection.wayback.purgeDeleted()
            // Holds the worker until `stop()`, so a caller needn't keep it alive.
            task = Task {
                while !Task.isCancelled {
                    guard self.isEnabled() else { try? await Task.sleep(for: .seconds(5)); continue }
                    let worked = await self.step()
                    try? await Task.sleep(for: worked ? self.pause : self.idle)
                }
            }
        }
    }

    public func stop() {
        lock.withLock { task?.cancel(); task = nil }
    }
}
