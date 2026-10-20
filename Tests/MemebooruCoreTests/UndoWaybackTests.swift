import Foundation
import Testing
@testable import MemebooruCore

@Suite struct UndoTests {
    private func stageImage(_ t: TempCollection, _ name: String) throws -> StagedItem {
        let src = t.url.appendingPathComponent(name)
        try Data(name.utf8).write(to: src)
        return try t.collection.staging.add(file: src, source: "test", extraTags: ["source_unknown"])
    }

    @Test func undoCommitSoftDeletes() throws {
        let t = try TempCollection()
        let c = t.collection
        let a = try stageImage(t, "a.jpg"), b = try stageImage(t, "b.jpg")
        _ = try c.commitStaged([a, b])
        #expect(try c.memes.count() == 2)
        #expect(try c.staging.count() == 0)
        let last = try c.undo.lastUndoable()
        #expect(last?.count == 2 && last?.kind == "commit")
        #expect(try c.undoLast() != nil)
        #expect(try c.memes.count() == 0)            // creations reversed
        #expect(try c.undo.lastUndoable() == nil)    // nothing left to undo
    }

    @Test func undoDiscardRestoresRowAndFiles() throws {
        let t = try TempCollection()
        let c = t.collection
        let a = try stageImage(t, "a.jpg"), b = try stageImage(t, "b.jpg")
        let fileA = c.staging.fileURL(a)
        #expect(FileManager.default.fileExists(atPath: fileA.path))
        _ = try c.discardStaged([a, b])
        #expect(try c.staging.count() == 0)
        #expect(!FileManager.default.fileExists(atPath: fileA.path))   // moved to trash
        #expect(try c.undoLast() != nil)
        #expect(try c.staging.count() == 2)
        #expect(FileManager.default.fileExists(atPath: fileA.path))    // restored
        let restored = try c.staging.list()
        #expect(Set(restored.map(\.id)) == Set([a.id, b.id]))
    }

    @Test func undoDeleteRestoresMemes() throws {
        let t = try TempCollection()
        let c = t.collection
        let m1 = Meme(kind: .image, textExact: "one"), m2 = Meme(kind: .image)
        try c.memes.insert(m1, tags: ["x"]); try c.memes.insert(m2)
        _ = try c.deleteMemes([m1.id, m2.id])
        #expect(try c.memes.count() == 0)
        #expect(try c.undoLast() != nil)
        #expect(try c.memes.count() == 2)
        #expect(try c.memes.get(m1.id)?.textExact == "one")
        #expect(try c.search.search("x").memes.map(\.id) == [m1.id])   // FTS/tags intact
    }

    @Test func undoStackIsLIFOAndPersistsViaDB() throws {
        let t = try TempCollection()
        let c = t.collection
        let m = Meme(kind: .image); try c.memes.insert(m)
        _ = try c.deleteMemes([m.id])          // batch 1
        let a = try stageImage(t, "a.jpg")
        _ = try c.commitStaged([a])            // batch 2
        // reopen the collection (simulates app restart) — undo state is in the DB
        let reopened = try Collection.open(at: c.url)
        #expect(try reopened.undo.lastUndoable()?.kind == "commit")
        _ = try reopened.undoLast()            // undo batch 2
        #expect(try reopened.undo.lastUndoable()?.kind == "delete")
        _ = try reopened.undoLast()            // undo batch 1
        #expect(try reopened.memes.get(m.id)?.deletedAt == nil)
    }
}

@Suite struct WaybackQueueTests {
    @Test func committingTweetEnqueuesWayback() throws {
        let t = try TempCollection()
        let c = t.collection
        let staging = c.staging
        let json = t.url.appendingPathComponent("tw.json")
        try Data("{}".utf8).write(to: json)
        let payload = TweetPayload(tweetID: "1", url: "https://x.com/a/status/1", authorName: "A", handle: "a")
        let item = try staging.add(file: json, source: "x", kind: .tweet, payload: .tweet(payload))
        _ = try staging.commit(item.id)
        #expect(try c.wayback.pendingCount() == 1)
        let jobs = try c.wayback.next(limit: 5)
        #expect(jobs.first?.url == "https://x.com/a/status/1")
        try c.wayback.markDone(jobs[0].memeID)
        #expect(try c.wayback.pendingCount() == 0)
    }

    @Test func nonTweetDoesNotEnqueue() throws {
        let t = try TempCollection()
        let c = t.collection
        let src = t.url.appendingPathComponent("a.jpg"); try Data("x".utf8).write(to: src)
        let item = try c.staging.add(file: src, source: "test")
        _ = try c.staging.commit(item.id)
        #expect(try c.wayback.pendingCount() == 0)
    }

