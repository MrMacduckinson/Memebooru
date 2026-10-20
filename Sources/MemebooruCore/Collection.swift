import Foundation

public struct CollectionError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ d: String) { description = d }
}

/// A self-contained folder: `collection.db` + `media/` + `thumbs/` + `staging/` + `device.json`.
public final class Collection: @unchecked Sendable {
    public static let dbName = "collection.db"

    public let url: URL
    public let db: Database
    public let media: MediaStore
    public let deviceID: String
    public private(set) var deviceName: String
    public let clock: HLCClock
    public let oplog: OpLog
    public let tags: TagRegistry
    public let memes: MemeStore
    public let search: QueryExecutor
    public let peers: PeerRegistry
    public let wayback: WaybackQueue
    public private(set) var undo: UndoLog!
    /// Internal staging (no analyzer) for undo/restore. Import UIs make their own with an analyzer.
    /// Made on each use (it holds no state of its own): a stored one would hold the collection, the
    /// collection it, and neither — nor the database files — would ever be freed.
    public var staging: StagingArea { StagingArea(collection: self, analyzer: nil) }

    public var mediaURL: URL { url.appendingPathComponent("media", isDirectory: true) }
    public var thumbsURL: URL { url.appendingPathComponent("thumbs", isDirectory: true) }
    public var stagingURL: URL { url.appendingPathComponent("staging", isDirectory: true) }
    public var name: String { url.deletingPathExtension().lastPathComponent }

    private init(url: URL) throws {
        let fm = FileManager.default
        self.url = url
        for dir in ["media", "thumbs", "staging"] {
            try fm.createDirectory(at: url.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        let device = try Self.loadOrCreateDevice(in: url)
        deviceID = device.id
        deviceName = device.name
        db = try Database(path: url.appendingPathComponent(Self.dbName).path)
        try db.exec("PRAGMA journal_mode = WAL")
        try Schema.migrate(db)
        media = MediaStore(root: url.appendingPathComponent("media", isDirectory: true),
                           thumbs: url.appendingPathComponent("thumbs", isDirectory: true))
        clock = HLCClock(device: deviceID)
        oplog = OpLog(db: db, clock: clock)
        if let last = try oplog.latestHLC() { clock.observe(last) }
        tags = TagRegistry(db: db, oplog: oplog)
        memes = MemeStore(db: db, oplog: oplog, tags: tags)
        search = QueryExecutor(db: db, tags: tags)
        peers = PeerRegistry(db: db)
        wayback = WaybackQueue(db: db)
        undo = UndoLog(db: db, collection: self)
    }

    /// Rename this replica (shown to peers). Not synced.
    public func renameDevice(_ name: String) throws {
        let file = url.appendingPathComponent("device.json")
        try JSONEncoder().encode(DeviceInfo(id: deviceID, name: name, machine: Self.machineID)).write(to: file, options: .atomic)
        deviceName = name
    }

    public static func exists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(dbName).path)
    }

    public static func create(at url: URL) throws -> Collection {
        guard !exists(at: url) else { throw CollectionError("collection already exists at \(url.path)") }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try Collection(url: url)
    }

    public static func open(at url: URL) throws -> Collection {
        guard exists(at: url) else { throw CollectionError("no collection at \(url.path)") }
        return try Collection(url: url)
    }

    public static func openOrCreate(at url: URL) throws -> Collection {
        exists(at: url) ? try open(at: url) : try create(at: url)
    }

    // MARK: - device.json

    private struct DeviceInfo: Codable { var id: String; var name: String; var machine: String? }

    /// Identity of this install. A collection folder copied to another machine carries a foreign
    /// `machine`, so it gets a fresh device id instead of impersonating the original.
    /// Kept in one file (`machineIDDirectory/machine-id`) that the app, the CLI and the share extension
    /// all read — each with its own preferences, they used to disagree and re-id the collection each
    /// time the other one opened it. A server sets `machineIDOverride` (from a file on its data volume).
    nonisolated(unsafe) public static var machineIDOverride: String?
    /// Apps that share collections with an extension point this at their app group container.
    nonisolated(unsafe) public static var machineIDDirectory: URL? = defaultMachineIDDirectory

    static var defaultMachineIDDirectory: URL? {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["MEMEBOORU_STATE_DIR"], !dir.isEmpty { return URL(fileURLWithPath: dir, isDirectory: true) }
        // Test runs never touch the real install's id (a test that wrote it would re-id the user's collections).
        if isTestProcess { return FileManager.default.temporaryDirectory.appendingPathComponent("memebooru-test-state-\(getpid())", isDirectory: true) }
        #if os(Linux)
        let config = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return config.appendingPathComponent("memebooru", isDirectory: true)
        #else
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Memebooru", isDirectory: true)
        #endif
    }

    /// swift test / xctest / Xcode test hosts.
    static var isTestProcess: Bool {
        let p = ProcessInfo.processInfo
        if p.environment["XCTestConfigurationFilePath"] != nil || p.environment["XCTestSessionIdentifier"] != nil { return true }
        let name = p.processName.lowercased()
        return name.contains("xctest") || name.contains("swiftpm-testing-helper") || name.hasSuffix("packagetests")
            || Bundle.main.bundlePath.hasSuffix(".xctest")
    }

