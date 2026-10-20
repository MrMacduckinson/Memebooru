import Foundation
import Testing
@testable import MemebooruCore

@Suite struct SearchTests {
    @Test func parsesSyntax() {
        let q = Query.parse("2022 Stalin -ussr stal* \"обед со сталиным\" -\"bad\" - x")
        #expect(q.include == [.tag("2022"), .tag("stalin"), .glob("stal*"), .tag("x")])
        #expect(q.exclude == [.tag("ussr")])
        #expect(q.phrases == ["обед со сталиным", "bad"])
    }

    private func seeded() throws -> (TempCollection, Meme, Meme, Meme) {
        let t = try TempCollection()
        let c = t.collection
        try c.tags.create("telegram_message", kind: .meta)
        try c.tags.addAlias("tg_message", to: try c.tags.resolve("telegram_message")!)
        let a = Meme(kind: .image, createdAt: 3, textExact: "обед", textVerbatim: "обед")
        let b = Meme(kind: .image, createdAt: 2, textExact: "ужин со сталиным")
        let d = Meme(kind: .video, createdAt: 1)
        try c.memes.insert(a, tags: ["stalin", "child", "2022", "picture", "tg_message"])
        try c.memes.insert(b, tags: ["stalin", "ussr_flag", "2021", "picture"])
        try c.memes.insert(d, tags: ["cat", "video", "2022"])
        return (t, a, b, d)
    }

    @Test func tagsAndAliasesAndNegation() throws {
        let (t, a, b, d) = try seeded()
        let s = t.collection.search
        #expect(try s.search("stalin").memes.map(\.id) == [a.id, b.id])
        #expect(try s.search("2022").memes.map(\.id) == [a.id, d.id])
        #expect(try s.search("stalin 2022").memes.map(\.id) == [a.id])
        #expect(try s.search("stalin -child").memes.map(\.id) == [b.id])
        #expect(try s.search("tg_message").memes.map(\.id) == [a.id])          // alias
        #expect(try s.search("ussr*").memes.map(\.id) == [b.id])                // glob
        #expect(try s.search("-picture").memes.map(\.id) == [d.id])
        #expect(try s.search("").memes.count == 3)
        #expect(try s.search("nonexistent_tag").memes.isEmpty)
    }

    @Test func fullTextPhrasesAndFallback() throws {
        let (t, a, b, _) = try seeded()
        let s = t.collection.search
        #expect(try s.search("\"обед\"").memes.map(\.id) == [a.id])
        #expect(try s.search("сталиным").memes.map(\.id) == [b.id])            // unknown word → FTS
        #expect(try s.search("stalin \"ужин\"").memes.map(\.id) == [b.id])
        #expect(try s.search("\"со сталиным\"").memes.map(\.id) == [b.id])
    }

    @Test func paginates() throws {
        let (t, a, b, d) = try seeded()
        let p1 = try t.collection.search.search("", limit: 2)
        #expect(p1.memes.map(\.id) == [a.id, b.id])
        #expect(p1.next != nil)
        let p2 = try t.collection.search.search("", limit: 2, after: p1.next)
        #expect(p2.memes.map(\.id) == [d.id])
        #expect(p2.next == nil)
    }
}
