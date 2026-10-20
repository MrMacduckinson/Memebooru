import Foundation
import Testing
@testable import MemebooruCore

/// Builders for x.com GraphQL tweet results (the shape `XTimelineParser.tweet(from:)` reads).
enum XFix {
    static let date = "Wed Oct 05 20:00:00 +0000 2022"

    /// A `Tweet` result. `user: nil` leaves the author block out entirely.
    static func tweet(_ id: String, text: String, handle: String? = "u", name: String = "U",
                      legacy extra: [String: Any] = [:], result more: [String: Any] = [:]) -> [String: Any] {
        var legacy: [String: Any] = ["full_text": text, "created_at": date]
        for (k, v) in extra { legacy[k] = v }
        var r: [String: Any] = ["__typename": "Tweet", "rest_id": id, "legacy": legacy]
        if let handle {
            r["core"] = ["user_results": ["result": ["legacy": ["screen_name": handle, "name": name,
                                                                "profile_image_url_https": "https://pbs.twimg.com/profile_images/1/\(handle)_normal.jpg"]]]]
        }
        for (k, v) in more { r[k] = v }
        return r
    }

    static func photo(_ name: String, w: Int? = 1200, h: Int? = 800, tco: String? = nil) -> [String: Any] {
        var m: [String: Any] = ["type": "photo", "media_url_https": "https://pbs.twimg.com/media/\(name).jpg"]
        if let w, let h { m["original_info"] = ["width": w, "height": h] }
        if let tco { m["url"] = tco }
        return m
    }

    static func video(_ variants: [[String: Any]], type: String = "video") -> [String: Any] {
        ["type": type, "media_url_https": "https://pbs.twimg.com/thumb.jpg", "original_info": ["width": 720, "height": 1280],
         "video_info": ["variants": variants]]
    }

    /// One timeline page (Likes shape) of results, with an optional bottom cursor.
    static func instructions(_ results: [[String: Any]], cursor: String? = nil) -> [[String: Any]] {
        var entries: [[String: Any]] = results.enumerated().map { i, r in
            ["entryId": "tweet-\(r["rest_id"] as? String ?? "x\(i)")", "content": ["itemContent": ["tweet_results": ["result": r]]]]
        }
        if let cursor { entries.append(["entryId": "cursor-bottom-1", "content": ["cursorType": "Bottom", "value": cursor]]) }
        return [["type": "TimelineAddEntries", "entries": entries]]
    }

    static func parse(_ result: [String: Any]) throws -> FetchedTweet {
        try #require(FetchedTweet.parse(raw: try JSONSerialization.data(withJSONObject: result)))
    }

    static func millis(_ iso: String) -> Int64 {
        Int64(ISO8601DateFormatter().date(from: iso)!.timeIntervalSince1970 * 1000)
    }
}

@Suite struct TweetTextRangeTests {
    /// x.com's `display_text_range` is in Unicode code points (not UTF-16 units, not grapheme clusters).
    private func reply(_ body: String, prefix: String = "@a ", suffix: String = "") throws -> FetchedTweet {
        let full = prefix + body + suffix
        let start = prefix.unicodeScalars.count
        return try XFix.parse(XFix.tweet("1", text: full,
                                         legacy: ["display_text_range": [start, start + body.unicodeScalars.count]]))
    }

    @Test(arguments: [
        "👨‍👩‍👧 family",                       // ZWJ sequence: 5 code points, 8 UTF-16 units, 1 grapheme
        "🇺🇦 flag and 🏳️‍🌈",                   // regional indicators + ZWJ flag
        "Привет, мир",                            // Cyrillic
        "مرحبا بالعالم",                         // RTL Arabic
        "日本語のテキスト𠮷",                      // CJK incl. an astral (surrogate-pair) ideograph
        "👍🏽 skin tone",                          // emoji + modifier
        "e\u{301}cole",                           // combining mark (2 code points, 1 grapheme)
    ])
    func replyMentionsAreCutByCodePoints(body: String) throws {
        // Sanity: the cases really differ between counting schemes where it matters.
        let tw = try reply(body)
        #expect(tw.text == body)
    }

    @Test func rangeEndDropsTheTrailingMediaLinkByCodePoints() throws {
        let tw = try reply("Привет 🇺🇦👨‍👩‍👧", prefix: "@a @b ", suffix: " https://t.co/media")
        #expect(tw.text == "Привет 🇺🇦👨‍👩‍👧")
    }

