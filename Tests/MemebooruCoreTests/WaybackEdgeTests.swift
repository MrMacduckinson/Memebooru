import Foundation
import Testing
@testable import MemebooruCore

@Suite struct WaybackQueueEdgeTests {
    private func setup() throws -> (TempCollection, ManualClock) {
        let t = try TempCollection()
        let clock = ManualClock(1_000_000)
        t.collection.wayback.now = { clock.value }
        return (t, clock)
    }

    private func tweet(_ c: Collection, _ n: Int) throws -> Meme {
        let m = Meme(kind: .tweet, payload: .tweet(TweetPayload(tweetID: "\(n)", url: "https://x.com/a/status/\(n)", authorName: "A", handle: "a")))
        try c.memes.insert(m)
        try c.wayback.enqueue(m.id, url: "https://x.com/a/status/\(n)")
        return m
    }

    @Test func pendingCountsItemsThatAreBackingOff() throws {
        let (t, clock) = try setup()
        let q = t.collection.wayback
        try q.enqueue(MemeID("m"), url: "u")
        try q.bump(MemeID("m"))
        #expect(try q.pendingCount() == 1)                    // waiting, but still pending
        #expect(try q.next().isEmpty)                         // not due
        clock.advance(WaybackQueue.backoff[0])
        #expect(try q.next().map(\.tries) == [1])
    }

    @Test func enqueueIgnoresEmptyUrlsAndDuplicates() throws {
        let (t, clock) = try setup()
        let q = t.collection.wayback
        try q.enqueue(MemeID("e"), url: "")
        #expect(try q.pendingCount() == 0)
        try q.enqueue(MemeID("m"), url: "first")
        try q.bump(MemeID("m"))
        try q.enqueue(MemeID("m"), url: "second")              // already queued: kept as is, tries too
        clock.advance(WaybackQueue.backoff[0])
        let job = try #require(try q.next().first)
        #expect(job.url == "first" && job.tries == 1)
        try q.markDone(MemeID("m"))
        try q.enqueue(MemeID("m"), url: "third")               // done stays done
        #expect(try q.pendingCount() == 0)
    }

    @Test func fewestTriesFirstThenOldest() throws {
        let (t, clock) = try setup()
        let q = t.collection.wayback
        for id in ["a", "b", "c"] { try q.enqueue(MemeID(id), url: id) }
        try q.bump(MemeID("a"))
        #expect(try q.next(limit: 5).map(\.memeID.rawValue) == ["b", "c"])
        clock.advance(WaybackQueue.backoff[0])
        #expect(try q.next(limit: 5).map(\.memeID.rawValue) == ["b", "c", "a"])
        #expect(try q.next(limit: 1).map(\.memeID.rawValue) == ["b"])
        #expect(try q.next(limit: 0).isEmpty)
    }

