import Foundation

/// What was done to a file: its frame cropped (pictures, GIFs, videos) and/or its ends trimmed
/// (videos, audio). The original is always kept, so an edit can be changed or undone later.
public struct MediaEdit: Codable, Sendable, Equatable, Hashable {
    /// The part kept, in the original's pixels (as shown, i.e. after EXIF rotation).
    public var crop: PixelRect?
    /// The stretch kept.
    public var trim: TimeRange?

    public init(crop: PixelRect? = nil, trim: TimeRange? = nil) { self.crop = crop; self.trim = trim }
    public var isEmpty: Bool { crop == nil && trim == nil }

    var json: String { String(decoding: try! JSONEncoder().encode(self), as: UTF8.self) }
    static func decode(_ s: String?) -> MediaEdit? {
        guard let s, let d = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MediaEdit.self, from: d)
    }
}

public struct TimeRange: Codable, Sendable, Equatable, Hashable {
    public var startMs: Int64, endMs: Int64
    public init(startMs: Int64, endMs: Int64) { self.startMs = startMs; self.endMs = endMs }
    public var durationMs: Int64 { endMs - startMs }
}

extension PixelRect {
    /// The same rectangle in a picture `k` times as large.
    public func scaled(_ k: Double) -> PixelRect {
        let x0 = Int((Double(x) * k).rounded()), y0 = Int((Double(y) * k).rounded())
        return PixelRect(x: x0, y: y0, width: max(1, Int((Double(x + width) * k).rounded()) - x0),
                         height: max(1, Int((Double(y + height) * k).rounded()) - y0))
    }
    /// Kept inside a `w` × `h` picture, at least 1 × 1.
    public func clamped(width w: Int, height h: Int) -> PixelRect {
        let x0 = min(max(0, x), max(0, w - 1)), y0 = min(max(0, y), max(0, h - 1))
        return PixelRect(x: x0, y: y0, width: min(max(1, width), w - x0), height: min(max(1, height), h - y0))
    }
    /// Even position and size (video encoders need them for 4:2:0 colour); shrinks inward.
    public var evened: PixelRect {
        let x0 = (x + 1) / 2 * 2, y0 = (y + 1) / 2 * 2
        let x1 = (x + width) / 2 * 2, y1 = (y + height) / 2 * 2
        return PixelRect(x: x0, y: y0, width: max(2, x1 - x0), height: max(2, y1 - y0))
    }
}

extension Bitmap {
    public func cropped(to r: PixelRect) -> Bitmap {
        let r = r.clamped(width: width, height: height)
        var out = Data(count: r.width * r.height * 4)
        rgba.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                for row in 0..<r.height {
                    let from = ((r.y + row) * width + r.x) * 4
                    dst.baseAddress!.advanced(by: row * r.width * 4).copyMemory(from: src.baseAddress!.advanced(by: from), byteCount: r.width * 4)
                }
            }
        }
        return Bitmap(width: r.width, height: r.height, rgba: out)
    }
}

// MARK: - Borders

/// Finds plain bands around a picture — black bars, white margins, a coloured frame, a screenshot's
/// grey padding — not only the black bars a video player looks for. From each side it walks inward
/// while a whole line is one colour (allowing for JPEG noise and a few stray pixels); after a thin
/// outline, a band in another colour goes too (a hairline round a white margin).
/// It never eats more than 45% of a side, and a picture that's all one colour has no borders.
public enum BorderDetector {
    /// How far a pixel may be from the band's colour (0–255, per channel) and still belong to it.
    public static let tolerance = 26
    /// The share of a line that may differ (dust, a watermark's edge) for it to still count as band.
    public static let strayShare = 0.006
    /// A line averaging this dark (luma 0–255) with at most this spread counts as black bar.
    public static let darkMean = 32.0
    public static let darkSpread = 12.0

