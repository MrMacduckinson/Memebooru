import Foundation

/// How ffmpeg gets run: as a separate process (macOS, Linux) or inside the app (iOS, where apps can't
/// launch executables — the app links FFmpeg as a library and provides this).
public protocol FFmpegRunner: Sendable {
    /// Runs the ffmpeg command line (arguments only, no program name). Throws with ffmpeg's error text.
    func ffmpeg(_ args: [String]) throws
    func probe(_ url: URL) throws -> MediaProbe
    func encoderNames() -> Set<String>
}

/// `MediaTranscoder` on top of the ffmpeg command line: the Mac app ships its own build (LGPL,
/// VideoToolbox encoders, dav1d/libvpx/opus/lame/webp), the iOS app links the same as a library, the
/// server uses the distro's ffmpeg. Encoders are picked from what the build actually has, and streams
/// are copied instead of re-encoded whenever the target allows it (no quality loss, near-instant).
public final class FFmpegTranscoder: MediaTranscoder, @unchecked Sendable {
    public let runner: any FFmpegRunner
    private let lock = NSLock()
    private var _encoders: Set<String>?

    public init(runner: any FFmpegRunner) { self.runner = runner }

    #if os(macOS) || os(Linux)
    /// First working ffmpeg/ffprobe pair among: `$MEMEBOORU_FFMPEG_DIR`, the given directories (the app
    /// bundle), Homebrew, /usr/local, /usr.
    public static func locate(in extra: [URL] = []) -> FFmpegTranscoder? {
        var dirs = extra
        if let d = ProcessInfo.processInfo.environment["MEMEBOORU_FFMPEG_DIR"] { dirs.insert(URL(fileURLWithPath: d), at: 0) }
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"].map { URL(fileURLWithPath: $0) }
        let fm = FileManager.default
        for d in dirs {
            let f = d.appendingPathComponent("ffmpeg"), p = d.appendingPathComponent("ffprobe")
            if fm.isExecutableFile(atPath: f.path), fm.isExecutableFile(atPath: p.path) {
                return FFmpegTranscoder(runner: ProcessFFmpegRunner(ffmpeg: f, ffprobe: p))
            }
        }
        return nil
    }
    #endif

    public var encoders: Set<String> {
        if let e = lock.withLock({ _encoders }) { return e }
        let names = runner.encoderNames()
        lock.withLock { _encoders = names }
        return names
    }

    /// The ffmpeg command line as is (e.g. for tests making sample media).
    public func runFFmpeg(_ args: [String]) throws { try runner.ffmpeg(["-nostdin", "-hide_banner"] + args) }

    public func probe(_ url: URL) throws -> MediaProbe {
        var p = try runner.probe(url)
        p.container = MediaStore.normalizeExt(url.pathExtension)
        return p
    }

    // MARK: - Frames

    public func frame(_ url: URL, at fraction: Double, maxSide: Int) throws -> Data {
        let dur = (try? probe(url).durationMs).flatMap { $0 }.map { Double($0) / 1000 } ?? 0
        let t = max(0, min(dur * fraction, max(0, dur - 0.05)))
        var args = ["-v", "error"]
        if t > 0 { args += ["-ss", String(format: "%.3f", t)] }
        args += inputDecoder(for: url) + ["-i", url.path, "-frames:v", "1"]
        if maxSide > 0 { args += ["-vf", "scale='min(\(maxSide),iw)':'min(\(maxSide),ih)':force_original_aspect_ratio=decrease"] }
        return try pngOutput(args, source: url)
    }

    public func stillPNG(_ url: URL) throws -> Data {
        try pngOutput(["-v", "error", "-i", url.path, "-frames:v", "1"], source: url)
    }

