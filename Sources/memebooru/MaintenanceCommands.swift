import ArgumentParser
import Foundation
import MemebooruCore

struct DeleteTweets: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete-tweets",
        abstract: "Soft-delete every tweet-kind meme (undoable in the app or with `undo`).")
    @OptionGroup var collection: CollectionOption
    func run() throws {
        let c = try collection.open()
        let ids = try c.search.search("", limit: 1_000_000).memes.filter { $0.kind == .tweet }.map(\.id)
        guard !ids.isEmpty else { print("no tweets"); return }
        let summary = try c.deleteMemes(ids, label: "Delete \(ids.count) tweets")
        print(summary + " — reversible: `memebooru undo`")
    }
}

struct Undo: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Undo the last reversible bulk action.")
    @OptionGroup var collection: CollectionOption
    func run() throws {
        let c = try collection.open()
        if let s = try c.undoLast() { print("undone: \(s)") } else { print("nothing to undo") }
    }
}
