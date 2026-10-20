import SwiftUI
import MemebooruCore
import UniformTypeIdentifiers

/// deviantART-2011 shell: dark green header across the top, "Просмотр / Категория" column on the left,
/// the page on the right. Detail pages open over the right side only, so the browse column stays put.
struct RootView: View {
    @Environment(Library.self) private var library
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    /// Phone: the browse column becomes a drawer behind the header's menu button.
    @State private var drawerOpen = false

    private var compact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        @Bindable var lib = library
        VStack(spacing: 0) {
            Header(compact: compact) { withAnimation(.easeOut(duration: 0.2)) { drawerOpen.toggle() } }.zIndex(3)
            if let b = library.busy { ProgressBar(label: b).zIndex(2) }
            if let label = library.lastUndoLabel { UndoBar(label: localizedHistoryLabel(label)).zIndex(2) }
            if let notice = library.notice { NoticeBar(text: notice).zIndex(2) }
            HStack(spacing: 0) {
                if !compact { BrowseSidebar() }
                DetailNavigator { page }
            }
            .overlay(alignment: .leading) { if compact { drawer } }
        }
        #if os(macOS)
        .ignoresSafeArea(.container, edges: .top)   // the header IS the title bar (traffic lights sit in it)
        #endif
        .onAppear { if UserDefaults.standard.bool(forKey: "openDrawer") { drawerOpen = true } }   // debug: -openDrawer YES
        .onChange(of: library.section) { drawerOpen = false }
        .onChange(of: library.query) { drawerOpen = false }
        .pageBackground()
        .foregroundStyle(Theme.text)
        .zfont(13)
        .environment(\.zoom, library.zoom)
        .environment(\.compactLayout, compact)
        .preferredColorScheme(.light)
        .tint(Theme.link)
        .focusEffectDisabled()   // no native blue focus rings — fields draw their own
        .background(TrafficLightAligner(centerY: Theme.headerHeight / 2))
        .fileImporter(isPresented: $lib.presentFileImporter, allowedContentTypes: [.image, .movie, .audio, .plainText, .folder], allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { library.stage(urls: urls) }
        }
        .fileImporter(isPresented: $lib.presentCollectionPicker, allowedContentTypes: [.folder]) { r in
            if case .success(let url) = r { library.open(url) }
        }
        .alert("Ошибка", isPresented: Binding(get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } })) {
            Button("OK") {}
        } message: { Text(library.errorMessage ?? "") }
        .dropDestination(for: URL.self) { urls, _ in library.stage(urls: urls); return true }
        // Its own view: two file importers on one view don't both work.
        .background {
            Color.clear.fileImporter(isPresented: $lib.presentCombineImporter, allowedContentTypes: [.image], allowsMultipleSelection: true) { r in
                if case .success(let urls) = r { library.combineFiles(urls) }
            }
        }
        .sheet(item: $lib.compositeEditor) { target in CompositeEditor(target: target).environment(library) }
        .sheet(item: $lib.editTarget) { target in EditSheet(target: target).environment(library) }
        .sheet(isPresented: $lib.presentXLogin) {
            XLoginView { session in library.setXSession(session) }
        }
        #if os(iOS)
        .sheet(item: $lib.sharedExport) { file in ActivityView(items: [file.url]) }
        #endif
    }

    /// Browse column sliding over the page from the left; tapping the dimmed page closes it.
    @ViewBuilder private var drawer: some View {
        if drawerOpen {
            ZStack(alignment: .leading) {
                Color.black.opacity(0.25).contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { drawerOpen = false } }
                    .transition(.opacity)
                BrowseSidebar().shadow(color: .black.opacity(0.25), radius: 8, x: 2)
                    .transition(.move(edge: .leading))
            }
            .ignoresSafeArea(edges: .bottom)
        }
    }

    @ViewBuilder private var page: some View {
        switch library.section {
        case .gallery: GalleryView()
        case .staging: StagingView()
        case .duplicates: DuplicatesView()
        case .tags: TagsView()
        case .sync: SyncView()
        case .history: UndoHistoryView()
        }
    }
}

// MARK: - Header ("overhead")

