import SwiftUI
import MemebooruCore

/// Clusters, not pairs: all copies of one meme in a row. Pick the one to keep.
struct DuplicatesView: View {
    @Environment(Library.self) private var library

    var body: some View {
        PageColumn {
            PageHeader(title: "Дубликаты", subtitle: plural(library.duplicateClusters.count, "group") + (library.containments.isEmpty ? "" : " · " + plural(library.containments.count, "crop"))) {
                GlassButton(title: "Проверить коллекцию", symbol: "magnifyingglass", prominent: true) { library.scanDuplicates() }
            }
            if library.duplicateClusters.isEmpty && library.containments.isEmpty {
                EmptyState(icon: "square.on.square.dashed", title: "Дубликаты пока не найдены",
                           subtitle: "Проверка сравнивает содержимое файлов и визуальные признаки, а также ищет изображения, вырезанные из других.")
            }
            ForEach(library.duplicateClusters) { ClusterRow(cluster: $0) }

            if !library.containments.isEmpty {
                Text("Фрагменты — одно изображение внутри другого").dfont(18, .regular).padding(.top, Space.s)
                ForEach(library.containments) { ContainmentRow(item: $0) }
            }
        }
    }
}

/// Picture of a post at a fixed box, shadowed like the grid.
private struct DupThumb: View {
    @Environment(Library.self) private var library
    let meme: Meme
    let side: CGFloat
    var body: some View {
        Button { library.openDetail(meme.id) } label: {
            ThumbCell(meme: meme, size: size).frame(width: side, height: side).contentShape(Rectangle())
        }.buttonStyle(.plain).linkPointer()
    }
    private var size: CGSize {
        switch meme.kind {
        case .text, .article, .audio, .tweet: return CGSize(width: side, height: side)
        default:
            let a = max(0.2, library.aspect(for: meme))
            return a > 1 ? CGSize(width: side, height: (side / a).rounded()) : CGSize(width: (side * a).rounded(), height: side)
        }
    }
}

/// One "A contains B" pair: the larger image, then the crop, with actions.
struct ContainmentRow: View {
    @Environment(\.zoom) private var zoom
    let item: ContainmentVM

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.l) { pair; Spacer(minLength: Space.l); buttons }
            VStack(alignment: .leading, spacing: Space.m) { pair; buttons }
        }
        .card()
    }

    private var pair: some View {
        HStack(alignment: .center, spacing: Space.m) {
            labeled(item.container, "Оригинал")
            Image(systemName: "arrow.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.faint)
            labeled(item.contained, "Обрезка")
            Text("Совпадающих точек: \(item.inliers)").zfont(11).foregroundStyle(Theme.muted).fixedSize()
                .padding(.leading, Space.s)
        }
    }

    private func labeled(_ m: Meme, _ label: String) -> some View {
        VStack(spacing: Space.s) {
            DupThumb(meme: m, side: 110 * zoom)
            Text(label).zfont(11, .bold).foregroundStyle(Theme.muted)
        }
    }

    @Environment(Library.self) private var library
    private var buttons: some View {
        HStack(spacing: Space.s) {
            GlassButton(title: "Удалить фрагмент", symbol: "trash", tint: Theme.danger) { library.deleteCrop(item) }
            GlassButton(title: "Оставить оба") { library.markContains(item) }
            GlassButton(title: "Не связаны") { library.dismissContainment(item) }
        }
    }
}

struct ClusterRow: View {
    @Environment(Library.self) private var library
    @Environment(\.zoom) private var zoom
    let cluster: DuplicateCluster

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Space.m) { clusterTitle; Spacer(minLength: Space.l); clusterButtons }
                VStack(alignment: .leading, spacing: Space.s) { clusterTitle; clusterButtons }
            }
            Rule()
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: Space.xl) {
                    ForEach(cluster.members, id: \.rawValue) { id in member(id) }
                }
                .padding(.vertical, Space.xs)
            }
            .scrollIndicators(.automatic)
        }
        .card()
    }

    private var clusterTitle: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Text("\(cluster.members.count) copies").dfont(18).lineLimit(1).fixedSize()
            Text(cluster.allExact ? "одинаковые файлы"
                 : cluster.maxDistance == 0 ? "визуально одинаковые"
                 : "похожие, расстояние ≤ \(cluster.maxDistance)").zfont(12).foregroundStyle(Theme.muted).lineLimit(1).fixedSize()
        }
    }
    private var clusterButtons: some View {
        HStack(spacing: Space.s) {
            GlassButton(title: "Все варианты") { library.markVariants(cluster) }
            GlassButton(title: "Не дубликаты") { library.dismiss(cluster) }
        }
    }

    @ViewBuilder private func member(_ id: MemeID) -> some View {
        if let m = library.meme(id) {
            let asset = library.primaryAsset(of: id)
            let w = 170 * zoom
            VStack(alignment: .leading, spacing: Space.xs) {
                DupThumb(meme: m, side: w).padding(.bottom, Space.xs)
                Text(asset?.originalName ?? m.kind.categoryName).zfont(12, .bold).foregroundStyle(Theme.link).lineLimit(1)
                Text(facts(asset)).zfont(11).foregroundStyle(Theme.muted).lineLimit(1)
                HStack(spacing: Space.s) { ForEach(library.tags(of: id).prefix(4), id: \.id) { t in Text(t.name).foregroundStyle(Theme.tagColor(t.kind)) } }
                    .zfont(11).lineLimit(1)
                GlassButton(title: "Оставить этот", prominent: true) { library.keep(id, in: cluster) }
                    .padding(.top, Space.s)
            }
            .frame(width: w, alignment: .leading)
        }
    }

    private func facts(_ a: Asset?) -> String {
        guard let a else { return "" }
        var p: [String] = []
        if let w = a.width, let h = a.height, w > 0, h > 0 { p.append("\(w)×\(h)") }
        p.append(a.ext)
        p.append(ByteCountFormatter.string(fromByteCount: a.bytes, countStyle: .file))
        return p.joined(separator: " · ")
    }
}