    @Test func utf16CountingWouldCutMidEmoji() {
        // Guard for the fixtures above: code points and UTF-16 units disagree for these strings.
        #expect("👨‍👩‍👧".unicodeScalars.count == 5 && "👨‍👩‍👧".utf16.count == 8)
        #expect("𠮷".unicodeScalars.count == 1 && "𠮷".utf16.count == 2)
    }

    @Test func rangeThatStartsAtZeroLeavesTheStartAlone() throws {
        let tw = try XFix.parse(XFix.tweet("1", text: "@a not a reply prefix", legacy: ["display_text_range": [0, 5]]))
        // Only a reply's leading mentions are cut; a range from 0 is ignored (the media link is removed separately).
        #expect(tw.text == "@a not a reply prefix")
    }

    @Test func outOfBoundsOrMalformedRangesAreIgnored() throws {
        let past = try XFix.parse(XFix.tweet("1", text: "short", legacy: ["display_text_range": [50, 60]]))
        #expect(past.text == "short")
        let endPast = try XFix.parse(XFix.tweet("1", text: "@a hello", legacy: ["display_text_range": [3, 999]]))
        #expect(endPast.text == "hello")
        let inverted = try XFix.parse(XFix.tweet("1", text: "@a hello", legacy: ["display_text_range": [3, 1]]))
        #expect(inverted.text == "")
        let one = try XFix.parse(XFix.tweet("1", text: "@a hello", legacy: ["display_text_range": [3]]))
        #expect(one.text == "@a hello")
        let strings = try XFix.parse(XFix.tweet("1", text: "@a hello", legacy: ["display_text_range": ["3", "8"]]))
        #expect(strings.text == "@a hello")
    }

    /// x.com HTML-escapes `&`, `<`, `>` in `full_text`, but its indices count the unescaped text
    /// (`&amp;` is one code point). Cutting the escaped string would lose the end of the reply.
    @Test func entitiesInAReplyDoNotShiftTheRange() throws {
        let tw = try XFix.parse(XFix.tweet("1", text: "@a Tom &amp; Jerry &lt;3 &gt;_&lt;",
                                           legacy: ["display_text_range": [3, 3 + "Tom & Jerry <3 >_<".unicodeScalars.count]]))
        #expect(tw.text == "Tom & Jerry <3 >_<")
    }
}

@Suite struct TweetEntityTests {
    @Test func decodesTheEntitiesXUsesOnce() {
        #expect(FetchedTweet.decodeEntities("&amp;amp;") == "&amp;")           // user literally typed "&amp;"
        #expect(FetchedTweet.decodeEntities("&amp;lt;") == "&lt;")
        #expect(FetchedTweet.decodeEntities("it&#39;s &quot;fine&quot;") == "it's \"fine\"")
        #expect(FetchedTweet.decodeEntities("&lt;3 &gt;") == "<3 >")
        #expect(FetchedTweet.decodeEntities("AT&T & &foo; &copy;") == "AT&T & &foo; &copy;")   // unknown / bare stay
        #expect(FetchedTweet.decodeEntities("no entities") == "no entities")
        #expect(FetchedTweet.decodeEntities("") == "")
    }

    @Test func tcoLinksAreExpandedEverywhereTheyAppear() throws {
        let urls: [[String: Any]] = [
            ["url": "https://t.co/A", "display_url": "example.com/a", "expanded_url": "https://example.com/a"],
            ["url": "https://t.co/B", "expanded_url": "https://example.org/b"],          // no display_url → expanded
            ["url": "https://t.co/C"],                                                  // nothing to expand to
        ]
        let tw = try XFix.parse(XFix.tweet("1", text: "see https://t.co/A and https://t.co/B, again https://t.co/A https://t.co/C",
                                           legacy: ["entities": ["urls": urls]]))
        #expect(tw.text == "see example.com/a and https://example.org/b, again example.com/a https://t.co/C")
    }

    @Test func mediaLinksAreRemovedFromTheText() throws {
        let tw = try XFix.parse(XFix.tweet("1", text: "look at this https://t.co/pic",
                                           legacy: ["extended_entities": ["media": [XFix.photo("p", tco: "https://t.co/pic")]]]))
        #expect(tw.text == "look at this" && tw.media.count == 1)
    }

