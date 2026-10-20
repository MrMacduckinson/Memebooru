import Foundation

/// Local-feature matching for "one image is a crop / zoom of another" — the case global perceptual
/// hashes (dHash/pHash) miss, because they describe the whole frame, not a sub-region.
///
/// Pipeline (a lightweight ORB, tuned for crops which keep the same orientation):
///   FAST-9 corners over a scale pyramid  →  256-bit BRIEF descriptors  →  Hamming match with Lowe ratio
///   →  RANSAC fit of a scale+translation model  →  containment decision from where one image maps into the other.
public enum FeatureMatch {

    public struct Keypoint: Sendable {
        public let x: Float          // in base-image pixels
        public let y: Float
        public let desc: (UInt64, UInt64, UInt64, UInt64)
    }

    public struct Features: Sendable {
        public let width: Int
        public let height: Int
        public let points: [Keypoint]
    }

    /// Direction of a detected containment plus how strong the evidence is.
    public struct Containment: Sendable {
        public enum Relation: Sendable { case aContainsB, bContainsA, nearDuplicate }
        public let relation: Relation
        public let inliers: Int
        public let scale: Float      // fitted B→A scale (≈1 for a near-duplicate)
    }

    // MARK: - Tuning
    static let fastThreshold: Float = 20      // corner contrast
    static let maxKeypointsPerLevel = 150
    static let pyramidLevels = 4
    static let pyramidScale: Float = 1.5      // each level is 1.5× smaller
    static let ratioTest: Float = 0.78
    static let maxDescDistance = 72           // reject weak matches (bits out of 256)
    static let ransacIters = 300
    static let inlierTolerance: Float = 4     // px at base resolution
    static let minInliers = 16

    // MARK: - Detect + describe

    public static func features(_ base: GrayImage) -> Features {
        var pts: [Keypoint] = []
        var level = base
        var scale: Float = 1
        for _ in 0..<pyramidLevels {
            if level.width < 24 || level.height < 24 { break }
            let blurred = boxBlur3(level)
            let corners = fast9(level, threshold: fastThreshold, topK: maxKeypointsPerLevel)
            for c in corners {
                guard let d = brief(blurred, x: c.0, y: c.1) else { continue }
                pts.append(Keypoint(x: Float(c.0) * scale, y: Float(c.1) * scale, desc: d))
            }
            let nw = Int(Float(level.width) / pyramidScale)
            let nh = Int(Float(level.height) / pyramidScale)
            if nw < 24 || nh < 24 { break }
            level = level.resized(nw, nh)
            scale *= pyramidScale
        }
        return Features(width: base.width, height: base.height, points: pts)
    }

    // MARK: - Match two images

    public static func containment(_ a: Features, _ b: Features) -> Containment? {
        let matches = matchDescriptors(a.points, b.points)
        guard matches.count >= minInliers else { return nil }

        // RANSAC a similarity-without-rotation model  A ≈ s·B + t  (two correspondences fix s, t).
        var bestInliers: [(Int, Int)] = []
        var bestS: Float = 1, bestTX: Float = 0, bestTY: Float = 0
        var rng = SplitMix64(seed: 0x9E3779B97F4A7C15)
        let m = matches.count
        for _ in 0..<ransacIters {
            let i = Int(rng.next() % UInt64(m)), j = Int(rng.next() % UInt64(m))
            if i == j { continue }
            let (ai, bi) = matches[i], (aj, bj) = matches[j]
            let bdx = b.points[bi].x - b.points[bj].x, bdy = b.points[bi].y - b.points[bj].y
            let adx = a.points[ai].x - a.points[aj].x, ady = a.points[ai].y - a.points[aj].y
            let bd = (bdx * bdx + bdy * bdy).squareRoot()
            let ad = (adx * adx + ady * ady).squareRoot()
            guard bd > 1e-3 else { continue }
            let s = ad / bd
            guard s > 0.1, s < 10 else { continue }
            let tx = a.points[ai].x - s * b.points[bi].x
            let ty = a.points[ai].y - s * b.points[bi].y
            var inliers: [(Int, Int)] = []
            let tol = inlierTolerance * max(1, s)
            for (ma, mb) in matches {
                let px = s * b.points[mb].x + tx, py = s * b.points[mb].y + ty
                let ex = px - a.points[ma].x, ey = py - a.points[ma].y
                if ex * ex + ey * ey <= tol * tol { inliers.append((ma, mb)) }
            }
            if inliers.count > bestInliers.count { bestInliers = inliers; bestS = s; bestTX = tx; bestTY = ty }
        }

        guard bestInliers.count >= minInliers else { return nil }

        // Where does B's frame land inside A? A = s·B + t maps B's box to this rectangle.
        let bw = Float(b.width), bh = Float(b.height)
        let mappedW = bestS * bw, mappedH = bestS * bh
        let areaA = Float(a.width) * Float(a.height)
        let mappedArea = mappedW * mappedH
        let ratio = mappedArea / areaA          // B-in-A footprint vs A

        let relation: Containment.Relation
        if ratio < 0.72 { relation = .aContainsB }          // B occupies a sub-region of A
        else if ratio > 1.0 / 0.72 { relation = .bContainsA }
        else { relation = .nearDuplicate }
        _ = (bestTX, bestTY)
        return Containment(relation: relation, inliers: bestInliers.count, scale: bestS)
    }

    // MARK: - Descriptor matching (brute force + Lowe ratio)

