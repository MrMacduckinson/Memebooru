import Foundation
import Testing
@testable import MemebooruCore

@Suite struct TagNameEdgeTests {
    @Test(arguments: [
        ("  USSR Flag ", "ussr_flag"), ("\tHello \n  World\t", "hello_world"), ("Ёлка", "ёлка"), ("@Handle", "@handle"),
        ("2022", "2022"), ("source_unknown", "source_unknown"), ("a-b", "a-b"), ("🐸", "🐸"), ("C++", "c++"),
        ("100%", "100%"), ("ΣΟΦΙΑ", "σοφια"), ("a\u{00A0}b", "a_b"),
    ])
    func normalizes(_ raw: String, _ expected: String) throws {
        #expect(try TagName.normalize(raw) == expected)
        #expect(TagName.isValid(raw))
    }

    @Test(arguments: ["", "   ", "\n\t", "-x", " -x", "--", "a*b", "*", "say \"hi\"", "\""])
    func rejects(_ raw: String) {
        #expect(throws: TagError.self) { try TagName.normalize(raw) }
        #expect(!TagName.isValid(raw))
    }

    @Test func veryLongNameIsKept() throws {
        let long = String(repeating: "я", count: 10_000)
        #expect(try TagName.normalize(long) == long)
    }
}

@Suite struct TagRegistryEdgeTests {
    @Test func createIsCaseAndSpaceInsensitiveUnique() throws {
        let t = try TempCollection()
        let tags = t.collection.tags
        let a = try tags.create("Ussr Flag", kind: .normal)
        #expect(a.name == "ussr_flag")
        #expect(throws: TagError.self) { try tags.create("USSR_FLAG", kind: .meta) }
        #expect(throws: TagError.self) { try tags.create("  ussr   flag ", kind: .normal) }
        #expect(try tags.all().count == 1)
    }

    @Test func ensureNeverChangesTheKindOfAnExistingTag() throws {
        let t = try TempCollection()
        let tags = t.collection.tags
        let y = try tags.create("2022", kind: .meta)
        #expect(try tags.ensure("2022", kind: .normal) == y)
        #expect(try tags.get(name: "2022")?.kind == .meta)
    }

    @Test func aliasToItselfIsANoOp() throws {
        let t = try TempCollection()
        let tags = t.collection.tags
        let a = try tags.create("cat", kind: .normal)
        try tags.addAlias("cat", to: a)
        try tags.addAlias("CAT", to: a)
        #expect(try tags.aliases(of: a).isEmpty)
        #expect(try tags.resolve("cat") == a)
        // Adding the same alias twice is idempotent too.
        try tags.addAlias("kot", to: a)
        try tags.addAlias("Kot", to: a)
        #expect(try tags.aliases(of: a) == ["kot"])
    }

    @Test func aliasesCannotFormCycles() throws {
        let t = try TempCollection()
        let tags = t.collection.tags
        let a = try tags.create("a", kind: .normal), b = try tags.create("b", kind: .normal)
        try tags.addAlias("x", to: a)
        // An alias can't take a tag's name, nor be moved to another tag, so a → b → a is impossible.
        #expect(throws: TagError.self) { try tags.addAlias("b", to: a) }
        #expect(throws: TagError.self) { try tags.addAlias("a", to: b) }
        #expect(throws: TagError.self) { try tags.addAlias("x", to: b) }
        #expect(try tags.resolve("x") == a)
        #expect(try tags.resolve("a") == a && tags.resolve("b") == b)
    }

    @Test func invalidAliasIsRejected() throws {
        let t = try TempCollection()
        let a = try t.collection.tags.create("a", kind: .normal)
        #expect(throws: TagError.self) { try t.collection.tags.addAlias("-a", to: a) }
        #expect(throws: TagError.self) { try t.collection.tags.addAlias("a*", to: a) }
        #expect(try t.collection.tags.aliases(of: a).isEmpty)
    }

