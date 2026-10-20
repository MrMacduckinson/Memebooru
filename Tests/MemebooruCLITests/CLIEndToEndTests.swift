import Foundation
import Testing
import MemebooruCore
@testable import memebooru

/// Whole workflows through the CLI against a temp collection: real files, real decoder, real SQLite.
/// Product rule checked throughout: imports land in STAGING, never directly in the collection.
@Suite struct CLIEndToEndTests {
    /// Folder with pictures (incl. an exact copy, a nested one, a hidden one, an unsupported file),
    /// paths with spaces and Cyrillic.
    struct Incoming {
        let dir: TempDir
        var folder: URL { dir.url.appendingPathComponent("incoming folder") }
        let horizontal: URL, vertical: URL, checker: URL, copy: URL, rings: URL
        let pngBytes: Data

        init() throws {
            dir = try TempDir("mb incoming")
            pngBytes = try Samples.png(.horizontal)
            horizontal = try dir.write("incoming folder/горизонт.png", pngBytes)
            vertical = try dir.write("incoming folder/vertical one.png", try Samples.png(.vertical))
            checker = try dir.write("incoming folder/sub dir/шахматы.png", try Samples.png(.checker))
            copy = try dir.write("incoming folder/copy of горизонт.png", pngBytes)
            try dir.write("incoming folder/readme.xyz", Data("not media".utf8))
            try dir.write("incoming folder/.hidden.png", try Samples.png(.checker))
            rings = try dir.write("elsewhere/кольца.png", try Samples.png(.rings))
        }
    }

    /// Staged id (8-char prefix) of the item whose original name is `name`, from `stage ls`.
    static func stagedID(_ ls: CLIResult, _ name: String) throws -> String {
        let line = try #require(ls.lines.first { $0.contains("← \(name)") }, "no staged \(name) in\n\(ls.out)")
        return String(line.prefix(8))
    }

    /// Full meme ids printed by `search`, in order.
    static func memeIDs(_ search: CLIResult) -> [String] {
        search.lines.dropLast().map { String($0.prefix(while: { !$0.isWhitespace })) }
    }

    static func count(_ search: CLIResult) -> Int? {
        guard let last = search.lines.last, let n = Int(last.prefix(while: \.isNumber)) else { return nil }
        return n
    }

    // MARK: - The main flow

