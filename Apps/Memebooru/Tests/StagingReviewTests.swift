import Foundation
import Testing
import SwiftUI
import MemebooruCore
@testable import Memebooru

/// The app's model driven the way the screens drive it — on a throwaway collection, never the real one.
@MainActor
final class AppFixture {
    let dir: URL
    let library = Library()
    private let savedDefaults: [String: Any?]
    private static let keys = ["stagingKind", "stagingFilter", "stagingGrid", "collectionPath", "waybackEnabled"]

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mb-app-\(UUID().uuidString)/Test.memebooru")
        let d = UserDefaults.standard
        savedDefaults = Dictionary(uniqueKeysWithValues: Self.keys.map { ($0, d.object(forKey: $0)) })
        library.waybackEnabled = false                     // never talk to archive.org from a test
        library.open(dir, remember: false)                 // never becomes the collection the app opens next
        library.stagingKind = nil
        library.stagingFilter = ""
    }

    /// Puts the user's own settings back (the test host shares the app's preferences).
    func tearDown() {
        library.go(.gallery)
        let d = UserDefaults.standard
        for (k, v) in savedDefaults { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } }
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
    }

    var staging: StagingArea { library.staging! }
    var collection: MemebooruCore.Collection { library.collection! }

    @discardableResult
    func text(_ s: String) throws -> StagedItem { try staging.add(text: s, source: "test") }

    @discardableResult
    func tweet(_ id: String, handle: String, text: String?, sizes: [TweetPayload.MediaSize]? = nil,
               media: Int = 0, replyTo: String? = nil) throws -> StagedItem {
        let json = dir.deletingLastPathComponent().appendingPathComponent("tweet-\(id).json")
        try Data("{}".utf8).write(to: json)
        var p = TweetPayload(tweetID: id, url: "https://x.com/\(handle)/status/\(id)", authorName: handle.capitalized, handle: handle,
                             replyToTweetID: replyTo)
        p.mediaSizes = sizes
        var extras: [StagedExtra] = []
        for i in 0..<media {
            let f = dir.deletingLastPathComponent().appendingPathComponent("m\(id)-\(i).png")
            try Self.png(width: 40, height: 20).write(to: f)
            extras.append(StagedExtra(role: .media, order: i, url: f))
        }
        return try staging.add(file: json, source: "x:\(handle)", originalName: "tweet-\(id).json", kind: .tweet,
                               textVerbatim: text, payload: .tweet(p), extraTags: ["@\(handle)"], extras: extras)
    }

    func picture(_ name: String, width: Int = 64, height: Int = 32) throws -> StagedItem {
        let f = dir.deletingLastPathComponent().appendingPathComponent(name)
        try Self.png(width: width, height: height).write(to: f)
        return try staging.add(file: f, source: "folder")
    }

    /// A real PNG (the analyser and the thumbnailer open it).
    static func png(width: Int, height: Int, orientation: Int? = nil) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, (orientation == nil ? "public.png" : "public.jpeg") as CFString, 1, nil)!
        let props: [CFString: Any] = orientation.map { [kCGImagePropertyOrientation: $0] } ?? [:]
        CGImageDestinationAddImage(dest, ctx.makeImage()!, props as CFDictionary)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    /// Waits (briefly) for background work the screens kick off.
    func eventually(_ what: String, timeout: Double = 15, _ check: () throws -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if try check() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("timed out waiting for \(what)")
    }
}

