import SwiftUI
import MemebooruCore

/// Staging as a page: the same grid as Posts (each item opens on its own page, like a post), or a list
/// of rows with their editors.
struct StagingView: View {
    @Environment(Library.self) private var library
    @Environment(\.zoom) private var zoom
    @Environment(\.compactLayout) private var compact
    @State private var selected: String?
    @FocusState private var filterFocused: Bool
    @State private var scroll = ScrollPosition(edge: .top)

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                let shown = library.shownStaged
                // Rows are heavy (cards, editors): only what's on screen is built. The grid is lazy itself.
                VStack(alignment: .leading, spacing: Space.l) {
                    header
                    if !library.stagedItems.isEmpty { toolbar }
                    if library.stagingGrid && library.stagingSelecting { SelectionBar() }
                    if library.stagingGrid {
                        grid(shown, width: geo.size.width)
                    } else {
                        LazyVStack(alignment: .leading, spacing: Space.l) {
                            ForEach(shown, id: \.id) { item in
                                StagedRow(item: item, expanded: selected == item.id) { selected = selected == item.id ? nil : item.id }
                            }
                        }
                    }
                    if !library.stagedItems.isEmpty && shown.isEmpty {
                        EmptyState(icon: "magnifyingglass", title: "Nothing matches",
                                   subtitle: "No staged items match “\(library.stagingFilter)”. Try other words or another kind.")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .pageInsets()
            }
            .scrollPosition($scroll)
        }
        .pageBackground()
        .onAppear { library.reloadStaging() }
        #if DEBUG
        // -autoScroll <points per second>: scrolls by itself, for recording how the page behaves.
        .task {
            let speed = UserDefaults.standard.double(forKey: "autoScroll")
            guard speed > 0 else { return }
            try? await Task.sleep(for: .seconds(2))
            for i in 0..<600 { scroll.scrollTo(y: CGFloat(i) * speed / 60); try? await Task.sleep(for: .milliseconds(16)) }
        }
        #endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            PageHeader(title: "Staging", subtitle: "\(library.stagedItems.count) pending") {
                GlassButton(title: "Commit all clean") { library.commitAllClean() }
                    .disabled(library.stagedItems.isEmpty)
                GlassButton(title: "Discard all", tint: Theme.danger) { library.discardAllStaged() }
                    .disabled(library.stagedItems.isEmpty)
                GlassButton(title: "Add files", symbol: "plus", prominent: true) { library.presentFileImporter = true }
            }
            if library.stagedItems.isEmpty {
                EmptyState(icon: "tray", title: "Nothing pending", subtitle: "Drop files anywhere in the window, or use Add in the header.")
            }
        }
    }

    private var toolbar: some View {
        @Bindable var lib = library
        let counts = Dictionary(grouping: library.stagedItems, by: \.kind).mapValues(\.count)
        return HStack(alignment: .center, spacing: Space.l) {
            if counts.count > 1 { KindTabs(counts: counts, total: library.stagedItems.count, selection: $lib.stagingKind) }
            Spacer(minLength: Space.l)
            if library.stagingGrid {
                LinkText(text: library.stagingSelecting ? "Done selecting" : "Select", size: 13, weight: library.stagingSelecting ? .bold : .regular) {
                    library.stagingSelecting.toggle()
                }
                .help("Choose several items: combine pictures into one meme, or commit / discard them together. ⌘-click also selects.")
                .accessibilityIdentifier("staging.select")
            }
            LayoutTabs(grid: $lib.stagingGrid)
            TextField("", text: $lib.stagingFilter, prompt: Text("Find in staging").foregroundStyle(Theme.faint))
                .textFieldStyle(.plain).zfont(12).focused($filterFocused)
                .accessibilityIdentifier("stagingFilter")
                .fieldChrome(focused: filterFocused)
                .frame(width: compact ? 160 : 240)
        }
    }

    /// The Posts grid: columns fill the page width exactly, every thumbnail centred in the same box.
    private func grid(_ items: [StagedItem], width: CGFloat) -> some View {
        let gap = Space.l
        let avail = max(0, width - (compact ? Space.l : Space.xl) * 2)
        let minCell = (compact ? GalleryCell.compactMinWidth : GalleryCell.minWidth) * zoom
        let n = max(1, Int((avail + gap) / (minCell + gap)))
        let cell = ((avail - gap * CGFloat(n - 1)) / CGFloat(n)).rounded(.down)
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(cell), spacing: gap, alignment: .top), count: n),
                         alignment: .leading, spacing: Space.xl) {
            ForEach(items, id: \.id) { StagedGalleryCell(item: $0, width: cell) }
        }
    }
}