    @Test func importStageCommitTagSearchDedupExportUndo() async throws {
        let c = try await CLICollection()
        let inc = try Incoming()

        // init made the folder (spaces + Cyrillic in the name) and `info` reads it.
        var r = await c.run("info")
        #expect(r.ok && r.out.contains("collection: Мемы и картинки") && r.out.contains("memes:      0"), "\(r)")

        // ---- import a folder: everything goes to staging
        r = await c.run("add", inc.folder.path, "-t", "Котики", "funny")
        #expect(r.ok, "\(r)")
        #expect(r.out.contains("  + горизонт.png") && r.out.contains("  + шахматы.png") && r.out.contains("  + vertical one.png"), "\(r)")
        #expect(r.out.contains("skip readme.xyz: unsupported") && !r.out.contains(".hidden.png"), "\(r)")
        #expect(r.out.contains("staged 4, skipped 1; total in staging: 4"), "\(r)")
        #expect(r.lines.filter { $0.contains("⚠") && $0.contains("1 possible duplicate(s)") }.count == 2, "\(r)")

        // HARD RULE: nothing is in the collection yet.
        r = await c.run("info")
        #expect(r.out.contains("memes:      0"), "\(r)")
        r = await c.run("search")
        #expect(r.ok && r.out.contains("0 result(s)"), "\(r)")
        #expect(try c.open().memes.count() == 0)

        let ls = await c.run("stage", "ls")
        #expect(ls.ok && ls.lines.last == "4 staged", "\(ls)")
        #expect(ls.lines.dropLast().allSatisfy { $0.contains("funny") && $0.contains("source_unknown") && $0.contains("image") }, "\(ls)")
        let hID = try Self.stagedID(ls, "горизонт.png"), copyID = try Self.stagedID(ls, "copy of горизонт.png")
        let vID = try Self.stagedID(ls, "vertical one.png"), cID = try Self.stagedID(ls, "шахматы.png")

        r = await c.run("stage", "show", copyID)
        #expect(r.ok && r.out.contains("DUPLICATE (exact) of staged \(hID)") && r.out.contains("size:      \(inc.pngBytes.count) B  64×64"), "\(r)")
        #expect(r.out.contains("user tags: котики funny") || r.out.contains("user tags: Котики funny"), "\(r)")

        r = await c.run("stage", "show", cID)
        #expect(r.ok && !r.out.contains("DUPLICATE") && r.out.contains("format:    PNG"), "nested-folder file, no duplicate: \(r)")

        r = await c.run("stage", "tag", vID, "-t", "вертикаль", "--append", "--text", "Вертикальная полоса")
        #expect(r.ok && r.out.hasPrefix("\(vID): ") && r.out.contains("вертикаль"), "\(r)")

        // ---- commit: exact duplicates are held back unless forced
        r = await c.run("stage", "commit", "all")
        #expect(r.ok, "\(r)")
        #expect(r.out.contains("skip \(hID): 1 duplicate(s), use --force") && r.out.contains("skip \(copyID): 1 duplicate(s), use --force"), "\(r)")
        #expect(r.lines.filter { $0.hasPrefix("✓ ") }.count == 2, "\(r)")
        r = await c.run("stage", "commit", hID, "--force", "-t", "extra")
        #expect(r.ok && r.lines.count == 1 && r.out.hasPrefix("✓ ") && r.out.contains("extra"), "\(r)")
        // The copy now duplicates a committed meme.
        r = await c.run("stage", "show", copyID)
        #expect(r.out.contains("DUPLICATE (exact) of meme"), "\(r)")
        r = await c.run("stage", "discard", copyID)
        #expect(r.ok && r.out == "Discarded 1 item. Undo: memebooru undo\n", "\(r)")
        r = await c.run("stage", "ls")
        #expect(r.out == "0 staged\n", "\(r)")
        // A discard is undoable, as in the app: the item and its file come back.
        r = await c.run("undo")
        #expect(r.ok, "\(r)")
        r = await c.run("stage", "ls")
        #expect(r.out.contains("1 staged"), "\(r)")
        r = await c.run("stage", "discard", copyID)
        #expect(r.ok, "\(r)")
        r = await c.run("info")
        #expect(r.out.contains("memes:      3"), "\(r)")

        // ---- search: tags, unicode, negation, limit, text
        r = await c.run("search", "funny")
        #expect(Self.count(r) == 3 && Self.memeIDs(r).count == 3, "\(r)")
        let hMeme = try #require(Self.memeIDs(await c.run("search", "extra")).first)
        r = await c.run("search", "котики")
        #expect(Self.count(r) == 3, "\(r)")
        r = await c.run("search", "Котики")
        #expect(Self.count(r) == 3, "\(r)")
        r = await c.run("search", "funny", "-extra")
        #expect(Self.count(r) == 2 && !r.out.contains(hMeme), "\(r)")
        r = await c.run("search", "-l", "1", "funny")
        #expect(r.out.contains("1 result(s) (more)"), "\(r)")
        r = await c.run("search", "вертикаль")
        #expect(Self.count(r) == 1 && r.out.contains("«Вертикальная полоса»"), "\(r)")
        r = await c.run("search", "nothing_has_this_tag")
        #expect(r.ok && Self.count(r) == 0, "\(r)")

        // ---- tags: alias, list, suggest, kind, edit
        r = await c.run("tag", "alias", "kot", "котики")
        #expect(r.ok && r.out == "kot → котики\n", "\(r)")
        r = await c.run("search", "kot")
        #expect(Self.count(r) == 3, "alias resolves in search: \(r)")
        r = await c.run("tag", "list")
        #expect(r.out.contains("котики  ×3  (aliases: kot)"), "\(r)")
        r = await c.run("tag", "suggest", "ko")
        #expect(r.out.contains("kot → котики") , "\(r)")
        r = await c.run("tag", "alias", "x", "no_such_tag")
        #expect(r.code == 64 && r.err.contains("unknown tag no_such_tag"), "\(r)")
        r = await c.run("tag", "kind", "extra", "meta")
        #expect(r.ok && r.out == "extra → meta\n", "\(r)")
        r = await c.run("edit", String(hMeme.prefix(10)), "-t", "новый", "--untag", "funny", "--text", "Привет, мир")
        #expect(r.ok && r.out.contains("новый") && !r.out.contains("funny") && r.out.contains("[extra]"), "\(r)")
        r = await c.run("show", hMeme)
        #expect(r.ok && r.out.contains("text:     Привет, мир") && r.out.contains("meta:     ") && r.out.contains("extra"), "\(r)")
        #expect(r.out.contains("asset:    primary") && r.out.contains("(горизонт.png)") && r.out.contains("64×64"), "\(r)")
        r = await c.run("search", "funny")
        #expect(Self.count(r) == 2, "\(r)")

        // ---- dedupe: the copy committed by force becomes a duplicate pair in the collection
        r = await c.run("add", inc.copy.path)
        let copy2 = try Self.stagedID(await c.run("stage", "ls"), "copy of горизонт.png")
        #expect(r.out.contains("⚠"), "\(r)")
        r = await c.run("stage", "commit", copy2, "--force")
        #expect(r.ok && r.out.hasPrefix("✓ "), "\(r)")
        let copyMeme = String(r.out.dropFirst(2).prefix(while: { !$0.isWhitespace }))
        r = await c.run("dedup", "scan")
        #expect(r.ok && r.out.contains("#1  2 memes, identical") && r.out.contains("1 cluster(s)."), "\(r)")
        r = await c.run("dedup", "keep", String(hMeme.prefix(8)))
        #expect(r.ok && r.out == "kept \(hMeme), removed 1\n", "\(r)")
        r = await c.run("dedup", "scan")
        #expect(r.out.contains("0 cluster(s)."), "\(r)")
        #expect(try c.open().memes.get(MemeID(copyMeme))?.deletedAt != nil)

        // ---- export: stored copy, converted copy, and refusals
        let out = try TempDir("mb export out")
        r = await c.run("export", hMeme, out.url.path)
        #expect(r.ok, "\(r)")
        let exported = URL(fileURLWithPath: r.out.trimmingCharacters(in: .newlines))
        #expect(exported.lastPathComponent == "горизонт.png" && (try? Data(contentsOf: exported)) == inc.pngBytes, "\(r)")
        r = await c.run("export", hMeme, out.path("as jpeg.jpg"), "-f", "jpeg")
        #expect(r.ok && r.out.contains("as jpeg.jpg"), "\(r)")
        #expect((try? Data(contentsOf: out.url.appendingPathComponent("as jpeg.jpg")))?.prefix(2) == Data([0xFF, 0xD8]))
        r = await c.run("export", hMeme, out.url.path, "-f", "bogus")
        #expect(r.code == 64 && r.err.contains("unknown format bogus"), "\(r)")
        r = await c.run("export", hMeme, out.url.path, "-f", "mp4H264")
        #expect(r.code == 64 && r.err.contains("can't be exported as"), "\(r)")
        r = await c.run("export", hMeme, out.url.path, "-f", "original")
        #expect(r.code == 1 && r.err.contains("no original kept for this meme"), "\(r)")
        r = await c.run("export", "ffffffffff", out.url.path)
        #expect(r.code == 64 && r.err.contains("no unique meme ffffffffff"), "\(r)")

        // ---- undo: the dedup removal, then the commits, newest first
        r = await c.run("undo")
        #expect(r.ok && r.out == "undone: Kept \(hMeme.prefix(8)), removed 1 duplicate\n", "\(r)")
        #expect(try c.open().memes.get(MemeID(copyMeme))?.deletedAt == nil, "dedup keep is undoable")
        r = await c.run("search")
        #expect(Self.count(r) == 4 && r.out.contains(copyMeme), "\(r)")
        // The verdict itself stays recorded, so the restored pair isn't offered again.
        r = await c.run("show", hMeme)
        #expect(r.out.contains("relation: \(hMeme) —duplicate→ \(copyMeme)"), "\(r)")
        var undone = 0
        while undone < 20 {
            r = await c.run("undo")
            #expect(r.ok, "\(r)")
            if r.out == "nothing to undo\n" { break }
            undone += 1
        }
        // Every commit was its own undo step, and so was the discard: the collection is empty again.
        #expect(undone == 4, "\(undone) undo steps")
        r = await c.run("search")
        #expect(Self.count(r) == 0, "\(r)")
    }