    private func tweet(_ c: Collection, _ n: Int) throws -> Meme {
        let m = Meme(kind: .tweet, payload: .tweet(TweetPayload(tweetID: "\(n)", url: "https://x.com/a/status/\(n)", authorName: "A", handle: "a")))
        try c.memes.insert(m)
        try c.wayback.enqueue(m.id, url: "https://x.com/a/status/\(n)")
        return m
    }

    @Test func workerStoresSnapshotRetriesFailuresAndSkipsDeleted() async throws {
        let t = try TempCollection()
        let c = t.collection
        let ok = try tweet(c, 1), failing = try tweet(c, 2)
        try c.wayback.enqueue(MemeID("gone"), url: "https://x.com/a/status/3")
        let worker = WaybackWorker(collection: c, pause: .zero, idle: .zero) { url in
            url.hasSuffix("/1") ? "https://web.archive.org/web/2026/\(url)" : nil
        }
        for _ in 0..<3 { #expect(await worker.step()) }
        #expect(!(await worker.step()))                                    // the failed one waits (backoff)
        guard case .tweet(let p)? = try c.memes.get(ok.id)?.payload else { Issue.record("not a tweet"); return }
        #expect(p.waybackURL == "https://web.archive.org/web/2026/https://x.com/a/status/1")
        #expect(try c.wayback.pendingCount() == 1)                          // still queued; the deleted one is dropped
        let clock = FakeClock()
        c.wayback.now = { clock.value }
        clock.value = Int64(Date().timeIntervalSince1970 * 1000) + WaybackQueue.backoff[0] + 1
        #expect(try c.wayback.next(limit: 5).map(\.memeID) == [failing.id])
        #expect(await worker.step())
        // The link is an ordinary edit, so it syncs.
        #expect(try c.db.scalarInt("SELECT count(*) FROM oplog WHERE entity = 'meme' AND entity_id = ?", [ok.id.rawValue]) > 0)
    }

    @Test func runningWorkerDrainsTheQueueAndCanBePaused() async throws {
        let t = try TempCollection()
        let c = t.collection
        let worker = WaybackWorker(collection: c, pause: .milliseconds(1), idle: .milliseconds(5)) { "https://web.archive.org/web/1/\($0)" }
        let enabled = Flag()
        worker.isEnabled = { enabled.value }
        worker.start()
        defer { worker.stop() }
        _ = try tweet(c, 1); _ = try tweet(c, 2)
        for _ in 0..<200 where try c.wayback.pendingCount() > 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(try c.wayback.pendingCount() == 0)
        enabled.value = false
        try await Task.sleep(for: .milliseconds(50))
        _ = try tweet(c, 3)
        try await Task.sleep(for: .milliseconds(100))
        #expect(try c.wayback.pendingCount() == 1)          // paused: queued, not archived
    }

    final class FakeClock: @unchecked Sendable {
        private let lock = NSLock(); private var v: Int64 = 0
        var value: Int64 { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
    }

    @Test func failuresBackOffThenGiveUp() throws {
        let t = try TempCollection()
        let c = t.collection
        let clock = FakeClock()
        clock.value = 1_000
        c.wayback.now = { clock.value }
        try c.wayback.enqueue(MemeID("m"), url: "https://x.com/x")
        for wait in WaybackQueue.backoff {
            #expect(try c.wayback.next().count == 1)
            try c.wayback.bump(MemeID("m"))
            clock.value += wait - 1
            #expect(try c.wayback.next().isEmpty)                            // not yet due
            clock.value += 1
        }
        #expect(try c.wayback.next().count == 1)                             // last attempt
        try c.wayback.bump(MemeID("m"))
        clock.value += 10 * WaybackQueue.backoff.last!
        #expect(try c.wayback.next().isEmpty && c.wayback.pendingCount() == 0)   // gave up
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock(); private var v = true
        var value: Bool { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
    }

    @Test func retryBudgetStopsPending() throws {
        let t = try TempCollection()
        let c = t.collection
        try c.wayback.enqueue(MemeID("m"), url: "https://x.com/x")
        for _ in 0..<WaybackQueue.maxTries { try c.wayback.bump(MemeID("m")) }
        #expect(try c.wayback.pendingCount() == 0)   // exhausted, no longer offered
    }
}

@Suite struct XCursorTests {
    @Test func cursorCheckpointRoundTrips() throws {
        let t = try TempCollection()
        let c = t.collection
        #expect(try c.xCursor("likes") == nil)
        try c.setXCursor("likes", "CURSOR_42")
        #expect(try c.xCursor("likes") == "CURSOR_42")
        try c.clearXCursor("likes")
        #expect(try c.xCursor("likes") == nil)
    }
}