struct Header: View {
    @Environment(Library.self) private var library
    var compact = false
    var onMenu: () -> Void = {}

    var body: some View {
        Group {
            if compact {
                // Phone: menu · brand · Add on one row, the search pill full width under it.
                VStack(spacing: Space.s) {
                    HStack(spacing: Space.m) {
                        Button(action: onMenu) {
                            Image(systemName: "line.3.horizontal").font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(Theme.headerText).frame(width: Space.control + 8, height: Space.control + 8)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        brand
                        Spacer(minLength: Space.s)
                        AddMenu()
                    }
                    .frame(height: Theme.headerHeight)
                    SearchBox()
                }
                .padding(.horizontal, Space.m)
                .padding(.bottom, Space.m)
            } else {
                HStack(spacing: Space.xl) {
                    brand
                    SearchBox().frame(width: 300)
                    AddMenu()
                    Spacer(minLength: Space.l)
                    status
                }
                #if os(macOS)
                .padding(.leading, 84)            // traffic lights end at ~68pt; one 16pt gap after them
                #else
                .padding(.leading, Space.l)
                #endif
                .padding(.trailing, Space.l)      // + HeaderLink's own 8pt = text ends 24pt in, on the page gutter
                .frame(height: Theme.headerHeight)
            }
        }
        .background(LinearGradient(colors: [Theme.headerTop, Theme.headerBottom], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea(edges: .top))   // iOS: runs up under the status bar
        .overlay(alignment: .bottom) {
            VStack(spacing: 0) { Theme.headerLine.frame(height: 1); Theme.highlight.opacity(0.7).frame(height: 1) }
                .offset(y: 1)
        }
        #if os(macOS)
        .gesture(WindowDragGesture())
        #endif
    }

    /// "memeBOORU" — the site's own wordmark rhythm (light word + bold caps), with the framed logo tile.
    private var brand: some View {
        Button { library.go(.gallery) } label: {
            HStack(spacing: Space.s) {
                RoundedRectangle(cornerRadius: 3).fill(Theme.menu)
                    .frame(width: 24, height: 24)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.headerAccent, lineWidth: 2))
                    .overlay(Image(systemName: "face.smiling").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.headerAccent))
                HStack(spacing: 0) {
                    Text("meme").font(.custom(Theme.displayFamily, fixedSize: 20))
                    Text("BOORU").font(.custom(Theme.displayFamily, fixedSize: 17).weight(.bold))
                }
                .foregroundStyle(Theme.headerText)
                .fixedSize()
            }
        }
        .buttonStyle(.plain).linkPointer()
    }

    private var status: some View {
        HStack(spacing: Space.l) {
            if let b = library.busy {
                HStack(spacing: Space.s) { MBSpinner(color: Theme.headerAccent); Text(b).zfont(12).foregroundStyle(Theme.headerMuted).lineLimit(1) }
            }
            if library.waybackPending > 0 { WaybackStatus() }
            HeaderLink(title: library.name, symbol: "chevron.right.circle.fill", color: Theme.headerAccent) {
                library.presentCollectionPicker = true
            }
            .help("Текущая коллекция. Нажмите, чтобы открыть другую")
        }
    }
}

/// "Wayback: 3 tweets queued" — saved tweets waiting to be copied to web.archive.org (so they outlive
/// deletion on x.com). Says when it's paused or archive.org is turning requests away; a click pauses / resumes.
struct WaybackStatus: View {
    @Environment(Library.self) private var library
    @State private var hover = false

    var body: some View {
        let n = library.waybackPending
        let tweets = n == 1 ? "1 tweet" : "\(n) tweets"
        let label: String = {
            if !library.waybackEnabled { return "Wayback на паузе, ожидают: \(tweets)" }
            if let at = library.waybackRetryAt { return "Wayback занят: \(tweets), повтор в \(at.formatted(date: .omitted, time: .shortened))" }
            return "Сохраняем в Wayback: \(tweets)"
        }()
        Button { library.setWayback(enabled: !library.waybackEnabled) } label: {
            Text(label).zfont(12).foregroundStyle(hover ? Theme.headerText : Theme.headerMuted).underline(hover).lineLimit(1)
        }
        .buttonStyle(.plain).linkPointer()
        .onHover { hover = $0 }
        .help(library.waybackEnabled
              ? "Сохранённые твиты архивируются в Wayback Machine (web.archive.org), чтобы сохранить их после удаления из x.com. Нажмите для паузы."
              : "Архивация твитов в Wayback Machine приостановлена. Нажмите для продолжения.")
    }
}

