import Foundation
import Testing
@testable import MemebooruCore

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

@Suite struct FolderImporterEdgeTests {
    /// A folder tree in the collection's temp dir.
    private func tree(_ t: TempCollection, _ files: [String: String]) throws -> URL {
        let root = t.url.appendingPathComponent("drop-\(UUID().uuidString)", isDirectory: true)
        for (path, content) in files { try write(content, to: root.appendingPathComponent(path)) }
        return root
    }

    @Test func nestedFoldersAreWalkedHiddenOnesSkipped() throws {
        let t = try TempCollection()
        let root = try tree(t, [
            "a.jpg": "a", "sub/b.png": "b", "sub/deeper/c.gif": "c", "sub/deeper/d.mp4": "d",
            ".DS_Store": "junk", "sub/.hidden.jpg": "h", ".git/objects/e.png": "e", "sub/._a.jpg": "appledouble",
        ])
        var seen: [String] = []
        let r = try FolderImporter(staging: t.collection.staging).importFiles([root], progress: { seen.append($0.lastPathComponent) })
        #expect(r.staged.map { $0.originalName ?? "" }.sorted() == ["a.jpg", "b.png", "c.gif", "d.mp4"])
        #expect(r.skipped.isEmpty)
        #expect(seen.sorted() == ["a.jpg", "b.png", "c.gif", "d.mp4"])
        #expect(r.staged.allSatisfy { $0.suggestedTags.contains("source_unknown") && $0.source == "folder" })
        #expect(Set(r.staged.map(\.kind)) == [.image, .gif, .video])
    }

    @Test func unsupportedFilesAreReportedAsSkipped() throws {
        let t = try TempCollection()
        let root = try tree(t, ["notes.pdf": "%PDF", "noext": "?", "archive.tar.gz": "z", "ok.webp": "w", "Thumbs.db": "x"])
        let r = try FolderImporter(staging: t.collection.staging).importFiles([root])
        #expect(r.staged.map(\.ext) == ["webp"])
        #expect(Set(r.skipped.map { $0.0.lastPathComponent }) == ["notes.pdf", "noext", "archive.tar.gz", "Thumbs.db"])
        #expect(r.skipped.allSatisfy { $0.1 == "unsupported" })
    }

    /// Old phone and Flash-era clips come in like any other video, to be converted to MP4 on commit.
    @Test func flvAnd3gpAreVideos() throws {
        let t = try TempCollection()
        let root = try tree(t, ["old.flv": "f", "phone.3GP": "p", "phone2.3g2": "q", "code.ts": "ts"])
        let r = try FolderImporter(staging: t.collection.staging).importFiles([root])
        #expect(r.staged.map(\.ext).sorted() == ["3g2", "3gp", "flv"])
        #expect(r.staged.allSatisfy { $0.kind == .video && $0.compatibility == .uncommon && $0.popularTarget == .mp4H264 })
        #expect(r.skipped.map { $0.0.lastPathComponent } == ["code.ts"])
        #expect(MediaType.detect(ext: "FLV")?.mime == "video/x-flv" && MediaType.detect(ext: "3gp")?.mime == "video/3gpp")
    }

    @Test func missingPathsAndEmptyFoldersAreFine() throws {
        let t = try TempCollection()
        let empty = try tree(t, [:])
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let ghost = t.url.appendingPathComponent("does-not-exist.jpg")
        let r = try FolderImporter(staging: t.collection.staging).importFiles([empty, ghost])
        #expect(r.staged.isEmpty && r.skipped.count == 1 && r.skipped[0].1 == "not found")
        #expect(try FolderImporter(staging: t.collection.staging).importFiles([]).staged.isEmpty)
    }