/// What to do with the chosen items: combine the pictures, commit or discard them all.
struct SelectionBar: View {
    @Environment(Library.self) private var library
    var body: some View {
        let chosen = library.selectedStaged
        let pictures = chosen.filter(Library.combinable)
        HStack(spacing: Space.m) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(Theme.link)
            Text(chosen.isEmpty ? "Click items to choose them; pictures are combined in the order you click them."
                                : "\(chosen.count) chosen").zfont(12).foregroundStyle(Theme.text)
            Spacer(minLength: Space.m)
            GlassButton(title: pictures.count >= 2 ? "Combine \(pictures.count) pictures" : "Combine pictures", symbol: "rectangle.split.2x1", prominent: true) {
                library.compositeEditor = .new(pictures.map(\.id))
            }
            .disabled(pictures.count < 2 || pictures.count != chosen.count)
            .help(pictures.count != chosen.count ? "Only pictures can be combined (not GIFs, videos, tweets or texts)." : "Put them together into one meme")
            .accessibilityIdentifier("selection.combine")
            GlassButton(title: "Commit") { library.commitSelected() }.disabled(chosen.isEmpty)
            GlassButton(title: "Discard", tint: Theme.danger) { library.discardSelected() }.disabled(chosen.isEmpty)
            GlassButton(title: "Cancel") { library.stagingSelecting = false }
        }
        .padding(.horizontal, Space.m).padding(.vertical, Space.s)
        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border))
    }
}

/// "Grid  List" — how Staging lays out its items.
struct LayoutTabs: View {
    @Binding var grid: Bool
    var body: some View {
        HStack(spacing: Space.m) {
            tab("Grid", "square.grid.2x2", on: grid) { grid = true }.accessibilityIdentifier("layout.grid")
            tab("List", "list.bullet", on: !grid) { grid = false }.accessibilityIdentifier("layout.list")
        }
    }
    private func tab(_ title: String, _ symbol: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Space.xs) {
                Image(systemName: symbol).font(.system(size: 11))
                Text(title).zfont(13, on ? .bold : .regular)
            }
            .foregroundStyle(on ? Theme.text : Theme.link)
        }
        .buttonStyle(.plain).linkPointer()
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

struct StagedRow: View {
    @Environment(Library.self) private var library
    @Environment(\.zoom) private var zoom
    @Environment(\.compactLayout) private var compact
    let item: StagedItem
    let expanded: Bool
    let toggle: () -> Void
    @State private var userTags = ""
    @State private var metaTags = ""
    @State private var textExact = ""
    @State private var textVerbatim = ""
    @State private var context = ""

