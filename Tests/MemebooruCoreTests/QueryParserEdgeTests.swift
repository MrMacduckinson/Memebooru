import Foundation
import Testing
@testable import MemebooruCore

/// Pure parsing: `Query.parse` never fails, whatever is typed into the search box.
@Suite struct QueryParserEdgeTests {
    @Test(arguments: ["", " ", "     ", "\t", "\n", " \t \n\r ", "\u{00A0}\u{2003}"])
    func blankInputIsEmpty(_ line: String) {
        let q = Query.parse(line)
        #expect(q.isEmpty)
        #expect(q == Query())
    }

    @Test func loneDashesAndEmptyQuotesAreIgnored() {
        #expect(Query.parse("-").isEmpty)
        #expect(Query.parse(" - - - ").isEmpty)
        #expect(Query.parse("\"\"").isEmpty)
        #expect(Query.parse("\"   \"").isEmpty)
        #expect(Query.parse("-\"\"").isEmpty)
        #expect(Query.parse("\"").isEmpty)                     // a single unbalanced quote
    }

    @Test func unbalancedQuoteRunsToTheEnd() {
        let q = Query.parse("stalin \"обед со")
        #expect(q.include == [.tag("stalin")])
        #expect(q.phrases == ["обед со"])
    }

    @Test func quoteGluedToWordsStaysInTheWord() {
        // Only a quote at the start of a term opens a phrase; inside a word it's just a character.
        let q = Query.parse("don\"t a\"b \"c d\"e")
        #expect(q.include == [.tag("don\"t"), .tag("a\"b"), .tag("e")])
        #expect(q.phrases == ["c d"])
    }

    @Test func phraseIsTrimmedButKeepsInnerSpacing() {
        #expect(Query.parse("\"  two  words  \"").phrases == ["two  words"])
    }

    @Test func negation() {
        let q = Query.parse("-ussr -USSR_Flag -stal* cat")
        #expect(q.include == [.tag("cat")])
        #expect(q.exclude == [.tag("ussr"), .tag("ussr_flag"), .glob("stal*")])
    }

    @Test func doubleDashNegatesADashWord() {
        // `--x`: the first dash negates, the rest is the word "-x" (which can never be a tag).
        #expect(Query.parse("--x").exclude == [.tag("-x")])
        #expect(Query.parse("--").exclude == [.tag("-")])
    }

    @Test func dashFollowedBySpaceIsDropped() {
        let q = Query.parse("a - b")
        #expect(q.include == [.tag("a"), .tag("b")])
        #expect(q.exclude.isEmpty)
    }

    @Test func negatedPhraseIsCurrentlyAPositivePhrase() {
        // Debatable (documented, see SearchTests.parsesSyntax): `Query` has no excluded phrases, so a
        // `-"..."` phrase is searched for, not excluded.
        let q = Query.parse("-\"bad words\"")
        #expect(q.phrases == ["bad words"])
        #expect(q.exclude.isEmpty)
    }

    @Test func caseFoldingIncludingCyrillic() {
        let q = Query.parse("STALIN Сталин ЁЛКА ΣΟΦΙΑ")
        #expect(q.include == [.tag("stalin"), .tag("сталин"), .tag("ёлка"), .tag("σοφια")])
    }

    @Test func phrasesKeepTheirCase() {
        #expect(Query.parse("\"Обед СО Сталиным\"").phrases == ["Обед СО Сталиным"])
    }

    @Test func emojiAndSymbols() {
        let q = Query.parse("🐸 @Handle #hashtag 2022 source_unknown c++ 100% a_b é")
        #expect(q.include == [.tag("🐸"), .tag("@handle"), .tag("#hashtag"), .tag("2022"), .tag("source_unknown"),
                              .tag("c++"), .tag("100%"), .tag("a_b"), .tag("é")])
    }

    @Test func emojiWithModifiersStaysOneTerm() {
        let family = "👨‍👩‍👧‍👦"
        let q = Query.parse("\(family) 👍🏽")
        #expect(q.include == [.tag(family), .tag("👍🏽")])
    }

    @Test func globs() {
        let q = Query.parse("* stal* *in st*n -*")
        #expect(q.include == [.glob("*"), .glob("stal*"), .glob("*in"), .glob("st*n")])
        #expect(q.exclude == [.glob("*")])
    }

    @Test func whitespaceOfAllKindsSeparates() {
        let q = Query.parse("a\tb\nc\r\nd\u{00A0}e")
        #expect(q.include == ["a", "b", "c", "d", "e"].map { .tag($0) })
    }

    @Test func sqlLookingInputIsJustWords() {
        let q = Query.parse("'; DROP TABLE meme; --")
        #expect(q.include == [.tag("';"), .tag("drop"), .tag("table"), .tag("meme;")])
        #expect(q.exclude == [.tag("-")])
    }

    @Test func veryLongQuery() {
        let words = (0..<5_000).map { "w\($0)" }
        let q = Query.parse(words.joined(separator: " ") + " \"" + String(repeating: "x", count: 100_000) + "\"")
        #expect(q.include.count == 5_000)
        #expect(q.phrases.first?.count == 100_000)
    }

    @Test func duplicatesArePreserved() {
        #expect(Query.parse("a a -a").include == [.tag("a"), .tag("a")])
    }
}
