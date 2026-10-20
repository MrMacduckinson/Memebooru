import SwiftUI
import MemebooruCore

/// What the crop / trim editor works on.
enum EditTarget: Identifiable, Equatable {
    case staged(String)
    case meme(MemeID)
    var id: String {
        switch self { case .staged(let s): "staged:" + s; case .meme(let m): "meme:" + m.rawValue }
    }
}

/// The file an edit starts from (always the untouched original) and what's been done to it so far.
struct EditSource {
    let url: URL
    let kind: MemeKind
    let edit: MediaEdit?
}

extension Library {
    var editor: MediaEditor { MediaEditor(analyzer: analyzer) }

    func editSource(_ target: EditTarget) -> EditSource? {
        switch target {
        case .staged(let id):
            guard let item = stagedItems.first(where: { $0.id == id }), let staging else { return nil }
            return EditSource(url: staging.editSource(item), kind: item.kind, edit: item.edit)
        case .meme(let id):
            guard let m = meme(id), let (primary, original) = try? collection?.formats(of: id), let p = primary else { return nil }
            // A converted post's original is in an uncommon format; edits start from it all the same (best quality).
            let base = original ?? p
            return fileURL(base).map { EditSource(url: $0, kind: m.kind, edit: p.edit) }
        }
    }

    /// Edits in the background; the page shows the result when it lands.
    func applyEdit(_ target: EditTarget, _ edit: MediaEdit?) {
        guard let staging, let c = collection else { return }
        editTarget = nil
        busy = edit == nil ? "Восстанавливаем оригинал…" : "Обрезаем…"
        let analyzer = analyzer
        Task {
            switch target {
            case .staged(let id):
                let r = await MediaLoader.run { Result { try staging.applyEdit(id, edit) } }
                if case .failure(let e) = r { errorMessage = "\(e)" }
                reloadStaging()
            case .meme(let id):
                let r = await MediaLoader.run { Result { try c.applyEdit(id, edit, analyzer: analyzer) } }
                if case .failure(let e) = r { errorMessage = "\(e)" }
                forgetAspect(id)
                runSearch(reset: true)
                threadVersion += 1
            }
            busy = nil
        }
    }

    // Slow reads for the editors, on the media pool.

    func detectBorders(_ s: EditSource) async -> PixelRect? {
        let editor = editor
        return await MediaLoader.run { try? editor.detectBorders(s.url, kind: s.kind) }
    }

    func detectSilence(_ s: EditSource) async -> TimeRange? {
        let editor = editor
        return await MediaLoader.run { try? editor.detectSilence(s.url) }
    }

    func waveform(_ s: EditSource, count: Int) async -> (peaks: [Float], durationMs: Int64)? {
        let editor = editor
        return await MediaLoader.run { try? editor.waveform(s.url, count: count) }
    }

    /// The picture to crop on: the image itself, or a frame of the video / GIF, full size.
    func editFrame(_ s: EditSource, at fraction: Double) async -> (image: PlatformImage, size: PixelSize)? {
        let editor = editor, encoder = platform.thumbs
        let png: (Data, PixelSize)? = await MediaLoader.run {
            guard let b = try? editor.frame(s.url, kind: s.kind, at: fraction),
                  let d = (try? encoder.encode(b, as: .png, quality: 1)) ?? nil else { return nil }
            return (d, PixelSize(width: b.width, height: b.height))
        }
        guard let (data, size) = png, let img = PlatformImage(data: data) else { return nil }
        return (img, size)
    }

    func durationMs(_ s: EditSource) async -> Int64? {
        let p = platform
        return await MediaLoader.run { (try? p.video.durationMs(s.url)) ?? ((try? p.transcoder?.probe(s.url)) ?? nil)?.durationMs }
    }
}
