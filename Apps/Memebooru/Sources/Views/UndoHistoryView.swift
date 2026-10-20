import SwiftUI
import MemebooruCore

/// "Недавно удалённые" — the full undo history. Every delete/discard is a batch; expand one to see each
/// removed item with a preview, and restore items one by one or the whole batch. Spans all past actions,
/// not just the last.
struct UndoHistoryView: View {
    @Environment(Library.self) private var library

    var body: some View {
        PageColumn {
            PageHeader(title: "История", subtitle: plural(library.undoBatches.count, "action")) { EmptyView() }
            if library.undoBatches.isEmpty {
                EmptyState(icon: "clock.arrow.circlepath", title: "История пока пуста",
                           subtitle: "Удалённые элементы можно восстановить здесь, в том числе после перезапуска.")
            }
            ForEach(library.undoBatches) { batch in
                UndoBatchRow(batch: batch)
            }
        }
    }
}

private struct UndoBatchRow: View {
    @Environment(Library.self) private var library
    @Environment(\.zoom) private var zoom
    let batch: UndoLog.Batch
    @State private var expanded = false
    @State private var items: [UndoEntryVM] = []

    private var date: String {
        Date(timeIntervalSince1970: Double(batch.createdAt) / 1000).formatted(date: .abbreviated, time: .shortened)
    }
    private var restorable: Int { items.filter { !$0.entry.undone }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            header
            if expanded {
                if items.isEmpty {
                    Text("В этом действии нет элементов для предпросмотра.").zfont(12).foregroundStyle(Theme.muted)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104 * zoom, maximum: 104 * zoom), spacing: Space.l, alignment: .top)],
                              alignment: .leading, spacing: Space.l) {
                        ForEach(items) { item in itemCell(item) }
                    }
                }
            }
        }
        .card()
    }

    private var header: some View {
        HStack(spacing: Space.m) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.muted)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: Space.xs / 2) {
                Text(localizedHistoryLabel(batch.summary)).zfont(13, .bold).foregroundStyle(Theme.link).lineLimit(1)
                Text("\(batch.count) item\(batch.count == 1 ? "" : "s") · \(date)").zfont(11).foregroundStyle(Theme.muted)
            }
            Spacer()
            if batch.undone {
                Text("восстановлено").zfont(12).foregroundStyle(Theme.meta)
            } else {
                GlassButton(title: "Восстановить всё", symbol: "arrow.uturn.backward") {
                    library.restoreUndoBatch(batch.id); reload()
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { toggle() }
    }

    @ViewBuilder private func itemCell(_ item: UndoEntryVM) -> some View {
        let side = 104 * zoom
        VStack(alignment: .leading, spacing: Space.xs) {
            Group {
                if let m = item.meme {
                    Button { library.openDetail(m.id) } label: {
                        ThumbCell(meme: m, size: CGSize(width: side, height: side)).contentShape(Rectangle())
                    }.buttonStyle(.plain).linkPointer()
                } else {
                    LitCard(label: "ЭЛЕМЕНТ") {
                        Image(systemName: "doc").font(.system(size: 20)).foregroundStyle(Theme.faint).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }.thumbShadow()
                }
            }
            .frame(width: side, height: side)
            .opacity(item.entry.undone ? 0.4 : 1)
            .padding(.bottom, Space.xs)

            Text(name(item)).zfont(11).foregroundStyle(Theme.text).lineLimit(1).frame(width: side, alignment: .leading)

            if item.entry.undone {
                Text("восстановлено").zfont(11).foregroundStyle(Theme.meta)
            } else {
                LinkText(text: "Восстановить", size: 11, weight: .bold) { library.restoreUndoEntry(item.entry.id); reload() }
            }
        }
    }

    private func name(_ item: UndoEntryVM) -> String {
        if let m = item.meme {
            if let a = library.primaryAsset(of: m.id), let n = a.originalName { return n }
            if let t = m.textExact ?? m.textVerbatim, !t.isEmpty { return String(t.prefix(24)) }
            return m.kind.categoryName
        }
        return item.entry.op == "stage_removed" ? "входящий элемент" : "элемент"
    }

    private func toggle() {
        expanded.toggle()
        if expanded, items.isEmpty { items = library.undoEntries(of: batch.id) }
    }
    private func reload() { items = library.undoEntries(of: batch.id) }
}
