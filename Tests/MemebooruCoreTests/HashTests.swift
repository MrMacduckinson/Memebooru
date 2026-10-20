import Foundation
import Testing
@testable import MemebooruCore

@Suite struct HashTests {
    /// Deterministic synthetic image: smooth gradient + a few blobs, so hashes are non-trivial.
    private func synthetic(seed: Int, noise: Float = 0, w: Int = 200, h: Int = 150) -> GrayImage {
        var rng = UInt64(seed &* 2654435761 + 12345)
        func rand() -> Float { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return Float(rng % 1000) / 1000 }
        var px = [Float](repeating: 0, count: w * h)
        // blobs in normalized coords so the same seed at another size is the same picture
        let blobs = (0..<5).map { _ in (x: rand(), y: rand(), r: 0.08 + rand() * 0.15) }
        for y in 0..<h { for x in 0..<w {
            let nx = Float(x) / Float(w), ny = Float(y) / Float(h)
            var v = nx * 180 + ny * 60
            for b in blobs where hypot(nx - b.x, ny - b.y) < b.r { v = 255 - v }
            if noise > 0 { v += (rand() - 0.5) * noise }
            px[y * w + x] = max(0, min(255, v))
        } }
        return GrayImage(width: w, height: h, pixels: px)
    }

    @Test func similarImagesAreClose_differentAreFar() {
        let a = synthetic(seed: 1)
        let aNoisy = synthetic(seed: 1, noise: 40)
        let aScaled = synthetic(seed: 1, w: 97, h: 73)
        let b = synthetic(seed: 2)
        #expect(PerceptualHash.hamming(PerceptualHash.pHash(a), PerceptualHash.pHash(aNoisy)) <= 6)
        #expect(PerceptualHash.hamming(PerceptualHash.pHash(a), PerceptualHash.pHash(aScaled)) <= 6)
        #expect(PerceptualHash.hamming(PerceptualHash.pHash(a), PerceptualHash.pHash(b)) >= 16)
        #expect(PerceptualHash.hamming(PerceptualHash.dHash(a), PerceptualHash.dHash(aNoisy)) <= 8)
        #expect(PerceptualHash.hamming(PerceptualHash.dHash(a), PerceptualHash.dHash(b)) >= 12)
    }

    @Test func int64RoundTrip() {
        let h: UInt64 = 0xF000_0000_0000_0001
        #expect(PerceptualHash.fromInt64(PerceptualHash.toInt64(h)) == h)
    }

    @Test func bkTreeFindsWithinRadius() {
        var tree = BKTree<String>()
        let base = PerceptualHash.pHash(synthetic(seed: 1))
        tree.insert(base, "a")
        tree.insert(base ^ 0b111, "a3")                  // distance 3
        tree.insert(PerceptualHash.pHash(synthetic(seed: 2)), "b")
        tree.insert(PerceptualHash.pHash(synthetic(seed: 3)), "c")
        let hits = tree.search(base, radius: 4).map(\.payload).sorted()
        #expect(hits == ["a", "a3"])
        #expect(tree.count == 4)
    }

    @Test func simhashOfNearTextsIsClose() {
        let a = TextHash.simhash("Сталин обедает с ребёнком, плакат СССР, вилка и ложка на столе")
        let b = TextHash.simhash("Сталин обедает с ребенком, плакат СССР, вилка и ложка на столе!")
        let c = TextHash.simhash("Совершенно другой текст про котов и собак в парке")
        #expect(PerceptualHash.hamming(a, b) <= 10)
        #expect(PerceptualHash.hamming(a, c) >= 16)
        #expect(TextHash.simhash("") == 0)
    }
}
