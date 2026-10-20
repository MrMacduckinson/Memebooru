import ArgumentParser
import Foundation
import MemebooruCore
import MemebooruNet
#if canImport(Network)
import Network
import MemebooruPlatformApple
#endif

struct Sync: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Synchronise with other devices.",
                                                    subcommands: [Listen.self, Connect.self, Peers.self, Discover.self, Forget.self])

    struct Listen: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Wait for peers (prints the pairing code). Ctrl-C to stop.")
        @OptionGroup var collection: CollectionOption
        @Option(name: .shortAndLong) var port: UInt16 = 0
        @Flag(name: .long, help: "Don't advertise via Bonjour.") var noBonjour = false
        func run() async throws {
            #if canImport(Network)
            let c = try collection.open()
            let say = Host.printer()
            let listener = SyncListener(collection: c)
            listener.onReport = { r in
                switch r {
                case .success(let rep): say("✓ \(rep.peerName): received \(rep.received) ops (\(rep.applied) new), sent \(rep.sent); media ↓\(rep.mediaReceived) ↑\(rep.mediaSent)\(rep.paired ? "  [paired]" : "")")
                case .failure(let e): say("✗ \(e)")
                }
                say("pairing code: \(listener.pairingCode)")
            }
            try listener.start(port: port, advertise: !noBonjour)
            defer { listener.stop() }
            try await Task.sleep(for: .milliseconds(300))
            say("listening on port \(listener.port) as \"\(c.deviceName)\"\npairing code: \(listener.pairingCode)")
            while true { try await Task.sleep(for: .seconds(3600)) }
            #else
            let c = try collection.open()
            let server = SyncServer(collection: c)
            let say = Host.printer()
            server.onEvent = { line in say(line); say("pairing code: \(server.pairingCode)") }
            try server.start(port: port == 0 ? 7300 : port)
            defer { server.stop() }
            say("listening on port \(server.port) as \"\(c.deviceName)\"\npairing code: \(server.pairingCode)")
            while true { try await Task.sleep(for: .seconds(3600)) }
            #endif
        }
    }

    struct Connect: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Sync with host:port or a Bonjour name. Add --code to pair.")
        @OptionGroup var collection: CollectionOption
        @Argument(help: "host:port, or the device name shown by `sync discover`") var target: String
        @Option(name: .long, help: "Pairing code shown on the other device.") var code: String?
        func run() async throws {
            #if canImport(Network)
            let c = try collection.open()
            let endpoint: NWEndpoint
            if let colon = target.lastIndex(of: ":"), let port = UInt16(target[target.index(after: colon)...]) {
                endpoint = .hostPort(host: NWEndpoint.Host(String(target[..<colon])), port: NWEndpoint.Port(rawValue: port)!)
            } else {
                let browser = PeerBrowser(); browser.start()
                var found: PeerBrowser.Found?
                for _ in 0..<20 { try await Task.sleep(for: .milliseconds(250)); if let f = browser.found.first(where: { $0.name == target }) { found = f; break } }
                browser.stop()
                guard let f = found else { throw ValidationError("no device named \(target) found") }
                endpoint = f.endpoint
            }
            let r = try await NetworkSync.sync(c, to: endpoint, code: code)
            print("✓ \(r.peerName): received \(r.received) ops (\(r.applied) new), sent \(r.sent); media ↓\(r.mediaReceived) ↑\(r.mediaSent)\(r.paired ? "  [paired]" : "")")
            #else
            guard let colon = target.lastIndex(of: ":"), let port = UInt16(target[target.index(after: colon)...]) else {
                throw ValidationError("use host:port (Bonjour names need Apple's Network framework)")
            }
            let c = try collection.open()
            let t = try await SocketTransport.connect(host: String(target[..<colon]), port: port)
            let r = try await SyncSession(collection: c, transport: t, role: .initiator, pairingCode: code).run()
            print("✓ \(r.peerName): received \(r.received) ops (\(r.applied) new), sent \(r.sent); media ↓\(r.mediaReceived) ↑\(r.mediaSent)\(r.paired ? "  [paired]" : "")")
            #endif
        }
    }

    struct Peers: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Paired devices.")
        @OptionGroup var collection: CollectionOption
        func run() throws {
            for p in try collection.open().peers.all() {
                let last = p.lastSync.map { Date(timeIntervalSince1970: Double($0) / 1000).formatted() } ?? "never"
                print("\(p.name)  [\(p.id)]  last sync: \(last)")
            }
        }
    }

    struct Discover: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List Memebooru devices on the local network.")
        func run() async throws {
            #if canImport(Network)
            let browser = PeerBrowser(); browser.start()
            try await Task.sleep(for: .seconds(2))
            for f in browser.found { print(f.name) }
            if browser.found.isEmpty { print("nothing found") }
            browser.stop()
            #endif
        }
    }

    struct Forget: ParsableCommand {
        @OptionGroup var collection: CollectionOption
        @Argument var deviceID: String
        func run() throws { try collection.open().peers.forget(id: deviceID); print("forgotten") }
    }
}
