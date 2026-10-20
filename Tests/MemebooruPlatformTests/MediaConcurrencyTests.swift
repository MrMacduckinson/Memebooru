import Foundation
import Testing
import MemebooruCore

/// Counting semaphore whose waiters suspend instead of holding a thread.
private final class AsyncGate: @unchecked Sendable {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let lock = NSLock()
    init(_ permits: Int) { self.permits = permits }

    func acquire() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if permits > 0 { permits -= 1; lock.unlock(); c.resume() } else { waiters.append(c); lock.unlock() }
        }
    }

    func release() {
        lock.lock()
        if waiters.isEmpty { permits += 1; lock.unlock() } else { let c = waiters.removeFirst(); lock.unlock(); c.resume() }
    }
}

/// Counts finished workers: a semaphore for blocking waiters, a continuation for async ones.
private final class Countdown: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private var left: Int
    private var waiter: CheckedContinuation<Void, Never>?
    private let lock = NSLock()
    init(_ n: Int) { left = n }

    func tick() {
        lock.lock()
        left -= 1
        let zero = left == 0
        let w = zero ? waiter : nil
        if zero { waiter = nil }
        lock.unlock()
        if zero { semaphore.signal() }
        w?.resume()
    }

    /// Blocks the calling thread until the count reaches zero (true) or `seconds` pass (false).
    func block(seconds: Double) -> Bool { semaphore.wait(timeout: .now() + seconds) == .success }

    /// Resumes when the count reaches zero, or after `seconds` (timed on a plain thread, not the pool).
    func wait(atMost seconds: Double) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if left == 0 { lock.unlock(); c.resume(); return }
            waiter = c
            lock.unlock()
            Thread.detachNewThread { [self] in
                Thread.sleep(forTimeInterval: seconds)
                lock.lock(); let w = waiter; waiter = nil; lock.unlock()
                w?.resume()
            }
        }
    }
}

private struct Job: Sendable {
    var url: URL
    var kind: MemeKind
    var analyze: Bool
}

