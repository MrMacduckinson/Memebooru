import Foundation
import Testing
@testable import MemebooruCore

/// Where the pictures of a combined meme go. Pure arithmetic, so it's the same everywhere.
@Suite struct CompositeLayoutTests {
    let wide = PixelSize(width: 1200, height: 600)     // 2:1
    let tall = PixelSize(width: 400, height: 800)      // 1:2
    let square = PixelSize(width: 500, height: 500)

    @Test func sideBySideSharesTheTallestHeight() {
        let g = CompositeLayout(.row).geometry(for: [wide, tall])
        // Height = the taller picture's 800; the wide one is scaled up to 1600 × 800.
        #expect(g.frames == [PixelRect(x: 0, y: 0, width: 1600, height: 800), PixelRect(x: 1600, y: 0, width: 400, height: 800)])
        #expect(g.width == 2000 && g.height == 800)
    }

    @Test func stackedSharesTheWidestWidth() {
        let g = CompositeLayout(.column).geometry(for: [wide, square])
        #expect(g.frames == [PixelRect(x: 0, y: 0, width: 1200, height: 600), PixelRect(x: 0, y: 600, width: 1200, height: 1200)])
        #expect(g.width == 1200 && g.height == 1800)
    }

    @Test func aChosenSizeIsKeptButNeverAboveTheLargest() {
        let small = CompositeLayout(.row, size: 400).geometry(for: [wide, tall])
        #expect(small.height == 400 && small.frames[0].width == 800 && small.frames[1].width == 200)
        let big = CompositeLayout(.row, size: 5000).geometry(for: [wide, tall])
        #expect(big.height == 800)                                   // capped at the tallest picture
        let tiny = CompositeLayout(.column, size: 1).geometry(for: [wide, tall])
        #expect(tiny.width == CompositeLayout.minSize)                 // not below the minimum
        #expect(CompositeLayout(.column).sizeRange(for: [wide, tall]) == 64...1200)
    }

    @Test func gapsSitBetweenPicturesOnly() {
        let g = CompositeLayout(.row, gap: 10).geometry(for: [square, square, square])
        #expect(g.frames.map(\.x) == [0, 510, 1020] && g.width == 1520)
        let c = CompositeLayout(.column, gap: 10).geometry(for: [square, square])
        #expect(c.frames[1].y == 510 && c.height == 1010)
    }

    @Test func gridRowsFillTheWidth() {
        // 2 × 2 of mixed shapes: every row exactly as wide as the whole, rows stacked.
        let g = CompositeLayout(.grid, columns: 2).geometry(for: [wide, tall, square, square])
        for row in [[0, 1], [2, 3]] {
            let f = row.map { g.frames[$0] }
            #expect(f.last!.x + f.last!.width == g.width)
            #expect(f[0].height == f[1].height && f[0].y == f[1].y)
        }
        #expect(g.frames[2].y == g.frames[0].y + g.frames[0].height)
        #expect(g.frames[3].y + g.frames[3].height == g.height)
        // Three in rows of two: the last one alone spans the width.
        let t = CompositeLayout(.grid, columns: 2).geometry(for: [square, square, square])
        #expect(t.frames[2].x == 0 && t.frames[2].width == t.width)
    }

    @Test func featureStackIsAsTallAsTheLead() {
        let g = CompositeLayout(.feature, gap: 6).geometry(for: [tall, wide, wide])
        let lead = g.frames[0], a = g.frames[1], b = g.frames[2]
        #expect(lead.x == 0 && lead.height == g.height)
        #expect(a.x == lead.width + 6 && a.width == b.width)
        #expect(a.y == 0 && b.y == a.height + 6)
        #expect(abs(b.y + b.height - g.height) <= 1)
        #expect(a.x + a.width == g.width)
    }