    private var thumbSide: CGFloat { (expanded ? 240 : 96) * zoom }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? Space.m : Space.l) {
            if item.kind == .tweet {
                // A tweet is reviewed as itself: the card (media, quote, the thread above on demand),
                // its tags and buttons beside it.
                let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.m))
                                     : AnyLayout(HStackLayout(alignment: .top, spacing: Space.l))
                layout {
                    StagedTweetPreview(item: item).frame(maxWidth: compact ? .infinity : 480)
                    VStack(alignment: .leading, spacing: Space.s) {
                        HStack(spacing: Space.l) {
                            LinkText(text: expanded ? "Done editing" : "Edit tags and text", color: Theme.link, size: 12, weight: .bold) { toggle() }
                            let model = library.tweetModel(staged: item, withQuote: false)
                            if !model.media.isEmpty {
                                LinkText(text: model.mediaOnly ? "Show as tweet" : "Show as media only", color: Theme.link, size: 12, weight: .bold) {
                                    library.toggleTweetDisplay(staged: item)
                                }
                            }
                        }
                        tags; notes
                    }
                    if !compact { Spacer(minLength: Space.l) }
                    actions
                }
            } else if compact {
                // Phone: thumb + name on top, notes full width, buttons last.
                HStack(alignment: .top, spacing: Space.m) {
                    StagedThumb(item: item, size: thumbSide).onTapGesture(perform: toggle).linkPointer()
                    VStack(alignment: .leading, spacing: Space.xs) { title; tags }
                }
                notes
                actions
            } else {
                HStack(alignment: .top, spacing: Space.l) {
                    StagedThumb(item: item, size: thumbSide).onTapGesture(perform: toggle).linkPointer()
                    VStack(alignment: .leading, spacing: Space.s) { title; tags; notes }
                    Spacer(minLength: Space.l)
                    actions
                }
            }
            if expanded {
                VStack(alignment: .leading, spacing: Space.m) {
                    Field(title: "General tags", text: $userTags, tint: Theme.general, onCommit: save)
                    Field(title: "Meta tags", text: $metaTags, tint: Theme.meta, onCommit: save)
                    Field(title: "Text", text: $textExact, onCommit: save)
                    Field(title: "Verbatim", text: $textVerbatim, onCommit: save)
                    Field(title: "Context", text: $context, lines: 3, onCommit: save)
                    HStack { Spacer(); GlassButton(title: "Save") { save() } }.frame(maxWidth: Theme.fieldMaxWidth)
                }
                .padding(.leading, compact || item.kind == .tweet ? 0 : thumbSide + Space.l)   // editor lines up with the text column
                .task(id: item.id) {
                    userTags = item.userTags.joined(separator: " "); metaTags = item.suggestedTags.joined(separator: " ")
                    textExact = item.textExact ?? ""; textVerbatim = item.textVerbatim ?? ""; context = item.context ?? ""
                }
            }
        }
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("stagedRow")
    }

    @ViewBuilder private var title: some View {
        let name = LinkText(text: item.originalName ?? item.id, color: Theme.link, size: 13, weight: .bold) { toggle() }
        let origin = Text("\(item.kind.categoryName) · from \(item.source)").zfont(11).foregroundStyle(Theme.muted)
        if compact { name; origin } else {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) { name; origin }
        }
    }

    private var tags: some View {
        FlowLayout(spacing: Space.m) {
            ForEach(item.userTags, id: \.self) { Text($0).zfont(12).foregroundStyle(Theme.general) }
            ForEach(item.suggestedTags, id: \.self) { Text($0).zfont(12).foregroundStyle(Theme.meta) }
        }
    }

    /// Format caution and possible duplicates.
    @ViewBuilder private var notes: some View {
        if item.compatibility == .uncommon { StagedFormatChoice(item: item).padding(.top, compact ? 0 : Space.xs) }
        let dups = library.duplicates(of: item)
        if !dups.isEmpty {
            FlowLayout(spacing: Space.s) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(Theme.danger)
                Text("\(dups.count) possible duplicate\(dups.count == 1 ? "" : "s")").zfont(12, .bold).foregroundStyle(Theme.danger)
                ForEach(Array(dups.enumerated()), id: \.offset) { _, h in
                    if let id = h.memeID, let m = library.meme(id) {
                        Button { library.openDetail(id) } label: { ThumbMini(meme: m).thumbShadow() }.buttonStyle(.plain).linkPointer()
                    }
                }
            }
            .padding(.top, compact ? 0 : Space.xs)
        }
    }

    private var actions: some View {
        HStack(spacing: Space.s) {
            GlassButton(title: item.willConvert && library.canConvert ? "Convert & commit" : "Commit", prominent: true) { save(); library.commit(item) }
            GlassIconButton(symbol: "trash", tint: Theme.danger) { library.discard(item) }
        }
    }

    private func save() {
        guard expanded else { return }
        var i = item
        i.userTags = userTags.split(separator: " ").map(String.init)
        i.suggestedTags = metaTags.split(separator: " ").map(String.init)
        i.textExact = textExact.isEmpty ? nil : textExact
        i.textVerbatim = textVerbatim.isEmpty ? nil : textVerbatim
        i.context = context.isEmpty ? nil : context
        library.updateStaged(i)
    }
}

