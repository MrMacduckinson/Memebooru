import Foundation
import Testing
@testable import MemebooruCore

@Suite struct DatabaseTests {
    @Test func migratesToCurrentVersion() throws {
        let db = try Database.inMemory()
        #expect(db.userVersion == 0)
        try Schema.migrate(db)
        #expect(db.userVersion == Schema.currentVersion)
        try Schema.migrate(db) // idempotent
        #expect(db.userVersion == Schema.currentVersion)
    }

    @Test func fts5IsAvailable() throws {
        let db = try Database.inMemory()
        try Schema.migrate(db)
        try db.run("INSERT INTO meme_fts(meme_id, text_exact) VALUES (?, ?)", ["m1", "обед со Сталиным"])
        let hits = try db.query("SELECT meme_id FROM meme_fts WHERE meme_fts MATCH ?", ["сталиным"]) { $0.string(0) }
        #expect(hits == ["m1"])
    }

    @Test func bindsAndReadsAllTypes() throws {
        let db = try Database.inMemory()
        try db.exec("CREATE TABLE t(i INTEGER, d REAL, s TEXT, b BLOB, n)")
        try db.run("INSERT INTO t VALUES (?,?,?,?,?)", [Int64(42), 1.5, "x", Data([1, 2, 3]), SQLValue.null])
        let row = try db.first("SELECT * FROM t") { ($0.int64("i"), $0.double("d"), $0.string("s"), $0.data("b"), $0.isNull(4)) }
        #expect(row?.0 == 42 && row?.1 == 1.5 && row?.2 == "x" && row?.3 == Data([1, 2, 3]) && row?.4 == true)
    }

    @Test func nestedTransactionRollsBackInnerOnly() throws {
        let db = try Database.inMemory()
        try db.exec("CREATE TABLE t(v)")
        try db.transaction {
            try db.run("INSERT INTO t VALUES (1)")
            _ = try? db.transaction {
                try db.run("INSERT INTO t VALUES (2)")
                throw TagError("boom")
            }
        }
        #expect(try db.scalarInt("SELECT count(*) FROM t") == 1)
    }

    @Test func paramCountMismatchThrows() throws {
        let db = try Database.inMemory()
        try db.exec("CREATE TABLE t(v)")
        #expect(throws: DatabaseError.self) { try db.run("INSERT INTO t VALUES (?)", []) }
    }
}