/// Header menu item: light text + a small circled glyph, like "Deviant Login ⌄" / "Join … ▸".
struct HeaderLink: View {
    let title: String
    var symbol: String = "chevron.down.circle.fill"
    var color: Color = Theme.headerText
    var active = false
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.iconLabel) {
                Text(title).zfont(13).lineLimit(1).fixedSize()
                Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(Theme.headerMuted)
            }
            .foregroundStyle(color)
            .padding(.horizontal, Space.s).frame(height: Space.control + 4)
            .background(RoundedRectangle(cornerRadius: 4).fill(hover || active ? Color(hex: 0x46524A) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).linkPointer()
        .onHover { hover = $0 }
    }
}

/// Dark menu panel that hangs off the header (the site's `.oh-menu`).
struct HeaderMenuPanel<Content: View>: View {
    var width: CGFloat = 250
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.vertical, Space.xs)
            .frame(width: width, alignment: .leading)
            .background(Theme.menu)
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 4, bottomTrailingRadius: 4))
            .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 3)
    }
}

/// A row in a dark header menu: pale text, teal gradient highlight on hover (`.mi:hover`).
struct HeaderMenuRow: View {
    let title: String
    var symbol: String? = nil
    var danger = false
    var trailing: String? = nil
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s) {
                if let symbol { Image(systemName: symbol).font(.system(size: 12)).frame(width: 16) }
                Text(title).zfont(12).lineLimit(1)
                Spacer(minLength: Space.s)
                if let trailing { Text(trailing).zfont(11).foregroundStyle(Theme.headerMuted) }
            }
            .foregroundStyle(hover ? .white : (danger ? Color(hex: 0xF0A08F) : Theme.headerText))
            .padding(.horizontal, Space.m).frame(minHeight: Space.control)
            .background(hover ? LinearGradient(colors: [Color(hex: 0x518FA1), Color(hex: 0x39798D)], startPoint: .top, endPoint: .bottom) : nil)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).linkPointer()
        .onHover { hover = $0 }
    }
}

struct HeaderMenuSeparator: View {
    var body: some View { Color(hex: 0x2B3432).frame(height: 1).padding(.vertical, Space.xs) }
}

// MARK: - Left browse column

struct BrowseSidebar: View {
    @Environment(Library.self) private var library

    /// Kind meta-tags, shown like the site's category list.
    private static let kindTags: [(tag: String, title: String)] = [
        ("picture", "Изображения"), ("gif", "GIFs"), ("video", "Видео"), ("audio", "Аудио"),
        ("text", "Текст"), ("article", "Статьи"), ("tweet", "Твиты"),
    ]

