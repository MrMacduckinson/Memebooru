import Foundation

public struct DuplicatePair: Sendable, Hashable {
    public enum Match: Sendable, Hashable { case exact, similar(distance: Int) }
    public let a: MemeID
    public let b: MemeID
    public let match: Match
    public var distance: Int { if case .similar(let d) = match { return d }; return 0 }
}

/// Whole-collection pass: same bytes, or pHash within `threshold`. Skips dismissed and already-related pairs.
public final class DuplicateScanner: @unchecked Sendable {
    private let collection: Collection
    private var db: Database { collection.db }

    public init(collection: Collection) { self.collection = collection }

    public func scan(threshold: Int = StagingArea.similarThreshold) throws -> [DuplicatePair] {
        let rows = try db.query(
            "SELECT a.meme_id, a.sha256, a.phash FROM asset a JOIN meme m ON m.id = a.meme_id WHERE a.role = 'primary' AND m.deleted_at IS NULL",
            []) { (MemeID($0.string(0)), $0.string(1), $0.optInt64(2)) }
        let dismissed = Set(try db.query("SELECT a_id, b_id FROM dismissed_pair", []) { Self.key($0.string(0), $0.string(1)) })
        let related = Set(try db.query("SELECT from_id, to_id FROM relation WHERE deleted_at IS NULL", []) { Self.key($0.string(0), $0.string(1)) })
        let skip = dismissed.union(related)

        var pairs: [DuplicatePair] = []
        var seen = Set<String>()
        var bySha: [String: [MemeID]] = [:]
        for (id, sha, _) in rows { bySha[sha, default: []].append(id) }
        for ids in bySha.values where ids.count > 1 {
            for i in 0..<ids.count { for j in (i + 1)..<ids.count {
                let k = Self.key(ids[i].rawValue, ids[j].rawValue)
                guard !skip.contains(k), seen.insert(k).inserted else { continue }
                pairs.append(DuplicatePair(a: ids[i], b: ids[j], match: .exact))
            } }
        }
        var tree = BKTree<MemeID>()
        for (id, _, ph) in rows { if let ph { tree.insert(PerceptualHash.fromInt64(ph), id) } }
        for (id, _, ph) in rows {
            guard let ph else { continue }
            for hit in tree.search(PerceptualHash.fromInt64(ph), radius: threshold) where hit.payload != id {
                let k = Self.key(id.rawValue, hit.payload.rawValue)
                guard !skip.contains(k), seen.insert(k).inserted else { continue }
                let (a, b) = id.rawValue < hit.payload.rawValue ? (id, hit.payload) : (hit.payload, id)
                pairs.append(DuplicatePair(a: a, b: b, match: .similar(distance: hit.distance)))
            }
        }
        return pairs.sorted { ($0.distance, $0.a.rawValue) < ($1.distance, $1.a.rawValue) }
    }

    /// "Not a duplicate" — never show this pair again.
    public func dismiss(_ a: MemeID, _ b: MemeID) throws {
        let (x, y) = a.rawValue < b.rawValue ? (a, b) : (b, a)
        try db.run("INSERT OR IGNORE INTO dismissed_pair(a_id, b_id) VALUES (?, ?)", [x.rawValue, y.rawValue])
    }

    static func key(_ a: String, _ b: String) -> String { a < b ? "\(a)|\(b)" : "\(b)|\(a)" }
}

/// Connected component of near/exact pairs: three webp/jpg/png copies of one meme land in one cluster.
public struct DuplicateCluster: Sendable, Hashable, Identifiable {
    public let members: [MemeID]          // sorted by id
    public let pairs: [DuplicatePair]     // edges inside the cluster
    public var id: String { members.map(\.rawValue).joined(separator: "|") }
    public var maxDistance: Int { pairs.map(\.distance).max() ?? 0 }
    public var allExact: Bool { pairs.allSatisfy { $0.match == .exact } }
}

extension DuplicateScanner {
    public func clusters(threshold: Int = StagingArea.similarThreshold) throws -> [DuplicateCluster] {
        Self.clusters(from: try scan(threshold: threshold))
    }

    /// Union-find over pairs.
    public static func clusters(from pairs: [DuplicatePair]) -> [DuplicateCluster] {
        var parent: [MemeID: MemeID] = [:]
        func find(_ x: MemeID) -> MemeID {
            var r = x
            while let p = parent[r], p != r { r = p }
            var c = x
            while let p = parent[c], p != r { parent[c] = r; c = p }
            return r
        }
        for p in pairs {
            parent[p.a] = parent[p.a] ?? p.a
            parent[p.b] = parent[p.b] ?? p.b
            let ra = find(p.a), rb = find(p.b)
            if ra != rb { parent[ra] = rb }
        }
        var groups: [MemeID: [DuplicatePair]] = [:]
        for p in pairs { groups[find(p.a), default: []].append(p) }
        return groups.values.map { edges in
            let members = Set(edges.flatMap { [$0.a, $0.b] }).sorted { $0.rawValue < $1.rawValue }
            return DuplicateCluster(members: members, pairs: edges.sorted { ($0.distance, $0.a.rawValue) < ($1.distance, $1.a.rawValue) })
        }
        .sorted { ($0.members.count, -$0.maxDistance) > ($1.members.count, -$1.maxDistance) }
    }

    /// Keep one member; every other member becomes its `duplicate` and is soft-deleted.
    public func resolve(_ cluster: DuplicateCluster, keeping keep: MemeID, memes: MemeStore) throws {
        for m in cluster.members where m != keep {
            try memes.addRelation(Relation(from: keep, to: m, kind: .duplicate))
            try memes.delete(m)
        }
    }

    /// All members are variants of each other (same template, different caption).
    public func markVariants(_ cluster: DuplicateCluster, memes: MemeStore) throws {
        for p in cluster.pairs { try memes.addRelation(Relation(from: p.a, to: p.b, kind: .variant)) }
    }

    /// Never show these together again.
    public func dismiss(_ cluster: DuplicateCluster) throws {
        for p in cluster.pairs { try dismiss(p.a, p.b) }
    }
}
