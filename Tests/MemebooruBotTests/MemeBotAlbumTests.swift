import Foundation
import Testing
import MemebooruCore
@testable import MemebooruBot

/// Pictures for album tests: `PIC w h shade` decodes to a solid w × h picture (anything after the first
/// line is ignored, so files can differ yet look the same); the "encoded" combined picture is
/// `RAW w h` + its pixels, which decodes too. No ImageIO / stb needed, same on Linux.
enum AlbumPictures {
    static func data(_ w: Int, _ h: Int, shade: UInt8, salt: String) -> Data { Data("PIC \(w) \(h) \(shade)\n\(salt)".utf8) }

    static func encode(_ b: Bitmap) -> Data {
        var d = Data("RAW \(b.width) \(b.height)\n".utf8)
        d.append(b.rgba)
        return d
    }

    static func decode(_ d: Data) -> Bitmap? {
        guard let nl = d.firstIndex(of: 10) else { return nil }
        let head = String(decoding: d[d.startIndex..<nl], as: UTF8.self).split(separator: " ")
        guard head.count >= 3, let w = Int(head[1]), let h = Int(head[2]), w > 0, h > 0 else { return nil }
        switch head[0] {
        case "RAW":
            let px = d[(nl + 1)...]
            return px.count == w * h * 4 ? Bitmap(width: w, height: h, rgba: Data(px)) : nil
        case "PIC":
            let shade = head.count > 3 ? UInt8(head[3]) ?? 0 : 0
            var px = Data(repeating: shade, count: w * h * 4)
            for i in stride(from: 3, to: px.count, by: 4) { px[i] = 255 }
            return Bitmap(width: w, height: h, rgba: px)
        default: return nil
        }
    }
}

struct AlbumMedia: ImageDecoder, VideoProbe, ThumbnailEncoder, HTTPClient {
    struct Unsupported: Error {}
    func decode(_ url: URL, maxSide: Int) throws -> Bitmap {
        guard let b = AlbumPictures.decode(try Data(contentsOf: url)) else { throw Unsupported() }
        return b
    }
    func imageSize(_ url: URL) throws -> (width: Int, height: Int) { let b = try decode(url, maxSide: 0); return (b.width, b.height) }
    func durationMs(_ url: URL) throws -> Int64 { throw Unsupported() }
    func frame(_ url: URL, at fraction: Double, maxSide: Int) throws -> Bitmap { throw Unsupported() }
    func jpeg(_ bitmap: Bitmap, quality: Double) throws -> Data { AlbumPictures.encode(bitmap) }
    func encode(_ bitmap: Bitmap, as format: MediaFormat, quality: Double) throws -> Data? { AlbumPictures.encode(bitmap) }
    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse { throw Unsupported() }
    static var analyzer: MediaAnalyzer {
        let f = AlbumMedia()
        return MediaAnalyzer(platform: Platform(images: f, video: f, thumbs: f, http: f))
    }
}

/// A clock the test moves by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_700_000_000)
    var now: Date { lock.withLock { t } }
    func advance(_ s: TimeInterval) { lock.withLock { t = t.addingTimeInterval(s) } }
}

@Suite struct MemeBotAlbumTests {
    let owner = TGUser(id: 42, firstName: "Owner", username: "owner")
    let chat = TGChat(id: 42)

    private func bot(_ t: TempCollection, _ api: FakeTelegram, analyzer: MediaAnalyzer? = AlbumMedia.analyzer,
                     wait: TimeInterval = 0, users: Set<Int64> = [42], clock: TestClock? = nil) -> MemeBot {
        var cfg = BotConfig(allowedUsers: users); cfg.albumWait = wait
        let b = MemeBot(api: api, collection: t.collection, analyzer: analyzer, config: cfg)
        b.log = { _ in }
        if let clock { b.now = { clock.now } }
        return b
    }

