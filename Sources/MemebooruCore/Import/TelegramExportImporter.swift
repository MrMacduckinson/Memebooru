import Foundation

/// Parses a Telegram Desktop "Export chat history" folder (`result.json` + media subfolders).
/// No authorization involved — the user exports from the official client and drags the folder in.
public struct TelegramExportImporter: Sendable {
    public struct Options: Sendable {
        public var includeStickers = true
        public var includeVoice = false
        public var includeTextMessages = true
        public var minTextLength = 40
        public init() {}
    }

    public let staging: StagingArea
    public var options = Options()

    public init(staging: StagingArea, options: Options = Options()) { self.staging = staging; self.options = options }

    public func importExport(at dir: URL, progress: ((String) -> Void)? = nil) throws -> ImportReport {
        let file = dir.appendingPathComponent("result.json")
        guard let data = try? Data(contentsOf: file),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = root["messages"] as? [[String: Any]] else {
            throw CollectionError("no readable result.json in \(dir.path)")
        }
        let chat = (root["name"] as? String) ?? "Telegram"
        var report = ImportReport()

        for msg in messages where (msg["type"] as? String) == "message" {
            let text = Self.flatten(msg["text"])
            let date = (msg["date_unixtime"] as? String).flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
                ?? Self.parseDate(msg["date"] as? String)
            let mediaType = msg["media_type"] as? String
            var ctx: [String] = ["Telegram: \(chat)"]
            if let from = msg["from"] as? String { ctx.append("from \(from)") }
            if let fwd = msg["forwarded_from"] as? String { ctx.append("forwarded from \(fwd)") }
            if let d = msg["date"] as? String { ctx.append(d) }
            var tags = ["telegram_message"]

            let rel = (msg["photo"] as? String) ?? (msg["file"] as? String)
            if let rel {
                if mediaType == "sticker" { guard options.includeStickers else { continue }; tags.append("sticker") }
                if mediaType == "voice_message" || mediaType == "video_message" { guard options.includeVoice else { continue } }
                if mediaType == "animation" { tags.append("gif") }
                let url = dir.appendingPathComponent(rel)
                guard FileManager.default.fileExists(atPath: url.path) else { report.skipped.append((url, "missing file")); continue }
                guard MediaType.detect(url: url) != nil else { report.skipped.append((url, "unsupported")); continue }
                progress?(rel)
                do {
                    report.staged.append(try staging.add(
                        file: url, source: "telegram:\(chat)", originalName: url.lastPathComponent, date: date,
                        textVerbatim: text.isEmpty ? nil : text, context: ctx.joined(separator: ", "), extraTags: tags))
                } catch { report.skipped.append((url, "\(error)")) }
            } else if options.includeTextMessages, text.count >= options.minTextLength {
                progress?("text #\(msg["id"] ?? 0)")
                report.staged.append(try staging.add(text: text, source: "telegram:\(chat)", date: date,
                                                     context: ctx.joined(separator: ", "), extraTags: tags))
            }
        }
        return report
    }

    /// `text` is either a string or an array of strings / `{type,text}` entities.
    static func flatten(_ v: Any?) -> String {
        if let s = v as? String { return s }
        guard let parts = v as? [Any] else { return "" }
        return parts.map { p -> String in
            if let s = p as? String { return s }
            if let d = p as? [String: Any], let t = d["text"] as? String { return t }
            return ""
        }.joined()
    }

    static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.date(from: s)
    }
}