    @Test func aTweetThatIsOnlyTheQuoteLinkHasNoText() throws {
        let link = "https://t.co/q"
        let tw = try XFix.parse(XFix.tweet("1", text: link, legacy: [
            "quoted_status_id_str": "2",
            "entities": ["urls": [["url": link, "display_url": "x.com/b/status/2", "expanded_url": "https://x.com/b/status/2"]]],
            "quoted_status_permalink": ["url": link, "display": "x.com/b/status/2", "expanded": "https://x.com/b/status/2"]]))
        #expect(tw.text.isEmpty && tw.quotedTweetID == "2")
    }

    @Test func aTweetThatIsOnlyALinkKeepsTheLink() throws {
        let tw = try XFix.parse(XFix.tweet("1", text: "https://t.co/x",
                                           legacy: ["entities": ["urls": [["url": "https://t.co/x", "display_url": "example.com/page"]]]]))
        #expect(tw.text == "example.com/page")
    }

    @Test func quotePermalinkIsStrippedWhicheverFormMatches() throws {
        // The text ends with the expanded form only (e.g. after t.co expansion) — still removed.
        let tw = try XFix.parse(XFix.tweet("1", text: "so true https://t.co/q", legacy: [
            "quoted_status_id_str": "2",
            "entities": ["urls": [["url": "https://t.co/q", "display_url": "x.com/b/status/2"]]],
            "quoted_status_permalink": ["url": "https://t.co/zzz", "display": "x.com/b/status/2", "expanded": "https://x.com/b/status/2"]]))
        #expect(tw.text == "so true")
        // A link in the middle that equals the permalink stays (only the trailing one is the quote's).
        let mid = try XFix.parse(XFix.tweet("1", text: "x.com/b/status/2 is great", legacy: [
            "quoted_status_id_str": "2",
            "quoted_status_permalink": ["url": "https://t.co/q", "display": "x.com/b/status/2", "expanded": "https://x.com/b/status/2"]]))
        #expect(mid.text == "x.com/b/status/2 is great")
    }

    @Test func emptyPermalinkFieldsAreIgnored() throws {
        let tw = try XFix.parse(XFix.tweet("1", text: "words", legacy: ["quoted_status_permalink": ["url": "", "display": "", "expanded": ""]]))
        #expect(tw.text == "words")
    }

    @Test func noteTweetReplacesTheTruncatedTextAndExpandsItsOwnLinks() throws {
        let long = String(repeating: "Очень длинный твит 🧵 ", count: 30) + "https://t.co/n1"
        #expect(long.count > 280)
        let note: [String: Any] = ["note_tweet_results": ["result": [
            "text": long, "entity_set": ["urls": [["url": "https://t.co/n1", "display_url": "example.com/long"]]]]]]
        let tw = try XFix.parse(XFix.tweet("1", text: "Очень длинный твит… https://t.co/more", result: ["note_tweet": note]))
        #expect(tw.text.hasSuffix("example.com/long") && tw.text.hasPrefix("Очень длинный твит 🧵"))
        #expect(!tw.text.contains("t.co"))
    }

    @Test func noteTweetWithoutTextFallsBackToFullText() throws {
        let tw = try XFix.parse(XFix.tweet("1", text: "short &amp; sweet", result: ["note_tweet": ["note_tweet_results": ["result": [:]]]]))
        #expect(tw.text == "short & sweet")
    }

    @Test func pollsAndCardsAreIgnoredButTheTextStays() throws {
        let card: [String: Any] = ["rest_id": "card://1", "legacy": ["name": "poll2choice_text_only",
                                                                      "binding_values": [["key": "choice1_label", "value": ["string_value": "yes"]]]]]
        let tw = try XFix.parse(XFix.tweet("1", text: "Which one?", result: ["card": card]))
        #expect(tw.text == "Which one?" && tw.media.isEmpty && tw.quoted.isEmpty)
    }
}

@Suite struct TweetMediaParsingTests {
    @Test func fourPhotosKeepOrderSizeAndOriginals() throws {
        let tw = try XFix.parse(XFix.tweet("1", text: "4 pics", legacy: ["extended_entities": ["media": (1...4).map { XFix.photo("p\($0)") }]]))
        #expect(tw.media.count == 4 && tw.media.allSatisfy { $0.kind == .photo })
        #expect(tw.media.map(\.url) == (1...4).map { "https://pbs.twimg.com/media/p\($0).jpg?name=orig" })
        #expect(tw.media.map(\.thumbnailURL) == (1...4).map { "https://pbs.twimg.com/media/p\($0).jpg" })
        #expect(tw.media[0].width == 1200 && tw.media[0].height == 800 && tw.animatedMedia == nil)
    }

