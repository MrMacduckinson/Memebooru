import ArgumentParser
import Foundation
import Testing
import MemebooruCore
@testable import memebooru

/// Every command and option of `memebooru`: what parses, what doesn't, and that help renders.
@Suite struct CLIParsingTests {
    private func parsed<T: ParsableCommand>(_ args: [String], as: T.Type = T.self) throws -> T {
        let cmd = try MemebooruCLI.parseAsRoot(args)
        return try #require(cmd as? T, "\(args) parsed as \(type(of: cmd))")
    }

    private func parseError(_ args: [String]) -> (code: Int32, message: String)? {
        do { _ = try MemebooruCLI.parseAsRoot(args); return nil }
        catch { return (MemebooruCLI.exitCode(for: error).rawValue, MemebooruCLI.fullMessage(for: error)) }
    }

    // MARK: Help and version

    /// Every command path in the tree, e.g. ["stage", "commit"].
    static let allCommandPaths: [[String]] = {
        var out: [[String]] = []
        func walk(_ t: any ParsableCommand.Type, _ path: [String]) {
            out.append(path)
            for s in t.configuration.subcommands { walk(s, path + [s._commandName]) }
        }
        walk(MemebooruCLI.self, [])
        return out
    }()

    @Test func commandTreeIsComplete() {
        let names = Set(Self.allCommandPaths.map { $0.joined(separator: " ") })
        for expected in ["init", "info", "add", "stage ls", "stage show", "stage tag", "stage commit", "stage discard",
                         "search", "show", "edit", "thumbs", "import telegram", "import tweet", "import likes", "import bookmarks",
                         "dedup scan", "dedup contains", "dedup keep", "dedup mark", "export", "convert", "render",
                         "sync listen", "sync connect", "sync peers", "sync discover", "sync forget",
                         "x login", "x logout", "x whoami", "x qid", "x dump", "x restage", "x chains", "x reparse",
                         "delete-tweets", "undo", "tag list", "tag add", "tag alias", "tag unalias", "tag merge", "tag kind", "tag suggest"] {
            #expect(names.contains(expected), "missing command \(expected)")
        }
    }

    @Test(arguments: CLIParsingTests.allCommandPaths)
    func helpRendersForEveryCommand(_ path: [String]) async {
        for flag in ["--help", "-h"] {
            let r = await CLI.run(path + [flag])
            #expect(r.code == 0, "\(r)")
            #expect(r.out.contains("USAGE: memebooru"), "\(r)")
            #expect(r.err.isEmpty)
        }
        // `help <path>` is the same text.
        let h = await CLI.run(["help"] + path)
        #expect(h.code == 0 && h.out.contains("USAGE:"), "\(h)")
    }

    @Test func helpForCommandsWithoutRunShowsTheirSubcommands() async {
        let root = await CLI.run([])
        #expect(root.code == 0 && root.out.contains("SUBCOMMANDS:") && root.out.contains("stage"), "\(root)")
        let stage = await CLI.run(["stage"])
        #expect(stage.code == 0 && stage.out.contains("commit"), "\(stage)")
        let x = await CLI.run(["x"])
        #expect(x.code == 0 && x.out.contains("login"), "\(x)")
    }

    @Test func versionFlag() async {
        let r = await CLI.run(["--version"])
        #expect(r.code == 0 && r.out.trimmingCharacters(in: .whitespacesAndNewlines) == "0.0.1", "\(r)")
    }

    @Test func exportHelpListsFormats() async {
        let r = await CLI.run(["export", "--help"])
        #expect(r.out.contains("png") && r.out.contains("mp4") && r.out.contains("original"), "\(r)")
    }

    // MARK: Errors

