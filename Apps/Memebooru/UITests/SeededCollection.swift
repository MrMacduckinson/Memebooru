import Foundation
import CoreGraphics
import ImageIO
import MemebooruCore
import MemebooruPlatformApple

/// A throwaway collection for one UI test: made and filled here (MemebooruCore, in the test runner),
/// then opened by the app through `-uiTestCollection <path>`. It lives in the runner's temporary folder
/// and is deleted afterwards — never the user's collection.
struct SeededCollection {
    let root: URL
    var url: URL { root.appendingPathComponent("UITest.memebooru", isDirectory: true) }

    /// What the standard seed stages, in this order (the grid shows them in it).
    static let pictures = ["cat-alpha", "dog-beta", "frog-gamma"]
    static let text = "Hello from the UI test"
    static let tweetHandle = "dril"

    /// Builds the collection; the database is closed again before the app opens it.
    static func make(_ fill: (Seeder) throws -> Void) throws -> SeededCollection {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mb-uitest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let seeded = SeededCollection(root: root)
        try autoreleasepool {
            let collection = try MemebooruCore.Collection.openOrCreate(at: seeded.url)
            let staging = StagingArea(collection: collection, analyzer: MediaAnalyzer(platform: PlatformApple.make()))
            try fill(Seeder(staging: staging, scratch: root))
        }
        return seeded
    }

    /// Three pictures, a text and a tweet in staging; nothing in Posts.
    static func standard() throws -> SeededCollection {
        try make { s in
            for (i, name) in pictures.enumerated() { try s.picture(name, pattern: i + 1) }
            try s.text(text)
            try s.tweet("1001", handle: tweetHandle, text: "I am a fake tweet for the UI test")
        }
    }

    func remove() {
        // Only ever our own temporary folder.
        guard root.path.hasPrefix(FileManager.default.temporaryDirectory.path), root.lastPathComponent.hasPrefix("mb-uitest-") else { return }
        try? FileManager.default.removeItem(at: root)
    }
}

/// Adds items to the seeded collection's staging area (and commits some, for Posts).
struct Seeder {
    let staging: StagingArea
    let scratch: URL

    /// Staging lists items by the millisecond they were added: keep them apart so the order is the seeding order.
    private func pause() { usleep(5_000) }

    @discardableResult
    func picture(_ name: String, pattern: Int, tags: [String] = []) throws -> StagedItem {
        let f = scratch.appendingPathComponent("\(name).png")
        try Self.png(width: 160, height: 120, stripes: pattern).write(to: f)
        var item = try staging.add(file: f, source: "uitest")
        if !tags.isEmpty { item.userTags = tags; try staging.update(item) }
        pause()
        return item
    }

    @discardableResult
    func text(_ s: String) throws -> StagedItem {
        defer { pause() }
        return try staging.add(text: s, source: "uitest")
    }

    @discardableResult
    func tweet(_ id: String, handle: String, text: String) throws -> StagedItem {
        let json = scratch.appendingPathComponent("tweet-\(id).json")
        try Data("{}".utf8).write(to: json)
        let p = TweetPayload(tweetID: id, url: "https://x.com/\(handle)/status/\(id)", authorName: handle.capitalized, handle: handle)
        defer { pause() }
        return try staging.add(file: json, source: "x:\(handle)", originalName: "tweet-\(id).json", kind: .tweet,
                               textVerbatim: text, payload: .tweet(p), extraTags: ["@\(handle)"])
    }

    func commit(_ item: StagedItem) throws { _ = try staging.commit(item.id) }

    /// A real PNG with `stripes` vertical bars, so no two seeded pictures look alike to the duplicate finder.
    static func png(width: Int, height: Int, stripes: Int) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.95, green: 0.9, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let bars = stripes * 2 + 1
        let w = CGFloat(width) / CGFloat(bars)
        ctx.setFillColor(CGColor(red: 0.2 + 0.2 * CGFloat(stripes % 3), green: 0.4, blue: 0.3, alpha: 1))
        for i in stride(from: 1, to: bars, by: 2) { ctx.fill(CGRect(x: CGFloat(i) * w, y: 0, width: w, height: CGFloat(height))) }
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }
}