private enum Work {
    static func inputs() throws -> [(URL, MemeKind)] {
        let h264 = FormatCase.h264
        var files: [(URL, MemeKind)] = [
            (try MT.make("cc.mp4", FormatCase.v1s + FormatCase.a1s + ["-c:v", h264, "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest"]), .video),
            (try MT.make("cc.mov", FormatCase.v1s + ["-c:v", h264, "-pix_fmt", "yuv420p"]), .video),
            (try MT.make("cc-silent.mp4", MT.pattern("320x240", seconds: 2) + ["-c:v", h264, "-pix_fmt", "yuv420p"]), .video),
            (try MT.make("cc.png", ["-f", "lavfi", "-i", "testsrc2=s=640x360", "-frames:v", "1"]), .image),
            (try MT.make("cc.jpg", ["-f", "lavfi", "-i", "testsrc2=s=1280x720", "-frames:v", "1"]), .image),
            (try MT.make("cc.gif", MT.pattern("120x80", seconds: 0.5, rate: 10)), .gif),
            (try MT.write(Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="40" height="20"><rect width="20" height="20" fill="red"/></svg>"#.utf8), as: "cc.svg"), .image),
        ]
        if MT.has("libvpx-vp9") { files.append((try MT.make("cc.webm", FormatCase.v1s + ["-c:v", "libvpx-vp9", "-b:v", "200k"]), .video)) }
        if MT.isApple { files.append((MT.fixture("pic.heic"), .image)) }
        return files
    }
}

@Suite(.serialized, .enabled(if: MT.hasFFmpeg && MT.h264 != nil)) struct MediaConcurrencyTests {
    /// 40 detached tasks thumbnailing/analysing videos and pictures at once must all finish.
    ///
    /// Guards against cooperative-pool starvation: a synchronous API that waits for async work (a Task,
    /// a GCD block) by blocking on a semaphore — as AppleVideoProbe and ProcessFFmpegRunner did — hangs
    /// forever once every pool thread is blocked like that, since the work it waits for has no thread
    /// left to run on. The pool is saturated on purpose: `cores − 1` workers at a time plus a "plug" task
    /// blocking the last thread until the deadline. On a deadlock the plug gives its thread back and
    /// tells the remaining workers to skip, so the starved work drains and the run carries on (failed)
    /// instead of hanging.
    @Test func fortyConcurrentThumbnailsAllFinish() async throws {
        let files = try Work.inputs()
        let jobs = (0..<40).map { i in Job(url: files[i % files.count].0, kind: files[i % files.count].1, analyze: i % 3 == 0) }
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let gate = AsyncGate(max(1, cores - 1))
        let aborted = Locked(false)
        let results = Locked([Int: Result<Int, any Error>]())
        let done = Countdown(jobs.count)
        let analyzer = MT.analyzer
        let limit = 90.0
        let started = ContinuousClock.now

        let plug = Task.detached { () -> Bool in
            let inTime = done.block(seconds: limit)
            if !inTime { aborted.with { $0 = true } }
            return inTime
        }
        for (i, job) in jobs.enumerated() {
            Task.detached {
                await gate.acquire()
                if !aborted.get {
                    let r = Result<Int, any Error> {
                        if job.analyze {
                            let info = analyzer.analyze(job.url, kind: job.kind)
                            guard let w = info.width, w > 0 else { throw CollectionError("no size") }
                            return w
                        }
                        let jpeg = try analyzer.thumbnail(job.url, kind: job.kind)
                        guard let jpeg, jpeg.starts(with: [0xFF, 0xD8]) else { throw CollectionError("no JPEG") }
                        return jpeg.count
                    }
                    results.with { $0[i] = r }
                }
                gate.release()
                done.tick()
            }
        }

        let inTime = await plug.value
        let elapsed = ContinuousClock.now - started
        let finished = results.get.count
        await done.wait(atMost: 120)                                          // let skipped/starved workers drain
        guard inTime else {
            Issue.record("""
                Deadlock: only \(finished)/\(jobs.count) concurrent thumbnails finished in \(Int(limit)) s \
                (\(cores - 1) workers + 1 blocked pool thread on \(cores) cores). Something blocks pool threads \
                waiting for async work it can't get a thread for (AppleVideoProbe.load? a GCD drain?).
                """)
            return
        }
        let r = results.get
        #expect(r.count == jobs.count)
        for (i, job) in jobs.enumerated() {
            switch r[i] {
            case .success(let n): #expect(n > 0)
            case .failure(let e): Issue.record("job \(i) \(job.url.lastPathComponent) (\(job.analyze ? "analyze" : "thumbnail")): \(e)")
            case nil: Issue.record("job \(i) never ran")
            }
        }
        #expect(elapsed < .seconds(limit))
    }

    /// Several staging areas over one collection, committing concurrently (SQLite + content store).
    @Test func concurrentCommitsIntoOneCollection() throws {
        let files = try Work.inputs()
        let c = try MT.collection()
        defer { try? FileManager.default.removeItem(at: c.url) }
        let s = StagingArea(collection: c, analyzer: MT.analyzer)
        // Same content several times over: the content store must cope with racing writers of one file.
        let items = try (0..<12).map { i in try s.add(file: files[i % 4].0, source: "test", extraTags: ["c\(i)"]) }
        let errors = Locked([String]())
        DispatchQueue.concurrentPerform(iterations: items.count) { i in
            do { _ = try StagingArea(collection: c, analyzer: MT.analyzer).commit(items[i].id) }
            catch { errors.with { $0.append("\(items[i].originalName ?? "?"): \(error)") } }
        }
        #expect(errors.get.isEmpty, "\(errors.get)")
        #expect(try c.memes.count() == items.count)
        #expect(try s.list().isEmpty)
        for i in items {
            #expect(try c.memes.memes(withSHA256: i.sha256).count >= 1 || i.willConvert)
        }
    }

    // MARK: - Performance sanity

    @Test(arguments: ["png", "jpg"])
    func fourKPictureThumbnailIsQuick(_ ext: String) throws {
        let src = try MT.make("4k.\(ext)", ["-f", "lavfi", "-i", "testsrc2=s=3840x2160", "-frames:v", "1"])
        _ = try MT.analyzer.thumbnail(MT.fixture("gray.jpg"), kind: .image)                     // warm up the decoders
        let clock = ContinuousClock()
        var thumb: Data?
        let took = try clock.measure { thumb = try MT.analyzer.thumbnail(src, kind: .image) }
        try MT.checkThumbnail(thumb, displaySize: (3840, 2160), "4K \(ext)")
        #expect(took < .seconds(5), "4K \(ext) thumbnail took \(took)")
        let analysed = clock.measure { _ = MT.analyzer.analyze(src, kind: .image) }
        #expect(analysed < .seconds(10), "4K \(ext) analysis took \(analysed)")
    }

    @Test func fourKVideoThumbnailIsQuick() throws {
        let src = try MT.make("4k.mp4", MT.pattern("3840x2160", seconds: 1) + ["-c:v", FormatCase.h264, "-pix_fmt", "yuv420p"])
        let clock = ContinuousClock()
        var thumb: Data?
        let took = try clock.measure { thumb = try MT.analyzer.thumbnail(src, kind: .video) }
        try MT.checkThumbnail(thumb, displaySize: (3840, 2160), "4K video")
        #expect(took < .seconds(15), "4K video thumbnail took \(took)")
    }
}
