import Foundation

/// Hybrid logical clock. Encoded as a fixed-width, lexicographically sortable string:
/// `<wall ms, 16 hex>-<counter, 4 hex>-<device id>`.
public struct HLC: Hashable, Comparable, Sendable, CustomStringConvertible, Codable {
    public let wall: Int64
    public let counter: Int
    public let device: String

    public init(wall: Int64, counter: Int, device: String) {
        self.wall = wall; self.counter = counter; self.device = device
    }

    public init?(string: String) {
        let parts = string.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let w = Int64(parts[0], radix: 16), let c = Int(parts[1], radix: 16) else { return nil }
        self.init(wall: w, counter: c, device: String(parts[2]))
    }

    public var description: String {
        String(format: "%016llx-%04x-", wall, counter) + device
    }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let h = HLC(string: s) else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad HLC \(s)")) }
        self = h
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer(); try c.encode(description)
    }

    public static func < (a: HLC, b: HLC) -> Bool {
        if a.wall != b.wall { return a.wall < b.wall }
        if a.counter != b.counter { return a.counter < b.counter }
        return a.device < b.device
    }
}

public final class HLCClock: @unchecked Sendable {
    public let device: String
    private var last: HLC
    private let lock = NSLock()

    public init(device: String) {
        self.device = device
        self.last = HLC(wall: 0, counter: 0, device: device)
    }

    public func now() -> HLC {
        lock.lock(); defer { lock.unlock() }
        let wall = Clock.nowMillis()
        if wall > last.wall { last = HLC(wall: wall, counter: 0, device: device) }
        else { last = HLC(wall: last.wall, counter: last.counter + 1, device: device) }
        return last
    }

    /// Fold in a timestamp received from a peer so our next tick is after it.
    public func observe(_ remote: HLC) {
        lock.lock(); defer { lock.unlock() }
        let wall = max(Clock.nowMillis(), remote.wall, last.wall)
        var counter = 0
        if wall == last.wall && wall == remote.wall { counter = max(last.counter, remote.counter) + 1 }
        else if wall == last.wall { counter = last.counter + 1 }
        else if wall == remote.wall { counter = remote.counter + 1 }
        last = HLC(wall: wall, counter: counter, device: device)
    }
}
