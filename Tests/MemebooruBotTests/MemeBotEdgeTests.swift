import Foundation
import Testing
import MemebooruCore
@testable import MemebooruBot

/// FakeTelegram, except uploads of files whose bytes contain "poison" fail (as Telegram does for files it rejects).
final class PickyTelegram: TelegramAPI, @unchecked Sendable {
    let inner = FakeTelegram()
    func getUpdates(offset: Int64?, timeout: Int) async throws -> [TGUpdate] { [] }
    func sendMessage(chatID: Int64, text: String, replyTo: Int?) async throws -> TGMessage {
        try await inner.sendMessage(chatID: chatID, text: text, replyTo: replyTo)
    }
    func sendMedia(_ kind: TGMediaKind, chatID: Int64, file: URL, silent: Bool) async throws -> TGMessage {
        if let d = try? Data(contentsOf: file), String(decoding: d, as: UTF8.self).contains("poison") {
            throw TelegramError("Bad Request: PHOTO_INVALID_DIMENSIONS")
        }
        return try await inner.sendMedia(kind, chatID: chatID, file: file, silent: silent)
    }
    func deleteMessage(chatID: Int64, messageID: Int) async throws { try await inner.deleteMessage(chatID: chatID, messageID: messageID) }
    func answerInlineQuery(id: String, results: [TGInlineResult], nextOffset: String?, cacheTime: Int, emptyButton: String?) async throws {
        try await inner.answerInlineQuery(id: id, results: results, nextOffset: nextOffset, cacheTime: cacheTime, emptyButton: emptyButton)
    }
    func setCommands(_ commands: [TGCommand]) async throws {}
    func getFile(fileID: String) async throws -> TGFile { try await inner.getFile(fileID: fileID) }
    func download(filePath: String) async throws -> Data { try await inner.download(filePath: filePath) }
}

/// fxtwitter stand-in that counts fetches.
final class CountingTweets: TweetSource, HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []
    var fetched: [String] { lock.withLock { ids } }
    func fetch(tweetID: String) async throws -> FetchedTweet {
        lock.withLock { ids.append(tweetID) }
        return FetchedTweet(id: tweetID, url: "https://x.com/a/status/\(tweetID)", text: "tweet \(tweetID)", authorName: "A", handle: "a",
                            postedAt: 1_650_000_000_000)
    }
    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        HTTPResponse(status: 200, headers: [:], body: Data("bytes-of-\(url.lastPathComponent)".utf8))
    }
}

@Suite struct MemeBotInlineEdgeTests {
    let owner = TGUser(id: 42, firstName: "Owner", username: "owner")
    let stranger = TGUser(id: 7, firstName: "Eve", username: nil)

    private func bot(_ t: TempCollection, _ api: any TelegramAPI, pageSize: Int = 20, analyzer: MediaAnalyzer? = nil) -> MemeBot {
        var cfg = BotConfig(allowedUsers: [42]); cfg.pageSize = pageSize
        return MemeBot(api: api, collection: t.collection, analyzer: analyzer, config: cfg)
    }

    private func image(_ c: Collection, tag: String, bytes: String, createdAt: Int64 = Clock.nowMillis()) throws -> Meme {
        let m = Meme(kind: .image, createdAt: createdAt)
        try c.memes.insert(m, tags: [tag])
        let st = try c.media.put(data: Data(bytes.utf8), ext: "png")
        try c.memes.addAsset(Asset(memeID: m.id, role: .primary, sha256: st.sha256, ext: "png", mime: "image/png", bytes: st.bytes))
        return m
    }

    private func ask(_ b: MemeBot, _ q: String, from: TGUser? = nil, offset: String = "", id: String = "q") async {
        await b.handle(TGUpdate(updateId: 1, inlineQuery: TGInlineQuery(id: id, from: from ?? owner, query: q, offset: offset)))
    }

    @Test func emptyAndBlankQueriesListTheNewestFirst() async throws {
        let t = try TempCollection(), api = FakeTelegram()
        for i in 0..<3 { try t.collection.memes.insert(Meme(kind: .text, createdAt: Int64(1000 + i), textVerbatim: "joke \(i)"), tags: ["joke"]) }
        let b = bot(t, api)
        await ask(b, "")
        await ask(b, "   ")
        #expect(api.answers.count == 2)
        #expect(api.answers[0].results.map(\.title) == ["joke 2", "joke 1", "joke 0"])
        #expect(api.answers[1].results.map(\.id) == api.answers[0].results.map(\.id))
        #expect(api.answers[0].button == nil && api.answers[0].next == "")
    }

