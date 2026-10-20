import Foundation
@testable import MemebooruCore

// Shared helpers for the edge-case / property suites. Linux-clean: no Apple-only APIs.

/// Deterministic RNG (SplitMix64) so fuzz runs are reproducible from a seed.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Thread-safe settable millisecond clock for `WaybackQueue.now`.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock(); private var v: Int64
    init(_ start: Int64 = 1_000_000) { v = start }
    var value: Int64 { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
    func advance(_ ms: Int64) { lock.withLock { v += ms } }
}

/// Thread-safe box for values touched from worker closures.
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock(); private var v: T
    init(_ v: T) { self.v = v }
    var value: T { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
    func mutate(_ f: (inout T) -> Void) { lock.withLock { f(&v) } }
}

extension TempCollection {
    /// Writes `data` to a fresh file under the collection's temp folder (outside staging/media).
    func file(_ name: String, _ data: Data) throws -> URL {
        let dir = url.appendingPathComponent("incoming-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let u = dir.appendingPathComponent(name)
        try data.write(to: u)
        return u
    }
    func file(_ name: String, _ text: String) throws -> URL { try file(name, Data(text.utf8)) }
}

// MARK: - Fake platform (no ImageIO / ffmpeg needed)

/// Pictures for the fake decoder are tiny text files: the first line names a synthetic pattern
/// (`IMG:h` horizontal gradient, `IMG:v` vertical gradient, `IMG:c` checkerboard); anything after
/// the first newline is ignored, so two files can differ byte-wise yet decode to the same picture
/// (a perfect near-duplicate). "Encoded" output is `RAW` + w + h + RGBA, which it also decodes.
enum FakePictures {
    static let side = 64

    static func data(_ pattern: Character, salt: String = "") -> Data { Data("IMG:\(pattern)\n\(salt)".utf8) }

    static func bitmap(_ pattern: Character) -> Bitmap {
        var px = Data(count: side * side * 4)
        for y in 0..<side { for x in 0..<side {
            let v: UInt8
            switch pattern {
            case "h": v = UInt8(x * 4)
            case "v": v = UInt8(y * 4)
            default: v = ((x / 8) + (y / 8)) % 2 == 0 ? 0 : 255
            }
            let i = (y * side + x) * 4
            px[i] = v; px[i + 1] = v; px[i + 2] = v; px[i + 3] = 255
        } }
        return Bitmap(width: side, height: side, rgba: px)
    }

    static func encodeRaw(_ b: Bitmap) -> Data {
        var d = Data("RAW".utf8)
        d.append(contentsOf: [UInt8(b.width >> 8), UInt8(b.width & 0xFF), UInt8(b.height >> 8), UInt8(b.height & 0xFF)])
        d.append(b.rgba)
        return d
    }

    static func decode(_ data: Data) -> Bitmap? {
        if data.starts(with: Data("RAW".utf8)), data.count >= 7 {
            let b = [UInt8](data.prefix(7))
            let w = Int(b[3]) << 8 | Int(b[4]), h = Int(b[5]) << 8 | Int(b[6])
            let rgba = data.dropFirst(7)
            guard rgba.count == w * h * 4 else { return nil }
            return Bitmap(width: w, height: h, rgba: Data(rgba))
        }
        guard data.starts(with: Data("IMG:".utf8)), data.count >= 5 else { return nil }
        let p = Character(UnicodeScalar([UInt8](data)[4]))
        guard "hvc".contains(p) else { return nil }
        return bitmap(p)
    }
}

struct FakeDecoder: ImageDecoder {
    struct Unreadable: Error {}
    func decode(_ url: URL, maxSide: Int) throws -> Bitmap {
        guard let b = FakePictures.decode(try Data(contentsOf: url)) else { throw Unreadable() }
        return b
    }
    func imageSize(_ url: URL) throws -> (width: Int, height: Int) {
        let b = try decode(url, maxSide: 0)
        return (b.width, b.height)
    }
}

struct FakeVideo: VideoProbe {
    struct NoVideo: Error {}
    func durationMs(_ url: URL) throws -> Int64 { throw NoVideo() }
    func frame(_ url: URL, at fraction: Double, maxSide: Int) throws -> Bitmap { throw NoVideo() }
}

struct FakeEncoder: ThumbnailEncoder {
    func jpeg(_ bitmap: Bitmap, quality: Double) throws -> Data { FakePictures.encodeRaw(bitmap) }
    func encode(_ bitmap: Bitmap, as format: MediaFormat, quality: Double) throws -> Data? {
        [.jpeg, .png].contains(format) ? FakePictures.encodeRaw(bitmap) : nil
    }
}

struct OfflineHTTP: HTTPClient {
    struct Offline: Error {}
    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse { throw Offline() }
}

enum FakePlatform {
    static let platform = Platform(images: FakeDecoder(), video: FakeVideo(), thumbs: FakeEncoder(), http: OfflineHTTP())
    static let analyzer = MediaAnalyzer(platform: platform)
}

// MARK: - Snapshots

/// Everything a user can observe about one meme, for "undo restores exact state" / convergence checks.
struct MemeSnapshot: Equatable, CustomStringConvertible {
    var id: String
    var live: Bool
    var kind: String
    var textExact: String?
    var textVerbatim: String?
    var context: String?
    var tags: [String]
    var assets: [String]
    var description: String { "\(id.prefix(8)) live=\(live) tags=\(tags) text=\(textExact ?? "-")" }
}

extension Collection {
    func snapshot() throws -> [MemeSnapshot] {
        let ids = try db.query("SELECT id FROM meme ORDER BY id", []) { $0.string(0) }
        return try ids.map { id in
            let m = try memes.get(MemeID(id))!
            return MemeSnapshot(id: id, live: m.deletedAt == nil, kind: m.kind.rawValue,
                                textExact: m.textExact, textVerbatim: m.textVerbatim, context: m.context,
                                tags: try memes.tags(of: m.id).map(\.name).sorted(),
                                assets: try memes.assets(of: m.id).map { "\($0.role.rawValue):\($0.order):\($0.sha256)" }.sorted())
        }
    }

    /// Ids a full, unpaginated search returns (newest first).
    func ids(_ query: String) throws -> [MemeID] { try search.search(query, limit: 1_000_000).memes.map(\.id) }
}