    @Test func origIsNotAddedTwiceOrToNonMediaHosts() {
        #expect(XMediaURL.origPhoto("https://pbs.twimg.com/media/a.jpg?name=small") == "https://pbs.twimg.com/media/a.jpg?name=small")
        #expect(XMediaURL.origPhoto("https://pbs.twimg.com/media/a?format=jpg") == "https://pbs.twimg.com/media/a?format=jpg&name=orig")
        #expect(XMediaURL.origPhoto("https://example.com/a.jpg") == "https://example.com/a.jpg")
        #expect(XMediaURL.bigAvatar("https://pbs.twimg.com/profile_images/1/me_normal.png") == "https://pbs.twimg.com/profile_images/1/me_400x400.png")
    }

    @Test func mixedPhotoVideoAndGIFAreTypedAndGIFsMarked() throws {
        let media: [[String: Any]] = [
            XFix.photo("p"),
            XFix.video([["content_type": "video/mp4", "bitrate": 2_176_000, "url": "https://video.twimg.com/v/hi.mp4"]]),
            XFix.video([["content_type": "video/mp4", "bitrate": 0, "url": "https://video.twimg.com/tweet_video/g.mp4"]], type: "animated_gif"),
        ]
        let tw = try XFix.parse(XFix.tweet("1", text: "mixed", legacy: ["extended_entities": ["media": media]]))
        #expect(tw.media.map(\.kind) == [.photo, .video, .gif])
        #expect(tw.animatedMedia == [2])
        #expect(tw.media[1].thumbnailURL == "https://pbs.twimg.com/thumb.jpg")
    }

    @Test func picksTheHighestBitrateMP4AndIgnoresHLS() throws {
        let variants: [[String: Any]] = [
            ["content_type": "application/x-mpegURL", "url": "https://video.twimg.com/v/pl.m3u8"],
            ["content_type": "video/mp4", "bitrate": 632_000, "url": "https://video.twimg.com/v/mid.mp4"],
            ["content_type": "video/mp4", "url": "https://video.twimg.com/v/nobitrate.mp4"],
            ["content_type": "video/mp4", "bitrate": 2_176_000, "url": "https://video.twimg.com/v/hi.mp4"],
            ["content_type": "video/mp4", "bitrate": 256_000, "url": "https://video.twimg.com/v/lo.mp4"],
        ]
        let tw = try XFix.parse(XFix.tweet("1", text: "v", legacy: ["extended_entities": ["media": [XFix.video(variants)]]]))
        #expect(tw.media.map(\.url) == ["https://video.twimg.com/v/hi.mp4"])
    }

    @Test func aVideoWithOnlyHLSIsDroppedNotCrashed() throws {
        let tw = try XFix.parse(XFix.tweet("1", text: "v", legacy: ["extended_entities": ["media": [
            XFix.video([["content_type": "application/x-mpegURL", "url": "https://video.twimg.com/v/pl.m3u8"]]),
            ["type": "video", "media_url_https": "https://pbs.twimg.com/t.jpg"],          // no video_info at all
            ["type": "photo"],                                                           // photo without a URL
        ]]]))
        #expect(tw.media.isEmpty && tw.animatedMedia == nil)
    }

    @Test func missingSizesAreNil() throws {
        let tw = try XFix.parse(XFix.tweet("1", text: "p", legacy: ["extended_entities": ["media": [XFix.photo("p", w: nil, h: nil)]]]))
        #expect(tw.media.first?.width == nil && tw.media.first?.height == nil)
    }

    @Test func entitiesMediaIsTheFallbackForExtendedEntities() throws {
        let tw = try XFix.parse(XFix.tweet("1", text: "p", legacy: ["entities": ["media": [XFix.photo("only")]]]))
        #expect(tw.media.map(\.url) == ["https://pbs.twimg.com/media/only.jpg?name=orig"])
    }
}

