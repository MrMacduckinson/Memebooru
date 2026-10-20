import Foundation
import Testing
@testable import MemebooruCore

/// The app, the CLI and the share extension must agree on which machine they are, or each one opening
/// the same collection takes it for a copy and gives it a new device id (breaking sync pairings).
@Suite struct MachineIDTests {
    private func dir() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("mb-mid-\(UUID().uuidString)") }

    @Test func firstUseKeepsTheOldIdAndEveryoneReadsIt() {
        let d = dir(); defer { try? FileManager.default.removeItem(at: d) }
        #expect(Collection.machineID(in: d, legacy: "app-id") == "app-id")      // the app came first
        #expect(Collection.machineID(in: d, legacy: "cli-id") == "app-id")      // the CLI reads the same file
        #expect(Collection.machineID(in: d, legacy: nil) == "app-id")           // a fresh extension too
    }

    @Test func noOldIdMakesANewOne() {
        let d = dir(); defer { try? FileManager.default.removeItem(at: d) }
        let a = Collection.machineID(in: d, legacy: nil)
        #expect(UUID(uuidString: a) != nil)
        #expect(Collection.machineID(in: d, legacy: nil) == a)
    }

    @Test func blankOrPaddedFilesAreHandled() throws {
        let d = dir(); defer { try? FileManager.default.removeItem(at: d) }
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try Data("  \n".utf8).write(to: d.appendingPathComponent("machine-id"))
        // Blank file: there's no id to read, and it can't be claimed atomically — still a stable answer.
        let first = Collection.machineID(in: d, legacy: "x")
        #expect(!first.isEmpty)
        try Data(" abc \n".utf8).write(to: d.appendingPathComponent("machine-id"))
        #expect(Collection.machineID(in: d, legacy: "x") == "abc")
    }

    @Test func manyProcessesStartingAtOnceAgree() async {
        let d = dir(); defer { try? FileManager.default.removeItem(at: d) }
        let ids = await withTaskGroup(of: String.self) { g in
            for i in 0..<32 { g.addTask { Collection.machineID(in: d, legacy: "id-\(i)") } }
            var all: Set<String> = []
            for await id in g { all.insert(id) }
            return all
        }
        #expect(ids.count == 1)
    }

    @Test func aCollectionKeepsItsDeviceIdAcrossOpeners() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mb-mid-\(UUID().uuidString).memebooru")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try Collection.create(at: url).deviceID
        // Reopened by "another program" on the same machine: same shared id, same device.
        #expect(try Collection.openOrCreate(at: url).deviceID == first)
    }
}

@Suite struct CollectionLifetimeTests {
    /// A collection that's no longer used goes away and closes its database (a long-running server
    /// or the CLI's tests open many; each kept its files open before).
    @Test func aClosedCollectionIsFreed() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mb-life-\(UUID().uuidString).memebooru")
        defer { try? FileManager.default.removeItem(at: url) }
        weak var gone: Collection?
        weak var gone2: Collection?
        do {
            let c = try Collection.create(at: url)
            _ = try c.staging.add(text: "hello", source: "test")
            _ = try c.staging.list()
            _ = try c.undo.allBatches()
            gone = c
        }
        do {
            let c = try Collection.openOrCreate(at: url)
            let item = try #require(try c.staging.list().first)
            _ = try c.staging.commit(item.id)
            gone2 = c
        }
        #expect(gone == nil && gone2 == nil)
    }
}

@Suite struct MachineIDIsolationTests {
    /// A test run must never create or change the real install's id file.
    @Test func testRunsKeepTheirOwnId() {
        #expect(Collection.isTestProcess)
        let dir = Collection.machineIDDirectory?.path ?? ""
        #expect(dir.hasPrefix(FileManager.default.temporaryDirectory.path) || ProcessInfo.processInfo.environment["MEMEBOORU_STATE_DIR"] != nil)
        #expect(!dir.contains("Application Support") && !dir.hasSuffix("/.config/memebooru"))
    }
}
