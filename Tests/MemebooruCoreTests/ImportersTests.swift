import Foundation
import Testing
@testable import MemebooruCore

@Suite struct ImportersTests {
    @Test func telegramExport() throws {
        let t = try TempCollection()
        let dir = t.url.appendingPathComponent("tg")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("photos"), withIntermediateDirectories: true)
        try Data("img".utf8).write(to: dir.appendingPathComponent("photos/p1.jpg"))
        let json = """
        {"name":"Saved Messages","type":"saved_messages","messages":[
          {"id":1,"type":"message","date":"2022-03-01T12:00:00","date_unixtime":"1646136000","from":"Me","photo":"photos/p1.jpg","text":[{"type":"plain","text":"обед"}," со Сталиным"]},
          {"id":2,"type":"message","date":"2021-01-01T00:00:00","from":"Me","forwarded_from":"Панорама","text":"Очень длинный текст анекдота, который явно тянет на отдельный мем в коллекции"},
          {"id":3,"type":"message","date":"2021-01-01T00:00:00","text":"ok"},
          {"id":4,"type":"service","date":"2021-01-01T00:00:00","action":"pin_message"},
          {"id":5,"type":"message","date":"2021-01-01T00:00:00","file":"missing.mp4","media_type":"video_file","text":""}
        ]}
        """
        try json.write(to: dir.appendingPathComponent("result.json"), atomically: true, encoding: .utf8)
        let staging = StagingArea(collection: t.collection, analyzer: nil)
        let r = try TelegramExportImporter(staging: staging).importExport(at: dir)
        #expect(r.staged.count == 2 && r.skipped.count == 1)
        let photo = r.staged[0], text = r.staged[1]
        #expect(photo.kind == .image && photo.textVerbatim == "обед со Сталиным")
        #expect(photo.suggestedTags == ["2022", "picture", "telegram_message"])
        #expect(photo.context?.contains("Saved Messages") == true)
        #expect(text.kind == .text && text.suggestedTags.contains("2021") && text.context?.contains("forwarded from Панорама") == true)
    }

    struct FakeHTTP: HTTPClient {
        func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
            let s = url.absoluteString
            if s.contains("wayback/available") {
                return HTTPResponse(status: 200, headers: [:], body: Data(#"{"archived_snapshots":{}}"#.utf8))
            }
            if s.contains("web.archive.org/save/") {
                return HTTPResponse(status: 200, headers: ["content-location": "/web/20240101000000/https://x.com/a/status/1"], body: Data())
            }
            return HTTPResponse(status: 200, headers: [:], body: Data("bytes-of-\(url.lastPathComponent)".utf8))
        }
    }
    struct FakeSource: TweetSource {
        func fetch(tweetID: String) async throws -> FetchedTweet {
            FetchedTweet(id: tweetID, url: "https://x.com/a/status/\(tweetID)", text: "hello world", authorName: "A", handle: "a",
                         avatarURL: "https://pbs.twimg.com/av.jpg", postedAt: 1_650_000_000_000, replyToHandle: "b", replyToTweetID: "9",
                         quotedTweetID: nil, media: [.init(kind: .photo, url: "https://pbs.twimg.com/m1.jpg", thumbnailURL: nil, width: 10, height: 10),
                                                     .init(kind: .video, url: "https://video.twimg.com/v.mp4", thumbnailURL: nil, width: nil, height: nil)],
                         raw: Data("{}".utf8))
        }
    }

    @Test func tweetImportStagesPayloadMediaAndCommitsAssets() async throws {
        let t = try TempCollection()
        let c = t.collection
        let staging = StagingArea(collection: c, analyzer: nil)
        let importer = TweetImporter(staging: staging, source: FakeSource(), http: FakeHTTP())
        #expect(TweetImporter.tweetID(from: "https://x.com/a/status/12345?s=20") == "12345")
        #expect(TweetImporter.tweetID(from: "nope") == nil)
        let item = try await importer.importTweet("https://twitter.com/a/status/1")
        #expect(item.kind == .tweet && item.ext == "json" && item.textVerbatim == "hello world")
        #expect(item.suggestedTags == ["2022", "@a", "tweet", "x"])
        #expect(item.context == "reply to @b")
        guard case .tweet(let p) = item.payload else { Issue.record("no payload"); return }
        #expect(p.waybackURL == "https://web.archive.org/web/20240101000000/https://x.com/a/status/1")
        #expect(p.replyToTweetID == "9" && p.handle == "a")
        #expect(staging.extras(item).map(\.role) == [.avatar, .media, .media])
        let m = try staging.commit(item.id)
        let assets = try c.memes.assets(of: m.id)
        #expect(assets.map(\.role) == [.avatar, .media, .media, .primary])
        #expect(assets.filter { $0.role == .media }.map(\.ext) == ["jpg", "mp4"])
        #expect(try c.memes.get(m.id)?.payload == .tweet(p))
        #expect(try c.search.search("tweet @a").memes.map(\.id) == [m.id])
    }

    @Test func duplicateScannerFindsExactAndSimilarAndHonorsDismiss() throws {
        let t = try TempCollection()
        let c = t.collection
        func meme(_ bytes: String, phash: UInt64?) throws -> MemeID {
            let m = Meme(kind: .image); try c.memes.insert(m)
            let st = try c.media.put(data: Data(bytes.utf8), ext: "jpg")
            try c.memes.addAsset(Asset(memeID: m.id, role: .primary, sha256: st.sha256, ext: "jpg", mime: "image/jpeg", bytes: st.bytes,
                                       phash: phash.map(PerceptualHash.toInt64)))
            return m.id
        }
        let base: UInt64 = 0x0123_4567_89ab_cdef
        let a = try meme("same", phash: base)
        let b = try meme("same", phash: base)                 // exact
        let d = try meme("other", phash: base ^ 0b1111)       // similar, distance 4
        _ = try meme("far", phash: ~base)                     // distance 64
        _ = try meme("nohash", phash: nil)
        let scanner = DuplicateScanner(collection: c)
        var pairs = try scanner.scan()
        #expect(pairs.count == 3)
        #expect(pairs.first?.match == .exact)
        #expect(pairs.contains { Set([$0.a, $0.b]) == Set([a, d]) && $0.match == .similar(distance: 4) })
        try scanner.dismiss(a, d)
        try c.memes.addRelation(Relation(from: a, to: b, kind: .duplicate))
        pairs = try scanner.scan()
        #expect(pairs.count == 1 && Set([pairs[0].a, pairs[0].b]) == Set([b, d]))
    }
}

