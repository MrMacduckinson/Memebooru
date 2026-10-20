import Crypto
import Foundation

/// A tweet as one picture — the app's paper card: avatar, name, text, media (video as its poster
/// frame with a play badge), the quoted tweet in its own frame, the date. For places that only show
/// pictures (the Telegram bot). Text goes through the platform's `TextRenderer`; everything else is
/// drawn here, so the result looks the same wherever it is made.
public struct TweetRenderer {
    /// Bump when the look changes: every stored render is then redone on next use.
    public static let version = 2

    let collection: Collection
    let analyzer: MediaAnalyzer
    let text: any TextRenderer
    /// Pixels per point (the card is 600 pt wide).
    let scale: Double

    public init(collection: Collection, analyzer: MediaAnalyzer, text: any TextRenderer, scale: Double = 2) {
        self.collection = collection; self.analyzer = analyzer; self.text = text; self.scale = scale
    }

    // The app's DA palette (Theme.swift).
    enum Palette {
        static let paper: UInt32 = 0xFBFCFA
        static let border: UInt32 = 0xA6B2A6
        static let text: UInt32 = 0x2C3635
        static let muted: UInt32 = 0x6B8678
        static let link: UInt32 = 0x337287
        static let surface: UInt32 = 0xDDE6DB
    }

    static let width = 600.0

    public func bitmap(_ meme: Meme) throws -> Bitmap {
        try card(meme, width: Int(Self.width * scale), compact: false, depth: 0).bitmap
    }

    /// PNG (JPEG if the PNG would be too heavy for a Telegram photo).
    public func encoded(_ meme: Meme) throws -> (data: Data, ext: String, width: Int, height: Int) {
        let b = try bitmap(meme)
        if let png = try analyzer.platform.thumbs.encode(b, as: .png, quality: 1), png.count <= 5_000_000 {
            return (png, "png", b.width, b.height)
        }
        return (try analyzer.platform.thumbs.jpeg(b, quality: 0.9), "jpg", b.width, b.height)
    }

    // MARK: - Layout

    /// One vertical block of the card: its height, and how to draw it at a y.
    private struct Block {
        let height: Int
        let draw: (inout Canvas, Int) -> Void
    }

    private func pt(_ v: Double) -> Int { Int((v * scale).rounded()) }

    private func card(_ meme: Meme, width: Int, compact: Bool, depth: Int) throws -> Canvas {
        let payload: TweetPayload? = if case .tweet(let p) = meme.payload { p } else { nil }
        let assets = try collection.memes.assets(of: meme.id)
        let pad = pt(compact ? 10 : 16)
        let inner = width - 2 * pad
        var blocks: [Block] = [try header(payload, avatar: assets.first { $0.role == .avatar }, width: inner, compact: compact)]
        if let handle = payload?.replyToHandle, !handle.isEmpty,
           let b = try text.render("Replying to @\(handle)", style: TextStyle(size: Double(pt(compact ? 11 : 13)), color: Palette.link, maxLines: 1), width: inner) {
            blocks.append(textBlock(b, x: pad))
        }
        if let body = meme.textVerbatim?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty,
           // x.com long posts run to 25,000 characters; Telegram takes a photo only up to width + height
           // 10,000 px, so the card stops at 90 lines (the caption links to the whole post).
           let b = try text.render(body, style: TextStyle(size: Double(pt(compact ? 13 : 16)), color: Palette.text, maxLines: compact ? 6 : 90), width: inner) {
            blocks.append(textBlock(b, x: pad))
        }
        if !compact {
            let media = assets.filter { $0.role == .media }.sorted { $0.order < $1.order }
            if let m = mediaBlock(media, x: pad, width: inner) { blocks.append(m) }
            if depth == 0, let q = try quoted(of: meme) {
                let qc = try card(q, width: inner, compact: true, depth: depth + 1).bitmap
                let r = Double(pt(12))
                blocks.append(Block(height: qc.height) { c, y in
                    let box = Box(Double(pad), Double(y), Double(qc.width), Double(qc.height))
                    c.draw(qc, in: box, radius: r)
                    c.stroke(box, Palette.border, radius: r, lineWidth: max(1, scale))
                })
            }
            if let ms = payload?.postedAt,
               let b = try text.render(Self.dateLine(ms), style: TextStyle(size: Double(pt(13)), color: Palette.muted, maxLines: 1), width: inner) {
                blocks.append(textBlock(b, x: pad))
            }
        }
        let gap = pt(compact ? 6 : 10)
        let height = 2 * pad + blocks.map(\.height).reduce(0, +) + gap * max(0, blocks.count - 1)
        var canvas = Canvas(width: width, height: height, fill: Palette.paper)
        var y = pad
        for b in blocks { b.draw(&canvas, y); y += b.height + gap }
        return canvas
    }

