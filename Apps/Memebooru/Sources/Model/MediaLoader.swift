import Foundation
import ImageIO
import SwiftUI

/// Pictures made from media files (thumbnails, posters, video frames) — made off the main thread on a
/// small dedicated pool, never on Swift concurrency's shared threads: the work blocks (ffmpeg, image
/// decoding), and blocking every shared thread is how the app once froze with spinners everywhere.
///
/// Each picture is asked for by the view that shows it (`.task(id:)`), so only that view redraws when
/// it lands — nothing app-wide is bumped. A view that scrolls away before its turn takes its request
/// back, so the queue holds what is on screen now, not everything ever scrolled past.
@MainActor
final class MediaLoader {
    private let cache = NSCache<NSString, PlatformImage>()
    private var failed: [String: Int] = [:]
    private var jobs: [String: Job] = [:]

    nonisolated static let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "memebooru.media"
        q.maxConcurrentOperationCount = 4
        q.qualityOfService = .utility
        return q
    }()

    private final class Job {
        var waiters: [UUID: CheckedContinuation<PlatformImage?, Never>] = [:]
        var operation: Operation?
    }

    init() { cache.countLimit = 1500 }

    /// Already made: no waiting, no flash when a view comes back on screen.
    func cached(_ key: String) -> PlatformImage? { cache.object(forKey: key as NSString) }

    func store(_ image: PlatformImage, for key: String) { cache.setObject(image, forKey: key as NSString) }
    func forgetAll() { cache.removeAllObjects(); failed = [:] }

    /// The picture for `key`, made by `make` (on the media pool) if it isn't cached. Requests for the
    /// same key share one job. A failed key is retried once, then left alone (nil).
    func image(_ key: String, newest: Bool = true, make: @escaping @Sendable () -> PlatformImage?) async -> PlatformImage? {
        if let img = cached(key) { return img }
        guard (failed[key] ?? 0) < 2, !Task.isCancelled else { return nil }
        let waiter = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<PlatformImage?, Never>) in
                if let job = jobs[key] { job.waiters[waiter] = c; return }
                let job = Job()
                job.waiters[waiter] = c
                jobs[key] = job
                let op = BlockOperation {
                    let img = UncheckedImage(make())
                    Task { @MainActor in self.finish(key, img.value) }
                }
                // What was asked for last is most likely what's on screen now.
                op.queuePriority = newest ? .high : .normal
                job.operation = op
                Self.queue.addOperation(op)
            }
        } onCancel: {
            Task { @MainActor in self.withdraw(key, waiter) }
        }
    }

    private func finish(_ key: String, _ img: PlatformImage?) {
        if let img { store(img, for: key) } else { failed[key, default: 0] += 1 }
        guard let job = jobs.removeValue(forKey: key) else { return }
        for c in job.waiters.values { c.resume(returning: img) }
    }

    private func withdraw(_ key: String, _ waiter: UUID) {
        guard let job = jobs[key], let c = job.waiters.removeValue(forKey: waiter) else { return }
        c.resume(returning: nil)
        // Nobody wants it any more and it hasn't started: drop it from the queue.
        if job.waiters.isEmpty, let op = job.operation, !op.isExecuting {
            op.cancel()
            jobs[key] = nil
        }
    }

    /// Runs blocking work (conversion, rasterizing) on the media pool and hands back its result.
    nonisolated static func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { c in queue.addOperation { c.resume(returning: body()) } }
    }

    /// Pixel size from the file's header — no decoding, fast enough to call while laying out.
    nonisolated static func pixelSize(_ url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }
        // EXIF orientations 5–8 are rotated a quarter turn: the shown picture is h × w.
        let o = props[kCGImagePropertyOrientation] as? Int ?? 1
        return o >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }
}

/// Carries a platform image from the media pool back to the main actor (it's never shared or mutated).
private struct UncheckedImage: @unchecked Sendable {
    let value: PlatformImage?
    init(_ v: PlatformImage?) { value = v }
}

/// Shows the picture `load` makes, or `placeholder` until it lands. Redraws only itself.
struct LoadedImage<Placeholder: View>: View {
    @Environment(Library.self) private var library
    let key: String
    var fit: ContentMode = .fill
    let load: @MainActor (Library) async -> PlatformImage?
    /// Shown until the picture lands; `true` once it couldn't be made.
    @ViewBuilder var placeholder: (_ failed: Bool) -> Placeholder
    @State private var loaded: (key: String, image: PlatformImage)?
    @State private var failedKey: String?

    var body: some View {
        Group {
            if let img = loaded?.key == key ? loaded?.image : library.loader.cached(key) {
                Image(platform: img).resizable().aspectRatio(contentMode: fit)
            } else {
                placeholder(failedKey == key)
            }
        }
        .task(id: key) {
            if let img = library.loader.cached(key) { loaded = (key, img); return }
            if let img = await load(library) { loaded = (key, img) } else if !Task.isCancelled { failedKey = key }
        }
    }
}
