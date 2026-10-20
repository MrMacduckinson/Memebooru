import Foundation
import Testing
import MemebooruCore
@testable import memebooru

/// The CLI writes to a collection that the app has open at the same time (its own SQLite
/// connection, reading and writing on another thread). Nothing may fail with "database is locked".
@Suite struct CLIConcurrencyTests {
    /// The "app": its own `Collection` on the same folder, hammering reads and writes until stopped.
    final class FakeApp: @unchecked Sendable {
        let collection: Collection
        let errors = Locked<[String]>([])
        let writes = Locked(0), reads = Locked(0)
        private let stop = Locked(false)
        private var thread: Thread?
        private let done = DispatchSemaphore(value: 0)

        init(_ url: URL) throws { collection = try Collection.open(at: url) }

        func start() {
            let t = Thread { [self] in
                var i = 0
                while !stop.value {
                    i += 1
                    do {
                        let m = Meme(kind: .text, textVerbatim: "app note \(i)")
                        try collection.memes.insert(m, tags: ["from_app", "app_\(i % 5)"])
                        if i % 3 == 0 { try collection.memes.addTag(m.id, "edited_in_app", kind: .normal) }
                        if i % 7 == 0 { try collection.deleteMemes([m.id], label: "app delete") }
                        writes.mutate { $0 += 1 }
                        _ = try collection.search.search("from_app", limit: 50)
                        _ = try collection.tags.suggest(prefix: "app")
                        _ = try collection.memes.count()
                        _ = try Host.staging(collection).list()
                        reads.mutate { $0 += 1 }
                    } catch { errors.mutate { $0.append("\(error)") } }
                }
                done.signal()
            }
            t.start()
            thread = t
        }

        func finish() {
            stop.mutate { $0 = true }
            done.wait()
        }
    }

    private static func noLockErrors(_ r: CLIResult) -> Bool {
        let all = (r.out + r.err).lowercased()
        return !all.contains("locked") && !all.contains("busy")
    }

    @Test func cliWritesWhileTheAppReadsAndWrites() async throws {
        let c = try await CLICollection()
        let inc = try TempDir()
        for (i, p) in Samples.Pattern.allCases.enumerated() { try inc.write("pic \(i).png", try Samples.png(p)) }

        let app = try FakeApp(c.url)
        app.start()

        var results: [CLIResult] = []
        for round in 0..<6 {
            results.append(await c.run("add", inc.url.path, "-t", "round_\(round)"))
            results.append(await c.run("stage", "ls"))
            results.append(await c.run("stage", "commit", "all", "--force"))
            results.append(await c.run("search", "round_\(round)"))
            results.append(await c.run("tag", "alias", "r\(round)", "round_\(round)"))
            results.append(await c.run("search", "from_app"))
            results.append(await c.run("dedup", "scan"))
            results.append(await c.run("info"))
            if round % 2 == 1 { results.append(await c.run("undo")) }
        }
        app.finish()

        for r in results { #expect(r.ok && Self.noLockErrors(r), "\(r)") }
        #expect(app.errors.value.isEmpty, "app side: \(app.errors.value.prefix(5))")
        #expect(app.writes.value >= 10 && app.reads.value >= 10, "app did \(app.writes.value) writes, \(app.reads.value) reads")

        // Both sides' writes are all there, seen from a third, fresh connection.
        let fresh = try c.open()
        #expect(try fresh.ids("from_app").count > 0)
        #expect(try fresh.ids("round_0").count == Samples.Pattern.allCases.count)
        #expect(try Host.staging(fresh).count() == 0)
        let integrity = try fresh.db.query("PRAGMA integrity_check", []) { $0.string(0) }
        #expect(integrity == ["ok"])
    }

    @Test func manyCLIRunsInParallelOnOneCollection() async throws {
        let c = try await CLICollection()
        let inc = try TempDir()
        for (i, p) in Samples.Pattern.allCases.enumerated() { try inc.write("p\(i).png", try Samples.png(p)) }
        let app = try FakeApp(c.url)
        app.start()
        let results = await withTaskGroup(of: CLIResult.self) { group in
            for i in 0..<12 {
                group.addTask {
                    switch i % 4 {
                    case 0: return await c.run("add", inc.url.path, "-t", "par_\(i)")
                    case 1: return await c.run("search", "from_app")
                    case 2: return await c.run("tag", "add", "tag_\(i)")
                    default: return await c.run("info")
                    }
                }
            }
            var out: [CLIResult] = []
            for await r in group { out.append(r) }
            return out
        }
        app.finish()
        for r in results { #expect(r.ok && Self.noLockErrors(r), "\(r)") }
        #expect(app.errors.value.isEmpty, "app side: \(app.errors.value.prefix(5))")
        #expect(try Host.staging(c.open()).count() == 3 * Samples.Pattern.allCases.count)
        // Every app insert landed (the CLI committed nothing here).
        #expect(try c.open().db.scalarInt("SELECT count(*) FROM meme", []) == Int64(app.writes.value))
    }
}
