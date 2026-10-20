import Foundation
import Testing
import MemebooruCore
@testable import MemebooruBot

final class TempCollection: @unchecked Sendable {
    let url: URL
    let collection: Collection
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("memebooru-bot-\(UUID().uuidString).memebooru")
        collection = try Collection.create(at: url)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

/// Records every call; serves canned files for getFile/download.
final class FakeTelegram: TelegramAPI, @unchecked Sendable {
    private let lock = NSLock()
    var sentMessages: [(chat: Int64, text: String)] = []
    /// What each sent message replied to, and the id it got (so a test can reply to the bot).
    var sentReplies: [(replyTo: Int?, id: Int)] = []
    var uploads: [(kind: TGMediaKind, chat: Int64, name: String)] = []
    var deleted: [Int] = []
    var answers: [(id: String, results: [TGInlineResult], next: String?, button: String?)] = []
    var commands: [TGCommand] = []
    var files: [String: (path: String, data: Data)] = [:]
    private var nextID = 1000

    private func newID() -> Int { lock.withLock { nextID += 1; return nextID } }

    func getUpdates(offset: Int64?, timeout: Int) async throws -> [TGUpdate] { [] }
    func sendMessage(chatID: Int64, text: String, replyTo: Int?) async throws -> TGMessage {
        let id = newID()
        lock.withLock { sentMessages.append((chatID, text)); sentReplies.append((replyTo, id)) }
        return TGMessage(messageId: id, from: nil, chat: TGChat(id: chatID), date: 0, text: text)
    }
    func sendMedia(_ kind: TGMediaKind, chatID: Int64, file: URL, silent: Bool) async throws -> TGMessage {
        let id = newID()
        lock.withLock { uploads.append((kind, chatID, file.lastPathComponent)) }
        let m = TGMessage(messageId: id, from: nil, chat: TGChat(id: chatID), date: 0)
        var ref = TGFileRef(fileId: "uploaded-\(id)")
        ref.fileUniqueId = "uniq-uploaded-\(id)"
        switch kind {
        case .photo: m.photo = [TGFileRef(fileId: "small-\(id)", fileSize: 1), ref]
        case .animation: m.animation = ref
        case .video: m.video = ref
        case .audio: m.audio = ref
        case .voice: m.voice = ref
        case .document: m.document = ref
        }
        if kind == .photo { m.photo![0].width = 90; m.photo![0].height = 90; m.photo![1].width = 800; m.photo![1].height = 800 }
        return m
    }
    func deleteMessage(chatID: Int64, messageID: Int) async throws { lock.withLock { deleted.append(messageID) } }
    func answerInlineQuery(id: String, results: [TGInlineResult], nextOffset: String?, cacheTime: Int, emptyButton: String?) async throws {
        lock.withLock { answers.append((id, results, nextOffset, emptyButton)) }
    }
    func setCommands(_ commands: [TGCommand]) async throws { self.commands = commands }
    func getFile(fileID: String) async throws -> TGFile {
        guard let f = files[fileID] else { throw TelegramError("no such file") }
        return TGFile(fileId: fileID, filePath: f.path, fileSize: Int64(f.data.count))
    }
    func download(filePath: String) async throws -> Data {
        guard let f = files.values.first(where: { $0.path == filePath }) else { throw TelegramError("404") }
        return f.data
    }
}

extension TGChat { init(id: Int64) { self.init(id: id, type: "private", title: nil, username: nil) } }

/// Just enough platform to draw a tweet: text as solid blocks, "PNG" = the raw pixels.
struct FakeMedia: ImageDecoder, VideoProbe, ThumbnailEncoder, HTTPClient, TextRenderer {
    struct Unsupported: Error {}
    func decode(_ url: URL, maxSide: Int) throws -> Bitmap { throw Unsupported() }
    func imageSize(_ url: URL) throws -> (width: Int, height: Int) { throw Unsupported() }
    func durationMs(_ url: URL) throws -> Int64 { throw Unsupported() }
    func frame(_ url: URL, at fraction: Double, maxSide: Int) throws -> Bitmap { throw Unsupported() }
    func jpeg(_ bitmap: Bitmap, quality: Double) throws -> Data { bitmap.rgba }
    func encode(_ bitmap: Bitmap, as format: MediaFormat, quality: Double) throws -> Data? { bitmap.rgba }
    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse { throw Unsupported() }
    func render(_ text: String, style: TextStyle, width: Int) throws -> Bitmap? {
        guard !text.isEmpty else { return nil }
        let w = min(width, text.count * Int(style.size / 2)), h = Int(style.size * 1.3)
        return Bitmap(width: w, height: h, rgba: Data(repeating: 128, count: w * h * 4))
    }
    static var analyzer: MediaAnalyzer {
        let f = FakeMedia()
        return MediaAnalyzer(platform: Platform(images: f, video: f, thumbs: f, http: f, text: f))
    }
}

@Suite struct MemeBotTests {
    let owner = TGUser(id: 42, firstName: "Owner", username: "owner")
    let stranger = TGUser(id: 7, firstName: "Eve", username: nil)

