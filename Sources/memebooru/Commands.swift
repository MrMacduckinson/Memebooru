import ArgumentParser
import Foundation
import MemebooruCore
#if canImport(ImageIO)
import MemebooruPlatformApple
#else
import MemebooruPlatformLinux
#endif

enum Host {
    // Test seams. Task-local, so parallel in-process runs never share them; nil in the shipped CLI.
    /// Replaces the OS platform (e.g. a fake HTTP client, so tests never touch the network).
    @TaskLocal static var platformOverride: Platform?
    /// Receives everything the CLI prints (stdout / stderr) instead of the terminal.
    @TaskLocal static var output: (@Sendable (String) -> Void)?
    @TaskLocal static var errorOutput: (@Sendable (String) -> Void)?

    static func platform() -> Platform {
        if let p = platformOverride { return p }
        #if canImport(ImageIO)
        return PlatformApple.make()
        #else
        return PlatformLinux.make()
        #endif
    }
    static func staging(_ c: Collection) -> StagingArea {
        StagingArea(collection: c, analyzer: MediaAnalyzer(platform: platform()))
    }
    static func fmtTags(_ tags: [Tag]) -> String {
        tags.map { $0.kind == .meta ? "[\($0.name)]" : $0.name }.joined(separator: " ")
    }
    static func short(_ id: String) -> String { String(id.prefix(8)) }
    /// The one post whose id starts with `prefix`.
    static func findMeme(_ c: Collection, _ prefix: String) throws -> MemeID {
        let all = try c.search.search("", limit: 1_000_000).memes.filter { $0.id.rawValue.hasPrefix(prefix.lowercased()) }
        guard all.count == 1 else { throw ValidationError(all.isEmpty ? "no staged item or post \(prefix)" : "ambiguous id \(prefix)") }
        return all[0].id
    }

    /// A line printer for callbacks on other threads (where task-locals are gone): writes to the
    /// sink of the task that made it, else straight to stdout, unbuffered, so live output shows at once.
    static func printer() -> @Sendable (String) -> Void {
        let sink = output
        return { line in
            if let sink { sink(line + "\n") } else { FileHandle.standardOutput.write(Data((line + "\n").utf8)) }
        }
    }

    static func printError(_ s: String) {
        if let sink = errorOutput { sink(s) } else { FileHandle.standardError.write(Data(s.utf8)) }
    }
}

/// Every `print` in this module goes through here, so tests can capture the output (`Host.output`).
/// Without a sink it is the standard `print`, byte for byte.
func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    let s = items.map { "\($0)" }.joined(separator: separator) + terminator
    if let sink = Host.output { sink(s) } else { Swift.print(s, terminator: "") }
}

struct Add: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stage files or folders (buffer zone).")
    @OptionGroup var collection: CollectionOption
    @Argument(help: "Files or directories.") var paths: [String]
    @Option(name: .shortAndLong, parsing: .upToNextOption, help: "Extra tags for every item.") var tags: [String] = []

    func run() throws {
        let c = try collection.open()
        let staging = Host.staging(c)
        let urls = paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let report = try FolderImporter(staging: staging).importFiles(urls) { print("  + \($0.lastPathComponent)") }
        for var item in report.staged where !tags.isEmpty { item.userTags = tags; try staging.update(item) }
        for (u, why) in report.skipped { print("  skip \(u.lastPathComponent): \(why)") }
        print("staged \(report.staged.count), skipped \(report.skipped.count); total in staging: \(try staging.count())")
        for item in report.staged {
            let dups = try staging.duplicates(of: item)
            if !dups.isEmpty { print("  ⚠ \(Host.short(item.id)) \(item.originalName ?? ""): \(dups.count) possible duplicate(s)") }
        }
    }
}