@Suite struct TweetShapeTests {
    @Test func datesParseOrAreNil() throws {
        let ok = try XFix.parse(XFix.tweet("1", text: "t"))
        #expect(ok.postedAt == XFix.millis("2022-10-05T20:00:00Z"))
        let offset = try XFix.parse(XFix.tweet("1", text: "t", legacy: ["created_at": "Wed Oct 05 23:00:00 +0300 2022"]))
        #expect(offset.postedAt == ok.postedAt)
        var noDate = XFix.tweet("1", text: "t"); var l = noDate["legacy"] as! [String: Any]; l["created_at"] = nil; noDate["legacy"] = l
        #expect(try XFix.parse(noDate).postedAt == nil)
        for bad in ["", "yesterday", "2022-10-05T20:00:00Z", "Wed Oct 32 20:00:00 +0000 2022"] {
            #expect(try XFix.parse(XFix.tweet("1", text: "t", legacy: ["created_at": bad])).postedAt == nil, "\(bad)")
        }
        #expect(XTimelineParser.parseTwitterDate("Wed Oct 05 20:00:00 +0000 2022") == XFix.millis("2022-10-05T20:00:00Z"))
    }

    @Test func newAuthorLayoutWinsAndAvatarIsUpsized() throws {
        let tw = try XFix.parse(XFix.tweet("1", text: "t", handle: nil, result: [
            "core": ["user_results": ["result": [
                "core": ["screen_name": "newhandle", "name": "New Name"],
                "avatar": ["image_url": "https://pbs.twimg.com/profile_images/9/a_normal.jpg"],
                "legacy": ["screen_name": "oldhandle", "name": "Old Name"]]]]]))
        #expect(tw.handle == "newhandle" && tw.authorName == "New Name")
        #expect(tw.avatarURL == "https://pbs.twimg.com/profile_images/9/a_400x400.jpg")
        #expect(tw.url == "https://x.com/newhandle/status/1")
    }

    @Test func missingAuthorStillParsesWithAWorkingLink() throws {
        let tw = try XFix.parse(XFix.tweet("123", text: "anon", handle: nil))
        #expect(tw.handle.isEmpty && tw.authorName.isEmpty && tw.avatarURL == nil)
        #expect(tw.url == "https://x.com/i/status/123")          // not "https://x.com//status/123"
    }

    @Test func resultsWithoutIDOrLegacyAreNotTweets() throws {
        #expect(XTimelineParser.tweet(from: ["rest_id": "1"]) == nil)
        #expect(XTimelineParser.tweet(from: ["legacy": ["full_text": "x"]]) == nil)
        #expect(FetchedTweet.parse(raw: Data("not json".utf8)) == nil)
        #expect(FetchedTweet.parse(raw: Data("[1,2]".utf8)) == nil)
        #expect(FetchedTweet.parse(raw: Data()) == nil)
    }

    @Test func tombstonesUnavailableAndWithheldAreSkippedVisibilityWrappersUnwrapped() throws {
        let wrapped: [String: Any] = ["__typename": "TweetWithVisibilityResults",
                                      "tweet": XFix.tweet("2", text: "limited"),
                                      "tweetInterstitial": ["__typename": "ContextualTweetInterstitial", "text": ["text": "age-restricted"]]]
        let results: [[String: Any]] = [
            XFix.tweet("1", text: "fine"),
            wrapped,
            ["__typename": "TweetTombstone", "tombstone": ["text": ["text": "This Post was deleted by the Post author."]]],
            ["__typename": "TweetUnavailable", "reason": "NsfwLoggedOut"],
            ["__typename": "TweetUnavailable", "reason": "Suspended"],
        ]
        var instructions = XFix.instructions([], cursor: "NEXT")
        var entries = instructions[0]["entries"] as! [[String: Any]]
        entries.insert(contentsOf: results.enumerated().map { i, r in
            ["entryId": "tweet-\(i)", "content": ["itemContent": ["tweet_results": ["result": r]]]]
        }, at: 0)
        entries.insert(["entryId": "tweet-empty", "content": ["itemContent": ["tweet_results": [:]]]], at: 0)
        instructions[0]["entries"] = entries
        let page = XTimelineParser.parse(instructions: instructions)
        #expect(page.tweets.map(\.id) == ["1", "2"] && page.cursor == "NEXT")
        #expect(page.tweets[1].text == "limited")
        // The saved raw JSON of an unwrapped tweet re-reads as the tweet itself.
        #expect(FetchedTweet.parse(raw: page.tweets[1].raw)?.text == "limited")
    }