    /// A photo message of album `group`; its file (a w × h picture) is served by `api`.
    private func photo(_ api: FakeTelegram, _ id: Int, group: String?, file: String, chat: TGChat? = nil, from: TGUser? = nil,
                       caption: String? = nil, w: Int = 40, h: Int = 60, shade: UInt8 = 100, bytesOf: String? = nil) -> TGMessage {
        api.files[file] = ("photos/\(file).jpg", AlbumPictures.data(w, h, shade: shade, salt: bytesOf ?? file))
        let m = TGMessage(messageId: id, from: from ?? owner, chat: chat ?? self.chat, date: 1_700_000_000)
        var f = TGFileRef(fileId: file); f.fileUniqueId = "U-\(file)"; f.width = w; f.height = h
        m.photo = [f]; m.caption = caption; m.mediaGroupId = group
        return m
    }

    private func sha(_ api: FakeTelegram, _ file: String) -> String { MediaStore.sha256(of: api.files[file]!.data) }

    private func send(_ b: MemeBot, _ m: TGMessage) async { await b.handle(TGUpdate(updateId: Int64(m.messageId), message: m)) }

    private func combinedMemes(_ c: Collection) throws -> [Meme] { try c.search.search(compositeTag).memes }

    // MARK: -

    @Test func albumOfTwoPhotosIsOneCombinedMemeInMessageOrder() async throws {
        let t = try TempCollection(), api = FakeTelegram()
        let b = bot(t, api)
        let first = photo(api, 10, group: "g1", file: "A", shade: 10)
        let second = photo(api, 11, group: "g1", file: "B", shade: 200)
        await send(b, second)                                     // order of arrival doesn't matter: message ids do
        await send(b, first)
        #expect(try t.collection.memes.count() == 0 && api.sentMessages.isEmpty)   // waiting for the rest of the album

        await b.flushDueAlbums()
        let memes = try combinedMemes(t.collection)
        let meme = try #require(memes.first)
        #expect(memes.count == 1 && meme.kind == .image && meme.payload.composite?.layout.arrangement == .row)
        #expect(try t.collection.parts(of: meme.id).map(\.sha256) == [sha(api, "A"), sha(api, "B")])
        let primary = try #require(try t.collection.memes.primaryAsset(of: meme.id))
        #expect(primary.width == 80 && primary.height == 60)
        let tags = Set(try t.collection.memes.tags(of: meme.id).map(\.name))
        #expect(tags.isSuperset(of: [compositeTag, "telegram_message", "picture", "2023"]))
        #expect(api.sentMessages.count == 1 && api.sentMessages[0].text.hasPrefix("Saved 2 pictures combined into one meme"))
        #expect(api.sentReplies[0].replyTo == 10)
        #expect(try t.collection.staging.list().isEmpty)          // nothing left behind in staging
        #expect(try t.collection.undo.lastUndoable() == nil)     // a bot save isn't an undo step (an undo mustn't stage the photos)
        #expect(try t.collection.memes.count() == 1)

        await b.flushDueAlbums()                                  // nothing more to do
        #expect(try t.collection.memes.count() == 1 && api.sentMessages.count == 1)
    }

    @Test func albumOfFourPhotosIsATwoByTwoGrid() async throws {
        let t = try TempCollection(), api = FakeTelegram()
        let b = bot(t, api)
        let files = ["P1", "P2", "P3", "P4"]
        for (i, f) in files.enumerated() { await send(b, photo(api, 20 + i, group: "four", file: f, shade: UInt8(40 * i))) }
        await b.flushDueAlbums()
        let meme = try #require(try combinedMemes(t.collection).first)
        #expect(try t.collection.memes.count() == 1)
        #expect(meme.payload.composite?.layout == CompositeLayout(.grid, columns: 2))
        #expect(try t.collection.parts(of: meme.id).map(\.sha256) == files.map { sha(api, $0) })
        #expect(api.sentMessages.last?.text.hasPrefix("Saved 4 pictures combined") == true)
    }