    // MARK: - Smaller flows

    @Test func stagingNeverCommitsByItself() async throws {
        let c = try await CLICollection()
        let inc = try Incoming()
        for args in [["add", inc.folder.path], ["add", inc.rings.path, "-t", "x"], ["stage", "ls"], ["stage", "show", "0"],
                     ["stage", "tag", "0", "-t", "a"], ["thumbs"], ["dedup", "scan"], ["search"], ["info"]] {
            _ = await c.run(args)
            #expect(try c.open().memes.count() == 0, "after \(args)")
        }
        #expect(try Host.staging(c.open()).count() == 5)
    }

    @Test func idPrefixesAreCheckedForStagedItemsAndMemes() async throws {
        let c = try await CLICollection()
        let inc = try Incoming()
        _ = await c.run("add", inc.horizontal.path, inc.vertical.path)
        var r = await c.run("stage", "show", "zzzz")
        #expect(r.code == 64 && r.err.contains("no staged item zzzz"), "\(r)")
        r = await c.run("stage", "commit", "")
        #expect(r.code == 64 && r.err.contains("ambiguous id"), "\(r)")
        r = await c.run("stage", "commit", "all")
        #expect(r.lines.filter { $0.hasPrefix("✓") }.count == 2, "\(r)")
        for args in [["show", "zz"], ["edit", "zz", "-t", "a"], ["dedup", "keep", "zz"], ["dedup", "mark", "zz", "yy", "variant"]] {
            r = await c.run(args)
            #expect(r.code == 64 && r.out.isEmpty, "\(r)")
        }
        r = await c.run("show", "")
        #expect(r.code == 64 && r.err.contains("ambiguous id"), "\(r)")
        // Uppercase prefixes work too.
        let id = try #require(Self.memeIDs(await c.run("search")).first)
        r = await c.run("show", id.prefix(6).uppercased())
        #expect(r.ok && r.out.contains("id:       \(id)"), "\(r)")
    }

