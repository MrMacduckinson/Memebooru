import Foundation
import Testing
@testable import MemebooruCore

/// QueryExecutor against a real collection: odd input, unicode, aliases, injection, wildcards.
@Suite struct SearchEdgeTests {
    /// a: stalin/2022/@durov/source_unknown, text "обед 100% chance"
    /// b: Сталин (cyrillic tag)/🐸/ussr_flag, text "ужин_со_сталиным and 50_50"
    /// d: cat/2022, no text. e: deleted, has every tag.
    struct Seed {
        let t: TempCollection
        let a: Meme, b: Meme, d: Meme, e: Meme
        var c: Collection { t.collection }
    }

    func seeded() throws -> Seed {
        let t = try TempCollection()
        let c = t.collection
        let a = Meme(kind: .image, createdAt: 40, textExact: "обед 100% chance", context: "O'Reilly said \"hi\"")
        let b = Meme(kind: .image, createdAt: 30, textExact: "ужин_со_сталиным and 50_50")
        let d = Meme(kind: .video, createdAt: 20)
        let e = Meme(kind: .image, createdAt: 10, textExact: "обед удалён")
        try c.memes.insert(a, tags: ["stalin", "2022", "@durov", "source_unknown"])
        try c.memes.insert(b, tags: ["Сталин", "🐸", "ussr_flag"])
        try c.memes.insert(d, tags: ["cat", "2022"])
        try c.memes.insert(e, tags: ["stalin", "Сталин", "🐸", "cat", "2022", "@durov", "source_unknown", "ussr_flag"])
        try c.memes.delete(e.id)
        return Seed(t: t, a: a, b: b, d: d, e: e)
    }

    @Test func blankQueriesReturnEverythingLive() throws {
        let s = try seeded()
        for q in ["", "   ", "\t\n", "\"\"", "-", " - "] {
            #expect(try s.c.ids(q) == [s.a.id, s.b.id, s.d.id], "query \(q.debugDescription)")
        }
    }

    @Test func tagsAreCaseInsensitive() throws {
        let s = try seeded()
        #expect(try s.c.ids("STALIN") == [s.a.id])
        #expect(try s.c.ids("СТАЛИН") == [s.b.id])
        #expect(try s.c.ids("сТаЛиН") == [s.b.id])
        #expect(try s.c.ids("Source_Unknown") == [s.a.id])
    }

    @Test func specialTagNames() throws {
        let s = try seeded()
        #expect(try s.c.ids("@durov") == [s.a.id])
        #expect(try s.c.ids("@DUROV") == [s.a.id])
        #expect(try s.c.ids("🐸") == [s.b.id])
        #expect(try s.c.ids("2022") == [s.a.id, s.d.id])
        #expect(try s.c.ids("2022 -cat") == [s.a.id])
        #expect(try s.c.ids("source_unknown") == [s.a.id])
        #expect(try s.c.ids("ussr_flag") == [s.b.id])
    }

    @Test func aliasesResolveEverywhere() throws {
        let s = try seeded()
        let cat = try #require(try s.c.tags.resolve("cat"))
        try s.c.tags.addAlias("Кот", to: cat)
        try s.c.tags.addAlias("neko", to: cat)
        #expect(try s.c.ids("кот") == [s.d.id])
        #expect(try s.c.ids("КОТ") == [s.d.id])
        #expect(try s.c.ids("2022 -neko") == [s.a.id])
        #expect(try s.c.ids("ne*") == [s.d.id])                       // globs see aliases too
        #expect(try s.c.ids("-ne*") == [s.a.id, s.b.id])
    }

    @Test func deletedMemesNeverShowUp() throws {
        let s = try seeded()
        for q in ["", "stalin", "сталин", "🐸", "cat", "2022", "@durov", "\"обед\"", "обед", "удалён", "*", "-nothing", "ussr*"] {
            #expect(try !s.c.ids(q).contains(s.e.id), "query \(q)")
        }
        #expect(try s.c.ids("удалён").isEmpty)
    }

    @Test func unknownTagsExcludedAreIgnored() throws {
        let s = try seeded()
        #expect(try s.c.ids("-no_such_tag") == [s.a.id, s.b.id, s.d.id])
    }

    @Test func unknownWordFallsBackToTextPrefix() throws {
        let s = try seeded()
        #expect(try s.c.ids("обе") == [s.a.id])                       // prefix match
        #expect(try s.c.ids("ОБЕД") == [s.a.id])                      // FTS is case-insensitive for Cyrillic too
        #expect(try s.c.ids("chance") == [s.a.id])
        #expect(try s.c.ids("reilly") == [s.a.id])                    // context is searched as well
    }

