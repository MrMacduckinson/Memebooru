import CSQLite
import Foundation

public struct DatabaseError: Error, CustomStringConvertible, Sendable {
    public let code: Int32
    public let message: String
    public let sql: String?
    public var description: String {
        "SQLite error \(code): \(message)" + (sql.map { " — in: \($0)" } ?? "")
    }
}

public enum SQLValue: Sendable, Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

public protocol SQLBindable: Sendable { var sqlValue: SQLValue { get } }
extension Int: SQLBindable { public var sqlValue: SQLValue { .int(Int64(self)) } }
extension Int64: SQLBindable { public var sqlValue: SQLValue { .int(self) } }
extension Double: SQLBindable { public var sqlValue: SQLValue { .double(self) } }
extension String: SQLBindable { public var sqlValue: SQLValue { .text(self) } }
extension Data: SQLBindable { public var sqlValue: SQLValue { .blob(self) } }
extension Bool: SQLBindable { public var sqlValue: SQLValue { .int(self ? 1 : 0) } }
extension SQLValue: SQLBindable { public var sqlValue: SQLValue { self } }
extension Optional: SQLBindable where Wrapped: SQLBindable {
    public var sqlValue: SQLValue { self?.sqlValue ?? .null }
}

/// One result row. Values are read by column index or name.
public struct Row {
    private let stmt: OpaquePointer
    private let names: [String: Int32]

    init(stmt: OpaquePointer, names: [String: Int32]) { self.stmt = stmt; self.names = names }

    private func col(_ name: String) -> Int32 {
        guard let i = names[name] else { preconditionFailure("no column \(name)") }
        return i
    }
    public func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    public func int64(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    public func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(stmt, i)) }
    public func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    public func string(_ i: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, i) else { return "" }
        return String(cString: c)
    }
    public func data(_ i: Int32) -> Data {
        let n = Int(sqlite3_column_bytes(stmt, i))
        guard n > 0, let p = sqlite3_column_blob(stmt, i) else { return Data() }
        return Data(bytes: p, count: n)
    }
    public func optInt64(_ i: Int32) -> Int64? { isNull(i) ? nil : int64(i) }
    public func optInt(_ i: Int32) -> Int? { isNull(i) ? nil : int(i) }
    public func optString(_ i: Int32) -> String? { isNull(i) ? nil : string(i) }

    public func int64(_ n: String) -> Int64 { int64(col(n)) }
    public func int(_ n: String) -> Int { int(col(n)) }
    public func double(_ n: String) -> Double { double(col(n)) }
    public func string(_ n: String) -> String { string(col(n)) }
    public func data(_ n: String) -> Data { data(col(n)) }
    public func optInt64(_ n: String) -> Int64? { optInt64(col(n)) }
    public func optInt(_ n: String) -> Int? { optInt(col(n)) }
    public func optString(_ n: String) -> String? { optString(col(n)) }
    public func bool(_ n: String) -> Bool { int64(col(n)) != 0 }
}

