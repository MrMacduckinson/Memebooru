import Foundation
import Testing
import MemebooruCore
import MemebooruNet

/// The built `memebooru-server` as a real daemon process: sync only (no token in its environment,
/// so it can never reach Telegram), Wayback off, an ephemeral port. Two collections sync through it,
/// it stops on SIGTERM (what `docker stop` sends), and a restart keeps its device identity.
enum ServerBinary {
    static let url: URL? = {
        var candidates: [URL] = []
        #if canImport(Darwin)
        if let xctest = Bundle.allBundles.first(where: { $0.bundlePath.hasSuffix(".xctest") }) {
            candidates.append(xctest.bundleURL.deletingLastPathComponent().appendingPathComponent("memebooru-server"))
        }
        #else
        // Linux: the tests are an executable in the products folder (Bundle.allBundles crashes there).
        candidates.append(URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("memebooru-server"))
        #endif
        candidates.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/memebooru-server"))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }()

    /// Only what the daemon needs; nothing from the developer's shell (tokens, collections) leaks in.
    static func environment(home: URL, _ extra: [String: String] = [:]) -> [String: String] {
        var env = ["PATH": "/usr/bin:/bin", "HOME": home.path, "TMPDIR": FileManager.default.temporaryDirectory.path, "MEMEBOORU_WAYBACK": "off",
                   "MEMEBOORU_STATE_DIR": home.appendingPathComponent("state").path]
        for (k, v) in extra { env[k] = v }
        return env
    }

    /// The daemon writes its stdout/stderr to files that the test polls (no pipes or reader threads).
    final class Running: @unchecked Sendable {
        let process = Process()
        private let outURL: URL, errURL: URL

        var output: String { (try? String(contentsOf: outURL, encoding: .utf8)) ?? "" }
        var errors: String { (try? String(contentsOf: errURL, encoding: .utf8)) ?? "" }

        init(_ args: [String], env: [String: String]) throws {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("mb-server-\(UUID().uuidString)")
            outURL = base.appendingPathExtension("out"); errURL = base.appendingPathExtension("err")
            FileManager.default.createFile(atPath: outURL.path, contents: nil)
            FileManager.default.createFile(atPath: errURL.path, contents: nil)
            let out = try FileHandle(forWritingTo: outURL), err = try FileHandle(forWritingTo: errURL)
            defer { try? out.close(); try? err.close() }   // the child has its own copies
            process.executableURL = ServerBinary.url
            process.arguments = args
            process.environment = env
            process.standardOutput = out; process.standardError = err
            process.standardInput = FileHandle.nullDevice
            try process.run()
        }

        deinit {
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
        }

        func terminate() {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
    }
}

@Suite(.serialized, .enabled(if: ServerBinary.url != nil, "memebooru-server is not built"))
struct ServerProcessTests {
    /// Not on Linux: there every test target shares one process, and a long-lived child started with
    /// Foundation's `Process` while the media tests spawn ffprobe / rsvg-convert by the hundred makes
    /// swift-corelibs-foundation lose some of those children's exits — their `waitUntilExit()` never
    /// returns (reproduced in the Docker gate; the suite without this test passes). The same daemon
    /// code runs in-process on Linux in `ServerRuntimeTests`.
    #if !os(Linux)
    @Test func daemonSyncsTwoDevicesStopsOnSigtermAndRestartsWithTheSameIdentity() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mb server proc \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let coll = dir.appendingPathComponent("data/Мемы.memebooru")
        let env = ServerBinary.environment(home: dir, ["MEMEBOORU_NAME": "proc-server"])

        let server = try ServerBinary.Running(["-c", coll.path, "--port", "0"], env: env)
        defer { server.terminate() }
        #expect(await eventually(.seconds(20)) { server.output.contains("sync: listening on port") }, "\(server.output)\n\(server.errors)")
        let log = server.output
        #expect(log.contains("telegram: no TELEGRAM_BOT_TOKEN — running sync only"), "\(log)")
        #expect(log.contains("device \"proc-server\""), "\(log)")
        let port = try #require(log.firstMatch(of: /listening on port (\d+); pairing code (\d{6})/).flatMap { UInt16($0.1) })
        let code1 = try #require(log.firstMatch(of: /pairing code (\d{6})/).map { String($0.1) })

        let a = try TempCollection("a"), b = try TempCollection("b")
        let fromA = Meme(kind: .text, textVerbatim: "from A"), fromB = Meme(kind: .text, textVerbatim: "from B")
        try a.collection.memes.insert(fromA, tags: ["a"])
        try b.collection.memes.insert(fromB, tags: ["b"])

        let ra = try await SyncSession(collection: a.collection, transport: try await SocketTransport.connect(host: "127.0.0.1", port: port),
                                       role: .initiator, pairingCode: code1).run()
        #expect(ra.paired && ra.peerName == "proc-server")
        #expect(await eventually { server.output.contains("sync: ✓") && server.output.contains("— paired") })
        // The code rotated after pairing: B trying the old one is refused and logged.
        let tb = try await SocketTransport.connect(host: "127.0.0.1", port: port)
        await #expect(throws: (any Error).self) {
            _ = try await SyncSession(collection: b.collection, transport: tb, role: .initiator, pairingCode: code1).run()
        }
        #expect(await eventually { server.output.contains("sync: ✗") })

        // SIGTERM (docker stop) ends it.
        server.terminate()
        #expect(server.process.terminationReason == .uncaughtSignal && server.process.terminationStatus == SIGTERM)

        // Read the replica's identity straight from disk: opening it as a `Collection` here would look
        // like another machine and mint a new device id.
        func deviceID() throws -> String {
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: coll.appendingPathComponent("device.json"))) as? [String: Any]
            return try #require(json?["id"] as? String)
        }
        let id1 = try deviceID()
        let restarted = try ServerBinary.Running(["-c", coll.path], env: ServerBinary.environment(home: dir, ["MEMEBOORU_NAME": "proc-server", "MEMEBOORU_SYNC_PORT": "0"]))
        defer { restarted.terminate() }
        #expect(await eventually(.seconds(20)) { restarted.output.contains("sync: listening on port") }, "\(restarted.output)\n\(restarted.errors)")
        let log2 = restarted.output
        #expect(log2.contains("— 1 posts"), "\(log2)")
        let port2 = try #require(log2.firstMatch(of: /listening on port (\d+)/).flatMap { UInt16($0.1) })
        let code3 = try #require(log2.firstMatch(of: /pairing code (\d{6})/).map { String($0.1) })

        // A, already paired, syncs without a code: the server is the same device after the restart.
        let ra2 = try await SyncSession(collection: a.collection, transport: try await SocketTransport.connect(host: "127.0.0.1", port: port2),
                                        role: .initiator).run()
        #expect(!ra2.paired)
        let rb = try await SyncSession(collection: b.collection, transport: try await SocketTransport.connect(host: "127.0.0.1", port: port2),
                                       role: .initiator, pairingCode: code3).run()
        #expect(rb.paired && rb.applied > 0)
        #expect(try b.collection.search.search("a").memes.map(\.id) == [fromA.id])
        let ra3 = try await SyncSession(collection: a.collection, transport: try await SocketTransport.connect(host: "127.0.0.1", port: port2),
                                        role: .initiator).run()
        #expect(ra3.applied > 0)
        #expect(try a.collection.search.search("b").memes.map(\.id) == [fromB.id])

        restarted.terminate()
        #expect(try deviceID() == id1, "the machine-id file keeps the identity across restarts")
        #expect(FileManager.default.fileExists(atPath: coll.path + ".machine-id"))
        let db = try Database(path: coll.appendingPathComponent(Collection.dbName).path)
        #expect(try db.scalarInt("SELECT count(*) FROM meme WHERE deleted_at IS NULL") == 2)
        #expect(try db.query("PRAGMA integrity_check", []) { $0.string(0) } == ["ok"])
    }
    #endif

    @Test func daemonRefusesToStartWithoutACollection() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("mb-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let p = try ServerBinary.Running([], env: ServerBinary.environment(home: home))
        p.process.waitUntilExit()
        #expect(p.process.terminationStatus == 64)
        #expect(eventuallySync { p.errors.contains("pass --collection or set MEMEBOORU_COLLECTION") }, "\(p.errors)")
    }
}

/// Blocking poll for pipe output that arrives on a reader thread.
func eventuallySync(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline { if condition() { return true }; Thread.sleep(forTimeInterval: 0.02) }
    return condition()
}