@MainActor
@Suite(.serialized) struct StagingReviewTests {
    @Test func filterByKindAndWords() throws {
        let f = try AppFixture(); defer { f.tearDown() }
        try f.text("Привет, мир")
        try f.text("hello WORLD")
        try f.tweet("1", handle: "elonmusk", text: "rockets")
        try f.tweet("2", handle: "dril", text: nil)
        f.library.reloadStaging()
        #expect(f.library.shownStaged.count == 4)

        f.library.stagingKind = .tweet
        #expect(f.library.shownStaged.count == 2)
        f.library.stagingFilter = "@DRIL"                         // handles, any case
        #expect(f.library.shownStaged.map(\.payloadTweetID) == ["2"])

        f.library.stagingKind = nil
        f.library.stagingFilter = "мир"                           // Cyrillic, lower-cased
        #expect(f.library.shownStaged.count == 1)
        f.library.stagingFilter = "world hello"                   // every word, any order
        #expect(f.library.shownStaged.count == 1)
        f.library.stagingFilter = "world missing"
        #expect(f.library.shownStaged.isEmpty)
        f.library.stagingFilter = "   "                            // only spaces: no filter
        #expect(f.library.shownStaged.count == 4)
    }

    @Test func shownListFollowsTheListAfterChanges() throws {
        let f = try AppFixture(); defer { f.tearDown() }
        let a = try f.text("one"), b = try f.text("two")
        f.library.reloadStaging()
        let before = f.library.shownStaged.map(\.id)
        #expect(Set(before) == [a.id, b.id])
        try f.text("three")
        f.library.reloadStaging()                                  // a cached list must not survive a reload
        #expect(f.library.shownStaged.count == 3)
    }

    @Test func neighboursWalkTheShownList() throws {
        let f = try AppFixture(); defer { f.tearDown() }
        for i in 0..<3 { try f.text("item \(i)") }
        f.library.reloadStaging()
        let ids = f.library.shownStaged.map(\.id)
        #expect(f.library.stagedNeighbor(of: ids[0], -1) == nil)
        #expect(f.library.stagedNeighbor(of: ids[0], 1)?.id == ids[1])
        #expect(f.library.stagedNeighbor(of: ids[2], 1) == nil)
        #expect(f.library.stagedNeighbor(of: "missing", 1) == nil)
    }

