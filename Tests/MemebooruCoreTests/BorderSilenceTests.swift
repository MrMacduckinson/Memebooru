import Foundation
import Testing
@testable import MemebooruCore

/// A picture: `fill` everywhere, `content` drawn in `rect` as a checkerboard (so it's never one colour).
private func picture(_ w: Int, _ h: Int, fill: (UInt8, UInt8, UInt8), content rect: PixelRect,
                     bands: [(PixelRect, (UInt8, UInt8, UInt8))] = [], noise: Int = 0, seed: UInt64 = 1) -> Bitmap {
    var px = [UInt8](repeating: 255, count: w * h * 4)
    var rng = seed
    func n() -> Int { guard noise > 0 else { return 0 }; rng = rng &* 6364136223846793005 &+ 1; return Int(rng >> 33) % (2 * noise + 1) - noise }
    func set(_ x: Int, _ y: Int, _ c: (UInt8, UInt8, UInt8)) {
        let i = (y * w + x) * 4
        px[i] = UInt8(clamping: Int(c.0) + n()); px[i + 1] = UInt8(clamping: Int(c.1) + n()); px[i + 2] = UInt8(clamping: Int(c.2) + n())
    }
    for y in 0..<h { for x in 0..<w { set(x, y, fill) } }
    for (r, c) in bands { for y in r.y..<(r.y + r.height) { for x in r.x..<(r.x + r.width) { set(x, y, c) } } }
    for y in rect.y..<(rect.y + rect.height) {
        for x in rect.x..<(rect.x + rect.width) { set(x, y, ((x / 3 + y / 3) % 2 == 0) ? (200, 40, 40) : (30, 90, 200)) }
    }
    return Bitmap(width: w, height: h, rgba: Data(px))
}

@Suite struct BorderDetectorTests {
    let inner = PixelRect(x: 30, y: 20, width: 140, height: 80)

    @Test func blackBarsLikeAVideoPlayer() {
        #expect(BorderDetector.contentRect(picture(200, 120, fill: (0, 0, 0), content: inner)) == inner)
    }

    @Test func notOnlyBlack() {
        for fill: (UInt8, UInt8, UInt8) in [(255, 255, 255), (240, 240, 240), (20, 140, 60), (128, 0, 128)] {
            #expect(BorderDetector.contentRect(picture(200, 120, fill: fill, content: inner)) == inner, "\(fill)")
        }
    }

    @Test func jpegNoiseStillCountsAsPlain() {
        #expect(BorderDetector.contentRect(picture(200, 120, fill: (0, 0, 0), content: inner, noise: 10)) == inner)
    }

    @Test func aHairlineAroundAMargin() {
        // A 2-px grey outline, then a white margin, then the picture: both go.
        let b = picture(200, 120, fill: (128, 128, 128), content: inner,
                        bands: [(PixelRect(x: 2, y: 2, width: 196, height: 116), (255, 255, 255))])
        #expect(BorderDetector.contentRect(b) == inner)
    }

    @Test func aCaptionBarsPaddingIsPicture() {
        // White margin, then the meme's own black caption bar (plain at first, then text): only the margin goes.
        let caption = PixelRect(x: 20, y: 20, width: 160, height: 30)
        let b = picture(200, 140, fill: (255, 255, 255), content: PixelRect(x: 20, y: 40, width: 160, height: 80),
                        bands: [(caption, (0, 0, 0))])
        #expect(BorderDetector.contentRect(b) == PixelRect(x: 20, y: 20, width: 160, height: 100))
    }

    @Test func onlySomeSides() {
        let r = PixelRect(x: 0, y: 25, width: 200, height: 70)            // letterbox: top and bottom only
        #expect(BorderDetector.contentRect(picture(200, 120, fill: (0, 0, 0), content: r)) == r)
        let l = PixelRect(x: 0, y: 0, width: 150, height: 120)            // one side
        #expect(BorderDetector.contentRect(picture(200, 120, fill: (255, 255, 255), content: l)) == l)
    }