    var body: some View {
        let usage = Dictionary(library.tags.map { ($0.tag.name, $0.usage) }, uniquingKeysWith: { a, _ in a })
        let popular = library.tags.filter { $0.tag.kind == .normal && $0.usage > 0 }
            .sorted { ($0.usage, $1.tag.name) > ($1.usage, $0.tag.name) }.prefix(16)
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                group("Просмотр") {
                    NavRow(title: "Коллекция", symbol: "photo.on.rectangle.angled", section: .gallery, count: nil)
                    NavRow(title: "Входящие", symbol: "tray.and.arrow.down", section: .staging, count: library.stagedItems.count)
                    NavRow(title: "Дубликаты", symbol: "square.on.square", section: .duplicates, count: library.duplicateClusters.count)
                    NavRow(title: "История", symbol: "clock.arrow.circlepath", section: .history, count: nil)
                }
                group("Управление") {
                    NavRow(title: "Теги", symbol: "tag", section: .tags, count: nil)
                    NavRow(title: "Синхронизация", symbol: "arrow.triangle.2.circlepath", section: .sync, count: library.sync.nearby.count)
                }
                let kinds = Self.kindTags.filter { (usage[$0.tag] ?? 0) > 0 }
                if !kinds.isEmpty {
                    group("Категория") {
                        ForEach(kinds, id: \.tag) { k in CategoryRow(title: k.title, tag: k.tag, count: usage[k.tag] ?? 0) }
                    }
                }
                if !popular.isEmpty {
                    group("Популярные теги") {
                        ForEach(Array(popular), id: \.id) { r in CategoryRow(title: r.tag.name, tag: r.tag.name, count: r.usage) }
                    }
                }
                collectionPill
            }
            .padding(.horizontal, Space.l)
            .padding(.top, Space.xl)          // same top as the page, so "Просмотр" lines up with the page title
            .padding(.bottom, Space.xxl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .frame(width: Theme.sidebarWidth)
        .background(Theme.sidebar)
        .overlay(alignment: .trailing) { Theme.sidebarRule.frame(width: 1) }
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ rows: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            SectionLabel(text: title)
            VStack(alignment: .leading, spacing: 0) { rows() }   // rows carry their own 4pt padding
        }
    }

    /// The "Mature Content Filter ON" pill, repurposed: which collection is open.
    private var collectionPill: some View {
        Button { library.presentCollectionPicker = true } label: {
            HStack(spacing: Space.iconLabel) {
                Image(systemName: "folder").font(.system(size: 11))
                Text("\(library.name) · публикаций: \(library.memeCount)").zfont(11).lineLimit(1)
            }
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, Space.s).padding(.vertical, Space.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.rule))
        }
        .buttonStyle(.plain).linkPointer()
        .help("Открыть другую коллекцию")
    }
}