    @Test func addReportsMissingPathsAndUnsupportedFiles() async throws {
        let c = try await CLICollection()
        let d = try TempDir()
        try d.write("notes.xyz", Data("x".utf8))
        let r = await c.run("add", d.path("does not exist.png"), d.path("notes.xyz"))
        #expect(r.ok, "\(r)")
        #expect(r.out.contains("skip does not exist.png: not found") && r.out.contains("skip notes.xyz: unsupported"), "\(r)")
        #expect(r.out.contains("staged 0, skipped 2; total in staging: 0"), "\(r)")
    }

    @Test func tagCommandsCreateMergeUnaliasAndKind() async throws {
        let c = try await CLICollection()
        var r = await c.run("tag", "add", "кот", "cat")
        #expect(r.ok && r.out == "created кот [normal]\ncreated cat [normal]\n", "\(r)")
        r = await c.run("tag", "add", "--meta", "reviewed")
        #expect(r.out == "created reviewed [meta]\n", "\(r)")
        r = await c.run("tag", "alias", "kitty", "cat")
        #expect(r.ok, "\(r)")
        r = await c.run("tag", "merge", "кот", "kitty")       // target through its alias
        #expect(r.ok && r.out == "merged кот → cat\n", "\(r)")
        r = await c.run("tag", "list")
        #expect(r.out.contains("cat") && r.out.contains("kitty") && r.out.contains("кот"), "\(r)")
        #expect(r.out.contains("[meta]   reviewed") || r.out.contains("[meta]  reviewed"), "\(r)")
        r = await c.run("tag", "unalias", "kitty")
        #expect(r.ok && r.out == "removed kitty\n", "\(r)")
        r = await c.run("tag", "merge", "nope", "cat")
        #expect(r.code == 64 && r.err.contains("unknown tag"), "\(r)")
        r = await c.run("tag", "kind", "nope", "meta")
        #expect(r.code == 64 && r.err.contains("unknown tag nope"), "\(r)")
        r = await c.run("tag", "kind", "reviewed", "normal")
        #expect(r.ok && r.out == "reviewed → normal\n", "\(r)")
        r = await c.run("tag", "suggest", "zzz")
        #expect(r.ok && r.out.isEmpty, "\(r)")
    }