    /// Old VHS, upscaled: black bars with noise that fade into the picture over a few pixels (a halo),
    /// as in a real clip that only lost its left bar before.
    @Test func noisyBarsWithASoftEdge() {
        let w = 240, h = 160
        var px = [UInt8](repeating: 255, count: w * h * 4)
        var seed: UInt64 = 3
        func noise(_ a: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1; return Int(seed >> 33) % (2 * a + 1) - a }
        for y in 0..<h { for x in 0..<w {
            // 20-px bars left and right: 16 ± 3, then a 6-px fade up to the picture (a busy texture).
            let fromEdge = min(x, w - 1 - x)
            let picture = 60 + ((x / 4 + y / 4) % 2) * 120 + noise(20)
            let v: Int
            if fromEdge < 20 { v = 16 + noise(3) }
            else if fromEdge < 26 { let k = Double(fromEdge - 19) / 7; v = Int(16 * (1 - k) + Double(picture) * k * 0.5) + noise(4) }
            else { v = picture }
            let i = (y * w + x) * 4
            px[i] = UInt8(clamping: v); px[i + 1] = UInt8(clamping: v); px[i + 2] = UInt8(clamping: v)
        } }
        let r = BorderDetector.contentRect(Bitmap(width: w, height: h, rgba: Data(px)))
        #expect(r != nil)
        if let r {
            #expect((20...26).contains(r.x) && (20...26).contains(w - r.x - r.width), "\(r)")
            #expect(r.y == 0 && r.height == h)
        }
    }

    @Test func nothingToCut() {
        let full = PixelRect(x: 0, y: 0, width: 200, height: 120)
        #expect(BorderDetector.contentRect(picture(200, 120, fill: (0, 0, 0), content: full)) == nil)
        // All one colour: no picture to find.
        #expect(BorderDetector.contentRect(picture(200, 120, fill: (9, 9, 9), content: PixelRect(x: 0, y: 0, width: 0, height: 0))) == nil)
        // Too small to judge.
        #expect(BorderDetector.contentRect(picture(6, 6, fill: (0, 0, 0), content: PixelRect(x: 2, y: 2, width: 2, height: 2))) == nil)
    }

    @Test func aGradientIsPictureNotFrame() {
        // A sky fading a shade per line must not be eaten band by band.
        var px = [UInt8](repeating: 255, count: 100 * 100 * 4)
        for y in 0..<100 { for x in 0..<100 { let i = (y * 100 + x) * 4; px[i] = UInt8(y * 2); px[i + 1] = UInt8(100 + y); px[i + 2] = 250 } }
        let b = Bitmap(width: 100, height: 100, rgba: Data(px))
        let r = BorderDetector.contentRect(b)
        #expect(r == nil || r!.height >= 80)
    }

    @Test func neverMoreThanAlmostHalfASide() {
        // A tiny picture in a huge margin: limited to 45% per side, so the walk gives up rather than guess.
        let b = picture(200, 200, fill: (255, 255, 255), content: PixelRect(x: 98, y: 98, width: 4, height: 4))
        let r = BorderDetector.contentRect(b)
        #expect(r == nil || (r!.width >= 20 && r!.height >= 20))
    }

    @Test func transparentMarginsCountAsWhite() {
        var b = picture(100, 80, fill: (0, 0, 0), content: PixelRect(x: 20, y: 10, width: 60, height: 60))
        var px = [UInt8](b.rgba)
        for y in 0..<80 { for x in 0..<100 where !(20..<80).contains(x) || !(10..<70).contains(y) { px[(y * 100 + x) * 4 + 3] = 0 } }
        b = Bitmap(width: 100, height: 80, rgba: Data(px))
        #expect(BorderDetector.contentRect(b) == PixelRect(x: 20, y: 10, width: 60, height: 60))
    }

    @Test func videoFramesUnite() {
        // One scene fills the frame more than another: the crop keeps what any of them shows.
        let a = picture(200, 120, fill: (0, 0, 0), content: PixelRect(x: 30, y: 20, width: 140, height: 80))
        let b = picture(200, 120, fill: (0, 0, 0), content: PixelRect(x: 20, y: 30, width: 120, height: 70))
        let fade = picture(200, 120, fill: (0, 0, 0), content: PixelRect(x: 0, y: 0, width: 0, height: 0))
        #expect(BorderDetector.contentRect(frames: [a, fade, b]) == PixelRect(x: 20, y: 20, width: 150, height: 80))
        #expect(BorderDetector.contentRect(frames: [fade, fade]) == nil)
        #expect(BorderDetector.contentRect(frames: []) == nil)
    }
}

