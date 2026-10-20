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
    let vendor = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Vendor/ffmpeg/bin")
    return PlatformApple.make(ffmpegDirs: [vendor])
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

private func close(_ a: (Int, Int, Int), _ b: (Int, Int, Int), _ tolerance: Int = 12) -> Bool {
    abs(a.0 - b.0) <= tolerance && abs(a.1 - b.1) <= tolerance && abs(a.2 - b.2) <= tolerance
}

@Suite(.serialized) struct TweetRenderTests {
    let c: Collection
    init() throws {
        c = try Collection.create(at: FileManager.default.temporaryDirectory.appendingPathComponent("tweet-render-\(UUID().uuidString).memebooru"))
    }

    @discardableResult
    private func attach(_ data: Data, ext: String, to meme: MemeID, role: Asset.Role, order: Int = 0) throws -> Asset {
        let f = try c.media.put(data: data, ext: ext)
        return try c.memes.addAsset(Asset(memeID: meme, role: role, sha256: f.sha256, ext: f.ext,
                                          mime: MediaType.detect(ext: ext)?.mime ?? "application/octet-stream", bytes: f.bytes, order: order))
    }

    private func tweet(_ text: String, author: String, handle: String, replyTo: String? = nil) throws -> Meme {
        let m = Meme(kind: .tweet, textVerbatim: text,
                     payload: .tweet(TweetPayload(tweetID: UUID().uuidString, url: "https://x.com/\(handle)/status/1", authorName: author,
                                                  handle: handle, postedAt: 1_700_000_000_000, replyToHandle: replyTo)))
        try c.memes.insert(m, tags: ["tweet"])
        return m
    }

    @Test func textWrapsAndTruncates() throws {
        let text = try #require(platform.text)
        let style = TextStyle(size: 32, color: 0x2C3635)
        let long = String(repeating: "Длинный текст с эмодзи 😂 ", count: 8)
        let one = try #require(try text.render("Привет 👋", style: style, width: 600))
        let many = try #require(try text.render(long, style: style, width: 600))
        let cut = try #require(try text.render(long, style: TextStyle(size: 32, color: 0x2C3635, maxLines: 1), width: 600))
        #expect(one.width <= 600 && many.width <= 600)
        #expect(many.height > one.height * 3)
        #expect(abs(cut.height - one.height) <= 4)
        #expect(try text.render("", style: style, width: 600) == nil)
        // Something is actually drawn, in the requested colour.
        let inked = stride(from: 3, to: one.rgba.count, by: 4).filter { one.rgba[$0] > 200 }
        #expect(!inked.isEmpty)
    }

    @Test func rendersTweetAndRedrawsOnlyWhenItChanges() throws {
        let quote = try tweet("Цитируемый твит", author: "Quoted Person", handle: "quoted")
        var main = try tweet("Кириллица, emoji 🔥😂 и перенос длинной строки, которая точно не влезет в одну строку карточки шириной 600 точек.",
                             author: "Мем Автор", handle: "meme_author", replyTo: "someone")
        try attach(try platform.thumbs.jpeg(solid(200, 200, (220, 40, 40)), quality: 0.9), ext: "jpg", to: main.id, role: .avatar)
        try attach(try platform.thumbs.jpeg(solid(800, 600, (40, 160, 40)), quality: 0.9), ext: "jpg", to: main.id, role: .media, order: 0)
        try attach(try platform.thumbs.jpeg(solid(600, 800, (40, 40, 200)), quality: 0.9), ext: "jpg", to: main.id, role: .media, order: 1)
        if let ff = platform.transcoder as? FFmpegTranscoder {
            let clip = FileManager.default.temporaryDirectory.appendingPathComponent("render-clip-\(UUID().uuidString).mp4")
            try ff.runFFmpeg(["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=s=320x240:d=1:r=10", "-c:v", "mpeg4", clip.path])
            try attach(try Data(contentsOf: clip), ext: "mp4", to: main.id, role: .media, order: 2)
        }
        try c.memes.addRelation(Relation(from: main.id, to: quote.id, kind: .quote))

        let first = try #require(try c.tweetRender(main, analyzer: analyzer))
        #expect(first.role == .render && first.width == 1200)
        #expect((first.height ?? 0) > 900)          // header, 3 lines, reply, 2-row grid, quote, date
        let url = c.media.url(sha256: first.sha256, ext: first.ext)
        if let out = ProcessInfo.processInfo.environment["MEMEBOORU_TEST_RENDER_OUT"] {
            try? FileManager.default.removeItem(atPath: out)
            try FileManager.default.copyItem(at: url, to: URL(fileURLWithPath: out))
        }
        let picture = try platform.images.decode(url, maxSide: 0)
        #expect(close(pixel(picture, 32 + 44, 32 + 44), (220, 40, 40)))   // avatar centre (pad 16pt, avatar 44pt, 2x)
        #expect(close(pixel(picture, 2, 2), (0xFB, 0xFC, 0xFA)))            // paper

        // Unchanged → the stored picture is reused, not drawn again.
        let again = try #require(try c.tweetRender(main, analyzer: analyzer))
        #expect(again.id == first.id && again.sha256 == first.sha256)

        // Quote gone → redrawn, shorter.
        try c.memes.removeRelation(from: main.id, to: quote.id, kind: .quote)
        let noQuote = try #require(try c.tweetRender(main, analyzer: analyzer))
        #expect(noQuote.sha256 != first.sha256 && (noQuote.height ?? 0) < (first.height ?? 0))

        // Text edited → redrawn; looking only (render: false) hands back the stale one.
        main.textVerbatim = "Другой текст"
        try c.memes.update(main)
        let stale = try #require(try c.tweetRender(main, analyzer: analyzer, render: false))
        #expect(stale.sha256 == noQuote.sha256)
        let redrawn = try #require(try c.tweetRender(main, analyzer: analyzer))
        #expect(redrawn.sha256 != noQuote.sha256)
        #expect(try c.memes.assets(of: main.id).filter { $0.role == .render }.count == 1)
    }

    @Test func nonTweetsHaveNoRender() throws {
        let m = Meme(kind: .text, textVerbatim: "hello")
        try c.memes.insert(m)
        #expect(try c.tweetRender(m, analyzer: analyzer) == nil)
    }
}