    private func imageMeme(_ c: Collection, tag: String, bytes: String = "png-bytes") throws -> Meme {
        let m = Meme(kind: .image)
        try c.memes.insert(m, tags: [tag])
        let st = try c.media.put(data: Data(bytes.utf8), ext: "png")
        try c.memes.addAsset(Asset(memeID: m.id, role: .primary, sha256: st.sha256, ext: "png", mime: "image/png", bytes: st.bytes, originalName: "cat.png"))
        return m
    }

    @Test func inlineUploadsOnceThenAnswersFromCache() async throws {
        let t = try TempCollection(), api = FakeTelegram()
        let img = try imageMeme(t.collection, tag: "cat")
        let txt = Meme(kind: .text, textVerbatim: "cat fact\nthey sleep a lot")
        try t.collection.memes.insert(txt, tags: ["cat"])
        let bot = MemeBot(api: api, collection: t.collection, analyzer: nil, config: BotConfig(allowedUsers: [42]))

        await bot.handle(TGUpdate(updateId: 1, inlineQuery: TGInlineQuery(id: "q1", from: owner, query: "cat")))
        let first = try #require(api.answers.first).results
        #expect(first.count == 2)
        let photo = try #require(first.first { $0.type == "photo" })
        #expect(photo.id == img.id.rawValue && photo.photoFileId?.hasPrefix("uploaded-") == true)   // largest size, not the thumbnail
        let article = try #require(first.first { $0.type == "article" })
        #expect(article.title == "cat fact" && article.inputMessageContent?.messageText == "cat fact\nthey sleep a lot")
        #expect(api.uploads.count == 1 && api.uploads[0].chat == 42 && api.deleted.count == 1)   // uploaded to the owner, then deleted

        await bot.handle(TGUpdate(updateId: 2, inlineQuery: TGInlineQuery(id: "q2", from: owner, query: "cat")))
        #expect(api.uploads.count == 1)                                   // second time: cached file_id
        #expect(api.answers[1].results.first { $0.type == "photo" }?.photoFileId == photo.photoFileId)
    }

