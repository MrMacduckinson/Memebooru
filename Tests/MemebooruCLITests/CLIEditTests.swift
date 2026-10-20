import Foundation
import Testing
@testable import memebooru
@testable import MemebooruCore

/// `stage edit`: crop borders / trim quiet ends, for staged items and saved posts.
@Suite(.serialized) struct CLIEditTests {
    /// A 64×64 checkerboard inside a 24-px white margin.
    private func framed(_ d: TempDir) throws -> URL {
        let inner = Samples.bitmap(.checker)
        let w = 112, h = 112
        var px = Data(repeating: 255, count: w * h * 4)
        for y in 0..<64 { for x in 0..<64 {
            let s = (y * 64 + x) * 4, t = ((y + 24) * w + x + 24) * 4
            for k in 0..<4 { px[t + k] = inner.rgba[s + k] }
        } }
        let data = try #require(try CLI.realPlatform.thumbs.encode(Bitmap(width: w, height: h, rgba: px), as: .png, quality: 1))
        return try d.write("in/framed.png", data)
    }

    @Test func autoCropManualCropResetAndPosts() async throws {
        let c = try await CLICollection()
        let d = try TempDir()
        _ = try framed(d)
        _ = await c.run("add", d.path("in"))
        let ls = await c.run("stage", "ls")
        let id = String(try #require(ls.lines.first).prefix(8))

        var r = await c.run("stage", "edit", id)
        #expect(r.code == 64 && r.err.contains("say what to do"), "\(r)")
        r = await c.run("stage", "edit", id, "--crop", "1,2,3")
        #expect(r.code == 64, "\(r)")
        r = await c.run("stage", "edit", id, "--trim", "2-1")
        #expect(r.code == 64, "\(r)")
        r = await c.run("stage", "edit", id, "--reset", "--auto-crop")
        #expect(r.code == 64, "\(r)")
        r = await c.run("stage", "edit", id, "--auto-trim")
        #expect(r.code != 0 && r.err.contains("can't be trimmed"), "\(r)")

        r = await c.run("stage", "edit", id, "--auto-crop")
        #expect(r.ok && r.out.contains("keeping 64×64 at 24,24") && r.out.contains("✓ \(id)  64×64"), "\(r)")
        r = await c.run("stage", "edit", id, "--crop", "0,0,112,50")
        #expect(r.ok && r.out.contains("112×50"), "\(r)")
        r = await c.run("stage", "edit", id, "--reset")
        #expect(r.ok && r.out.contains("112×112") && r.out.contains("(original)"), "\(r)")

        // The same on a saved post, which keeps its original from the first edit on.
        r = await c.run("stage", "edit", id, "--auto-crop")
        r = await c.run("stage", "commit", id)
        #expect(r.ok, "\(r)")
        let col = try c.open()
        let meme = try #require(try col.search.search("").memes.first)
        #expect(try col.formats(of: meme.id).original != nil)
        r = await c.run("stage", "edit", String(meme.id.rawValue.prefix(8)), "--reset")
        #expect(r.ok && r.out.contains("112×112"), "\(r)")
    }
}
