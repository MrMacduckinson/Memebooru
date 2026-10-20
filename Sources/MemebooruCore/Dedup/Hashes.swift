import Foundation

/// Grayscale float image used as hashing input.
public struct GrayImage: Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [Float]   // row-major, 0…255

    public init(width: Int, height: Int, pixels: [Float]) {
        precondition(pixels.count == width * height)
        self.width = width; self.height = height; self.pixels = pixels
    }

    public init(_ bitmap: Bitmap) {
        let w = bitmap.width, h = bitmap.height
        var px = [Float](repeating: 0, count: w * h)
        bitmap.rgba.withUnsafeBytes { buf in
            let p = buf.bindMemory(to: UInt8.self)
            for i in 0..<(w * h) {
                let r = Float(p[i * 4]), g = Float(p[i * 4 + 1]), b = Float(p[i * 4 + 2])
                px[i] = 0.299 * r + 0.587 * g + 0.114 * b
            }
        }
        width = w; height = h; pixels = px
    }

    /// Box-filter downscale to exactly `w`×`h` (area averaging; fine for hashing).
    public func resized(_ w: Int, _ h: Int) -> GrayImage {
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let y0 = y * height / h, y1 = max(y0 + 1, (y + 1) * height / h)
            for x in 0..<w {
                let x0 = x * width / w, x1 = max(x0 + 1, (x + 1) * width / w)
                var sum: Float = 0
                for yy in y0..<y1 { for xx in x0..<x1 { sum += pixels[yy * width + xx] } }
                out[y * w + x] = sum / Float((y1 - y0) * (x1 - x0))
            }
        }
        return GrayImage(width: w, height: h, pixels: out)
    }
}

public enum PerceptualHash {
    /// Difference hash: 9×8 downscale, each bit = left pixel brighter than right.
    public static func dHash(_ img: GrayImage) -> UInt64 {
        let s = img.resized(9, 8)
        var h: UInt64 = 0
        for y in 0..<8 { for x in 0..<8 {
            h <<= 1
            if s.pixels[y * 9 + x] > s.pixels[y * 9 + x + 1] { h |= 1 }
        } }
        return h
    }

    /// pHash: 32×32 downscale → DCT-II → top-left 8×8 (skipping DC) vs median.
    public static func pHash(_ img: GrayImage) -> UInt64 {
        let n = 32
        let s = img.resized(n, n)
        // separable DCT: rows then columns, only first 8 coefficients needed
        var cosTable = [Float](repeating: 0, count: 8 * n)
        for u in 0..<8 { for x in 0..<n {
            cosTable[u * n + x] = cos(Float.pi * Float(2 * x + 1) * Float(u) / Float(2 * n))
        } }
        var rows = [Float](repeating: 0, count: n * 8)   // rows[y*8+u]
        for y in 0..<n { for u in 0..<8 {
            var acc: Float = 0
            for x in 0..<n { acc += s.pixels[y * n + x] * cosTable[u * n + x] }
            rows[y * 8 + u] = acc
        } }
        var dct = [Float](repeating: 0, count: 64)          // dct[v*8+u]
        for v in 0..<8 { for u in 0..<8 {
            var acc: Float = 0
            for y in 0..<n { acc += rows[y * 8 + u] * cosTable[v * n + y] }
            dct[v * 8 + u] = acc
        } }
        let ac = Array(dct[1...])                             // drop DC term
        let median = ac.sorted()[ac.count / 2]
        var h: UInt64 = 0
        for i in 0..<64 {
            h <<= 1
            if i > 0, dct[i] > median { h |= 1 }
        }
        return h
    }

    public static func hamming(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }

    /// SQLite stores INTEGER as signed 64-bit; bit-cast both ways.
    public static func toInt64(_ h: UInt64) -> Int64 { Int64(bitPattern: h) }
    public static func fromInt64(_ i: Int64) -> UInt64 { UInt64(bitPattern: i) }
}

public enum TextHash {
    /// Simhash over word shingles; near-identical texts differ in few bits.
    public static func simhash(_ text: String) -> UInt64 {
        let words = text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        guard !words.isEmpty else { return 0 }
        var v = [Int](repeating: 0, count: 64)
        func add(_ token: String) {
            let h = fnv1a(token)
            for b in 0..<64 { v[b] += (h >> UInt64(b)) & 1 == 1 ? 1 : -1 }
        }
        for w in words { add(w) }
        if words.count > 1 { for i in 0..<(words.count - 1) { add(words[i] + " " + words[i + 1]) } }
        var out: UInt64 = 0
        for b in 0..<64 where v[b] > 0 { out |= 1 << UInt64(b) }
        return out
    }

    static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 { h ^= UInt64(byte); h = h &* 0x100000001b3 }
        return h
    }
}
