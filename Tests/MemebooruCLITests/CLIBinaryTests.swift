import Foundation
import Testing

/// The built `memebooru` executable as a real process: exit codes and stdout/stderr as a shell sees them.
/// Only invocations that never open a collection or the x.com session, so the user's settings stay untouched.
enum Binary {
    /// `.build/<config>/` — next to the test bundle (macOS) or test executable (Linux).
    static let productsDir: URL? = {
        #if canImport(Darwin)
        if let xctest = Bundle.allBundles.first(where: { $0.bundlePath.hasSuffix(".xctest") }) {
            return xctest.bundleURL.deletingLastPathComponent()
        }
        return Bundle.main.bundleURL
        #else
        // Linux: the tests are an executable in the products folder (Bundle.allBundles crashes there).
        return URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        #endif
    }()

    static func url(_ name: String) -> URL? {
        let candidates = [productsDir?.appendingPathComponent(name),
                          URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                            .appendingPathComponent(".build/debug/\(name)")].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// A minimal environment: no MEMEBOORU_*, X_*, TELEGRAM_* leaking in from the developer's shell.
    static func cleanEnvironment(home: URL) -> [String: String] {
        // MEMEBOORU_STATE_DIR: the machine id goes in the throwaway home, never the real one.
        ["PATH": "/usr/bin:/bin", "HOME": home.path, "TMPDIR": FileManager.default.temporaryDirectory.path, "LANG": "en_US.UTF-8",
         "MEMEBOORU_STATE_DIR": home.appendingPathComponent("state").path]
    }

    struct Output { let code: Int32; let out: String; let err: String }

    static func run(_ name: String, _ args: [String]) throws -> Output {
        let exe = try #require(url(name), "\(name) not built")
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("mb-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.environment = cleanEnvironment(home: home)
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile(), e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Output(code: p.terminationStatus, out: String(decoding: o, as: UTF8.self), err: String(decoding: e, as: UTF8.self))
    }
}

@Suite(.enabled(if: Binary.url("memebooru") != nil, "the memebooru executable is not built"))
struct CLIBinaryTests {
    @Test func versionAndHelp() throws {
        let v = try Binary.run("memebooru", ["--version"])
        #expect(v.code == 0 && v.out == "0.0.1\n" && v.err.isEmpty, "\(v)")
        let h = try Binary.run("memebooru", ["--help"])
        #expect(h.code == 0 && h.out.contains("USAGE: memebooru <subcommand>") && h.out.contains("SUBCOMMANDS:"), "\(h)")
        for path in [["stage", "commit"], ["import", "likes"], ["x", "login"], ["sync", "connect"], ["search"]] {
            let r = try Binary.run("memebooru", path + ["--help"])
            #expect(r.code == 0 && r.out.contains("USAGE: memebooru \(path.joined(separator: " "))"), "\(path): \(r)")
        }
    }

    @Test func usageErrorsExit64OnStderr() throws {
        for args in [["frobnicate"], ["init"], ["search", "--limit", "x"], ["tag", "kind", "a", "bogus"], ["sync", "listen", "--port", "70000"]] {
            let r = try Binary.run("memebooru", args)
            #expect(r.code == 64 && r.out.isEmpty && r.err.hasPrefix("Error: "), "\(args): \(r)")
        }
    }

    @Test func missingCollectionMessages() throws {
        let r = try Binary.run("memebooru", ["info"])
        #expect(r.code == 64 && r.err.contains("pass --collection or set MEMEBOORU_COLLECTION"), "\(r)")
        let gone = FileManager.default.temporaryDirectory.appendingPathComponent("no such dir \(UUID().uuidString)/Мемы.memebooru").path
        let r2 = try Binary.run("memebooru", ["info", "-c", gone])
        #expect(r2.code == 1 && r2.err.contains("Error: no collection at \(gone)"), "\(r2)")
        // The search example from the help parses (and then fails only on the missing collection).
        let r3 = try Binary.run("memebooru", ["search", "-c", gone, "2022", "stalin", "-ussr", "обед"])
        #expect(r3.code == 1 && r3.err.contains("no collection at"), "\(r3)")
    }
}