    @Test func exactPhrase() throws {
        let s = try seeded()
        #expect(try s.c.ids("\"обед 100\"") == [s.a.id])
        #expect(try s.c.ids("\"100 обед\"").isEmpty)                  // order matters
        #expect(try s.c.ids("\"said \"").isEmpty == false)
    }

    @Test func quotesInsideWordsDoNotBreakSearch() throws {
        // A word containing `"` can't be a tag name; it must not make the search throw.
        let s = try seeded()
        #expect(try s.c.ids("a\"b").isEmpty)
        #expect(try s.c.ids("stalin don\"t").isEmpty)
        #expect(try s.c.ids("-a\"b") == [s.a.id, s.b.id, s.d.id])
    }

    @Test func dashWordsDoNotBreakSearch() throws {
        let s = try seeded()
        #expect(try s.c.ids("--x") == [s.a.id, s.b.id, s.d.id])     // excluding a non-tag excludes nothing
        #expect(try s.c.ids("stalin --") == [s.a.id])
    }

    @Test func sqlInjectionLookingInputIsHarmless() throws {
        let s = try seeded()
        let evil = ["'; DROP TABLE meme; --", "\" OR 1=1 --", "') OR ('1'='1", "stalin' OR '1'='1", "*/ DELETE FROM meme_tag; /*",
                    "\"; DROP TABLE meme; --\"", "NEAR(a b)", "a OR b", "a AND NOT b", "col:val", "^x", "{a b}"]
        for q in evil {
            let hits = try s.c.ids(q)
            #expect(!hits.contains(s.e.id), "query \(q)")
            #expect(hits.count <= 3, "query \(q)")
        }
        #expect(try s.c.memes.count() == 3)
        #expect(try s.c.db.scalarInt("SELECT count(*) FROM meme_tag") > 0)
        #expect(try s.c.ids("stalin") == [s.a.id])
    }

    @Test func injectionTextStoredInAMemeIsFoundLiterally() throws {
        let t = try TempCollection()
        let m = Meme(kind: .text, textVerbatim: "Robert'); DROP TABLE meme;--")
        try t.collection.memes.insert(m)
        #expect(try t.collection.ids("\"robert'); drop table meme;--\"") == [m.id])
        #expect(try t.collection.ids("robert") == [m.id])
        #expect(try t.collection.memes.count() == 1)
    }

    @Test func likeWildcardsAreNotWildcards() throws {
        // Text search is FTS (not LIKE): `%` and `_` never act as "anything".
        let s = try seeded()
        #expect(try !s.c.ids("%").contains(s.d.id))
        #expect(try !s.c.ids("_").contains(s.d.id))
        #expect(try !s.c.ids("\"%\"").contains(s.d.id))
        #expect(try s.c.ids("\"%\"").count < 3)
        #expect(try s.c.ids("_%_").count < 3)
        // `_` is a separator for the text tokenizer, so "50_50" is the words 50, 50.
        #expect(try s.c.ids("\"50 50\"") == [s.b.id])
    }

    @Test func tagNamesWithLikeWildcardsMatchLiterally() throws {
        let t = try TempCollection()
        let c = t.collection
        let pct = Meme(kind: .image, createdAt: 2), us = Meme(kind: .image, createdAt: 1)
        try c.memes.insert(pct, tags: ["100%"])
        try c.memes.insert(us, tags: ["a_b"])
        try c.memes.insert(Meme(kind: .image, createdAt: 0), tags: ["1000", "axb"])
        #expect(try c.ids("100%") == [pct.id])
        #expect(try c.ids("a_b") == [us.id])
        #expect(try c.tags.suggest(prefix: "100%").map(\.text) == ["100%"])
        #expect(try c.tags.suggest(prefix: "a_").map(\.text) == ["a_b"])
    }

    @Test func globWithAllStarMatchesAnyTaggedMeme() throws {
        let s = try seeded()
        let untagged = Meme(kind: .image, createdAt: 5)
        try s.c.memes.insert(untagged)
        #expect(try s.c.ids("*") == [s.a.id, s.b.id, s.d.id])
        #expect(try s.c.ids("-*") == [untagged.id])
        #expect(try s.c.ids("*🐸*") == [s.b.id])
        #expect(try s.c.ids("@*") == [s.a.id])
    }