    @Test func pageSizeCapsResultsAndPagesThroughEverything() async throws {
        let t = try TempCollection(), api = FakeTelegram()
        for i in 0..<25 { try t.collection.memes.insert(Meme(kind: .text, createdAt: Int64(i + 1), textVerbatim: "n \(i)"), tags: ["n"]) }
        let b = bot(t, api)
        await ask(b, "n")
        #expect(api.answers[0].results.count == 20)
        let next = try #require(api.answers[0].next)
        await ask(b, "n", offset: next)
        #expect(api.answers[1].results.count == 5 && api.answers[1].next == "")
        #expect(Set(api.answers.flatMap { $0.results.map(\.id) }).count == 25)
    }

    @Test(arguments: ["garbage", "_", "123_", "abc_def", "9223372036854775807_zzz", "-5_x"])
    func malformedOffsetsDoNotBreakTheAnswer(offset: String) async throws {
        let t = try TempCollection(), api = FakeTelegram()
        try t.collection.memes.insert(Meme(kind: .text, textVerbatim: "only one"), tags: ["one"])
        await ask(bot(t, api), "one", offset: offset)
        #expect(api.answers.count == 1)
    }

    @Test func veryLongAndOddQueriesStillGetAnAnswer() async throws {
        let t = try TempCollection(), api = FakeTelegram()
        try t.collection.memes.insert(Meme(kind: .text, textVerbatim: "кот и 😂"), tags: ["кот", "😂"])
        let b = bot(t, api)
        let odd = [String(repeating: "очень длинный запрос ", count: 400), "\"unbalanced", "a*", "(", ")", "NOT", "AND OR", "-", "-кот",
                   "NEAR(", "^", "'", "\u{0}", "%", "_", "кот -", "\n"]
        for (i, q) in odd.enumerated() { await ask(b, q, id: "odd\(i)") }
        let answered = Set(api.answers.map(\.id))
        let unanswered = odd.indices.filter { !answered.contains("odd\($0)") }.map { odd[$0].prefix(30) }
        #expect(unanswered.isEmpty, "every inline query is answered, even with nothing: \(unanswered)")
        #expect(api.answers.allSatisfy { $0.results.count <= 20 })
    }

    @Test(arguments: ["кот", "КОТ", "😂"])
    func unicodeTagsAreFound(q: String) async throws {
        let t = try TempCollection(), api = FakeTelegram()
        let m = Meme(kind: .text, textVerbatim: "мем")
        try t.collection.memes.insert(m, tags: ["кот", "😂"])
        await ask(bot(t, api), q)
        #expect(api.answers.first?.results.map(\.id) == [m.id.rawValue])
    }

    @Test func uploadsPerQueryAreBudgetedAndTheRestComeNextTime() async throws {
        let t = try TempCollection(), api = FakeTelegram()
        for i in 0..<10 { _ = try image(t.collection, tag: "pic", bytes: "image \(i)", createdAt: Int64(1000 + i)) }
        let b = bot(t, api)
        await ask(b, "pic", id: "a")
        #expect(api.uploads.count == 6 && api.answers[0].results.count == 6)
        await ask(b, "pic", id: "b")
        #expect(api.uploads.count == 10 && api.answers[1].results.count == 10)
        await ask(b, "pic", id: "c")
        #expect(api.uploads.count == 10)                                      // all cached now
    }

    @Test func oneFileTelegramRejectsDoesNotSinkTheWholeAnswer() async throws {
        let t = try TempCollection(), api = PickyTelegram()
        _ = try image(t.collection, tag: "pic", bytes: "good one", createdAt: 3000)
        _ = try image(t.collection, tag: "pic", bytes: "poison pill", createdAt: 2000)
        _ = try image(t.collection, tag: "pic", bytes: "another good one", createdAt: 1000)
        await ask(bot(t, api), "pic")
        #expect(api.inner.answers.count == 1)
        #expect(api.inner.answers.first?.results.count == 2)
    }