struct Stage: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Inspect and commit staged items.",
                                                    subcommands: [Ls.self, Show.self, Tag.self, Commit.self, Discard.self,
                                                                  Combine.self, Relayout.self, Split.self, Edit.self])

    static func find(_ staging: StagingArea, _ prefix: String) throws -> StagedItem {
        let all = try staging.list().filter { $0.id.hasPrefix(prefix.lowercased()) }
        guard all.count == 1 else { throw ValidationError(all.isEmpty ? "no staged item \(prefix)" : "ambiguous id \(prefix)") }
        return all[0]
    }

    struct Ls: ParsableCommand {
        @OptionGroup var collection: CollectionOption
        func run() throws {
            let staging = Host.staging(try collection.open())
            let items = try staging.list()
            for i in items {
                let dups = try staging.duplicates(of: i)
                let dupMark = dups.isEmpty ? "" : "  ⚠\(dups.count)"
                let fmt = i.compatibility == .uncommon
                    ? "  [\(i.formatLabel) → \(i.willConvert ? (i.popularTarget?.label ?? "?") : "kept as is")\(i.willConvert && i.willKeepOriginal ? " + original" : "")]"
                    : ""
                print("\(Host.short(i.id))  \(i.kind.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0))  \(i.effectiveTags.joined(separator: " "))  ← \(i.originalName ?? "")\(fmt)\(dupMark)")
            }
            print("\(items.count) staged")
        }
    }

    struct Show: ParsableCommand {
        @OptionGroup var collection: CollectionOption
        @Argument var id: String
        func run() throws {
            let c = try collection.open()
            let staging = Host.staging(c)
            let i = try Stage.find(staging, id)
            print("id:        \(i.id)\nkind:      \(i.kind)\nsource:    \(i.source)\nfile:      \(staging.fileURL(i).path)")
            print("size:      \(i.bytes) B  \(i.info.width.map { "\($0)×\(i.info.height ?? 0)" } ?? "")  \(i.info.durationMs.map { "\($0) ms" } ?? "")")
            print("format:    \(i.formatLabel)" + (i.compatibility == .uncommon
                ? " — uncommon; on commit: \(i.willConvert ? "convert to \(i.popularTarget?.label ?? "?")" : "keep as is")\(i.willConvert && i.willKeepOriginal ? ", keep original" : "")"
                : ""))
            print("suggested: \(i.suggestedTags.joined(separator: " "))\nuser tags: \(i.userTags.joined(separator: " "))")
            if let t = i.textVerbatim { print("text:      \(t.prefix(200))") }
            for d in try staging.duplicates(of: i) {
                switch d.match {
                case .exact: print("DUPLICATE (exact) of meme \(d.memeID!)")
                case .similar(let dist): print("similar (d=\(dist)) to meme \(d.memeID!)")
                case .stagedExact(let sid): print("DUPLICATE (exact) of staged \(Host.short(sid))")
                case .stagedSimilar(let sid, let dist): print("similar (d=\(dist)) to staged \(Host.short(sid))")
                }
            }
        }
    }

    struct Tag: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Set user tags / text on a staged item.")
        @OptionGroup var collection: CollectionOption
        @Argument var id: String
        @Option(name: .shortAndLong, parsing: .upToNextOption) var tags: [String] = []
        @Option(name: .long) var text: String?
        @Option(name: .long) var verbatim: String?
        @Option(name: .long) var context: String?
        @Flag(name: .long, help: "Append instead of replace.") var append = false
        func run() throws {
            let staging = Host.staging(try collection.open())
            var i = try Stage.find(staging, id)
            i.userTags = append ? i.userTags + tags : tags
            if let text { i.textExact = text }
            if let verbatim { i.textVerbatim = verbatim }
            if let context { i.context = context }
            try staging.update(i)
            print("\(Host.short(i.id)): \(i.effectiveTags.joined(separator: " "))")
        }
    }

    struct Commit: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Move staged item(s) into the collection.")
        @OptionGroup var collection: CollectionOption
        @Argument(help: "Staged id prefix, or 'all'.") var id: String
        @Option(name: .shortAndLong, parsing: .upToNextOption, help: "Tags (added to suggested ones).") var tags: [String] = []
        @Flag(name: .long, help: "Commit even if duplicates were found.") var force = false
        @Flag(name: .long, help: "Store uncommon formats as they are (default: convert to the popular format).") var noConvert = false
        @Flag(name: .long, inversion: .prefixedNo, help: "Also keep the original file when converting (default: only for SVG).") var keepOriginal: Bool?
        func run() throws {
            let c = try collection.open()
            let staging = Host.staging(c)
            let items = id == "all" ? try staging.list() : [try Stage.find(staging, id)]
            // One undo step for the whole command, like a commit in the app (`memebooru undo`).
            let batch = try c.undo.begin(kind: "commit", summary: "Commit \(items.count) staged")
            var done = 0
            defer { try? c.undo.finish(batch, summary: "Committed \(done) item\(done == 1 ? "" : "s")") }
            for var i in items {
                let dups = try staging.duplicates(of: i)
                if !dups.isEmpty && !force { print("skip \(Host.short(i.id)): \(dups.count) duplicate(s), use --force"); continue }
                if !tags.isEmpty { i.userTags += tags; try staging.update(i) }
                let m = try staging.commit(i.id, undoBatch: batch, convert: noConvert ? false : nil, keepOriginal: keepOriginal)
                done += 1
                let (p, o) = try c.formats(of: m.id)
                let fmt = p.map { a in a.sourceLabel.map { " [\($0) → \(a.formatLabel)\(o != nil ? ", original kept" : "")]" } ?? "" } ?? ""
                print("✓ \(m.id)  \(Host.fmtTags(try c.memes.tags(of: m.id)))\(fmt)")
            }
        }
    }

    struct Discard: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove staged item(s); `memebooru undo` brings them back.")
        @OptionGroup var collection: CollectionOption
        @Argument(help: "Staged id prefix, or 'all'.") var id: String
        func run() throws {
            let c = try collection.open()
            let staging = Host.staging(c)
            let items = id == "all" ? try staging.list() : [try Stage.find(staging, id)]
            guard !items.isEmpty else { print("discarded 0"); return }
            // Into the trash, one undo step — the same as Discard in the app.
            print(try c.discardStaged(items) + ". Undo: memebooru undo")
        }
    }

    struct LayoutOptions: ParsableArguments {
        @Option(name: .shortAndLong, help: "row (side by side), column (one above the other), grid, or feature (one large + a stack). Default: chosen from the pictures' shapes.")
        var layout: CompositeLayout.Arrangement?
        @Option(name: .long, help: "Pictures per row in a grid.") var columns: Int = 2
        @Option(name: .long, help: "Shared height (row, feature) or width (column, grid) in pixels; at most the largest picture's.") var size: Int?
        @Option(name: .long, help: "Pixels of white between pictures.") var gap: Int = 0

        func validate() throws {
            if columns < 1 { throw ValidationError("--columns must be at least 1") }
            if let size, size < 1 { throw ValidationError("--size must be positive") }
            if gap < 0 || gap > 500 { throw ValidationError("--gap must be 0…500") }
        }
        var chosen: CompositeLayout? { layout.map { CompositeLayout($0, columns: columns, size: size, gap: gap) } }
    }

    struct Combine: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Combine several staged pictures into one meme (a diptych, triptych…).",
                                                        discussion: "memebooru stage combine 3fa2 9c01 --layout column")
        @OptionGroup var collection: CollectionOption
        @Argument(help: "Staged picture id prefixes, in order.") var ids: [String]
        @OptionGroup var layout: LayoutOptions
        func validate() throws { if ids.count < 2 { throw ValidationError("give at least two pictures") } }
        func run() throws {
            let staging = Host.staging(try collection.open())
            let items = try ids.map { try Stage.find(staging, $0) }
            let c = try staging.combine(items.map(\.id), layout: layout.chosen)
            let l = c.payload.composite!.layout
            print("✓ \(Host.short(c.id))  \(items.count) pictures, \(l.arrangement.rawValue), \(c.info.width ?? 0)×\(c.info.height ?? 0)  \(c.effectiveTags.joined(separator: " "))")
        }
    }

    struct Relayout: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Change how a combined picture is laid out (staged item or saved post).")
        @OptionGroup var collection: CollectionOption
        @Argument(help: "Staged id prefix or post id prefix.") var id: String
        @OptionGroup var layout: LayoutOptions
        @Option(name: .long, parsing: .upToNextOption, help: "New order of the pictures, e.g. --order 2 1 3 (1-based).") var order: [Int] = []
        func run() throws {
            let c = try collection.open()
            let staging = Host.staging(c)
            let newOrder = order.isEmpty ? nil : order.map { $0 - 1 }
            if let item = try staging.list().first(where: { $0.id.hasPrefix(id.lowercased()) }) {
                guard let current = item.payload.composite?.layout else { throw ValidationError("\(Host.short(item.id)) is not a combined picture") }
                let r = try staging.recombine(item.id, layout: layout.chosen ?? current, order: newOrder)
                print("✓ \(Host.short(r.id))  \(r.info.width ?? 0)×\(r.info.height ?? 0)")
                return
            }
            let memeID = try Host.findMeme(c, id)
            guard let current = try c.memes.get(memeID)?.payload.composite?.layout else { throw ValidationError("\(id) is not a combined picture") }
            let a = try c.recombine(memeID, layout: layout.chosen ?? current, order: newOrder, analyzer: MediaAnalyzer(platform: Host.platform()))
            print("✓ \(memeID)  \(a.width ?? 0)×\(a.height ?? 0)")
        }
    }

    struct Split: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Turn a staged combined picture back into separate pictures.")
        @OptionGroup var collection: CollectionOption
        @Argument var id: String
        func run() throws {
            let staging = Host.staging(try collection.open())
            let parts = try staging.split(try Stage.find(staging, id).id)
            print("✓ split into \(parts.count): " + parts.map { Host.short($0.id) }.joined(separator: " "))
        }
    }
}