    @Test func tweetsAreSentAsPicturesWithTheirLink() async throws {
        let t = try TempCollection(), api = FakeTelegram()
        let tweet = Meme(kind: .tweet, textVerbatim: "funny tweet",
                         payload: .tweet(TweetPayload(tweetID: "1", url: "https://x.com/a/status/1", authorName: "A", handle: "a")))
        try t.collection.memes.insert(tweet, tags: ["tweet"])
        let bot = MemeBot(api: api, collection: t.collection, analyzer: FakeMedia.analyzer, config: BotConfig(allowedUsers: [42]))

        await bot.handle(TGUpdate(updateId: 1, inlineQuery: TGInlineQuery(id: "q1", from: owner, query: "tweet")))
        let r = try #require(api.answers.first?.results.first)
        #expect(r.type == "photo" && r.caption == "https://x.com/a/status/1")
        let render = try #require(try t.collection.memes.asset(of: tweet.id, role: .render))
        #expect(render.width == 1200 && api.uploads.count == 1)

        await bot.handle(TGUpdate(updateId: 2, inlineQuery: TGInlineQuery(id: "q2", from: owner, query: "tweet")))
        #expect(api.uploads.count == 1 && api.answers[1].results.first?.photoFileId == r.photoFileId)   // not drawn or sent again

        // Without a text renderer: text + link, as before.
        let t2 = try TempCollection()
        try t2.collection.memes.insert(tweet, tags: ["tweet"])
        let plainBot = MemeBot(api: api, collection: t2.collection, analyzer: nil, config: BotConfig(allowedUsers: [42]))
        await plainBot.handle(TGUpdate(updateId: 3, inlineQuery: TGInlineQuery(id: "q3", from: owner, query: "tweet")))
        let text = try #require(api.answers.last?.results.first)
        #expect(text.type == "article" && text.inputMessageContent?.messageText == "funny tweet\n\nhttps://x.com/a/status/1")
    }

    /// fxtwitter stand-in: tweet 100 quotes 200; 404 is missing. Media downloads return some bytes.
    struct FakeTweets: TweetSource, HTTPClient {
        struct NotFound: Error, CustomStringConvertible { var description: String { "tweet not found" } }
        func fetch(tweetID: String) async throws -> FetchedTweet {
            guard tweetID != "404" else { throw NotFound() }
            return FetchedTweet(id: tweetID, url: "https://x.com/a/status/\(tweetID)", text: "tweet \(tweetID)", authorName: "A", handle: "a",
                                avatarURL: "https://pbs.twimg.com/av.jpg", postedAt: 1_650_000_000_000,
                                quotedTweetID: tweetID == "100" ? "200" : nil,
                                media: tweetID == "100" ? [.init(kind: .photo, url: "https://pbs.twimg.com/m1.jpg")] : [])
        }
        func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
            HTTPResponse(status: 200, headers: [:], body: Data("bytes-of-\(url.lastPathComponent)".utf8))
        }
    }

