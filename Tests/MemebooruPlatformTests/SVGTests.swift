import Foundation
import Testing
import MemebooruCore
import CNanoSVG
@testable import MemebooruBot
#if canImport(ImageIO)
import MemebooruPlatformApple
#endif
#if os(Linux)
import MemebooruPlatformLinux
#endif

private func platform() -> Platform {
    #if canImport(ImageIO)
    return PlatformApple.make()
    #else
    return PlatformLinux.make()
    #endif
}

/// 200×100, transparent background, a pure red square on the left and pure blue on the right.
private let sample = """
    <svg xmlns="http://www.w3.org/2000/svg" width="200" height="100" viewBox="0 0 200 100">
      <rect x="10" y="10" width="80" height="80" fill="#ff0000"/>
      <rect x="110" y="10" width="80" height="80" fill="#0000ff"/>
    </svg>
    """

private func writeSample() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sample-\(UUID().uuidString).svg")
    try sample.write(to: url, atomically: true, encoding: .utf8)
    return url
}

private func pixel(_ b: Bitmap, _ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
    let i = (y * b.width + x) * 4
    return (b.rgba[i], b.rgba[i + 1], b.rgba[i + 2])
}

@Suite struct SVGTests {
    /// The iOS path (no public SVG reader in UIKit): nanosvg keeps the size and the colours.
    @Test func nanosvgRendersSample() throws {
        let url = try writeSample()
        defer { try? FileManager.default.removeItem(at: url) }
        var w: Float = 0, h: Float = 0
        #expect(cnanosvg_size(url.path, &w, &h) == 0)
        #expect(w == 200 && h == 100)
        var pw: Int32 = 0, ph: Int32 = 0
        let pixels = try #require(cnanosvg_render(url.path, 400, &pw, &ph))
        defer { free(pixels) }
        #expect(pw == 400 && ph == 200)
        let b = Bitmap(width: Int(pw), height: Int(ph), rgba: Data(bytes: pixels, count: Int(pw * ph) * 4))
        #expect(pixel(b, 100, 100) == (255, 0, 0))
        #expect(pixel(b, 300, 100) == (0, 0, 255))
        #expect(b.rgba[(5 * b.width + 5) * 4 + 3] == 0)   // margin stays transparent
    }

    @Test func svgIsAnImageKind() {
        #expect(MediaType.detect(ext: "svg")?.kind == .image)
        #expect(MediaType.detect(ext: "SVG")?.mime == "image/svg+xml")
    }

    @Test func sizeComesFromTheSVG() throws {
        let url = try writeSample(); defer { try? FileManager.default.removeItem(at: url) }
        let (w, h) = try platform().images.imageSize(url)
        #expect(w == 200 && h == 100)
    }

    /// Rasterised to fit maxSide (vectors scale up), on white, colours where the shapes are.
    @Test func rasterisesOnWhiteAtRequestedSize() throws {
        let url = try writeSample(); defer { try? FileManager.default.removeItem(at: url) }
        let b = try platform().images.decode(url, maxSide: 400)
        #expect(b.width == 400 && b.height == 200)
        let bg = pixel(b, 2, 2), red = pixel(b, 100, 100), blue = pixel(b, 300, 100)
        #expect(bg.0 > 240 && bg.1 > 240 && bg.2 > 240)
        #expect(red.0 > 200 && red.1 < 60 && red.2 < 60)
        #expect(blue.2 > 200 && blue.0 < 60 && blue.1 < 60)
    }

    @Test func analyzerGivesSizeHashesAndThumbnail() throws {
        let url = try writeSample(); defer { try? FileManager.default.removeItem(at: url) }
        let analyzer = MediaAnalyzer(platform: platform())
        let info = analyzer.analyze(url, kind: .image)
        #expect(info.width == 200 && info.height == 100 && info.phash != nil && info.dhash != nil)
        let jpeg = try #require(try analyzer.thumbnail(url, kind: .image))
        #expect(jpeg.starts(with: [0xFF, 0xD8]))
    }

