import ArgumentParser
import Foundation
import MemebooruBot
import MemebooruCore
import MemebooruNet
#if canImport(ImageIO)
import MemebooruPlatformApple
#endif
#if os(Linux)
import MemebooruPlatformLinux
#endif

/// The VPS daemon: keeps a full replica of the collection, lets your devices sync with it over the
/// internet (encrypted, paired), and runs the Telegram bot on top of the same replica.
/// Every option can come from the environment, which is how Docker passes it.
@main
struct Server: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "memebooru-server",
        abstract: "Memebooru sync server + Telegram bot.",
        discussion: """
            Environment: MEMEBOORU_COLLECTION, MEMEBOORU_SYNC_PORT, MEMEBOORU_NAME,
            TELEGRAM_BOT_TOKEN, TELEGRAM_ALLOWED_USERS (comma-separated ids), TELEGRAM_CACHE_CHAT,
            TELEGRAM_API_BASE (self-hosted Bot API server; default https://api.telegram.org),
            MEMEBOORU_WAYBACK=off (don't archive saved tweets on the Wayback Machine).
            """)

    @Option(name: [.customShort("c"), .long], help: "Collection folder; created if missing.")
    var collection: String?
    @Option(name: .long, help: "TCP port for device sync (default 7300).")
    var port: UInt16?
    @Option(name: .long, help: "Name shown to paired devices (default: memebooru-server).")
    var name: String?
    @Option(name: .long, help: "Telegram bot token from @BotFather. Omit to run sync only.")
    var botToken: String?
    @Option(name: .long, help: "Telegram user ids allowed to use the bot, comma-separated.")
    var allow: String?
    // `.unconditional`: channel ids are negative (-100…), which would otherwise parse as an option name.
    @Option(name: .long, parsing: .unconditional, help: "Chat id the bot uploads files to for inline file_ids (a private channel).")
    var cacheChat: Int64?
    @Flag(name: .long, help: "Upload every not-yet-cached file to Telegram on start, so inline answers are instant.")
    var warm = false

    func run() async throws {
        let settings = try settings(env: ProcessInfo.processInfo.environment)
        let url = URL(fileURLWithPath: settings.collectionPath)
        Collection.machineIDOverride = try Self.machineID(nextTo: url)
        let c = try Collection.openOrCreate(at: url)
        if c.deviceName != settings.deviceName { try c.renameDevice(settings.deviceName) }
        #if os(Linux)
        signal(SIGPIPE, SIG_IGN)
        #endif
        let runtime = try ServerRuntime.start(settings, collection: c, platform: Self.platform())
        await runtime.serve()
    }

    /// Options first, then the environment, then defaults.
    func settings(env: [String: String]) throws -> ServerSettings {
        guard let path = collection ?? env["MEMEBOORU_COLLECTION"] else {
            throw ValidationError("pass --collection or set MEMEBOORU_COLLECTION")
        }
        let token = botToken ?? env["TELEGRAM_BOT_TOKEN"]
        return ServerSettings(
            collectionPath: path,
            syncPort: port ?? env["MEMEBOORU_SYNC_PORT"].flatMap(UInt16.init) ?? 7300,
            deviceName: name ?? env["MEMEBOORU_NAME"] ?? "memebooru-server",
            wayback: (env["MEMEBOORU_WAYBACK"] ?? "on").lowercased() != "off",
            botToken: token?.isEmpty == false ? token : nil,
            allowedUsers: Set((allow ?? env["TELEGRAM_ALLOWED_USERS"] ?? "")
                .split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Int64($0) }),
            cacheChat: cacheChat ?? env["TELEGRAM_CACHE_CHAT"].flatMap(Int64.init),
            // TELEGRAM_API_BASE: a self-hosted Bot API server (lifts the 20 MB download limit), or a test double.
            apiBase: env["TELEGRAM_API_BASE"].flatMap(URL.init(string:)) ?? URL(string: "https://api.telegram.org")!,
            warm: warm)
    }

    /// Stable identity of this server, kept beside the collection on the data volume
    /// (`<collection>.machine-id`), so restarts and image rebuilds keep the same device id.
    static func machineID(nextTo collection: URL) throws -> String {
        let file = collection.deletingLastPathComponent().appendingPathComponent(collection.lastPathComponent + ".machine-id")
        if let s = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { return s }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased()
        try id.write(to: file, atomically: true, encoding: .utf8)
        return id
    }

    static func platform() -> Platform {
        #if canImport(ImageIO)
        return PlatformApple.make()
        #else
        return PlatformLinux.make()
        #endif
    }

    static func log(_ s: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        // Unbuffered write: docker logs must show lines immediately (and Glibc's `stdout` isn't concurrency-safe).
        FileHandle.standardOutput.write(Data("\(ts) \(s)\n".utf8))
    }
}