/// Primary nav row: icon + label (+ count). Current page is rust-colored like "Deviations" on the site.
struct NavRow: View {
    @Environment(Library.self) private var library
    let title: String
    let symbol: String
    let section: Library.Section
    let count: Int?
    @State private var hover = false
    var body: some View {
        let selected = library.section == section   // stays lit on a post page, like "Deviations" on the site
        Button { library.go(section) } label: {
            HStack(spacing: Space.s) {
                Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: NavRow.iconWidth)
                    .foregroundStyle(selected ? Theme.selected : Theme.muted)
                Text(title).zfont(14)
                    .foregroundStyle(selected ? Theme.selected : (hover ? Theme.linkHover : Theme.link))
                    .underline(hover && !selected)
                Spacer(minLength: Space.xs)
                if let count, count > 0 { Text("\(count)").zfont(11).monospacedDigit().foregroundStyle(Theme.muted) }
            }
            .padding(.vertical, Space.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).linkPointer()
        .onHover { hover = $0 }
        .accessibilityIdentifier("nav.\(title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
    static let iconWidth: CGFloat = 18
    /// Where a nav row's label starts — category rows indent to exactly here, so all sidebar text shares one edge.
    static let labelInset: CGFloat = iconWidth + Space.s
}

/// Indented category link (a tag search), bold when it is the current query.
struct CategoryRow: View {
    @Environment(Library.self) private var library
    let title: String
    let tag: String
    let count: Int
    @State private var hover = false
    var body: some View {
        let current = library.query.trimmingCharacters(in: .whitespaces) == tag && library.section == .gallery
        Button { library.search(tag: tag) } label: {
            HStack(spacing: Space.xs) {
                Text(title).zfont(12, current ? .bold : .regular).lineLimit(1)
                    .foregroundStyle(current ? Theme.text : (hover ? Theme.linkHover : Theme.link))
                    .underline(hover && !current)
                Spacer(minLength: Space.xs)
                Text("\(count)").zfont(10).monospacedDigit().foregroundStyle(Theme.faint)
            }
            .padding(.leading, NavRow.labelInset).padding(.vertical, Space.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).linkPointer()
        .onHover { hover = $0 }
    }
}

// MARK: - Status strips

/// Progress strip shown during imports / long tasks.
struct ProgressBar: View {
    @Environment(Library.self) private var library
    let label: String
    var body: some View {
        HStack(spacing: Space.m) {
            MBSpinner()
            Text(label).zfont(12, .bold)
            Spacer()
            if library.busyCancellable {
                GlassButton(title: "Остановить", tint: Theme.danger) { library.cancelActiveImport() }
            }
        }
        .padding(.horizontal, Space.l).padding(.vertical, Space.s)
        .background(Color(hex: 0xEEF3C8))
        .overlay(alignment: .bottom) { Theme.goBorder.frame(height: 1) }
    }
}

/// Strip with a one-off piece of information (and where to go about it).
struct NoticeBar: View {
    @Environment(Library.self) private var library
    let text: String
    var body: some View {
        HStack(spacing: Space.m) {
            Image(systemName: "info.circle.fill").foregroundStyle(Theme.link)
            Text(text).zfont(12).foregroundStyle(Theme.text)
            Spacer()
            if let target = library.noticeAction {
                GlassButton(title: "Проверить") { library.go(target); library.notice = nil }
            }
            Button { library.notice = nil } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.muted) }
                .buttonStyle(.plain).linkPointer()
        }
        .padding(.horizontal, Space.l).padding(.vertical, Space.s)
        .background(Color(hex: 0xE4EEF1))
        .overlay(alignment: .bottom) { Theme.rule.frame(height: 1) }
    }
}

/// Strip with the last undoable action.
struct UndoBar: View {
    @Environment(Library.self) private var library
    let label: String
    var body: some View {
        HStack(spacing: Space.m) {
            Button { library.go(.history) } label: {
                HStack(spacing: Space.s) {
                    Image(systemName: "arrow.uturn.backward.circle").foregroundStyle(Theme.muted)
                    Text(label).zfont(12).foregroundStyle(Theme.text).accessibilityIdentifier("undoLabel")
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).linkPointer().help("Открыть историю для просмотра и восстановления")
            Spacer()
            GlassButton(title: "Отменить") { library.undoLast() }.accessibilityIdentifier("undoButton")
            Button { library.dismissUndo() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.muted) }
                .buttonStyle(.plain).linkPointer()
        }
        .padding(.horizontal, Space.l).padding(.vertical, Space.s)
        .background(Theme.surfaceSunk)
        .overlay(alignment: .bottom) { Theme.rule.frame(height: 1) }
    }
}

// MARK: - Add menu

/// "Добавить ⌄" header menu — a dark dropdown, no native `Menu`.
struct AddMenu: View {
    @Environment(Library.self) private var library
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// Phone: "Добавить" sits at the right edge, so the menu opens leftwards.
    private var menuAlignment: Alignment { sizeClass == .compact ? .topTrailing : .topLeading }
    #else
    private let menuAlignment = Alignment.topLeading
    #endif
    @State private var open = false
    @State private var showTweet = false
    @State private var showText = false
    @State private var input = ""
    var body: some View {
        HeaderLink(title: "Добавить", active: open) { open.toggle() }
            .help("Добавить мемы")
            .overlay(alignment: menuAlignment) {
                if open { dropdown.offset(y: Theme.headerHeight - 6).zIndex(100) }
            }
            .sheet(isPresented: $showTweet) { PromptSheet(title: "Ссылка на твит", text: $input, placeholder: "https://x.com/user/status/…") { library.importTweet(input); input = "" } }
            .sheet(isPresented: $showText) { PromptSheet(title: "Текстовый мем", text: $input, placeholder: "Вставить текст…", multiline: true) { library.stage(text: input); input = "" } }
    }

    private var dropdown: some View {
        HeaderMenuPanel(width: 250) {
            row("Файлы или папка…", "folder", trailing: "⌘O") { library.presentFileImporter = true }
            row("Коллаж…", "rectangle.split.2x1") { library.presentCombineImporter = true }
            row("Твит по ссылке…", "bird") { showTweet = true }
            row("Текст…", "text.alignleft") { showText = true }
            HeaderMenuSeparator()
            if library.xLoggedIn {
                row("Импорт понравившихся из x.com", "heart") { library.importLikes() }
                row("Импорт закладок x.com", "bookmark") { library.importBookmarks() }
                row("Выйти из x.com", "rectangle.portrait.and.arrow.right") { library.logoutX() }
            } else {
                row("Войти в x.com…", "person.crop.circle") { library.presentXLogin = true }
            }
            HeaderMenuSeparator()
            row(library.waybackEnabled ? "Приостановить архивацию Wayback" : "Продолжить архивацию Wayback",
                library.waybackEnabled ? "pause.circle" : "play.circle") { library.setWayback(enabled: !library.waybackEnabled) }
            row("Удалить все твиты…", "trash", danger: true) { library.deleteAllTweets() }
        }
    }

