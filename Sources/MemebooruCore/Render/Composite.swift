import Foundation

/// How the pictures of a combined meme (a diptych, triptych…) are put together. People often send one
/// meme as several pictures in one message; it's kept as one meme: the pictures themselves (assets of
/// role `part`, in order) plus this layout, and the combined picture made from them as the primary file.
public struct CompositeLayout: Codable, Sendable, Equatable, Hashable {
    public enum Arrangement: String, Codable, Sendable, CaseIterable {
        /// Side by side, all one height.
        case row
        /// One above the other, all one width.
        case column
        /// Rows of `columns` pictures; each row fills the full width (pictures in a row share a height).
        case grid
        /// The first picture large on the left, the others stacked on the right, together as tall as it.
        case feature
    }

    public var arrangement: Arrangement
    /// Pictures per row (grid only).
    public var columns: Int
    /// The shared side in pixels: the height of a row (`row`, `feature`) or the width of the whole
    /// (`column`, `grid`). nil = as large as the largest picture allows (smaller ones are scaled up).
    public var size: Int?
    /// Space between pictures, in pixels (white).
    public var gap: Int

    public init(_ arrangement: Arrangement, columns: Int = 2, size: Int? = nil, gap: Int = 0) {
        self.arrangement = arrangement; self.columns = columns; self.size = size; self.gap = gap
    }

    /// The longest side the result may have (what JPEG and every common viewer can open) …
    public static let maxSide = 32_767
    /// … and the most pixels (about 400 MB while it's drawn; ten 4K screenshots fit). Larger layouts
    /// are scaled down as a whole. Ordinary combinations — even several full-resolution screenshots
    /// side by side — stay at full size.
    public static let maxPixels = 100_000_000
    /// The smallest shared side offered.
    public static let minSize = 64

    /// A sensible first layout: two or three pictures go side by side when they're tall or square, one
    /// above the other when they're wide (as people read comics); four make a 2 × 2 grid; more, a grid
    /// of three.
    public static func suggested(for sizes: [PixelSize]) -> CompositeLayout {
        let n = sizes.count
        if n == 4 { return CompositeLayout(.grid, columns: 2) }
        if n > 4 { return CompositeLayout(.grid, columns: 3) }
        let wide = sizes.filter { $0.aspect > 1.15 }.count
        return CompositeLayout(wide * 2 > n ? .column : .row)
    }

    /// The shared side when `size` is nil: the largest picture's own height (row, feature) or width
    /// (column), or the widest row at its tallest picture's height (grid). The user may pick less, never more.
    public func naturalSize(for sizes: [PixelSize]) -> Int {
        guard !sizes.isEmpty else { return 0 }
        switch arrangement {
        case .row, .feature: return sizes.map(\.height).max()!
        case .column: return sizes.map(\.width).max()!
        case .grid:
            let rows = Self.chunks(sizes.indices.map { $0 }, max(1, columns))
            return rows.map { row -> Int in
                let h = Double(row.map { sizes[$0].height }.max()!)
                let w = row.reduce(0.0) { $0 + h * sizes[$1].aspect } + Double(gap * (row.count - 1))
                return Int(w.rounded())
            }.max()!
        }
    }

    /// The range the shared side can be set to.
    public func sizeRange(for sizes: [PixelSize]) -> ClosedRange<Int> {
        let natural = naturalSize(for: sizes)
        return min(Self.minSize, natural)...natural
    }

