import ArgumentParser
import Foundation
import Testing
import MemebooruCore
@testable import memebooru
#if canImport(ImageIO)
import MemebooruPlatformApple
#else
import MemebooruPlatformLinux
#endif

// Drives the `memebooru` CLI in-process, the way ArgumentParser's `main()` does, with its output,
// platform (HTTP) and x.com session folder swapped through task-local seams. Nothing here touches
// the network, the user's saved x.com session, or the real Application Support folder.

/// Thread-safe box for values touched from command callbacks.
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock(); private var v: T
    init(_ v: T) { self.v = v }
    var value: T { lock.withLock { v } }
    func mutate(_ f: (inout T) -> Void) { lock.withLock { f(&v) } }
}

struct CLIResult: CustomStringConvertible {
    let args: [String]
    let code: Int32
    let out: String
    let err: String
    var ok: Bool { code == 0 }
    var lines: [String] { out.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) }
    var description: String { "memebooru \(args.joined(separator: " ")) → \(code)\n--- stdout\n\(out)--- stderr\n\(err)" }
}

/// Any HTTP request is an error: the default for every CLI run, so a stray download fails loudly.
final class NoNetwork: HTTPClient, @unchecked Sendable {
    struct Blocked: Error, CustomStringConvertible { let url: URL; var description: String { "network blocked in tests: \(url)" } }
    let requests = Locked<[URL]>([])
    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        requests.mutate { $0.append(url) }
        throw Blocked(url: url)
    }
}

enum CLI {
    /// The real platform (ImageIO / stb, ffmpeg when installed) with the network cut off.
    static let realPlatform: Platform = {
        #if canImport(ImageIO)
        return PlatformApple.make()
        #else
        return PlatformLinux.make()
        #endif
    }()

    static func platform(http: any HTTPClient) -> Platform {
        var p = realPlatform
        p.http = http
        return p
    }

    /// Per-process sandbox for x.com session files; every run uses it unless a test passes its own.
    static let sandboxXDir: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("mb-cli-x-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// Runs `memebooru <args>` in-process. Exit code and stdout/stderr split exactly as `main()` does.
    /// `live` also receives stdout as it is written (for commands that run until cancelled).
    static func run(_ args: [String], http: (any HTTPClient)? = nil, xDir: URL? = nil, live: Locked<String>? = nil) async -> CLIResult {
        let out = Locked(""), err = Locked("")
        let code = await Host.$output.withValue({ s in out.mutate { $0 += s }; live?.mutate { $0 += s } }) {
            await Host.$errorOutput.withValue({ s in err.mutate { $0 += s } }) {
                await Host.$platformOverride.withValue(platform(http: http ?? NoNetwork())) {
                    await XSessionStore.$directoryOverride.withValue(xDir ?? sandboxXDir) {
                        await execute(args, out: out, err: err)
                    }
                }
            }
        }
        return CLIResult(args: args, code: code, out: out.value, err: err.value)
    }

    private static func execute(_ args: [String], out: Locked<String>, err: Locked<String>) async -> Int32 {
        do {
            var command = try MemebooruCLI.parseAsRoot(args)
            if var async = command as? any AsyncParsableCommand { try await async.run() } else { try command.run() }
            return ExitCode.success.rawValue
        } catch {
            let code = MemebooruCLI.exitCode(for: error)
            let message = MemebooruCLI.fullMessage(for: error)
            if !message.isEmpty {
                if code == .success { out.mutate { $0 += message + "\n" } } else { err.mutate { $0 += message + "\n" } }
            }
            return code.rawValue
        }
    }

    /// Parses only (no run): the command it resolves to, or the parse error.
    static func parse(_ args: [String]) -> Result<any ParsableCommand, Error> {
        Result { try MemebooruCLI.parseAsRoot(args) }
    }
}

/// A temp folder (name may contain spaces / unicode), removed on deinit.
final class TempDir: @unchecked Sendable {
    let url: URL
    init(_ name: String = "mb cli тест") throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name) \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    func path(_ rel: String) -> String { url.appendingPathComponent(rel).path }

    @discardableResult
    func write(_ rel: String, _ data: Data) throws -> URL {
        let u = url.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: u)
        return u
    }
}