extension CompositeLayout.Arrangement: ExpressibleByArgument {}

extension Stage {
    struct Edit: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Crop plain borders / trim quiet ends (staged item or saved post); the original is kept.",
            discussion: "memebooru stage edit 3fa2 --auto-crop\nmemebooru stage edit 3fa2 --crop 40,30,1360,764 --trim 1.2-3.5\nmemebooru stage edit 3fa2 --reset")
        @OptionGroup var collection: CollectionOption
        @Argument(help: "Staged id prefix or post id prefix.") var id: String
        @Flag(name: .long, help: "Cut the plain borders found (pictures, GIFs, videos).") var autoCrop = false
        @Option(name: .long, help: "Keep this rectangle: x,y,width,height in the original's pixels.") var crop: String?
        @Flag(name: .long, help: "Cut the quiet start and end found (videos, sounds).") var autoTrim = false
        @Option(name: .long, help: "Keep this stretch: start-end in seconds, e.g. 1.25-3.5.") var trim: String?
        @Flag(name: .long, help: "Undo all edits: back to the original.") var reset = false

        func validate() throws {
            if reset && (autoCrop || crop != nil || autoTrim || trim != nil) { throw ValidationError("--reset can't be combined with other edits") }
            if !reset && !autoCrop && crop == nil && !autoTrim && trim == nil { throw ValidationError("say what to do: --auto-crop, --crop, --auto-trim, --trim or --reset") }
            if autoCrop && crop != nil { throw ValidationError("use --auto-crop or --crop, not both") }
            if autoTrim && trim != nil { throw ValidationError("use --auto-trim or --trim, not both") }
            if let crop { _ = try Self.rect(crop) }
            if let trim { _ = try Self.range(trim) }
        }

        static func rect(_ s: String) throws -> PixelRect {
            let n = s.split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard n.count == 4, let x = n[0], let y = n[1], let w = n[2], let h = n[3], x >= 0, y >= 0, w > 0, h > 0 else {
                throw ValidationError("--crop wants x,y,width,height (whole pixels, width and height above 0)")
            }
            return PixelRect(x: x, y: y, width: w, height: h)
        }
        static func range(_ s: String) throws -> TimeRange {
            let p = s.split(separator: "-").map { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard p.count == 2, let a = p[0], let b = p[1], a >= 0, b > a else { throw ValidationError("--trim wants start-end in seconds, end after start") }
            return TimeRange(startMs: Int64((a * 1000).rounded()), endMs: Int64((b * 1000).rounded()))
        }

        func run() throws {
            let c = try collection.open()
            let staging = Host.staging(c)
            let analyzer = MediaAnalyzer(platform: Host.platform())
            let editor = MediaEditor(analyzer: analyzer)
            // What the edit starts from: the original, kept since the first edit.
            let item = try staging.list().first { $0.id.hasPrefix(id.lowercased()) }
            let memeID = item == nil ? try Host.findMeme(c, id) : nil
            let kind: MemeKind, source: URL, current: MediaEdit?
            if let item {
                kind = item.kind; source = staging.editSource(item); current = item.edit
            } else {
                guard let m = try c.memes.get(memeID!), let p = try c.memes.primaryAsset(of: memeID!) else { throw ValidationError("no such post") }
                let base = try c.memes.asset(of: memeID!, role: .original) ?? p
                kind = m.kind; source = c.media.url(sha256: base.sha256, ext: base.ext); current = p.edit
            }
            var edit = reset ? MediaEdit() : (current ?? MediaEdit())
            if autoCrop {
                guard MediaEditor.canCrop(kind) else { throw ValidationError("a \(kind.rawValue) can't be cropped") }
                edit.crop = try editor.detectBorders(source, kind: kind)
                print(edit.crop.map { "borders: keeping \($0.width)×\($0.height) at \($0.x),\($0.y)" } ?? "no plain borders found")
            }
            if let crop { edit.crop = try Self.rect(crop) }
            if autoTrim {
                guard MediaEditor.canTrim(kind) else { throw ValidationError("a \(kind.rawValue) can't be trimmed") }
                edit.trim = try editor.detectSilence(source)
                print(edit.trim.map { String(format: "quiet ends: keeping %.3f–%.3f s", Double($0.startMs) / 1000, Double($0.endMs) / 1000) } ?? "no quiet ends found")
            }
            if let trim { edit.trim = try Self.range(trim) }
            if let item {
                let r = try staging.applyEdit(item.id, edit.isEmpty ? nil : edit)
                print("✓ \(Host.short(r.id))  \(r.info.width.map { "\($0)×\(r.info.height ?? 0)" } ?? "")\(r.info.durationMs.map { String(format: " %.3f s", Double($0) / 1000) } ?? "")\(r.edit == nil ? "  (original)" : "")")
            } else {
                let a = try c.applyEdit(memeID!, edit.isEmpty ? nil : edit, analyzer: analyzer)
                print("✓ \(memeID!)  \(a.width.map { "\($0)×\(a.height ?? 0)" } ?? "")\(a.durationMs.map { String(format: " %.3f s", Double($0) / 1000) } ?? "")\(a.edit == nil ? "  (original)" : "")")
            }
        }
    }
}