    @Test(arguments: [
        ["frobnicate"],                                  // unknown command
        ["init"],                                        // missing <path>
        ["add", "-c", "x"],                              // missing paths
        ["add", "-c", "x", "f.png", "-t"],               // option without value
        ["add", "-c", "x", "f.png", "--bogus"],          // unknown option
        ["search", "-c", "x", "--limit", "many"],        // not an Int
        ["search", "-c", "x", "-l"],
        ["stage", "show", "-c", "x"],                    // missing id
        ["stage", "commit", "-c", "x"],
        ["stage", "commit", "-c", "x", "all", "--keep-originals"],   // misspelt flag
        ["tag", "kind", "-c", "x", "funny", "bogus"],    // not a TagKind
        ["tag", "alias", "-c", "x", "only-one"],
        ["tag", "merge", "-c", "x", "a"],
        ["dedup", "scan", "-c", "x", "-t", "close"],
        ["dedup", "contains", "-c", "x", "--max-images", "1.5"],
        ["dedup", "mark", "-c", "x", "a", "b"],          // missing verdict
        ["export", "-c", "x", "id"],                     // missing dest
        ["render", "-c", "x"],
        ["sync", "listen", "-c", "x", "--port", "70000"],   // out of UInt16
        ["sync", "listen", "-c", "x", "--port", "-1"],
        ["sync", "connect", "-c", "x"],
        ["sync", "forget", "-c", "x"],
        ["x", "restage", "-c", "x"],                     // --tag is required
        ["x", "dump"],                                   // missing feed
        ["import", "likes", "-c", "x", "--page-delay", "soon"],
        ["import", "likes", "-c", "x", "--limit", "∞"],
        ["import", "telegram", "-c", "x"],
        ["edit", "-c", "x"],
        ["convert", "-c", "x"],
        ["show", "-c", "x"],
        ["delete-tweets", "-c", "x", "extra"],           // takes no arguments
        ["undo", "-c", "x", "extra"],
        ["init", "a", "b"],
    ])
    func badInvocationsAreUsageErrors(_ args: [String]) async {
        let e = parseError(args)
        #expect(e != nil, "\(args) should not parse")
        #expect(e?.code == ExitCode.validationFailure.rawValue, "\(args): \(e?.message ?? "")")
        // And through the full path: exit 64, message on stderr, nothing on stdout.
        let r = await CLI.run(args)
        #expect(r.code == 64 && r.out.isEmpty && r.err.contains("Error:"), "\(r)")
        #expect(r.err.contains("Usage:") || r.err.contains("Help:"), "\(r)")
    }

    @Test func missingCollectionIsAValidationError() async throws {
        try #require(ProcessInfo.processInfo.environment["MEMEBOORU_COLLECTION"] == nil, "MEMEBOORU_COLLECTION is set in this environment")
        for args in [["info"], ["stage", "ls"], ["search", "cat"], ["undo"], ["tag", "list"], ["x", "reparse"], ["sync", "peers"]] {
            let r = await CLI.run(args)
            #expect(r.code == 64 && r.err.contains("pass --collection or set MEMEBOORU_COLLECTION"), "\(r)")
        }
    }

    @Test func nonexistentCollectionFailsWithExitOne() async throws {
        let d = try TempDir()
        for args in [["info"], ["stage", "ls"], ["search"], ["undo"]] {
            let r = await CLI.run(args + ["-c", d.path("nope here.memebooru")])
            #expect(r.code == 1 && r.err.contains("no collection at") && r.err.contains("nope here.memebooru"), "\(r)")
        }
    }

    @Test func usageErrorsComeBeforeTouchingTheCollection() async throws {
        let d = try TempDir()
        let r = await CLI.run(["search", "-c", d.path("missing.memebooru"), "--limit", "x"])
        #expect(r.code == 64 && !r.err.contains("no collection"), "\(r)")
    }

    // MARK: Values

    @Test func initPathWithSpacesAndUnicode() throws {
        let c = try parsed(["init", "/tmp/My Мемы 🐸/коллекция"], as: Init.self)
        #expect(c.path == "/tmp/My Мемы 🐸/коллекция")
    }

    @Test func collectionOptionShortLongAndEquals() throws {
        #expect(try parsed(["info", "-c", "/a b/c.memebooru"], as: Info.self).collection.path == "/a b/c.memebooru")
        #expect(try parsed(["info", "--collection", "/x y"], as: Info.self).collection.path == "/x y")
        #expect(try parsed(["info", "--collection=/z/ж.memebooru"], as: Info.self).collection.path == "/z/ж.memebooru")
        #expect(try parsed(["info"], as: Info.self).collection.path == nil)
    }