    private static func matchDescriptors(_ a: [Keypoint], _ b: [Keypoint]) -> [(Int, Int)] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        var out: [(Int, Int)] = []
        for i in 0..<a.count {
            let da = a[i].desc
            var best = Int.max, second = Int.max, bestJ = -1
            for j in 0..<b.count {
                let d = hamming(da, b[j].desc)
                if d < best { second = best; best = d; bestJ = j }
                else if d < second { second = d }
            }
            if bestJ >= 0, best <= maxDescDistance, Float(best) < ratioTest * Float(second) {
                out.append((i, bestJ))
            }
        }
        return out
    }

    @inline(__always)
    private static func hamming(_ x: (UInt64, UInt64, UInt64, UInt64), _ y: (UInt64, UInt64, UInt64, UInt64)) -> Int {
        (x.0 ^ y.0).nonzeroBitCount + (x.1 ^ y.1).nonzeroBitCount + (x.2 ^ y.2).nonzeroBitCount + (x.3 ^ y.3).nonzeroBitCount
    }

    // MARK: - FAST-9 corner detector

    private static let circle: [(Int, Int)] = [
        (0, -3), (1, -3), (2, -2), (3, -1), (3, 0), (3, 1), (2, 2), (1, 3),
        (0, 3), (-1, 3), (-2, 2), (-3, 1), (-3, 0), (-3, -1), (-2, -2), (-1, -3)
    ]

    /// Returns corner (x, y) locations, non-max suppressed, top-K by score.
    private static func fast9(_ img: GrayImage, threshold t: Float, topK: Int) -> [(Int, Int)] {
        let w = img.width, h = img.height
        let px = img.pixels
        var scored: [(Int, Int, Float)] = []
        for y in 3..<(h - 3) {
            for x in 3..<(w - 3) {
                let c = px[y * w + x]
                let hi = c + t, lo = c - t
                // Quick reject with the 4 compass points.
                let p0 = px[(y - 3) * w + x], p8 = px[(y + 3) * w + x]
                let p4 = px[y * w + x + 3], p12 = px[y * w + x - 3]
                let brightCount = (p0 > hi ? 1 : 0) + (p8 > hi ? 1 : 0) + (p4 > hi ? 1 : 0) + (p12 > hi ? 1 : 0)
                let darkCount = (p0 < lo ? 1 : 0) + (p8 < lo ? 1 : 0) + (p4 < lo ? 1 : 0) + (p12 < lo ? 1 : 0)
                if brightCount < 3 && darkCount < 3 { continue }
                // Full 16-ring contiguous arc of ≥9.
                var ring = [Float](repeating: 0, count: 16)
                for k in 0..<16 { ring[k] = px[(y + circle[k].1) * w + (x + circle[k].0)] }
                if arc(ring, hi: hi, lo: lo) {
                    var score: Float = 0
                    for k in 0..<16 { score += abs(ring[k] - c) }
                    scored.append((x, y, score))
                }
            }
        }
        // Non-max suppression on a small grid, then top-K.
        scored.sort { $0.2 > $1.2 }
        var kept: [(Int, Int)] = []
        var occupied = Set<Int>()
        let cell = 6
        let gw = (w + cell - 1) / cell
        for (x, y, _) in scored {
            let key = (y / cell) * gw + (x / cell)
            if occupied.contains(key) { continue }
            occupied.insert(key); kept.append((x, y))
            if kept.count >= topK { break }
        }
        return kept
    }

    /// Is there a contiguous arc of ≥9 of the 16 ring pixels all brighter than `hi` (or all darker than `lo`)?
    private static func arc(_ ring: [Float], hi: Float, lo: Float) -> Bool {
        for sign in 0..<2 {
            var run = 0, best = 0
            for k in 0..<(16 + 9) {
                let v = ring[k % 16]
                let ok = sign == 0 ? v > hi : v < lo
                if ok { run += 1; best = max(best, run) } else { run = 0 }
            }
            if best >= 9 { return true }
        }
        return false
    }

    // MARK: - BRIEF descriptor

    /// 256 sampling pairs inside a 31×31 patch, generated once, deterministically.
    private static let pattern: [(Int8, Int8, Int8, Int8)] = {
        var rng = SplitMix64(seed: 0xD1B54A32D192ED03)
        var out: [(Int8, Int8, Int8, Int8)] = []
        let r: Int32 = 13
        func g() -> Int8 { Int8(Int32(rng.next() % UInt64(2 * r + 1)) - r) }
        for _ in 0..<256 { out.append((g(), g(), g(), g())) }
        return out
    }()

    private static func brief(_ img: GrayImage, x: Int, y: Int) -> (UInt64, UInt64, UInt64, UInt64)? {
        let w = img.width, h = img.height
        guard x >= 15, y >= 15, x < w - 15, y < h - 15 else { return nil }
        let px = img.pixels
        var words: [UInt64] = [0, 0, 0, 0]
        for i in 0..<256 {
            let (ax, ay, bx, by) = pattern[i]
            let a = px[(y + Int(ay)) * w + (x + Int(ax))]
            let b = px[(y + Int(by)) * w + (x + Int(bx))]
            if a < b { words[i >> 6] |= (1 << UInt64(i & 63)) }
        }
        return (words[0], words[1], words[2], words[3])
    }

    // MARK: - Small helpers

    /// 3×3 box blur (reduces BRIEF's noise sensitivity).
    private static func boxBlur3(_ img: GrayImage) -> GrayImage {
        let w = img.width, h = img.height, src = img.pixels
        var out = src
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                var s: Float = 0
                for dy in -1...1 { for dx in -1...1 { s += src[(y + dy) * w + (x + dx)] } }
                out[y * w + x] = s / 9
            }
        }
        return GrayImage(width: w, height: h, pixels: out)
    }
}

/// Deterministic PRNG so scans are reproducible.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