/// A temp dir holding a fresh collection created through `memebooru init`.
final class CLICollection: @unchecked Sendable {
    let dir: TempDir
    let path: String
    var url: URL { URL(fileURLWithPath: path) }
    init(name: String = "Мемы и картинки") async throws {
        dir = try TempDir()
        let r = await CLI.run(["init", dir.path(name)])
        try #require(r.ok, "\(r)")
        path = dir.path(name + ".memebooru")
    }

    /// `memebooru <args…> -c <collection>`; `-c` goes last so `parsing: .remaining` arguments keep working
    /// when callers put it themselves.
    func run(_ args: String..., http: (any HTTPClient)? = nil) async -> CLIResult {
        await CLI.run(Self.inject(args, path), http: http)
    }
    func run(_ args: [String], http: (any HTTPClient)? = nil) async -> CLIResult {
        await CLI.run(Self.inject(args, path), http: http)
    }

    /// Puts `-c path` right after the (sub)command words, before any positional argument.
    static func inject(_ args: [String], _ path: String) -> [String] {
        var command: any ParsableCommand.Type = MemebooruCLI.self
        var i = 0
        while i < args.count, let sub = command.configuration.subcommands.first(where: { $0._commandName == args[i] }) {
            command = sub; i += 1
        }
        return Array(args[..<i]) + ["-c", path] + Array(args[i...])
    }

    func open() throws -> Collection { try Collection.open(at: url) }
}

// MARK: - Media samples

enum Samples {
    /// 64×64 grey pictures with very different perceptual hashes.
    enum Pattern: CaseIterable { case horizontal, vertical, checker, rings }

    static func bitmap(_ p: Pattern, side: Int = 64) -> Bitmap {
        var px = Data(count: side * side * 4)
        for y in 0..<side { for x in 0..<side {
            let v: UInt8
            switch p {
            case .horizontal: v = UInt8(x * 255 / (side - 1))
            case .vertical: v = UInt8(y * 255 / (side - 1))
            case .checker: v = ((x / 16) + (y / 16)) % 2 == 0 ? 0 : 255
            case .rings:
                let dx = Double(x - side / 2), dy = Double(y - side / 2)
                v = Int((dx * dx + dy * dy).squareRoot() / 6) % 2 == 0 ? 30 : 220
            }
            let i = (y * side + x) * 4
            px[i] = v; px[i + 1] = v; px[i + 2] = v; px[i + 3] = 255
        } }
        return Bitmap(width: side, height: side, rgba: px)
    }

    /// A real PNG, made by the platform's own encoder (ImageIO / stb), falling back to ffmpeg.
    static func png(_ p: Pattern) throws -> Data {
        if let d = try CLI.realPlatform.thumbs.encode(bitmap(p), as: .png, quality: 1) { return d }
        let ff = try #require(ffmpeg, "no PNG encoder and no ffmpeg")
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("mb-\(UUID().uuidString).rgba")
        let out = raw.deletingPathExtension().appendingPathExtension("png")
        defer { try? FileManager.default.removeItem(at: raw); try? FileManager.default.removeItem(at: out) }
        try bitmap(p).rgba.write(to: raw)
        try ff.runFFmpeg(["-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgba", "-s", "64x64", "-i", raw.path, out.path])
        return try Data(contentsOf: out)
    }

    static var ffmpeg: FFmpegTranscoder? { CLI.realPlatform.transcoder as? FFmpegTranscoder }
    static var h264: String? {
        guard let e = ffmpeg?.encoders else { return nil }
        return e.contains("libx264") ? "libx264" : e.contains("h264_videotoolbox") ? "h264_videotoolbox" : nil
    }

    /// A one-second 64×64 H.264 MP4 (nil without ffmpeg / an H.264 encoder).
    static func mp4() throws -> Data? {
        guard let ff = ffmpeg, let enc = h264 else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("mb-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        try ff.runFFmpeg(["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=64x64:rate=10", "-t", "1",
                          "-c:v", enc, "-pix_fmt", "yuv420p", out.path])
        return try Data(contentsOf: out)
    }
}

extension Collection {
    /// Ids a full, unpaginated search returns.
    func ids(_ query: String) throws -> [MemeID] { try search.search(query, limit: 1_000_000).memes.map(\.id) }
}

/// Polls `condition` (up to `timeout`), for state that settles on another thread.
func eventually(_ timeout: Duration = .seconds(5), _ condition: () throws -> Bool) async rethrows -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return try condition()
}
