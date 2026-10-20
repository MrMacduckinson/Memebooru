import Foundation
import Testing
import MemebooruCore
#if canImport(ImageIO)
import MemebooruPlatformApple
#endif
#if os(Linux)
import MemebooruPlatformLinux
#endif

private let platform: Platform = {
    #if canImport(ImageIO)
    return PlatformApple.make()
    #else
    return PlatformLinux.make()
    #endif
}()
private let analyzer = MediaAnalyzer(platform: platform)

private func solid(_ w: Int, _ h: Int, _ rgb: (UInt8, UInt8, UInt8)) -> Bitmap {
    var px = Data(count: w * h * 4)
    for i in stride(from: 0, to: px.count, by: 4) { px[i] = rgb.0; px[i + 1] = rgb.1; px[i + 2] = rgb.2; px[i + 3] = 255 }
    return Bitmap(width: w, height: h, rgba: px)
}

private func pixel(_ b: Bitmap, _ x: Int, _ y: Int) -> (Int, Int, Int) {
    let i = (y * b.width + x) * 4
    return (Int(b.rgba[i]), Int(b.rgba[i + 1]), Int(b.rgba[i + 2]))
}

/// Layout constants of `TweetRenderer` at scale 2 (600 pt card → 1200 px).
private enum L {
    static let width = 1200, pad = 32, inner = 1200 - 64, gap = 20
    static let maxMediaHeight = 920, tile = 360, tileGap = 8
}

@Suite(.serialized) struct TweetRenderEdgeTests {
    let c: Collection
    init() throws {
        c = try Collection.create(at: FileManager.default.temporaryDirectory.appendingPathComponent("tweet-render-edge-\(UUID().uuidString).memebooru"))
    }

    private var renderer: TweetRenderer? { platform.text.map { TweetRenderer(collection: c, analyzer: analyzer, text: $0) } }

    private func tweet(_ text: String?, name: String = "Автор", handle: String = "author", posted: Int64? = 1_700_000_000_000,
                       replyTo: String? = nil) throws -> Meme {
        let m = Meme(kind: .tweet, textVerbatim: text,
                     payload: .tweet(TweetPayload(tweetID: UUID().uuidString, url: "https://x.com/\(handle)/status/1", authorName: name,
                                                  handle: handle, postedAt: posted, replyToHandle: replyTo)))
        try c.memes.insert(m, tags: ["tweet"])
        return m
    }

    @discardableResult
    private func attach(_ bitmap: Bitmap, to meme: MemeID, role: Asset.Role, order: Int = 0) throws -> Asset {
        let f = try c.media.put(data: try platform.thumbs.jpeg(bitmap, quality: 0.9), ext: "jpg")
        return try c.memes.addAsset(Asset(memeID: meme, role: role, sha256: f.sha256, ext: "jpg", mime: "image/jpeg",
                                          width: bitmap.width, height: bitmap.height, bytes: f.bytes, order: order))
    }

