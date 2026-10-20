import Crypto
import Foundation

/// Byte transport between two peers. Framing is done by `SyncSession`.
public protocol PeerTransport: Sendable {
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close() async
}

/// Wire messages. One JSON frame each; `media` is followed by one raw frame with the file bytes.
/// Only `hello` travels in the clear; everything after it goes through a `SecureChannel`.
public enum SyncMessage: Codable, Sendable, Equatable {
    case hello(deviceID: String, name: String, vector: [String: HLC], nonce: String, key: String, version: Int)
    case auth(hmac: String)                       // HMAC-SHA256(secret, peerNonce ‖ transcript)
    case pair(code: String)                       // pairing handshake instead of auth
    case paired(secret: String)                   // responder accepted the code
    case reject(reason: String)
    case ops([Op])
    case opsDone
    case needMedia([MediaRef])
    case media(MediaRef)                          // + raw frame
    case mediaDone
    case done
}

public struct MediaRef: Codable, Sendable, Hashable {
    public let sha256: String
    public let ext: String
    public init(sha256: String, ext: String) { self.sha256 = sha256; self.ext = ext }
}

public struct SyncReport: Sendable {
    public var peerID = "", peerName = ""
    public var sent = 0, received = 0, applied = 0
    public var mediaSent = 0, mediaReceived = 0
    public var paired = false
    public init() {}
}

public struct SyncError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ d: String) { description = d }
}

/// A pairing attempt with the wrong code — listeners count these (`PairingGuard`).
public struct WrongPairingCode: Error, CustomStringConvertible, Sendable {
    public let peerName: String
    public var description: String { "wrong pairing code from \(peerName)" }
}

public enum SyncProtocol {
    /// v2: X25519 + ChaCha20-Poly1305 channel, HMAC bound to the handshake transcript.
    public static let version = 2
}

public enum SyncAuth {
    /// Proof of the shared secret, bound to the peer's nonce and this session's handshake transcript,
    /// so a captured proof is useless in any other session.
    public static func hmac(secret: String, nonce: String, transcript: Data = Data()) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        return HMAC<SHA256>.authenticationCode(for: Data(nonce.utf8) + transcript, using: key)
            .map { String(format: "%02x", $0) }.joined()
    }
    public static func randomSecret() -> String {
        (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
    public static func randomCode() -> String { String(format: "%06d", Int.random(in: 0..<1_000_000)) }
}
