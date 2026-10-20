import ArgumentParser
import Foundation
import MemebooruCore

struct Import: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Import from external sources into staging.",
                                                    subcommands: [Telegram.self, Tweet.self, ImportX.self, ImportBookmarks.self])

    struct Telegram: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Telegram Desktop export folder (result.json + media).")
        @OptionGroup var collection: CollectionOption
        @Argument var folder: String
        @Flag(name: .long, help: "Skip stickers.") var noStickers = false
        @Flag(name: .long, help: "Include voice/video messages.") var voice = false
        @Flag(name: .long, help: "Skip text-only messages.") var noText = false
        func run() throws {
            let staging = Host.staging(try collection.open())
            var opts = TelegramExportImporter.Options()
            opts.includeStickers = !noStickers; opts.includeVoice = voice; opts.includeTextMessages = !noText
            let r = try TelegramExportImporter(staging: staging, options: opts)
                .importExport(at: URL(fileURLWithPath: (folder as NSString).expandingTildeInPath)) { print("  + \($0)") }
            for (u, why) in r.skipped { print("  skip \(u.lastPathComponent): \(why)") }
            print("staged \(r.staged.count), skipped \(r.skipped.count)")
        }
    }

    struct Tweet: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Tweet by URL: text, media, author, reply chain, Wayback snapshot.")
        @OptionGroup var collection: CollectionOption
        @Argument var urls: [String]
        @Flag(name: .long, help: "Don't touch the Wayback Machine.") var noArchive = false
        func run() async throws {
            let staging = Host.staging(try collection.open())
            let http = Host.platform().http
            let importer = TweetImporter(staging: staging, source: FxTwitterSource(http: http), http: http, archive: !noArchive)
            for u in urls {
                do {
                    let item = try await importer.importTweet(u)
                    guard case .tweet(let p) = item.payload else { continue }
                    print("✓ \(Host.short(item.id)) @\(p.handle): «\((item.textVerbatim ?? "").prefix(60))»  media=\(staging.extras(item).filter { $0.role == .media }.count)  wayback=\(p.waybackURL ?? "-")")
                } catch { print("✗ \(u): \(error)") }
            }
        }
    }
}