/// Everything the server runs with, resolved from options + environment.
struct ServerSettings: Sendable, Equatable {
    var collectionPath: String
    var syncPort: UInt16
    var deviceName: String
    var wayback: Bool
    /// nil (unset or empty) = sync only, no bot.
    var botToken: String?
    var allowedUsers: Set<Int64>
    var cacheChat: Int64?
    var apiBase: URL
    var warm: Bool
}

/// The running parts of the server over one open collection: sync listener, Wayback worker, and the
/// Telegram bot when a token is set. `start` brings them up; `serve` blocks (bot polling, or idling for
/// sync only) until its task is cancelled; `stop` shuts the listener and worker down.
final class ServerRuntime: @unchecked Sendable {
    let collection: Collection
    let sync: SyncServer
    let wayback: WaybackWorker
    let bot: MemeBot?
    private let warm: Bool
    private let log: @Sendable (String) -> Void

    private init(collection: Collection, sync: SyncServer, wayback: WaybackWorker, bot: MemeBot?, warm: Bool,
                 log: @escaping @Sendable (String) -> Void) {
        self.collection = collection; self.sync = sync; self.wayback = wayback; self.bot = bot; self.warm = warm; self.log = log
    }

    static func start(_ s: ServerSettings, collection c: Collection, platform: Platform,
                      telegram: (_ token: String, _ base: URL) -> any TelegramAPI = { HTTPTelegramAPI(token: $0, base: $1) },
                      log: @escaping @Sendable (String) -> Void = Server.log) throws -> ServerRuntime {
        // Sync
        let sync = SyncServer(collection: c)
        sync.onEvent = { line in log("sync: \(line)") }
        try sync.start(port: s.syncPort)
        log("collection \(c.url.path) — \((try? c.memes.count()) ?? 0) posts, device \"\(c.deviceName)\"")
        log("sync: listening on port \(sync.port); pairing code \(sync.pairingCode) (also /code in the bot)")

        // Wayback: snapshots for tweets saved here (the bot's links), same queue and worker as the app.
        let wayback = WaybackWorker(collection: c, http: platform.http)
        if s.wayback {
            wayback.onJob = { id, link in log("wayback: \(id) " + (link ?? "failed, will retry")) }
            wayback.start()
            let pending = (try? c.wayback.pendingCount()) ?? 0
            if pending > 0 { log("wayback: \(pending) tweet(s) queued") }
        }

        // Bot
        guard let token = s.botToken else {
            log("telegram: no TELEGRAM_BOT_TOKEN — running sync only")
            return ServerRuntime(collection: c, sync: sync, wayback: wayback, bot: nil, warm: false, log: log)
        }
        if s.allowedUsers.isEmpty {
            log("telegram: TELEGRAM_ALLOWED_USERS is empty — the bot will answer nobody. Message it once; it replies with your id.")
        }
        let config = BotConfig(allowedUsers: s.allowedUsers, cacheChat: s.cacheChat)
        let bot = MemeBot(api: telegram(token, s.apiBase), collection: c, analyzer: MediaAnalyzer(platform: platform),
                          config: config, tweetSource: FxTwitterSource(http: platform.http), pairingInfo: { [sync] in "\(sync.pairingCode) (port \(sync.port))" })
        bot.log = log
        log("telegram: bot running for \(s.allowedUsers.count) user(s)")
        return ServerRuntime(collection: c, sync: sync, wayback: wayback, bot: bot, warm: s.warm, log: log)
    }

    /// Runs until the calling task is cancelled (in the daemon: forever).
    func serve() async {
        guard let bot else {
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
            return
        }
        if warm {
            let log = self.log
            Task.detached { let n = await bot.warmCache(); log("telegram: warmed \(n) file(s)") }
        }
        await bot.run()
    }

    func stop() {
        sync.stop()
        wayback.stop()
    }
}