    @Test func strangersCannotSteerTheLastUsedList() async throws {
        let t = try TempCollection(), api = FakeTelegram()
        let old = Meme(kind: .text, createdAt: 1, textVerbatim: "old")
        try t.collection.memes.insert(old, tags: ["x"])
        try t.collection.memes.insert(Meme(kind: .text, createdAt: 2, textVerbatim: "new"), tags: ["x"])
        let b = bot(t, api)
        await b.handle(TGUpdate(updateId: 1, chosenInlineResult: TGChosenInlineResult(resultId: old.id.rawValue, from: stranger)))
        await ask(b, "")
        #expect(api.answers[0].results.first?.title == "new")
        await ask(b, "x", from: stranger)
        #expect(api.answers[1].results.isEmpty && api.answers[1].button == nil)
    }

    // MARK: - Tweets in inline answers

    private func tweetMeme(_ c: Collection, text: String?, replyTo: String? = nil, display: TweetDisplay? = nil,
                           media: [(ext: String, bytes: String)]) throws -> Meme {
        var p = TweetPayload(tweetID: UUID().uuidString, url: "https://x.com/a/status/1", authorName: "A", handle: "a", replyToTweetID: replyTo)
        p.display = display
        let m = Meme(kind: .tweet, textVerbatim: text, payload: .tweet(p))
        try c.memes.insert(m, tags: ["tweet"])
        for (i, f) in media.enumerated() {
            let st = try c.media.put(data: Data(f.bytes.utf8), ext: f.ext)
            try c.memes.addAsset(Asset(memeID: m.id, role: .media, sha256: st.sha256, ext: f.ext,
                                       mime: MediaType.detect(ext: f.ext)?.mime ?? "", bytes: st.bytes, order: i))
        }
        return m
    }

    @Test func mediaOnlyTweetsGoOutAsTheirMediaWithTheLink() async throws {
        let t = try TempCollection(), api = FakeTelegram()
        let photo = try tweetMeme(t.collection, text: nil, media: [("jpg", "photo bytes"), ("jpg", "second")])
        let b = bot(t, api, analyzer: FakeMedia.analyzer)
        await ask(b, "tweet")
        let r = try #require(api.answers.first?.results.first)
        #expect(r.id == photo.id.rawValue && r.type == "photo" && r.caption == "https://x.com/a/status/1")
        #expect(try t.collection.memes.asset(of: photo.id, role: .render) == nil)       // no card drawn
        #expect(api.uploads.count == 1 && api.uploads[0].name.hasSuffix(".jpg"))       // the first media only
    }

    @Test func aMediaOnlyVideoTweetIsAVideoResult() async throws {
        let t = try TempCollection(), api = FakeTelegram()
        _ = try tweetMeme(t.collection, text: "  ", media: [("mp4", "video bytes")])
        await ask(bot(t, api), "tweet")
        let r = try #require(api.answers.first?.results.first)
        #expect(r.type == "video" && r.title == "@a" && r.videoFileId != nil && r.caption == "https://x.com/a/status/1")
    }

    @Test func repliesAndCardChoicesAreDrawnAsCards() async throws {
        let t = try TempCollection(), api = FakeTelegram()
        let reply = try tweetMeme(t.collection, text: nil, replyTo: "0", media: [("jpg", "r")])
        let card = try tweetMeme(t.collection, text: nil, display: .card, media: [("jpg", "c")])
        await ask(bot(t, api, analyzer: FakeMedia.analyzer), "tweet")
        #expect(api.answers.first?.results.count == 2)
        #expect(try t.collection.memes.asset(of: reply.id, role: .render) != nil)
        #expect(try t.collection.memes.asset(of: card.id, role: .render) != nil)
    }

    @Test func aTextTweetWithoutRendererIsAnArticleWithTheLink() async throws {
        let t = try TempCollection(), api = FakeTelegram()
        _ = try tweetMeme(t.collection, text: String(repeating: "длинный твит ", count: 500), media: [])
        await ask(bot(t, api), "tweet")
        let r = try #require(api.answers.first?.results.first)
        #expect(r.type == "article" && r.title == "@a")
        let body = try #require(r.inputMessageContent?.messageText)
        #expect(body.count <= 4096 && (r.description?.count ?? 0) <= 120)
    }
}