    public static var machineID: String {
        if let o = machineIDOverride { return o }
        let legacyKey = "memebooru.machineID"
        guard let dir = machineIDDirectory else { return legacyMachineID(legacyKey) }
        return machineID(in: dir, legacy: UserDefaults.standard.string(forKey: legacyKey))
    }

    /// The id stored in `dir/machine-id`, created on first use — from `legacy` (this install's old
    /// per-app id, so collections it already opened don't take it for a copy) or a new one.
    static func machineID(in dir: URL, legacy: String?) -> String {
        let file = dir.appendingPathComponent("machine-id")
        if let m = readMachineID(file) { return m }
        let m = legacy ?? UUID().uuidString.lowercased()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do { try Data(m.utf8).write(to: file, options: .withoutOverwriting) }
        catch { if let other = readMachineID(file) { return other } }   // another process got there first
        return m
    }

    private static func readMachineID(_ file: URL) -> String? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    private static func legacyMachineID(_ key: String) -> String {
        if let m = UserDefaults.standard.string(forKey: key) { return m }
        let m = UUID().uuidString.lowercased()
        UserDefaults.standard.set(m, forKey: key)
        UserDefaults.standard.synchronize()   // a CLI may exit (or be killed) before the async flush
        return m
    }

    // MARK: - Bulk actions (undoable, survive restart)

    /// Commit every staged item; returns a summary. Reversible via `undoLast`.
    @discardableResult
    /// `onProgress` gets the count done after each item; `isCancelled` stops between items (what's
    /// committed stays, in the same undo step).
    public func commitStaged(_ items: [StagedItem], analyzer: MediaAnalyzer? = nil,
                             onProgress: ((Int) -> Void)? = nil, isCancelled: () -> Bool = { false }) throws -> String {
        guard !items.isEmpty else { return "Nothing to commit" }
        let area = analyzer.map { StagingArea(collection: self, analyzer: $0) } ?? staging
        let batch = try undo.begin(kind: "commit", summary: "Commit \(items.count) staged")
        var done = 0
        func summary() -> String { "Committed \(done) item\(done == 1 ? "" : "s")" }
        do {
            for item in items {
                if isCancelled() { break }
                _ = try area.commit(item.id, undoBatch: batch)
                done += 1
                onProgress?(done)
            }
        } catch {
            try? undo.finish(batch, summary: summary())   // what did go in stays one honest undo step (none if nothing did)
            throw error
        }
        try undo.finish(batch, summary: summary())
        return summary()
    }

    /// Discard every staged item to a trash folder; reversible via `undoLast`.
    @discardableResult
    public func discardStaged(_ items: [StagedItem]) throws -> String {
        guard !items.isEmpty else { return "Nothing to discard" }
        let batch = try undo.begin(kind: "discard", summary: "Discard \(items.count) staged")
        do { for item in items { try staging.discardToTrash(item, batch: batch) } }
        catch { try? undo.finish(batch); throw error }
        let summary = "Discarded \(items.count) item\(items.count == 1 ? "" : "s")"
        try undo.finish(batch, summary: summary)
        return summary
    }

    /// Soft-delete memes; reversible via `undoLast`.
    @discardableResult
    public func deleteMemes(_ ids: [MemeID], label: String? = nil) throws -> String {
        guard !ids.isEmpty else { return "Nothing to delete" }
        let batch = try undo.begin(kind: "delete", summary: "Delete \(ids.count)")
        do { for id in ids { try memes.delete(id); try undo.record(batch, op: "delete_meme", data: id.rawValue) } }
        catch { try? undo.finish(batch); throw error }
        let summary = label ?? "Deleted \(ids.count) meme\(ids.count == 1 ? "" : "s")"
        try undo.finish(batch, summary: summary)
        return summary
    }

    public func deleteMeme(_ id: MemeID) throws -> String { try deleteMemes([id]) }

    @discardableResult
    public func undoLast() throws -> String? { try undo.undoLast() }

    /// x import cursor (checkpoint) per feed.
    public func xCursor(_ feed: String) throws -> String? { try db.scalarString("SELECT cursor FROM x_cursor WHERE feed = ?", [feed]) }
    public func setXCursor(_ feed: String, _ cursor: String?) throws {
        try db.run("INSERT INTO x_cursor(feed, cursor, updated_at) VALUES (?,?,?) ON CONFLICT(feed) DO UPDATE SET cursor = excluded.cursor, updated_at = excluded.updated_at",
                   [feed, cursor, Clock.nowMillis()])
    }
    public func clearXCursor(_ feed: String) throws { try db.run("DELETE FROM x_cursor WHERE feed = ?", [feed]) }

    private static func loadOrCreateDevice(in url: URL) throws -> DeviceInfo {
        let file = url.appendingPathComponent("device.json")
        let machine = machineID
        if let data = try? Data(contentsOf: file), var d = try? JSONDecoder().decode(DeviceInfo.self, from: data) {
            if d.machine == machine { return d }
            d = DeviceInfo(id: UUID().uuidString.lowercased(), name: d.name, machine: machine)   // cloned folder → new replica
            try JSONEncoder().encode(d).write(to: file, options: .atomic)
            return d
        }
        let d = DeviceInfo(id: UUID().uuidString.lowercased(), name: ProcessInfo.processInfo.hostName, machine: machine)
        try JSONEncoder().encode(d).write(to: file, options: .atomic)
        return d
    }
}
