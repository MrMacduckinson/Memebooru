import Foundation
import Network
import Observation
import MemebooruCore
import MemebooruPlatformApple

/// Listener + discovery + sync actions for the open collection.
@Observable @MainActor
final class SyncController {
    private(set) var listener: SyncListener?
    private let browser = PeerBrowser()
    private(set) var nearby: [PeerBrowser.Found] = []
    private(set) var paired: [PeerRegistry.Peer] = []
    private(set) var pairingCode = ""
    private(set) var port: UInt16 = 0
    private(set) var busyWith: String?
    private(set) var log: [String] = []
    private var collection: Collection?
    private var deviceName = ""

    func attach(_ c: Collection) {
        detach()
        collection = c
        deviceName = c.deviceName
        let l = SyncListener(collection: c)
        l.onReport = { [weak self] r in
            Task { @MainActor in
                guard let self else { return }
                switch r {
                case .success(let rep): self.note("↔ \(rep.peerName): \(rep.received) получено / \(rep.sent) отправлено, медиа ↓\(rep.mediaReceived) ↑\(rep.mediaSent)\(rep.paired ? " — подключено" : "")")
                case .failure(let e): self.note("✗ \(e)")
                }
                self.refresh()
            }
        }
        do { try l.start(); listener = l } catch { note("listener failed: \(error)") }
        browser.onChange = { [weak self] found in
            Task { @MainActor in self?.nearby = found.filter { $0.name != self?.deviceName } }
        }
        browser.start()
        Task { try? await Task.sleep(for: .milliseconds(400)); refresh() }
    }

    func detach() {
        listener?.stop(); listener = nil
        browser.stop()
        nearby = []; paired = []
    }

    func refresh() {
        pairingCode = listener?.pairingCode ?? ""
        port = listener?.port ?? 0
        paired = (try? collection?.peers.all()) ?? []
    }

    /// Sync with a discovered device; `code` pairs a new one.
    func sync(with found: PeerBrowser.Found, code: String?, then done: @escaping @MainActor () -> Void) {
        guard let c = collection else { return }
        busyWith = found.name
        let ep = found.endpoint
        Task.detached {
            let result = await Result { try await NetworkSync.sync(c, to: ep, code: code?.isEmpty == true ? nil : code) }
            await MainActor.run {
                switch result {
                case .success(let r):
                    try? c.peers.setEndpoint(id: r.peerID, "bonjour:\(found.name)")
                    self.note("↔ \(r.peerName): \(r.received) получено / \(r.sent) отправлено, медиа ↓\(r.mediaReceived) ↑\(r.mediaSent)\(r.paired ? " — подключено" : "")")
                case .failure(let e): self.note("✗ \(found.name): \(e)")
                }
                self.busyWith = nil; self.refresh(); done()
            }
        }
    }

    /// Sync with a paired device: via its Bonjour name if it is nearby, else its stored host:port.
    func sync(peer: PeerRegistry.Peer, then done: @escaping @MainActor () -> Void) {
        if let f = nearby.first(where: { $0.name == peer.name }) { sync(with: f, code: nil, then: done); return }
        if let ep = peer.endpoint, ep.hasPrefix("tcp:"), let (host, port) = Self.hostPort(String(ep.dropFirst(4))) {
            sync(host: host, port: port, code: nil, then: done); return
        }
        note("✗ \(peer.name) недоступно: устройство не рядом, адрес не указан")
    }

    func sync(host: String, port: UInt16, code: String?, then done: @escaping @MainActor () -> Void) {
        guard let c = collection else { return }
        busyWith = "\(host):\(port)"
        Task.detached {
            let result = await Result { try await NetworkSync.sync(c, host: host, port: port, code: code?.isEmpty == true ? nil : code) }
            await MainActor.run {
                switch result {
                case .success(let r):
                    try? c.peers.setEndpoint(id: r.peerID, "tcp:\(host):\(port)")
                    self.note("↔ \(r.peerName): \(r.received) получено / \(r.sent) отправлено, медиа ↓\(r.mediaReceived) ↑\(r.mediaSent)\(r.paired ? " — подключено" : "")")
                case .failure(let e): self.note("✗ \(host):\(port): \(e)")
                }
                self.busyWith = nil; self.refresh(); done()
            }
        }
    }

    func forget(_ peer: PeerRegistry.Peer) { try? collection?.peers.forget(id: peer.id); refresh() }

    static func hostPort(_ s: String) -> (String, UInt16)? {
        guard let colon = s.lastIndex(of: ":"), let port = UInt16(s[s.index(after: colon)...]) else { return nil }
        return (String(s[..<colon]), port)
    }

    private func note(_ s: String) {
        log.insert("\(Date().formatted(date: .omitted, time: .shortened))  \(s)", at: 0)
        if log.count > 50 { log.removeLast() }
    }
}

extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
