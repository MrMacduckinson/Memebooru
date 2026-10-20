import Foundation
import Testing
@testable import MemebooruCore

@Suite struct MemeStoreTests {
    @Test func insertReadUpdateDelete() throws {
        let t = try TempCollection()
        let c = t.collection
        var m = Meme(kind: .image, textExact: "обед", textVerbatim: "обед")
        try c.memes.insert(m, tags: ["stalin", "child", "2022"])
        #expect(try c.memes.count() == 1)
        #expect(try c.memes.tags(of: m.id).map(\.name) == ["2022", "child", "stalin"])

        m.context = "плакат"
        try c.memes.update(m)
        #expect(try c.memes.get(m.id)?.context == "плакат")

        try c.memes.delete(m.id)
        #expect(try c.memes.count() == 0)
        #expect(try c.memes.get(m.id)?.deletedAt != nil) // tombstone kept
    }

    @Test func tweetPayloadRoundTrips() throws {
        let t = try TempCollection()
        let p = TweetPayload(tweetID: "1", url: "https://x.com/a/status/1", authorName: "A", handle: "a", waybackURL: "https://web.archive.org/web/1")
        let m = Meme(kind: .tweet, payload: .tweet(p))
        try t.collection.memes.insert(m)
        #expect(try t.collection.memes.get(m.id)?.payload == .tweet(p))
    }

    @Test func tagsViaAliasAndSetTags() throws {
        let t = try TempCollection()
        let c = t.collection
        let tg = try c.tags.create("telegram_message", kind: .meta)
        try c.tags.addAlias("tg_message", to: tg)
        let m = Meme(kind: .image)
        try c.memes.insert(m, tags: ["tg_message"])
        #expect(try c.memes.tags(of: m.id).map(\.name) == ["telegram_message"])
        try c.memes.setTags(m.id, ["stalin", "tg_message"])
        #expect(try c.memes.tags(of: m.id).map(\.name) == ["telegram_message", "stalin"])
        try c.memes.setTags(m.id, ["stalin"])
        #expect(try c.memes.tags(of: m.id).map(\.name) == ["stalin"])
    }

    @Test func keysetPagination() throws {
        let t = try TempCollection()
        let c = t.collection
        for i in 0..<7 { try c.memes.insert(Meme(kind: .image, createdAt: 1000 + Int64(i))) }
        let p1 = try c.memes.recent(limit: 3)
        #expect(p1.map(\.createdAt) == [1006, 1005, 1004])
        let p2 = try c.memes.recent(limit: 3, before: MemeCursor(createdAt: p1.last!.createdAt, id: p1.last!.id))
        #expect(p2.map(\.createdAt) == [1003, 1002, 1001])
        let p3 = try c.memes.recent(limit: 3, before: MemeCursor(createdAt: p2.last!.createdAt, id: p2.last!.id))
        #expect(p3.map(\.createdAt) == [1000])
    }

    @Test func oplogRecordsEveryChange() throws {
        let t = try TempCollection()
        let c = t.collection
        let m = Meme(kind: .image, textExact: "x")
        try c.memes.insert(m, tags: ["a"])       // create + text_exact + tag create + meme_tag add
        let n1 = try c.oplog.count()
        #expect(n1 == 4)
        try c.memes.update(m)                     // nothing changed → no ops
        #expect(try c.oplog.count() == n1)
        try c.memes.removeTag(m.id, "a")
        #expect(try c.oplog.count() == n1 + 1)
        let ops = try c.oplog.ops(after: nil)
        #expect(ops.map(\.hlc) == ops.map(\.hlc).sorted())
        #expect(ops.allSatisfy { $0.deviceID == c.deviceID })
    }

    @Test func assetsAndRelations() throws {
        let t = try TempCollection()
        let c = t.collection
        let a = Meme(kind: .image), b = Meme(kind: .image)
        try c.memes.insert(a); try c.memes.insert(b)
        let stored = try c.media.put(data: Data("hello".utf8), ext: "txt")
        try c.memes.addAsset(Asset(memeID: a.id, role: .primary, sha256: stored.sha256, ext: "txt", mime: "text/plain", bytes: stored.bytes))
        #expect(try c.memes.primaryAsset(of: a.id)?.sha256 == stored.sha256)
        #expect(try c.memes.memes(withSHA256: stored.sha256) == [a.id])
        try c.memes.addRelation(Relation(from: b, to: a, kind: .contains))
        #expect(try c.memes.relations(of: a.id).map(\.kind) == [.contains])
        try c.memes.removeRelation(from: b.id, to: a.id, kind: .contains)
        #expect(try c.memes.relations(of: a.id).isEmpty)
    }
}

private extension Relation {
    init(from: Meme, to: Meme, kind: Kind) { self.init(from: from.id, to: to.id, kind: kind) }
}