    @Test func dedupMarkRecordsRelationsAndDismisses() async throws {
        let c = try await CLICollection()
        let inc = try Incoming()
        _ = await c.run("add", inc.horizontal.path, inc.vertical.path)
        _ = await c.run("stage", "commit", "all")
        let ids = Self.memeIDs(await c.run("search"))
        try #require(ids.count == 2)
        var r = await c.run("dedup", "mark", ids[0], ids[1], "variant")
        #expect(r.ok && r.out == "\(ids[0]) —variant→ \(ids[1])\n", "\(r)")
        r = await c.run("show", ids[0])
        #expect(r.out.contains("relation: \(ids[0]) —variant→ \(ids[1])"), "\(r)")
        r = await c.run("dedup", "mark", ids[0], ids[1], "no")
        #expect(r.ok && r.out == "dismissed\n", "\(r)")
        r = await c.run("dedup", "mark", ids[0], ids[1], "cousin")
        #expect(r.code == 64 && r.err.contains("bad verdict cousin"), "\(r)")
        r = await c.run("dedup", "mark", ids[0], ids[1], "duplicate", "--delete-b")
        #expect(r.ok && r.out.contains("deleted \(ids[1])"), "\(r)")
        #expect(Self.count(await c.run("search")) == 1)
        // The deletion is undoable like any other delete.
        r = await c.run("undo")
        #expect(r.ok && r.out.hasPrefix("undone: "), "\(r)")
        #expect(Self.count(await c.run("search")) == 2)
    }