    @Test func unicodeAndUppercaseNamesKeepTheirNameAndNormaliseTheExtension() throws {
        let t = try TempCollection()
        let root = try tree(t, ["кот 😺.JPG": "cat", "日本/ミーム.Jpeg": "jp", "مرحبا.PNG": "ar", "spaces and #%&.gif": "g"])
        let r = try FolderImporter(staging: t.collection.staging).importFiles([root])
        #expect(r.skipped.isEmpty && r.staged.count == 4)
        let names = Set(r.staged.compactMap(\.originalName).map { $0.precomposedStringWithCanonicalMapping })
        #expect(names == Set(["кот 😺.JPG", "ミーム.Jpeg", "مرحبا.PNG", "spaces and #%&.gif"].map(\.precomposedStringWithCanonicalMapping)))
        #expect(Set(r.staged.map(\.ext)) == ["jpg", "png", "gif"])
        for item in r.staged { #expect(FileManager.default.fileExists(atPath: t.collection.staging.fileURL(item).path)) }
    }

    @Test func theSameFileTwiceIsStagedTwiceAndFlaggedAsADuplicate() throws {
        let t = try TempCollection()
        let root = try tree(t, ["x.png": "same bytes", "copy/x-again.png": "same bytes"])
        let file = root.appendingPathComponent("x.png")
        let area = t.collection.staging
        let r = try FolderImporter(staging: area).importFiles([file, file, root])
        #expect(r.staged.count == 4 && Set(r.staged.map(\.sha256)).count == 1)
        let hits = try area.duplicates(of: r.staged[0])
        #expect(hits.filter { if case .stagedExact = $0.match { return true } else { return false } }.count == 3)
        // Committing one makes the rest exact duplicates of a meme.
        let meme = try area.commit(r.staged[0].id)
        #expect(try area.duplicates(of: r.staged[1]).contains { $0.memeID == meme.id && $0.match == .exact })
    }

    @Test func textFilesBecomeTextMemes() throws {
        let t = try TempCollection()
        let root = try tree(t, ["joke.txt": "Колобок повесился 🫠", "readme.md": "# title"])
        let r = try FolderImporter(staging: t.collection.staging).importFiles([root])
        let joke = try #require(r.staged.first { $0.originalName == "joke.txt" })
        #expect(joke.kind == .text && joke.textVerbatim == "Колобок повесился 🫠")
        #expect(r.staged.count == 2)
    }

    @Test func symlinksDoNotLoopAndAreNeverStoredAsLinks() throws {
        let t = try TempCollection()
        let fm = FileManager.default
        let outside = try tree(t, ["real.jpg": "real bytes"])
        let root = try tree(t, ["own.jpg": "own"])
        try fm.createSymbolicLink(at: root.appendingPathComponent("link.jpg"), withDestinationURL: outside.appendingPathComponent("real.jpg"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)          // a cycle
        try fm.createSymbolicLink(at: root.appendingPathComponent("dangling.jpg"), withDestinationURL: root.appendingPathComponent("nope.jpg"))

        let area = t.collection.staging
        let r = try FolderImporter(staging: area).importFiles([root, root.appendingPathComponent("link.jpg")])
        // The walk terminates; a link passed directly is imported by what it points to.
        let names = r.staged.compactMap(\.originalName)
        #expect(names.contains("own.jpg") && names.contains("link.jpg"))
        for item in r.staged {
            let staged = area.fileURL(item)
            #expect((try? fm.destinationOfSymbolicLink(atPath: staged.path)) == nil, "\(item.originalName ?? "") staged as a link")
        }
        // Committed media must be real files: deleting the link's target must not lose the meme.
        let linked = try #require(r.staged.first { $0.originalName == "link.jpg" })
        let meme = try area.commit(linked.id)
        try fm.removeItem(at: outside)
        let primary = try #require(try t.collection.memes.asset(of: meme.id, role: .primary))
        #expect(try Data(contentsOf: t.collection.media.url(sha256: primary.sha256, ext: primary.ext)) == Data("real bytes".utf8))
    }
}

@Suite struct TelegramExportEdgeTests {
    /// A synthetic Telegram Desktop export: `result.json` + the files it names.
    private func export(_ t: TempCollection, messages: [[String: Any]], files: [String: String], name: String? = "Мемы 🐸") throws -> URL {
        let dir = t.url.appendingPathComponent("tg-\(UUID().uuidString)", isDirectory: true)
        for (path, content) in files { try write(content, to: dir.appendingPathComponent(path)) }
        var root: [String: Any] = ["type": "private_channel", "id": 1, "messages": messages]
        if let name { root["name"] = name }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: root).write(to: dir.appendingPathComponent("result.json"))
        return dir
    }

    private func msg(_ id: Int, _ fields: [String: Any]) -> [String: Any] {
        var m: [String: Any] = ["id": id, "type": "message", "date": "2021-06-15T12:00:00", "date_unixtime": "1623758400", "from": "Me", "text": ""]
        for (k, v) in fields { m[k] = v }
        return m
    }

    private let long = "Достаточно длинный текст анекдота, чтобы стать отдельным мемом в коллекции."

    @Test func everyKindOfMessage() throws {
        let t = try TempCollection()
        let dir = try export(t, messages: [
            msg(1, ["photo": "photos/photo_1.jpg", "width": 800, "height": 600, "text": "подпись"]),
            msg(2, ["file": "video_files/v.mp4", "media_type": "video_file", "mime_type": "video/mp4"]),
            msg(3, ["file": "stickers/s.webp", "media_type": "sticker", "sticker_emoji": "😂"]),
            msg(4, ["file": "voice_messages/audio_1.ogg", "media_type": "voice_message"]),
            msg(5, ["file": "round_video_messages/r.mp4", "media_type": "video_message"]),
            msg(6, ["file": "video_files/anim.mp4", "media_type": "animation"]),
            msg(7, ["text": long]),
            msg(8, ["text": "коротко"]),
            msg(9, ["text": long, "forwarded_from": "Канал «Юмор»"]),
            msg(10, ["photo": "photos/missing.jpg"]),
            msg(11, ["file": "stickers/animated.tgs", "media_type": "sticker"]),
            msg(12, ["photo": "(File not included. Change data exporting settings to download.)"]),
            ["id": 13, "type": "service", "date": "2021-06-15T12:00:00", "action": "pin_message"],
            msg(14, ["text": [["type": "bold", "text": "Жирный "], "и ", ["type": "link", "text": "https://example.com"],
                              ["type": "custom_emoji", "text": "🔥", "document_id": "1"], " — и ещё немного текста для длины."] as [Any]]),
        ], files: ["photos/photo_1.jpg": "p", "video_files/v.mp4": "v", "stickers/s.webp": "s", "voice_messages/audio_1.ogg": "o",
                   "round_video_messages/r.mp4": "r", "video_files/anim.mp4": "a", "stickers/animated.tgs": "t"])

        var seen: [String] = []
        let r = try TelegramExportImporter(staging: t.collection.staging).importExport(at: dir, progress: { seen.append($0) })
        let byName = Dictionary(r.staged.compactMap { i in i.originalName.map { ($0, i) } }, uniquingKeysWith: { a, _ in a })

        // Default options: stickers yes, voice / round videos no, short texts no.
        #expect(Set(byName.keys).isSuperset(of: ["photo_1.jpg", "v.mp4", "s.webp", "anim.mp4"]))
        #expect(byName["audio_1.ogg"] == nil && byName["r.mp4"] == nil)
        #expect(byName["photo_1.jpg"]?.textVerbatim == "подпись" && byName["photo_1.jpg"]?.kind == .image)
        #expect(byName["s.webp"]?.suggestedTags.contains("sticker") == true)
        #expect(byName["anim.mp4"]?.suggestedTags.contains("gif") == true)
        #expect(byName["v.mp4"]?.textVerbatim == nil && byName["v.mp4"]?.kind == .video)
        #expect(r.staged.allSatisfy { $0.suggestedTags.contains("telegram_message") && $0.suggestedTags.contains("2021") && $0.source == "telegram:Мемы 🐸" })

        let texts = r.staged.filter { $0.kind == .text }
        #expect(texts.count == 3)
        #expect(texts.contains { $0.context?.contains("forwarded from Канал «Юмор»") == true })
        #expect(texts.contains { $0.textVerbatim == "Жирный и https://example.com🔥 — и ещё немного текста для длины." })
        #expect(!texts.contains { $0.textVerbatim == "коротко" })

        let skipped = Dictionary(r.skipped.map { ($0.0.lastPathComponent, $0.1) }, uniquingKeysWith: { a, _ in a })
        #expect(skipped["missing.jpg"] == "missing file")
        #expect(skipped["animated.tgs"] == "unsupported")
        #expect(skipped["(File not included. Change data exporting settings to download.)"] == "missing file")
        #expect(r.staged.count + r.skipped.count == 10)
        #expect(seen.contains("photos/photo_1.jpg") && seen.contains { $0.hasPrefix("text #") })
        #expect(try t.collection.memes.count() == 0)                          // staging only
    }

    @Test func optionsSwitchKindsOnAndOff() throws {
        let t = try TempCollection()
        let dir = try export(t, messages: [
            msg(1, ["file": "stickers/s.webp", "media_type": "sticker"]),
            msg(2, ["file": "voice_messages/a.ogg", "media_type": "voice_message"]),
            msg(3, ["file": "round_video_messages/r.mp4", "media_type": "video_message"]),
            msg(4, ["text": "ровно сорок символов? нет, двадцать"]),
            msg(5, ["text": long]),
        ], files: ["stickers/s.webp": "s", "voice_messages/a.ogg": "o", "round_video_messages/r.mp4": "r"])
        var o = TelegramExportImporter.Options()
        o.includeStickers = false; o.includeVoice = true; o.includeTextMessages = true; o.minTextLength = 5
        let r = try TelegramExportImporter(staging: t.collection.staging, options: o).importExport(at: dir)
        #expect(Set(r.staged.compactMap(\.originalName)).isSuperset(of: ["a.ogg", "r.mp4"]))
        #expect(!r.staged.contains { $0.originalName == "s.webp" })
        #expect(r.staged.filter { $0.kind == .text }.count == 2)
        #expect(r.staged.first { $0.originalName == "a.ogg" }?.kind == .audio)

        var noText = TelegramExportImporter.Options(); noText.includeTextMessages = false
        let none = try TelegramExportImporter(staging: t.collection.staging, options: noText).importExport(at: dir)
        #expect(!none.staged.contains { $0.kind == .text })
    }

    @Test func datesComeFromUnixTimeThenTheLocalDate() throws {
        let t = try TempCollection()
        let dir = try export(t, messages: [
            ["id": 1, "type": "message", "date": "2019-07-01T10:00:00", "text": "Сообщение без unixtime, но достаточно длинное для импорта."],
            ["id": 2, "type": "message", "date_unixtime": "1435752000", "date": "2030-01-01T00:00:00",
             "text": "Сообщение с unixtime, которое важнее строки даты в экспорте."],
            ["id": 3, "type": "message", "date": "not a date", "text": "Сообщение с битой датой, которое всё равно должно импортироваться."],
        ], files: [:])
        let r = try TelegramExportImporter(staging: t.collection.staging).importExport(at: dir)
        #expect(r.staged.count == 3)
        #expect(r.staged[0].suggestedTags.contains("2019"))
        #expect(r.staged[1].suggestedTags.contains("2015"))
        #expect(r.staged[2].context?.contains("not a date") == true)
    }

    @Test func aChatWithoutANameAndMessagesWithoutSenders() throws {
        let t = try TempCollection()
        let dir = try export(t, messages: [["id": 1, "type": "message", "text": long]], files: [:], name: nil)
        let r = try TelegramExportImporter(staging: t.collection.staging).importExport(at: dir)
        #expect(r.staged.first?.source == "telegram:Telegram" && r.staged.first?.context == "Telegram: Telegram")
    }

    @Test func unreadableExportsThrow() throws {
        let t = try TempCollection()
        let area = t.collection.staging
        let empty = t.url.appendingPathComponent("empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(throws: CollectionError.self) { try TelegramExportImporter(staging: area).importExport(at: empty) }
        try Data("{not json".utf8).write(to: empty.appendingPathComponent("result.json"))
        #expect(throws: (any Error).self) { try TelegramExportImporter(staging: area).importExport(at: empty) }
        try Data(#"{"name":"x"}"#.utf8).write(to: empty.appendingPathComponent("result.json"))
        #expect(throws: CollectionError.self) { try TelegramExportImporter(staging: area).importExport(at: empty) }
        try Data(#"{"name":"x","messages":[]}"#.utf8).write(to: empty.appendingPathComponent("result.json"))
        #expect(try TelegramExportImporter(staging: area).importExport(at: empty).staged.isEmpty)
    }

    @Test func flattenHandlesEveryTextShape() {
        #expect(TelegramExportImporter.flatten("plain") == "plain")
        #expect(TelegramExportImporter.flatten(nil) == "")
        #expect(TelegramExportImporter.flatten(42) == "")
        #expect(TelegramExportImporter.flatten(["a", ["type": "bold", "text": "b"], ["type": "weird"], 7, "c"] as [Any]) == "abc")
    }
}