    @Test func addPathsAndUnicodeTags() throws {
        let a = try parsed(["add", "-c", "c", "my folder/a b.png", "второй файл.gif", "-t", "котики", "🐸", "tag_with_underscore"], as: Add.self)
        #expect(a.paths == ["my folder/a b.png", "второй файл.gif"])
        #expect(a.tags == ["котики", "🐸", "tag_with_underscore"])
        // -t stops at the next option
        let b = try parsed(["add", "-t", "one", "two", "-c", "c", "p"], as: Add.self)
        #expect(b.tags == ["one", "two"] && b.paths == ["p"] && b.collection.path == "c")
        #expect(try parsed(["add", "--tags", "x", "-c", "c", "p"], as: Add.self).tags == ["x"])
    }

    @Test func stageSubcommandOptions() throws {
        let t = try parsed(["stage", "tag", "-c", "c", "ab12", "-t", "a", "б", "--text", "exact text", "--verbatim", "ВЕРБАТИМ",
                            "--context", "ctx", "--append"], as: Stage.Tag.self)
        #expect(t.id == "ab12" && t.tags == ["a", "б"] && t.text == "exact text" && t.verbatim == "ВЕРБАТИМ" && t.context == "ctx" && t.append)

        let c0 = try parsed(["stage", "commit", "-c", "c", "all"], as: Stage.Commit.self)
        #expect(c0.id == "all" && !c0.force && !c0.noConvert && c0.keepOriginal == nil && c0.tags.isEmpty)
        let c1 = try parsed(["stage", "commit", "-c", "c", "ab", "--force", "--no-convert", "--keep-original", "-t", "x", "y"], as: Stage.Commit.self)
        #expect(c1.force && c1.noConvert && c1.keepOriginal == true && c1.tags == ["x", "y"])
        #expect(try parsed(["stage", "commit", "-c", "c", "ab", "--no-keep-original"], as: Stage.Commit.self).keepOriginal == false)

        #expect(try parsed(["stage", "discard", "-c", "c", "all"], as: Stage.Discard.self).id == "all")
        #expect(try parsed(["stage", "show", "-c", "c", "ABC"], as: Stage.Show.self).id == "ABC")
        _ = try parsed(["stage", "ls", "-c", "c"], as: Stage.Ls.self)
    }

    @Test func searchQueryKeepsDashesAndUnicode() throws {
        let s = try parsed(["search", "-c", "c", "-l", "5", "2022", "stalin", "-ussr", "обед", "\"two words\""], as: Search.self)
        #expect(s.limit == 5)
        #expect(s.query == ["2022", "stalin", "-ussr", "обед", "\"two words\""])
        #expect(try parsed(["search", "-c", "c"], as: Search.self).query.isEmpty)
        #expect(try parsed(["search", "-c", "c"], as: Search.self).limit == 50)
        // after the first query word everything is query, including what looks like an option
        #expect(try parsed(["search", "-c", "c", "cat", "-l", "3"], as: Search.self).query == ["cat", "-l", "3"])
        // a query may start with a negation
        let neg = try parsed(["search", "-c", "c", "-ussr", "обед"], as: Search.self)
        #expect(neg.query == ["-ussr", "обед"] && neg.limit == 50 && neg.collection.path == "c")
        let neg2 = try parsed(["search", "-l", "2", "-c", "c", "--", "-cat"], as: Search.self)
        #expect(neg2.limit == 2 && neg2.collection.path == "c" && neg2.query == ["--", "-cat"])
    }

    /// The command's own abstract shows this exact invocation.
    @Test func documentedSearchExampleRuns() async throws {
        let c = try await CLICollection()
        let r = await c.run("search", "2022", "stalin", "-ussr", "обед")
        #expect(r.code == 0 && r.out.contains("0 result(s)"), "\(r)")
        let neg = await c.run("search", "-ussr")
        #expect(neg.code == 0, "\(neg)")
        let dashes = await c.run("search", "--", "-ussr")
        #expect(dashes.code == 0, "\(dashes)")
    }