@Suite struct ClusterTests {
    @Test func unionFindGroupsTriples() throws {
        let a = MemeID("a"), b = MemeID("b"), c = MemeID("c"), d = MemeID("d"), e = MemeID("e")
        let pairs = [
            DuplicatePair(a: a, b: b, match: .exact),
            DuplicatePair(a: b, b: c, match: .similar(distance: 5)),
            DuplicatePair(a: d, b: e, match: .similar(distance: 9)),
        ]
        let cl = DuplicateScanner.clusters(from: pairs)
        #expect(cl.count == 2)
        #expect(cl[0].members == [a, b, c] && cl[0].maxDistance == 5 && !cl[0].allExact)
        #expect(cl[1].members == [d, e])
    }

    @Test func resolveKeepsOneDeletesRest() throws {
        let t = try TempCollection()
        let c = t.collection
        var ids: [MemeID] = []
        for _ in 0..<3 {
            let m = Meme(kind: .image); try c.memes.insert(m); ids.append(m.id)
            let st = try c.media.put(data: Data("same".utf8), ext: "jpg")
            try c.memes.addAsset(Asset(memeID: m.id, role: .primary, sha256: st.sha256, ext: "jpg", mime: "image/jpeg", bytes: 4))
        }
        let scanner = DuplicateScanner(collection: c)
        let clusters = try scanner.clusters()
        #expect(clusters.count == 1 && clusters[0].members.count == 3 && clusters[0].allExact)
        try scanner.resolve(clusters[0], keeping: ids[1], memes: c.memes)
        #expect(try c.memes.count() == 1)
        #expect(try c.memes.relations(of: ids[1]).count == 2)
        #expect(try scanner.clusters().isEmpty)
    }
}