    @Test func veryLongQueries() throws {
        let s = try seeded()
        // Thousands of unknown words: one FTS expression, no error, no hits.
        let unknown = (0..<2_000).map { "zz\($0)" }.joined(separator: " ")
        #expect(try s.c.ids(unknown).isEmpty)
        // The same known tag over and over still means just that tag.
        let repeated = Array(repeating: "stalin", count: 2_000).joined(separator: " ")
        #expect(try s.c.ids(repeated) == [s.a.id])
        let excluded = Array(repeating: "-cat", count: 2_000).joined(separator: " ")
        #expect(try s.c.ids(excluded) == [s.a.id, s.b.id])
        // A huge single word.
        #expect(try s.c.ids(String(repeating: "я", count: 50_000)).isEmpty)
        #expect(try s.c.ids("\"" + String(repeating: "x ", count: 20_000) + "\"").isEmpty)
    }

    @Test func countMatchesSearch() throws {
        let s = try seeded()
        for q in ["", "2022", "stalin", "-cat", "обед", "*"] {
            #expect(try s.c.search.count(Query.parse(q)) == s.c.ids(q).count)
        }
    }
}

// MARK: - Pagination

@Suite struct SearchPaginationTests {
    func pages(_ c: Collection, _ q: String, limit: Int) throws -> [[MemeID]] {
        var out: [[MemeID]] = []
        var cursor: MemeCursor?
        repeat {
            let p = try c.search.search(q, limit: limit, after: cursor)
            out.append(p.memes.map(\.id))
            cursor = p.next
            if out.count > 10_000 { Issue.record("runaway pagination"); break }
        } while cursor != nil
        return out
    }

    @Test(arguments: [1, 2, 3, 7, 10, 49, 50, 51, 500])
    func noDuplicatesNoGapsWithTiedTimestamps(limit: Int) throws {
        let t = try TempCollection()
        let c = t.collection
        // Many memes share a created_at → ordering falls back to id.
        for i in 0..<50 { try c.memes.insert(Meme(kind: .image, createdAt: Int64(i / 7)), tags: ["x"]) }
        let all = try c.ids("x")
        let paged = try pages(c, "x", limit: limit)
        #expect(paged.flatMap { $0 } == all)
        #expect(Set(all).count == 50)
        #expect(paged.dropLast().allSatisfy { $0.count == limit })
        #expect(paged.last?.isEmpty == false || all.isEmpty)
    }

    @Test func exactMultipleOfLimitHasNoTrailingEmptyPage() throws {
        let t = try TempCollection()
        for i in 0..<6 { try t.collection.memes.insert(Meme(kind: .image, createdAt: Int64(i))) }
        let p = try pages(t.collection, "", limit: 3)
        #expect(p.map(\.count) == [3, 3])
    }

    @Test func emptyResultHasNoCursor() throws {
        let t = try TempCollection()
        let p = try t.collection.search.search("nothing_here", limit: 10)
        #expect(p.memes.isEmpty && p.next == nil)
        let z = try t.collection.search.search("", limit: 0)
        #expect(z.memes.isEmpty && z.next == nil)
    }

    @Test func stableWhenMemesAreAddedOrDeletedMidPagination() throws {
        let t = try TempCollection()
        let c = t.collection
        var original: [MemeID] = []
        for i in 0..<30 {
            let m = Meme(kind: .image, createdAt: 1_000 + Int64(i))
            try c.memes.insert(m, tags: ["p"]); original.append(m.id)
        }
        original.reverse()                                       // newest first
        var seen: [MemeID] = []
        var cursor: MemeCursor?
        var round = 0
        repeat {
            let p = try c.search.search("p", limit: 4, after: cursor)
            seen += p.memes.map(\.id)
            cursor = p.next
            round += 1
            // Meanwhile: a new upload (newer than everything) and a delete of an already-shown meme.
            try c.memes.insert(Meme(kind: .image, createdAt: 10_000 + Int64(round)), tags: ["p"])
            if let shown = p.memes.first { try c.memes.delete(shown.id) }
        } while cursor != nil
        #expect(seen == original)                                 // no dupes, no gaps, no newcomers
    }

    @Test func memeInsertedBehindTheCursorAppearsExactlyOnce() throws {
        let t = try TempCollection()
        let c = t.collection
        for i in 0..<10 { try c.memes.insert(Meme(kind: .image, createdAt: 100 + Int64(i * 10))) }
        let p1 = try c.search.search("", limit: 3)
        let late = Meme(kind: .image, createdAt: 105)             // older than the cursor: belongs to a later page
        try c.memes.insert(late)
        var rest: [MemeID] = []
        var cursor = p1.next
        while let cur = cursor {
            let p = try c.search.search("", limit: 3, after: cur)
            rest += p.memes.map(\.id); cursor = p.next
        }
        let all = p1.memes.map(\.id) + rest
        #expect(all.filter { $0 == late.id }.count == 1)
        #expect(Set(all).count == all.count && all.count == 11)
    }

