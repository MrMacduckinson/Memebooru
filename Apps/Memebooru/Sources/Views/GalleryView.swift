import SwiftUI
import MemebooruCore

/// The browse grid, laid out like deviantART's: fixed cells, each thumbnail centered in a square box
/// with a soft shadow, a bold title link and an "in Category" line underneath.
struct GalleryView: View {
    @Environment(Library.self) private var library
    @Environment(\.zoom) private var zoom
    @Environment(\.compactLayout) private var compact

    var body: some View {
        GeometryReader { geo in
            // Columns fill the page width exactly (no centered leftover), so the first column starts on
            // the same 24pt gutter as the page title and the last one ends on the right gutter.
            let gap = Space.l
            let avail = max(0, geo.size.width - (compact ? Space.l : Space.xl) * 2)
            let minCell = (compact ? GalleryCell.compactMinWidth : GalleryCell.minWidth) * zoom   // phone: two columns
            let n = max(1, Int((avail + gap) / (minCell + gap)))
            let cell = ((avail - gap * CGFloat(n - 1)) / CGFloat(n)).rounded(.down)
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    PageHeader(title: library.query.isEmpty ? "Коллекция" : "Поиск", subtitle: subtitle) {
                        if !library.query.isEmpty { GlassButton(title: "Очистить поиск", symbol: "xmark") { library.query = "" } }
                    }
                    if library.results.isEmpty {
                        EmptyState(icon: library.query.isEmpty ? "photo.on.rectangle.angled" : "magnifyingglass",
                                   title: library.query.isEmpty ? "В коллекции пока пусто" : "Ничего не найдено",
                                   subtitle: library.query.isEmpty ? "Перетащите файлы в окно или нажмите «Добавить» вверху."
                                                                   : "Ничего не найдено. Попробуйте другие теги или сократите запрос.")
                    } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(cell), spacing: gap, alignment: .top), count: n),
                                  alignment: .leading, spacing: Space.xl) {
                            ForEach(library.results, id: \.id) { m in
                                GalleryCell(meme: m, width: cell)
                                    .onAppear { library.loadMoreIfNeeded(current: m) }
                            }
                        }
                    }
                }
                .pageInsets()
            }
        }
        .pageBackground()
    }

    private var subtitle: String {
        let n = "\(library.results.count)\(library.nextCursor != nil ? "+" : "")"
        return library.query.isEmpty ? "\(library.name) · найдено: \(n)" : "Результатов: \(n), запрос: «\(library.query.trimmingCharacters(in: .whitespaces))»"
    }
}

/// One grid cell: thumb box, title, category line.
struct GalleryCell: View {
    @Environment(Library.self) private var library
    @Environment(\.zoom) private var zoom
    let meme: Meme
    let width: CGFloat
    static let minWidth: CGFloat = 176      // narrowest column; the grid widens columns to fill the row
    static let compactMinWidth: CGFloat = 150
    static let boxHeight: CGFloat = 150     // DA's 150px thumbnail height

    @State private var titleHover = false

    var body: some View {
        let box = CGSize(width: width, height: Self.boxHeight * zoom)
        VStack(spacing: Space.s) {
            Button { library.openDetail(meme.id) } label: {
                ThumbCell(meme: meme, size: fitted(in: box))
                    .frame(width: box.width, height: box.height)   // every thumb centered in the same box
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).linkPointer()
            .accessibilityIdentifier("postCell")
            .accessibilityLabel(title)
            .contextMenu { Button("Удалить", role: .destructive) { library.delete(meme.id) } }

            VStack(spacing: Space.xs / 2) {
                Text(title).zfont(12, .bold).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(titleHover ? Theme.linkHover : Theme.link)
                    .underline(titleHover)
                    .onHover { titleHover = $0 }
                    .onTapGesture { library.openDetail(meme.id) }
                    .linkPointer()
                HStack(spacing: Space.xs) {
                    Text("in").foregroundStyle(Theme.text)
                    LinkText(text: meme.kind.categoryName, color: Theme.muted, size: 11) { library.search(tag: meme.kind.kindTag) }
                }
                .zfont(11)
            }
            .frame(width: width)
        }
    }

    /// Thumbnail size: fit the meme's aspect inside the box. Cards (text/audio/tweet) use a fixed shape.
    private func fitted(in box: CGSize) -> CGSize {
        switch meme.kind {
        // Cards keep one shape (the site's 150×125 lit thumb), whatever the column width.
        case .text, .article, .audio: return CGSize(width: min(box.width, box.height * 1.2), height: box.height * 0.84)
        case .tweet:
            // Shown as media: the picture's own shape, like a picture post. As a tweet: the whole cell.
            guard let a = library.mediaOnlyAspect(meme) else { return box }
            return a > box.width / box.height ? CGSize(width: box.width, height: (box.width / a).rounded())
                                              : CGSize(width: (box.height * a).rounded(), height: box.height)
        default:
            // Pictures: fit the box height (150), never wider than the column.
            let a = max(0.2, library.aspect(for: meme))
            return a > box.width / box.height ? CGSize(width: box.width, height: (box.width / a).rounded())
                                              : CGSize(width: (box.height * a).rounded(), height: box.height)
        }
    }

    /// Posts have no titles, so borrow the most telling thing they do have.
    private var title: String {
        switch meme.kind {
        case .tweet:
            if case .tweet(let p) = meme.payload, !p.handle.isEmpty { return "@" + p.handle }
        default: break   // text posts show their words in the thumb — the title shouldn't repeat them
        }
        let general = library.tags(of: meme.id).filter { $0.kind == .normal }.prefix(3).map(\.name)
        if !general.isEmpty { return general.joined(separator: " ") }
        if let n = library.primaryAsset(of: meme.id)?.originalName { return (n as NSString).deletingPathExtension }
        return meme.kind.categoryName
    }
}

extension MemeKind {
    /// The auto meta-tag every post of this kind carries.
    var kindTag: String { self == .image ? "picture" : rawValue }
}