    @Test func interleavedAlbumsOfTwoChatsStayApart() async throws {
        let t = try TempCollection(), api = FakeTelegram()
        let b = bot(t, api, users: [42, 43])
        let other = TGUser(id: 43, firstName: "Second", username: nil), otherChat = TGChat(id: 43)
        // The same media_group_id in both chats: the chat is part of what makes an album.
        await send(b, photo(api, 10, group: "g", file: "A1"))
        await send(b, photo(api, 11, group: "g", file: "B1", chat: otherChat, from: other))
        await send(b, photo(api, 12, group: "g", file: "A2"))
        await send(b, photo(api, 13, group: "g", file: "B2", chat: otherChat, from: other))
        await send(b, photo(api, 14, group: "g", file: "A3"))
        await b.flushDueAlbums()

        let memes = try combinedMemes(t.collection)
        #expect(try memes.count == 2 && t.collection.memes.count() == 2)
        let partSets = try memes.map { try t.collection.parts(of: $0.id).map(\.sha256) }
        #expect(partSets.contains(["A1", "A2", "A3"].map { sha(api, $0) }))
        #expect(partSets.contains(["B1", "B2"].map { sha(api, $0) }))
        #expect(Set(api.sentMessages.map(\.chat)) == [42, 43] && api.sentMessages.count == 2)
        #expect(api.sentMessages.first { $0.chat == 42 }?.text.hasPrefix("Saved 3 pictures") == true)
        #expect(api.sentMessages.first { $0.chat == 43 }?.text.hasPrefix("Saved 2 pictures") == true)
    }

    @Test func ownAlbumCaptionIsItsTagsAndEditingItRetags() async throws {
        let t = try TempCollection(), api = FakeTelegram()
        let b = bot(t, api)
        let captioned = photo(api, 31, group: "c", file: "C2", caption: "cat sleepy")
        await send(b, photo(api, 30, group: "c", file: "C1"))
        await send(b, captioned)
        await b.flushDueAlbums()
        let meme = try #require(try combinedMemes(t.collection).first)
        #expect(meme.textVerbatim == nil)
        #expect(Set(try t.collection.memes.tags(of: meme.id).map(\.name)).isSuperset(of: ["cat", "sleepy", compositeTag]))

        captioned.caption = "dog"
        await b.handle(TGUpdate(updateId: 99, editedMessage: captioned))
        let names = Set(try t.collection.memes.tags(of: meme.id).map(\.name))
        #expect(names.contains("dog") && !names.contains("cat") && names.contains(compositeTag))
    }

    @Test func forwardedAlbumCaptionIsTheMemesText() async throws {
        let t = try TempCollection(), api = FakeTelegram()
        let b = bot(t, api)
        let origin = TGOrigin(type: "channel", date: 1_600_000_000, chat: TGChat(id: -100, type: "channel", title: "Memes", username: "memes"))
        for (i, f) in ["F1", "F2", "F3"].enumerated() {
            let m = photo(api, 40 + i, group: "fwd", file: f, caption: i == 0 ? "when the build is green" : nil)
            m.forwardOrigin = origin
            await send(b, m)
        }
        await b.flushDueAlbums()
        let meme = try #require(try combinedMemes(t.collection).first)
        #expect(meme.textVerbatim == "when the build is green" && meme.context == "forwarded from Memes @memes")
        let tags = Set(try t.collection.memes.tags(of: meme.id).map(\.name))
        #expect(tags.contains("2020") && !tags.contains("when"))                     // year of the post; the caption isn't tags
    }