    @Test func quotedTombstoneKeepsTheIDButEmbedsNothing() throws {
        let tw = try XFix.parse(XFix.tweet("1", text: "lol", legacy: ["quoted_status_id_str": "9"],
                                           result: ["quoted_status_result": ["result": ["__typename": "TweetTombstone"]]]))
        #expect(tw.quotedTweetID == "9" && tw.quoted.isEmpty)
    }

    @Test func quotedTweetBehindAVisibilityWrapperIsEmbedded() throws {
        let tw = try XFix.parse(XFix.tweet("1", text: "lol", legacy: ["quoted_status_id_str": "9"], result: [
            "quoted_status_result": ["result": ["__typename": "TweetWithVisibilityResults", "tweet": XFix.tweet("9", text: "quoted", handle: "q")]]]))
        #expect(tw.quoted.map(\.id) == ["9"] && tw.quoted.first?.handle == "q")
    }

    @Test func quoteOfAQuoteParsesBothLevels() throws {
        let c = XFix.tweet("3", text: "innermost")
        let b = XFix.tweet("2", text: "middle", legacy: ["quoted_status_id_str": "3"], result: ["quoted_status_result": ["result": c]])
        let a = try XFix.parse(XFix.tweet("1", text: "outer", legacy: ["quoted_status_id_str": "2"], result: ["quoted_status_result": ["result": b]]))
        #expect(a.quoted.first?.id == "2" && a.quoted.first?.quoted.first?.id == "3")
        #expect(a.quoted.count == 1)
    }

    @Test func selfReplyThreadKeepsItsParent() throws {
        let tw = try XFix.parse(XFix.tweet("2", text: "@alice 2/ more", handle: "alice", legacy: [
            "in_reply_to_screen_name": "alice", "in_reply_to_status_id_str": "1", "display_text_range": [7, 14]]))
        #expect(tw.replyToHandle == "alice" && tw.replyToTweetID == "1" && tw.text == "2/ more")
    }

    @Test func rawRoundTripsThroughParse() throws {
        let original = XFix.tweet("5", text: "@a hi &amp; bye https://t.co/m", legacy: [
            "display_text_range": [3, 11], "in_reply_to_status_id_str": "4", "in_reply_to_screen_name": "a",
            "extended_entities": ["media": [XFix.photo("m", tco: "https://t.co/m"), XFix.video([["content_type": "video/mp4", "bitrate": 1, "url": "https://video.twimg.com/a.mp4"]], type: "animated_gif")]]])
        let first = try XFix.parse(original)
        let again = try #require(FetchedTweet.parse(raw: first.raw))
        #expect(again.text == first.text && again.media == first.media && again.replyToTweetID == "4")
        #expect(first.text == "hi & bye")
    }
}

@Suite struct FxTwitterParsingTests {
    private func fx(_ tweet: [String: Any]) throws -> FetchedTweet {
        try #require(FetchedTweet.parse(raw: try JSONSerialization.data(withJSONObject: ["code": 200, "message": "OK", "tweet": tweet])))
    }

    @Test func readsTheFxtwitterShape() throws {
        let tw = try fx([
            "id": "10", "url": "https://x.com/bob/status/10", "text": "Tom &amp; Jerry 😺",
            "author": ["name": "Bob", "screen_name": "bob", "avatar_url": "https://pbs.twimg.com/b.jpg"],
            "created_timestamp": 1_665_000_800, "replying_to": "carol", "replying_to_status": "9",
            "media": ["all": [
                ["type": "photo", "url": "https://pbs.twimg.com/media/p.jpg?name=orig", "width": 10, "height": 20],
                ["type": "video", "url": "https://video.twimg.com/v.mp4", "thumbnail_url": "https://pbs.twimg.com/t.jpg"],
                ["type": "gif", "url": "https://video.twimg.com/g.mp4"],
                ["url": "https://example.com/no-type"],                                     // skipped
            ]],
            "quote": ["id": "8", "text": "quoted", "author": ["name": "Q", "screen_name": "q"]],
        ])
        #expect(tw.id == "10" && tw.text == "Tom & Jerry 😺" && tw.handle == "bob" && tw.authorName == "Bob")
        #expect(tw.postedAt == 1_665_000_800_000 && tw.replyToHandle == "carol" && tw.replyToTweetID == "9")
        #expect(tw.media.map(\.kind) == [.photo, .video, .gif] && tw.media[0].width == 10 && tw.animatedMedia == [2])
        #expect(tw.quotedTweetID == "8" && tw.quoted.first?.text == "quoted" && tw.quoted.first?.url == "https://x.com/i/status/8")
        // The quote's own raw re-reads as an fxtwitter response.
        #expect(FetchedTweet.parse(raw: try #require(tw.quoted.first).raw)?.id == "8")
    }