    @Test func picturesKeepTheirShape() {
        for arrangement in CompositeLayout.Arrangement.allCases {
            let sizes = [wide, tall, square, PixelSize(width: 333, height: 777), PixelSize(width: 1920, height: 1080)]
            let g = CompositeLayout(arrangement, columns: 3, gap: 4).geometry(for: sizes)
            for (f, s) in zip(g.frames, sizes) {
                let a = Double(f.width) / Double(f.height)
                #expect(abs(a - s.aspect) / s.aspect < 0.02, "\(arrangement) \(s)")
            }
            // Nothing overlaps, nothing sticks out.
            for (i, f) in g.frames.enumerated() {
                #expect(f.x >= 0 && f.y >= 0 && f.x + f.width <= g.width && f.y + f.height <= g.height, "\(arrangement)")
                for o in g.frames[(i + 1)...] {
                    let apart = f.x + f.width <= o.x || o.x + o.width <= f.x || f.y + f.height <= o.y || o.y + o.height <= f.y
                    #expect(apart, "\(arrangement) overlap")
                }
            }
        }
    }

    @Test func screenshotsStayFullSize() {
        // Three 16" MacBook screenshots side by side (10368 px wide) or stacked: nothing shrinks.
        let shot = PixelSize(width: 3456, height: 2234)
        let row = CompositeLayout(.row).geometry(for: [shot, shot, shot])
        #expect(row.width == 3 * 3456 && row.height == 2234)
        let column = CompositeLayout(.column).geometry(for: [shot, shot, shot])
        #expect(column.width == 3456 && column.height == 3 * 2234)
    }

    @Test func hugeResultsShrinkAsAWhole() {
        let poster = PixelSize(width: 6000, height: 9000)
        let g = CompositeLayout(.row).geometry(for: [poster, poster, poster])      // 18000 × 9000 = 162 MP
        #expect(g.width * g.height <= CompositeLayout.maxPixels)
        #expect(abs(Double(g.frames[0].width) / Double(g.frames[0].height) - poster.aspect) < 0.01)
        let strip = CompositeLayout(.row).geometry(for: Array(repeating: PixelSize(width: 4000, height: 200), count: 10))
        #expect(max(strip.width, strip.height) <= CompositeLayout.maxSide)          // a very long strip: the side limit
    }

    @Test func oddInputsDontCrash() {
        #expect(CompositeLayout(.row).geometry(for: []).frames.isEmpty)
        #expect(CompositeLayout(.grid, columns: 0).geometry(for: [square, square]).frames.count == 2)    // treated as 1
        #expect(CompositeLayout(.feature).geometry(for: [square]).width == 500)
        #expect(CompositeLayout(.row).geometry(for: [PixelSize(width: 0, height: 10), square]).frames.isEmpty)
        let sliver = CompositeLayout(.row).geometry(for: [PixelSize(width: 1, height: 4000), PixelSize(width: 4000, height: 1)])
        #expect(sliver.frames.allSatisfy { $0.width >= 1 && $0.height >= 1 })
    }

    @Test func suggestionsFollowTheShapes() {
        #expect(CompositeLayout.suggested(for: [tall, tall]).arrangement == .row)
        #expect(CompositeLayout.suggested(for: [wide, wide]).arrangement == .column)
        #expect(CompositeLayout.suggested(for: [square, square, square]).arrangement == .row)
        #expect(CompositeLayout.suggested(for: [square, square, square, square]) == CompositeLayout(.grid, columns: 2))
        #expect(CompositeLayout.suggested(for: Array(repeating: square, count: 7)) == CompositeLayout(.grid, columns: 3))
    }

    @Test func layoutsSurviveStorageAndOlderData() throws {
        let l = CompositeLayout(.feature, columns: 3, size: 900, gap: 12)
        let payload = MemePayload.composite(CompositePayload(layout: l))
        let json = try #require(try payload.encodeJSON())
        #expect(try MemePayload.decode(kind: .image, json: json) == payload)
        #expect(try MemePayload.decode(kind: .image, json: nil) == .none)
        // A layout saved by a version that knew fewer fields.
        #expect(try MemePayload.decode(kind: .image, json: #"{"layout":{"arrangement":"column"}}"#) == .composite(CompositePayload(layout: CompositeLayout(.column))))
        // Unknown arrangement from a newer version: falls back instead of losing the meme.
        #expect(try MemePayload.decode(kind: .image, json: #"{"layout":{"arrangement":"spiral"}}"#).composite?.layout.arrangement == .row)
        let data = try JSONEncoder().encode(payload)
        #expect(try JSONDecoder().decode(MemePayload.self, from: data) == payload)
    }
}
