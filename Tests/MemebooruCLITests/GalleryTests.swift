import Foundation
import Testing
@testable import memebooru
import MemebooruCore

@Suite(.serialized) struct GalleryTests {
    @Test func explicitImportAndSafePublicExport() async throws {
        let c = try await CLICollection(), d = try TempDir()
        let data = try #require(try CLI.realPlatform.thumbs.encode(Samples.bitmap(.checker), as: .png, quality: 1))
        _ = try d.write("originals/image.png", data)
        let item = GalleryItem(url: "https://frutigeraeroarchive.org/images/wallpapers/test.png",
            sourcePage: "https://frutigeraeroarchive.org/wallpapers", title: "Public image", category: "test",
            file: "originals/image.png", sha256: MediaStore.sha256(of: data), bytes: Int64(data.count), width: 64, height: 64,
            tags: ["обои", "узор", "клетка", "монохромный"])
        let manifest = try d.write("tagged.json", JSONEncoder().encode(GalleryCatalogue(source: item.sourcePage, items: [item])))
        for file in ["index.html", "app.js", "style.css", "favicon.svg"] { try d.write("web/" + file, Data("test".utf8)) }
        var r = await c.run("gallery", "import", manifest.path)
        #expect(r.ok, "\(r)")
        let col = try c.open()
        #expect(try col.staging.count() == 1)
        #expect(try col.memes.count() == 0)
        r = await c.run("gallery", "import", manifest.path)
        #expect(r.ok)
        #expect(try col.staging.count() == 1)
        r = await c.run("gallery", "publish", manifest.path, "--output", d.path("public"), "--web", d.path("web"))
        #expect(!r.ok)
        #expect(!FileManager.default.fileExists(atPath: d.path("public")))
        _ = try col.commitStaged(col.staging.list())
        #expect(try col.tags.resolve("узор")?.kind == .normal)
        // A private item and private metadata in the same collection must never be exported.
        let privateItem = Meme(kind: .text, textVerbatim: "PRIVATE_SENTINEL")
        try col.memes.insert(privateItem, tags: ["private_tag"])
        let publicID = try #require(try col.memes.memes(withSHA256: item.sha256).first)
        try col.memes.addTag(publicID, "private_tag")
        r = await c.run("gallery", "publish", manifest.path, "--output", d.path("public"), "--web", d.path("web"))
        #expect(r.ok, "\(r)")
        #expect(try String(contentsOfFile: d.path("public/favicon.svg"), encoding: .utf8) == "test")
        let encoded = try String(contentsOfFile: d.path("public/catalogue.json"), encoding: .utf8)
        #expect(!encoded.contains("private_tag") && !encoded.contains("PRIVATE_SENTINEL"))
        let exported = try JSONDecoder().decode(GalleryCatalogue.self, from: Data(encoded.utf8))
        #expect(exported.items.count == 1)
        #expect(try Data(contentsOf: URL(fileURLWithPath: d.path("public/" + exported.items[0].file))) == data)
        for file in ["collection.db", "device.json", "staging"] { #expect(!FileManager.default.fileExists(atPath: d.path("public/" + file))) }
    }
    @Test func rejectTraversalAndChecksumMismatchBeforeImport() async throws {
        let c = try await CLICollection(), d = try TempDir()
        var item = GalleryItem(url: "https://frutigeraeroarchive.org/image.png", sourcePage: "https://frutigeraeroarchive.org/wallpapers",
            title: "image", category: "test", file: "../secret.png", sha256: String(repeating: "a", count: 64), bytes: 3, width: 1, height: 1, tags: ["обои"])
        #expect(throws: (any Error).self) { try Gallery.sourceFile(item, root: d.url) }
        item.file = "originals/image.png"; try d.write(item.file, Data([1, 2, 3]))
        let manifest = try d.write("tagged.json", JSONEncoder().encode(GalleryCatalogue(source: item.sourcePage, items: [item])))
        let r = await c.run("gallery", "import", manifest.path)
        #expect(!r.ok)
        #expect(try c.open().staging.count() == 0)
    }
}
