import Foundation
import Testing
@testable import MemebooruCore

private func tempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("mb-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func randomData(_ n: Int) -> Data {
    var rng = SystemRandomNumberGenerator()
    return Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) })
}

private final class Box<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ v: T) { value = v }
    func with<R>(_ body: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(&value) }
}

/// Content-addressed store: hashing, naming, put/move/remove round trips, races.
@Suite struct MediaStoreEdgeTests {
    static let emptySHA = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    @Test func hashingFilesAndDataAgree() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Empty, tiny, exactly one read chunk (1 MiB), one byte over, several chunks.
        for size in [0, 1, 1 << 20, (1 << 20) + 1, 3 * (1 << 20) + 12345] {
            let data = randomData(size)
            let url = dir.appendingPathComponent("f\(size)")
            try data.write(to: url)
            #expect(try MediaStore.sha256(of: url) == MediaStore.sha256(of: data), "size \(size)")
        }
        #expect(MediaStore.sha256(of: Data()) == Self.emptySHA)
        #expect(throws: (any Error).self) { try MediaStore.sha256(of: dir.appendingPathComponent("missing")) }
    }

    @Test func putCopyMoveAndRemoveRoundTrip() throws {
        let t = try TempCollection()
        let store = t.collection.media
        let fm = FileManager.default
        let data = randomData(4096)
        let sha = MediaStore.sha256(of: data)

        // Copy: the source stays; the stored file has the bytes, under media/<2>/<sha>.<ext>.
        let src = t.url.appendingPathComponent("Мем 😹 copy.PNG")
        try data.write(to: src)
        let a = try store.put(src)
        #expect(a.wasNew && a.sha256 == sha && a.ext == "png" && a.bytes == 4096)
        #expect(a.url == store.url(sha256: sha, ext: "png"))
        #expect(a.url.deletingLastPathComponent().lastPathComponent == String(sha.prefix(2)))
        let storedBytes = try Data(contentsOf: a.url)
        #expect(storedBytes == data && fm.fileExists(atPath: src.path))

        // Same bytes again under another name / as data: nothing new.
        let other = t.url.appendingPathComponent("other name.png")
        try data.write(to: other)
        #expect(try store.put(other).wasNew == false)
        #expect(try store.put(data: data, ext: "PNG") == StoredFile(sha256: sha, ext: "png", bytes: 4096, url: a.url, wasNew: false))

        // Move of an already-stored file: the source is still consumed.
        let moved = try store.put(other, move: true)
        #expect(!moved.wasNew && !fm.fileExists(atPath: other.path))

        // Move of a new file: renamed into place.
        let fresh = randomData(100)
        let src2 = t.url.appendingPathComponent("fresh.jpeg")
        try fresh.write(to: src2)
        let b = try store.put(src2, move: true)
        let movedBytes = try Data(contentsOf: b.url)
        #expect(b.wasNew && b.ext == "jpg" && !fm.fileExists(atPath: src2.path) && movedBytes == fresh)

        // The same content under another extension is a separate file (paths are sha + ext).
        let c = try store.put(data: data, ext: "webp")
        #expect(c.wasNew && c.url != a.url && store.exists(sha256: sha, ext: "png") && store.exists(sha256: sha, ext: "webp"))

        // Remove takes the thumbnail too; removing what isn't there is fine.
        try fm.createDirectory(at: store.thumbs, withIntermediateDirectories: true)
        try Data([0xFF, 0xD8]).write(to: store.thumbURL(sha256: sha))
        try store.remove(sha256: sha, ext: "png")
        #expect(!store.exists(sha256: sha, ext: "png") && !fm.fileExists(atPath: store.thumbURL(sha256: sha).path))
        #expect(store.exists(sha256: sha, ext: "webp"))
        try store.remove(sha256: sha, ext: "png")
        try store.remove(sha256: String(repeating: "0", count: 64), ext: "gif")
    }

    @Test func emptyAndExtensionlessFiles() throws {
        let t = try TempCollection()
        let store = t.collection.media
        let empty = t.url.appendingPathComponent("empty.gif")
        try Data().write(to: empty)
        let e = try store.put(empty)
        #expect(e.sha256 == Self.emptySHA && e.bytes == 0 && e.ext == "gif" && FileManager.default.fileExists(atPath: e.url.path))

        let noExt = t.url.appendingPathComponent("README")
        try Data("x".utf8).write(to: noExt)
        #expect(try store.put(noExt).ext == "bin")
        #expect(try store.put(noExt, ext: "TXT").ext == "txt")
        let dotted = t.url.appendingPathComponent(".hidden.Jpeg")
        try Data("y".utf8).write(to: dotted)
        #expect(try store.put(dotted).ext == "jpg")
        #expect(throws: (any Error).self) { try store.put(t.url.appendingPathComponent("missing.png")) }
    }

    /// Several writers storing the same new content at once (e.g. two duplicates committed together):
    /// every one succeeds, exactly one file results, and nobody sees it half-written.
    @Test(arguments: [false, true])
    func racingPutsOfTheSameContent(_ move: Bool) throws {
        let t = try TempCollection()
        let store = t.collection.media
        let data = randomData(2 << 20)
        let sha = MediaStore.sha256(of: data)
        let n = 16
        let sources = try (0..<n).map { i -> URL in
            let u = t.url.appendingPathComponent("src-\(i).mp4")
            try data.write(to: u)
            return u
        }
        let outcomes = Box([Result<StoredFile, any Error>]())
        DispatchQueue.concurrentPerform(iterations: n) { i in
            let r = Result { try store.put(sources[i], move: move) }
            outcomes.with { $0.append(r) }
        }
        let all = outcomes.with { $0 }
        let failures = all.compactMap { if case .failure(let e) = $0 { "\(e)" } else { nil } }
        #expect(failures.isEmpty, "\(failures)")
        let stored = all.compactMap { try? $0.get() }
        // A rename may replace an identical file a racing writer just placed, so more than one can
        // report `wasNew` — harmless (same bytes, and nothing reads the flag); at least one must.
        #expect(stored.filter(\.wasNew).count >= 1)
        #expect(Set(stored.map(\.url)) == [store.url(sha256: sha, ext: "mp4")])
        #expect(try MediaStore.sha256(of: store.url(sha256: sha, ext: "mp4")) == sha)
        let dir = store.url(sha256: sha, ext: "mp4").deletingLastPathComponent()
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["\(sha).mp4"], "temporary files left behind")
        if move { #expect(sources.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }) }
    }

    @Test func fileNamesFitNameMax() {
        #expect(MediaStore.fileName("meme", ext: "png") == "meme.png")
        #expect(MediaStore.fileName("meme", ext: "") == "meme")
        for base in [String(repeating: "n", count: 300), String(repeating: "я", count: 200), String(repeating: "👨‍👩‍👧", count: 40),
                     String(repeating: "e\u{301}", count: 150)] {
            for ext in ["jpg", "webm", ""] {
                let name = MediaStore.fileName(base, ext: ext)
                #expect(name.utf8.count <= 255, "\(name.utf8.count) bytes")
                #expect(name.utf8.count > 255 - 20, "trimmed too much: \(name.utf8.count)")
                #expect(ext.isEmpty || name.hasSuffix("." + ext))
                #expect(base.hasPrefix(ext.isEmpty ? name : String(name.dropLast(ext.count + 1))), "cut inside a character")
            }
        }
    }
}