    @Test func sparseFxtwitterResponseStillParses() throws {
        let tw = try fx([:])
        #expect(tw.id.isEmpty && tw.text.isEmpty && tw.media.isEmpty && tw.postedAt == nil && tw.quoted.isEmpty)
    }
}

@Suite struct TweetIDFromStringTests {
    @Test(arguments: [
        ("https://x.com/a/status/12345?s=20", "12345"),
        ("https://twitter.com/a/statuses/777", "777"),
        ("https://x.com/a/status/42/photo/1", "42"),
        ("https://mobile.twitter.com/a/status/9/video/1?t=abc", "9"),
        ("123", "123"),
    ])
    func extractsIDs(input: String, id: String) {
        #expect(TweetImporter.tweetID(from: input) == id)
    }

    @Test(arguments: ["", "nope", "https://x.com/home", "١٢٣", "½", "12a"])
    func rejectsNonIDs(input: String) {
        #expect(TweetImporter.tweetID(from: input) == nil)
    }
}

@Suite struct TweetMediaFileTests {
    struct Bytes: HTTPClient {
        func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
            if url.absoluteString.contains("broken") { return HTTPResponse(status: 404, headers: [:], body: Data()) }
            return HTTPResponse(status: 200, headers: [:], body: Data("bytes-\(url.absoluteString)".utf8))
        }
    }
    struct NoSource: TweetSource {
        func fetch(tweetID: String) async throws -> FetchedTweet { throw CollectionError("offline") }
    }

    private static let tweet = FetchedTweet(
        id: "1", url: "https://x.com/u/status/1", text: "", authorName: "U", handle: "u",
        avatarURL: "https://pbs.twimg.com/profile_images/1/u_400x400.png",
        media: [.init(kind: .photo, url: "https://pbs.twimg.com/media/a.png?name=orig"),
                .init(kind: .photo, url: "https://pbs.twimg.com/media/b?format=jpg&name=orig"),
                .init(kind: .video, url: "https://video.twimg.com/ext_tw_video/1/pu/vid/720x1280/c.mp4?tag=12"),
                .init(kind: .gif, url: "https://video.twimg.com/tweet_video/d"),
                .init(kind: .photo, url: "https://pbs.twimg.com/media/broken.jpg")])

    @Test func preparedMediaKeepTheirRealExtensions() async throws {
        let t = try TempCollection()
        let importer = TweetImporter(staging: t.collection.staging, source: NoSource(), http: Bytes(), archive: false)
        let p = try await importer.prepare(Self.tweet)
        #expect(p.media.map(\.url.pathExtension) == ["png", "jpg", "mp4", "mp4"])        // broken one skipped
        #expect(p.avatarURL?.pathExtension == "png")
        let meme = try importer.commitPrepared(p, into: t.collection)
        let media = try t.collection.memes.assets(of: meme.id).filter { $0.role == .media }.sorted { $0.order < $1.order }
        #expect(media.map(\.ext) == ["png", "jpg", "mp4", "mp4"] && media.map(\.mime) == ["image/png", "image/jpeg", "video/mp4", "video/mp4"])
        #expect(meme.textVerbatim == nil)                           // a media-only tweet has no text
        #expect(!FileManager.default.fileExists(atPath: p.jsonURL.deletingLastPathComponent().path))   // temp dir cleaned
    }

    @Test func stagedMediaKeepTheirRealExtensions() async throws {
        let t = try TempCollection()
        let importer = TweetImporter(staging: t.collection.staging, source: NoSource(), http: Bytes(), archive: false)
        let item = try await importer.stage(Self.tweet)
        let media = t.collection.staging.extras(item).filter { $0.role == .media }
        #expect(media.map(\.order) == [0, 1, 2, 3])
        #expect(media.map(\.url.pathExtension) == ["png", "jpg", "mp4", "mp4"])
        #expect(item.textVerbatim == nil && item.context == nil)
    }
}
