import Foundation

extension Collection {
    /// Pictures and videos saved without their size (added before the media tools were around, or by
    /// an older version) are measured now — without a size a viewer can't give them their shape until
    /// a frame is decoded, so they jump. A file that can't be measured gets 0 × 0 and isn't tried again.
    /// Returns how many were measured.
    @discardableResult
    public func fillMissingMediaSizes(analyzer: MediaAnalyzer, isCancelled: () -> Bool = { false }) throws -> Int {
        let rows = try db.query("""
            SELECT id, sha256, ext FROM asset
            WHERE role IN ('primary', 'media', 'original') AND (width IS NULL OR height IS NULL)
            """, []) { (id: $0.int(0), sha: $0.string(1), ext: $0.string(2)) }
        var filled = 0
        for r in rows {
            if isCancelled() { break }
            guard let kind = MediaType.detect(ext: r.ext)?.kind, [.image, .gif, .video].contains(kind) else { continue }
            let url = media.url(sha256: r.sha, ext: r.ext)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let info = analyzer.analyze(url, kind: kind)
            try db.run("""
                UPDATE asset SET width = ?, height = ?, duration_ms = coalesce(duration_ms, ?), codecs = coalesce(codecs, ?) WHERE id = ?
                """, [info.width ?? 0, info.height ?? 0, info.durationMs, info.codecs, r.id])
            if (info.width ?? 0) > 0 { filled += 1 }
        }
        return filled
    }
}