struct Search: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Search: memebooru search 2022 stalin -ussr \"lunch\"")
    @OptionGroup var collection: CollectionOption
    // Captured verbatim from the first query word on, so negations like `-ussr` are query, not options.
    @Argument(parsing: .captureForPassthrough,
              help: "Query tokens; put options like -l before the query (and `--` before a first word like -cat).") var query: [String] = []
    @Option(name: .shortAndLong) var limit: Int = 50
    func validate() throws {
        // Captured arguments skip ArgumentParser's own help handling.
        if query.first == "--help" || query.first == "-h" { throw CleanExit.helpRequest(self) }
    }
    func run() throws {
        let c = try collection.open()
        let words = query.first == "--" ? Array(query.dropFirst()) : query
        let page = try c.search.search(words.joined(separator: " "), limit: limit)
        for m in page.memes {
            let asset = try c.memes.primaryAsset(of: m.id)
            let text = m.textExact ?? m.textVerbatim
            print("\(m.id)  \(m.kind.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0))  \(Host.fmtTags(try c.memes.tags(of: m.id)))\(text.map { "  «\($0.prefix(40))»" } ?? "")  \(asset.map { $0.originalName ?? "\($0.sha256.prefix(8)).\($0.ext)" } ?? "")")
        }
        print("\(page.memes.count) result(s)\(page.next != nil ? " (more)" : "")")
    }
}

