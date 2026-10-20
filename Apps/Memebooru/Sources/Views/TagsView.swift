import SwiftUI
import MemebooruCore

/// Tag index like a booru's tag list: name, count, kind, aliases — one table in a box.
/// Reads `library.tags` (loaded in the model) so the count is right on the first frame — no 0→N flash.
struct TagsView: View {
    @Environment(Library.self) private var library
    @State private var filter = ""
    @State private var includeDeleted = false
    @State private var aliasInput: [Int64: String] = [:]

    private var visible: [TagRowModel] {
        library.tags
            .filter { includeDeleted || !$0.isDead }   // hide tags used only by deleted memes unless asked
            .filter { filter.isEmpty || $0.tag.name.contains(filter) || $0.aliases.contains { $0.contains(filter) } }
            .sorted { (count($0), $1.tag.name) > (count($1), $0.tag.name) }
    }
    private func count(_ r: TagRowModel) -> Int { includeDeleted ? r.usageAll : r.usage }

    var body: some View {
        PageColumn {
            PageHeader(title: "Теги", subtitle: plural(visible.count, "tag")) {
                MBToggle(isOn: $includeDeleted, label: "Включая удалённые")
                    .help("Учитывать теги удалённых публикаций")
                SteadyTextField(text: $filter, placeholder: "Фильтр тегов", size: 12)
                    .fieldChrome().frame(width: 200)
            }
            if visible.isEmpty {
                EmptyState(icon: "tag", title: filter.isEmpty ? "Тегов пока нет" : "Подходящих тегов нет",
                           subtitle: filter.isEmpty ? "Теги появятся здесь после добавления к публикациям." : "Нет совпадений с «\(filter)».")
            } else {
                Grid(alignment: .leading, horizontalSpacing: Space.xl, verticalSpacing: 0) {
                    GridRow {
                        head("Тег"); head("Коллекция"); head("Тип"); head("Алиасы").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.bottom, Space.s)
                    GridRow { Rule().gridCellColumns(4) }
                    ForEach(visible) { r in
                        GridRow(alignment: .firstTextBaseline) {
                            LinkText(text: r.tag.name, color: Theme.tagColor(r.tag.kind), size: 13, weight: .bold) { library.search(tag: r.tag.name) }
                            Text("\(count(r))").zfont(12).monospacedDigit().foregroundStyle(r.isDead ? Theme.danger : Theme.text)
                            LinkText(text: Theme.kindName(r.tag.kind), color: Theme.muted, size: 12) { library.setTagKind(r.tag, r.tag.kind == .meta ? .normal : .meta) }
                                .help("Нажмите для переключения между обычным тегом и метатегом")
                            aliases(r).frame(maxWidth: .infinity, alignment: .leading)   // last column takes the slack
                        }
                        .padding(.vertical, Space.s)
                        GridRow { Theme.rule.opacity(0.6).frame(height: 1).gridCellColumns(4) }
                    }
                }
                .card()
            }
        }
    }

    private func head(_ t: String) -> some View { Text(t).zfont(11, .bold).foregroundStyle(Theme.muted) }

    private func aliases(_ r: TagRowModel) -> some View {
        HStack(spacing: Space.m) {
            ForEach(r.aliases, id: \.self) { a in
                HStack(spacing: Space.xs) {
                    Text(a).zfont(12).foregroundStyle(Theme.text)
                    LinkText(text: "×", color: Theme.faint, size: 12) { library.removeAlias(a) }
                }
            }
            SteadyTextField(text: Binding(get: { aliasInput[r.tag.id] ?? "" }, set: { aliasInput[r.tag.id] = $0 }),
                            placeholder: "+ alias", size: 12,
                            onSubmit: { if let a = aliasInput[r.tag.id], !a.isEmpty { library.addAlias(a, to: r.tag); aliasInput[r.tag.id] = nil } })
                .frame(width: 120)
        }
    }
}