    @Test func backoffScheduleIsExact() throws {
        let (t, clock) = try setup()
        let q = t.collection.wayback
        try q.enqueue(MemeID("m"), url: "u")
        for (i, wait) in WaybackQueue.backoff.enumerated() {
            try q.bump(MemeID("m"))
            let due = clock.value + wait
            clock.value = due - 1
            #expect(try q.next().isEmpty, "attempt \(i + 2) came early")
            clock.value = due
            if i + 1 < WaybackQueue.maxTries { #expect(try q.next().first?.tries == i + 1) }
        }
    }

    @Test func maxTriesCutoff() throws {
        let (t, clock) = try setup()
        let q = t.collection.wayback
        try q.enqueue(MemeID("m"), url: "u")
        for _ in 0..<(WaybackQueue.maxTries - 1) { try q.bump(MemeID("m")) }
        #expect(try q.pendingCount() == 1)
        clock.advance(WaybackQueue.backoff.reduce(0, +))
        #expect(try q.next().count == 1)                      // the last allowed attempt
        try q.bump(MemeID("m"))
        #expect(try q.pendingCount() == 0)
        clock.advance(1_000 * WaybackQueue.backoff.last!)
        #expect(try q.next().isEmpty)
        try q.bump(MemeID("m"))                               // bumping past the end is harmless
        try q.bump(MemeID("never-queued"))
        #expect(try q.pendingCount() == 0)
        #expect(WaybackQueue.maxTries == WaybackQueue.backoff.count + 1)
    }

    @Test func purgeDeletedOnlyDropsPendingTweetsThatAreGone() throws {
        let (t, _) = try setup()
        let c = t.collection
        let live = try tweet(c, 1), gone = try tweet(c, 2), archivedThenGone = try tweet(c, 3)
        try c.wayback.enqueue(MemeID("not-a-meme"), url: "u")
        try c.wayback.markDone(archivedThenGone.id)
        _ = try c.deleteMemes([gone.id, archivedThenGone.id])
        try c.wayback.purgeDeleted()
        let rows = try c.db.query("SELECT meme_id FROM wayback_queue ORDER BY meme_id", []) { $0.string(0) }
        #expect(Set(rows) == [live.id.rawValue, archivedThenGone.id.rawValue, "not-a-meme"])
        #expect(try c.wayback.pendingCount() == 2)
        try c.wayback.clear()
        #expect(try c.db.scalarInt("SELECT count(*) FROM wayback_queue") == 0)
    }

    @Test func restagingTweetsPurgesTheirSnapshots() throws {
        let t = try TempCollection()
        let c = t.collection
        let json = try t.file("t.json", "{}")
        let item = try c.staging.add(file: json, source: "x", kind: .tweet,
                                     payload: .tweet(TweetPayload(tweetID: "9", url: "https://x.com/a/status/9", authorName: "A", handle: "a")))
        let m = try c.staging.commit(item.id)
        #expect(try c.wayback.pendingCount() == 1)
        _ = try c.restageTweets([m.id], into: c.staging)
        #expect(try c.wayback.pendingCount() == 0)
        let back = try #require(try c.staging.list().first)
        _ = try c.staging.commit(back.id)
        #expect(try c.wayback.pendingCount() == 1)            // queued again for the new meme
    }
}

@Suite struct WaybackWorkerEdgeTests {
    private func tweet(_ c: Collection, _ n: Int, waybackURL: String? = nil) throws -> Meme {
        let m = Meme(kind: .tweet, payload: .tweet(TweetPayload(tweetID: "\(n)", url: "https://x.com/a/status/\(n)", authorName: "A", handle: "a", waybackURL: waybackURL)))
        try c.memes.insert(m)
        try c.wayback.enqueue(m.id, url: "https://x.com/a/status/\(n)")
        return m
    }

    @Test func skipsDeletedMemesWithoutCallingArchive() async throws {
        let t = try TempCollection()
        let c = t.collection
        let calls = Locked<[String]>([]), jobs = Locked<[String]>([])
        let gone = try tweet(c, 1), live = try tweet(c, 2)
        try c.memes.delete(gone.id)
        let worker = WaybackWorker(collection: c, pause: .zero, idle: .zero) { url in
            calls.mutate { $0.append(url) }; return "https://web.archive.org/web/1/\(url)"
        }
        worker.onJob = { id, link in jobs.mutate { $0.append("\(id.rawValue)=\(link ?? "nil")") } }
        while await worker.step() {}
        #expect(calls.value == ["https://x.com/a/status/2"])
        #expect(jobs.value.contains("\(gone.id.rawValue)=nil"))
        #expect(try c.wayback.pendingCount() == 0)
        guard case .tweet(let p)? = try c.memes.get(live.id)?.payload else { Issue.record("payload"); return }
        #expect(p.waybackURL == "https://web.archive.org/web/1/https://x.com/a/status/2")
        guard case .tweet(let g)? = try c.memes.get(gone.id)?.payload else { Issue.record("payload"); return }
        #expect(g.waybackURL == nil)                            // a deleted meme is never touched
    }

