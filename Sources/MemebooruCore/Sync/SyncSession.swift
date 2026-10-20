import Foundation

/// One synchronisation run between this collection and a peer.
/// Initiator drives; responder answers. Steps: hello/auth → ops both ways → media both ways → done.
public final class SyncSession: @unchecked Sendable {
    public enum Role: Sendable { case initiator, responder }

    private let collection: Collection
    private let transport: any PeerTransport
    /// `transport` until the hellos are exchanged, then the encrypted channel on top of it.
    private var channel: any PeerTransport
    private let role: Role
    /// Secret for an already paired peer; nil to attempt pairing with `pairingCode`.
    private let secret: String?
    private let pairingCode: String?
    /// Responder: code shown on screen right now; a `pair` message must match it.
    private let acceptCode: String?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(collection: Collection, transport: any PeerTransport, role: Role,
                secret: String? = nil, pairingCode: String? = nil, acceptCode: String? = nil) {
        self.collection = collection; self.transport = transport; self.channel = transport; self.role = role
        self.secret = secret; self.pairingCode = pairingCode; self.acceptCode = acceptCode
    }

    // MARK: - Framing

    private func send(_ m: SyncMessage) async throws { try await channel.send(try encoder.encode(m)) }
    private func receive() async throws -> SyncMessage {
        let data = try await channel.receive()
        return try decoder.decode(SyncMessage.self, from: data)
    }

    // MARK: - Run

    public func run() async throws -> SyncReport {
        var report = SyncReport()
        defer { Task { await transport.close() } }

        // 1. hello (clear) → key agreement → everything else encrypted
        let myNonce = SyncAuth.randomSecret()
        let myVector = try collection.oplog.vector()
        let handshake = SecureChannel.Handshake()
        let myHello = try encoder.encode(SyncMessage.hello(deviceID: collection.deviceID, name: collection.deviceName, vector: myVector,
                                                           nonce: myNonce, key: handshake.publicKeyBase64, version: SyncProtocol.version))
        try await transport.send(myHello)
        let peerHello = try await transport.receive()
        guard let hello = try? decoder.decode(SyncMessage.self, from: peerHello),
              case .hello(let peerID, let peerName, let peerVector, let peerNonce, let peerKey, let peerVersion) = hello else {
            throw SyncError("peer speaks an older sync protocol — update Memebooru on both devices")
        }
        guard peerVersion == SyncProtocol.version else { throw SyncError("peer uses sync protocol v\(peerVersion), this is v\(SyncProtocol.version)") }
        report.peerID = peerID; report.peerName = peerName
        let secure = try SecureChannel(over: transport, handshake: handshake, peerPublicKeyBase64: peerKey,
                                       isInitiator: role == .initiator,
                                       initiatorHello: role == .initiator ? myHello : peerHello,
                                       responderHello: role == .initiator ? peerHello : myHello)
        channel = secure
        let transcript = secure.transcript

        // 2. auth or pairing
        let storedSecret: String? = if let secret { secret } else { try collection.peers.secret(for: peerID) }
        var sessionSecret = storedSecret
        switch role {
        case .initiator:
            if let s = storedSecret {
                try await send(.auth(hmac: SyncAuth.hmac(secret: s, nonce: peerNonce, transcript: transcript)))
            } else if let code = pairingCode {
                try await send(.pair(code: code))
            } else { throw SyncError("not paired with \(peerName) — pair first") }
            switch try await receive() {
            case .auth(let h):
                guard let s = sessionSecret, h == SyncAuth.hmac(secret: s, nonce: myNonce, transcript: transcript) else { throw SyncError("peer failed authentication") }
            case .paired(let s):
                sessionSecret = s; report.paired = true
            case .reject(let why): throw SyncError("peer rejected: \(why)")
            default: throw SyncError("unexpected reply to auth")
            }
        case .responder:
            switch try await receive() {
            case .auth(let h):
                guard let s = storedSecret, h == SyncAuth.hmac(secret: s, nonce: myNonce, transcript: transcript) else {
                    try await send(.reject(reason: "unknown device or bad secret")); throw SyncError("initiator failed authentication")
                }
                try await send(.auth(hmac: SyncAuth.hmac(secret: s, nonce: peerNonce, transcript: transcript)))
            case .pair(let code):
                guard let expected = acceptCode else {
                    try await send(.reject(reason: "pairing is closed on this device — try again later")); throw SyncError("pairing closed")
                }
                guard code == expected else {
                    try await send(.reject(reason: "wrong pairing code")); throw WrongPairingCode(peerName: peerName)
                }
                let s = SyncAuth.randomSecret(); sessionSecret = s; report.paired = true
                try await send(.paired(secret: s))
            case .reject(let why): throw SyncError("peer rejected: \(why)")
            default: throw SyncError("expected auth")
            }
        }
        // Never record ourselves as a peer (loopback / self-sync would otherwise pile up junk rows).
        if let s = sessionSecret, peerID != collection.deviceID {
            try collection.peers.upsert(id: peerID, name: peerName, secret: s)
        }

        // 3. ops: initiator sends first, then responder
        let applier = OpApplier(collection: collection)
        func sendOps() async throws {
            let ops = try collection.oplog.ops(missingFrom: peerVector, limit: Int.max)
            for chunk in stride(from: 0, to: ops.count, by: 500).map({ Array(ops[$0..<min($0 + 500, ops.count)]) }) {
                try await send(.ops(chunk)); report.sent += chunk.count
            }
            try await send(.opsDone)
        }
        func receiveOps() async throws {
            while true {
                switch try await receive() {
                case .ops(let ops):
                    let r = try applier.apply(ops); report.received += ops.count; report.applied += r.applied
                case .opsDone: return
                case .reject(let why): throw SyncError("peer rejected: \(why)")
                default: throw SyncError("expected ops")
                }
            }
        }
        if role == .initiator { try await sendOps(); try await receiveOps() } else { try await receiveOps(); try await sendOps() }

        // 4. media: initiator asks first, then responder
        func requestMedia() async throws {
            let missing = try applier.missingMedia().map { MediaRef(sha256: $0.sha256, ext: $0.ext) }
            try await send(.needMedia(missing))
            while true {
                switch try await receive() {
                case .media(let ref):
                    let bytes = try await channel.receive()
                    guard MediaStore.sha256(of: bytes) == ref.sha256 else { continue }
                    _ = try collection.media.put(data: bytes, ext: ref.ext); report.mediaReceived += 1
                case .mediaDone: return
                default: throw SyncError("expected media")
                }
            }
        }
        func serveMedia() async throws {
            guard case .needMedia(let refs) = try await receive() else { throw SyncError("expected needMedia") }
            for ref in refs {
                let url = collection.media.url(sha256: ref.sha256, ext: ref.ext)
                guard let bytes = try? Data(contentsOf: url) else { continue }
                try await send(.media(ref)); try await channel.send(bytes); report.mediaSent += 1
            }
            try await send(.mediaDone)
        }
        if role == .initiator { try await requestMedia(); try await serveMedia() } else { try await serveMedia(); try await requestMedia() }

        // 5. done
        try await send(.done)
        _ = try? await receive()
        try collection.peers.touch(id: peerID)
        return report
    }
}

