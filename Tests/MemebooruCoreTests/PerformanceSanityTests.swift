import Foundation
import Testing
@testable import MemebooruCore

/// Generous time bounds (debug build, shared CI box): these catch accidental O(n²) / per-row queries,
/// not micro-regressions.
@Suite(.serialized) struct PerformanceSanityTests {
    private func seconds(_ body: () throws -> Void) rethrows -> Double {
        let start = ContinuousClock.now
        try body()
        let d = ContinuousClock.now - start
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    /// `prefix` + zero-padded number (no `String(format:)` varargs, same on every platform).
    private func pad(_ prefix: String, _ n: Int, _ width: Int, radix: Int = 10) -> String {
        let s = String(n, radix: radix)
        return prefix + String(repeating: "0", count: max(0, width - s.count)) + s
    }

    @Test(.timeLimit(.minutes(2))) func tenThousandStagedItems() throws {
        let t = try TempCollection()
        let c = t.collection
        // Rows are written directly (copying 10k files would only measure the disk).
        try c.db.transaction {
            for i in 0..<10_000 {
                try c.db.run("""
                    INSERT INTO staged(id, kind, source, original_name, sha256, ext, mime, bytes, phash, suggested_tags, user_tags, added_at, parent_id)
                    VALUES (?, 'image', 'perf', ?, ?, 'jpg', 'image/jpeg', 1, ?, '["2022","picture"]', '["cat"]', ?, NULL)
                    """, [pad("s", i, 5), "f\(i).jpg", pad("", i, 64, radix: 16), Int64(i &* 2_654_435_761), Int64(i)])
            }
            for i in 0..<2_000 {      // chain tweets riding along with the first 200 items
                try c.db.run("""
                    INSERT INTO staged(id, kind, source, sha256, ext, mime, bytes, suggested_tags, user_tags, added_at, parent_id)
                    VALUES (?, 'tweet', 'perf', ?, 'json', 'application/json', 1, '["chain"]', '[]', ?, ?)
                    """, [pad("c", i, 5), pad("c", i, 63, radix: 16), Int64(i), pad("s", i / 10, 5)])
            }
        }
        var items: [StagedItem] = []
        let listTime = try seconds { items = try c.staging.list() }
        var n = 0
        let countTime = try seconds { n = try c.staging.count() }
        #expect(items.count == 10_000 && n == 10_000)
        #expect(items.first?.id == "s00000" && items.last?.id == "s09999")
        #expect(items.allSatisfy { $0.parentID == nil })
        #expect(listTime < 5, "list() took \(listTime)s")
        #expect(countTime < 0.5, "count() took \(countTime)s")
        let chainTime = try seconds { for i in 0..<200 { _ = try c.staging.chain(of: pad("s", i, 5)) } }
        #expect(chainTime < 2, "200 × chain(of:) took \(chainTime)s")
        let dupTime = try seconds { _ = try c.staging.duplicates(of: items[5_000]) }
        #expect(dupTime < 3, "duplicates(of:) took \(dupTime)s")
    }

    @Test(.timeLimit(.minutes(3))) func searchOverFiveThousandMemes() throws {
        let t = try TempCollection()
        let c = t.collection
        var rng = SeededRNG(seed: 5_000)
        let tags = (0..<60).map { "tag\($0)" } + ["stalin", "сталин", "🐸", "2022", "2023"]
        let words = ["обед", "ужин", "штирлиц", "plan", "zebra", "мем", "кот", "dog", "lorem", "ipsum"]
        let insertTime = try seconds {
            try c.db.transaction {
                for i in 0..<5_000 {
                    let text = (0..<5).map { _ in words.randomElement(using: &rng)! }.joined(separator: " ")
                    let picks = (0..<4).map { _ in tags.randomElement(using: &rng)! }
                    try c.memes.insert(Meme(kind: .image, createdAt: Int64(i / 3), textExact: text), tags: picks)
                }
            }
        }
        #expect(insertTime < 60, "inserting 5k memes took \(insertTime)s")
        #expect(try c.memes.count() == 5_000)

        let queries = ["", "stalin", "tag1 tag2", "-tag3", "tag*", "обед", "\"обед ужин\"", "stalin -2022 штир", "🐸 сталин", "nothing_matches_this"]
        for q in queries {
            var page: SearchPage!
            let time = try seconds { page = try c.search.search(q, limit: 60) }
            #expect(time < 2, "search \(q.debugDescription) took \(time)s")
            #expect(page.memes.count <= 60)
        }
        // Walking all pages of the broadest query.
        var seen = 0, cursor: MemeCursor?
        let walk = try seconds {
            repeat {
                let p = try c.search.search("", limit: 200, after: cursor)
                seen += p.memes.count; cursor = p.next
            } while cursor != nil
        }
        #expect(seen == 5_000)
        #expect(walk < 10, "paging through 5k took \(walk)s")
        let suggestTime = try seconds { for p in ["t", "ta", "tag", "с", "🐸", ""] { _ = try c.tags.suggest(prefix: p) } }
        #expect(suggestTime < 3, "suggest took \(suggestTime)s")
    }
}
