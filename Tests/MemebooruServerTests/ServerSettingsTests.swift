import ArgumentParser
import Foundation
import Testing
@testable import memebooru_server

/// Options + environment → `ServerSettings`, exactly as the daemon resolves them (Docker passes env).
/// Tokens here are made-up strings; nothing contacts Telegram.
@Suite struct ServerSettingsTests {
    static let fakeToken = "000000:TEST-not-a-real-token"

    private func server(_ args: [String]) throws -> Server {
        let cmd = try Server.parseAsRoot(args)
        return try #require(cmd as? Server)
    }
    private func settings(_ args: [String], env: [String: String] = [:]) throws -> ServerSettings {
        try server(args).settings(env: env)
    }

    @Test func defaults() throws {
        let s = try settings(["-c", "/data/Мемы.memebooru"])
        #expect(s == ServerSettings(collectionPath: "/data/Мемы.memebooru", syncPort: 7300, deviceName: "memebooru-server",
                                    wayback: true, botToken: nil, allowedUsers: [], cacheChat: nil,
                                    apiBase: URL(string: "https://api.telegram.org")!, warm: false))
    }

    @Test func missingCollectionIsAValidationError() throws {
        #expect(throws: ValidationError.self) { try self.settings([]) }
        do { _ = try settings([]) } catch {
            #expect(Server.exitCode(for: error) == .validationFailure)
            #expect(Server.fullMessage(for: error).contains("pass --collection or set MEMEBOORU_COLLECTION"))
        }
        #expect(try settings([], env: ["MEMEBOORU_COLLECTION": "/srv/a b.memebooru"]).collectionPath == "/srv/a b.memebooru")
    }

    @Test func optionsWinOverEnvironment() throws {
        let env = ["MEMEBOORU_COLLECTION": "/env", "MEMEBOORU_SYNC_PORT": "7400", "MEMEBOORU_NAME": "env-name",
                   "TELEGRAM_BOT_TOKEN": "env-token", "TELEGRAM_ALLOWED_USERS": "1", "TELEGRAM_CACHE_CHAT": "-100"]
        let s = try settings(["--collection", "/opt", "--port", "7500", "--name", "Сервер", "--bot-token", Self.fakeToken,
                              "--allow", "2,3", "--cache-chat", "-200", "--warm"], env: env)
        #expect(s.collectionPath == "/opt" && s.syncPort == 7500 && s.deviceName == "Сервер")
        #expect(s.botToken == Self.fakeToken && s.allowedUsers == [2, 3] && s.cacheChat == -200 && s.warm)

        let e = try settings([], env: env)
        #expect(e.collectionPath == "/env" && e.syncPort == 7400 && e.deviceName == "env-name")
        #expect(e.botToken == "env-token" && e.allowedUsers == [1] && e.cacheChat == -100 && !e.warm)
    }

    @Test func emptyOrMissingTokenMeansSyncOnly() throws {
        #expect(try settings(["-c", "c"]).botToken == nil)
        #expect(try settings(["-c", "c"], env: ["TELEGRAM_BOT_TOKEN": ""]).botToken == nil)
        #expect(try settings(["-c", "c", "--bot-token", ""]).botToken == nil)
        // An explicit empty option still beats the environment (the operator turned the bot off).
        #expect(try settings(["-c", "c", "--bot-token", ""], env: ["TELEGRAM_BOT_TOKEN": Self.fakeToken]).botToken == nil)
    }

    @Test(arguments: [
        ("1,2,3", [1, 2, 3]),
        ("1, 2 ,3", [1, 2, 3]),
        ("1 2  3", [1, 2, 3]),
        ("42,,42", [42]),
        ("abc, 7, -5, 9999999999999999999999", [7, -5]),   // junk and overflow ignored
        ("", []),
        (" , ", []),
    ] as [(String, Set<Int64>)])
    func allowedUsersParsing(_ raw: String, _ expected: Set<Int64>) throws {
        #expect(try settings(["-c", "c", "--allow", raw]).allowedUsers == expected)
        #expect(try settings(["-c", "c"], env: ["TELEGRAM_ALLOWED_USERS": raw]).allowedUsers == expected)
    }

    @Test func badEnvironmentNumbersFallBackToDefaults() throws {
        let s = try settings(["-c", "c"], env: ["MEMEBOORU_SYNC_PORT": "seventy", "TELEGRAM_CACHE_CHAT": "chan"])
        #expect(s.syncPort == 7300 && s.cacheChat == nil)
        #expect(try settings(["-c", "c"], env: ["MEMEBOORU_SYNC_PORT": "70000"]).syncPort == 7300)
        #expect(try settings(["-c", "c"], env: ["MEMEBOORU_SYNC_PORT": "0"]).syncPort == 0)   // 0 = any free port
    }

    @Test(arguments: [("off", false), ("OFF", false), ("Off", false), ("on", true), ("no", true), ("", true)])
    func waybackSwitch(_ value: String, _ enabled: Bool) throws {
        #expect(try settings(["-c", "c"], env: ["MEMEBOORU_WAYBACK": value]).wayback == enabled)
    }

    @Test func apiBaseFromEnvironment() throws {
        let s = try settings(["-c", "c"], env: ["TELEGRAM_API_BASE": "http://127.0.0.1:8081"])
        #expect(s.apiBase == URL(string: "http://127.0.0.1:8081")!)
        #expect(try settings(["-c", "c"]).apiBase.host == "api.telegram.org")
    }

    @Test(arguments: [
        ["--port", "70000"], ["--port", "-1"], ["--port", "port"], ["--cache-chat", "chan"], ["--bogus"],
        ["--collection"], ["extra-positional"], ["--warm=yes"],
    ])
    func badOptionsAreUsageErrors(_ args: [String]) {
        do { _ = try Server.parseAsRoot(args); Issue.record("\(args) parsed") }
        catch { #expect(Server.exitCode(for: error) == .validationFailure, "\(args): \(Server.fullMessage(for: error))") }
    }

    /// Telegram channel ids are negative: `--cache-chat -100…` must not be read as an option name.
    @Test func negativeCacheChatID() throws {
        #expect(try settings(["-c", "c", "--cache-chat", "-1001234567890"]).cacheChat == -1_001_234_567_890)
        #expect(try settings(["--cache-chat", "-5", "-c", "c"]).cacheChat == -5)
        #expect(try settings(["-c", "c", "--cache-chat=-7"]).cacheChat == -7)
    }

    @Test func helpAndUnicodePaths() throws {
        // `--help` parses to ArgumentParser's help command, whose run() ends with the help text.
        do { var cmd = try Server.parseAsRoot(["--help"]); try cmd.run(); Issue.record("--help ran") }
        catch {
            #expect(Server.exitCode(for: error) == .success)
            let help = Server.fullMessage(for: error)
            #expect(help.contains("USAGE: memebooru-server") && help.contains("TELEGRAM_BOT_TOKEN") && help.contains("--warm"))
        }
        #expect(try settings(["-c", "/data/мои мемы 🐸.memebooru"]).collectionPath == "/data/мои мемы 🐸.memebooru")
    }

    // MARK: machine id

    @Test func machineIDIsStableAndLivesBesideTheCollection() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mb server тест \(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let coll = dir.appendingPathComponent("nested dir/Мемы.memebooru")
        let a = try Server.machineID(nextTo: coll)
        let b = try Server.machineID(nextTo: coll)
        #expect(a == b && UUID(uuidString: a) != nil)
        let file = dir.appendingPathComponent("nested dir/Мемы.memebooru.machine-id")
        #expect(try String(contentsOf: file, encoding: .utf8) == a)
        // Hand-edited file with whitespace is trimmed; an empty one is replaced.
        try "  fixed-id \n".write(to: file, atomically: true, encoding: .utf8)
        #expect(try Server.machineID(nextTo: coll) == "fixed-id")
        try "".write(to: file, atomically: true, encoding: .utf8)
        let c = try Server.machineID(nextTo: coll)
        #expect(!c.isEmpty && c != "fixed-id")
        // A different collection gets its own id.
        #expect(try Server.machineID(nextTo: dir.appendingPathComponent("other.memebooru")) != c)
    }
}