    /// SVG is an uncommon format: by default it's shown as a PNG, and the vector is kept as the original.
    @Test func importedSVGBecomesPNGWithTheVectorKept() throws {
        let url = try writeSample(); defer { try? FileManager.default.removeItem(at: url) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("svg-\(UUID().uuidString).memebooru")
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = try Collection.create(at: dir)
        let staging = StagingArea(collection: c, analyzer: MediaAnalyzer(platform: platform()))
        let item = try staging.add(file: url, source: "test")
        #expect(item.compatibility == .uncommon && item.popularTarget == .png && item.willKeepOriginal)
        let meme = try staging.commit(item.id)
        let (primary, original) = try c.formats(of: meme.id)
        let p = try #require(primary), o = try #require(original)
        #expect(meme.kind == .image && p.ext == "png" && p.width == 200 && p.sourceLabel == "SVG")
        #expect(o.ext == "svg" && o.mime == "image/svg+xml" && o.width == 200)
        #expect(FileManager.default.fileExists(atPath: c.media.thumbURL(sha256: p.sha256).path))
        #expect(try c.search.search("picture").memes.count == 1)
    }

    /// Kept as SVG only (conversion declined): still an image meme with size and thumbnail.
    @Test func svgKeptAsIs() throws {
        let url = try writeSample(); defer { try? FileManager.default.removeItem(at: url) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("svg-\(UUID().uuidString).memebooru")
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = try Collection.create(at: dir)
        let staging = StagingArea(collection: c, analyzer: MediaAnalyzer(platform: platform()))
        let meme = try staging.commit(try staging.add(file: url, source: "test").id, convert: false)
        let p = try #require(try c.memes.primaryAsset(of: meme.id))
        #expect(p.ext == "svg" && p.width == 200 && p.compatibility(kind: .image) == .uncommon)
        #expect(FileManager.default.fileExists(atPath: c.media.thumbURL(sha256: p.sha256).path))
    }
}

/// Records uploads only; enough for the inline path.
private final class UploadRecorder: TelegramAPI, @unchecked Sendable {
    var uploads: [(kind: TGMediaKind, name: String, head: [UInt8])] = []
    var results: [TGInlineResult] = []
    func getUpdates(offset: Int64?, timeout: Int) async throws -> [TGUpdate] { [] }
    func sendMessage(chatID: Int64, text: String, replyTo: Int?) async throws -> TGMessage { TGMessage(messageId: 1, from: nil, chat: TGChat(id: chatID, type: "private", title: nil, username: nil), date: 0) }
    func sendMedia(_ kind: TGMediaKind, chatID: Int64, file: URL, silent: Bool) async throws -> TGMessage {
        uploads.append((kind, file.lastPathComponent, Array(try Data(contentsOf: file).prefix(2))))
        let m = TGMessage(messageId: 7, from: nil, chat: TGChat(id: chatID, type: "private", title: nil, username: nil), date: 0)
        var f = TGFileRef(fileId: "P"); f.width = 10; f.height = 10
        m.photo = [f]
        return m
    }
    func deleteMessage(chatID: Int64, messageID: Int) async throws {}
    func answerInlineQuery(id: String, results: [TGInlineResult], nextOffset: String?, cacheTime: Int, emptyButton: String?) async throws { self.results = results }
    func setCommands(_ commands: [TGCommand]) async throws {}
    func getFile(fileID: String) async throws -> TGFile { throw TelegramError("n/a") }
    func download(filePath: String) async throws -> Data { throw TelegramError("n/a") }
}

extension SVGTests {
    @Test func botSendsSVGAsARenderedPhoto() async throws {
        let url = try writeSample(); defer { try? FileManager.default.removeItem(at: url) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("svgbot-\(UUID().uuidString).memebooru")
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = try Collection.create(at: dir)
        let analyzer = MediaAnalyzer(platform: platform())
        let staging = StagingArea(collection: c, analyzer: analyzer)
        _ = try staging.commit(try staging.add(file: url, source: "test", extraTags: ["vector"]).id, convert: false)   // SVG only

        let api = UploadRecorder()
        let bot = MemeBot(api: api, collection: c, analyzer: analyzer, config: BotConfig(allowedUsers: [1]))
        await bot.handle(TGUpdate(updateId: 1, inlineQuery: TGInlineQuery(id: "q", from: TGUser(id: 1, firstName: nil, username: nil), query: "vector")))
        #expect(api.uploads.count == 1)
        #expect(api.uploads.first?.kind == .photo && api.uploads.first?.name.hasSuffix(".png") == true)
        #expect(api.uploads.first?.head == [0x89, 0x50])                    // really a PNG (SVG's popular format), not the SVG
        #expect(api.results.first?.type == "photo" && api.results.first?.photoFileId == "P")
    }
}