    @Test func commitGoesStraightOnToTheNextItem() async throws {
        let f = try AppFixture(); defer { f.tearDown() }
        for i in 0..<3 { try f.text("meme \(i)") }
        f.library.reloadStaging()
        let ids = f.library.shownStaged.map(\.id)
        f.library.go(.staging)
        f.library.openStaged = ids[0]
        f.library.commitAndAdvance(f.library.shownStaged[0])
        #expect(f.library.openStaged == ids[1])                    // at once, not after the commit lands
        #expect(!f.library.stagedItems.contains { $0.id == ids[0] })
        try await f.eventually("the commit") { try f.collection.memes.count() == 1 }
        #expect(f.library.stagedItems.count == 2)
        #expect(f.library.openStaged == ids[1])                    // the reload after it doesn't close the page

        // The last one goes back to the one before it; when nothing is left the page closes.
        f.library.openStaged = ids[2]
        f.library.commitAndAdvance(try #require(f.library.stagedItems.first { $0.id == ids[2] }))
        #expect(f.library.openStaged == ids[1])
        f.library.commitAndAdvance(try #require(f.library.stagedItems.first { $0.id == ids[1] }))
        #expect(f.library.openStaged == nil)
        try await f.eventually("all commits") { try f.collection.memes.count() == 3 }
        #expect(f.library.stagedItems.isEmpty)
    }

    @Test func discardIsUndoableAndAdvances() throws {
        let f = try AppFixture(); defer { f.tearDown() }
        try f.text("keep"); try f.text("drop")
        f.library.reloadStaging()
        let ids = f.library.shownStaged.map(\.id)
        f.library.openStaged = ids[1]
        f.library.discardAndAdvance(f.library.shownStaged[1])
        #expect(f.library.openStaged == ids[0])
        #expect(f.library.stagedItems.map(\.id) == [ids[0]])
        #expect(f.library.lastUndoLabel != nil)
        f.library.undoLast()
        #expect(Set(f.library.stagedItems.map(\.id)) == Set(ids))
    }

    @Test func backClosesThePostFirstThenTheStagedPage() throws {
        let f = try AppFixture(); defer { f.tearDown() }
        let item = try f.text("x")
        f.library.reloadStaging()
        f.library.go(.staging)
        f.library.openStaged = item.id
        f.library.openDetail(MemeID("some-post"))
        f.library.popDetailImmediate()
        #expect(f.library.detailStack.isEmpty && f.library.openStaged == item.id)
        f.library.popDetailImmediate()
        #expect(f.library.openStaged == nil)
        f.library.openStaged = item.id
        f.library.go(.gallery)                                     // switching pages closes it too
        #expect(f.library.openStaged == nil)
        f.library.openStaged = item.id
        f.library.typedQuery = "cats"                              // so does searching
        #expect(f.library.openStaged == nil && f.library.section == .gallery)
    }

    @Test func aStagedPageClosesWhenItsItemIsGone() throws {
        let f = try AppFixture(); defer { f.tearDown() }
        let item = try f.text("x")
        f.library.reloadStaging()
        f.library.openStaged = item.id
        try f.staging.discard(item.id)
        f.library.reloadStaging()
        #expect(f.library.openStaged == nil)
    }

    @Test func pausingWaybackKeepsTheQueue() throws {
        let f = try AppFixture(); defer { f.tearDown() }
        let meme = Meme(kind: .text, presentation: .native, textVerbatim: "t")
        try f.collection.memes.insert(meme)
        try f.collection.wayback.enqueue(meme.id, url: "https://x.com/a/status/1")
        f.library.setWayback(enabled: false)
        #expect(f.library.waybackPending == 1)                     // paused, not forgotten
        f.library.setWayback(enabled: true)
        f.library.setWayback(enabled: false)
        #expect(try f.collection.wayback.pendingCount() == 1)
    }
}

@MainActor
@Suite struct TweetCardModelTests {
    @Test func stagedMediaGetsItsShapeWithoutOpeningFiles() throws {
        let f = try AppFixture(); defer { f.tearDown() }
        let t = try f.tweet("9", handle: "a", text: nil, sizes: [.init(order: 0, width: 1600, height: 900)], media: 1)
        let m = f.library.tweetModel(staged: t)
        #expect(m.media.count == 1)
        #expect(abs((m.media[0].aspect ?? 0) - 16.0 / 9.0) < 0.001)   // from x.com, not the 40×20 file
        #expect(m.mediaOnly)                                           // no text, not a reply: just the picture
    }

    @Test func picturesWithoutSizesAreMeasuredFromTheFile() throws {
        let f = try AppFixture(); defer { f.tearDown() }
        let t = try f.tweet("10", handle: "a", text: "words", media: 1)
        let m = f.library.tweetModel(staged: t)
        #expect(m.media.first?.aspect == 2)                            // the 40×20 PNG's header
        #expect(!m.mediaOnly)
    }

    @Test func aReplyIsNeverBareMediaUnlessChosen() throws {
        let f = try AppFixture(); defer { f.tearDown() }
        let t = try f.tweet("11", handle: "a", text: nil, media: 1, replyTo: "5")
        #expect(!f.library.tweetModel(staged: t).mediaOnly)
        f.library.reloadStaging()
        f.library.toggleTweetDisplay(staged: t)
        let again = try #require(f.library.stagedItems.first { $0.id == t.id })
        #expect(f.library.tweetModel(staged: again).mediaOnly)
    }

    @Test func titlesForTheGrid() throws {
        let f = try AppFixture(); defer { f.tearDown() }
        #expect(try f.tweet("1", handle: "dril", text: "x").reviewTitle == "@dril")
        #expect(try f.picture("Гигачад анфас.png").reviewTitle == "Гигачад анфас")
        let long = String(repeating: "слово ", count: 40)
        #expect(try f.text("first line\nsecond").reviewTitle == "first line")
        #expect(try f.text(long).reviewTitle.count == 60)
        #expect(try f.text("   ").reviewTitle == MemeKind.text.categoryName)
    }
}