struct StagedThumb: View {
    @Environment(Library.self) private var library
    let item: StagedItem
    var size: CGFloat = 96
    var body: some View {
        Group {
            if [.image, .gif, .video].contains(item.kind) {
                // Any picture or video format: a real frame (made on the media pool, ffmpeg for what the OS can't read).
                LoadedImage(key: "staged:" + item.sha256, fit: .fit, load: { await $0.loadStagedThumbnail(item) }) { failed in
                    LitCard(label: item.kind.rawValue.uppercased()) {
                        Group {
                            if failed { Image(systemName: item.kind.symbol).font(.system(size: 22)).foregroundStyle(Theme.faint) }
                            else { MBSpinner() }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .thumbShadow()
                .overlay(alignment: .bottomLeading) {
                    if item.kind == .video {
                        Image(systemName: "play.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            .padding(5).background(Theme.menu.opacity(0.75), in: Circle()).padding(Space.xs)
                    }
                }
            } else if item.kind == .text || item.kind == .tweet {
                LitCard(label: "TEXT") {
                    Text(item.textVerbatim ?? "").zfont(11).foregroundStyle(Color(hex: 0x222222))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(Space.s)
                }.thumbShadow()
            } else {
                LitCard(label: item.kind.rawValue.uppercased()) {
                    Image(systemName: item.kind.symbol).font(.system(size: 22)).foregroundStyle(Theme.faint)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }.thumbShadow()
            }
        }
        .frame(width: size, height: size)
    }
}

/// Caution note on a staged file in an uncommon format: what it is, and the two choices for commit.
struct StagedFormatChoice: View {
    @Environment(Library.self) private var library
    let item: StagedItem

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            let icon = Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(Theme.warnInk)
            let format = Text("Uncommon format: \(item.formatLabel)").zfont(12, .bold).foregroundStyle(Theme.warnInk)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: Space.iconLabel) {
                    icon; format
                    Text("— Telegram, phones and browsers may not open it.").zfont(12).foregroundStyle(Theme.muted)
                }
                // Narrow: the explanation wraps under the format name.
                HStack(alignment: .firstTextBaseline, spacing: Space.iconLabel) {
                    icon
                    VStack(alignment: .leading, spacing: Space.xs) {
                        format
                        Text("Telegram, phones and browsers may not open it.").zfont(12).foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if library.canConvert, let target = item.popularTarget {
                MBToggle(isOn: Binding(get: { item.willConvert }, set: { v in var i = item; i.convert = v; library.updateStaged(i) }),
                         label: "Convert to \(target.label) when adding")
                MBToggle(isOn: Binding(get: { item.willKeepOriginal }, set: { v in var i = item; i.keepOriginal = v; library.updateStaged(i) }),
                         label: "Also keep the original \(item.formatLabel)")
                    .disabled(!item.willConvert)
                    .opacity(item.willConvert ? 1 : 0.45)
            } else {
                Text("Converting needs the media tools (ffmpeg); it will be added as it is.").zfont(12).foregroundStyle(Theme.muted)
            }
        }
        .padding(Space.m)
        .frame(maxWidth: Theme.fieldMaxWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.warnBackground))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.warnBorder))
    }
}

/// A staged tweet as it will be saved: the card, and the thread it replies to (fetched with it) on demand.
struct StagedTweetPreview: View {
    @Environment(Library.self) private var library
    let item: StagedItem
    @State private var showThread = false

    var body: some View {
        let chain = library.stagedChain(item)
        let ancestors = library.stagedAncestors(of: item, chain: chain)
        VStack(alignment: .leading, spacing: 0) {
            if !ancestors.isEmpty {
                if showThread {
                    ForEach(ancestors.reversed(), id: \.id) { a in
                        TweetCardView(model: library.tweetModel(staged: a, chain: chain), maxMediaHeight: 200)
                        Rectangle().fill(Theme.border).frame(width: 2, height: Space.m).padding(.leading, Space.l + 21)
                    }
                } else {
                    LinkText(text: "Show the \(ancestors.count == 1 ? "tweet" : "\(ancestors.count) tweets") it replies to", color: Theme.link, size: 12) {
                        showThread = true
                    }
                    .padding(.bottom, Space.s)
                }
            }
            TweetCardView(model: library.tweetModel(staged: item, chain: chain), maxMediaHeight: 280)
        }
    }
}

/// "All · Tweets · Pictures" — the site's text tabs: the current one dark and bold.
struct KindTabs: View {
    let counts: [MemeKind: Int]
    let total: Int
    @Binding var selection: MemeKind?

    var body: some View {
        FlowLayout(spacing: Space.l) {
            tab(nil, "All", total)
            ForEach(MemeKind.allCases.filter { counts[$0] != nil }, id: \.self) { k in tab(k, k.categoryName, counts[k] ?? 0) }
        }
    }

    private func tab(_ k: MemeKind?, _ title: String, _ n: Int) -> some View {
        let on = selection == k
        return Button { selection = k } label: {
            HStack(spacing: Space.xs) {
                Text(title).zfont(13, on ? .bold : .regular).foregroundStyle(on ? Theme.text : Theme.link)
                Text("\(n)").zfont(11).foregroundStyle(Theme.muted)
            }
        }
        .buttonStyle(.plain).linkPointer()
        .accessibilityIdentifier("kindTab.\(k?.rawValue ?? "all")")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