/// Thin synchronous wrapper over the bundled SQLite. Serialized via a recursive lock, so a
/// single instance may be shared between threads; transactions nest as SAVEPOINTs.
public final class Database: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    private var savepointDepth = 0

    public let path: String

    public init(path: String) throws {
        self.path = path
        var h: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &h, flags, nil)
        guard rc == SQLITE_OK, let h else {
            let msg = h.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            if let h { sqlite3_close_v2(h) }
            throw DatabaseError(code: rc, message: msg, sql: nil)
        }
        handle = h
        sqlite3_busy_timeout(h, 5000)
        try exec("PRAGMA foreign_keys = ON")
    }

    public static func inMemory() throws -> Database { try Database(path: ":memory:") }

    deinit { if let handle { sqlite3_close_v2(handle) } }

    public static var sqliteVersion: String { String(cString: sqlite3_libversion()) }

    // MARK: - Locking

    public func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    // MARK: - Execution

    /// Run one or more `;`-separated statements without parameters.
    public func exec(_ sql: String) throws {
        try sync {
            var err: UnsafeMutablePointer<CChar>?
            let rc = sqlite3_exec(handle, sql, nil, nil, &err)
            if rc != SQLITE_OK {
                let msg = err.map { String(cString: $0) } ?? "exec failed"
                sqlite3_free(err)
                throw DatabaseError(code: rc, message: msg, sql: sql)
            }
        }
    }

    /// Run a single statement with bound parameters; ignores result rows.
    public func run(_ sql: String, _ params: [SQLBindable] = []) throws {
        try sync {
            let stmt = try prepare(sql, params)
            defer { sqlite3_finalize(stmt) }
            let rc = sqlite3_step(stmt)
            if rc != SQLITE_DONE && rc != SQLITE_ROW { throw error(rc, sql) }
        }
    }

    /// Run a statement and map every row.
    public func query<T>(_ sql: String, _ params: [SQLBindable] = [], _ map: (Row) throws -> T) throws -> [T] {
        try sync {
            let stmt = try prepare(sql, params)
            defer { sqlite3_finalize(stmt) }
            var names: [String: Int32] = [:]
            for i in 0..<sqlite3_column_count(stmt) {
                names[String(cString: sqlite3_column_name(stmt, i))] = i
            }
            var out: [T] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_ROW { out.append(try map(Row(stmt: stmt, names: names))) }
                else if rc == SQLITE_DONE { break }
                else { throw error(rc, sql) }
            }
            return out
        }
    }

    public func first<T>(_ sql: String, _ params: [SQLBindable] = [], _ map: (Row) throws -> T) throws -> T? {
        try query(sql, params, map).first
    }

    public func scalarInt(_ sql: String, _ params: [SQLBindable] = []) throws -> Int64 {
        try first(sql, params) { $0.int64(0) } ?? 0
    }

    public func scalarString(_ sql: String, _ params: [SQLBindable] = []) throws -> String? {
        try first(sql, params) { $0.optString(0) } ?? nil
    }

    public var lastInsertRowID: Int64 { sync { sqlite3_last_insert_rowid(handle) } }
    public var changes: Int { sync { Int(sqlite3_changes(handle)) } }

    // MARK: - Transactions

    /// Nested calls become SAVEPOINTs; any thrown error rolls back that level.
    /// The outermost level is `BEGIN IMMEDIATE`: it takes the write lock up front (waiting via the busy
    /// timeout), because a deferred read-then-write transaction can't wait for another connection's
    /// writer — SQLite answers "database is locked" at once.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try sync {
            let outer = savepointDepth == 0
            let name = "sp\(savepointDepth)"
            try exec(outer ? "BEGIN IMMEDIATE" : "SAVEPOINT \(name)")
            savepointDepth += 1
            let result: T
            do {
                result = try body()
            } catch {
                savepointDepth -= 1
                if outer { try? exec("ROLLBACK") } else { try? exec("ROLLBACK TO \(name)"); try? exec("RELEASE \(name)") }
                throw error
            }
            savepointDepth -= 1
            do { try exec(outer ? "COMMIT" : "RELEASE \(name)") } catch {
                if outer { try? exec("ROLLBACK") } else { try? exec("ROLLBACK TO \(name)"); try? exec("RELEASE \(name)") }
                throw error
            }
            return result
        }
    }

    // MARK: - Pragmas

    public var userVersion: Int {
        get { (try? scalarInt("PRAGMA user_version")).map(Int.init) ?? 0 }
    }
    public func setUserVersion(_ v: Int) throws { try exec("PRAGMA user_version = \(v)") }

    // MARK: - Internals

    private func prepare(_ sql: String, _ params: [SQLBindable]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw error(rc, sql) }
        let expected = Int(sqlite3_bind_parameter_count(stmt))
        guard expected == params.count else {
            sqlite3_finalize(stmt)
            throw DatabaseError(code: SQLITE_MISUSE, message: "expected \(expected) params, got \(params.count)", sql: sql)
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            let brc: Int32
            switch p.sqlValue {
            case .null: brc = sqlite3_bind_null(stmt, idx)
            case .int(let v): brc = sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): brc = sqlite3_bind_double(stmt, idx, v)
            case .text(let s): brc = sqlite3_bind_text(stmt, idx, s, -1, transient)
            case .blob(let d):
                brc = d.withUnsafeBytes { buf in
                    sqlite3_bind_blob(stmt, idx, buf.baseAddress, Int32(buf.count), transient)
                }
            }
            if brc != SQLITE_OK { sqlite3_finalize(stmt); throw error(brc, sql) }
        }
        return stmt
    }

    private func error(_ rc: Int32, _ sql: String) -> DatabaseError {
        DatabaseError(code: rc, message: String(cString: sqlite3_errmsg(handle)), sql: sql)
    }
}