    private func height(_ m: Meme) throws -> Int { try #require(renderer).bitmap(m).height }

    @Test func renderingIsDeterministic() throws {
        let r = try #require(renderer)
        let m = try tweet("Детерминизм 🔁 one two three", replyTo: "someone")
        try attach(solid(300, 200, (200, 30, 30)), to: m.id, role: .media)
        try attach(solid(64, 64, (10, 120, 200)), to: m.id, role: .avatar)
        let a = try r.bitmap(m), b = try r.bitmap(m)
        let fresh = try #require(platform.text.map { TweetRenderer(collection: c, analyzer: analyzer, text: $0) }).bitmap(m)
        #expect(a.width == L.width && a.width == b.width && a.height == b.height)
        #expect(a.rgba == b.rgba && a.rgba == fresh.rgba)
        let e1 = try r.encoded(m), e2 = try r.encoded(m)
        #expect(e1.data == e2.data && e1.ext == "png" && e1.width == L.width && e1.height == a.height)
        #expect(try r.fingerprint(m) == r.fingerprint(m))
    }

    @Test func longTextGrowsDownNeverSideways() throws {
        let short = try height(try tweet("коротко"))
        let long = try height(try tweet(String(repeating: "Очень длинный текст твита, который переносится. ", count: 40)))
        let word = try height(try tweet(String(repeating: "x", count: 3000)))                // one unbreakable word
        let lines = try height(try tweet(String(repeating: "line\n", count: 60)))
        #expect(long > short + 400 && lines > short + 1000)
        #expect(word >= short)
        // Nothing wider than the card: text bitmaps fit the inner width.
        let text = try #require(platform.text)
        for s in [String(repeating: "x", count: 3000), String(repeating: "https://example.com/a/b/c?d=e ", count: 20)] {
            let b = try #require(try text.render(s, style: TextStyle(size: 32, color: 0), width: L.inner))
            #expect(b.width <= L.inner)
        }
    }

    @Test(arguments: [
        "مرحبا بالعالم، هذه تغريدة طويلة نسبياً من اليمين إلى اليسار",
        "שלום עולם mixed with English and ١٢٣",
        "日本語のツイート、漢字とかなと𠮷",
        "👨‍👩‍👧 🇺🇦 🏳️‍🌈 👍🏽 😂😂😂",
        "Zalgo t̷̡̛e̸̢͝x̵̧̛t̶̨͘ and e\u{301}",
        "\u{200F}\u{202E}override\u{202C} and zero\u{200B}width",
    ])
    func scriptsAndEmojiRenderInsideTheCard(text: String) throws {
        let none = try height(try tweet(nil))
        let m = try tweet(text)
        let b = try #require(renderer).bitmap(m)
        #expect(b.width == L.width && b.height > none)
        // Some ink where the text goes (below the 88 px header + gap).
        let y0 = L.pad + 88 + L.gap
        var inked = false
        for y in y0..<min(b.height, y0 + 40) where !inked {
            for x in L.pad..<(L.width - L.pad) where pixel(b, x, y) != (0xFB, 0xFC, 0xFA) { inked = true; break }
        }
        #expect(inked)
    }

    @Test func noAvatarDrawsThePlaceholderCircle() throws {
        let b = try #require(renderer).bitmap(try tweet("no face"))
        let centre = pixel(b, L.pad + 44, L.pad + 44)
        #expect(abs(centre.0 - 0xDD) <= 2 && abs(centre.1 - 0xE6) <= 2 && abs(centre.2 - 0xDB) <= 2)
        #expect(pixel(b, 1, 1) == (0xFB, 0xFC, 0xFA))
    }

    @Test func emptyNamesAndNoDateStillRender() throws {
        let bare = try height(try tweet(nil, name: "", handle: "", posted: nil))
        let dated = try height(try tweet(nil, name: "", handle: "", posted: 0))
        #expect(bare >= 2 * L.pad + 88 && dated > bare)
    }

    @Test(arguments: [(1, 852), (2, L.tile), (3, 2 * L.tile + L.tileGap), (4, 2 * L.tile + L.tileGap), (5, 2 * L.tile + L.tileGap)])
    func mediaBlockHeights(count: Int, block: Int) throws {
        let base = try height(try tweet("grid"))
        let m = try tweet("grid")
        for i in 0..<count { try attach(solid(800, 600, (UInt8(40 * i), 100, 100)), to: m.id, role: .media, order: i) }
        #expect(try height(m) == base + block + L.gap)
    }

    @Test func veryTallAndVeryWideImagesAreFitted() throws {
        let base = try height(try tweet("fit"))
        let tall = try tweet("fit")
        try attach(solid(100, 4000, (1, 2, 3)), to: tall.id, role: .media)
        #expect(try height(tall) == base + L.maxMediaHeight + L.gap)             // capped at 460 pt
        let wide = try tweet("fit")
        try attach(solid(4000, 100, (1, 2, 3)), to: wide.id, role: .media)
        #expect(try (27...30).contains(height(wide) - base - L.gap))             // 4000×100 scaled to 1136 wide
        let tiny = try tweet("fit")
        try attach(solid(10, 10, (1, 2, 3)), to: tiny.id, role: .media)
        #expect(try height(tiny) == base + L.maxMediaHeight + L.gap)             // small square scales up, to the height cap
    }

    @Test func mediaNotOnThisDeviceIsLeftOut() throws {
        let base = try height(try tweet("sync"))
        let m = try tweet("sync")
        let a = try attach(solid(800, 600, (1, 2, 3)), to: m.id, role: .media)
        try FileManager.default.removeItem(at: c.media.url(sha256: a.sha256, ext: a.ext))
        #expect(try height(m) == base)
    }

    @Test func quoteBoxIsOneLevelAndGoesWithTheQuote() throws {
        let inner = try tweet("самый внутренний")
        let quoted = try tweet("цитата")
        let main = try tweet("главный")
        let plain = try height(main)
        try c.memes.addRelation(Relation(from: main.id, to: quoted.id, kind: .quote))
        let withQuote = try height(main)
        #expect(withQuote > plain + 100)
        // The quote's own quote isn't drawn inside it.
        try c.memes.addRelation(Relation(from: quoted.id, to: inner.id, kind: .quote))
        #expect(try height(main) == withQuote)
        // A quote with media is drawn compact (no media).
        try attach(solid(800, 600, (9, 9, 9)), to: quoted.id, role: .media)
        #expect(try height(main) == withQuote)
        // Deleted quote → no box.
        _ = try c.deleteMemes([quoted.id])
        #expect(try height(main) == plain)
    }

    /// x.com long posts go up to 25,000 characters; Telegram's sendPhoto wants width + height ≤ 10,000,
    /// so the card's text stops at 90 lines.
    @Test func aMaximumLengthPostFitsTelegramPhotoLimits() throws {
        let s = String(repeating: "Длинный пост для подписчиков Premium, до двадцати пяти тысяч символов. ", count: 350)
        let m = try tweet(s)
        #expect(L.width + (try height(m)) <= 10_000)
    }

    @Test func aTweetLinkedAsItsOwnQuoteDoesNotRecurse() throws {
        let m = try tweet("self quote")
        try c.memes.addRelation(Relation(from: m.id, to: m.id, kind: .quote))
        #expect(try height(m) > 0)
    }
}