    private func row(_ title: String, _ symbol: String, danger: Bool = false, trailing: String? = nil, _ action: @escaping () -> Void) -> some View {
        HeaderMenuRow(title: title, symbol: symbol, danger: danger, trailing: trailing) { open = false; action() }
    }
}

// MARK: - Search

/// The header search pill: sunken field + "Поиск" button, tag suggestions in a dark dropdown.
struct SearchBox: View {
    @Environment(Library.self) private var library
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var lib = library
        HStack(spacing: 0) {
            TextField("", text: $lib.typedQuery, prompt: Text("теги, \"текст\", -исключение").foregroundStyle(Color(hex: 0x6F8175)))
                .textFieldStyle(.plain).zfont(12).foregroundStyle(Theme.text).focused($focused)
                .accessibilityIdentifier("searchField")
                .onSubmit { library.go(.gallery); focused = false }
                .onChange(of: library.wantSearchFocus) { _, v in if v { focused = true; library.wantSearchFocus = false } }
                .padding(.horizontal, Space.s)
            if !library.query.isEmpty {
                Button { library.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Color(hex: 0x6F8175))
                }.buttonStyle(.plain).linkPointer().padding(.trailing, Space.s)
            }
            Button { library.go(.gallery); focused = false } label: {
                Text("Поиск").zfont(12).foregroundStyle(Theme.headerAccent)
                    .padding(.horizontal, Space.s + 2).frame(maxHeight: .infinity)
                    .background(LinearGradient(colors: [Color(hex: 0x5E7064), Color(hex: 0x46554B)], startPoint: .top, endPoint: .bottom))
                    .overlay(alignment: .leading) { Color(hex: 0x2B3432).frame(width: 1) }
            }.buttonStyle(.plain).linkPointer().accessibilityIdentifier("searchButton")
        }
        .frame(height: 24)
        .background(LinearGradient(colors: [Color(hex: focused ? 0xE9F0E8 : 0xB3C1B5), Color(hex: focused ? 0xFDFFFC : 0xC9D5CA)], startPoint: .top, endPoint: .bottom))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(hex: 0x2B3432), lineWidth: 1))
        .overlay(alignment: .topLeading) {
            if focused, !suggestions.isEmpty {
                HeaderMenuPanel(width: 300) {
                    ForEach(suggestions, id: \.text) { s in
                        HeaderMenuRow(title: s.isAlias ? "\(s.text) → \(s.tag.name)" : s.text,
                                      symbol: s.tag.kind == .meta ? "tag.fill" : "tag",
                                      trailing: "\(s.usage)") { complete(with: s) }
                    }
                }
                .offset(y: 30).zIndex(10)
            }
        }
    }

    private var lastToken: (prefix: String, negated: Bool) {
        let last = library.query.split(separator: " ", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        return last.hasPrefix("-") ? (String(last.dropFirst()), true) : (last, false)
    }

    private var suggestions: [TagSuggestion] {
        let t = lastToken
        guard !t.prefix.isEmpty, !t.prefix.contains("\"") else { return [] }
        return library.suggestions(for: t.prefix).filter { $0.text != t.prefix }
    }

    private func complete(with s: TagSuggestion) {
        var parts = library.query.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let neg = lastToken.negated
        if parts.isEmpty { parts = [""] }
        parts[parts.count - 1] = (neg ? "-" : "") + s.text
        library.query = parts.joined(separator: " ") + " "
        library.go(.gallery)
    }
}

// MARK: - Shared bits