@Suite struct MemeBotLinkTests {
    @Test(arguments: [
        ("https://x.com/a/status/1", ["1"]),
        ("https://twitter.com/a/status/2?s=20&t=AbC", ["2"]),
        ("https://mobile.twitter.com/a/status/3", ["3"]),
        ("https://www.x.com/a/status/4", ["4"]),
        ("https://fxtwitter.com/a/status/5/photo/1", ["5"]),
        ("https://vxtwitter.com/a/status/6/video/1", ["6"]),
        ("https://fixupx.com/a/status/7", ["7"]),
        ("https://fixvx.com/a/status/8", ["8"]),
        ("HTTPS://X.COM/SomeOne/STATUS/9", ["9"]),
        ("x.com/a/status/10", ["10"]),
        ("http://twitter.com/a/statuses/11", ["11"]),
        ("https://x.com/i/status/12", ["12"]),
        ("https://x.com/i/web/status/13", ["13"]),
        ("(see x.com/a/status/14)", ["14"]),
        ("<https://x.com/a/status/15>", ["15"]),
        ("https://d.fxtwitter.com/a/status/16", ["16"]),
        ("https://x.com/a/status/17#reply", ["17"]),
        ("line one\nhttps://x.com/a/status/18\nhttps://twitter.com/b/status/19", ["18", "19"]),
        ("x.com/a/status/1 twitter.com/b/status/2 https://x.com/a/status/1?s=46", ["1", "2"]),
        ("https://x.com/a/status/", []),
        ("https://x.com/a/likes", []),
        ("https://x.com/home", []),
        ("https://linux.com/a/status/20", []),
        ("https://example.com/a/status/21", []),
        ("https://nitter.net/a/status/22", []),
        ("status/23", []),
        ("", []),
    ])
    func tweetLinkVariants(text: String, ids: [String]) {
        #expect(MemeBot.tweetIDs(in: text) == ids)
    }

    @Test func wordsAndLinksAreSeparated() {
        #expect(MemeBot.words("a, b,,c  /cmd\tд") == ["a", "b", "c", "д"])
        #expect(MemeBot.words("") == [])
        #expect(MemeBot.withoutLinks("cats x.com/a/status/1 dogs https://twitter.com/b/status/2?s=20") == "cats dogs")
        #expect(MemeBot.withoutLinks("lol.") == "lol.")
    }

    private let owner = TGUser(id: 42, firstName: "Owner", username: "owner")

    private func send(_ b: MemeBot, _ text: String, from: TGUser? = nil, chat: TGChat = TGChat(id: 42), id: Int = 1) async {
        await b.handle(TGUpdate(updateId: Int64(id), message: TGMessage(messageId: id, from: from ?? owner, chat: chat, date: 0, text: text)))
    }

    @Test func severalLinksInOneMessageAreEachSavedOnce() async throws {
        let t = try TempCollection(), api = FakeTelegram(), src = CountingTweets()
        let b = MemeBot(api: api, collection: t.collection, analyzer: nil, config: BotConfig(allowedUsers: [42]), tweetSource: src, http: src)
        await send(b, "funny https://x.com/a/status/1 and https://twitter.com/b/status/2?s=20 again x.com/a/status/1")
        #expect(src.fetched.sorted() == ["1", "2"])
        #expect(try t.collection.memes.count() == 2 && t.collection.staging.count() == 0)
        for id in ["1", "2"] {
            let meme = try #require(try t.collection.memes.memeForTweet(id))
            let names = try t.collection.memes.tags(of: meme).map(\.name)
            #expect(names.contains("funny") && names.contains("and") && names.contains("again"))
        }
        #expect(api.sentMessages.filter { $0.text.hasPrefix("Saved tweet by @a") }.count == 2)
    }

    @Test func nonTweetMessagesSaveNothing() async throws {
        let t = try TempCollection(), api = FakeTelegram(), src = CountingTweets()
        let b = MemeBot(api: api, collection: t.collection, analyzer: nil, config: BotConfig(allowedUsers: [42]), tweetSource: src, http: src)
        for (i, text) in ["hello", "https://example.com/a/status/9", "https://x.com/home", "   ", "https://linux.com/a/status/5"].enumerated() {
            await send(b, text, id: i + 1)
        }
        #expect(try src.fetched.isEmpty && t.collection.memes.count() == 0)
        #expect(api.sentMessages.allSatisfy { $0.text.hasPrefix("Forward a meme") })
        #expect(api.sentMessages.count == 4)                                     // blank text gets no reply
    }