    /// The content rectangle, or nil when there's nothing to cut.
    public static func contentRect(_ b: Bitmap) -> PixelRect? {
        guard b.width >= 8, b.height >= 8 else { return nil }
        let px = [UInt8](b.rgba)
        func at(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * b.width + x) * 4
            // On white: transparent margins count as white, like the picture shows them.
            let a = Int(px[i + 3])
            func ch(_ v: UInt8) -> Int { (Int(v) * a + 255 * (255 - a)) / 255 }
            return (ch(px[i]), ch(px[i + 1]), ch(px[i + 2]))
        }
        /// Pixels of a line: along x at row y (horizontal) or along y at column x.
        func line(_ horizontal: Bool, _ n: Int, from: Int, to: Int) -> [(Int, Int, Int)] {
            (from..<to).map { horizontal ? at($0, n) : at(n, $0) }
        }
        func median(_ p: [(Int, Int, Int)]) -> (Int, Int, Int) {
            func m(_ v: [Int]) -> Int { v.sorted()[v.count / 2] }
            return (m(p.map(\.0)), m(p.map(\.1)), m(p.map(\.2)))
        }
        func luma(_ c: (Int, Int, Int)) -> Int { (c.0 * 299 + c.1 * 587 + c.2 * 114) / 1000 }
        /// Dark on average with little spread (black bar with noise), as video players judge bars.
        func dark(_ p: [(Int, Int, Int)]) -> Bool {
            guard !p.isEmpty else { return false }
            let l = p.map { Double(luma($0)) }
            let mean = l.reduce(0, +) / Double(l.count)
            let sd = (l.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(l.count)).squareRoot()
            return mean <= darkMean && sd <= darkSpread
        }
        func uniform(_ p: [(Int, Int, Int)], _ c: (Int, Int, Int)) -> Bool {
            let off = p.filter { abs($0.0 - c.0) > tolerance || abs($0.1 - c.1) > tolerance || abs($0.2 - c.2) > tolerance }.count
            return Double(off) <= Double(p.count) * strayShare
        }

        var top = 0, bottom = b.height, left = 0, right = b.width
        func distance(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Int { max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2)) }
        /// Walks one side inward; returns how many lines are band. A band is lines of one colour (its
        /// pixels within `tolerance`, its median steady) ending at a sharp edge: where a smooth
        /// gradient merely drifts on, it's picture, and that band is given back.
        func walk(horizontal: Bool, forward: Bool) -> Int {
            let length = horizontal ? b.height : b.width
            let limit = Int(Double(length) * 0.45)
            var depth = 0, bands = 0, bandStart = 0
            var colour: (Int, Int, Int)?
            var darkBand = false
            while depth < limit {
                let n = forward ? depth : length - 1 - depth
                let p = horizontal ? line(true, n, from: left, to: right) : line(false, n, from: top, to: bottom)
                let m = median(p)
                let isDark = dark(p)
                if let c = colour, uniform(p, c), distance(m, c) <= 8 { depth += 1; continue }
                // Black bars of old or upscaled video are noisy and fade into the picture: like a video
                // player's crop detection, a line that is dark on average is still bar.
                if darkBand && isDark { depth += 1; continue }
                let plain = uniform(p, m)
                // Soft edge after a light band: a gradient (a sky), so that band was picture after all.
                if let c = colour, !darkBand, plain, distance(m, c) < tolerance * 3 { return bandStart }
                // A new band begins only on a line that is itself one colour (or dark). A second one only
                // after a thin outline (a hairline round a screenshot's margin): after a real margin, a plain
                // stretch is more likely the picture's own (a caption bar's padding).
                guard plain || isDark, bands == 0 || (bands < 3 && depth - bandStart <= max(3, length / 66)) else { break }
                colour = m; darkBand = isDark || luma(m) <= 40; bands += 1; bandStart = depth; depth += 1
            }
            return depth == limit ? 0 : depth          // ran out of room: that's the picture itself, not a band
        }
        top = walk(horizontal: true, forward: true)
        bottom = b.height - walk(horizontal: true, forward: false)
        left = walk(horizontal: false, forward: true)
        right = b.width - walk(horizontal: false, forward: false)
        // Second pass for the rows: the columns are known now, so side bars don't hide top/bottom bands.
        if left > 0 || right < b.width {
            top = walk(horizontal: true, forward: true)
            bottom = b.height - walk(horizontal: true, forward: false)
        }
        guard bottom - top >= 4, right - left >= 4 else { return nil }
        let r = PixelRect(x: left, y: top, width: right - left, height: bottom - top)
        return r == PixelRect(x: 0, y: 0, width: b.width, height: b.height) ? nil : r
    }

    /// The content of several frames (a video, a GIF): what any of them shows — the largest rectangle,
    /// so a scene with a dark corner doesn't cut the others. Frames that are one colour (a fade) are skipped.
    public static func contentRect(frames: [Bitmap]) -> PixelRect? {
        guard let first = frames.first else { return nil }
        let rects = frames.compactMap { f -> PixelRect? in
            if let r = contentRect(f) { return r }
            return isPlain(f) ? nil : PixelRect(x: 0, y: 0, width: f.width, height: f.height)
        }
        guard !rects.isEmpty else { return nil }
        let x0 = rects.map(\.x).min()!, y0 = rects.map(\.y).min()!
        let x1 = rects.map { $0.x + $0.width }.max()!, y1 = rects.map { $0.y + $0.height }.max()!
        let r = PixelRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        return r == PixelRect(x: 0, y: 0, width: first.width, height: first.height) ? nil : r
    }

    /// One colour all over (a black frame between scenes).
    static func isPlain(_ b: Bitmap) -> Bool {
        let px = [UInt8](b.rgba)
        guard px.count >= 4 else { return true }
        var lo = (255, 255, 255), hi = (0, 0, 0)
        for i in stride(from: 0, to: px.count, by: 4 * 7) {
            lo = (min(lo.0, Int(px[i])), min(lo.1, Int(px[i + 1])), min(lo.2, Int(px[i + 2])))
            hi = (max(hi.0, Int(px[i])), max(hi.1, Int(px[i + 1])), max(hi.2, Int(px[i + 2])))
        }
        return hi.0 - lo.0 <= tolerance && hi.1 - lo.1 <= tolerance && hi.2 - lo.2 <= tolerance
    }
}