    @Test func editOptions() throws {
        let e = try parsed(["edit", "-c", "c", "id1", "-t", "new", "нов", "--untag", "old", "старый", "--meta", "--text", "t",
                            "--verbatim", "v", "--context", "ctx"], as: EditCmd.self)
        #expect(e.id == "id1" && e.tags == ["new", "нов"] && e.untag == ["old", "старый"] && e.meta && e.text == "t" && e.verbatim == "v" && e.context == "ctx")
    }

    @Test func importOptions() throws {
        let t = try parsed(["import", "telegram", "-c", "c", "~/Telegram Desktop/ChatExport 2024", "--no-stickers", "--voice", "--no-text"],
                           as: Import.Telegram.self)
        #expect(t.folder == "~/Telegram Desktop/ChatExport 2024" && t.noStickers && t.voice && t.noText)

        let tw = try parsed(["import", "tweet", "-c", "c", "https://x.com/a/status/1", "2", "--no-archive"], as: Import.Tweet.self)
        #expect(tw.urls == ["https://x.com/a/status/1", "2"] && tw.noArchive)

        let l = try parsed(["import", "likes", "-c", "c", "-l", "0", "--tags", "мои", "x", "--cookies", "auth_token=A; ct0=B", "--fresh", "--page-delay", "0"],
                           as: ImportX.self)
        #expect(l.options.limit == 0 && l.options.tags == ["мои", "x"] && l.options.cookies == "auth_token=A; ct0=B" && l.options.fresh && l.options.pageDelay == 0)
        let d = try parsed(["import", "bookmarks", "-c", "c"], as: ImportBookmarks.self)
        #expect(d.options.limit == 100 && d.options.pageDelay == 2 && !d.options.fresh && d.options.cookies == nil && d.options.tags.isEmpty)
    }

    @Test func dedupOptions() throws {
        #expect(try parsed(["dedup", "scan", "-c", "c"], as: Dedup.Scan.self).threshold == StagingArea.similarThreshold)
        #expect(try parsed(["dedup", "scan", "-c", "c", "-t", "3"], as: Dedup.Scan.self).threshold == 3)
        let co = try parsed(["dedup", "contains", "-c", "c", "--max-images", "10", "--mark"], as: Dedup.Contains.self)
        #expect(co.maxImages == 10 && co.mark)
        #expect(try parsed(["dedup", "keep", "-c", "c", "abc"], as: Dedup.Keep.self).id == "abc")
        let m = try parsed(["dedup", "mark", "-c", "c", "a", "b", "duplicate", "--delete-b"], as: Dedup.Mark.self)
        #expect(m.a == "a" && m.b == "b" && m.verdict == "duplicate" && m.deleteB)
    }

    @Test func exportConvertRenderOptions() throws {
        let e = try parsed(["export", "-c", "c", "abc", "/out dir/файл.png", "-f", "png"], as: Export.self)
        #expect(e.id == "abc" && e.dest == "/out dir/файл.png" && e.format == "png")
        #expect(try parsed(["export", "-c", "c", "abc", "d"], as: Export.self).format == "stored")
        let cv = try parsed(["convert", "-c", "c", "all", "--keep-original"], as: Convert.self)
        #expect(cv.id == "all" && cv.keepOriginal)
        let r = try parsed(["render", "-c", "c", "abc", "-o", "/tmp/a b.png", "--force"], as: Render.self)
        #expect(r.id == "abc" && r.output == "/tmp/a b.png" && r.force)
    }

    @Test func syncOptions() throws {
        let l = try parsed(["sync", "listen", "-c", "c", "-p", "7301", "--no-bonjour"], as: Sync.Listen.self)
        #expect(l.port == 7301 && l.noBonjour)
        #expect(try parsed(["sync", "listen", "-c", "c"], as: Sync.Listen.self).port == 0)
        let c = try parsed(["sync", "connect", "-c", "c", "[::1]:7300", "--code", "123456"], as: Sync.Connect.self)
        #expect(c.target == "[::1]:7300" && c.code == "123456")
        #expect(try parsed(["sync", "connect", "-c", "c", "Mac Studio Миши"], as: Sync.Connect.self).target == "Mac Studio Миши")
        #expect(try parsed(["sync", "forget", "-c", "c", "dev-1"], as: Sync.Forget.self).deviceID == "dev-1")
        _ = try parsed(["sync", "peers", "-c", "c"], as: Sync.Peers.self)
        _ = try parsed(["sync", "discover"], as: Sync.Discover.self)
    }