struct Dedup: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Find duplicates across the whole collection.",
                                                    subcommands: [Scan.self, Contains.self, Keep.self, Mark.self])

    struct Contains: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Find crops: one image contained in another (feature matching).")
        @OptionGroup var collection: CollectionOption
        @Option(name: .long, help: "Max images to compare.") var maxImages: Int = 800
        @Flag(name: .long, help: "Record each as a 'contains' relation.") var mark = false
        func run() throws {
            let c = try collection.open()
            let images = Host.platform().images
            let scanner = ContainmentScanner(collection: c, decode: { url in
                (try? images.decode(url, maxSide: 512)).map { GrayImage($0) }
            })
            let results = try scanner.scan(maxImages: maxImages) { done, total in
                if done == total { Host.printError("compared \(total) pairs\n") }
            }
            for r in results {
                let cn = (try? c.memes.primaryAsset(of: r.container)?.originalName) ?? nil
                let dn = (try? c.memes.primaryAsset(of: r.contained)?.originalName) ?? nil
                print("\(Host.short(r.container.rawValue)) [\(cn ?? "")]  ⊃  \(Host.short(r.contained.rawValue)) [\(dn ?? "")]   (\(r.inliers) inliers)")
                if mark { try c.memes.addRelation(Relation(from: r.container, to: r.contained, kind: .contains)) }
            }
            print("\(results.count) containment(s).\(mark ? " Recorded." : " Add --mark to record.")")
        }
    }

    struct Scan: ParsableCommand {
        @OptionGroup var collection: CollectionOption
        @Option(name: .shortAndLong, help: "Max pHash Hamming distance.") var threshold: Int = StagingArea.similarThreshold
        func run() throws {
            let c = try collection.open()
            let clusters = try DuplicateScanner(collection: c).clusters(threshold: threshold)
            for (n, cl) in clusters.enumerated() {
                print("#\(n + 1)  \(cl.members.count) memes, \(cl.allExact ? "identical" : "d≤\(cl.maxDistance)")")
                for m in cl.members {
                    print("    \(Host.short(m.rawValue))  \(try c.memes.primaryAsset(of: m)?.originalName ?? "")  \(Host.fmtTags(try c.memes.tags(of: m)))")
                }
            }
            print("\(clusters.count) cluster(s). Resolve: memebooru dedup keep <id>  |  dedup mark <a> <b> duplicate|variant|contains|no")
        }
    }

    struct Keep: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Keep one meme of its cluster, mark and delete the rest.")
        @OptionGroup var collection: CollectionOption
        @Argument var id: String
        func run() throws {
            let c = try collection.open()
            let scanner = DuplicateScanner(collection: c)
            guard let cl = try scanner.clusters().first(where: { $0.members.contains { $0.rawValue.hasPrefix(id.lowercased()) } }),
                  let keep = cl.members.first(where: { $0.rawValue.hasPrefix(id.lowercased()) }) else { throw ValidationError("no cluster contains \(id)") }
            // What `scanner.resolve` does, with the deletions as one undo step (`memebooru undo`).
            let others = cl.members.filter { $0 != keep }
            for m in others { try c.memes.addRelation(Relation(from: keep, to: m, kind: .duplicate)) }
            try c.deleteMemes(others, label: "Kept \(Host.short(keep.rawValue)), removed \(others.count) duplicate\(others.count == 1 ? "" : "s")")
            print("kept \(keep), removed \(cl.members.count - 1)")
        }
    }

    struct Mark: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Record a relation for a pair, or 'no' to dismiss it.")
        @OptionGroup var collection: CollectionOption
        @Argument var a: String
        @Argument var b: String
        @Argument(help: "duplicate | variant | contains (a contains b) | no") var verdict: String
        @Flag(name: .long, help: "With 'duplicate': delete b, keeping a.") var deleteB = false
        func run() throws {
            let c = try collection.open()
            let all = try c.search.search("", limit: 1_000_000).memes
            func find(_ p: String) throws -> MemeID {
                let m = all.filter { $0.id.rawValue.hasPrefix(p.lowercased()) }
                guard m.count == 1 else { throw ValidationError("no unique meme for \(p)") }
                return m[0].id
            }
            let (x, y) = (try find(a), try find(b))
            if verdict == "no" { try DuplicateScanner(collection: c).dismiss(x, y); print("dismissed"); return }
            guard let kind = Relation.Kind(rawValue: verdict) else { throw ValidationError("bad verdict \(verdict)") }
            try c.memes.addRelation(Relation(from: x, to: y, kind: kind))
            if kind == .duplicate && deleteB { try c.deleteMemes([y]); print("deleted \(y)") }
            print("\(x) —\(kind.rawValue)→ \(y)")
        }
    }
}

struct Export: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Copy a meme out of the collection, optionally converted (the copy is never stored).",
        discussion: "--format: stored (default), original, or one of: \(MediaFormat.allCases.map(\.rawValue).joined(separator: ", "))")
    @OptionGroup var collection: CollectionOption
    @Argument var id: String
    @Argument(help: "Destination file or directory.") var dest: String
    @Option(name: .shortAndLong, help: "stored | original | a format (see --help).") var format = "stored"

    func run() throws {
        let c = try collection.open()
        let m = try c.search.search("", limit: 1_000_000).memes.filter { $0.id.rawValue.hasPrefix(id.lowercased()) }
        guard m.count == 1 else { throw ValidationError("no unique meme \(id)") }
        let choice: ExportChoice
        switch format {
        case "stored": choice = .stored
        case "original": choice = .original
        default:
            guard let f = MediaFormat(rawValue: format) else { throw ValidationError("unknown format \(format)") }
            guard FormatPolicy.exportFormats(kind: m[0].kind).contains(f) else { throw ValidationError("a \(m[0].kind.rawValue) can't be exported as \(f.label)") }
            choice = .format(f)
        }
        if choice == .stored, let p = try c.memes.primaryAsset(of: m[0].id), p.compatibility(kind: m[0].kind) == .uncommon {
            let target = FormatPolicy.popularTarget(kind: m[0].kind, ext: p.ext, codecs: p.codecs)
            print("note: stored only as \(p.formatLabel), an uncommon format\(target.map { " — try --format \($0.rawValue)" } ?? "")")
        }
        let out = try c.export(m[0].id, as: choice, to: URL(fileURLWithPath: (dest as NSString).expandingTildeInPath),
                               analyzer: MediaAnalyzer(platform: Host.platform()))
        print(out.path)
    }
}

