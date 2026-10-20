import Crypto
import Foundation

/// Encrypted, authenticated framing on top of any `PeerTransport`.
///
/// Both peers send an ephemeral X25519 public key in their `hello`. The ECDH result is expanded with
/// HKDF (salt = hash of both hello frames, so the keys are bound to this exact handshake) into one
/// ChaCha20-Poly1305 key per direction. Every frame after `hello` is sealed with a per-direction counter
/// nonce, so tampering, replay, reordering or dropping a frame all fail decryption.
///
/// This gives confidentiality against anyone watching the wire (the VPS link crosses the internet) with
/// no certificates to manage. Authentication of *who* is on the other end is still the job of the
/// pairing code / shared-secret HMAC, which `SyncSession` binds to `transcript`.
public final class SecureChannel: PeerTransport, @unchecked Sendable {
    private let inner: any PeerTransport
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0
    private let lock = NSLock()

    /// SHA-256 of the initiator's hello followed by the responder's hello.
    public let transcript: Data

    public struct Handshake {   // not Sendable: swift-crypto keys aren't on Linux; lives inside one session
        public let privateKey: Curve25519.KeyAgreement.PrivateKey
        public var publicKeyBase64: String { privateKey.publicKey.rawRepresentation.base64EncodedString() }
        public init() { privateKey = Curve25519.KeyAgreement.PrivateKey() }
    }

    /// - Parameters:
    ///   - initiatorHello/responderHello: the exact encoded hello frames as sent on the wire.
    public init(over inner: any PeerTransport, handshake: Handshake, peerPublicKeyBase64: String,
                isInitiator: Bool, initiatorHello: Data, responderHello: Data) throws {
        guard let raw = Data(base64Encoded: peerPublicKeyBase64),
              let peerKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw) else {
            throw SyncError("peer sent an invalid key")
        }
        let shared = try handshake.privateKey.sharedSecretFromKeyAgreement(with: peerKey)
        var h = SHA256()
        h.update(data: initiatorHello)
        h.update(data: responderHello)
        let transcript = Data(h.finalize())
        func key(_ label: String) -> SymmetricKey {
            shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: transcript,
                                           sharedInfo: Data("memebooru sync v2 \(label)".utf8), outputByteCount: 32)
        }
        let i2r = key("initiator->responder"), r2i = key("responder->initiator")
        self.inner = inner
        self.transcript = transcript
        self.sendKey = isInitiator ? i2r : r2i
        self.receiveKey = isInitiator ? r2i : i2r
    }

    private static func nonce(_ counter: UInt64) throws -> ChaChaPoly.Nonce {
        var bytes = Data(repeating: 0, count: 4)
        withUnsafeBytes(of: counter.bigEndian) { bytes.append(contentsOf: $0) }
        return try ChaChaPoly.Nonce(data: bytes)
    }

    public func send(_ data: Data) async throws {
        let counter = lock.withLock { () -> UInt64 in defer { sendCounter += 1 }; return sendCounter }
        let box = try ChaChaPoly.seal(data, using: sendKey, nonce: Self.nonce(counter))
        try await inner.send(box.ciphertext + box.tag)
    }

    public func receive() async throws -> Data {
        let frame = try await inner.receive()
        guard frame.count >= 16 else { throw SyncError("truncated encrypted frame") }
        let counter = lock.withLock { () -> UInt64 in defer { receiveCounter += 1 }; return receiveCounter }
        let box = try ChaChaPoly.SealedBox(nonce: Self.nonce(counter),
                                           ciphertext: frame.prefix(frame.count - 16), tag: frame.suffix(16))
        do { return try ChaChaPoly.open(box, using: receiveKey) }
        catch { throw SyncError("encrypted frame failed authentication (tampered or out of order)") }
    }

    public func close() async { await inner.close() }
}

/// Throttles pairing attempts on a listener that is reachable from the internet: after `maxFailures`
/// wrong codes inside `window`, pairing is refused until the window has passed. Paired peers
/// (HMAC auth) are never affected.
public final class PairingGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [Date] = []
    public let maxFailures: Int
    public let window: TimeInterval

    public init(maxFailures: Int = 5, window: TimeInterval = 600) {
        self.maxFailures = maxFailures; self.window = window
    }

    public var isLocked: Bool {
        lock.withLock {
            let cutoff = Date().addingTimeInterval(-window)
            failures.removeAll { $0 < cutoff }
            return failures.count >= maxFailures
        }
    }

    public func recordFailure() { lock.withLock { failures.append(Date()) } }
    public func reset() { lock.withLock { failures.removeAll() } }
}