    @Test func xOptions() throws {
        let l = try parsed(["x", "login", "--cookies", "auth_token=a; ct0=b"], as: X.Login.self)
        #expect(l.cookies == "auth_token=a; ct0=b" && l.authToken == nil)
        let l2 = try parsed(["x", "login", "--auth-token", "a", "--csrf", "b", "--user-id", "1"], as: X.Login.self)
        #expect(l2.authToken == "a" && l2.csrf == "b" && l2.userID == "1")
        let q = try parsed(["x", "qid", "--likes", "L", "--bookmarks", "B", "--user", "U", "--discover"], as: X.Qid.self)
        #expect(q.likes == "L" && q.bookmarks == "B" && q.user == "U" && q.discover)
        let d = try parsed(["x", "dump", "likes", "--out", "a b.json"], as: X.Dump.self)
        #expect(d.feed == "likes" && d.out == "a b.json")
        #expect(try parsed(["x", "dump", "bookmarks"], as: X.Dump.self).out == "x-dump.json")
        #expect(try parsed(["x", "restage", "-c", "c", "--tag", "liked"], as: X.Restage.self).tag == "liked")
        _ = try parsed(["x", "chains", "-c", "c"], as: X.Chains.self)
        _ = try parsed(["x", "reparse", "-c", "c"], as: X.Reparse.self)
        _ = try parsed(["x", "logout"], as: X.Logout.self)
        _ = try parsed(["x", "whoami"], as: X.Whoami.self)
    }

    @Test func tagSubcommands() throws {
        _ = try parsed(["tag", "list", "-c", "c"], as: TagCmd.List.self)
        let a = try parsed(["tag", "add", "-c", "c", "--meta", "мета тег", "two"], as: TagCmd.Add.self)
        #expect(a.meta && a.names == ["мета тег", "two"])
        let al = try parsed(["tag", "alias", "-c", "c", "tg_message", "telegram_message"], as: TagCmd.Alias.self)
        #expect(al.alias == "tg_message" && al.tag == "telegram_message")
        #expect(try parsed(["tag", "unalias", "-c", "c", "tg"], as: TagCmd.Unalias.self).alias == "tg")
        let m = try parsed(["tag", "merge", "-c", "c", "src", "dst"], as: TagCmd.Merge.self)
        #expect(m.source == "src" && m.target == "dst")
        #expect(try parsed(["tag", "kind", "-c", "c", "t", "meta"], as: TagCmd.Kind.self).kind == .meta)
        #expect(try parsed(["tag", "kind", "-c", "c", "t", "normal"], as: TagCmd.Kind.self).kind == .normal)
        #expect(try parsed(["tag", "suggest", "-c", "c", "ко"], as: TagCmd.Suggest.self).prefix == "ко")
    }

    @Test func maintenanceCommands() throws {
        _ = try parsed(["delete-tweets", "-c", "c"], as: DeleteTweets.self)
        _ = try parsed(["undo", "-c", "c"], as: Undo.self)
        _ = try parsed(["thumbs", "-c", "c"], as: Thumbs.self)
        _ = try parsed(["info", "-c", "c"], as: Info.self)
        #expect(try parsed(["show", "-c", "c", "ab"], as: Show.self).id == "ab")
    }

    @Test func injectHelperPutsCollectionAfterTheCommandWords() {
        #expect(CLICollection.inject(["stage", "tag", "id", "-t", "x"], "/p") == ["stage", "tag", "-c", "/p", "id", "-t", "x"])
        #expect(CLICollection.inject(["search", "x", "stage"], "/p") == ["search", "-c", "/p", "x", "stage"])
        #expect(CLICollection.inject(["tag", "add", "add"], "/p") == ["tag", "add", "-c", "/p", "add"])
    }
}