// MARK: - Silence

/// Finds where the sound starts and ends: the quiet lead-in and tail (hiss, room tone, nothing) go.
public enum SilenceDetector {
    /// Loudness of 20 ms windows (RMS, 0…1).
    public static func levels(_ samples: [Int16], rate: Int, windowMs: Int = 20) -> [Float] {
        let n = max(1, rate * windowMs / 1000)
        return stride(from: 0, to: samples.count, by: n).map { start in
            let end = min(samples.count, start + n)
            var sum = 0.0
            for i in start..<end { let v = Double(samples[i]) / 32768; sum += v * v }
            return Float((sum / Double(max(1, end - start))).squareRoot())
        }
    }

    /// The stretch to keep, or nil when there's no quiet edge worth cutting (or no sound at all).
    /// Quiet = below −45 dBFS and 30 dB under the loudest part; a little air is left on both sides.
    public static func soundRange(_ samples: [Int16], rate: Int) -> TimeRange? {
        let windowMs = 20
        let lv = levels(samples, rate: rate, windowMs: windowMs)
        guard let peak = lv.max(), peak > 0.001 else { return nil }
        let threshold = max(Float(0.0056), peak * 0.0316)          // −45 dBFS, or −30 dB under the peak
        guard let first = lv.firstIndex(where: { $0 > threshold }), let last = lv.lastIndex(where: { $0 > threshold }) else { return nil }
        let total = Int64(samples.count) * 1000 / Int64(max(1, rate))
        let start = max(0, Int64(first * windowMs) - 80)
        let end = min(total, Int64((last + 1) * windowMs) + 150)
        // Less than a tenth of a second to gain on either side: leave it.
        guard start > 100 || total - end > 100 else { return nil }
        return TimeRange(startMs: start, endMs: end)
    }

    /// Peaks for drawing a waveform: `count` buckets, 0…1.
    public static func peaks(_ samples: [Int16], count: Int) -> [Float] {
        guard !samples.isEmpty, count > 0 else { return [] }
        let per = max(1, samples.count / count)
        return stride(from: 0, to: samples.count, by: per).prefix(count).map { start in
            var m: Int32 = 0
            for i in start..<min(samples.count, start + per) { m = max(m, abs(Int32(samples[i]))) }
            return Float(m) / 32768
        }
    }
}
