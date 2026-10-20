#if os(Linux)
import Foundation
import MemebooruCore

/// Tweet text through `pango-view` (pango1.0-tools): proper shaping for every script and colour
/// emoji (with fonts-noto-core + fonts-noto-color-emoji installed).
public struct PangoTextRenderer: TextRenderer {
    let tool: URL
    let decoder = StbImageDecoder()

    /// nil when pango-view isn't installed — the bot then sends tweets as text.
    public static func locate() -> PangoTextRenderer? {
        let dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/usr/local/bin").split(separator: ":").map(String.init)
        for d in dirs {
            let url = URL(fileURLWithPath: d).appendingPathComponent("pango-view")
            if FileManager.default.isExecutableFile(atPath: url.path) { return PangoTextRenderer(tool: url) }
        }
        return nil
    }

    public func render(_ text: String, style: TextStyle, width: Int) throws -> Bitmap? {
        guard !text.isEmpty, width > 0 else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mb-text-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("text.txt"), output = dir.appendingPathComponent("text.png")
        try Data(text.utf8).write(to: input)
        var args = ["-q", "--pixels", "--width=\(width)", "--wrap=word-char", "--hinting=none", "--margin=0",
                    "--font=Noto Sans,DejaVu Sans\(style.bold ? " Bold" : "") \(Int(style.size.rounded()))",
                    "--foreground=" + String(format: "#%06X", style.color), "--background=transparent",
                    "--output=\(output.path)"]
        if style.maxLines > 0 { args += ["--height=-\(style.maxLines)", "--ellipsize=end"] }
        let p = Process()
        p.executableURL = tool
        p.arguments = args + [input.path]
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw PlatformLinuxError(description: "pango-view exited \(p.terminationStatus)") }
        return try decoder.decode(output, maxSide: 0)
    }
}
#endif