    @Test func linksWithoutATweetSourceSayItIsNotSetUp() async throws {
        let t = try TempCollection(), api = FakeTelegram()
        let b = MemeBot(api: api, collection: t.collection, analyzer: nil, config: BotConfig(allowedUsers: [42]))
        await send(b, "https://x.com/a/status/1")
        #expect(api.sentMessages.last?.text == "Saving tweets by link isn't set up on this server.")
    }

    @Test func strangersCannotSaveOrProbe() async throws {
        let t = try TempCollection(), api = FakeTelegram(), src = CountingTweets()
        let b = MemeBot(api: api, collection: t.collection, analyzer: nil, config: BotConfig(allowedUsers: [42]), tweetSource: src, http: src)
        let eve = TGUser(id: 7, firstName: "Eve", username: "eve")
        let group = TGChat(id: -100, type: "supergroup", title: "G", username: nil)
        await send(b, "https://x.com/a/status/1", from: eve)                          // private: told their id
        await send(b, "/add", from: eve, chat: group, id: 2)                           // group: silence
        await send(b, "/stats", from: eve, chat: group, id: 3)
        let anon = TGMessage(messageId: 4, from: nil, chat: group, date: 0, text: "/stats")
        await b.handle(TGUpdate(updateId: 4, message: anon))
        let edited = TGMessage(messageId: 5, from: eve, chat: TGChat(id: 7), date: 0); edited.caption = "tags"
        await b.handle(TGUpdate(updateId: 5, editedMessage: edited))
        #expect(try src.fetched.isEmpty && t.collection.memes.count() == 0)
        #expect(api.sentMessages.count == 1 && api.sentMessages[0].text.contains("Your Telegram id is 7"))
    }

    @Test func groupChatterIsIgnoredButCommandsWork() async throws {
        let t = try TempCollection(), api = FakeTelegram(), src = CountingTweets()
        let b = MemeBot(api: api, collection: t.collection, analyzer: nil, config: BotConfig(allowedUsers: [42]), tweetSource: src, http: src)
        let group = TGChat(id: -100, type: "group", title: "G", username: nil)
        await send(b, "https://x.com/a/status/1 lol", chat: group)
        #expect(src.fetched.isEmpty && api.sentMessages.isEmpty)
        await send(b, "/help@SomeBot", chat: group, id: 2)
        await send(b, "/nonsense", chat: group, id: 3)
        await send(b, "/edittag onlyone", chat: group, id: 4)
        #expect(api.sentMessages.map { String($0.text.prefix(18)) } == ["Save a meme:\n• for", "Unknown command. /", "Usage: /edittag ol"])
    }
}

@Suite struct UploadKindTests {
    /// Telegram refuses photos past width + height 10 000 or 1:20; those go as files.
    @Test func oversizedPicturesGoAsFiles() {
        #expect(MemeBot.uploadKind(ext: "jpg", bytes: 1000, width: 1920, height: 1080) == .photo)
        #expect(MemeBot.uploadKind(ext: "png", bytes: 1000, width: 10368, height: 2234) == .document)   // three screenshots in a row
        #expect(MemeBot.uploadKind(ext: "png", bytes: 1000, width: 400, height: 9000) == .document)     // a long strip
        #expect(MemeBot.uploadKind(ext: "jpg", bytes: 1000, width: 200, height: 4100) == .document)     // 1:20.5
        #expect(MemeBot.uploadKind(ext: "jpg", bytes: 1000, width: 200, height: 4000) == .photo)        // exactly 1:20
        #expect(MemeBot.uploadKind(ext: "jpg", bytes: 11_000_000, width: 100, height: 100) == .document)
        #expect(MemeBot.uploadKind(ext: "jpg", bytes: 1000) == .photo)                                  // size unknown
        #expect(MemeBot.uploadKind(ext: "mp4", bytes: 1000, width: 20000, height: 100) == .video)
    }
}
