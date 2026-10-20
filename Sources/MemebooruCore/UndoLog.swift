import Foundation

/// Persistent, cross-restart undo for bulk actions. Each action is a batch of reversible entries.
public final class UndoLog: @unchecked Sendable {
    public struct Batch: Sendable, Equatable, Identifiable {
        public let id: Int64
        public let kind: String
        public let summary: String
        public let createdAt: Int64
        public let count: Int
        public var undone: Bool = false
    }

    /// One reversible item inside a batch (e.g. a single deleted post).
    public struct Entry: Sendable, Equatable, Identifiable {
        public let id: Int64
        public let op: String
        public let data: String?
        public let undone: Bool
        /// The meme this entry restores, when it references one directly (for a preview thumbnail).
        public var memeID: String? { (op == "delete_meme" || op == "create_meme") ? data : nil }
    }

    private let db: Database
    private unowned let collection: Collection

    init(db: Database, collection: Collection) { self.db = db; self.collection = collection }

    // MARK: - Recording

    @discardableResult
    public func begin(kind: String, summary: String) throws -> Int64 {
        // One locked unit: another thread's insert in between would hand us its row id.
        try db.sync {
            try db.run("INSERT INTO undo_batch(kind, summary, created_at) VALUES (?,?,?)", [kind, summary, Clock.nowMillis()])
            return db.lastInsertRowID
        }
    }

    func record(_ batch: Int64, op: String, data: String?) throws {
        try db.run("INSERT INTO undo_entry(batch_id, op, data) VALUES (?,?,?)", [batch, op, data])
    }

    /// Finalize a batch's summary + count, or delete it if empty.
    public func finish(_ batch: Int64, summary: String? = nil) throws {
        let n = try db.scalarInt("SELECT count(*) FROM undo_entry WHERE batch_id = ?", [batch])
        if n == 0 { try db.run("DELETE FROM undo_batch WHERE id = ?", [batch]); return }
        try db.run("UPDATE undo_batch SET count = ?" + (summary != nil ? ", summary = ?" : "") + " WHERE id = ?",
                   summary != nil ? [n, summary!, batch] : [n, batch])
    }

    // MARK: - Query

    public func lastUndoable() throws -> Batch? {
        try db.first("SELECT id, kind, summary, created_at, count, undone FROM undo_batch WHERE undone = 0 ORDER BY id DESC LIMIT 1", [], Self.batch)
    }

    /// Full history, newest first (for the "Recently deleted" page).
    public func allBatches() throws -> [Batch] {
        try db.query("SELECT id, kind, summary, created_at, count, undone FROM undo_batch ORDER BY id DESC", [], Self.batch)
    }

    /// The reversible items of a batch, oldest first.
    public func entries(of batchID: Int64) throws -> [Entry] {
        try db.query("SELECT id, op, data, undone FROM undo_entry WHERE batch_id = ? ORDER BY id", [batchID]) {
            Entry(id: $0.int64("id"), op: $0.string("op"), data: $0.optString("data"), undone: $0.int("undone") != 0)
        }
    }

    private static func batch(_ r: Row) -> Batch {
        Batch(id: r.int64("id"), kind: r.string("kind"), summary: r.string("summary"),
              createdAt: r.int64("created_at"), count: r.int("count"), undone: r.int("undone") != 0)
    }

    // MARK: - Undo

    /// Reverse the most recent un-undone batch. Returns its summary.
    @discardableResult
    public func undoLast() throws -> String? {
        guard let batch = try lastUndoable() else { return nil }
        try undo(batch.id)
        return batch.summary
    }

    public func undo(_ batchID: Int64) throws {
        try db.transaction {
            // reverse order; skip entries already restored individually
            let entries = try db.query("SELECT id, op, data FROM undo_entry WHERE batch_id = ? AND undone = 0 ORDER BY id DESC", [batchID]) {
                ($0.int64("id"), $0.string("op"), $0.optString("data"))
            }
            for (eid, op, data) in entries {
                try apply(op: op, data: data, batchID: batchID)
                try db.run("UPDATE undo_entry SET undone = 1 WHERE id = ?", [eid])
            }
            try db.run("UPDATE undo_batch SET undone = 1 WHERE id = ?", [batchID])
        }
    }

    /// Restore one item. Marks the batch fully undone once its last remaining item is restored.
    public func restoreEntry(_ entryID: Int64) throws {
        try db.transaction {
            guard let e = try db.first("SELECT batch_id, op, data, undone FROM undo_entry WHERE id = ?", [entryID], {
                (batch: $0.int64("batch_id"), op: $0.string("op"), data: $0.optString("data"), undone: $0.int("undone") != 0)
            }), !e.undone else { return }
            try apply(op: e.op, data: e.data, batchID: e.batch)
            try db.run("UPDATE undo_entry SET undone = 1 WHERE id = ?", [entryID])
            let remaining = try db.scalarInt("SELECT count(*) FROM undo_entry WHERE batch_id = ? AND undone = 0", [e.batch])
            if remaining == 0 { try db.run("UPDATE undo_batch SET undone = 1 WHERE id = ?", [e.batch]) }
        }
    }

    private func apply(op: String, data: String?, batchID: Int64) throws {
        switch op {
        case "create_meme":                              // undo a creation → soft delete
            if let id = data { try collection.memes.delete(MemeID(id)) }
        case "delete_meme":                              // undo a deletion → restore
            if let id = data { try collection.memes.undelete(MemeID(id)) }
        case "stage_removed":                            // undo a discard → restore row + files
            if let json = data, let d = json.data(using: .utf8),
               let item = try? JSONDecoder().decode(StagedItemDTO.self, from: d) {
                try collection.staging.restore(item.item, fromTrash: batchID)
            }
        case "stage_created":                            // undo a combine / split → drop what it made
            if let id = data { try collection.staging.discard(id) }
        default: break
        }
    }
}

/// Serializable staged item for the undo log.
struct StagedItemDTO: Codable { let item: StagedItem }
