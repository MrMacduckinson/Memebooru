import Foundation
import Testing
@testable import MemebooruCore

/// Serves any URL with a few bytes — media downloads for staged tweets.
private struct AnyBytes: HTTPClient, TweetSource {
    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        HTTPResponse(status: 200, headers: [:], body: Data("bytes".utf8))
    }
    func fetch(tweetID: String) async throws -> FetchedTweet { throw CollectionError("offline") }
}

@Suite struct MediaSizeTests {
    private static func tweet(_ id: String, sizes: [(Int?, Int?)]) -> FetchedTweet {
        FetchedTweet(id: id, url: "https://x.com/u/status/\(id)", text: "", authorName: "U", handle: "u",
                     media: sizes.enumerated().map { i, s in
                         .init(kind: .photo, url: "https://pbs.twimg.com/\(id)-\(i).jpg", width: s.0, height: s.1)
                     })
    }

    @Test func sizesComeFromXAndSkipUnknownOnes() {
        let t = Self.tweet("1", sizes: [(1200, 675), (nil, 10), (0, 0), (640, 640)])
        #expect(t.mediaSizes == [.init(order: 0, width: 1200, height: 675), .init(order: 3, width: 640, height: 640)])
        #expect(Self.tweet("2", sizes: []).mediaSizes == nil)
        #expect(Self.tweet("3", sizes: [(nil, nil)]).mediaSizes == nil)
    }

    @Test func stagedTweetsKeepTheirMediaSizes() async throws {
        let t = try TempCollection()
        let src = AnyBytes()
        let importer = TweetImporter(staging: t.collection.staging, source: src, http: src, archive: false)
        let item = try await importer.stage(Self.tweet("7", sizes: [(1600, 900), (900, 1600)]))
        guard case .tweet(let p) = item.payload else { Issue.record("not a tweet"); return }
        #expect(p.mediaSize(order: 0)?.width == 1600 && p.mediaSize(order: 1)?.height == 1600)
        #expect(p.mediaSize(order: 5) == nil)
        // It survives the round trip through the database.
        let again = try #require(try t.collection.staging.list().first)
        #expect(again.payload == item.payload)
    }

    @Test func olderStagedTweetsGetSizesFromTheirSavedJSONOnce() async throws {
        let t = try TempCollection()
        let staging = t.collection.staging
        // A tweet saved the old way: x.com's JSON on disk, no sizes in the payload.
        let raw: [String: Any] = [
            "rest_id": "42",
            "legacy": ["full_text": "hi", "created_at": "Wed Oct 05 20:00:00 +0000 2022",
                       "extended_entities": ["media": [["type": "photo", "media_url_https": "https://pbs.twimg.com/media/a.jpg",
                                                        "original_info": ["width": 800, "height": 400]]]]],
        ]
        let json = FileManager.default.temporaryDirectory.appendingPathComponent("mb-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: raw).write(to: json)
        let p = TweetPayload(tweetID: "42", url: "https://x.com/u/status/42", authorName: "U", handle: "u")
        let item = try staging.add(file: json, source: "x:u", kind: .tweet, payload: .tweet(p))
        // And one without media.
        let plain = FileManager.default.temporaryDirectory.appendingPathComponent("mb-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: ["rest_id": "43", "legacy": ["full_text": "text only"]]).write(to: plain)
        let other = try staging.add(file: plain, source: "x:u", kind: .tweet,
                                    payload: .tweet(TweetPayload(tweetID: "43", url: "u", authorName: "U", handle: "u")))

        #expect(try staging.fillMediaSizes() == 2)
        let filled = try #require(try staging.list().first { $0.id == item.id })
        guard case .tweet(let fp) = filled.payload else { Issue.record("not a tweet"); return }
        #expect(fp.mediaSizes == [.init(order: 0, width: 800, height: 400)])
        let none = try #require(try staging.list().first { $0.id == other.id })
        guard case .tweet(let np) = none.payload else { Issue.record("not a tweet"); return }
        #expect(np.mediaSizes == [])                                   // read, nothing there: not read again
        #expect(try staging.fillMediaSizes() == 0)
    }

    @Test func oldPayloadsWithoutSizesStillDecode() throws {
        let old = #"{"tweetID":"1","url":"u","authorName":"A","handle":"a"}"#
        let p = try JSONDecoder().decode(TweetPayload.self, from: Data(old.utf8))
        #expect(p.mediaSizes == nil && p.mediaSize(order: 0) == nil)
    }

    @Test func retryTimeIsTheEarliestWaitingTweet() throws {
        let t = try TempCollection()
        let q = t.collection.wayback
        nonisolated(unsafe) var clock: Int64 = 1_000_000
        q.now = { clock }
        #expect(try q.nextRetryAt() == nil)                            // nothing queued
        let a = Meme(kind: .tweet, presentation: .native), b = Meme(kind: .tweet, presentation: .native)
        try t.collection.memes.insert(a); try t.collection.memes.insert(b)
        try q.enqueue(a.id, url: "https://x.com/a/status/1")
        try q.enqueue(b.id, url: "https://x.com/a/status/2")
        #expect(try q.nextRetryAt() == nil)                            // due now, not waiting
        try q.bump(a.id)
        #expect(try q.nextRetryAt() == nil)                            // b is still due
        try q.bump(b.id); try q.bump(b.id)
        #expect(try q.nextRetryAt() == clock + WaybackQueue.backoff[0])
        clock += WaybackQueue.backoff[0]
        #expect(try q.nextRetryAt() == nil)                            // a's wait is over
    }
}
