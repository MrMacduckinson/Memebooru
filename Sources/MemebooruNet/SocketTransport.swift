import Foundation
import MemebooruCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// Plain POSIX TCP so the sync server runs on Linux (no Network.framework there). Wire format matches
// `NWTransport`: each frame is a 4-byte big-endian length followed by the payload, so an Apple client
// using Network.framework talks to this server unchanged.

private let sockStream: Int32 = {
    #if canImport(Glibc)
    return Int32(SOCK_STREAM.rawValue)
    #else
    return SOCK_STREAM
    #endif
}()

private let sendFlags: Int32 = {
    #if canImport(Glibc)
    return Int32(MSG_NOSIGNAL)   // a dropped peer must not kill the server with SIGPIPE
    #else
    return 0                     // Darwin: SO_NOSIGPIPE is set on the socket instead
    #endif
}()

public struct SocketError: Error, CustomStringConvertible, Sendable {
    public let description: String
    init(_ what: String) { description = "\(what): \(String(cString: strerror(errno)))" }
    init(message: String) { description = message }
}

/// One TCP connection carrying length-prefixed frames. Blocking I/O runs on its own serial queues,
/// so the async API never blocks a cooperative thread.
public final class SocketTransport: PeerTransport, @unchecked Sendable {
    public static let maxFrame = 512 * 1024 * 1024

    private let fd: Int32
    private let readQueue = DispatchQueue(label: "memebooru.socket.read")
    private let writeQueue = DispatchQueue(label: "memebooru.socket.write")
    private let lock = NSLock()
    private var closed = false
    public let remoteAddress: String

    init(fd: Int32, remoteAddress: String) {
        self.fd = fd; self.remoteAddress = remoteAddress
        Self.configure(fd)
    }

    deinit { closeNow() }

    static func configure(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, Int32(IPPROTO_TCP), TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        #if canImport(Darwin)
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        // Keepalive: a VPS peer that silently vanished is detected instead of hanging a session forever.
        setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Connect to `host:port` (name or IPv4/IPv6 literal), trying each resolved address in turn.
    public static func connect(host: String, port: UInt16) async throws -> SocketTransport {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do { cont.resume(returning: try connectBlocking(host: host, port: port)) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    private static func connectBlocking(host: String, port: UInt16) throws -> SocketTransport {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = sockStream
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &res)
        guard rc == 0, let first = res else {
            throw SocketError(message: "cannot resolve \(host): \(String(cString: gai_strerror(rc)))")
        }
        defer { freeaddrinfo(first) }
        var lastError = SocketError(message: "no address for \(host)")
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let ai = p {
            let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            if fd >= 0 {
                if Glue.connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 {
                    return SocketTransport(fd: fd, remoteAddress: "\(host):\(port)")
                }
                lastError = SocketError("connect to \(host):\(port)")
                _ = Glue.close(fd)
            }
            p = ai.pointee.ai_next
        }
        throw lastError
    }

    // MARK: - PeerTransport

    public func send(_ data: Data) async throws {
        var buf = Data(capacity: data.count + 4)
        var len = UInt32(data.count).bigEndian
        withUnsafeBytes(of: &len) { buf.append(contentsOf: $0) }
        buf.append(data)
        let frame = buf   // immutable for the write queue
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            writeQueue.async {
                do { try self.writeAll(frame); cont.resume() } catch { cont.resume(throwing: error) }
            }
        }
    }

    public func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            readQueue.async {
                do {
                    let header = try self.readExactly(4)
                    let len = header.withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
                    guard len <= Self.maxFrame else { throw SocketError(message: "frame too large (\(len) bytes)") }
                    cont.resume(returning: len == 0 ? Data() : try self.readExactly(len))
                } catch { cont.resume(throwing: error) }
            }
        }
    }

    public func close() async { closeNow() }

    private func closeNow() {
        let shouldClose = lock.withLock { () -> Bool in defer { closed = true }; return !closed }
        if shouldClose { _ = shutdown(fd, Int32(SHUT_RDWR)); _ = Glue.close(fd) }
    }

    // MARK: - Blocking I/O

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var off = 0
            while off < buf.count {
                let n = Glue.send(fd, buf.baseAddress! + off, buf.count - off, sendFlags)
                if n < 0 { if errno == EINTR { continue }; throw SocketError("send") }
                off += n
            }
        }
    }

    private func readExactly(_ count: Int) throws -> Data {
        var out = Data(count: count)
        try out.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) in
            var off = 0
            while off < count {
                let n = Glue.recv(fd, buf.baseAddress! + off, count - off, 0)
                if n == 0 { throw SyncError("peer closed") }
                if n < 0 { if errno == EINTR { continue }; throw SocketError("recv") }
                off += n
            }
        }
        return out
    }
}

/// Accepts TCP connections on a port (IPv6 dual-stack, so IPv4 clients work too) and hands each one
/// to `onConnection` on its own task.
public final class SocketListener: @unchecked Sendable {
    private var fd: Int32 = -1
    private let lock = NSLock()
    private var running = false
    public private(set) var port: UInt16 = 0

    public init() {}