struct Show: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show one meme.")
    @OptionGroup var collection: CollectionOption
    @Argument var id: String
    func run() throws {
        let c = try collection.open()
        let all = try c.search.search("", limit: 100_000).memes.filter { $0.id.rawValue.hasPrefix(id.lowercased()) }
        guard all.count == 1, let m = all.first else { throw ValidationError(all.isEmpty ? "no meme \(id)" : "ambiguous id") }
        let tags = try c.memes.tags(of: m.id)
        print("id:       \(m.id)\nkind:     \(m.kind) (\(m.presentation))\ncreated:  \(Date(timeIntervalSince1970: Double(m.createdAt) / 1000))")
        print("tags:     \(tags.filter { $0.kind == .normal }.map(\.name).joined(separator: " "))")
        print("meta:     \(tags.filter { $0.kind == .meta }.map(\.name).joined(separator: " "))")
        if let t = m.textExact { print("text:     \(t)") }
        if let t = m.textVerbatim, t != m.textExact { print("verbatim: \(t)") }
        if let t = m.context { print("context:  \(t)") }
        for a in try c.memes.assets(of: m.id) {
            print("asset:    \(a.role.rawValue) \(c.media.url(sha256: a.sha256, ext: a.ext).path)\(a.originalName.map { " (\($0))" } ?? "") \(a.width.map { "\($0)×\(a.height ?? 0)" } ?? "") phash=\(a.phash.map { String(PerceptualHash.fromInt64($0), radix: 16) } ?? "-")")
            if a.role == .primary || a.role == .original {
                print("          \(a.formatLabel) — \(a.compatibility(kind: m.kind) == .popular ? "popular" : "uncommon")\(a.sourceLabel.map { ", converted from \($0)" } ?? "")")
            }
        }
        for r in try c.memes.relations(of: m.id) { print("relation: \(r.from) —\(r.kind.rawValue)→ \(r.to)") }
    }
}