    @Test func addToOnePhotoOfAGroupAlbumSavesTheWholeAlbum() async throws {
        let t = try TempCollection(), api = FakeTelegram()
        let b = bot(t, api)
        let group = TGChat(id: -500, type: "supergroup", title: "Friends", username: nil)
        let ann = TGUser(id: 99, firstName: "Ann", username: "ann")
        let p1 = photo(api, 50, group: "ga", file: "G1", chat: group, from: ann, caption: "lol look")
        let p2 = photo(api, 51, group: "ga", file: "G2", chat: group, from: ann)
        await send(b, p1); await send(b, p2)
        await b.flushAlbums()
        #expect(try t.collection.memes.count() == 0 && api.sentMessages.isEmpty)    // a group's album is only remembered

        let add = TGMessage(messageId: 52, from: owner, chat: group, date: 0, text: "/add funny")
        add.replyToMessage = p2
        await send(b, add)
        let meme = try #require(try combinedMemes(t.collection).first)
        #expect(try t.collection.memes.count() == 1 && t.collection.parts(of: meme.id).map(\.sha256) == [sha(api, "G1"), sha(api, "G2")])
        #expect(meme.textVerbatim == "lol look" && meme.context == "posted in Friends by Ann @ann")
        #expect(try t.collection.memes.tags(of: meme.id).map(\.name).contains("funny"))
        #expect(api.sentReplies.last?.replyTo == 52 && api.sentMessages.last?.text.hasPrefix("Saved 2 pictures combined") == true)

        // /add to the other photo: it's known (by Telegram's id of the picture) — just tags.
        let again = TGMessage(messageId: 53, from: owner, chat: group, date: 0, text: "/add more")
        again.replyToMessage = p1
        await send(b, again)
        #expect(try t.collection.memes.count() == 1 && api.sentMessages.last?.text.hasPrefix("Already saved.") == true)
        #expect(try t.collection.memes.tags(of: meme.id).map(\.name).contains("more"))

        // A group album I never saw the rest of: /add saves the one photo it replies to.
        let lone = photo(api, 60, group: "unseen", file: "G9", chat: group, from: ann)
        let add2 = TGMessage(messageId: 61, from: owner, chat: group, date: 0, text: "/add")
        add2.replyToMessage = lone
        await send(b, add2)
        #expect(try t.collection.memes.count() == 2 && api.sentMessages.last?.text.hasPrefix("Saved (image)") == true)
    }

    @Test func addToAnAlbumStillArrivingSavesItAtOnceWithItsTags() async throws {
        let t = try TempCollection(), api = FakeTelegram()
        let b = bot(t, api, wait: 60)
        let p1 = photo(api, 70, group: "w", file: "W1", caption: "cat")
        await send(b, p1)
        await send(b, photo(api, 71, group: "w", file: "W2"))
        let add = TGMessage(messageId: 72, from: owner, chat: chat, date: 0, text: "/add extra")
        add.replyToMessage = p1
        await send(b, add)
        let meme = try #require(try combinedMemes(t.collection).first)
        #expect(Set(try t.collection.memes.tags(of: meme.id).map(\.name)).isSuperset(of: ["cat", "extra"]))
        #expect(api.sentReplies.last?.replyTo == 72)
        await b.flushAlbums()
        #expect(try t.collection.memes.count() == 1 && api.sentMessages.count == 1)
    }

