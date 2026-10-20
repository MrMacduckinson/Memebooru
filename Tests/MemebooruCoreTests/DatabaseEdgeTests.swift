import Foundation
import Testing
@testable import MemebooruCore

private func tempFolder(_ tag: String) throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("mb-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

@Suite struct MigrationTests {
    /// A `collection.db` frozen at schema `version`, holding data written with that version's columns only.
    private func legacyCollection(at version: Int) throws -> URL {
        let dir = try tempFolder("legacy-v\(version)").appendingPathExtension("memebooru")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(path: dir.appendingPathComponent(Collection.dbName).path)
        for sql in Schema.migrations.prefix(version) { try db.exec(sql) }
        try db.setUserVersion(version)
        guard version >= 1 else { return dir }
        try db.exec("""
            INSERT INTO meme(id, kind, presentation, created_at, updated_at, text_exact, text_verbatim, context, payload)
              VALUES ('m1', 'image', 'native', 1000, 1000, 'обед со Сталиным', NULL, 'плакат', NULL);
            INSERT INTO meme(id, kind, presentation, created_at, updated_at, payload)
              VALUES ('t1', 'tweet', 'native', 900, 900, '{"authorName":"A","handle":"a","tweetID":"77","url":"https://x.com/a/status/77"}');
            INSERT INTO meme(id, kind, presentation, created_at, updated_at, deleted_at) VALUES ('gone', 'image', 'native', 800, 800, 850);
            INSERT INTO meme_fts(meme_id, text_exact, text_verbatim, context) VALUES ('m1', 'обед со Сталиным', NULL, 'плакат');
            INSERT INTO tag(name, kind, created_at) VALUES ('stalin', 'normal', 1), ('2022', 'meta', 1);
            INSERT INTO tag_alias(name, tag_id) VALUES ('коба', 1);
            INSERT INTO meme_tag(meme_id, tag_id) VALUES ('m1', 1), ('m1', 2), ('gone', 1);
            INSERT INTO asset(meme_id, role, sha256, ext, mime, width, height, bytes, phash, ord, original_name)
              VALUES ('m1', 'primary', 'abc', 'jpg', 'image/jpeg', 10, 20, 3, 42, 0, 'Обед.jpg');
            INSERT INTO relation(from_id, to_id, kind, created_at) VALUES ('t1', 'm1', 'contains', 1);
            INSERT INTO staged(id, kind, source, original_name, sha256, ext, mime, bytes, suggested_tags, user_tags, added_at)
              VALUES ('s1', 'image', 'test', 'a.jpg', 'def', 'jpg', 'image/jpeg', 5, '["picture"]', '["cat"]', 1);
            INSERT INTO oplog(op_id, device_id, hlc, entity, entity_id, field, value, applied_at)
              VALUES ('op1', 'devA', '00000000000003e8-0000-devA', 'meme', 'm1', 'text_exact', 'обед со Сталиным', 1),
                     ('op2', 'devA', '00000000000003e9-0000-devA', 'meme', 'm1', 'text_exact', 'обед со Сталиным', 1);
            INSERT INTO peer(device_id, name, secret, added_at) VALUES ('devA', 'Mac', 's3cr3t', 1);
            """)
        if version >= 3 {
            try db.exec("""
                INSERT INTO undo_batch(kind, summary, created_at, count) VALUES ('delete', 'Deleted 1 meme', 1, 1);
                INSERT INTO undo_entry(batch_id, op, data) VALUES (1, 'delete_meme', 'gone');
                INSERT INTO wayback_queue(meme_id, url, added_at, tries) VALUES ('t1', 'https://x.com/a/status/77', 1, 1);
                INSERT INTO x_cursor(feed, cursor, updated_at) VALUES ('likes', 'C1', 1);
                """)
        }
        return dir
    }

    @Test(arguments: Array(0..<Schema.currentVersion))
    func upgradesFromEveryOlderVersionWithDataIntact(version: Int) throws {
        let dir = try legacyCollection(at: version)
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = try Collection.open(at: dir)
        #expect(c.db.userVersion == Schema.currentVersion)
        #expect(try c.db.scalarString("PRAGMA integrity_check") == "ok")
        #expect(try c.db.scalarInt("PRAGMA foreign_key_check") == 0)
        guard version >= 1 else {
            #expect(try c.memes.count() == 0)
            return
        }
        let m = try #require(try c.memes.get(MemeID("m1")))
        #expect(m.textExact == "обед со Сталиным" && m.context == "плакат")
        #expect(try c.memes.tags(of: m.id).map(\.name) == ["2022", "stalin"])
        #expect(try c.ids("коба") == [m.id])
        #expect(try c.ids("\"сталиным\"") == [m.id])
        #expect(try c.memes.count() == 2)
        #expect(try c.tags.usage(of: try #require(try c.tags.get(name: "stalin"))) == 1)
        let asset = try #require(try c.memes.primaryAsset(of: m.id))
        #expect(asset.originalName == "Обед.jpg" && asset.phash == 42 && asset.codecs == nil && asset.sourceSHA256 == nil)
        guard case .tweet(let p)? = try c.memes.get(MemeID("t1"))?.payload else { Issue.record("tweet payload lost"); return }
        #expect(p.tweetID == "77" && p.display == nil)
        #expect(try c.memes.relations(of: m.id).map(\.kind) == [.contains])
        let staged = try #require(try c.staging.get("s1"))
        #expect(staged.parentID == nil && staged.convert == nil && staged.keepOriginal == nil && staged.info.codecs == nil)
        #expect(staged.userTags == ["cat"] && staged.suggestedTags == ["picture"])
        #expect(try c.staging.list().map(\.id) == ["s1"])
        #expect(try c.peers.secret(for: "devA") == "s3cr3t")
        // v2 back-fills per-field clocks from the existing log (the newest op wins). From v2 on the log
        // keeps them itself, so only a pre-v2 file has the raw ops this fixture writes.
        if version < 2 {
            #expect(try c.oplog.fieldClock("meme", "m1", "text_exact")?.description == "00000000000003e9-0000-devA")
        }
        var stalinCount = 1
        if version >= 3 {
            stalinCount = 2                                                     // `gone` is back
            #expect(try c.wayback.pendingCount() == 1)
            #expect(try c.wayback.next().map(\.memeID) == [MemeID("t1")])     // next_try_at defaults to "due"
            #expect(try c.xCursor("likes") == "C1")
            #expect(try c.undo.entries(of: 1).map(\.undone) == [false])
            #expect(try c.undoLast() == "Deleted 1 meme")
            #expect(try c.memes.count() == 3)
        }
        // And the upgraded collection keeps working.
        try c.memes.insert(Meme(kind: .image), tags: ["stalin"])
        #expect(try c.ids("stalin").count == stalinCount + 1)
    }

    @Test func aFailingMigrationLeavesTheDatabaseAtItsOldVersion() throws {
        let db = try Database.inMemory()
        for sql in Schema.migrations.prefix(4) { try db.exec(sql) }
        try db.setUserVersion(4)
        try db.exec("CREATE TABLE tg_file_ref(x)")             // clashes with v5
        try db.exec("CREATE TABLE marker(v); INSERT INTO marker VALUES (1)")
        #expect(throws: DatabaseError.self) { try Schema.migrate(db) }
        #expect(db.userVersion == 4)
        #expect(try db.scalarInt("SELECT count(*) FROM sqlite_master WHERE name = 'tg_usage'") == 0)
        #expect(try db.scalarInt("SELECT count(*) FROM marker") == 1)
        try db.exec("DROP TABLE tg_file_ref")
        try Schema.migrate(db)
        #expect(db.userVersion == Schema.currentVersion)
    }

    @Test func aNewerDatabaseIsLeftAlone() throws {
        let db = try Database.inMemory()
        try Schema.migrate(db)
        try db.setUserVersion(Schema.currentVersion + 5)
        try Schema.migrate(db)
        #expect(db.userVersion == Schema.currentVersion + 5)
    }

    @Test func everyMigrationAppliesOnTopOfThePreviousOne() throws {
        let db = try Database.inMemory()
        for v in 1...Schema.currentVersion {
            try db.exec(Schema.migrations[v - 1]); try db.setUserVersion(v)
            #expect(try db.scalarString("PRAGMA integrity_check") == "ok")
        }
        let fresh = try Database.inMemory()
        try Schema.migrate(fresh)
        let schema = { (d: Database) in try d.query("SELECT type, name, sql FROM sqlite_master ORDER BY name", []) { "\($0.string(0)) \($0.string(1)) \($0.optString(2) ?? "")" } }
        #expect(try schema(db) == schema(fresh))
    }
}

@Suite struct DatabaseEdgeTests {
    @Test func throwingInsideATransactionRollsBackAndTheDatabaseStaysUsable() throws {
        let db = try Database.inMemory()
        try db.exec("CREATE TABLE t(v UNIQUE)")
        for i in 0..<20 {
            #expect(throws: TagError.self) {
                try db.transaction {
                    try db.run("INSERT INTO t VALUES (?)", [i])
                    try db.transaction { try db.run("INSERT INTO t VALUES (?)", [i + 1000]) }
                    throw TagError("boom \(i)")
                }
            }
        }
        #expect(try db.scalarInt("SELECT count(*) FROM t") == 0)
        // A constraint violation inside rolls back too.
        #expect(throws: DatabaseError.self) {
            try db.transaction {
                try db.run("INSERT INTO t VALUES (1)")
                try db.run("INSERT INTO t VALUES (1)")
            }
        }
        #expect(try db.scalarInt("SELECT count(*) FROM t") == 0)
        try db.transaction { try db.run("INSERT INTO t VALUES (7)") }
        #expect(try db.scalarInt("SELECT count(*) FROM t") == 1)
        #expect(try db.scalarString("PRAGMA integrity_check") == "ok")
    }

    @Test func deepNesting() throws {
        let db = try Database.inMemory()
        try db.exec("CREATE TABLE t(v)")
        func nest(_ depth: Int) throws {
            guard depth > 0 else { return }
            try db.transaction {
                try db.run("INSERT INTO t VALUES (?)", [depth])
                if depth % 10 == 0 { _ = try? db.transaction { try db.run("INSERT INTO t VALUES (-1)"); throw TagError("x") } }
                try nest(depth - 1)
            }
        }
        try nest(100)
        #expect(try db.scalarInt("SELECT count(*) FROM t") == 100)
        #expect(try db.scalarInt("SELECT count(*) FROM t WHERE v < 0") == 0)
    }

    @Test func valuesRoundTripAtTheirExtremes() throws {
        let db = try Database.inMemory()
        try db.exec("CREATE TABLE t(i INTEGER, s TEXT, b BLOB)")
        let text = "NUL-free unicode: Ёж 🐸 👨‍👩‍👧‍👦 \u{FFFD} 'quote' \"dq\" %_\\"
        let blob = Data((0..<70_000).map { UInt8($0 % 256) })
        for i in [Int64.min, -1, 0, Int64.max] { try db.run("INSERT INTO t VALUES (?,?,?)", [i, text, blob]) }
        let rows = try db.query("SELECT i, s, b FROM t ORDER BY i", []) { ($0.int64(0), $0.string(1), $0.data(2)) }
        #expect(rows.map(\.0) == [Int64.min, -1, 0, Int64.max])
        #expect(rows.allSatisfy { $0.1 == text && $0.2 == blob })
        #expect(try db.first("SELECT ?", [Data()]) { $0.data(0) } == Data())
        #expect(try db.first("SELECT NULL", []) { $0.optString(0) } == .some(nil))
    }

    @Test func badPathsAndMissingCollectionsThrow() throws {
        #expect(throws: DatabaseError.self) { _ = try Database(path: "/definitely/not/a/dir/\(UUID().uuidString)/x.db") }
        let dir = try tempFolder("missing").appendingPathComponent("c.memebooru")
        #expect(throws: CollectionError.self) { _ = try Collection.open(at: dir) }
        let c = try Collection.openOrCreate(at: dir)
        #expect(throws: CollectionError.self) { _ = try Collection.create(at: dir) }
        let again = try Collection.openOrCreate(at: dir)
        #expect(again.deviceID == c.deviceID)
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
    }

    @Test func walModeAndReopen() throws {
        let t = try TempCollection()
        #expect(try t.collection.db.scalarString("PRAGMA journal_mode") == "wal")
        let m = Meme(kind: .image, textExact: "wal")
        try t.collection.memes.insert(m, tags: ["w"])
        // A second connection sees committed writes right away, while the first is still open.
        let second = try Collection.open(at: t.url)
        #expect(try second.memes.get(m.id)?.textExact == "wal")
        try second.memes.addTag(m.id, "from_second")
        #expect(try t.collection.memes.tags(of: m.id).map(\.name).contains("from_second"))
        #expect(FileManager.default.fileExists(atPath: t.url.appendingPathComponent("collection.db-wal").path))
        // Checkpoint + reopen: still all there.
        try t.collection.db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        let third = try Collection.open(at: t.url)
        #expect(try third.ids("w") == [m.id])
        #expect(try third.ids("from_second") == [m.id])
        #expect(try third.db.scalarString("PRAGMA journal_mode") == "wal")
    }

    @Test func manyTasksShareOneCollection() async throws {
        let t = try TempCollection()
        let c = t.collection
        let errors = Locked<[String]>([])
        await withTaskGroup(of: Void.self) { group in
            for w in 0..<12 {
                group.addTask {
                    do {
                        for i in 0..<25 {
                            let m = Meme(kind: .image, textExact: "w\(w) i\(i)")
                            try c.memes.insert(m, tags: ["worker_\(w)", "all"])
                            if i % 5 == 0 { try c.memes.addTag(m.id, "fifth") }
                            if i % 7 == 0 { _ = try c.deleteMemes([m.id]) }
                            _ = try c.search.search("all -fifth", limit: 10)
                            _ = try c.tags.suggest(prefix: "work")
                        }
                    } catch { errors.mutate { $0.append("\(error)") } }
                }
            }
        }
        #expect(errors.value.isEmpty, "\(errors.value.prefix(3))")
        let deletedPerWorker = (0..<25).filter { $0 % 7 == 0 }.count
        #expect(try c.memes.count() == 12 * (25 - deletedPerWorker))
        for w in 0..<12 { #expect(try c.ids("worker_\(w)").count == 25 - deletedPerWorker) }
        // Every undo batch holds exactly its own delete (batch ids aren't mixed up between threads).
        let batches = try c.undo.allBatches()
        #expect(batches.count == 12 * deletedPerWorker)
        for b in batches {
            let entries = try c.undo.entries(of: b.id)
            #expect(entries.count == 1 && b.count == 1)
        }
        #expect(try c.db.scalarString("PRAGMA integrity_check") == "ok")
    }

    @Test func concurrentUndoBatchesGetTheirOwnIds() async throws {
        let t = try TempCollection()
        let undo = t.collection.undo!
        let ids = Locked<[Int64]>([])
        await withTaskGroup(of: Void.self) { group in
            for w in 0..<16 {
                group.addTask {
                    for i in 0..<150 {
                        guard let id = try? undo.begin(kind: "k", summary: "w\(w) i\(i)") else { continue }
                        ids.mutate { $0.append(id) }
                    }
                }
            }
        }
        #expect(ids.value.count == 16 * 150)
        #expect(Set(ids.value).count == ids.value.count)              // no two callers handed the same batch
    }

    @Test func twoConnectionsWritingConcurrentlyNeverSeeDatabaseIsLocked() async throws {
        let t = try TempCollection()
        let other = try Collection.open(at: t.url)            // e.g. the app and the CLI on one collection
        let seed = (0..<40).map { Meme(kind: .image, textExact: "v0 \($0)") }
        for m in seed { try t.collection.memes.insert(m) }
        let errors = Locked<[String]>([])
        await withTaskGroup(of: Void.self) { group in
            for (w, c) in [t.collection, other, t.collection, other].enumerated() {
                group.addTask {
                    do {
                        for round in 0..<30 {
                            // read-then-write transactions (update reads the old row first)
                            var m = try c.memes.get(seed[(round * 7 + w) % seed.count].id)!
                            m.textExact = "w\(w) r\(round)"
                            try c.memes.update(m)
                            try c.memes.addTag(m.id, "t\(w)")
                            try c.memes.insert(Meme(kind: .text, textVerbatim: "new \(w) \(round)"))
                        }
                    } catch { errors.mutate { $0.append("\(error)") } }
                }
            }
        }
        #expect(errors.value.isEmpty, "\(errors.value.prefix(3))")
        #expect(try t.collection.memes.count() == 40 + 4 * 30)
        #expect(try other.memes.count() == 40 + 4 * 30)
        #expect(try t.collection.db.scalarString("PRAGMA integrity_check") == "ok")
    }
}