struct Convert: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Convert a meme stored in an uncommon format to its popular format.")
    @OptionGroup var collection: CollectionOption
    @Argument(help: "Meme id prefix, or 'all' for every uncommon meme.") var id: String
    @Flag(name: .long, help: "Keep the uncommon file as the meme's original.") var keepOriginal = false

    func run() throws {
        let c = try collection.open()
        let analyzer = MediaAnalyzer(platform: Host.platform())
        let all = try c.search.search("", limit: 1_000_000).memes
        let targets = id == "all" ? all : all.filter { $0.id.rawValue.hasPrefix(id.lowercased()) }
        var done = 0
        for m in targets {
            guard let p = try c.memes.primaryAsset(of: m.id), p.compatibility(kind: m.kind) == .uncommon else {
                if id != "all" { print("\(Host.short(m.id.rawValue)): already popular") }
                continue
            }
            do {
                let a = try c.convertMeme(m.id, keepOriginal: keepOriginal, analyzer: analyzer)
                print("✓ \(Host.short(m.id.rawValue))  \(p.formatLabel) → \(a.formatLabel)\(keepOriginal ? " (original kept)" : "")")
                done += 1
            } catch { print("✗ \(Host.short(m.id.rawValue))  \(p.formatLabel): \(error)") }
        }
        print("converted \(done)")
    }
}

struct Render: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Draw tweets as pictures (what the Telegram bot sends), stored as each tweet's render.")
    @OptionGroup var collection: CollectionOption
    @Argument(help: "Tweet meme id prefix, or 'all'.") var id: String
    @Option(name: .shortAndLong, help: "Also copy the picture to this file (single tweet only).") var output: String?
    @Flag(name: .long, help: "Draw again even when the stored picture is up to date.") var force = false

    func run() throws {
        let c = try collection.open()
        let analyzer = MediaAnalyzer(platform: Host.platform())
        guard analyzer.platform.text != nil else {
            throw ValidationError("no text renderer on this machine (Linux: install pango1.0-tools and fonts-noto-core)")
        }
        let all = try c.search.search("", limit: 1_000_000).memes.filter { $0.kind == .tweet }
        let targets = id == "all" ? all : all.filter { $0.id.rawValue.hasPrefix(id.lowercased()) }
        if targets.isEmpty { print("no tweets match \(id)") }
        var drawn = 0
        for m in targets {
            let before = try c.memes.asset(of: m.id, role: .render)?.sha256
            do {
                guard let a = try c.tweetRender(m, analyzer: analyzer, force: force) else { continue }
                let fresh = a.sha256 != before
                if fresh { drawn += 1 }
                print("\(fresh ? "✓" : "=") \(Host.short(m.id.rawValue))  \(a.width ?? 0)×\(a.height ?? 0) \(a.ext)")
                if let output, targets.count == 1 {
                    let dest = URL(fileURLWithPath: output)
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.copyItem(at: c.media.url(sha256: a.sha256, ext: a.ext), to: dest)
                }
            } catch { print("✗ \(Host.short(m.id.rawValue)): \(error)") }
        }
        print("drawn \(drawn), up to date \(targets.count - drawn)")
    }
}