    @Test func tweetLinksAreRecognised() {
        #expect(MemeBot.tweetIDs(in: "look https://x.com/some_one/status/123?s=20 and twitter.com/b/statuses/456 and https://x.com/a/status/123")
                == ["123", "456"])
        #expect(MemeBot.tweetIDs(in: "https://fxtwitter.com/a/status/7 https://mobile.twitter.com/a/status/8/photo/1") == ["7", "8"])
        #expect(MemeBot.tweetIDs(in: "https://x.com/home https://example.com/a/status/9").isEmpty)
        #expect(MemeBot.withoutLinks("https://x.com/a/status/1 funny cats") == "funny cats")
    }

    @Test func tweetLinkIsSavedWithQuoteTagsAndPicture() async throws {
        let t = try TempCollection(), api = FakeTelegram()
        let fake = FakeTweets()
        let bot = MemeBot(api: api, collection: t.collection, analyzer: FakeMedia.analyzer, config: BotConfig(allowedUsers: [42]),
                          tweetSource: fake, http: fake)
        let m = TGMessage(messageId: 1, from: owner, chat: TGChat(id: 42), date: 0, text: "https://x.com/a/status/100?s=20 funny cats")
        await bot.handle(TGUpdate(updateId: 1, message: m))

        let id = try #require(try t.collection.memes.memeForTweet("100"))
        let names = try t.collection.memes.tags(of: id).map(\.name)
        #expect(names.contains("funny") && names.contains("cats") && names.contains("tweet") && names.contains("@a"))
        let assets = try t.collection.memes.assets(of: id)
        #expect(assets.contains { $0.role == .media } && assets.contains { $0.role == .avatar } && assets.contains { $0.role == .render })
        let quoted = try #require(try t.collection.memes.memeForTweet("200"))
        #expect(try t.collection.memes.relations(of: id).contains { $0.kind == .quote && $0.to == quoted })
        #expect(api.sentMessages.last?.text.hasPrefix("Saved tweet by @a, 1 media:") == true)

        // Same link again: nothing new, just the tags. Forwarded link: saved, with no tags from the text.
        await bot.handle(TGUpdate(updateId: 2, message: TGMessage(messageId: 2, from: owner, chat: TGChat(id: 42), date: 0, text: "x.com/a/status/100 more")))
        #expect(api.sentMessages.last?.text.hasPrefix("Already in the collection.") == true)
        #expect(try t.collection.memes.tags(of: id).map(\.name).contains("more"))
        let fwd = TGMessage(messageId: 3, from: owner, chat: TGChat(id: 42), date: 0, text: "wow https://twitter.com/a/status/300")
        fwd.forwardOrigin = TGOrigin(type: "user", date: 0, senderUser: TGUser(id: 5, firstName: "Bob", username: "bob"))
        await bot.handle(TGUpdate(updateId: 3, message: fwd))
        let third = try #require(try t.collection.memes.memeForTweet("300"))
        #expect(!(try t.collection.memes.tags(of: third).map(\.name).contains("wow")))
        #expect(try t.collection.memes.count() == 3)

        // A tweet that can't be fetched gets a message, not a meme.
        await bot.handle(TGUpdate(updateId: 4, message: TGMessage(messageId: 4, from: owner, chat: TGChat(id: 42), date: 0, text: "https://x.com/a/status/404")))
        #expect(api.sentMessages.last?.text == "Couldn't get tweet 404: tweet not found")
    }

    @Test func strangersGetNothing() async throws {
        let t = try TempCollection(), api = FakeTelegram()
        _ = try imageMeme(t.collection, tag: "cat")
        let bot = MemeBot(api: api, collection: t.collection, analyzer: nil, config: BotConfig(allowedUsers: [42]))
        await bot.handle(TGUpdate(updateId: 1, inlineQuery: TGInlineQuery(id: "q", from: stranger, query: "cat")))
        #expect(api.answers.first?.results.isEmpty == true && api.uploads.isEmpty)

        let hi = TGMessage(messageId: 1, from: stranger, chat: TGChat(id: 7), date: 0, text: "/start")
        await bot.handle(TGUpdate(updateId: 2, message: hi))
        #expect(api.sentMessages.first?.text.contains("Your Telegram id is 7") == true)
        #expect(try t.collection.memes.count() == 1)
    }

    @Test func forwardedPhotoIsSavedTaggedAndDeduplicated() async throws {
        let t = try TempCollection(), api = FakeTelegram()
        api.files["in-photo"] = ("photos/file_3.jpg", Data("jpeg-bytes".utf8))
        let bot = MemeBot(api: api, collection: t.collection, analyzer: nil, config: BotConfig(allowedUsers: [42]))

        func forward(_ id: Int) -> TGMessage {
            let m = TGMessage(messageId: id, from: owner, chat: TGChat(id: 42), date: 1_700_000_000)
            m.photo = [TGFileRef(fileId: "in-photo")]
            m.caption = "when the build is green"
            m.forwardOrigin = TGOrigin(type: "channel", date: 1_600_000_000, chat: TGChat(id: -100, type: "channel", title: "Memes", username: "memes"))
            return m
        }
        await bot.handle(TGUpdate(updateId: 1, message: forward(10)))
        let memes = try t.collection.search.search("telegram_message").memes
        let saved = try #require(memes.first)
        #expect(memes.count == 1 && saved.kind == .image)
        #expect(saved.context == "forwarded from Memes @memes" && saved.textVerbatim == "when the build is green")
        #expect(try t.collection.search.search("2020").memes.count == 1)   // year from the original post, not the forward
        #expect(api.sentMessages.last?.text.hasPrefix("Saved (image)") == true)
        // The incoming file_id is cached: an inline answer needs no upload.
        await bot.handle(TGUpdate(updateId: 2, inlineQuery: TGInlineQuery(id: "q", from: owner, query: "telegram_message")))
        #expect(api.uploads.isEmpty && api.answers.last?.results.first?.photoFileId == "in-photo")

        // Replying to "Saved" with words tags the meme.
        let savedReply = TGMessage(messageId: 1001, from: nil, chat: TGChat(id: 42), date: 0)
        let tagMsg = TGMessage(messageId: 11, from: owner, chat: TGChat(id: 42), date: 0, text: "ci, green-build")
        tagMsg.replyToMessage = savedReply
        await bot.handle(TGUpdate(updateId: 3, message: tagMsg))
        #expect(Set(try t.collection.memes.tags(of: saved.id).map(\.name)).isSuperset(of: ["ci", "green-build"]))

        // Same file again → not saved twice.
        await bot.handle(TGUpdate(updateId: 4, message: forward(12)))
        #expect(try t.collection.memes.count() == 1)
        #expect(api.sentMessages.last?.text.hasPrefix("Already in the collection") == true)
    }

    @Test func forwardedTextBecomesATextMeme() async throws {
        let t = try TempCollection(), api = FakeTelegram()
        let bot = MemeBot(api: api, collection: t.collection, analyzer: nil, config: BotConfig(allowedUsers: [42]))
        let m = TGMessage(messageId: 1, from: owner, chat: TGChat(id: 42), date: 1_700_000_000, text: "copypasta line one\nline two")
        m.forwardOrigin = TGOrigin(type: "user", date: 1_700_000_000, senderUser: TGUser(id: 5, firstName: "Bob", username: "bob"))
        await bot.handle(TGUpdate(updateId: 1, message: m))
        let saved = try #require(try t.collection.search.search("telegram_message").memes.first)
        #expect(saved.kind == .text && saved.textVerbatim == "copypasta line one\nline two" && saved.context == "forwarded from Bob @bob")

        // Plain (non-forwarded) text is not saved — it gets a hint.
        let plain = TGMessage(messageId: 2, from: owner, chat: TGChat(id: 42), date: 0, text: "hello")
        await bot.handle(TGUpdate(updateId: 2, message: plain))
        #expect(try t.collection.memes.count() == 1)
    }

    @Test func inlinePagination() async throws {
        let t = try TempCollection(), api = FakeTelegram()
        for i in 0..<5 { try t.collection.memes.insert(Meme(kind: .text, textVerbatim: "joke \(i)"), tags: ["joke"]) }
        var cfg = BotConfig(allowedUsers: [42]); cfg.pageSize = 3
        let bot = MemeBot(api: api, collection: t.collection, analyzer: nil, config: cfg)
        await bot.handle(TGUpdate(updateId: 1, inlineQuery: TGInlineQuery(id: "a", from: owner, query: "joke")))
        let next = try #require(api.answers[0].next)
        #expect(api.answers[0].results.count == 3 && !next.isEmpty)
        await bot.handle(TGUpdate(updateId: 2, inlineQuery: TGInlineQuery(id: "b", from: owner, query: "joke", offset: next)))
        #expect(api.answers[1].results.count == 2 && api.answers[1].next == "")
        let ids = Set((api.answers[0].results + api.answers[1].results).map(\.id))
        #expect(ids.count == 5)
    }

    @Test func inlineResultJSONUsesBotAPINames() throws {
        var r = TGInlineResult(type: "photo", id: "x"); r.photoFileId = "F"
        let e = JSONEncoder(); e.keyEncodingStrategy = .convertToSnakeCase
        let json = String(decoding: try e.encode(r), as: UTF8.self)
        #expect(json.contains("\"photo_file_id\":\"F\"") && !json.contains("gif_file_id"))
        let a = try #require(MemeBot.article(id: "y", text: "hi"))
        #expect(String(decoding: try e.encode(a), as: UTF8.self).contains("\"input_message_content\":{\"message_text\":\"hi\"}"))
    }

    @Test func updatesDecodeFromBotAPIJSON() throws {
        let json = """
            {"update_id": 9, "message": {"message_id": 3, "date": 1700000000,
              "from": {"id": 42, "is_bot": false, "first_name": "O"}, "chat": {"id": 42, "type": "private"},
              "animation": {"file_id": "A", "file_unique_id": "u", "width": 1, "height": 1, "duration": 2},
              "forward_origin": {"type": "hidden_user", "date": 1690000000, "sender_user_name": "Anon"}}}
            """
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
        let u = try d.decode(TGUpdate.self, from: Data(json.utf8))
        #expect(u.message?.animation?.fileId == "A")
        #expect(MemeBot.context(of: u.message!) == "forwarded from Anon")
        #expect(MemeBot.fileRef(in: u.message!)?.kind == .animation)
    }

    // MARK: - tgbooru-style features

    private func photoMessage(_ id: Int, from: TGUser, chat: TGChat, fileID: String, unique: String, caption: String? = nil) -> TGMessage {
        let m = TGMessage(messageId: id, from: from, chat: chat, date: 1_700_000_000)
        var f = TGFileRef(fileId: fileID); f.fileUniqueId = unique; f.width = 100; f.height = 100
        m.photo = [f]; m.caption = caption
        return m
    }

    @Test func ownPhotoCaptionIsTagsAndEditingItRetags() async throws {
        let t = try TempCollection(), api = FakeTelegram()
        api.files["F1"] = ("photos/file_9.jpg", Data("own-photo".utf8))
        let bot = MemeBot(api: api, collection: t.collection, analyzer: nil, config: BotConfig(allowedUsers: [42]))
        let msg = photoMessage(20, from: owner, chat: TGChat(id: 42), fileID: "F1", unique: "U1", caption: "cat sleepy")
        await bot.handle(TGUpdate(updateId: 1, message: msg))
        let meme = try #require(try t.collection.search.search("cat sleepy").memes.first)
        #expect(meme.textVerbatim == nil)                                   // caption became tags, not text

        msg.caption = "dog"
        await bot.handle(TGUpdate(updateId: 2, editedMessage: msg))
        let names = Set(try t.collection.memes.tags(of: meme.id).map(\.name))
        #expect(names.contains("dog") && !names.contains("cat") && names.contains("telegram_message"))   // meta tags kept
        #expect(api.sentMessages.last?.text.hasPrefix("Tags updated") == true)
    }

    @Test func replyCommandsWorkInGroups() async throws {
        let t = try TempCollection(), api = FakeTelegram()
        api.files["G1"] = ("photos/file_5.jpg", Data("group-meme".utf8))
        let bot = MemeBot(api: api, collection: t.collection, analyzer: nil, config: BotConfig(allowedUsers: [42]))
        let group = TGChat(id: -500, type: "supergroup", title: "Friends", username: nil)
        let friend = TGUser(id: 99, firstName: "Ann", username: "ann")
        let posted = photoMessage(30, from: friend, chat: group, fileID: "G1", unique: "UG1", caption: "lol look")

        func cmd(_ id: Int, _ text: String, to target: TGMessage? = posted) -> TGUpdate {
            let m = TGMessage(messageId: id, from: owner, chat: group, date: 0, text: text); m.replyToMessage = target
            return TGUpdate(updateId: Int64(id), message: m)
        }
        // A friend's own post in the group is ignored; the owner's /add saves it.
        await bot.handle(TGUpdate(updateId: 1, message: posted))
        #expect(try t.collection.memes.count() == 0)
        await bot.handle(cmd(31, "/add@Memebooru_Test_Bot funny cat"))
        let meme = try #require(try t.collection.search.search("funny cat").memes.first)
        #expect(meme.context == "posted in Friends by Ann @ann" && meme.textVerbatim == "lol look")

        await bot.handle(cmd(32, "/info"))
        #expect(api.sentMessages.last?.text.contains("funny") == true && api.sentMessages.last?.text.contains("Friends") == true)
        await bot.handle(cmd(33, "/deltag funny"))
        await bot.handle(cmd(34, "/addtag wow"))
        #expect(Set(try t.collection.memes.tags(of: meme.id).map(\.name)).isSuperset(of: ["cat", "wow"]))
        #expect(!(try t.collection.memes.tags(of: meme.id).map(\.name)).contains("funny"))
        await bot.handle(cmd(35, "/tags only_this"))
        let after = try t.collection.memes.tags(of: meme.id)
        #expect(after.filter { $0.kind == .normal }.map(\.name) == ["only_this"] && after.contains { $0.kind == .meta })
        await bot.handle(cmd(36, "/add more"))                                  // already saved → just tags
        #expect(try api.sentMessages.last?.text.hasPrefix("Already saved.") == true && t.collection.memes.count() == 1)
        await bot.handle(cmd(37, "/delete"))
        #expect(try t.collection.memes.count() == 0)
        await bot.handle(cmd(38, "/info", to: nil))
        #expect(api.sentMessages.last?.text.hasPrefix("Reply to a meme") == true)
    }

    @Test func lastUsedComeFirstOnEmptyQueryAndEmptyResultsGetAButton() async throws {
        let t = try TempCollection(), api = FakeTelegram()
        let old = Meme(kind: .text, createdAt: 1_000, textVerbatim: "old joke")
        try t.collection.memes.insert(old, tags: ["joke"])
        for i in 0..<3 { try t.collection.memes.insert(Meme(kind: .text, textVerbatim: "new \(i)"), tags: ["joke"]) }
        let bot = MemeBot(api: api, collection: t.collection, analyzer: nil, config: BotConfig(allowedUsers: [42]))

        await bot.handle(TGUpdate(updateId: 1, chosenInlineResult: TGChosenInlineResult(resultId: old.id.rawValue, from: owner)))
        await bot.handle(TGUpdate(updateId: 2, inlineQuery: TGInlineQuery(id: "e", from: owner, query: "")))
        let ids = api.answers[0].results.map(\.id)
        #expect(ids.first == old.id.rawValue && ids.count == 4 && Set(ids).count == 4)

        await bot.handle(TGUpdate(updateId: 3, inlineQuery: TGInlineQuery(id: "n", from: owner, query: "no_such_tag_xyz")))
        #expect(api.answers[1].results.isEmpty && api.answers[1].button != nil)
    }

    @Test func edittagRenamesOrMerges() async throws {
        let t = try TempCollection(), api = FakeTelegram()
        let a = Meme(kind: .text, textVerbatim: "a"), b = Meme(kind: .text, textVerbatim: "b")
        try t.collection.memes.insert(a, tags: ["kot"]); try t.collection.memes.insert(b, tags: ["cat"])
        let bot = MemeBot(api: api, collection: t.collection, analyzer: nil, config: BotConfig(allowedUsers: [42]))
        let chat = TGChat(id: 42)
        await bot.handle(TGUpdate(updateId: 1, message: TGMessage(messageId: 1, from: owner, chat: chat, date: 0, text: "/edittag kot cat")))
        #expect(api.sentMessages.last?.text == "Merged kot into cat.")
        #expect(try t.collection.search.search("cat").memes.count == 2)
        await bot.handle(TGUpdate(updateId: 2, message: TGMessage(messageId: 2, from: owner, chat: chat, date: 0, text: "/edittag cat feline")))
        #expect(try t.collection.search.search("feline").memes.count == 2)
    }

    @Test func statsAndCommandsMenu() async throws {
        let t = try TempCollection(), api = FakeTelegram()
        _ = try imageMeme(t.collection, tag: "cat")
        try t.collection.memes.insert(Meme(kind: .text, textVerbatim: "x"), tags: ["cat", "joke"])
        let bot = MemeBot(api: api, collection: t.collection, analyzer: nil, config: BotConfig(allowedUsers: [42]))
        await bot.handle(TGUpdate(updateId: 1, message: TGMessage(messageId: 1, from: owner, chat: TGChat(id: 42), date: 0, text: "/stats")))
        let text = try #require(api.sentMessages.last?.text)
        #expect(text.hasPrefix("2 posts:") && text.contains("Top tags: cat 2, joke 1") && text.contains("1.5 own tags per post"))
        #expect(MemeBot.commands.map(\.command).contains("edittag"))
    }
}