    private func textBlock(_ b: Bitmap, x: Int) -> Block {
        Block(height: b.height) { c, y in c.draw(b, x: x, y: y) }
    }

    /// Avatar circle, bold name over the muted @handle, centred on the avatar.
    private func header(_ p: TweetPayload?, avatar: Asset?, width: Int, compact: Bool) throws -> Block {
        let side = pt(compact ? 30 : 44)
        let gap = pt(12)
        let pad = pt(compact ? 10 : 16)
        let textWidth = max(1, width - side - gap)
        let name = try text.render(p?.authorName ?? "", style: TextStyle(size: Double(pt(compact ? 13 : 16)), bold: true, color: Palette.text, maxLines: 1), width: textWidth)
        let handle = try text.render("@\(p?.handle ?? "")", style: TextStyle(size: Double(pt(compact ? 11 : 14)), color: Palette.muted, maxLines: 1), width: textWidth)
        let face = avatar.flatMap { a -> Bitmap? in
            let url = collection.media.url(sha256: a.sha256, ext: a.ext)
            return try? analyzer.converter.raster(url, maxSide: side * 2)
        }
        let textHeight = (name?.height ?? 0) + (handle?.height ?? 0)
        let height = max(side, textHeight)
        return Block(height: height) { c, y in
            let box = Box(Double(pad), Double(y + (height - side) / 2), Double(side), Double(side))
            if let face { c.draw(face, in: box, fit: .fill, radius: Double(side) / 2) }
            else { c.fill(box, Palette.surface, radius: Double(side) / 2) }
            var ty = y + (height - textHeight) / 2
            if let name { c.draw(name, x: pad + side + gap, y: ty); ty += name.height }
            if let handle { c.draw(handle, x: pad + side + gap, y: ty) }
        }
    }

