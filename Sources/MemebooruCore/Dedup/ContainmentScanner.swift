import Foundation

public struct ContainmentResult: Sendable, Hashable {
    public let container: MemeID     // the larger image
    public let contained: MemeID     // the crop / sub-image
    public let inliers: Int
}

/// Whole-collection "one image is a crop of another" pass. Decoding is injected (the core has no image
/// codec), so the same scanner runs from the CLI and the app. It extracts local features once per image,
/// then checks each not-yet-related pair for containment.
public final class ContainmentScanner {
    private let collection: Collection
    private let decode: (URL) -> GrayImage?
    private var db: Database { collection.db }

    public init(collection: Collection, decode: @escaping (URL) -> GrayImage?) {
        self.collection = collection
        self.decode = decode
    }

    public func scan(maxImages: Int = 800, maxSide: Int = 512,
                     onProgress: ((_ done: Int, _ total: Int) -> Void)? = nil) throws -> [ContainmentResult] {
        let rows = try db.query("""
            SELECT m.id, a.sha256, a.ext FROM meme m
              JOIN asset a ON a.meme_id = m.id AND a.role = 'primary'
             WHERE m.deleted_at IS NULL AND m.kind IN ('image','gif')
            """, []) { (MemeID($0.string(0)), $0.string(1), $0.string(2)) }
        let items = Array(rows.prefix(maxImages))

        // Extract features once per image.
        var feats: [(MemeID, FeatureMatch.Features)] = []
        feats.reserveCapacity(items.count)
        for (id, sha, ext) in items {
            if let g = decode(collection.media.url(sha256: sha, ext: ext)) {
                feats.append((id, FeatureMatch.features(g)))
            }
        }

        // Don't resurface pairs the user already judged or that are already linked.
        let dismissed = Set(try db.query("SELECT a_id, b_id FROM dismissed_pair", []) { DuplicateScanner.key($0.string(0), $0.string(1)) })
        let related = Set(try db.query("SELECT from_id, to_id FROM relation WHERE deleted_at IS NULL", []) { DuplicateScanner.key($0.string(0), $0.string(1)) })
        let skip = dismissed.union(related)

        var out: [ContainmentResult] = []
        let total = feats.count * (feats.count - 1) / 2
        var done = 0
        for i in 0..<feats.count {
            for j in (i + 1)..<feats.count {
                done += 1
                if done % 200 == 0 { onProgress?(done, total) }
                let k = DuplicateScanner.key(feats[i].0.rawValue, feats[j].0.rawValue)
                if skip.contains(k) { continue }
                guard let c = FeatureMatch.containment(feats[i].1, feats[j].1) else { continue }
                switch c.relation {
                case .aContainsB: out.append(ContainmentResult(container: feats[i].0, contained: feats[j].0, inliers: c.inliers))
                case .bContainsA: out.append(ContainmentResult(container: feats[j].0, contained: feats[i].0, inliers: c.inliers))
                case .nearDuplicate: break   // the pHash pass already covers these
                }
            }
        }
        onProgress?(total, total)
        return out.sorted { $0.inliers > $1.inliers }
    }
}
