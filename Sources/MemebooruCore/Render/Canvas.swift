import Foundation

/// A rectangle in canvas pixels.
struct Box: Equatable {
    var x: Double, y: Double, w: Double, h: Double
    init(_ x: Double, _ y: Double, _ w: Double, _ h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }
    var maxX: Double { x + w }
    var maxY: Double { y + h }
    func inset(_ d: Double) -> Box { Box(x + d, y + d, w - 2 * d, h - 2 * d) }
}

/// Opaque RGB canvas for rendered cards: antialiased fills, rounded / circular clipping, scaled bitmaps.
/// Pure Swift, so a tweet renders to the same pixels on the Mac, the phone and the server.
struct Canvas {
    let width: Int
    let height: Int
    private(set) var px: [UInt8]

    init(width: Int, height: Int, fill: UInt32) {
        self.width = max(1, width); self.height = max(1, height)
        px = [UInt8](repeating: 255, count: self.width * self.height * 4)
        let (r, g, b) = Self.rgb(fill)
        for i in stride(from: 0, to: px.count, by: 4) { px[i] = r; px[i + 1] = g; px[i + 2] = b }
    }

    static func rgb(_ c: UInt32) -> (UInt8, UInt8, UInt8) { (UInt8(c >> 16 & 0xFF), UInt8(c >> 8 & 0xFF), UInt8(c & 0xFF)) }

    var bitmap: Bitmap { Bitmap(width: width, height: height, rgba: Data(px)) }

    // MARK: - Shapes

    /// Signed distance from a point to a rounded rectangle (negative inside).
    private static func distance(_ x: Double, _ y: Double, _ b: Box, _ r: Double) -> Double {
        let r = min(r, b.w / 2, b.h / 2)
        let qx = abs(x - (b.x + b.w / 2)) - (b.w / 2 - r)
        let qy = abs(y - (b.y + b.h / 2)) - (b.h / 2 - r)
        return hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - r
    }

    /// 0…1: how much of the pixel centred at (x, y) the rounded rectangle covers.
    static func coverage(_ x: Double, _ y: Double, _ b: Box, radius: Double) -> Double {
        min(1, max(0, 0.5 - distance(x, y, b, radius)))
    }

    private mutating func blend(_ i: Int, _ c: (UInt8, UInt8, UInt8), _ a: Double) {
        guard a > 0 else { return }
        if a >= 1 { px[i] = c.0; px[i + 1] = c.1; px[i + 2] = c.2; return }
        px[i] = UInt8((Double(px[i]) * (1 - a) + Double(c.0) * a).rounded())
        px[i + 1] = UInt8((Double(px[i + 1]) * (1 - a) + Double(c.1) * a).rounded())
        px[i + 2] = UInt8((Double(px[i + 2]) * (1 - a) + Double(c.2) * a).rounded())
    }

    /// Pixel rows/columns a box touches, clamped to the canvas.
    private func span(_ b: Box) -> (x0: Int, x1: Int, y0: Int, y1: Int)? {
        let x0 = max(0, Int(b.x.rounded(.down))), x1 = min(width, Int(b.maxX.rounded(.up)))
        let y0 = max(0, Int(b.y.rounded(.down))), y1 = min(height, Int(b.maxY.rounded(.up)))
        return x0 < x1 && y0 < y1 ? (x0, x1, y0, y1) : nil
    }

    mutating func fill(_ b: Box, _ color: UInt32, radius: Double = 0, opacity: Double = 1) {
        guard let s = span(b) else { return }
        let c = Self.rgb(color)
        for y in s.y0..<s.y1 {
            for x in s.x0..<s.x1 {
                blend((y * width + x) * 4, c, opacity * Self.coverage(Double(x) + 0.5, Double(y) + 0.5, b, radius: radius))
            }
        }
    }

    /// A `lineWidth` outline drawn inside the box.
    mutating func stroke(_ b: Box, _ color: UInt32, radius: Double = 0, lineWidth: Double = 1) {
        guard let s = span(b) else { return }
        let c = Self.rgb(color), inner = b.inset(lineWidth), innerR = max(0, radius - lineWidth)
        for y in s.y0..<s.y1 {
            for x in s.x0..<s.x1 {
                let cx = Double(x) + 0.5, cy = Double(y) + 0.5
                let a = Self.coverage(cx, cy, b, radius: radius) - Self.coverage(cx, cy, inner, radius: innerR)
                blend((y * width + x) * 4, c, a)
            }
        }
    }

