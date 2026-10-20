#if canImport(Network)
import Foundation
import Network
import MemebooruCore

/// Length-prefixed frames over an NWConnection.
public final class NWTransport: PeerTransport, @unchecked Sendable {
    private let connection: NWConnection
    public static let maxFrame = 512 * 1024 * 1024

    public init(connection: NWConnection) { self.connection = connection }

    /// Client side: open a connection to host:port (or a Bonjour endpoint) and wait until ready.
    public static func connect(to endpoint: NWEndpoint) async throws -> NWTransport {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let conn = NWConnection(to: endpoint, using: params)
        let t = NWTransport(connection: conn)
        try await t.waitReady()
        return t
    }

    public static func connect(host: String, port: UInt16) async throws -> NWTransport {
        try await connect(to: .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!))
    }

    func waitReady() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let done = Locked(false)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: if done.take() { cont.resume() }
                case .failed(let e): if done.take() { cont.resume(throwing: e) }
                case .cancelled: if done.take() { cont.resume(throwing: SyncError("connection cancelled")) }
                case .waiting(let e): if done.take() { cont.resume(throwing: SyncError("cannot reach peer: \(e)")) }
                default: break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    public func send(_ data: Data) async throws {
        var frame = Data(capacity: data.count + 4)
        var len = UInt32(data.count).bigEndian
        withUnsafeBytes(of: &len) { frame.append(contentsOf: $0) }
        frame.append(data)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: frame, completion: .contentProcessed { e in
                if let e { cont.resume(throwing: e) } else { cont.resume() }
            })
        }
    }

    public func receive() async throws -> Data {
        let header = try await receiveExactly(4)
        let len = header.withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
        guard len <= Self.maxFrame else { throw SyncError("frame too large") }
        return len == 0 ? Data() : try await receiveExactly(len)
    }

    private func receiveExactly(_ n: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            connection.receive(minimumIncompleteLength: n, maximumLength: n) { data, _, isComplete, error in
                if let error { cont.resume(throwing: error); return }
                guard let data, data.count == n else {
                    cont.resume(throwing: SyncError(isComplete ? "peer closed" : "short read")); return
                }
                cont.resume(returning: data)
            }
        }
    }

    public func close() async { connection.cancel() }
}

/// Small lock for one-shot continuations.
final class Locked: @unchecked Sendable {
    private var v: Bool; private let lock = NSLock()
    init(_ v: Bool) { self.v = v }
    /// Returns true the first time only.
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; if v { return false }; v = true; return true }
}

/// Listens for peers (TCP + Bonjour `_memebooru._tcp`) and runs responder sessions.
public final class SyncListener: @unchecked Sendable {
    public static let serviceType = "_memebooru._tcp"

    private let collection: Collection
    private var listener: NWListener?
    private let lock = NSLock()
    private var _code = SyncAuth.randomCode()
    public var onReport: (@Sendable (Result<SyncReport, Error>) -> Void)?

    /// Pairing code to show on screen. Regenerated after each successful pairing.
    public var pairingCode: String { lock.lock(); defer { lock.unlock() }; return _code }
    public private(set) var port: UInt16 = 0
    /// Refuses pairing for a while after repeated wrong codes (6 digits must not be brute-forceable).
    public let pairingGuard = PairingGuard()

    /// Debug/testing: pin the pairing code.
    public func setCode(_ code: String) { lock.withLock { _code = code } }

    public init(collection: Collection) { self.collection = collection }

    public func start(port: UInt16 = 0, advertise: Bool = true) throws {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
        if advertise {
            l.service = NWListener.Service(name: collection.deviceName, type: Self.serviceType, txtRecord: NWTXTRecord(["id": collection.deviceID]))
        }
        l.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            Task.detached { await self.handle(conn) }
        }
        l.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let p = l.port?.rawValue { self?.port = p }
        }
        l.start(queue: .global(qos: .userInitiated))
        listener = l
    }

    public func stop() { listener?.cancel(); listener = nil }

    private func handle(_ conn: NWConnection) async {
        let transport = NWTransport(connection: conn)
        do {
            try await transport.waitReady()
            let session = SyncSession(collection: collection, transport: transport, role: .responder,
                                      acceptCode: pairingGuard.isLocked ? nil : pairingCode)
            let report = try await session.run()
            if report.paired { lock.withLock { _code = SyncAuth.randomCode() }; pairingGuard.reset() }
            onReport?(.success(report))
        } catch {
            if error is WrongPairingCode { pairingGuard.recordFailure() }
            onReport?(.failure(error))
        }
    }
}

/// Discovers other Memebooru instances on the local network.
public final class PeerBrowser: @unchecked Sendable {
    public struct Found: Sendable, Hashable, Identifiable {
        public let name: String
        public let endpoint: NWEndpoint
        public var id: String { name }
    }
    private var browser: NWBrowser?
    private let lock = NSLock()
    private var _found: [Found] = []
    public var onChange: (@Sendable ([Found]) -> Void)?
    public var found: [Found] { lock.lock(); defer { lock.unlock() }; return _found }

    public init() {}

    public func start() {
        let params = NWParameters()
        params.includePeerToPeer = true
        let b = NWBrowser(for: .bonjour(type: SyncListener.serviceType, domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            let list = results.compactMap { r -> Found? in
                if case .service(let name, _, _, _) = r.endpoint { return Found(name: name, endpoint: r.endpoint) }
                return nil
            }.sorted { $0.name < $1.name }
            lock.lock(); _found = list; lock.unlock()
            onChange?(list)
        }
        b.start(queue: .global(qos: .utility))
        browser = b
    }

    public func stop() { browser?.cancel(); browser = nil }
}

public enum NetworkSync {
    /// Initiate a sync with a peer; `code` pairs with a new device.
    public static func sync(_ collection: Collection, to endpoint: NWEndpoint, code: String? = nil) async throws -> SyncReport {
        let transport = try await NWTransport.connect(to: endpoint)
        return try await SyncSession(collection: collection, transport: transport, role: .initiator, pairingCode: code).run()
    }
    public static func sync(_ collection: Collection, host: String, port: UInt16, code: String? = nil) async throws -> SyncReport {
        try await sync(collection, to: .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!), code: code)
    }
}
#endif