    /// One picture fitted to the width (≤ 460 pt tall), or a two-column grid of cropped tiles.
    private func mediaBlock(_ media: [Asset], x: Int, width: Int) -> Block? {
        let tiles: [(bitmap: Bitmap, video: Bool)] = media.prefix(4).compactMap { a in
            let url = collection.media.url(sha256: a.sha256, ext: a.ext)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }   // not synced here yet
            let kind = MediaType.detect(ext: a.ext)?.kind ?? .image
            let side = width * 2
            let bmp: Bitmap? = switch kind {
            case .video, .gif: (try? analyzer.videoFrame(url, maxSide: side)) ?? (try? analyzer.converter.raster(url, maxSide: side))
            default: try? analyzer.converter.raster(url, maxSide: side)
            }
            return bmp.map { ($0, kind == .video || kind == .gif) }
        }
        guard !tiles.isEmpty else { return nil }
        let r = Double(pt(12))
        if tiles.count == 1, let t = tiles.first {
            let k = min(Double(width) / Double(t.bitmap.width), Double(pt(460)) / Double(t.bitmap.height))
            let w = Int((Double(t.bitmap.width) * k).rounded()), h = Int((Double(t.bitmap.height) * k).rounded())
            return Block(height: h) { c, y in
                let box = Box(Double(x + (width - w) / 2), Double(y), Double(w), Double(h))
                c.draw(t.bitmap, in: box, radius: r)
                if t.video { playBadge(&c, in: box) }
            }
        }
        let gap = pt(4), tileH = pt(180)
        let tileW = (width - gap) / 2
        let rows = (tiles.count + 1) / 2
        return Block(height: rows * tileH + (rows - 1) * gap) { c, y in
            for (i, t) in tiles.enumerated() {
                var box = Box(Double(x + (i % 2) * (tileW + gap)), Double(y + (i / 2) * (tileH + gap)), Double(tileW), Double(tileH))
                if tiles.count == 3 {
                    // As on X: the first one tall on the left, the other two stacked on the right.
                    box = i == 0 ? Box(Double(x), Double(y), Double(tileW), Double(2 * tileH + gap))
                                 : Box(Double(x + tileW + gap), Double(y + (i - 1) * (tileH + gap)), Double(tileW), Double(tileH))
                }
                c.draw(t.bitmap, in: box, fit: .fill, radius: Double(pt(8)))
                if t.video { playBadge(&c, in: box) }
            }
        }
    }

    private func playBadge(_ c: inout Canvas, in box: Box) {
        let d = Double(pt(44)), cx = box.x + box.w / 2, cy = box.y + box.h / 2
        c.fill(Box(cx - d / 2, cy - d / 2, d, d), 0x000000, radius: d / 2, opacity: 0.55)
        let s = d * 0.36
        c.fillTriangle([(cx - s * 0.4, cy - s / 2), (cx - s * 0.4, cy + s / 2), (cx + s * 0.55, cy)], 0xFFFFFF)
    }

    private func quoted(of meme: Meme) throws -> Meme? {
        guard let r = try collection.memes.relations(of: meme.id).first(where: { $0.from == meme.id && $0.kind == .quote }),
              let q = try collection.memes.get(r.to), q.deletedAt == nil else { return nil }
        return q
    }

    static func dateLine(_ ms: Int64) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm · d MMM yyyy"
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    // MARK: - Freshness

    /// Hash of everything the picture shows; stored with the render, so a changed tweet (text edited,
    /// media or quote loaded later, new look) is drawn again.
    public func fingerprint(_ meme: Meme) throws -> String {
        var parts = ["v\(Self.version)", "s\(scale)"]
        func add(_ m: Meme) throws {
            parts.append(m.textVerbatim ?? "")
            if case .tweet(let p) = m.payload { parts += [p.authorName, p.handle, p.replyToHandle ?? "", p.postedAt.map(String.init) ?? ""] }
            for a in try collection.memes.assets(of: m.id) where a.role == .media || a.role == .avatar {
                let present = FileManager.default.fileExists(atPath: collection.media.url(sha256: a.sha256, ext: a.ext).path)
                parts.append("\(a.role.rawValue):\(a.order):\(a.sha256):\(present)")
            }
        }
        try add(meme)
        if let q = try quoted(of: meme) { parts.append("quote"); try add(q) }
        return SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension Collection {
    /// The meme's picture for places that can't show a tweet (Telegram): its stored `render` asset,
    /// drawn again first when out of date (or always, with `force`). `render: false` only looks — a
    /// stale picture beats none. nil when the meme isn't a tweet or this platform can't draw text.
    public func tweetRender(_ meme: Meme, analyzer: MediaAnalyzer, render: Bool = true, force: Bool = false) throws -> Asset? {
        guard meme.kind == .tweet else { return nil }
        let stored = try memes.asset(of: meme.id, role: .render)
        guard let text = analyzer.platform.text else { return stored }
        let renderer = TweetRenderer(collection: self, analyzer: analyzer, text: text)
        let fp = try renderer.fingerprint(meme)
        if !force, let stored, stored.sourceSHA256 == fp, media.exists(sha256: stored.sha256, ext: stored.ext) { return stored }
        guard render else { return stored }
        let out = try renderer.encoded(meme)
        let file = try media.put(data: out.data, ext: out.ext)
        // `sourceSHA256` = what the picture was made from (the fingerprint), as for converted files.
        return try memes.putAsset(Asset(memeID: meme.id, role: .render, sha256: file.sha256, ext: file.ext,
                                        mime: out.ext == "png" ? "image/png" : "image/jpeg",
                                        width: out.width, height: out.height, bytes: file.bytes, sourceSHA256: fp))
    }
}