    @Test func removeAliasOnlyRemovesAliases() throws {
        let t = try TempCollection()
        let tags = t.collection.tags
        let a = try tags.create("a", kind: .normal)
        try tags.addAlias("aa", to: a)
        try tags.removeAlias("a")              // a tag name, not an alias: nothing happens
        try tags.removeAlias("nope")
        #expect(try tags.resolve("a") == a)
        try tags.removeAlias("AA")
        #expect(try tags.resolve("aa") == nil)
    }

    @Test func mergeIntoTheCanonicalTagOfAnAlias() throws {
        let t = try TempCollection()
        let c = t.collection
        let y = try c.tags.create("stalin", kind: .normal)
        try c.tags.addAlias("коба", to: y)
        let x = try c.tags.create("iosif", kind: .normal)
        try c.tags.addAlias("soso", to: x)
        let m1 = Meme(kind: .image), m2 = Meme(kind: .image)
        try c.memes.insert(m1, tags: ["iosif"])
        try c.memes.insert(m2, tags: ["коба", "soso"])
        let target = try #require(try c.tags.resolve("коба"))
        try c.tags.merge(x, into: target)
        #expect(try c.tags.all().map(\.name) == ["stalin"])
        #expect(Set(try c.tags.aliases(of: y)) == ["коба", "iosif", "soso"])
        for name in ["iosif", "soso", "коба", "stalin"] { #expect(try c.tags.resolve(name) == y) }
        #expect(try c.tags.usage(of: y) == 2)
        #expect(try c.memes.tags(of: m2.id).map(\.name) == ["stalin"])          // no duplicate row
        #expect(Set(try c.ids("soso")) == [m1.id, m2.id])
    }

    @Test func mergeIntoItselfDoesNothing() throws {
        let t = try TempCollection()
        let c = t.collection
        let a = try c.tags.create("a", kind: .normal)
        try c.memes.insert(Meme(kind: .image), tags: ["a"])
        try c.tags.merge(a, into: a)
        #expect(try c.tags.usage(of: a) == 1 && c.tags.aliases(of: a).isEmpty)
    }

    @Test func mergeIntoAVanishedTagFailsAtomically() throws {
        let t = try TempCollection()
        let c = t.collection
        let a = try c.tags.create("a", kind: .normal), b = try c.tags.create("b", kind: .normal)
        let m = Meme(kind: .image)
        try c.memes.insert(m, tags: ["a"])
        try c.tags.delete(b)                                   // `b` is now a stale value
        let opsBefore = try c.oplog.count()
        #expect(throws: (any Error).self) { try c.tags.merge(a, into: b) }
        #expect(try c.tags.get(name: "a") == a)                 // rolled back: `a` and its usage survive
        #expect(try c.memes.tags(of: m.id).map(\.name) == ["a"])
        #expect(try c.oplog.count() == opsBefore)
    }

    @Test func mergeChainKeepsAllNamesResolvable() throws {
        let t = try TempCollection()
        let c = t.collection
        let a = try c.tags.create("a", kind: .normal), b = try c.tags.create("b", kind: .normal), d = try c.tags.create("d", kind: .normal)
        let m = Meme(kind: .image)
        try c.memes.insert(m, tags: ["a", "b"])
        try c.tags.merge(a, into: b)
        try c.tags.merge(try #require(try c.tags.get(name: "b")), into: d)
        for n in ["a", "b", "d"] { #expect(try c.tags.resolve(n) == d) }
        #expect(try c.memes.tags(of: m.id).map(\.name) == ["d"])
        #expect(try c.tags.usage(of: d) == 1)
    }

    @Test func renameEdgeCases() throws {
        let t = try TempCollection()
        let c = t.collection
        let a = try c.tags.create("kot", kind: .normal)
        try c.tags.addAlias("cat", to: a)
        let other = try c.tags.create("dog", kind: .normal)
        let m = Meme(kind: .image)
        try c.memes.insert(m, tags: ["kot"])

        #expect(throws: TagError.self) { _ = try c.tags.rename(a, to: "dog") }
        #expect(throws: TagError.self) { _ = try c.tags.rename(a, to: "-bad") }
        #expect(try c.tags.rename(a, to: "KOT").name == "kot")                  // to itself: fine

        // Renaming to one of its own aliases promotes the alias.
        let renamed = try c.tags.rename(a, to: "Cat")
        #expect(renamed.name == "cat" && renamed.id == a.id)
        #expect(try c.tags.aliases(of: renamed).isEmpty)
        #expect(try c.memes.tags(of: m.id).map(\.name) == ["cat"])
        #expect(try c.ids("cat") == [m.id])
        #expect(try c.tags.resolve("kot") == nil)                              // old name isn't kept
        #expect(try c.tags.resolve("dog") == other)
    }

    @Test func kindChangesAreVisibleAndOrderTags() throws {
        let t = try TempCollection()
        let c = t.collection
        let m = Meme(kind: .image)
        try c.memes.insert(m, tags: ["b", "a", "2022"])
        #expect(try c.memes.tags(of: m.id).map(\.name) == ["2022", "a", "b"])
        try c.tags.setKind(try #require(try c.tags.get(name: "2022")), .meta)
        try c.tags.setKind(try #require(try c.tags.get(name: "b")), .meta)
        let tags = try c.memes.tags(of: m.id)
        #expect(tags.map(\.name) == ["2022", "b", "a"])                         // meta first, then by name
        #expect(tags.map(\.kind) == [.meta, .meta, .normal])
        try c.tags.setKind(try #require(try c.tags.get(name: "b")), .normal)
        #expect(try c.tags.get(name: "b")?.kind == .normal)
    }

    @Test func usageCountsIgnoreDeletedMemesButRawUsageDoesNot() throws {
        let t = try TempCollection()
        let c = t.collection
        let ms = (0..<4).map { _ in Meme(kind: .image) }
        for m in ms { try c.memes.insert(m, tags: ["x"]) }
        let x = try #require(try c.tags.get(name: "x"))
        _ = try c.deleteMemes([ms[0].id, ms[1].id])
        #expect(try c.tags.usage(of: x) == 2 && c.tags.rawUsage(of: x) == 4)
        #expect(try c.tags.suggest(prefix: "x").first?.usage == 2)
        _ = try c.undoLast()
        #expect(try c.tags.usage(of: x) == 4)
        try c.memes.removeTag(ms[3].id, "x")
        #expect(try c.tags.usage(of: x) == 3 && c.tags.rawUsage(of: x) == 3)
    }

    @Test func deletingATagCascades() throws {
        let t = try TempCollection()
        let c = t.collection
        let x = try c.tags.create("x", kind: .normal)
        try c.tags.addAlias("xx", to: x)
        let m = Meme(kind: .image)
        try c.memes.insert(m, tags: ["x", "y"])
        try c.tags.delete(x)
        #expect(try c.memes.tags(of: m.id).map(\.name) == ["y"])
        #expect(try c.tags.resolve("xx") == nil)
        #expect(try c.db.scalarInt("SELECT count(*) FROM tag_alias") == 0)
        #expect(try c.ids("x").isEmpty)
        // The name is free again.
        #expect(try c.tags.create("xx", kind: .normal).name == "xx")
    }

    @Test func addingTheSameTagTwiceViaAliasIsOneRow() throws {
        let t = try TempCollection()
        let c = t.collection
        let a = try c.tags.create("a", kind: .normal)
        try c.tags.addAlias("b", to: a)
        let m = Meme(kind: .image)
        try c.memes.insert(m, tags: ["a", "b", "A", " a "])
        #expect(try c.memes.tags(of: m.id).map(\.name) == ["a"])
        #expect(try c.tags.rawUsage(of: a) == 1)
        try c.memes.removeTag(m.id, "B")
        #expect(try c.memes.tags(of: m.id).isEmpty)
        try c.memes.removeTag(m.id, "never_existed")       // unknown: silently nothing
        #expect(throws: TagError.self) { try c.memes.removeTag(m.id, "-bad") }
    }

    @Test func insertWithAnInvalidTagRollsBackEverything() throws {
        let t = try TempCollection()
        let c = t.collection
        let m = Meme(kind: .image, textExact: "rollback me")
        let ops = try c.oplog.count()
        #expect(throws: TagError.self) { try c.memes.insert(m, tags: ["fine", "-bad"]) }
        #expect(try c.memes.get(m.id) == nil)
        #expect(try c.tags.get(name: "fine") == nil)
        #expect(try c.oplog.count() == ops)
        #expect(try c.db.scalarInt("SELECT count(*) FROM meme_fts") == 0)
        #expect(try c.ids("rollback").isEmpty)
    }
}

@Suite struct TagSuggestEdgeTests {
    func seeded() throws -> TempCollection {
        let t = try TempCollection()
        let c = t.collection
        try c.memes.insert(Meme(kind: .image), tags: ["сталин", "стакан", "ёлка", "🐸frog", "a_b", "axb", "50%", "500", "stalin"])
        try c.memes.insert(Meme(kind: .image), tags: ["сталин", "стакан"])
        try c.memes.insert(Meme(kind: .image), tags: ["сталин"])
        try c.tags.addAlias("Коба", to: try #require(try c.tags.get(name: "сталин")))
        return t
    }

    @Test func unicodePrefixesAnyCase() throws {
        let t = try seeded()
        let s = t.collection.tags
        #expect(try s.suggest(prefix: "ста").map(\.text) == ["сталин", "стакан"])          // by usage
        #expect(try s.suggest(prefix: "СТА").map(\.text) == ["сталин", "стакан"])
        #expect(try s.suggest(prefix: "  Ста  ").map(\.text) == ["сталин", "стакан"])
        #expect(try s.suggest(prefix: "Ё").map(\.text) == ["ёлка"])
        #expect(try s.suggest(prefix: "🐸").map(\.text) == ["🐸frog"])
        let koba = try s.suggest(prefix: "КО")
        #expect(koba.map(\.text) == ["коба"] && koba.first?.isAlias == true && koba.first?.tag.name == "сталин" && koba.first?.usage == 3)
    }

    @Test func wildcardsInThePrefixAreLiteral() throws {
        let t = try seeded()
        let s = t.collection.tags
        #expect(try s.suggest(prefix: "a_").map(\.text) == ["a_b"])
        #expect(try s.suggest(prefix: "50%").map(\.text) == ["50%"])
        #expect(try s.suggest(prefix: "%").isEmpty)
        #expect(try s.suggest(prefix: "_").isEmpty)
    }

    @Test func backslashInThePrefixIsLiteral() throws {
        let t = try TempCollection()
        let c = t.collection
        try c.tags.create("a\\b", kind: .normal)
        try c.tags.create("a%b", kind: .normal)
        #expect(try c.tags.suggest(prefix: "a\\").map(\.text) == ["a\\b"])
        #expect(try c.tags.suggest(prefix: "a\\b").map(\.text) == ["a\\b"])
    }

    @Test func emptyPrefixListsEverythingUpToTheLimit() throws {
        let t = try seeded()
        let s = t.collection.tags
        let all = try s.suggest(prefix: "", limit: 100)
        #expect(all.count == 10)                                     // 9 tags + 1 alias
        #expect(all.first?.text == "сталин" || all.first?.text == "коба")
        #expect(all.map(\.usage) == all.map(\.usage).sorted(by: >))
        #expect(try s.suggest(prefix: "", limit: 3).count == 3)
        #expect(try s.suggest(prefix: "", limit: 0).isEmpty)
    }

    @Test func injectionLookingPrefix() throws {
        let t = try seeded()
        #expect(try t.collection.tags.suggest(prefix: "'; DROP TABLE tag; --").isEmpty)
        #expect(try t.collection.tags.all().count == 9)
    }
}