    @Test func replyingSplitToTheAnswerMakesSeparateMemes() async throws {
        let t = try TempCollection(), api = FakeTelegram()
        let b = bot(t, api)
        await send(b, photo(api, 10, group: "s", file: "S1", caption: "cat"))
        await send(b, photo(api, 11, group: "s", file: "S2"))
        await b.flushDueAlbums()
        let combined = try #require(try combinedMemes(t.collection).first)
        let answer = TGMessage(messageId: try #require(api.sentReplies.last?.id), from: nil, chat: chat, date: 0)

        let split = TGMessage(messageId: 12, from: owner, chat: chat, date: 0, text: "Split")
        split.replyToMessage = answer
        await send(b, split)
        #expect(api.sentMessages.last?.text.hasPrefix("Split into 2 memes") == true)
        #expect(try t.collection.memes.get(combined.id)?.deletedAt != nil && combinedMemes(t.collection).isEmpty)
        let parts = try t.collection.search.search("cat").memes
        #expect(parts.count == 2 && parts.allSatisfy { $0.kind == .image && $0.payload == .none })
        #expect(Set(try parts.map { try t.collection.memes.primaryAsset(of: $0.id)!.sha256 }) == [sha(api, "S1"), sha(api, "S2")])
        #expect(try parts.allSatisfy { !(try t.collection.memes.tags(of: $0.id).map(\.name).contains(compositeTag)) })

        // The separate pictures answer inline with the file ids Telegram gave the album: no upload.
        await b.handle(TGUpdate(updateId: 50, inlineQuery: TGInlineQuery(id: "q", from: owner, query: "cat")))
        #expect(api.uploads.isEmpty && Set(api.answers.last?.results.compactMap(\.photoFileId) ?? []) == ["S1", "S2"])

        // One undo step brings the combined meme back.
        #expect(try t.collection.undoLast() == "Split into 2 pictures")
        #expect(try combinedMemes(t.collection).map(\.id) == [combined.id] && t.collection.memes.count() == 1)
    }

    @Test func slashSplitRepliedToAPhotoOfTheAlbum() async throws {
        let t = try TempCollection(), api = FakeTelegram()
        let b = bot(t, api)
        let p1 = photo(api, 10, group: "s", file: "S1")
        await send(b, p1)
        await send(b, photo(api, 11, group: "s", file: "S2"))
        await send(b, photo(api, 12, group: "s", file: "S3"))
        await b.flushDueAlbums()
        let cmd = TGMessage(messageId: 13, from: owner, chat: chat, date: 0, text: "/split")
        cmd.replyToMessage = p1
        await send(b, cmd)
        #expect(try t.collection.memes.count() == 3 && combinedMemes(t.collection).isEmpty)
        #expect(api.sentMessages.last?.text.hasPrefix("Split into 3 memes") == true)

        // Not a combined meme (any more): /split says so, and "split" in reply to a single save is just a tag.
        await send(b, cmd)
        #expect(api.sentMessages.last?.text == "That isn't a combined meme.")
        let single = photo(api, 20, group: nil, file: "ONE")
        await send(b, single)
        let saved = try #require(api.sentReplies.last?.id)
        let word = TGMessage(messageId: 21, from: owner, chat: chat, date: 0, text: "split")
        word.replyToMessage = TGMessage(messageId: saved, from: nil, chat: chat, date: 0)
        await send(b, word)
        #expect(try t.collection.search.search("split").memes.count == 1)
        let bare = TGMessage(messageId: 22, from: owner, chat: chat, date: 0, text: "/split")
        await send(b, bare)
        #expect(api.sentMessages.last?.text.hasPrefix("Reply /split") == true)
    }

    @Test func theSameAlbumTwiceIsSavedOnce() async throws {
        let t = try TempCollection(), api = FakeTelegram()
        let b = bot(t, api)
        await send(b, photo(api, 10, group: "d1", file: "D1"))
        await send(b, photo(api, 11, group: "d1", file: "D2"))
        await b.flushDueAlbums()
        // Sent again: new messages, new album id, same pictures.
        await send(b, photo(api, 20, group: "d2", file: "D1", caption: "again"))
        await send(b, photo(api, 21, group: "d2", file: "D2"))
        await b.flushDueAlbums()
        #expect(try t.collection.memes.count() == 1)
        #expect(api.sentMessages.last?.text.hasPrefix("Already in the collection.") == true)
        let meme = try #require(try combinedMemes(t.collection).first)
        #expect(try t.collection.memes.tags(of: meme.id).map(\.name).contains("again"))
        // The same pictures from somewhere else (other Telegram files, same bytes), in another order: the
        // combined picture would differ, but they're the same pictures — still the same meme.
        await send(b, photo(api, 30, group: "d3", file: "E2", bytesOf: "D2"))
        await send(b, photo(api, 31, group: "d3", file: "E1", bytesOf: "D1"))
        await b.flushDueAlbums()
        #expect(try t.collection.memes.count() == 1 && api.sentMessages.last?.text.hasPrefix("Already in the collection.") == true)
        #expect(try t.collection.staging.list().isEmpty)
        #expect(api.sentMessages.count == 3)
        // Other files that make exactly the same combined picture: that picture is already there.
        await send(b, photo(api, 40, group: "d4", file: "X1"))
        await send(b, photo(api, 41, group: "d4", file: "X2"))
        await b.flushDueAlbums()
        #expect(try t.collection.memes.count() == 1 && api.sentMessages.last?.text.hasPrefix("Already in the collection.") == true)
        #expect(try t.collection.staging.list().isEmpty)
        // Different pictures: a new meme.
        await send(b, photo(api, 50, group: "d5", file: "Y1", shade: 1))
        await send(b, photo(api, 51, group: "d5", file: "Y2", shade: 2))
        await b.flushDueAlbums()
        #expect(try combinedMemes(t.collection).count == 2)
    }

    @Test func mixedAlbumCombinesOnlyThePhotos() async throws {
        let t = try TempCollection(), api = FakeTelegram()
        let b = bot(t, api)
        api.files["V1"] = ("videos/file_1.mp4", Data("video-bytes".utf8))
        api.files["DOC"] = ("documents/file_2.gif", Data("GIF89a-not-really".utf8))
        let video = TGMessage(messageId: 11, from: owner, chat: chat, date: 1_700_000_000)
        var v = TGFileRef(fileId: "V1"); v.fileUniqueId = "U-V1"
        video.video = v; video.mediaGroupId = "mix"; video.caption = "mixed bag"
        let doc = TGMessage(messageId: 13, from: owner, chat: chat, date: 1_700_000_000)
        var d = TGFileRef(fileId: "DOC", fileName: "clip.gif"); d.fileUniqueId = "U-DOC"
        doc.document = d; doc.mediaGroupId = "mix"
        await send(b, photo(api, 10, group: "mix", file: "M1"))
        await send(b, video)
        await send(b, photo(api, 12, group: "mix", file: "M2"))
        await send(b, doc)
        await b.flushDueAlbums()

        #expect(try t.collection.memes.count() == 3)
        let meme = try #require(try combinedMemes(t.collection).first)
        #expect(try t.collection.parts(of: meme.id).map(\.sha256) == [sha(api, "M1"), sha(api, "M2")])
        let kinds = try t.collection.search.search("mixed bag").memes.map(\.kind)
        #expect(Set(kinds) == [.image, .video, .gif] && kinds.count == 3)          // the album's caption goes with all of it
        #expect(api.sentMessages.map { String($0.text.prefix(12)) } == ["Saved 2 pict", "Saved (video", "Saved (gif):"])

        // One photo with a video: nothing to combine.
        let t2 = try TempCollection(), api2 = FakeTelegram()
        let b2 = bot(t2, api2)
        api2.files["V1"] = api.files["V1"]
        let video2 = TGMessage(messageId: 2, from: owner, chat: chat, date: 0)
        video2.video = v; video2.mediaGroupId = "pv"
        await send(b2, photo(api2, 1, group: "pv", file: "ALONE"))
        await send(b2, video2)
        await b2.flushDueAlbums()
        #expect(try t2.collection.memes.count() == 2 && combinedMemes(t2.collection).isEmpty)
        #expect(api2.sentMessages.map { String($0.text.prefix(12)) } == ["Saved (image", "Saved (video"])
    }

    @Test func aOnePhotoAlbumIsJustAPhoto() async throws {
        let t = try TempCollection(), api = FakeTelegram()
        let b = bot(t, api)
        await send(b, photo(api, 10, group: "solo", file: "SOLO", caption: "cat"))
        await b.flushDueAlbums()
        let meme = try #require(try t.collection.search.search("cat").memes.first)
        #expect(try meme.payload == .none && t.collection.memes.count() == 1)
        #expect(api.sentMessages.last?.text.hasPrefix("Saved (image)") == true)
    }

    @Test func withoutMediaToolsAlbumPhotosAreSavedSeparately() async throws {
        let t = try TempCollection(), api = FakeTelegram()
        let b = bot(t, api, analyzer: nil)
        await send(b, photo(api, 10, group: "n", file: "N1", caption: "cat"))
        await send(b, photo(api, 11, group: "n", file: "N2"))
        await b.flushDueAlbums()
        #expect(try t.collection.search.search("cat").memes.count == 2 && combinedMemes(t.collection).isEmpty)
    }

    /// The album waits `albumWait` after its latest message. A message of the same album that comes after
    /// the album was saved starts a new one: here a lone photo, saved as a meme of its own.
    @Test func albumWaitsForItsLastMessageAndALateOneIsSavedOnItsOwn() async throws {
        let t = try TempCollection(), api = FakeTelegram(), clock = TestClock()
        let b = bot(t, api, wait: 1, clock: clock)
        await send(b, photo(api, 10, group: "late", file: "L1"))
        #expect(b.albumDue() == clock.now.addingTimeInterval(1))
        clock.advance(0.5); await b.flushDueAlbums()
        #expect(try t.collection.memes.count() == 0)
        clock.advance(0.25); await send(b, photo(api, 11, group: "late", file: "L2"))
        #expect(b.albumDue() == clock.now.addingTimeInterval(1))   // the wait starts again
        clock.advance(0.5); await b.flushDueAlbums()             // 1.25 s since the first, 0.5 since the latest: still waiting
        #expect(try t.collection.memes.count() == 0)
        clock.advance(0.5); await b.flushDueAlbums()             // exactly 1 s since the latest
        #expect(try t.collection.memes.count() == 1 && combinedMemes(t.collection).count == 1)
        #expect(b.albumDue() == nil)

        clock.advance(0.125); await send(b, photo(api, 12, group: "late", file: "L3"))
        clock.advance(1); await b.flushDueAlbums()
        #expect(try t.collection.memes.count() == 2 && combinedMemes(t.collection).count == 1)
        #expect(api.sentMessages.last?.text.hasPrefix("Saved (image)") == true)
        let combined = try #require(try combinedMemes(t.collection).first)
        #expect(try t.collection.parts(of: combined.id).count == 2)

        // flushAlbums saves whatever has arrived, due or not.
        await send(b, photo(api, 20, group: "now", file: "N1", shade: 30))
        await send(b, photo(api, 21, group: "now", file: "N2", shade: 60))
        await b.flushAlbums()
        #expect(try combinedMemes(t.collection).count == 2)
    }

    @Test func aCombinedMemeIsAnsweredInlineWithItsCombinedPicture() async throws {
        let t = try TempCollection(), api = FakeTelegram()
        let b = bot(t, api)
        await send(b, photo(api, 10, group: "i", file: "I1"))
        await send(b, photo(api, 11, group: "i", file: "I2"))
        await b.flushDueAlbums()
        let meme = try #require(try combinedMemes(t.collection).first)
        let primary = try #require(try t.collection.memes.primaryAsset(of: meme.id))

        await b.handle(TGUpdate(updateId: 1, inlineQuery: TGInlineQuery(id: "q1", from: owner, query: compositeTag)))
        let r = try #require(api.answers.last?.results.first)
        #expect(r.type == "photo" && r.id == meme.id.rawValue && r.photoFileId?.hasPrefix("uploaded-") == true)
        #expect(api.uploads.count == 1 && api.uploads[0].kind == .photo && api.uploads[0].name == "\(primary.sha256).\(primary.ext)")
        await b.handle(TGUpdate(updateId: 2, inlineQuery: TGInlineQuery(id: "q2", from: owner, query: compositeTag)))
        #expect(api.uploads.count == 1 && api.answers.last?.results.first?.photoFileId == r.photoFileId)
    }

    @Test func mediaGroupIDDecodesFromBotAPIJSON() throws {
        let json = """
            {"update_id": 9, "message": {"message_id": 3, "date": 1700000000, "media_group_id": "13579",
              "from": {"id": 42, "is_bot": false, "first_name": "O"}, "chat": {"id": 42, "type": "private"},
              "photo": [{"file_id": "P", "file_unique_id": "u", "width": 90, "height": 90}]}}
            """
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
        let u = try d.decode(TGUpdate.self, from: Data(json.utf8))
        #expect(u.message?.mediaGroupId == "13579" && u.message?.photo?.first?.fileId == "P")
    }
}