struct PromptSheet: View {
    let title: String
    @Binding var text: String
    var placeholder = ""
    var multiline = false
    let onSubmit: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text(title).dfont(20)
            if multiline {
                TextEditor(text: $text).scrollContentBackground(.hidden).zfont(13).frame(minHeight: 160).fieldChrome()
            } else {
                TextField(placeholder, text: $text).textFieldStyle(.plain).zfont(13).fieldChrome().onSubmit { onSubmit(); dismiss() }
            }
            HStack(spacing: Space.s) {
                Spacer()
                GlassButton(title: "Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                GlassButton(title: "Добавить", prominent: true) { onSubmit(); dismiss() }.keyboardShortcut(.defaultAction).disabled(text.isEmpty)
            }
        }
        .padding(Space.xl).frame(minWidth: 440)
        .background(Theme.surface)
        .preferredColorScheme(.light)
    }
}

/// Inline tag list: colored links separated by spaces, like a booru post page.
struct TagLine: View {
    let tags: [Tag]
    var size: CGFloat = 13
    var onRemove: ((Tag) -> Void)? = nil
    @Environment(Library.self) private var library
    var body: some View {
        FlowLayout(spacing: Space.m) {
            ForEach(tags, id: \.id) { t in
                HStack(spacing: Space.xs) {
                    LinkText(text: t.name, color: Theme.tagColor(t.kind), size: size) { library.search(tag: t.name) }
                    if let onRemove { LinkText(text: "×", color: Theme.faint, size: size - 1) { onRemove(t) } }
                }
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = Space.xs
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > w, x > 0 { x = 0; y += rowH + lineSpacing; rowH = 0 }
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
        return CGSize(width: w, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + lineSpacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
    }
}

extension MemeKind {
    var symbol: String {
        switch self {
        case .image: "photo"; case .gif: "livephoto"; case .video: "film"; case .audio: "waveform"
        case .text: "text.alignleft"; case .article: "newspaper"; case .tweet: "bird"
        }
    }
    /// Category name for "in …" captions.
    var categoryName: String {
        switch self {
        case .image: "Изображения"; case .gif: "GIF"; case .video: "Видео"; case .audio: "Аудио"
        case .text: "Текст"; case .article: "Статьи"; case .tweet: "Твиты"
        }
    }
}

// MARK: - Traffic lights

#if os(macOS)
import AppKit

/// The header doubles as the title bar, so the window buttons are re-centered vertically in it
/// (AppKit parks them at the top of a 28pt strip). Re-applied whenever AppKit lays the titlebar out again.
struct TrafficLightAligner: NSViewRepresentable {
    let centerY: CGFloat
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { context.coordinator.attach(to: v.window, centerY: centerY) }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { context.coordinator.attach(to: v.window, centerY: centerY) }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []
        private var centerY: CGFloat = 21
        private var applying = false

        func attach(to window: NSWindow?, centerY: CGFloat) {
            self.centerY = centerY
            guard let window else { return }
            if self.window !== window {
                observers.forEach(NotificationCenter.default.removeObserver)
                observers = []
                self.window = window
                let nc = NotificationCenter.default
                for name in [NSWindow.didResizeNotification, NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification] {
                    observers.append(nc.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.apply() })
                }
                for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                    guard let b = window.standardWindowButton(type) else { continue }
                    b.postsFrameChangedNotifications = true
                    observers.append(nc.addObserver(forName: NSView.frameDidChangeNotification, object: b, queue: .main) { [weak self] _ in self?.apply() })
                }
            }
            apply()
        }

        private func apply() {
            guard !applying, let window, !window.styleMask.contains(.fullScreen) else { return }
            applying = true; defer { applying = false }
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let b = window.standardWindowButton(type), let sv = b.superview else { continue }
                // Button center `centerY` points below the window's top edge (window coords are bottom-up),
                // converted into the button's superview (flipped or not, origin.y = mid − h/2 either way).
                let mid = sv.convert(NSPoint(x: 0, y: window.frame.height - centerY), from: nil)
                let y = mid.y - b.frame.height / 2
                if abs(b.frame.origin.y - y) > 0.5 { b.setFrameOrigin(NSPoint(x: b.frame.origin.x, y: y)) }
            }
        }
    }
}
#else
struct TrafficLightAligner: View { let centerY: CGFloat; var body: some View { EmptyView() } }
#endif
