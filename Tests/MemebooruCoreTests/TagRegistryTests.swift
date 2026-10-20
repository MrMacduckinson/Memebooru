import Foundation
import Testing
@testable import MemebooruCore

@Suite struct TagRegistryTests {
    @Test func normalizesNames() throws {
        #expect(try TagName.normalize("  USSR Flag ") == "ussr_flag")
        #expect(throws: TagError.self) { try TagName.normalize("-bad") }
        #expect(throws: TagError.self) { try TagName.normalize("a*b") }
        #expect(throws: TagError.self) { try TagName.normalize("   ") }
    }

    @Test func aliasResolvesToCanonical() throws {
        let t = try TempCollection()
        let tags = t.collection.tags
        let tg = try tags.create("telegram_message", kind: .meta)
        try tags.addAlias("tg_message", to: tg)
        #expect(try tags.resolve("tg_message")?.id == tg.id)
        #expect(try tags.resolve("TG message")?.id == tg.id)
        #expect(try tags.aliases(of: tg) == ["tg_message"])
        // alias can't be reused as a tag name
        #expect(throws: TagError.self) { try tags.create("tg_message", kind: .normal) }
        // ensure() through alias returns the canonical tag, not a new one
        #expect(try tags.ensure("tg_message").id == tg.id)
        #expect(try tags.all().count == 1)
    }

    @Test func mergeMovesUsageAndKeepsAlias() throws {
        let t = try TempCollection()
        let c = t.collection
        let a = try c.tags.create("stalin", kind: .normal)
        let b = try c.tags.create("iosif_stalin", kind: .normal)
        let m1 = Meme(kind: .image), m2 = Meme(kind: .image)
        try c.memes.insert(m1, tags: ["stalin"])
        try c.memes.insert(m2, tags: ["iosif_stalin", "stalin"])
        try c.tags.merge(b, into: a)
        #expect(try c.tags.resolve("iosif_stalin")?.id == a.id)
        #expect(try c.tags.usage(of: a) == 2)
        #expect(try c.tags.all().map(\.name) == ["stalin"])
        #expect(try c.memes.tags(of: m2.id).map(\.name) == ["stalin"])
    }

    @Test func suggestIncludesAliasesOrderedByUsage() throws {
        let t = try TempCollection()
        let c = t.collection
        let tg = try c.tags.create("telegram_message", kind: .meta)
        try c.tags.addAlias("tg_message", to: tg)
        try c.tags.create("text", kind: .meta)
        try c.memes.insert(Meme(kind: .text), tags: ["telegram_message"])
        let s = try c.tags.suggest(prefix: "t")
        #expect(s.first?.text == "telegram_message")
        #expect(s.first?.usage == 1)
        #expect(s.contains { $0.text == "tg_message" && $0.isAlias && $0.tag.name == "telegram_message" })
        #expect(s.contains { $0.text == "text" })
    }
}