/// Extension → kind/mime, and the format policy tables, including odd spellings.
@Suite struct MediaTypePolicyTests {
    @Test func detectionIgnoresCaseAndNormalises() {
        for (ext, kind) in [("JPG", MemeKind.image), ("Jpeg", .image), ("PNG", .image), ("HEIC", .image), ("Svg", .image), ("AVIF", .image),
                            ("JXL", .image), ("TIF", .image), ("GIF", .gif), ("MP4", .video), ("MoV", .video), ("WEBM", .video),
                            ("M4V", .video), ("MKV", .video), ("AVI", .video), ("MP3", .audio), ("M4A", .audio), ("OGG", .audio),
                            ("OGA", .audio), ("OPUS", .audio), ("FLAC", .audio), ("WAV", .audio), ("AAC", .audio), ("TXT", .text), ("MD", .text)] {
            #expect(MediaType.detect(ext: ext)?.kind == kind, "\(ext)")
            #expect(MediaType.detect(url: URL(fileURLWithPath: "/tmp/x.\(ext)"))?.kind == kind)
        }
        #expect(MediaType.detect(ext: "JPEG")?.mime == "image/jpeg")
        // Unknown, empty and "almost" extensions.
        for ext in ["", "bin", "xyz", "jpg ", "jpgx", "mp4.", "exe", "html", "zip", "pdf"] { #expect(MediaType.detect(ext: ext) == nil, "\(ext)") }
        #expect(MediaType.detect(url: URL(fileURLWithPath: "/tmp/noext")) == nil)
        #expect(MediaType.detect(url: URL(fileURLWithPath: "/tmp/a.png.jpg"))?.mime == "image/jpeg")
        #expect(MediaType.detect(url: URL(fileURLWithPath: "/tmp/.hidden.mp4"))?.kind == .video)
        #expect(MediaType.supportedExtensions.isSuperset(of: ["jpg", "png", "gif", "mp4", "webm", "svg", "mp3", "flac"]))
        #expect(MediaStore.normalizeExt("JPEG") == "jpg" && MediaStore.normalizeExt("") == "bin" && MediaStore.normalizeExt("TiF") == "tif")
        for mime in Set(MediaType.table.values.map(\.1)) {
            let ext = MediaType.ext(forMime: mime)
            #expect(ext.flatMap { MediaType.detect(ext: $0)?.mime } == mime, "\(mime)")
        }
        #expect(MediaType.ext(forMime: "application/x-nope") == nil)
    }

    @Test func probeCodecsRoundTrip() {
        let cases = [MediaProbe(container: "mp4", video: "h264", audio: "aac"),
                     MediaProbe(container: "png", video: "png", hasAlpha: true),
                     MediaProbe(container: nil, video: nil, audio: "opus"),
                     MediaProbe(container: "webm", video: "vp9", audio: nil, hasAlpha: true)]
        for p in cases {
            let back = MediaProbe(codecs: p.codecs)
            #expect(back?.container == p.container && back?.video == p.video && back?.audio == p.audio && back?.hasAlpha == p.hasAlpha, "\(p.codecs)")
        }
        #expect(MediaProbe(codecs: "?/-/-")?.container == nil)
        for bad in [nil, "", "mp4", "mp4/h264", "a/b/c/d", "+a"] as [String?] { #expect(MediaProbe(codecs: bad) == nil, "\(String(describing: bad))") }
    }

    @Test func compatibilityIsCaseInsensitiveAndCodecAware() {
        let c = FormatPolicy.compatibility
        #expect(c(.image, "JPG", nil) == .popular && c(.image, "Jpeg", nil) == .popular && c(.image, "PNG", nil) == .popular)
        #expect(c(.image, "WEBP", "webp/webp/-+a") == .popular)
        for ext in ["heic", "heif", "avif", "jxl", "bmp", "tif", "tiff", "svg", "ico", "bin", "gif"] { #expect(c(.image, ext, nil) == .uncommon, "\(ext)") }
        #expect(c(.video, "MP4", "mp4/h264/aac") == .popular && c(.video, "m4v", "m4v/h264/aac") == .popular)
        #expect(c(.video, "mp4", "mp4/h264/mp3") == .popular && c(.video, "mp4", "mp4/h264/-") == .popular)
        #expect(c(.video, "mp4", nil) == .popular)                                  // not probed: trusted by extension
        #expect(c(.video, "mp4", "mp4/hevc/aac") == .uncommon && c(.video, "mp4", "mp4/vp9/opus") == .uncommon)
        #expect(c(.video, "mp4", "mp4/gif/-") == .uncommon)                         // a GIF named .mp4
        for ext in ["mov", "webm", "mkv", "avi", "flv", "ts", "3gp", "bin"] { #expect(c(.video, ext, "\(ext)/h264/aac") == .uncommon, "\(ext)") }
        #expect(c(.gif, "GIF", nil) == .popular && c(.gif, "mp4", "mp4/h264/-") == .popular && c(.gif, "mp4", "mp4/vp9/-") == .uncommon)
        #expect(c(.gif, "webp", nil) == .uncommon)
        #expect(c(.audio, "MP3", nil) == .popular && c(.audio, "m4a", "m4a/-/aac") == .popular && c(.audio, "aac", "aac/-/aac") == .popular)
        #expect(c(.audio, "m4a", "m4a/-/alac") == .uncommon)
        for ext in ["ogg", "oga", "opus", "flac", "wav", "aiff", "amr", "wma"] { #expect(c(.audio, ext, nil) == .uncommon, "\(ext)") }
        for k in [MemeKind.text, .article, .tweet] { #expect(c(k, "whatever", nil) == .popular) }
    }

    @Test func popularTargets() {
        let t = FormatPolicy.popularTarget
        #expect(t(.image, "HEIC", "heic/hevc/-") == .jpeg && t(.image, "heic", "heic/hevc/-+a") == .png)
        #expect(t(.image, "avif", "avif/av1/-") == .jpeg && t(.image, "AVIF", "avif/av1/-+a") == .png)
        for ext in ["png", "bmp", "tif", "TIFF", "svg", "gif"] { #expect(t(.image, ext, nil) == .png, "\(ext)") }
        for ext in ["jxl", "bin", "ico", "tga"] { #expect(t(.image, ext, nil) == .jpeg, "\(ext)") }
        #expect(t(.gif, "webp", nil) == .gif && t(.video, "mkv", nil) == .mp4H264 && t(.audio, "flac", nil) == .mp3)
        for k in [MemeKind.text, .article, .tweet] { #expect(t(k, "x", nil) == nil) }
        // Every target is itself popular for the kind, and is something MediaType reads back.
        for kind in [MemeKind.image, .gif, .video, .audio] {
            let target = t(kind, "x", nil)!
            #expect(target.isPopular)
            #expect(FormatPolicy.compatibility(kind: kind, ext: target.ext, codecs: nil) == .popular, "\(kind) → \(target)")
        }
    }

    @Test func labels() {
        let l = FormatPolicy.label
        #expect(l("MKV", "mkv/av1/opus") == "MKV · AV1 · Opus" && l("webm", "webm/vp8/vorbis") == "WebM · VP8 · Vorbis")
        #expect(l("jpg", "jpg/mjpeg/-") == "JPEG" && l("JPEG", nil) == "JPEG" && l("png", "png/png/-+a") == "PNG" && l("svg", nil) == "SVG")
        #expect(l("avi", "avi/mpeg4/pcm_s16le") == "AVI · MPEG-4 · PCM" && l("mov", "mov/prores/-") == "MOV · ProRes")
        #expect(l("xyz", nil) == "XYZ" && l("flv", "flv/flv1/mp3") == "FLV · Sorenson H.263 · MP3" && l("3gp", "mov,mp4/h263/amr_nb") == "3GP · H.263 · AMR" && l("mp4", "mp4/-/aac") == "MP4 · AAC")
        #expect(l("", nil) == "")
    }

    @Test func exportFormatsAreReimportable() {
        for f in MediaFormat.allCases {
            let kind = MediaType.detect(ext: f.ext)?.kind
            #expect(kind != nil, "\(f.label) writes .\(f.ext), which import doesn't know")
            #expect(f.matches(ext: f.ext.uppercased(), codecs: Self.typical(f)), "\(f.label) doesn't match its own output")
        }
        let groups: [MemeKind: MediaFormat.Group] = [.image: .still, .gif: .animation, .video: .video, .audio: .audio]
        for (kind, group) in groups {
            for f in FormatPolicy.exportFormats(kind: kind) where f.isPopular && f.group == group {
                #expect(FormatPolicy.compatibility(kind: kind, ext: f.ext, codecs: Self.typical(f)) == .popular,
                        "\(kind): popular format \(f.label) is classed uncommon")
            }
        }
        #expect(MediaFormat.tiff.matches(ext: "TIF", codecs: nil) && MediaFormat.jpeg.matches(ext: "Jpeg", codecs: nil))
        #expect(!MediaFormat.mp4H264.matches(ext: "mov", codecs: "mov/h264/aac") && MediaFormat.movH264.matches(ext: "MOV", codecs: "mov/h264/aac"))
        // MP4 · H.264 · MP3 counts as popular (stored as is), but isn't "MP4 · H.264" to the exporter, so
        // exporting it as MP4 · H.264 re-encodes instead of copying.
        withKnownIssue("compatibility and MediaFormat.mp4H264 disagree about MP3 audio in MP4") {
            #expect(MediaFormat.mp4H264.matches(ext: "mp4", codecs: "mp4/h264/mp3"))
        }
    }

    static func typical(_ f: MediaFormat) -> String? {
        switch f {
        case .mp4H264: "mp4/h264/aac"
        case .mp4HEVC: "mp4/hevc/aac"
        case .movH264: "mov/h264/aac"
        case .webmVP9: "webm/vp9/opus"
        case .mkvH264: "mkv/h264/opus"
        case .m4a: "m4a/-/aac"
        case .opus: "ogg/-/opus"
        case .mp3: "mp3/-/mp3"
        default: nil
        }
    }
}