/// Known devices and their shared secrets.
public final class PeerRegistry: @unchecked Sendable {
    public struct Peer: Sendable, Equatable, Identifiable {
        public let id: String; public let name: String; public let endpoint: String?; public let lastSync: Int64?
    }
    private let db: Database
    init(db: Database) { self.db = db }

    public func all() throws -> [Peer] {
        try db.query("SELECT device_id, name, endpoint, last_seen_hlc FROM peer ORDER BY name", []) { r in
            Peer(id: r.string(0), name: r.string(1), endpoint: r.optString(2), lastSync: r.optString(3).flatMap(Int64.init))
        }
    }
    public func secret(for id: String) throws -> String? {
        try db.scalarString("SELECT secret FROM peer WHERE device_id = ?", [id])
    }
    public func upsert(id: String, name: String, secret: String, endpoint: String? = nil) throws {
        try db.run("""
            INSERT INTO peer(device_id, name, endpoint, secret, added_at) VALUES (?,?,?,?,?)
            ON CONFLICT(device_id) DO UPDATE SET name = excluded.name, secret = excluded.secret,
                endpoint = coalesce(excluded.endpoint, peer.endpoint)
            """, [id, name, endpoint, secret, Clock.nowMillis()])
    }
    public func setEndpoint(id: String, _ endpoint: String) throws {
        try db.run("UPDATE peer SET endpoint = ? WHERE device_id = ?", [endpoint, id])
    }
    public func touch(id: String) throws {
        try db.run("UPDATE peer SET last_seen_hlc = ? WHERE device_id = ?", [String(Clock.nowMillis()), id])
    }
    public func forget(id: String) throws { try db.run("DELETE FROM peer WHERE device_id = ?", [id]) }
}

/// In-process transport pair for tests and same-machine sync.
public final class PipeTransport: PeerTransport, @unchecked Sendable {
    private let inbox: AsyncStream<Data>
    private let push: AsyncStream<Data>.Continuation
    private var peerPush: AsyncStream<Data>.Continuation?
    private var iterator: AsyncStream<Data>.AsyncIterator

    private init() {
        var c: AsyncStream<Data>.Continuation!
        inbox = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        push = c
        iterator = inbox.makeAsyncIterator()
    }

    public static func pair() -> (PipeTransport, PipeTransport) {
        let a = PipeTransport(), b = PipeTransport()
        a.peerPush = b.push; b.peerPush = a.push
        return (a, b)
    }

    public func send(_ data: Data) async throws { peerPush?.yield(data) }
    public func receive() async throws -> Data {
        guard let d = await iterator.next() else { throw SyncError("peer closed") }
        return d
    }
    public func close() async { peerPush?.finish() }
}