    /// Where each picture goes, in pixels, and the size of the whole.
    public func geometry(for sizes: [PixelSize]) -> CompositeGeometry {
        guard !sizes.isEmpty, sizes.allSatisfy({ $0.width > 0 && $0.height > 0 }) else { return CompositeGeometry(width: 0, height: 0, frames: []) }
        let range = sizeRange(for: sizes)
        let s = Double(Swift.min(Swift.max(size ?? range.upperBound, range.lowerBound), range.upperBound))
        let g = Double(Swift.max(0, gap))
        var frames: [(x: Double, y: Double, w: Double, h: Double)] = Array(repeating: (0, 0, 0, 0), count: sizes.count)
        var total = (w: 0.0, h: 0.0)
        switch arrangement {
        case .row:
            var x = 0.0
            for (i, p) in sizes.enumerated() {
                let w = s * p.aspect
                frames[i] = (x, 0, w, s); x += w + g
            }
            total = (x - g, s)
        case .column:
            var y = 0.0
            for (i, p) in sizes.enumerated() {
                let h = s / p.aspect
                frames[i] = (0, y, s, h); y += h + g
            }
            total = (s, y - g)
        case .grid:
            var y = 0.0
            for row in Self.chunks(sizes.indices.map { $0 }, Swift.max(1, columns)) {
                // Every row fills the width: its height is what makes its pictures add up to it.
                let h = (s - g * Double(row.count - 1)) / row.reduce(0.0) { $0 + sizes[$1].aspect }
                var x = 0.0
                for i in row { let w = h * sizes[i].aspect; frames[i] = (x, y, w, h); x += w + g }
                y += h + g
            }
            total = (s, y - g)
        case .feature:
            if sizes.count == 1 { frames[0] = (0, 0, s * sizes[0].aspect, s); total = (frames[0].w, s); break }
            let lead = s * sizes[0].aspect
            let rest = Array(sizes.indices.dropFirst())
            // The stack's width makes its pictures (and the gaps) exactly as tall as the lead picture.
            let w = (s - g * Double(rest.count - 1)) / rest.reduce(0.0) { $0 + 1 / sizes[$1].aspect }
            frames[0] = (0, 0, lead, s)
            var y = 0.0
            for i in rest { let h = w / sizes[i].aspect; frames[i] = (lead + g, y, w, h); y += h + g }
            total = (lead + g + w, s)
        }
        // Too large overall: everything shrinks together.
        let k = Swift.min(1, Double(Self.maxSide) / Swift.max(total.w, total.h, 1),
                          (Double(Self.maxPixels) / Swift.max(1, total.w * total.h)).squareRoot())
        func px(_ v: Double) -> Int { Int((v * k).rounded()) }
        let rects = frames.map { f in
            // Edges are rounded, not sizes, so neighbours meet without a seam.
            PixelRect(x: px(f.x), y: px(f.y), width: Swift.max(1, px(f.x + f.w) - px(f.x)), height: Swift.max(1, px(f.y + f.h) - px(f.y)))
        }
        return CompositeGeometry(width: Swift.max(1, px(total.w)), height: Swift.max(1, px(total.h)), frames: rects)
    }

    static func chunks(_ a: [Int], _ n: Int) -> [[Int]] {
        stride(from: 0, to: a.count, by: n).map { Array(a[$0..<Swift.min($0 + n, a.count)]) }
    }

    // Older clients: a missing field decodes to its default.
    private enum CodingKeys: String, CodingKey { case arrangement, columns, size, gap }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        arrangement = (try? c.decode(Arrangement.self, forKey: .arrangement)) ?? .row
        columns = (try? c.decode(Int.self, forKey: .columns)) ?? 2
        size = try? c.decode(Int.self, forKey: .size)
        gap = (try? c.decode(Int.self, forKey: .gap)) ?? 0
    }
}

public struct PixelSize: Codable, Sendable, Equatable, Hashable {
    public var width: Int, height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
    public var aspect: Double { Double(width) / Double(Swift.max(1, height)) }
}

public struct PixelRect: Sendable, Equatable, Hashable, Codable {
    public var x: Int, y: Int, width: Int, height: Int
    public init(x: Int, y: Int, width: Int, height: Int) { self.x = x; self.y = y; self.width = width; self.height = height }
}

public struct CompositeGeometry: Sendable, Equatable {
    public var width: Int, height: Int
    public var frames: [PixelRect]
}

/// What a combined meme keeps beside its pictures: how they're laid out.
public struct CompositePayload: Codable, Sendable, Equatable {
    public var layout: CompositeLayout
    public init(layout: CompositeLayout) { self.layout = layout }
}

/// Draws the combined picture from its parts, on white.
public struct CompositeRenderer: Sendable {
    let converter: MediaConverter
    public init(converter: MediaConverter) { self.converter = converter }

    public struct Result: Sendable { public let data: Data; public let ext: String; public let width: Int; public let height: Int }

    /// Lossless sources (or any transparency) give a PNG, photos a JPEG.
    public func render(_ parts: [URL], layout: CompositeLayout) throws -> Result {
        guard parts.count >= 2 else { throw CollectionError("combining needs at least two pictures") }
        let bitmaps = try parts.map { try converter.raster($0, maxSide: 0) }
        let geo = layout.geometry(for: bitmaps.map { PixelSize(width: $0.width, height: $0.height) })
        var canvas = Canvas(width: geo.width, height: geo.height, fill: 0xFFFFFF)
        for (b, f) in zip(bitmaps, geo.frames) {
            canvas.draw(b, in: Box(Double(f.x), Double(f.y), Double(f.width), Double(f.height)), fit: .fill)
        }
        let lossless = parts.contains { ["png", "gif", "bmp", "tif", "tiff", "svg", "webp"].contains($0.pathExtension.lowercased()) }
        let format: MediaFormat = lossless ? .png : .jpeg
        guard let data = try converter.platform.thumbs.encode(canvas.bitmap, as: format, quality: 0.92) else {
            throw CollectionError("can't write \(format.label) here")
        }
        return Result(data: data, ext: format.ext, width: geo.width, height: geo.height)
    }
}
