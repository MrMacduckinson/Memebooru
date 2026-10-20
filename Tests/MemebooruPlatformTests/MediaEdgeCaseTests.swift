import Foundation
import Testing
import MemebooruCore
#if canImport(ImageIO)
import UniformTypeIdentifiers
#endif

/// Linux decodes pictures with stb, which ignores EXIF orientation: recorded as a known issue there.
private func onLinuxKnownIssue(_ comment: String, _ body: () throws -> Void) rethrows {
    try linuxKnownIssue(comment, body)
}

/// Base samples the edge cases are made from (all small, all made by ffmpeg).
private enum Base {
    static func png() throws -> URL { try MT.make("edge.png", ["-f", "lavfi", "-i", "testsrc2=s=160x90", "-frames:v", "1"]) }
    static func jpg() throws -> URL { try MT.make("edge.jpg", ["-f", "lavfi", "-i", "testsrc2=s=640x360", "-frames:v", "1", "-q:v", "3"]) }
    static func gif() throws -> URL { try MT.make("edge.gif", MT.pattern("120x80", seconds: 0.5, rate: 10)) }
    static func mp4() throws -> URL {
        try MT.make("edge.mp4", FormatCase.v1s + FormatCase.a1s + ["-c:v", FormatCase.h264, "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest"])
    }
    /// moov first: the first half alone is still a playable file.
    static func mp4Faststart() throws -> URL {
        try MT.make("edge-fs.mp4", MT.pattern("192x108", seconds: 2) + ["-c:v", FormatCase.h264, "-pix_fmt", "yuv420p", "-movflags", "+faststart"])
    }
    static func webm() throws -> URL { try MT.make("edge.webm", MT.pattern("192x108", seconds: 2) + ["-c:v", "libvpx-vp9", "-b:v", "300k"]) }
    static func mov() throws -> URL { try MT.make("edge.mov", FormatCase.v1s + ["-c:v", "prores_ks", "-profile:v", "0"]) }
    static func mp3() throws -> URL { try MT.make("edge.mp3", MT.tone(seconds: 2) + ["-c:a", "libmp3lame"]) }
    static func flac() throws -> URL { try MT.make("edge.flac", MT.tone(seconds: 2) + ["-c:a", "flac"]) }
    static func svg() throws -> URL {
        try MT.write(Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="200" height="100"><rect width="100" height="100" fill="red"/><rect x="100" width="100" height="100" fill="blue"/></svg>"#.utf8), as: "edge.svg")
    }

    static func sample(for ext: String) throws -> URL {
        switch ext.lowercased() {
        case "png": try png()
        case "jpg", "jpeg": try jpg()
        case "gif": try gif()
        case "mp4": try mp4()
        case "webm": try webm()
        case "mov": try mov()
        case "mp3": try mp3()
        case "flac": try flac()
        case "svg": try svg()
        default: throw CollectionError("no base sample for .\(ext)")
        }
    }
}

/// After a commit attempt: either a meme with a stored file, or nothing changed and the item still staged.
private func commitIsAtomic(_ c: Collection, _ s: StagingArea, _ item: StagedItem, convert: Bool? = nil,
                            sourceLocation: SourceLocation = #_sourceLocation) throws -> Meme? {
    let before = try c.memes.count()
    do {
        let meme = try s.commit(item.id, convert: convert)
        let p = try #require(try c.memes.primaryAsset(of: meme.id), sourceLocation: sourceLocation)
        #expect(c.media.exists(sha256: p.sha256, ext: p.ext), sourceLocation: sourceLocation)
        #expect(try s.get(item.id) == nil, sourceLocation: sourceLocation)
        return meme
    } catch {
        #expect(try c.memes.count() == before, "failed commit left a meme behind", sourceLocation: sourceLocation)
        #expect(try s.get(item.id) != nil, "failed commit lost the staged item: \(error)", sourceLocation: sourceLocation)
        #expect(FileManager.default.fileExists(atPath: s.fileURL(item).path), "failed commit lost the staged file", sourceLocation: sourceLocation)
        return nil
    }
}

@Suite(.serialized, .enabled(if: MT.hasFFmpeg && MT.h264 != nil)) struct MediaEdgeCaseTests {
    // MARK: - Empty, truncated, garbage

    @Test(arguments: ["jpg", "png", "gif", "webp", "heic", "avif", "svg", "mp4", "webm", "mov", "mp3", "flac", "ogg", "wav"])
    func zeroByteFile(_ ext: String) throws {
        let url = try MT.write(Data(), as: "empty.\(ext)")
        let kind = try #require(MediaType.detect(ext: ext)).kind
        let info = MT.analyzer.analyze(url, kind: kind)
        #expect(info.width == nil && info.height == nil && info.phash == nil && info.dhash == nil)
        #expect((info.durationMs ?? 0) == 0, "an empty file has no length: \(String(describing: info.durationMs))")
        if kind != .audio { #expect(throws: (any Error).self) { try MT.analyzer.thumbnail(url, kind: kind) } }

        // Staged as is (nothing to analyse). Converting it can only fail — then it stays in staging, intact.
        let c = try MT.collection()
        defer { try? FileManager.default.removeItem(at: c.url) }
        let s = StagingArea(collection: c, analyzer: MT.analyzer)
        let item = try s.add(file: url, source: "test")
        #expect(item.bytes == 0 && item.sha256 == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        if let meme = try commitIsAtomic(c, s, item) {
            let p = try #require(try c.memes.primaryAsset(of: meme.id))
            #expect(p.bytes == 0 && p.width == nil)
            #expect(!FileManager.default.fileExists(atPath: c.media.thumbURL(sha256: p.sha256).path), "thumbnail made from nothing")
        } else {
            #expect(item.willConvert)
            // Declining the conversion always works.
            _ = try #require(try commitIsAtomic(c, s, item, convert: false))
        }
    }

    @Test(arguments: ["png", "jpg", "gif", "mp4", "faststart.mp4", "webm", "mov", "mp3", "flac", "svg"])
    func truncatedFile(_ name: String) throws {
        let src = name == "faststart.mp4" ? try Base.mp4Faststart() : try Base.sample(for: name)
        let data = try Data(contentsOf: src)
        let ext = (name as NSString).pathExtension.isEmpty ? name : (name as NSString).pathExtension
        let url = try MT.write(data.prefix(data.count / 2), as: "half.\(ext)")
        let kind = try #require(MediaType.detect(url: url)).kind

        let clock = ContinuousClock()
        let took = try clock.measure {
            let info = MT.analyzer.analyze(url, kind: kind)
            if let w = info.width, let h = info.height { #expect(w > 0 && h > 0) }
            if let d = info.durationMs { #expect(d >= 0 && d < 10_000) }
            // A partial picture/frame is fine; a bogus one (wrong size, not a JPEG) is not.
            if let thumb = try? MT.analyzer.thumbnail(url, kind: kind) {
                try MT.checkThumbnail(thumb, displaySize: nil, "half \(name)")
            }
            let c = try MT.collection()
            defer { try? FileManager.default.removeItem(at: c.url) }
            let s = StagingArea(collection: c, analyzer: MT.analyzer)
            _ = try commitIsAtomic(c, s, try s.add(file: url, source: "test"))
        }
        #expect(took < .seconds(60), "truncated \(name) took \(took)")
    }

    /// A playable prefix keeps working: half a fast-start MP4 / WebM still has frames and a length.
    @Test(arguments: ["faststart.mp4", "webm"])
    func truncatedStreamableVideoStillThumbnails(_ name: String) throws {
        let src = name == "webm" ? try Base.webm() : try Base.mp4Faststart()
        let data = try Data(contentsOf: src)
        let url = try MT.write(data.prefix(data.count / 2), as: "half-play.\((name as NSString).pathExtension.isEmpty ? name : (name as NSString).pathExtension)")
        try MT.checkThumbnail(MT.analyzer.thumbnail(url, kind: .video), displaySize: (192, 108), "half \(name)")
    }

    @Test(arguments: ["png", "jpg", "gif", "webp", "svg", "mp4", "webm", "mp3", "flac"])
    func garbageBytes(_ ext: String) throws {
        var rng = SystemRandomNumberGenerator()
        let junk = Data((0..<8192).map { _ in UInt8.random(in: 0...255, using: &rng) })
        let url = try MT.write(junk, as: "junk.\(ext)")
        let kind = try #require(MediaType.detect(ext: ext)).kind
        let info = MT.analyzer.analyze(url, kind: kind)
        #expect(info.width == nil && info.phash == nil)
        if kind != .audio { #expect(throws: (any Error).self) { try MT.analyzer.thumbnail(url, kind: kind) } }
    }

    // MARK: - Names and extensions

    @Test(arguments: [
        "MEME.JPG", "Pic.Png", "CLIP.MP4", "Clip.WebM", "TONE.FLAC", "VECTOR.SVG", "anim.GIF",
        "meme.png.jpg", "clip.mp4.webm", "photo.final.FINAL.v2.png",
        "мем про кота 😹 (копия 2).png", "🙂🙃.mp4", "日本語のファイル名.webm", "e\u{301}clair.jpg",          // decomposed é
        "  spaces  in  name .png", "tab\tand\nnewline.jpg", "quote'\"dq.png", "semi;colon&amp=1.gif", "pct%20hash#q?.mp4",
        "-leading-dash.mp4", "file:colon.webm", "http:x.jpg", "[brackets] {braces} (parens).png", ".hidden.png",
        String(repeating: "я", count: 120) + ".png",                                               // 244 bytes
        String(repeating: "x", count: 250) + ".webm",                                              // 255 bytes, converted
    ])
    func oddFileName(_ name: String) throws {
        let ext = (name as NSString).pathExtension
        let url = try MT.copy(try Base.sample(for: ext), as: name)
        let detected = try #require(MediaType.detect(url: url), "not detected: \(name)")
        let kind = detected.kind

        let info = MT.analyzer.analyze(url, kind: kind)
        #expect(info.codecs != nil, "no probe for \(name)")
        if kind != .audio {
            #expect((info.width ?? 0) > 0 && info.phash != nil, "no size/hash for \(name)")
            try MT.checkThumbnail(MT.analyzer.thumbnail(url, kind: kind), displaySize: info.width.flatMap { w in info.height.map { (w, $0) } }, name)
        }

        let c = try MT.collection()
        defer { try? FileManager.default.removeItem(at: c.url) }
        let meme = try MT.commit(c, url)
        let (primary, original) = try c.formats(of: meme.id)
        let p = try #require(primary)
        #expect(p.ext == p.ext.lowercased() && !p.ext.isEmpty)
        #expect(c.media.exists(sha256: p.sha256, ext: p.ext))
        if p.sourceSHA256 == nil { #expect(p.originalName == name) }                // kept as is
        else {
            #expect(p.originalName?.hasPrefix((name as NSString).deletingPathExtension) == true)
            #expect((original != nil) == (ext.lowercased() == "svg"), "only SVG keeps its original by default")
        }
        if kind != .audio { #expect(FileManager.default.fileExists(atPath: c.media.thumbURL(sha256: p.sha256).path)) }
        #expect(p.compatibility(kind: kind) == .popular)
    }

    /// The longest names the file system allows, with no extension: converting must not overflow
    /// NAME_MAX when it appends the new extension.
    @Test func longestNameWithoutExtension() throws {
        let name = String(repeating: "n", count: 255)
        let url = try MT.copy(try Base.png(), as: name)
        #expect(MediaType.detect(url: url) == nil)
        let c = try MT.collection()
        defer { try? FileManager.default.removeItem(at: c.url) }
        let meme = try MT.commit(c, url, kind: .image)
        let p = try #require(try c.formats(of: meme.id).primary)
        #expect(p.ext == "jpg" && p.width == 160 && p.height == 90)
        let out = try MT.freshDir()
        let exported = try c.export(meme.id, as: .format(.png), to: out, analyzer: MT.analyzer)
        #expect(exported.lastPathComponent.utf8.count <= 255 && FileManager.default.fileExists(atPath: exported.path))
    }

    /// No extension: not picked up by itself, but works when the kind is given (content decides).
    @Test func noExtension() throws {
        let png = try MT.copy(try Base.png(), as: "picture")
        let mp4 = try MT.copy(try Base.mp4(), as: "clip")
        #expect(MediaType.detect(url: png) == nil && MediaStore.normalizeExt(png.pathExtension) == "bin")
        let c = try MT.collection()
        defer { try? FileManager.default.removeItem(at: c.url) }
        let s = StagingArea(collection: c, analyzer: MT.analyzer)
        #expect(throws: (any Error).self) { try s.add(file: png, source: "test") }
        let report = try FolderImporter(staging: s).importFiles([png])
        #expect(report.staged.isEmpty && report.skipped.count == 1)

        let pi = try s.add(file: png, source: "test", kind: .image)
        #expect(pi.ext == "bin" && pi.info.width == 160 && pi.info.height == 90 && pi.compatibility == .uncommon)
        let pm = try #require(try c.formats(of: s.commit(pi.id).id).primary)
        #expect(pm.ext == "jpg" && pm.width == 160)

        let vi = try s.add(file: mp4, source: "test", kind: .video)
        #expect(vi.info.width == 192 && (vi.info.durationMs ?? 0) > 800)
        let vm = try #require(try c.formats(of: s.commit(vi.id).id).primary)
        #expect(vm.ext == "mp4" && vm.compatibility(kind: .video) == .popular && vm.width == 192)
        #expect(FileManager.default.fileExists(atPath: c.media.thumbURL(sha256: vm.sha256).path))
    }

    /// Content in a file named for something else.
    @Test func wrongExtension() throws {
        let c = try MT.collection()
        defer { try? FileManager.default.removeItem(at: c.url) }
        let t = try #require(MT.platform.transcoder)

        // PNG named .jpg / JPEG named .png: decoders go by content; popular either way, kept as is.
        for (src, name, size) in [(try Base.png(), "png-really.jpg", (160, 90)), (try Base.jpg(), "jpeg-really.png", (640, 360))] {
            let url = try MT.copy(src, as: name)
            let info = MT.analyzer.analyze(url, kind: .image)
            #expect(info.width == size.0 && info.height == size.1 && info.phash != nil, "\(name)")
            try MT.checkThumbnail(MT.analyzer.thumbnail(url, kind: .image), displaySize: size, name)
            let p = try #require(try c.formats(of: MT.commit(c, url).id).primary)
            #expect(p.width == size.0)
        }

        // GIF named .mp4 / WebM named .mp4: the probe sees the real codec, so they're converted into real MP4s.
        for (src, name) in [(try Base.gif(), "gif-really.mp4"), (try Base.webm(), "webm-really.mp4")] {
            let url = try MT.copy(src, as: name)
            let item = try StagingArea(collection: c, analyzer: MT.analyzer).add(file: url, source: "test")
            #expect(item.kind == .video && item.compatibility == .uncommon, "\(name): \(item.info.codecs ?? "nil")")
            try MT.checkThumbnail(MT.analyzer.thumbnail(url, kind: .video), displaySize: nil, name)
            let p = try #require(try c.formats(of: StagingArea(collection: c, analyzer: MT.analyzer).commit(item.id).id).primary)
            let probe = try t.probe(c.media.url(sha256: p.sha256, ext: p.ext))
            #expect(p.ext == "mp4" && probe.video == "h264", "\(name) stored as \(probe.codecs)")
        }

        // MP4 named .gif: analysed and thumbnailed through ffmpeg…
        let fake = try MT.copy(try Base.mp4(), as: "mp4-really.gif")
        let info = MT.analyzer.analyze(fake, kind: .gif)
        #expect(info.width == 192 && info.height == 108 && info.phash != nil)
        try MT.checkThumbnail(MT.analyzer.thumbnail(fake, kind: .gif), displaySize: (192, 108), "mp4-really.gif")
        let p = try #require(try c.formats(of: MT.commit(c, fake).id).primary)
        // …but nothing sniffs content: ".gif" counts as popular, so an MP4 is stored and sent as a GIF.
        let stored = try t.probe(c.media.url(sha256: p.sha256, ext: p.ext))
        withKnownIssue("no content sniffing: an MP4 named .gif is stored as .gif without conversion") {
            #expect(stored.video == "gif", "stored .\(p.ext) holds \(stored.codecs)")
        }
    }

    @Test func hiddenAndUnsupportedFilesInAFolder() throws {
        let dir = try MT.freshDir()
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("sub/.git"), withIntermediateDirectories: true)
        try fm.copyItem(at: try Base.png(), to: dir.appendingPathComponent("a.png"))
        try fm.copyItem(at: try Base.png(), to: dir.appendingPathComponent(".hidden.png"))
        try fm.copyItem(at: try Base.jpg(), to: dir.appendingPathComponent("sub/B.JPG"))
        try fm.copyItem(at: try Base.png(), to: dir.appendingPathComponent("sub/.git/c.png"))
        try fm.copyItem(at: try Base.png(), to: dir.appendingPathComponent("noext"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("notes.xyz"))
        try Data().write(to: dir.appendingPathComponent("sub/.DS_Store"))

        let c = try MT.collection()
        defer { try? FileManager.default.removeItem(at: c.url) }
        let report = try FolderImporter(staging: StagingArea(collection: c, analyzer: MT.analyzer)).importFiles([dir])
        #expect(Set(report.staged.compactMap(\.originalName)) == ["a.png", "B.JPG"])
        #expect(Set(report.skipped.map { $0.0.lastPathComponent }) == ["noext", "notes.xyz"])
        #expect(report.skipped.allSatisfy { $0.1 == "unsupported" })
        #expect(report.staged.allSatisfy { ($0.info.width ?? 0) > 0 })
    }

    // MARK: - Geometry

    @Test(arguments: [(20000, 100), (100, 20000), (16000, 1), (1, 4000), (3840, 2160), (2, 2)])
    func extremeSizesKeepThumbnailsBounded(_ w: Int, _ h: Int) throws {
        // Made even-sized and cropped: older ffmpeg's colour source refuses 1-px sides.
        let src = try MT.make("size-\(w)x\(h).png", ["-f", "lavfi", "-i", "color=c=red:s=\(w + w % 2)x\(h + h % 2),format=rgb24,crop=\(w):\(h)", "-frames:v", "1"])
        let clock = ContinuousClock()
        var thumb: Data?
        let took = try clock.measure {
            let info = MT.analyzer.analyze(src, kind: .image)
            #expect(info.width == w && info.height == h)
            thumb = try MT.analyzer.thumbnail(src, kind: .image)
        }
        let b = try MT.checkThumbnail(thumb, displaySize: (w, h), "\(w)×\(h)")
        #expect(MT.isRed(MT.pixel(b, b.width / 2, b.height / 2)))
        #expect(took < .seconds(20), "\(w)×\(h) took \(took)")
    }

    /// Uncommon and huge: the conversion keeps the full size.
    @Test func hugeBMPConvertsAtFullSize() throws {
        let src = try MT.make("wide.bmp", ["-f", "lavfi", "-i", "testsrc2=s=12000x200", "-frames:v", "1", "-pix_fmt", "bgr24"])
        let c = try MT.collection()
        defer { try? FileManager.default.removeItem(at: c.url) }
        let p = try #require(try c.formats(of: MT.commit(c, src).id).primary)
        #expect(p.ext == "png" && p.width == 12000 && p.height == 200)
        try MT.checkThumbnail(Data(contentsOf: c.media.thumbURL(sha256: p.sha256)), displaySize: (12000, 200), "wide.bmp")
    }

    @Test(arguments: [(2048, 64), (64, 1024)])
    func panoramaVideo(_ w: Int, _ h: Int) throws {
        let src = try MT.make("pano-\(w)x\(h).webm", MT.pattern("\(w)x\(h)") + ["-c:v", "libvpx-vp9", "-b:v", "200k"])
        let info = MT.analyzer.analyze(src, kind: .video)
        #expect(info.width == w && info.height == h)
        try MT.checkThumbnail(MT.analyzer.thumbnail(src, kind: .video), displaySize: (w, h), "\(w)×\(h) video")
        let c = try MT.collection()
        defer { try? FileManager.default.removeItem(at: c.url) }
        let p = try #require(try c.formats(of: MT.commit(c, src).id).primary)
        #expect(p.ext == "mp4" && p.width == w && p.height == h)
    }

    // MARK: - Orientation

    /// EXIF orientation 6 (camera held upright): the stored pixels are landscape, the picture is portrait.
    @Test func exifRotatedJPEGIsPortrait() throws {
        let plain = try MT.platform.thumbs.jpeg(try MT.decode(try MT.redBluePNG(64, 32), ext: "png"), quality: 0.9)
        let url = try MT.write(MT.withEXIFOrientation(plain, 6), as: "rot6.jpg")
        let info = MT.analyzer.analyze(url, kind: .image)
        let thumb = try MT.analyzer.thumbnail(url, kind: .image)
        onLinuxKnownIssue("stb ignores EXIF orientation") {
            #expect(info.width == 32 && info.height == 64, "size \(String(describing: info.width))×\(String(describing: info.height))")
            guard let b = try? MT.checkThumbnail(thumb, displaySize: (32, 64), "rot6 thumbnail") else { return }
            // Rotated 90° clockwise for display: the stored left (red) half ends up on top.
            #expect(MT.isRed(MT.pixel(b, b.width / 2, b.height / 4)) && MT.isBlue(MT.pixel(b, b.width / 2, b.height * 3 / 4)),
                    "top \(MT.pixel(b, b.width / 2, b.height / 4)) bottom \(MT.pixel(b, b.width / 2, b.height * 3 / 4))")
        }

        // Popular: stored as is (EXIF and all), with the portrait size.
        let c = try MT.collection()
        defer { try? FileManager.default.removeItem(at: c.url) }
        let meme = try MT.commit(c, url)
        let p = try #require(try c.formats(of: meme.id).primary)
        let sha = try MediaStore.sha256(of: url)
        #expect(p.ext == "jpg" && p.sha256 == sha)

        // Exporting it to another format bakes the rotation in.
        let out = try MT.freshDir().appendingPathComponent("rot6.png")
        try c.export(meme.id, as: .format(.png), to: out, analyzer: MT.analyzer)
        let e = try MT.platform.images.decode(out, maxSide: 0)
        onLinuxKnownIssue("stb ignores EXIF orientation") {
            #expect(e.width == 32 && e.height == 64, "exported \(e.width)×\(e.height): rotation lost")
            #expect(MT.isRed(MT.pixel(e, 16, 8)), "exported top \(MT.pixel(e, 16, 8))")
        }
    }

    #if canImport(ImageIO)
    /// An iPhone HEIC shot upright (orientation 6) becomes an upright JPEG on import.
    @Test func rotatedHEICConvertsUpright() throws {
        let heic = try MT.imageIO(try MT.redBluePNG(64, 32), type: .heic, orientation: 6)
        let url = try MT.write(heic, as: "IMG_0001.HEIC")
        let info = MT.analyzer.analyze(url, kind: .image)
        #expect(info.width == 32 && info.height == 64)
        try MT.checkThumbnail(MT.analyzer.thumbnail(url, kind: .image), displaySize: (32, 64), "rotated HEIC")

        let c = try MT.collection()
        defer { try? FileManager.default.removeItem(at: c.url) }
        let p = try #require(try c.formats(of: MT.commit(c, url).id).primary)
        #expect(p.ext == "jpg")
        #expect(p.width == 32 && p.height == 64, "stored \(String(describing: p.width))×\(String(describing: p.height))")
        let stored = try MT.platform.images.decode(c.media.url(sha256: p.sha256, ext: p.ext), maxSide: 0)
        #expect(stored.width == 32 && stored.height == 64, "converted JPEG is \(stored.width)×\(stored.height): orientation dropped")
        #expect(MT.isRed(MT.pixel(stored, stored.width / 2, stored.height / 4)))
    }
    #endif

    /// A phone's portrait video: landscape frames + a 90° display matrix.
    @Test func rotatedVideoIsPortrait() throws {
        let plain = try MT.make("rot-src.mp4", FormatCase.v1s + FormatCase.a1s + ["-c:v", FormatCase.h264, "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest"])
        func rotated(_ name: String) throws -> URL {
            do { return try MT.make(name, ["-display_rotation", "90", "-i", plain.path, "-c", "copy"]) }       // ffmpeg ≥ 7
            catch { return try MT.make(name, ["-i", plain.path, "-c", "copy", "-metadata:s:v:0", "rotate=90"]) }
        }
        for name in ["rot90.mp4", "rot90.mov"] {
            let url = try rotated(name)
            let info = MT.analyzer.analyze(url, kind: .video)
            #expect(info.width == 108 && info.height == 192, "\(name): size \(String(describing: info.width))×\(String(describing: info.height))")
            try MT.checkThumbnail(MT.analyzer.thumbnail(url, kind: .video), displaySize: (108, 192), name)

            let c = try MT.collection()
            defer { try? FileManager.default.removeItem(at: c.url) }
            let meme = try MT.commit(c, url)
            let p = try #require(try c.formats(of: meme.id).primary)
            #expect(p.ext == "mp4" && p.width == 108 && p.height == 192, "\(name) stored \(String(describing: p.width))×\(String(describing: p.height))")
            let thumb = try Data(contentsOf: c.media.thumbURL(sha256: p.sha256))
            try MT.checkThumbnail(thumb, displaySize: (108, 192), "stored \(name)")
            // Exported as WebM (re-encoded): rotation applied to the pixels.
            let out = try MT.freshDir().appendingPathComponent("r.webm")
            let webm = try c.export(meme.id, as: .format(.webmVP9), to: out, analyzer: MT.analyzer)
            let wp = try #require(MT.platform.transcoder).probe(webm)
            #expect(wp.width == 108 && wp.height == 192, "exported webm \(String(describing: wp.width))×\(String(describing: wp.height))")
        }
    }

    // MARK: - SVG

    @Test(arguments: [
        ("viewbox-only", #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 300 150"><rect width="300" height="150" fill="red"/></svg>"#, (300, 150)),
        ("size-only", #"<svg xmlns="http://www.w3.org/2000/svg" width="120" height="60"><rect width="120" height="60" fill="red"/></svg>"#, (120, 60)),
        ("tiny", #"<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1" viewBox="0 0 1 1"><rect width="1" height="1" fill="red"/></svg>"#, (1, 1)),
        ("huge", #"<svg xmlns="http://www.w3.org/2000/svg" width="100000" height="50000" viewBox="0 0 2 1"><rect width="2" height="1" fill="red"/></svg>"#, (100000, 50000)),
        ("prolog", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"no\"?>\n<!DOCTYPE svg PUBLIC \"-//W3C//DTD SVG 1.1//EN\" \"http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd\">\n<!-- made by hand -->\n<svg xmlns=\"http://www.w3.org/2000/svg\" version=\"1.1\" width=\"80\" height=\"40\"><rect width=\"80\" height=\"40\" fill=\"red\"/></svg>", (80, 40)),
        ("bom", "\u{FEFF}<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"50\" height=\"100\"><rect width=\"50\" height=\"100\" fill=\"red\"/></svg>", (50, 100)),
    ] as [(String, String, (Int, Int))])
    func svgVariant(_ name: String, _ xml: String, _ size: (Int, Int)) throws {
        let url = try MT.write(Data(xml.utf8), as: "\(name).svg")
        let clock = ContinuousClock()
        var thumb: Data?
        var info = MediaInfo()
        let took = try clock.measure {
            info = MT.analyzer.analyze(url, kind: .image)
            thumb = try MT.analyzer.thumbnail(url, kind: .image)
        }
        let check = {
            #expect(info.width == size.0 && info.height == size.1, "\(name): \(String(describing: info.width))×\(String(describing: info.height))")
        }
        // rsvg-convert renders the whole picture just to measure it: a 100000×50000 SVG is beyond cairo.
        if name == "huge" { onLinuxKnownIssue("Linux measures an SVG by rasterising it at full size", check) } else { check() }
        let b = try MT.checkThumbnail(thumb, displaySize: size, "\(name).svg")
        #expect(MT.isRed(MT.pixel(b, b.width / 2, b.height / 2)))
        #expect(took < .seconds(20), "\(name).svg took \(took)")

        // Import: PNG + the vector kept (or, if the picture can't be rasterised whole, still staged and storable as SVG).
        let c = try MT.collection()
        defer { try? FileManager.default.removeItem(at: c.url) }
        let s = StagingArea(collection: c, analyzer: MT.analyzer)
        let item = try s.add(file: url, source: "test")
        if let meme = try commitIsAtomic(c, s, item) {
            let (p, o) = try c.formats(of: meme.id)
            #expect(p?.ext == "png" && o?.ext == "svg")
            #expect(max(p?.width ?? 0, p?.height ?? 0) <= MediaConverter.maxVectorSide, "\(name): rasterised at \(String(describing: p?.width))×\(String(describing: p?.height))")
        } else {
            let record = { () -> Void in _ = Issue.record("\(name).svg: converting to PNG failed") }
            if name == "huge" { onLinuxKnownIssue("rsvg-convert can't render a 100000-px SVG to measure or convert it", record) } else { record() }
            _ = try #require(try commitIsAtomic(c, s, item, convert: false))
        }
    }

    @Test(arguments: [
        ("no-size", #"<svg xmlns="http://www.w3.org/2000/svg"><rect width="50" height="50" fill="red"/></svg>"#),
        ("malformed", #"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="#),
        ("not-svg", "just some text"),
        ("html", "<html><body>nope</body></html>"),
    ])
    func oddSVGDoesNotCrash(_ name: String, _ xml: String) throws {
        let url = try MT.write(Data(xml.utf8), as: "\(name).svg")
        let info = MT.analyzer.analyze(url, kind: .image)
        if let w = info.width, let h = info.height { #expect(w > 0 && h > 0) }
        if let thumb = try? MT.analyzer.thumbnail(url, kind: .image) { try MT.checkThumbnail(thumb, displaySize: nil, "\(name).svg") }
        let c = try MT.collection()
        defer { try? FileManager.default.removeItem(at: c.url) }
        let s = StagingArea(collection: c, analyzer: MT.analyzer)
        _ = try commitIsAtomic(c, s, try s.add(file: url, source: "test"))
    }

    // MARK: - Odd streams

    /// An .mp4 holding only audio is a "video" by its extension: it gets a length but no picture.
    @Test func audioOnlyMP4() throws {
        let url = try MT.make("audio-only.mp4", MT.tone() + ["-c:a", "aac"])
        let info = MT.analyzer.analyze(url, kind: .video)
        #expect(info.width == nil && info.phash == nil)
        #expect(abs(Int(info.durationMs ?? 0) - 1000) < 150)
        #expect(throws: (any Error).self) { try MT.analyzer.thumbnail(url, kind: .video) }
        let c = try MT.collection()
        defer { try? FileManager.default.removeItem(at: c.url) }
        let p = try #require(try c.formats(of: MT.commit(c, url).id).primary)
        #expect(p.ext == "mp4" && p.compatibility(kind: .video) == .popular && p.codecs == "mp4/-/aac")
        #expect(!FileManager.default.fileExists(atPath: c.media.thumbURL(sha256: p.sha256).path))
        #expect(!FormatPolicy.exportFormats(kind: .video, hasAudio: true).isEmpty)
    }

    /// H.264 in 4:4:4 with odd sides is "h264" to the policy, yet browsers, iOS and Telegram can't play it.
    @Test func h264HighFourFourFourCountsAsPopular() throws {
        guard MT.has("libx264") else { return }
        let url = try MT.make("h444.mp4", ["-f", "lavfi", "-i", "testsrc=s=101x57:d=1:r=25", "-c:v", "libx264", "-pix_fmt", "yuv444p"])
        let info = MT.analyzer.analyze(url, kind: .video)
        #expect(info.width == 101 && info.height == 57)
        withKnownIssue("compatibility ignores H.264 profile/chroma: 4:4:4 counts as popular") {
            #expect(FormatPolicy.compatibility(kind: .video, ext: "mp4", codecs: info.codecs) == .uncommon)
        }
    }

    // MARK: - Same content, different names

    @Test func identicalContentIsStoredOnce() throws {
        let c = try MT.collection()
        defer { try? FileManager.default.removeItem(at: c.url) }
        let s = StagingArea(collection: c, analyzer: MT.analyzer)
        let names = ["a.png", "Копия a.png", "A.PNG", "a (1).png"]
        let items = try names.map { try s.add(file: try MT.copy(try Base.png(), as: $0), source: "test") }
        #expect(Set(items.map(\.sha256)).count == 1)
        // Each sees the others in staging as exact duplicates.
        for i in items {
            let dups = try s.duplicates(of: i)
            #expect(dups.filter { if case .stagedExact = $0.match { true } else { false } }.count == names.count - 1)
        }
        let first = try s.commit(items[0].id)
        #expect(try s.duplicates(of: items[1]).contains { $0.memeID == first.id && $0.match == .exact })
        for i in items.dropFirst() { _ = try s.commit(i.id) }

        #expect(try c.memes.count() == names.count)
        let files = try FileManager.default.subpathsOfDirectory(atPath: c.media.root.path).filter { $0.hasSuffix(".png") }
        #expect(files.count == 1, "\(files)")
        let thumbs = try FileManager.default.contentsOfDirectory(atPath: c.media.thumbs.path)
        #expect(thumbs.count == 1)
        #expect(try c.memes.memes(withSHA256: items[0].sha256).count == names.count)

        // .jpg and .jpeg are one extension: one stored file.
        let j1 = try MT.commit(c, try MT.copy(try Base.jpg(), as: "x.jpg"))
        let j2 = try MT.commit(c, try MT.copy(try Base.jpg(), as: "x.JPEG"))
        #expect(try c.memes.primaryAsset(of: j1.id)?.ext == "jpg" && c.memes.primaryAsset(of: j2.id)?.ext == "jpg")
        let jpgs = try FileManager.default.subpathsOfDirectory(atPath: c.media.root.path).filter { $0.hasSuffix(".jpg") || $0.hasSuffix(".jpeg") }
        #expect(jpgs.count == 1)
    }

    /// The same uncommon file imported twice converts to byte-identical output, so it dedups too.
    @Test func identicalUncommonFilesConvertToOneFile() throws {
        let c = try MT.collection()
        defer { try? FileManager.default.removeItem(at: c.url) }
        let bmp = try MT.make("dedup.bmp", ["-f", "lavfi", "-i", "testsrc2=s=160x90", "-frames:v", "1", "-pix_fmt", "bgr24"])
        let a = try #require(try c.formats(of: MT.commit(c, try MT.copy(bmp, as: "one.bmp")).id).primary)
        let b = try #require(try c.formats(of: MT.commit(c, try MT.copy(bmp, as: "two.BMP")).id).primary)
        #expect(a.sha256 == b.sha256 && a.sourceSHA256 == b.sourceSHA256)
    }
}