struct Thumbs: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Generate missing thumbnails.")
    @OptionGroup var collection: CollectionOption
    func run() throws {
        let c = try collection.open()
        let analyzer = MediaAnalyzer(platform: Host.platform())
        var made = 0
        for m in try c.search.search("", limit: 1_000_000).memes {
            guard let a = try c.memes.primaryAsset(of: m.id) else { continue }
            let url = c.media.url(sha256: a.sha256, ext: a.ext)
            if !FileManager.default.fileExists(atPath: c.media.thumbURL(sha256: a.sha256).path),
               (try? analyzer.ensureThumbnail(for: url, sha256: a.sha256, kind: m.kind, in: c.media)) != nil { made += 1 }
        }
        print("generated \(made)")
    }
}

struct EditCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "edit", abstract: "Edit tags/text of an existing meme.")
    @OptionGroup var collection: CollectionOption
    @Argument var id: String
    @Option(name: .shortAndLong, parsing: .upToNextOption, help: "Tags to add.") var tags: [String] = []
    @Option(name: .long, parsing: .upToNextOption, help: "Tags to remove.") var untag: [String] = []
    @Flag(name: .long, help: "Added tags are meta.") var meta = false
    @Option(name: .long) var text: String?
    @Option(name: .long) var verbatim: String?
    @Option(name: .long) var context: String?
    func run() throws {
        let c = try collection.open()
        let all = try c.search.search("", limit: 1_000_000).memes.filter { $0.id.rawValue.hasPrefix(id.lowercased()) }
        guard all.count == 1, var m = all.first else { throw ValidationError(all.isEmpty ? "no meme \(id)" : "ambiguous id") }
        for t in tags { try c.memes.addTag(m.id, t, kind: meta ? .meta : .normal) }
        for t in untag { try c.memes.removeTag(m.id, t) }
        if text != nil || verbatim != nil || context != nil {
            if let text { m.textExact = text }
            if let verbatim { m.textVerbatim = verbatim }
            if let context { m.context = context }
            try c.memes.update(m)
        }
        print("\(m.id)  \(Host.fmtTags(try c.memes.tags(of: m.id)))")
    }
}
