#if os(iOS) && canImport(MBFFmpeg)
import Foundation
import MBFFmpeg
import MemebooruCore

/// FFmpeg linked into the app (iOS can't launch helper executables): the same command lines the Mac
/// runs as a process, executed in-process by the patched fftools (`scripts/build-ffmpeg-ios.sh`).
/// Runs are serialised inside the library — fftools keeps global state.
struct InProcessFFmpegRunner: FFmpegRunner {
    func ffmpeg(_ args: [String]) throws {
        let owned = (["ffmpeg"] + args).map { strdup($0) }
        defer { owned.forEach { free($0) } }
        var argv: [UnsafePointer<CChar>?] = owned.map { UnsafePointer($0) }
        var err = [CChar](repeating: 0, count: 4096)
        let rc = mb_ffmpeg_run(Int32(argv.count), &argv, &err, Int32(err.count))
        guard rc == 0 else {
            let msg = String(cString: err).split(separator: "\n").suffix(8).joined(separator: " ")
            throw TranscodeError("ffmpeg failed (\(rc)): \(msg)")
        }
    }

    func probe(_ url: URL) throws -> MediaProbe {
        var r = mb_probe_result()
        var err = [CChar](repeating: 0, count: 1024)
        guard mb_probe(url.path, &r, &err, Int32(err.count)) == 0 else {
            throw TranscodeError("cannot read \(url.lastPathComponent): \(String(cString: err))")
        }
        func text<T>(_ field: T) -> String? {
            let s = withUnsafeBytes(of: field) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            return s.isEmpty ? nil : s
        }
        return MediaProbe(container: text(r.container), video: text(r.video), audio: text(r.audio),
                          width: r.width > 0 ? Int(r.width) : nil, height: r.height > 0 ? Int(r.height) : nil,
                          durationMs: r.durationMs > 0 ? r.durationMs : nil, hasAlpha: r.hasAlpha != 0)
    }

    func encoderNames() -> Set<String> {
        var buffer = [CChar](repeating: 0, count: 65_536)
        _ = mb_encoders(&buffer, Int32(buffer.count))
        return Set(String(cString: buffer).split(separator: "\n").map(String.init))
    }
}
#endif