    @Test func throwingArchiveIsRetriedWithBackoffThenGivenUp() async throws {
        let t = try TempCollection()
        let c = t.collection
        let clock = ManualClock(Clock.nowMillis())
        c.wayback.now = { clock.value }
        struct RateLimited: Error {}
        let calls = Locked(0)
        let m = try tweet(c, 1)
        let worker = WaybackWorker(collection: c, pause: .zero, idle: .zero) { _ in calls.value += 1; throw RateLimited() }
        for attempt in 1...WaybackQueue.maxTries {
            #expect(await worker.step())
            #expect(calls.value == attempt)
            #expect(!(await worker.step()))                    // nothing due until the backoff passes
            clock.advance(WaybackQueue.backoff[min(attempt - 1, WaybackQueue.backoff.count - 1)])
        }
        #expect(!(await worker.step()))
        #expect(try c.wayback.pendingCount() == 0)
        #expect(try c.memes.get(m.id)?.deletedAt == nil)
    }

    @Test func aNonTweetInTheQueueIsNeverMarkedArchived() async throws {
        // Only tweets carry a snapshot link; anything else just uses up its attempts.
        let t = try TempCollection()
        let c = t.collection
        let clock = ManualClock(Clock.nowMillis())
        c.wayback.now = { clock.value }
        let img = Meme(kind: .image)
        try c.memes.insert(img)
        try c.wayback.enqueue(img.id, url: "https://example.com")
        let worker = WaybackWorker(collection: c, pause: .zero, idle: .zero) { "https://web.archive.org/web/1/\($0)" }
        #expect(await worker.step())
        #expect(try c.wayback.next().isEmpty && c.wayback.pendingCount() == 1)
        #expect(try c.memes.get(img.id)?.payload == MemePayload.none)
    }

    @Test func disabledWorkerPausesWithoutDraining() async throws {
        let t = try TempCollection()
        let c = t.collection
        let calls = Locked(0)
        let enabled = Locked(false)
        _ = try tweet(c, 1); _ = try tweet(c, 2)
        let worker = WaybackWorker(collection: c, pause: .milliseconds(1), idle: .milliseconds(5)) { url in
            calls.value += 1; return "https://web.archive.org/web/1/\(url)"
        }
        worker.isEnabled = { enabled.value }
        worker.start()
        defer { worker.stop() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(calls.value == 0)
        #expect(try c.wayback.pendingCount() == 2)             // kept, not dropped
        enabled.value = true                                   // the paused loop rechecks every 5 s
        for _ in 0..<800 where try c.wayback.pendingCount() > 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(try c.wayback.pendingCount() == 0)
        #expect(calls.value == 2)
    }

    @Test func startIsIdempotentAndRestartable() async throws {
        let t = try TempCollection()
        let c = t.collection
        let calls = Locked<[String]>([])
        let worker = WaybackWorker(collection: c, pause: .milliseconds(1), idle: .milliseconds(2)) { url in
            calls.mutate { $0.append(url) }; return "https://web.archive.org/web/1/\(url)"
        }
        worker.start(); worker.start(); worker.start()
        for n in 1...5 { _ = try tweet(c, n) }
        for _ in 0..<300 where try c.wayback.pendingCount() > 0 { try await Task.sleep(for: .milliseconds(10)) }
        worker.stop()
        #expect(calls.value.count == 5 && Set(calls.value).count == 5)   // each archived exactly once
        worker.stop()                                                    // stopping twice is fine
        _ = try tweet(c, 6)
        worker.start()
        defer { worker.stop() }
        for _ in 0..<300 where try c.wayback.pendingCount() > 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(calls.value.count == 6)
    }

    @Test func startPurgesTweetsDeletedWhileTheAppWasClosed() async throws {
        let t = try TempCollection()
        let c = t.collection
        let gone = try tweet(c, 1)
        try c.memes.delete(gone.id)
        let worker = WaybackWorker(collection: c, pause: .zero, idle: .seconds(60)) { _ in nil }
        worker.isEnabled = { false }
        worker.start()
        worker.stop()
        #expect(try c.db.scalarInt("SELECT count(*) FROM wayback_queue") == 0)
    }
}