    @Test func dedupContainsFindsACrop() async throws {
        let c = try await CLICollection()
        let d = try TempDir()
        // A detailed picture and its centre crop.
        let side = 256
        var px = Data(count: side * side * 4)
        var rng = UInt64(42)
        for i in 0..<(side * side) {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            let x = i % side, y = i / side
            let v = UInt8(truncatingIfNeeded: ((x / 8) * 37 + (y / 8) * 91 + Int(rng >> 60)) % 256)
            px[i * 4] = v; px[i * 4 + 1] = UInt8(truncatingIfNeeded: Int(v) * 3); px[i * 4 + 2] = UInt8(truncatingIfNeeded: Int(v) * 7); px[i * 4 + 3] = 255
        }
        let big = Bitmap(width: side, height: side, rgba: px)
        var crop = Data(count: 128 * 128 * 4)
        for y in 0..<128 { for x in 0..<128 {
            let s = ((y + 64) * side + (x + 64)) * 4, t = (y * 128 + x) * 4
            crop.replaceSubrange(t..<t + 4, with: px[s..<s + 4])
        } }
        let enc = CLI.realPlatform.thumbs
        try d.write("big.png", try #require(try enc.encode(big, as: .png, quality: 1)))
        try d.write("crop.png", try #require(try enc.encode(Bitmap(width: 128, height: 128, rgba: crop), as: .png, quality: 1)))
        _ = await c.run("add", d.url.path)
        _ = await c.run("stage", "commit", "all", "--force")
        let r = await c.run("dedup", "contains", "--max-images", "10")
        #expect(r.ok, "\(r)")
        #expect(r.out.contains("containment(s).") && r.out.contains("Add --mark to record."), "\(r)")
        #expect(r.err.isEmpty || r.err.contains("compared"), "\(r)")
    }

    @Test func videoImportCommitAndExport() async throws {
        guard let mp4 = try Samples.mp4() else {
            withKnownIssue("ffmpeg with an H.264 encoder is not installed — video flow skipped") { Issue.record("no ffmpeg") }
            return
        }
        let c = try await CLICollection()
        let d = try TempDir()
        let file = try d.write("клип с пробелом.mp4", mp4)
        var r = await c.run("add", file.path, "-t", "video_tag")
        #expect(r.ok && r.out.contains("staged 1"), "\(r)")
        #expect(try c.open().memes.count() == 0)
        r = await c.run("stage", "ls")
        #expect(r.out.contains("video") && r.out.contains("video_tag"), "\(r)")
        let id = try Self.stagedID(r, "клип с пробелом.mp4")
        r = await c.run("stage", "show", id)
        #expect(r.out.contains("64×64") && r.out.contains(" ms"), "\(r)")
        r = await c.run("stage", "commit", "all")
        #expect(r.ok && r.out.hasPrefix("✓ "), "\(r)")
        let meme = try #require(Self.memeIDs(await c.run("search", "video_tag")).first)
        r = await c.run("show", meme)
        #expect(r.out.contains("kind:     video"), "\(r)")
        let out = try TempDir()
        r = await c.run("export", meme, out.url.path)
        #expect(r.ok && (try? Data(contentsOf: URL(fileURLWithPath: r.out.trimmingCharacters(in: .newlines)))) == mp4, "\(r)")
        r = await c.run("export", meme, out.path("still.png"), "-f", "png")
        #expect(r.code == 64 && r.err.contains("can't be exported as"), "\(r)")
        r = await c.run("thumbs")
        #expect(r.ok && r.out.hasPrefix("generated "), "\(r)")
    }

    @Test func telegramExportImportGoesToStaging() async throws {
        let c = try await CLICollection()
        let d = try TempDir("Telegram Desktop export")
        try d.write("ChatExport 2024/photos/photo 1.png", try Samples.png(.checker))
        try d.write("ChatExport 2024/stickers/s.webp", Data("RIFF....WEBP".utf8))
        let long = String(repeating: "очень длинное сообщение ", count: 3)
        let root: [String: Any] = ["name": "Мемы 🐸", "messages": [
            ["id": 1, "type": "message", "date": "2024-01-02T03:04:05", "date_unixtime": "1704164645", "from": "Миша",
             "photo": "photos/photo 1.png", "text": "подпись"],
            ["id": 2, "type": "message", "date": "2024-01-02T03:04:06", "text": long],
            ["id": 3, "type": "message", "date": "2024-01-02T03:04:07", "file": "stickers/s.webp", "media_type": "sticker", "text": ""],
            ["id": 4, "type": "service", "action": "pin_message"],
            ["id": 5, "type": "message", "photo": "photos/missing.png", "text": ""],
        ]]
        try d.write("ChatExport 2024/result.json", try JSONSerialization.data(withJSONObject: root))
        var r = await c.run("import", "telegram", d.path("ChatExport 2024"), "--no-stickers")
        #expect(r.ok, "\(r)")
        #expect(r.out.contains("  + photos/photo 1.png") && r.out.contains("skip missing.png: missing file"), "\(r)")
        #expect(r.out.contains("staged 2, skipped 1"), "\(r)")
        #expect(try c.open().memes.count() == 0)
        r = await c.run("stage", "ls")
        #expect(r.out.contains("telegram_message") && r.out.contains("2 staged"), "\(r)")
        r = await c.run("import", "telegram", d.path("nope"))
        #expect(r.code == 1 && r.err.contains("no readable result.json"), "\(r)")
    }

    @Test func emptyCollectionCommandsAreQuiet() async throws {
        let c = try await CLICollection()
        let expectations: [([String], String)] = [
            (["stage", "ls"], "0 staged\n"),
            (["stage", "commit", "all"], ""),
            (["stage", "discard", "all"], "discarded 0\n"),
            (["search"], "0 result(s)\n"),
            (["thumbs"], "generated 0\n"),
            (["dedup", "scan"], "0 cluster(s). Resolve: memebooru dedup keep <id>  |  dedup mark <a> <b> duplicate|variant|contains|no\n"),
            (["convert", "all"], "converted 0\n"),
            (["delete-tweets"], "no tweets\n"),
            (["undo"], "nothing to undo\n"),
            (["tag", "list"], ""),
            (["sync", "peers"], ""),
            (["x", "reparse"], "updated 0 staged tweets\n"),
            (["x", "restage", "--tag", "liked"], "moving 0 tweets tagged liked to staging…\nstaged 0. Undo: memebooru undo\n"),
        ]
        for (args, expected) in expectations {
            let r = await c.run(args)
            #expect(r.ok && r.out == expected && r.err.isEmpty, "\(r)")
        }
        let render = await c.run("render", "all")
        if CLI.realPlatform.text != nil {
            #expect(render.ok && render.out == "no tweets match all\ndrawn 0, up to date 0\n", "\(render)")
        } else {
            #expect(render.code == 64 && render.err.contains("no text renderer"), "\(render)")
        }
    }

    @Test func initRefusesAnExistingCollectionAndAddsTheExtension() async throws {
        let d = try TempDir()
        var r = await CLI.run(["init", d.path("plain name")])
        #expect(r.ok && r.out.hasPrefix("created ") && r.out.contains("plain name.memebooru"), "\(r)")
        r = await CLI.run(["init", d.path("plain name.memebooru")])
        #expect(r.code == 1 && r.err.contains("collection already exists"), "\(r)")
        r = await CLI.run(["info", "-c", d.path("plain name.memebooru")])
        #expect(r.ok && r.out.contains("collection: plain name"), "\(r)")
    }

    @Test func collectionFromEnvironmentVariableIsNotNeededWhenFlagGiven() async throws {
        // `-c` and `--collection=` are equivalent end to end.
        let c = try await CLICollection(name: "eq")
        let a = await CLI.run(["info", "-c", c.path]), b = await CLI.run(["info", "--collection=\(c.path)"])
        #expect(a.ok && a.out == b.out, "\(a)\n\(b)")
    }
}
