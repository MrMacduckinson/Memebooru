import ArgumentParser
import Foundation
import MemebooruCore

@main
struct MemebooruCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "memebooru",
        abstract: "Booru for memes — collection tools.",
        version: "0.0.1",
        subcommands: [Gallery.self, Init.self, Info.self, Add.self, Stage.self, Search.self, Show.self, EditCmd.self, Thumbs.self, Import.self, Dedup.self, Export.self, Convert.self, Render.self, Sync.self, X.self, DeleteTweets.self, Undo.self, TagCmd.self]
    )
}

struct CollectionOption: ParsableArguments {
    @Option(name: [.customShort("c"), .customLong("collection")], help: "Path to a *.memebooru folder (or $MEMEBOORU_COLLECTION).")
    var path: String?

    func open() throws -> Collection {
        guard let p = path ?? ProcessInfo.processInfo.environment["MEMEBOORU_COLLECTION"] else {
            throw ValidationError("pass --collection or set MEMEBOORU_COLLECTION")
        }
        return try Collection.open(at: URL(fileURLWithPath: p))
    }
}

struct Init: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Create a new collection folder.")
    @Argument(help: "Folder to create, e.g. ~/Memes.memebooru") var path: String

    func run() throws {
        var url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        if url.pathExtension != "memebooru" { url = url.appendingPathExtension("memebooru") }
        let c = try Collection.create(at: url)
        print("created \(c.url.path) (device \(c.deviceID))")
    }
}

struct Info: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show collection stats.")
    @OptionGroup var collection: CollectionOption

    func run() throws {
        let c = try collection.open()
        print("collection: \(c.name)  (\(c.url.path))")
        print("device:     \(c.deviceName) [\(c.deviceID)]")
        print("sqlite:     \(Database.sqliteVersion), schema v\(c.db.userVersion)")
        print("memes:      \(try c.memes.count())")
        print("tags:       \(try c.tags.all().count)")
        print("ops:        \(try c.oplog.count())")
    }
}

struct TagCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tag", abstract: "Manage tags and aliases.",
        subcommands: [List.self, Add.self, Alias.self, Unalias.self, Merge.self, Kind.self, Suggest.self])

    struct List: ParsableCommand {
        @OptionGroup var collection: CollectionOption
        func run() throws {
            let c = try collection.open()
            for t in try c.tags.all() {
                let aliases = try c.tags.aliases(of: t)
                let a = aliases.isEmpty ? "" : "  (aliases: \(aliases.joined(separator: ", ")))"
                print("\(t.kind == .meta ? "[meta]  " : "[normal]") \(t.name)  ×\(try c.tags.usage(of: t))\(a)")
            }
        }
    }

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a tag.")
        @OptionGroup var collection: CollectionOption
        @Flag(name: .long, help: "Create as meta tag.") var meta = false
        @Argument var names: [String]
        func run() throws {
            let c = try collection.open()
            for n in names { let t = try c.tags.create(n, kind: meta ? .meta : .normal); print("created \(t.name) [\(t.kind.rawValue)]") }
        }
    }

    struct Alias: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add alias: memebooru tag alias tg_message telegram_message")
        @OptionGroup var collection: CollectionOption
        @Argument var alias: String
        @Argument var tag: String
        func run() throws {
            let c = try collection.open()
            guard let t = try c.tags.resolve(tag) else { throw ValidationError("unknown tag \(tag)") }
            try c.tags.addAlias(alias, to: t)
            print("\(alias) → \(t.name)")
        }
    }

    struct Unalias: ParsableCommand {
        @OptionGroup var collection: CollectionOption
        @Argument var alias: String
        func run() throws { try collection.open().tags.removeAlias(alias); print("removed \(alias)") }
    }

    struct Merge: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Merge SOURCE into TARGET; SOURCE becomes an alias.")
        @OptionGroup var collection: CollectionOption
        @Argument var source: String
        @Argument var target: String
        func run() throws {
            let c = try collection.open()
            guard let s = try c.tags.resolve(source), let t = try c.tags.resolve(target) else { throw ValidationError("unknown tag") }
            try c.tags.merge(s, into: t)
            print("merged \(s.name) → \(t.name)")
        }
    }

    struct Kind: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Set tag kind: normal | meta")
        @OptionGroup var collection: CollectionOption
        @Argument var tag: String
        @Argument var kind: TagKind
        func run() throws {
            let c = try collection.open()
            guard let t = try c.tags.resolve(tag) else { throw ValidationError("unknown tag \(tag)") }
            try c.tags.setKind(t, kind)
            print("\(t.name) → \(kind.rawValue)")
        }
    }

    struct Suggest: ParsableCommand {
        @OptionGroup var collection: CollectionOption
        @Argument var prefix: String
        func run() throws {
            for s in try collection.open().tags.suggest(prefix: prefix) {
                print("\(s.text)\(s.isAlias ? " → \(s.tag.name)" : "")  [\(s.tag.kind.rawValue)] ×\(s.usage)")
            }
        }
    }
}

extension TagKind: ExpressibleByArgument {}