    @Test func cursorFromADeletedMemeStillWorks() throws {
        let t = try TempCollection()
        let c = t.collection
        var ids: [MemeID] = []
        for i in 0..<5 { let m = Meme(kind: .image, createdAt: Int64(i)); try c.memes.insert(m); ids.append(m.id) }
        let p1 = try c.search.search("", limit: 2)
        for m in p1.memes { try c.memes.delete(m.id) }
        let p2 = try c.search.search("", limit: 10, after: p1.next)
        #expect(p2.memes.map(\.id) == [ids[2], ids[1], ids[0]])
    }

    @Test func recentAgreesWithSearch() throws {
        let t = try TempCollection()
        let c = t.collection
        for i in 0..<25 { try c.memes.insert(Meme(kind: .image, createdAt: Int64(i % 4))) }
        var recent: [MemeID] = []
        var cursor: MemeCursor?
        while true {
            let page = try c.memes.recent(limit: 6, before: cursor)
            recent += page.map(\.id)
            guard page.count == 6, let last = page.last else { break }
            cursor = MemeCursor(createdAt: last.createdAt, id: last.id)
        }
        #expect(recent == (try c.ids("")))
        #expect(Set(recent).count == 25)
    }
}

// MARK: - Chain hiding

@Suite struct ChainHidingTests {
    struct Seed { let t: TempCollection; let post: Meme; let parent: Meme; let quoted: Meme }

    func seeded() throws -> Seed {
        let t = try TempCollection()
        let c = t.collection
        let post = Meme(kind: .tweet, createdAt: 3, textVerbatim: "the post")
        let parent = Meme(kind: .tweet, createdAt: 2, textVerbatim: "the parent")
        let quoted = Meme(kind: .tweet, createdAt: 1, textVerbatim: "the quote")
        try c.memes.insert(post, tags: ["tweet", "liked", "@u"])
        try c.memes.insert(parent, tags: ["chain", "thread", "@u"])
        try c.memes.insert(quoted, tags: ["chain", "quoted", "@v"])
        return Seed(t: t, post: post, parent: parent, quoted: quoted)
    }

    @Test func hiddenFromOrdinaryQueries() throws {
        let s = try seeded()
        let c = s.t.collection
        #expect(try c.ids("") == [s.post.id])
        #expect(try c.ids("@u") == [s.post.id])
        #expect(try c.ids("@v").isEmpty)
        #expect(try c.ids("\"the\"") == [s.post.id])
        #expect(try c.ids("the") == [s.post.id])
        #expect(try c.ids("-liked").isEmpty)
        #expect(try c.ids("*").contains(s.parent.id) == false)
    }

    @Test func shownWhenAskedFor() throws {
        let s = try seeded()
        let c = s.t.collection
        #expect(try c.ids("chain") == [s.parent.id, s.quoted.id])
        #expect(try c.ids("CHAIN") == [s.parent.id, s.quoted.id])
        #expect(try c.ids("thread") == [s.parent.id])
        #expect(try c.ids("quoted") == [s.quoted.id])
        #expect(try c.ids("chain @v") == [s.quoted.id])
        #expect(try c.ids("chain -thread") == [s.quoted.id])
        #expect(try c.ids("thread \"parent\"") == [s.parent.id])
    }

    @Test func excludingChainIsNotAskingForIt() throws {
        let s = try seeded()
        #expect(try s.t.collection.ids("-chain") == [s.post.id])
        #expect(try s.t.collection.ids("-thread") == [s.post.id])
    }

    @Test func anAliasOfTheChainTagAsksForChainToo() throws {
        // A query that requires the chain tag (by an alias) would otherwise always come back empty.
        let s = try seeded()
        let c = s.t.collection
        try c.tags.addAlias("цепочка", to: try #require(try c.tags.resolve("chain")))
        #expect(try c.ids("цепочка") == [s.parent.id, s.quoted.id])
    }

    @Test func noChainTagNoFilter() throws {
        let t = try TempCollection()
        let m = Meme(kind: .tweet)
        try t.collection.memes.insert(m, tags: ["tweet"])
        #expect(try t.collection.ids("") == [m.id])
        #expect(try t.collection.ids("chain").isEmpty)
    }

    @Test func promotedChainTweetIsVisible() throws {
        let s = try seeded()
        let c = s.t.collection
        try c.memes.removeTag(s.parent.id, "chain")
        #expect(try c.ids("") == [s.post.id, s.parent.id])
        #expect(try c.ids("chain") == [s.quoted.id])
    }
}