@Suite struct EditGeometryTests {
    @Test func rectangles() {
        let r = PixelRect(x: 3, y: 5, width: 11, height: 7)
        #expect(r.evened == PixelRect(x: 4, y: 6, width: 10, height: 6))
        #expect(PixelRect(x: -5, y: 90, width: 500, height: 50).clamped(width: 100, height: 100) == PixelRect(x: 0, y: 90, width: 100, height: 10))
        #expect(PixelRect(x: 10, y: 10, width: 20, height: 20).scaled(2) == PixelRect(x: 20, y: 20, width: 40, height: 40))
        let b = Bitmap(width: 4, height: 3, rgba: Data((0..<48).map { UInt8($0) }))
        let c = b.cropped(to: PixelRect(x: 1, y: 1, width: 2, height: 2))
        #expect(c.width == 2 && c.height == 2 && [UInt8](c.rgba)[0] == 20 && [UInt8](c.rgba)[8] == 36)
    }

    @Test func editsStoreAndCompare() throws {
        let e = MediaEdit(crop: PixelRect(x: 1, y: 2, width: 3, height: 4), trim: TimeRange(startMs: 100, endMs: 900))
        #expect(MediaEdit.decode(e.json) == e)
        #expect(MediaEdit().isEmpty && !e.isEmpty)
        #expect(MediaEdit.decode("garbage") == nil && MediaEdit.decode(nil) == nil)
        #expect(TimeRange(startMs: 100, endMs: 900).durationMs == 800)
    }
}

@Suite struct SilenceDetectorTests {
    let rate = 8000
    func tone(_ ms: Int, amplitude: Double) -> [Int16] {
        (0..<(rate * ms / 1000)).map { Int16(amplitude * 32767 * sin(Double($0) * 2 * .pi * 440 / Double(rate))) }
    }
    func quiet(_ ms: Int, hiss: Double = 0) -> [Int16] {
        var seed: UInt64 = 7
        return (0..<(rate * ms / 1000)).map { _ in seed = seed &* 6364136223846793005 &+ 1; return Int16(hiss * 32767 * (Double(seed >> 40) / Double(1 << 24) - 0.5)) }
    }

    @Test func quietEndsAreFound() throws {
        let s = quiet(1500) + tone(2000, amplitude: 0.5) + quiet(1000)
        let r = try #require(SilenceDetector.soundRange(s, rate: rate))
        #expect(abs(r.startMs - 1500) <= 100 && r.startMs <= 1500)       // a little air before it
        #expect(abs(r.endMs - 3500) <= 200 && r.endMs >= 3500)           // and after
    }

    @Test func roomHissIsQuietToo() throws {
        let s = quiet(1000, hiss: 0.003) + tone(1000, amplitude: 0.3) + quiet(1000, hiss: 0.003)
        let r = try #require(SilenceDetector.soundRange(s, rate: rate))
        #expect(r.startMs >= 850 && r.endMs <= 2200)
    }

    @Test func quietRecordingsAreJudgedAgainstThemselves() throws {
        // A whisper: −30 dB under its own peak counts, not an absolute level.
        let s = quiet(800) + tone(1000, amplitude: 0.02) + quiet(800)
        let r = try #require(SilenceDetector.soundRange(s, rate: rate))
        #expect(r.startMs >= 650 && r.endMs <= 2000)
    }

    @Test func nothingToCut() {
        #expect(SilenceDetector.soundRange(tone(2000, amplitude: 0.5), rate: rate) == nil)       // sound all the way
        #expect(SilenceDetector.soundRange(quiet(2000), rate: rate) == nil)                      // no sound at all
        #expect(SilenceDetector.soundRange([], rate: rate) == nil)
        #expect(SilenceDetector.soundRange(quiet(60) + tone(1000, amplitude: 0.5), rate: rate) == nil)   // < 0.1 s to gain
    }

    @Test func waveformPeaks() {
        let p = SilenceDetector.peaks(quiet(500) + tone(500, amplitude: 0.8), count: 10)
        #expect(p.count == 10 && p[0] < 0.01 && p[9] > 0.7)
        #expect(SilenceDetector.peaks([], count: 10).isEmpty)
    }
}