    /// Writes one PNG to a temporary file (not a pipe: in-process ffmpeg has no stdout of its own).
    private func pngOutput(_ args: [String], source: URL) throws -> Data {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("mb-frame-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: out) }
        try runFFmpeg(args + ["-c:v", "png", "-update", "1", "-y", out.path])
        guard let png = try? Data(contentsOf: out), !png.isEmpty else { throw TranscodeError("no picture in \(source.lastPathComponent)") }
        return png
    }

    /// VP9/VP8 with alpha only decode their alpha plane through libvpx.
    private func inputDecoder(for url: URL, probe p: MediaProbe? = nil) -> [String] {
        guard let p = p ?? (try? probe(url)), p.hasAlpha else { return [] }
        if p.video == "vp9" { return ["-c:v", "libvpx-vp9"] }
        if p.video == "vp8" { return ["-c:v", "libvpx"] }
        return []
    }

    // MARK: - Edit

    public func edit(_ src: URL, crop: PixelRect?, trim: TimeRange?, to format: MediaFormat, dest: URL) throws {
        let p = (try? probe(src)) ?? MediaProbe()
        try? FileManager.default.removeItem(at: dest)
        var args = ["-v", "error", "-y"]
        // Seeking before the input while re-encoding is frame-exact and doesn't decode the skipped part.
        if let trim, trim.startMs > 0 { args += ["-ss", String(format: "%.3f", Double(trim.startMs) / 1000)] }
        args += inputDecoder(for: src, probe: p) + ["-i", src.path]
        if let trim { args += ["-t", String(format: "%.3f", Double(max(1, trim.durationMs)) / 1000)] }
        let flatten = "format=rgba,split[bg][fg];[bg]drawbox=c=white@1:replace=1:t=fill[w];[w][fg]overlay=format=auto"
        let cropFilter = crop.map { "crop=\($0.width):\($0.height):\($0.x):\($0.y)" }
        let aac = encoders.contains("aac_at") ? ["-c:a", "aac_at", "-b:a", "192k"] : ["-c:a", "aac", "-b:a", "192k"]
        switch format {
        case .mp4H264:
            let even = "scale='max(2,trunc(iw/2)*2)':'max(2,trunc(ih/2)*2)'"
            let chain = [p.hasAlpha ? flatten : nil, cropFilter, even, "format=yuv420p"].compactMap { $0 }.joined(separator: ",")
            args += ["-filter_complex", "[0:v]" + chain + "[v]", "-map", "[v]", "-map", "0:a:0?"] + h264(p)
            args += p.audio == nil ? ["-an"] : aac
            args += ["-movflags", "+faststart"]
        case .gif:
            // Same size and speed as the source: only the frame changes.
            let pal = "split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5"
            let chain = [p.hasAlpha ? flatten : nil, cropFilter, pal].compactMap { $0 }.joined(separator: ",")
            args += ["-filter_complex", "[0:v]" + chain, "-loop", "0", "-an"]
        case .mp3:
            args += ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]
        case .m4a:
            args += ["-vn"] + aac
        default:
            throw TranscodeError("can't crop or trim into \(format.label)")
        }
        try runFFmpeg(args + [dest.path])
        guard (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap({ $0 }) ?? 0 > 0 else {
            throw TranscodeError("ffmpeg produced nothing for \(format.label)")
        }
    }

    public func pcm(_ url: URL, rate: Int) throws -> [Int16] {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("mb-pcm-\(UUID().uuidString).raw")
        defer { try? FileManager.default.removeItem(at: out) }
        try runFFmpeg(["-v", "error", "-y", "-i", url.path, "-vn", "-ac", "1", "-ar", String(rate), "-f", "s16le", "-c:a", "pcm_s16le", out.path])
        let data = try Data(contentsOf: out)
        return data.withUnsafeBytes { raw in Array(raw.bindMemory(to: Int16.self)).map { Int16(littleEndian: $0) } }
    }

    // MARK: - Convert

    public func convert(_ src: URL, to format: MediaFormat, dest: URL, probe given: MediaProbe?) throws {
        let p = given ?? (try? probe(src)) ?? MediaProbe()
        try? FileManager.default.removeItem(at: dest)
        var args = ["-v", "error", "-y"] + inputDecoder(for: src, probe: p) + ["-i", src.path]
        // Even sides for 4:2:0, and never below 2 (a 1-px side would round to 0, which scale reads as "keep 1").
        let even = "scale='max(2,trunc(iw/2)*2)':'max(2,trunc(ih/2)*2)'"
        // Transparent video → a codec without alpha: composite onto white instead of black.
        let flatten = "format=rgba,split[bg][fg];[bg]drawbox=c=white@1:replace=1:t=fill[w];[w][fg]overlay=format=auto"
        func videoFilter(_ extra: String) -> [String] {
            let chain = [p.hasAlpha ? flatten : nil, extra].compactMap { $0 }.joined(separator: ",")
            return p.hasAlpha ? ["-filter_complex", "[0:v]" + chain + "[v]", "-map", "[v]", "-map", "0:a?"] : ["-vf", chain]
        }
        func audio(copyIf ok: Set<String>, encode: [String]) -> [String] {
            guard let a = p.audio else { return ["-an"] }
            return ok.contains(a) ? ["-c:a", "copy"] : encode
        }
        let aac = encoders.contains("aac_at") ? ["-c:a", "aac_at", "-b:a", "192k"] : ["-c:a", "aac", "-b:a", "192k"]

        switch format {
        case .mp4H264, .movH264, .mkvH264:
            if p.video == "h264", !p.hasAlpha {
                args += ["-map", "0:v:0", "-map", "0:a:0?", "-c:v", "copy"]
            } else {
                args += videoFilter(even + ",format=yuv420p") + h264(p)
            }
            args += audio(copyIf: format == .mkvH264 ? ["aac", "mp3", "opus", "vorbis", "flac"] : ["aac", "mp3"], encode: aac)
            if format != .mkvH264 { args += ["-movflags", "+faststart"] }
        case .mp4HEVC:
            args += (p.video == "hevc" && !p.hasAlpha ? ["-c:v", "copy"] : videoFilter(even + ",format=yuv420p") + hevc(p))
            args += ["-tag:v", "hvc1"] + audio(copyIf: ["aac", "mp3"], encode: aac) + ["-movflags", "+faststart"]
        case .webmVP9:
            args += (p.video == "vp9" ? ["-c:v", "copy"] :
                     ["-vf", "format=yuva420p", "-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-deadline", "good", "-cpu-used", "4"])
            args += audio(copyIf: ["opus", "vorbis"], encode: ["-c:a", "libopus", "-b:a", "128k"])
        case .gif:
            if p.video == "gif" { try FileManager.default.copyItem(at: src, to: dest); return }
            let pal = "fps=15,scale='min(640,iw)':-2:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5"
            args += ["-filter_complex", "[0:v]" + (p.hasAlpha ? flatten + "," : "") + pal, "-loop", "0", "-an"]
        case .webpAnimated:
            try require("libwebp_anim")
            args += ["-vf", "fps=20,scale='min(640,iw)':-2:flags=lanczos", "-c:v", "libwebp_anim", "-q:v", "75", "-loop", "0", "-an"]
        case .mp3:
            args += ["-vn"] + (p.audio == "mp3" ? ["-c:a", "copy"] : ["-c:a", "libmp3lame", "-q:a", "2"])
        case .m4a:
            args += ["-vn"] + (p.audio == "aac" ? ["-c:a", "copy"] : aac)
        case .opus:
            args += ["-vn"] + (p.audio == "opus" ? ["-c:a", "copy"] : ["-c:a", "libopus", "-b:a", "128k"])
        case .flac:
            args += ["-vn", "-c:a", "flac"]
        case .wav:
            args += ["-vn", "-c:a", "pcm_s16le"]
        case .jpeg:
            args += ["-frames:v", "1", "-c:v", "mjpeg", "-q:v", "2", "-pix_fmt", "yuvj444p"]
        case .png:
            args += ["-frames:v", "1", "-c:v", "png"]
        case .webp:
            try require("libwebp")
            args += ["-frames:v", "1", "-c:v", "libwebp", "-q:v", "90"]
        case .tiff:
            args += ["-frames:v", "1", "-c:v", "tiff", "-compression_algo", "deflate"]
        case .bmp:
            args += ["-frames:v", "1", "-c:v", "bmp", "-pix_fmt", "bgr24"]
        case .heic:
            throw TranscodeError("HEIC is written by the system encoder, not ffmpeg")
        }
        try runFFmpeg(args + [dest.path])
        guard (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap({ $0 }) ?? 0 > 0 else {
            throw TranscodeError("ffmpeg produced nothing for \(format.label)")
        }
    }

    private func h264(_ p: MediaProbe) -> [String] {
        if encoders.contains("libx264") { return ["-c:v", "libx264", "-crf", "20", "-preset", "medium", "-profile:v", "high"] }
        if encoders.contains("h264_videotoolbox") { return ["-c:v", "h264_videotoolbox"] + toolboxQuality(p, q: 65, bitsPerPixel: 4) + ["-profile:v", "high", "-allow_sw", "1"] }
        return ["-c:v", "mpeg4", "-q:v", "3"]
    }

    private func hevc(_ p: MediaProbe) -> [String] {
        if encoders.contains("libx265") { return ["-c:v", "libx265", "-crf", "24", "-preset", "medium"] }
        if encoders.contains("hevc_videotoolbox") { return ["-c:v", "hevc_videotoolbox"] + toolboxQuality(p, q: 60, bitsPerPixel: 3) + ["-allow_sw", "1"] }
        return h264(p)
    }

    /// VideoToolbox takes constant quality only on Apple-silicon Macs; iOS needs a bitrate —
    /// sized from the frame (≈8 Mbit/s for 1080p H.264), never below 1 Mbit/s.
    private func toolboxQuality(_ p: MediaProbe, q: Int, bitsPerPixel: Int) -> [String] {
        #if os(iOS)
        let pixels = (p.width ?? 1280) * (p.height ?? 720)
        return ["-b:v", String(max(1_000_000, pixels * bitsPerPixel))]
        #else
        return ["-q:v", String(q)]
        #endif
    }

    private func require(_ encoder: String) throws {
        guard encoders.contains(encoder) else { throw TranscodeError("this ffmpeg has no \(encoder) encoder") }
    }

}

#if os(macOS) || os(Linux)
/// ffmpeg/ffprobe as child processes.
public struct ProcessFFmpegRunner: FFmpegRunner {
    public let ffmpegURL: URL
    public let ffprobeURL: URL
    public init(ffmpeg: URL, ffprobe: URL) { ffmpegURL = ffmpeg; ffprobeURL = ffprobe }

    public func ffmpeg(_ args: [String]) throws { _ = try run(ffmpegURL, args) }

    public func encoderNames() -> Set<String> {
        let out = (try? run(ffmpegURL, ["-hide_banner", "-encoders"])).map { String(decoding: $0, as: UTF8.self) } ?? ""
        // Lines look like " V....D libx264              libx264 H.264 …"
        return Set(out.split(separator: "\n").compactMap { line -> String? in
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 2, cols[0].count == 6, cols[0].first.map({ "VAS".contains($0) }) == true else { return nil }
            return String(cols[1])
        })
    }

    private struct ProbeJSON: Decodable {
        struct Stream: Decodable {
            var codec_type: String?; var codec_name: String?; var width: Int?; var height: Int?; var pix_fmt: String?
            var tags: [String: String]?
            var side_data_list: [SideData]?
        }
        struct SideData: Decodable { var rotation: Double? }
        struct Format: Decodable { var format_name: String?; var duration: String? }
        var streams: [Stream]?; var format: Format?
    }

    public func probe(_ url: URL) throws -> MediaProbe {
        let data = try run(ffprobeURL, ["-v", "error", "-show_entries",
                                        "format=format_name,duration:stream=codec_type,codec_name,width,height,pix_fmt:stream_tags=alpha_mode,title,rotate:stream_side_data=rotation",
                                        "-of", "json", url.path])
        let j = try JSONDecoder().decode(ProbeJSON.self, from: data)
        let streams = j.streams ?? []
        let videos = streams.filter { $0.codec_type == "video" }
        let v = videos.first
        let a = streams.first { $0.codec_type == "audio" }
        let pix = v?.pix_fmt ?? ""
        let dur = j.format?.duration.flatMap(Double.init).map { Int64($0 * 1000) }.flatMap { $0 > 0 ? $0 : nil }
        // HEIF/AVIF keep transparency as a second, greyscale picture (auxiliary alpha) beside the colour one.
        let auxAlpha = videos.dropFirst().contains { s in
            s.tags?["title"]?.lowercased() == "alpha"
                || (dur == nil && (s.pix_fmt ?? "").hasPrefix("gray") && s.width == v?.width && s.height == v?.height)
        }
        // JPEG has no alpha: ffmpeg reports 4-channel (CMYK/YCCK) JPEGs as "yuva444p".
        let alpha = v?.codec_name != "mjpeg" && (pix.hasPrefix("yuva") || pix.hasPrefix("rgba") || pix.hasPrefix("argb") || pix.hasPrefix("bgra")
            || pix.hasPrefix("abgr") || pix == "ya8" || pix == "ya16be" || pix.hasPrefix("gbrap")
            || v?.tags?["alpha_mode"] == "1" || v?.tags?["ALPHA_MODE"] == "1" || auxAlpha)
        // Display size: a phone's portrait video is stored landscape with a 90° display matrix.
        // Older files keep it as a `rotate` tag instead.
        let side: Double? = v?.side_data_list?.compactMap { $0.rotation }.first
        let tag: Double? = v?.tags?["rotate"].flatMap { Double($0) }
        let rotation = Int((side ?? tag ?? 0).rounded())
        let sideways = abs(rotation) % 180 == 90
        // 0×0 = ffprobe recognised the container but couldn't decode the picture (SVG, animated WebP, junk).
        let (w, h) = (v?.width.flatMap { $0 > 0 ? $0 : nil }, v?.height.flatMap { $0 > 0 ? $0 : nil })
        return MediaProbe(container: nil, video: v?.codec_name, audio: a?.codec_name,
                          width: sideways ? h : w, height: sideways ? w : h, durationMs: dur, hasAlpha: alpha)
    }

    @discardableResult
    private func run(_ exe: URL, _ args: [String]) throws -> Data {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        let out = Pipe()
        // stderr goes to a file, not a second pipe: a file never fills up, so stdout can be drained on
        // this thread alone. (Draining stderr on a GCD worker deadlocked: called from Swift concurrency
        // with every pool thread blocked here, GCD had no thread left to run the drain.)
        let errURL = FileManager.default.temporaryDirectory.appendingPathComponent("mb-stderr-\(UUID().uuidString).txt")
        guard FileManager.default.createFile(atPath: errURL.path, contents: nil) else { throw TranscodeError("cannot create \(errURL.path)") }
        let errFile = try FileHandle(forWritingTo: errURL)
        defer { try? errFile.close(); try? FileManager.default.removeItem(at: errURL) }
        p.standardOutput = out
        p.standardError = errFile
        p.standardInput = FileHandle.nullDevice
        // Wait on a semaphore, not `waitUntilExit()`: that spins the run loop, and on the main thread
        // SwiftUI would re-enter its view update from inside it (seen as a hang).
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        // Close now, not when the Pipe is freed: on Linux the Process keeps it alive, so every run
        // leaked a descriptor — and past 1024 of them Foundation (select-based) misses child exits.
        try? out.fileHandleForReading.close()
        exited.wait()
        guard p.terminationStatus == 0 else {
            let errText = (try? Data(contentsOf: errURL)) ?? Data()
            let msg = String(decoding: errText, as: UTF8.self).split(separator: "\n").suffix(3).joined(separator: " ")
            throw TranscodeError("\(exe.lastPathComponent) failed: \(msg)")
        }
        return data
    }
}
#endif

public struct TranscodeError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ d: String) { description = d }
}