    public func start(port: UInt16, onConnection: @escaping @Sendable (SocketTransport) async -> Void) throws {
        let fd = socket(AF_INET6, sockStream, 0)
        guard fd >= 0 else { throw SocketError("socket") }
        var one: Int32 = 1, zero: Int32 = 0
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, Int32(IPPROTO_IPV6), IPV6_V6ONLY, &zero, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in6()
        #if canImport(Darwin)
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        #endif
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = port.bigEndian
        addr.sin6_addr = in6addr_any
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Glue.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
        guard bound == 0 else { let e = SocketError("bind port \(port)"); _ = Glue.close(fd); throw e }
        guard listen(fd, 16) == 0 else { let e = SocketError("listen"); _ = Glue.close(fd); throw e }

        var actual = sockaddr_in6(), len = socklen_t(MemoryLayout<sockaddr_in6>.size)
        _ = withUnsafeMutablePointer(to: &actual) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        self.port = UInt16(bigEndian: actual.sin6_port)
        lock.withLock { self.fd = fd; running = true }

        let thread = Thread { [weak self] in self?.acceptLoop(fd: fd, onConnection: onConnection) }
        thread.name = "memebooru.accept"
        thread.start()
    }

    public func stop() {
        let fd = lock.withLock { () -> Int32 in running = false; return self.fd }
        if fd >= 0 { _ = shutdown(fd, Int32(SHUT_RDWR)); _ = Glue.close(fd) }
    }

    private func acceptLoop(fd: Int32, onConnection: @escaping @Sendable (SocketTransport) async -> Void) {
        while lock.withLock({ running }) {
            var peer = sockaddr_storage(), len = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let client = withUnsafeMutablePointer(to: &peer) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &len) } }
            if client < 0 {
                if errno == EINTR { continue }
                if !lock.withLock({ running }) { return }
                Thread.sleep(forTimeInterval: 0.1)    // e.g. EMFILE: back off instead of spinning
                continue
            }
            let transport = SocketTransport(fd: client, remoteAddress: Self.describe(&peer))
            Task.detached { await onConnection(transport) }
        }
    }

    private static func describe(_ storage: inout sockaddr_storage) -> String {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t(MemoryLayout<sockaddr_storage>.size), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            }
        }
        return rc == 0 ? String(cString: host) : "?"
    }
}

/// Free functions whose names clash with methods (`close`, `send`, …) or differ by platform.
enum Glue {
    static func close(_ fd: Int32) -> Int32 {
        #if canImport(Glibc)
        return Glibc.close(fd)
        #else
        return Darwin.close(fd)
        #endif
    }
    static func connect(_ fd: Int32, _ addr: UnsafePointer<sockaddr>!, _ len: socklen_t) -> Int32 {
        #if canImport(Glibc)
        return Glibc.connect(fd, addr, len)
        #else
        return Darwin.connect(fd, addr, len)
        #endif
    }
    static func bind(_ fd: Int32, _ addr: UnsafePointer<sockaddr>!, _ len: socklen_t) -> Int32 {
        #if canImport(Glibc)
        return Glibc.bind(fd, addr, len)
        #else
        return Darwin.bind(fd, addr, len)
        #endif
    }
    static func send(_ fd: Int32, _ buf: UnsafeRawPointer, _ n: Int, _ flags: Int32) -> Int {
        #if canImport(Glibc)
        return Glibc.send(fd, buf, n, flags)
        #else
        return Darwin.send(fd, buf, n, flags)
        #endif
    }
    static func recv(_ fd: Int32, _ buf: UnsafeMutableRawPointer, _ n: Int, _ flags: Int32) -> Int {
        #if canImport(Glibc)
        return Glibc.recv(fd, buf, n, flags)
        #else
        return Darwin.recv(fd, buf, n, flags)
        #endif
    }
}

/// Responder side of sync over TCP: every connection runs a `SyncSession`; wrong pairing codes are
/// throttled by `pairingGuard`. The pairing code rotates after each successful pairing.
public final class SyncServer: @unchecked Sendable {
    private let collection: Collection
    private let listener = SocketListener()
    private let lock = NSLock()
    private var code = SyncAuth.randomCode()
    public let pairingGuard = PairingGuard()
    public var onEvent: (@Sendable (String) -> Void)?

    public init(collection: Collection) { self.collection = collection }

    public var pairingCode: String { lock.withLock { code } }
    public var port: UInt16 { listener.port }

    public func start(port: UInt16) throws {
        try listener.start(port: port) { [weak self] transport in await self?.handle(transport) }
    }

    public func stop() { listener.stop() }

    private func handle(_ transport: SocketTransport) async {
        let locked = pairingGuard.isLocked
        let session = SyncSession(collection: collection, transport: transport, role: .responder,
                                  acceptCode: locked ? nil : pairingCode)
        do {
            let r = try await session.run()
            if r.paired {
                lock.withLock { code = SyncAuth.randomCode() }
                pairingGuard.reset()
            }
            onEvent?("✓ \(r.peerName) [\(transport.remoteAddress)]: ↓\(r.received) ops (\(r.applied) new) ↑\(r.sent); media ↓\(r.mediaReceived) ↑\(r.mediaSent)\(r.paired ? " — paired" : "")")
        } catch let e as WrongPairingCode {
            pairingGuard.recordFailure()
            onEvent?("✗ \(e) [\(transport.remoteAddress)]\(pairingGuard.isLocked ? " — pairing locked for \(Int(pairingGuard.window / 60)) min" : "")")
        } catch {
            onEvent?("✗ \(transport.remoteAddress): \(error)")
        }
    }
}
