import Foundation
import Testing
@testable import MemebooruCore

@Suite struct MediaStoreTests {
    @Test func contentAddressedPutIsIdempotent() throws {
        let t = try TempCollection()
        let store = t.collection.media
        let src = t.url.appendingPathComponent("in.JPEG")
        try Data("abc".utf8).write(to: src)
        let first = try store.put(src)
        let second = try store.put(src)
        #expect(first.wasNew && !second.wasNew)
        #expect(first.ext == "jpg")
        #expect(first.sha256 == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(first.url.path.hasSuffix("/media/ba/\(first.sha256).jpg"))
        #expect(store.exists(sha256: first.sha256, ext: "jpg"))
        try store.remove(sha256: first.sha256, ext: "jpg")
        #expect(!store.exists(sha256: first.sha256, ext: "jpg"))
    }

    @Test func hlcIsMonotonicAndSortable() {
        let clock = HLCClock(device: "dev-a")
        let a = clock.now(), b = clock.now(), c = clock.now()
        #expect(a < b && b < c)
        #expect(a.description < b.description && b.description < c.description)
        #expect(HLC(string: b.description) == b)
        clock.observe(HLC(wall: c.wall + 100_000, counter: 3, device: "dev-b"))
        #expect(clock.now().wall >= c.wall + 100_000)
    }
}