    /// Filled triangle (the play badge), edges softened over one pixel.
    mutating func fillTriangle(_ p: [(Double, Double)], _ color: UInt32) {
        guard p.count == 3 else { return }
        let xs = p.map(\.0), ys = p.map(\.1)
        guard let s = span(Box(xs.min()!, ys.min()!, xs.max()! - xs.min()!, ys.max()! - ys.min()!)) else { return }
        let c = Self.rgb(color)
        // Orientation-independent: distance to each edge, positive inside.
        let area = (p[1].0 - p[0].0) * (p[2].1 - p[0].1) - (p[1].1 - p[0].1) * (p[2].0 - p[0].0)
        let sign: Double = area >= 0 ? 1 : -1
        for y in s.y0..<s.y1 {
            for x in s.x0..<s.x1 {
                let cx = Double(x) + 0.5, cy = Double(y) + 0.5
                var d = Double.infinity
                for k in 0..<3 {
                    let a = p[k], b = p[(k + 1) % 3]
                    let len = hypot(b.0 - a.0, b.1 - a.1)
                    guard len > 0 else { continue }
                    d = min(d, sign * ((b.0 - a.0) * (cy - a.1) - (b.1 - a.1) * (cx - a.0)) / len)
                }
                blend((y * width + x) * 4, c, min(1, max(0, d + 0.5)))
            }
        }
    }

    // MARK: - Bitmaps

    /// Draws `bitmap` 1:1 with its top-left at (x, y) — for text blocks.
    mutating func draw(_ bitmap: Bitmap, x: Int, y: Int) {
        bitmap.rgba.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            for sy in 0..<bitmap.height {
                let dy = y + sy
                guard dy >= 0, dy < height else { continue }
                for sx in 0..<bitmap.width {
                    let dx = x + sx
                    guard dx >= 0, dx < width else { continue }
                    let si = (sy * bitmap.width + sx) * 4
                    blend((dy * width + dx) * 4, (src[si], src[si + 1], src[si + 2]), Double(src[si + 3]) / 255)
                }
            }
        }
    }

    enum Fit { case stretch, fill }

    /// Draws `bitmap` scaled into `b` — `.fill` crops the centre to the box's aspect — clipped to a
    /// rounded rectangle of `radius` (a circle when the box is square and radius = w/2).
    mutating func draw(_ bitmap: Bitmap, in b: Box, fit: Fit = .stretch, radius: Double = 0) {
        guard bitmap.width > 0, bitmap.height > 0, let s = span(b) else { return }
        // Source rectangle that maps onto the box.
        var sx0 = 0.0, sy0 = 0.0, sw = Double(bitmap.width), sh = Double(bitmap.height)
        if fit == .fill {
            let boxAspect = b.w / b.h, srcAspect = sw / sh
            if srcAspect > boxAspect { let nw = sh * boxAspect; sx0 = (sw - nw) / 2; sw = nw }
            else { let nh = sw / boxAspect; sy0 = (sh - nh) / 2; sh = nh }
        }
        let kx = sw / b.w, ky = sh / b.h
        // Downscaling: average an n×n grid of bilinear samples over each pixel's footprint.
        let nx = min(4, max(1, Int(kx.rounded(.up)))), ny = min(4, max(1, Int(ky.rounded(.up))))
        bitmap.rgba.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            func sample(_ fx: Double, _ fy: Double) -> (Double, Double, Double, Double) {
                let x = min(max(fx - 0.5, 0), Double(bitmap.width - 1)), y = min(max(fy - 0.5, 0), Double(bitmap.height - 1))
                let x0 = Int(x), y0 = Int(y), x1 = min(x0 + 1, bitmap.width - 1), y1 = min(y0 + 1, bitmap.height - 1)
                let tx = x - Double(x0), ty = y - Double(y0)
                var out = (0.0, 0.0, 0.0, 0.0)
                for (xx, yy, w) in [(x0, y0, (1 - tx) * (1 - ty)), (x1, y0, tx * (1 - ty)), (x0, y1, (1 - tx) * ty), (x1, y1, tx * ty)] where w > 0 {
                    let i = (yy * bitmap.width + xx) * 4
                    let a = Double(src[i + 3]) / 255 * w
                    // Premultiplied while averaging, so transparent pixels don't bleed their colour.
                    out.0 += Double(src[i]) * a; out.1 += Double(src[i + 1]) * a; out.2 += Double(src[i + 2]) * a; out.3 += a
                }
                return out
            }
            for y in s.y0..<s.y1 {
                for x in s.x0..<s.x1 {
                    let cx = Double(x) + 0.5, cy = Double(y) + 0.5
                    let clip = Self.coverage(cx, cy, b, radius: radius)
                    guard clip > 0 else { continue }
                    var acc = (0.0, 0.0, 0.0, 0.0)
                    for j in 0..<ny {
                        for i in 0..<nx {
                            let fx = sx0 + (Double(x) - b.x + (Double(i) + 0.5) / Double(nx)) * kx
                            let fy = sy0 + (Double(y) - b.y + (Double(j) + 0.5) / Double(ny)) * ky
                            let v = sample(fx, fy)
                            acc.0 += v.0; acc.1 += v.1; acc.2 += v.2; acc.3 += v.3
                        }
                    }
                    guard acc.3 > 0 else { continue }
                    let c = (UInt8(min(255, (acc.0 / acc.3).rounded())), UInt8(min(255, (acc.1 / acc.3).rounded())), UInt8(min(255, (acc.2 / acc.3).rounded())))
                    blend((y * width + x) * 4, c, clip * acc.3 / Double(nx * ny))
                }
            }
        }
    }
}
