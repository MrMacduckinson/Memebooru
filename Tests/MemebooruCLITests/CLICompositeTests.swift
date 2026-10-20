import Foundation
import Testing
@testable import memebooru
@testable import MemebooruCore

/// `stage combine / relayout / split`: several pictures sent as one meme, kept as one.
@Suite(.serialized) struct CLICompositeTests {
    private func stagedIDs(_ c: CLICollection) async throws -> [String: String] {
        let ls = await c.run("stage", "ls")
        var ids: [String: String] = [:]
        for line in ls.lines.dropLast() { if let r = line.range(of: "← ") { ids[String(line[r.upperBound...]).components(separatedBy: "  ")[0]] = String(line.prefix(8)) } }
        return ids
    }

    @Test func combineRelayoutCommitAndRelayoutAgain() async throws {
        let c = try await CLICollection()
        let d = try TempDir()
        for (name, p) in [("панель 1.png", Samples.Pattern.horizontal), ("панель 2.png", .vertical), ("панель 3.png", .checker)] {
            try d.write("in/\(name)", try Samples.png(p))
        }
        var r = await c.run("add", d.path("in"), "-t", "комикс")
        #expect(r.ok, "\(r)")
        let ids = try await stagedIDs(c)
        let (a, b, x) = (try #require(ids["панель 1.png"]), try #require(ids["панель 2.png"]), try #require(ids["панель 3.png"]))

        r = await c.run("stage", "combine", a)
        #expect(r.code == 64 && r.err.contains("at least two"), "\(r)")
        r = await c.run("stage", "combine", a, b, x, "--layout", "spiral")
        #expect(r.code == 64, "\(r)")
        r = await c.run("stage", "combine", a, b, x, "--layout", "grid", "--columns", "0")
        #expect(r.code == 64 && r.err.contains("--columns"), "\(r)")

        r = await c.run("stage", "combine", a, b, x, "--layout", "column", "--gap", "4")
        #expect(r.ok && r.out.hasPrefix("✓ ") && r.out.contains("3 pictures, column, 64×200") && r.out.contains("combined"), "\(r)")
        let cid = String(r.out.dropFirst(2).prefix(8))
        r = await c.run("stage", "ls")
        #expect(r.out.contains("1 staged") && r.out.contains("комикс"), "\(r)")

        // 32 px is below the smallest allowed shared side (64): kept at 64, so three 64-px squares in a row.
        r = await c.run("stage", "relayout", cid, "--layout", "row", "--size", "32", "--order", "3", "1", "2")
        #expect(r.ok && r.out.contains("192×64"), "\(r)")
        r = await c.run("stage", "relayout", cid, "--order", "1", "1", "2")
        #expect(r.code != 0 && r.err.contains("every picture once"), "\(r)")

        r = await c.run("stage", "commit", cid)
        #expect(r.ok && r.out.contains("[combined]"), "\(r)")
        let col = try c.open()
        let meme = try #require(try col.search.search("combined").memes.first)
        #expect(try col.parts(of: meme.id).count == 3)
        r = await c.run("stage", "relayout", String(meme.id.rawValue.prefix(8)), "--layout", "grid", "--columns", "2")
        #expect(r.ok && r.out.contains(meme.id.rawValue), "\(r)")
        #expect(try c.open().memes.get(meme.id)?.payload.composite?.layout == CompositeLayout(.grid, columns: 2))
    }

    @Test func splitAndUndo() async throws {
        let c = try await CLICollection()
        let d = try TempDir()
        try d.write("in/a.png", try Samples.png(.rings)); try d.write("in/b.png", try Samples.png(.checker))
        _ = await c.run("add", d.path("in"))
        let ids = try await stagedIDs(c)
        var r = await c.run("stage", "combine", try #require(ids["a.png"]), try #require(ids["b.png"]))
        #expect(r.ok, "\(r)")
        let cid = String(r.out.dropFirst(2).prefix(8))
        r = await c.run("stage", "split", cid)
        #expect(r.ok && r.out.hasPrefix("✓ split into 2"), "\(r)")
        r = await c.run("stage", "ls")
        #expect(r.out.contains("2 staged") && r.out.contains("a 1.png") && r.out.contains("a 2.png"), "\(r)")
        r = await c.run("undo")
        #expect(r.ok, "\(r)")
        r = await c.run("stage", "ls")
        #expect(r.out.contains("1 staged") && r.out.contains("a +1.png"), "\(r)")
        r = await c.run("stage", "split", "nothere")
        #expect(r.code != 0, "\(r)")
    }

    @Test func onlyCombinedPicturesRelayout() async throws {
        let c = try await CLICollection()
        let d = try TempDir()
        try d.write("in/a.png", try Samples.png(.rings))
        _ = await c.run("add", d.path("in"))
        let id = try #require(try await stagedIDs(c)["a.png"])
        let r = await c.run("stage", "relayout", id, "--layout", "row")
        #expect(r.code != 0 && r.err.contains("not a combined picture"), "\(r)")
    }
}
