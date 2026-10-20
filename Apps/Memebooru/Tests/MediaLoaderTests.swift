import Foundation
import Testing
import SwiftUI
import AVFoundation
import MemebooruCore
import MemebooruPlatformApple
@testable import Memebooru

/// Counts calls from the media pool.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    var value: Int { lock.withLock { n } }
    func bump() { lock.withLock { n += 1 } }
}

@MainActor
@Suite(.serialized) struct MediaLoaderTests {
    nonisolated private static func image() -> PlatformImage {
        #if os(macOS)
        NSImage(size: NSSize(width: 2, height: 1))
        #else
        UIGraphicsImageRenderer(size: CGSize(width: 2, height: 1)).image { _ in }
        #endif
    }

    @Test func requestsForOneKeyShareOneJob() async {
        let loader = MediaLoader()
        let calls = Counter()
        let tasks = (0..<20).map { _ in
            Task { await loader.image("k") { calls.bump(); Thread.sleep(forTimeInterval: 0.05); return Self.image() } != nil }
        }
        var results: [Bool] = []
        for t in tasks { results.append(await t.value) }
        #expect(results.allSatisfy { $0 } && results.count == 20)
        #expect(calls.value == 1)
        #expect(loader.cached("k") != nil)
        _ = await loader.image("k") { calls.bump(); return nil }      // cached: not made again
        #expect(calls.value == 1)
    }

    @Test func aFailureIsRetriedOnceThenLeftAlone() async {
        let loader = MediaLoader()
        let calls = Counter()
        for _ in 0..<5 { _ = await loader.image("bad") { calls.bump(); return nil } }
        #expect(calls.value == 2)
        loader.forgetAll()                                             // a new collection: try again
        _ = await loader.image("bad") { calls.bump(); return nil }
        #expect(calls.value == 3)
    }

    @Test func scrolledAwayRequestsLeaveTheQueue() async throws {
        let loader = MediaLoader()
        let gate = DispatchSemaphore(value: 0)
        // Occupy the whole pool.
        let busy = (0..<MediaLoader.queue.maxConcurrentOperationCount).map { i in
            Task { @MainActor in await loader.image("busy\(i)") { gate.wait(); return Self.image() } }
        }
        try await Task.sleep(for: .milliseconds(200))
        let made = Counter()
        let wanted = Task { @MainActor in await loader.image("offscreen") { made.bump(); return Self.image() } }
        try await Task.sleep(for: .milliseconds(100))
        wanted.cancel()                                                // the view went away
        #expect(await wanted.value == nil)
        for _ in busy { gate.signal() }
        for t in busy { _ = await t.value }
        while MediaLoader.queue.operationCount > 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(made.value == 0)
    }

    /// The freeze we had: every shared thread blocked on a frame that needed a shared thread itself.
    /// Many video frames at once must all arrive.
    @Test(.timeLimit(.minutes(1))) func manyVideoFramesAtOnceDontFreeze() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mb-frames-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = dir.appendingPathComponent("v.mp4")
        try await Self.writeTestVideo(to: video)        // AVFoundation: no ffmpeg needed, works on iOS too

        let probe = AppleVideoProbe()
        // Straight from Swift concurrency's own threads, far more than there are of them.
        let n = ProcessInfo.processInfo.activeProcessorCount * 4
        let ok = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<n { group.addTask { (try? probe.frame(video, at: 0.5, maxSide: 64)) != nil } }
            var n = 0
            for await r in group where r { n += 1 }
            return n
        }
        #expect(ok == n)

        // And through the loader, as the screens ask for them.
        let loader = MediaLoader()
        let tasks = (0..<n).map { i in
            Task { await loader.image("v\(i)") { (try? probe.frame(video, at: 0.5, maxSide: 64)).map { _ in Self.image() } } != nil }
        }
        var images = 0
        for t in tasks where await t.value { images += 1 }
        #expect(images == n)
    }

    /// A 2-second 320×240 H.264 MP4 (20 frames of changing grey).
    nonisolated private static func writeTestVideo(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320,
            kCVPixelBufferHeightKey as String: 240])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for i in 0..<20 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_32BGRA, nil, &buffer)
            let b = try #require(buffer)
            CVPixelBufferLockBaseAddress(b, [])
            memset(CVPixelBufferGetBaseAddress(b), Int32(i * 12), CVPixelBufferGetDataSize(b))
            CVPixelBufferUnlockBaseAddress(b, [])
            #expect(adaptor.append(b, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 10)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed, "\(String(describing: writer.error))")
    }

    @Test func pixelSizeReadsTheHeaderAndTurnsRotatedPhotos() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mb-px-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plain = dir.appendingPathComponent("a.png"), turned = dir.appendingPathComponent("b.jpg")
        try AppFixture.png(width: 300, height: 100).write(to: plain)
        try AppFixture.png(width: 300, height: 100, orientation: 6).write(to: turned)   // a phone photo held upright
        #expect(MediaLoader.pixelSize(plain) == CGSize(width: 300, height: 100))
        #expect(MediaLoader.pixelSize(turned) == CGSize(width: 100, height: 300))
        let notAPicture = dir.appendingPathComponent("c.png")
        try Data("not a picture".utf8).write(to: notAPicture)
        #expect(MediaLoader.pixelSize(notAPicture) == nil)
        #expect(MediaLoader.pixelSize(dir.appendingPathComponent("missing.png")) == nil)
    }
}

@MainActor
@Suite struct LayoutMathTests {
    @Test func fittingKeepsTheShapeInsideTheBox() {
        let box = CGSize(width: 200, height: 150)
        #expect(StagedArt.fit(2, in: box) == CGSize(width: 200, height: 100))       // wide: full width
        #expect(StagedArt.fit(0.5, in: box) == CGSize(width: 75, height: 150))      // tall: full height
        #expect(StagedArt.fit(4.0 / 3.0, in: box) == box)
        #expect(StagedArt.fit(0.01, in: box).width >= 30)                          // a sliver stays visible
        #expect(StagedArt.fit(100, in: box).height >= 1)
    }

    @Test func aspectFitBoxReportsTheHeightItDraws() {
        // Width-bound: height follows the width.
        #expect(AspectFitBox.size(width: 600, aspect: 2, maxHeight: 400) == CGSize(width: 600, height: 300))
        // Height-bound: capped, never taller than allowed.
        #expect(AspectFitBox.size(width: 600, aspect: 0.5, maxHeight: 400).height == 400)
        // No width offered: the natural size at the cap.
        #expect(AspectFitBox.size(width: nil, aspect: 0.5, maxHeight: 400) == CGSize(width: 200, height: 400))
        // Whole points, so rows under it don't sit on half pixels.
        #expect(AspectFitBox.size(width: 333, aspect: 1.7, maxHeight: 999).height == (333 / 1.7).rounded())
    }

    @Test func whatThePlayerOpensAsIs() {
        #expect(Library.avPlayable(ext: "mp4", codecs: nil))
        #expect(Library.avPlayable(ext: "MOV", codecs: nil))
        #expect(!Library.avPlayable(ext: "webm", codecs: nil))
        #expect(!Library.avPlayable(ext: "mkv", codecs: nil))
        #expect(Library.avPlayable(ext: "mp4", codecs: "mov,mp4/h264/aac"))
        #expect(!Library.avPlayable(ext: "mp4", codecs: "mov,mp4/vp9/opus"))       // VP9 in MP4: needs a preview
        #expect(Library.avPlayable(ext: "m4a", codecs: "mov,mp4/-/aac"))
    }
}
