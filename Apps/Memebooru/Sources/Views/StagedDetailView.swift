import SwiftUI
import MemebooruCore

// MARK: - Grid cell

/// A staged item in the Staging grid: the same cell as a post's in Posts.
struct StagedGalleryCell: View {
    @Environment(Library.self) private var library
    @Environment(\.zoom) private var zoom
    let item: StagedItem
    let width: CGFloat
    @State private var titleHover = false

    var body: some View {
        let box = CGSize(width: width, height: GalleryCell.boxHeight * zoom)
        VStack(spacing: Space.s) {
            Button { open() } label: {
                StagedArt(item: item, size: StagedArt.fitted(item, in: box, library: library))
                    .frame(width: box.width, height: box.height)
                    .contentShape(Rectangle())
                    .overlay(alignment: .topLeading) { if library.stagingSelecting { check } }
            }
            .buttonStyle(.plain).linkPointer()
            .accessibilityIdentifier("stagedCell")
            .accessibilityLabel(item.reviewTitle)
            .contextMenu {
                Button(item.willConvert && library.canConvert ? "Convert & commit" : "Commit") { library.commit(item) }
                Button("Discard", role: .destructive) { library.discard(item) }
            }

            VStack(spacing: Space.xs / 2) {
                Text(item.reviewTitle).zfont(12, .bold).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(titleHover ? Theme.linkHover : Theme.link)
                    .underline(titleHover)
                    .onHover { titleHover = $0 }
                    .onTapGesture { open() }
                    .linkPointer()
                HStack(spacing: Space.xs) {
                    Text("in").foregroundStyle(Theme.text)
                    LinkText(text: item.kind.categoryName, color: Theme.muted, size: 11) { library.stagingKind = item.kind }
                }
                .zfont(11)
            }
            .frame(width: width)
        }
    }
}

extension StagedGalleryCell {
    /// Opens the item — or, while choosing (or on ⌘-click), adds it to / takes it out of the choice.
    private func open() {
        #if os(macOS)
        if !library.stagingSelecting, NSEvent.modifierFlags.contains(.command) { library.stagingSelecting = true }
        #endif
        if library.stagingSelecting { library.toggleSelected(item) } else { library.openStaged = item.id }
    }

    /// A tick with the item's place in the choice (the order pictures are combined in).
    @ViewBuilder private var check: some View {
        let n = library.stagingSelection.firstIndex(of: item.id)
        ZStack {
            Circle().fill(n != nil ? Theme.link : Theme.paper.opacity(0.9))
            Circle().stroke(n != nil ? Color.white : Theme.buttonBorder, lineWidth: 1.5)
            if let n { Text("\(n + 1)").font(.system(size: 11, weight: .heavy)).foregroundStyle(.white) }
        }
        .frame(width: 22, height: 22)
        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
        .padding(Space.s)
    }
}

/// A staged item drawn at an exact size, like `ThumbCell` draws a post: pictures at their own shape,
/// GIFs playing, videos previewing on hover, tweets as cards, text and audio as literature cards.
struct StagedArt: View {
    @Environment(Library.self) private var library
    let item: StagedItem
    let size: CGSize

    var body: some View {
        content
            .frame(width: size.width, height: size.height)
            .clipped()
            .overlay(alignment: .topTrailing) {
                if item.kind == .gif {
                    Text("GIF").font(.system(size: 8, weight: .heavy)).foregroundStyle(.white)
                        .padding(.horizontal, 3).padding(.vertical, 1)
                        .background(Theme.menu.opacity(0.8), in: RoundedRectangle(cornerRadius: 2)).padding(Space.xs)
                }
            }
            .thumbShadow()
    }

    @ViewBuilder private var content: some View {
        let url = library.stagedFileURL(item)
        switch item.kind {
        case .tweet:
            TweetCardView(model: library.tweetModel(staged: item, chain: library.stagedChain(item)), compact: true)
        case .image, .gif, .video:
            ZStack {
                Theme.surfaceSunk
                LoadedImage(key: "staged:" + item.sha256, load: { await $0.loadStagedThumbnail(item) }) { failed in
                    if failed { Image(systemName: item.kind.symbol).font(.system(size: 22)).foregroundStyle(Theme.faint) }
                    else { MBSpinner() }
                }
                if item.kind == .gif, let url, url.pathExtension.lowercased() == "gif" { AnimatedGif(url: url) }
                if item.kind == .video {
                    HoverVideo(url: Library.avPlayable(ext: item.ext, codecs: item.info.codecs) ? url : nil, poster: nil)
                }
            }
        case .audio:
            LitCard(label: "AUDIO") {
                Image(systemName: "waveform").font(.system(size: 22)).foregroundStyle(Theme.faint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .text, .article:
            LitCard(label: item.kind == .article ? "ARTICLE" : "TEXT") {
                Text((item.textVerbatim ?? item.textExact ?? "…").trimmingCharacters(in: .whitespacesAndNewlines))
                    .zfont(12).foregroundStyle(Color(hex: 0x222222)).lineSpacing(1).minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(Space.s)
            }
        }
    }

    /// The item's shape fitted into `box` (cards keep one shape, as in Posts).
    @MainActor static func fitted(_ item: StagedItem, in box: CGSize, library: Library) -> CGSize {
        switch item.kind {
        case .text, .article, .audio: return CGSize(width: min(box.width, box.height * 1.2), height: box.height * 0.84)
        case .tweet: return library.stagedMediaOnlyAspect(item).map { fit($0, in: box) } ?? box
        default: return fit(item.aspect ?? 4.0 / 3.0, in: box)
        }
    }

    static func fit(_ aspect: CGFloat, in box: CGSize) -> CGSize {
        let a = max(0.2, aspect)
        return a > box.width / box.height ? CGSize(width: box.width, height: (box.width / a).rounded())
                                          : CGSize(width: (box.height * a).rounded(), height: box.height)
    }
}

extension StagedDetailView {
    /// "Crop edges…", "Crop and trim…", "Trim…" — and "Edit crop…" once done.
    static func editTitle(_ kind: MemeKind, edited: Bool) -> String {
        switch kind {
        case .audio: edited ? "Edit trim…" : "Trim quiet ends…"
        case .video: edited ? "Edit crop and trim…" : "Crop and trim…"
        default: edited ? "Edit crop…" : "Crop edges…"
        }
    }
    static func editSymbol(_ kind: MemeKind) -> String { kind == .audio ? "waveform.path" : "crop" }

    /// "cropped to 200 × 120, 0:01.500–0:04.000 kept".
    static func describe(_ e: MediaEdit, kind: MemeKind) -> String {
        var parts: [String] = []
        if let c = e.crop { parts.append("cropped to \(c.width) × \(c.height)") }
        if let t = e.trim { parts.append("\(TimeField.format(t.startMs))–\(TimeField.format(t.endMs)) kept") }
        return parts.joined(separator: ", ") + " (original kept)"
    }
}

extension StagedItem {
    /// Staged items have no titles either: the tweet's author, the file's name, the text's first words.
    var reviewTitle: String {
        if case .tweet(let p) = payload, !p.handle.isEmpty { return "@" + p.handle }
        // A pasted text's "file" is a temporary one: its words say more.
        if kind == .text || kind == .article {
            let t = (textVerbatim ?? textExact ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let line = t.split(separator: "\n").first else { return kind.categoryName }
            return String(line.prefix(60))
        }
        if let n = originalName, kind != .tweet { return (n as NSString).deletingPathExtension }
        return kind.categoryName
    }

    /// Width / height when the file was measured.
    var aspect: CGFloat? {
        guard let w = info.width, let h = info.height, w > 0, h > 0 else { return nil }
        return CGFloat(w) / CGFloat(h)
    }
}

extension Library {
    /// Width / height of a staged tweet shown as bare media; nil when it's shown as a tweet.
    func stagedMediaOnlyAspect(_ item: StagedItem) -> CGFloat? {
        let m = tweetModel(staged: item, withQuote: false)
        guard m.mediaOnly, let first = m.media.first else { return nil }
        return m.media.count > 1 ? 1 : first.aspect ?? cachedPoster(first.url).map { $0.size.width / max(1, $0.size.height) } ?? 1
    }
}

// MARK: - Page

/// A staged item on its own page, laid out like a post's: the item itself, its text and tags to edit on
/// the left; Commit, Discard, the previous / next item and the file's details on the right.
/// Committing or discarding goes straight on to the next item, so a long import is reviewed in one pass.
struct StagedDetailView: View {
    @Environment(Library.self) private var library
    @Environment(\.zoom) private var zoom
    let id: String
    @State private var userTags = ""
    @State private var metaTags = ""
    @State private var textExact = ""
    @State private var textVerbatim = ""
    @State private var context = ""
    @State private var showFields = false
    @State private var showThread = true

    var body: some View {
        if let item = library.stagedItems.first(where: { $0.id == id }) {
            GeometryReader { geo in
                ScrollViewReader { proxy in
                    ScrollView {
                        let wide = geo.size.width >= 900
                        let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: Space.xxl))
                                          : AnyLayout(VStackLayout(alignment: .leading, spacing: Space.xl))
                        VStack(alignment: .leading, spacing: Space.l) {
                            breadcrumb(item)
                            layout {
                                mainColumn(item, geo)
                                sideColumn(item)
                                    .frame(width: wide ? sideWidth : nil)
                                    .frame(maxWidth: wide ? nil : .infinity, alignment: .leading)
                            }
                        }
                        .pageInsets()
                    }
                    // A reply opens on the tweet itself; the thread above is a scroll up (as on x.com).
                    .task(id: id) {
                        guard item.kind == .tweet, !library.stagedAncestors(of: item, chain: library.stagedChain(item)).isEmpty else { return }
                        try? await Task.sleep(for: .milliseconds(30))
                        proxy.scrollTo(TweetThreadView.focalID, anchor: .top)
                    }
                }
            }
            .pageBackground()
            .task(id: id) { seed(item) }
            .background { shortcuts(item) }
        } else {
            Color.clear.pageBackground()
        }
    }

    private var sideWidth: CGFloat { Theme.detailSidebarWidth * min(zoom, 1.2) }
    private var isTextKind: Bool { [.text, .article].contains(library.stagedItems.first { $0.id == id }?.kind) }

    private func seed(_ item: StagedItem) {
        userTags = item.userTags.joined(separator: " ")
        metaTags = item.suggestedTags.joined(separator: " ")
        textExact = item.textExact ?? ""; textVerbatim = item.textVerbatim ?? ""; context = item.context ?? ""
        showFields = false
    }

    /// The item with this page's edits, saved.
    @discardableResult
    private func save(_ item: StagedItem) -> StagedItem {
        var i = item
        i.userTags = userTags.split(separator: " ").map(String.init)
        i.suggestedTags = metaTags.split(separator: " ").map(String.init)
        i.textExact = textExact.isEmpty ? nil : textExact
        i.textVerbatim = textVerbatim.isEmpty ? nil : textVerbatim
        i.context = context.isEmpty ? nil : context
        if i != item { library.updateStaged(i) }
        return i
    }

    private func go(_ item: StagedItem, _ delta: Int) {
        guard let next = library.stagedNeighbor(of: item.id, delta) else { return }
        save(item)
        library.openStaged = next.id
    }

    // MARK: Main column

    private func breadcrumb(_ item: StagedItem) -> some View {
        HStack(spacing: Space.xs) {
            LinkText(text: "‹ Staging", size: 12) { save(item); library.popDetail() }.accessibilityIdentifier("stagedBack")
            Text("/").zfont(12).foregroundStyle(Theme.faint)
            LinkText(text: item.kind.categoryName, size: 12) { save(item); library.stagingKind = item.kind; library.popDetail() }
            if let n = library.shownStaged.firstIndex(where: { $0.id == item.id }) {
                Text("· \(n + 1) of \(library.shownStaged.count)").zfont(12).foregroundStyle(Theme.muted)
                    .accessibilityIdentifier("stagedPosition")
            }
        }
    }

    private func mainColumn(_ item: StagedItem, _ geo: GeometryProxy) -> some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            VStack(alignment: .leading, spacing: Space.m) {
                stage(item, geo)
                if item.compatibility == .uncommon { StagedFormatChoice(item: item) }
                duplicates(item)
            }
            titleBlock(item)
            VStack(alignment: .leading, spacing: Space.m) { fields(item) }
            SectionBlock("Tags") {
                tagField("General", $userTags, "stalin child glasses", Theme.general, item)
                tagField("Meta", $metaTags, "2022 picture source_unknown", Theme.meta, item)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func stage(_ item: StagedItem, _ geo: GeometryProxy) -> some View {
        let url = library.stagedFileURL(item)
        let maxH = min(geo.size.height * 0.68, 760)
        switch item.kind {
        case .tweet:
            StagedThreadView(item: item, maxMediaHeight: max(260, geo.size.height - 300))
        case .image:
            Group {
                if let url, let img = library.displayImage(url) { Image(platform: img).resizable().scaledToFit() }
                else { StagedArt(item: item, size: CGSize(width: 320, height: 240)) }
            }
            .aspectRatio(item.aspect ?? 4.0 / 3.0, contentMode: .fit)
            .frame(maxHeight: maxH).thumbShadow().frame(maxWidth: .infinity)
        case .gif:
            Group { if let url { AnimatedGif(url: url) } }
                .aspectRatio(item.aspect ?? 4.0 / 3.0, contentMode: .fit)
                .frame(maxHeight: maxH).thumbShadow().frame(maxWidth: .infinity)
        case .video:
            ZStack {
                LoadedImage(key: "staged:" + item.sha256, fit: .fit, load: { await $0.loadStagedThumbnail(item) }) { _ in Theme.surfaceSunk }
                if let url, Library.avPlayable(ext: item.ext, codecs: item.info.codecs) {
                    MediaPlayer(url: url)
                } else {
                    Text("\(item.formatLabel) plays here once it's converted on commit.").zfont(12, .bold).foregroundStyle(Theme.text)
                        .padding(Space.m).background(RoundedRectangle(cornerRadius: 4).fill(Theme.paper.opacity(0.9)))
                }
            }
            .aspectRatio(item.aspect ?? 16.0 / 9.0, contentMode: .fit)
            .frame(maxHeight: maxH).thumbShadow().frame(maxWidth: .infinity)
        case .audio:
            if let url { MediaPlayer(url: url, isAudio: true) }
        case .text, .article:
            TextField("", text: $textVerbatim, axis: .vertical)
                .lineLimit(1...).textFieldStyle(.plain).zfont(17).lineSpacing(4)
                .foregroundStyle(Color(hex: 0x222222))
                .onSubmit { save(item) }
                .frame(maxWidth: Theme.fieldMaxWidth, alignment: .leading)
                .padding(.horizontal, Space.xl).padding(.vertical, Space.xl)
                .background(Theme.paper)
                .overlay(Rectangle().stroke(Theme.border))
                .thumbShadow()
                .frame(maxWidth: .infinity)
        }
    }

    /// Already in the collection (or staged twice): the matches, each opening its post.
    @ViewBuilder private func duplicates(_ item: StagedItem) -> some View {
        let dups = library.duplicates(of: item)
        if !dups.isEmpty {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(alignment: .firstTextBaseline, spacing: Space.iconLabel) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(Theme.danger)
                    Text("\(dups.count) possible duplicate\(dups.count == 1 ? "" : "s") already here").zfont(12, .bold).foregroundStyle(Theme.danger)
                }
                FlowLayout(spacing: Space.s) {
                    ForEach(Array(dups.enumerated()), id: \.offset) { _, h in
                        if let mid = h.memeID, let m = library.meme(mid) {
                            Button { library.openDetail(mid) } label: { ThumbMini(meme: m).thumbShadow() }.buttonStyle(.plain).linkPointer()
                        }
                    }
                }
            }
            .padding(Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.warnBackground))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.warnBorder))
        }
    }

    private func titleBlock(_ item: StagedItem) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .top, spacing: Space.m) {
                RoundedRectangle(cornerRadius: 3).fill(Theme.surface)
                    .frame(width: 44, height: 44)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.border))
                    .overlay(Image(systemName: item.kind.symbol).font(.system(size: 18)).foregroundStyle(Theme.muted))
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(title(item)).dfont(24).foregroundStyle(Theme.text).lineLimit(2)
                        .shadow(color: .white.opacity(0.7), radius: 0, x: 0, y: 1)
                        .accessibilityIdentifier("stagedTitle")
                    HStack(spacing: Space.xs) {
                        Text("in").foregroundStyle(Theme.text)
                        LinkText(text: item.kind.categoryName, size: 12) { save(item); library.stagingKind = item.kind; library.popDetail() }
                        Text("· from \(item.source) · staged " + Date(timeIntervalSince1970: Double(item.addedAt) / 1000).formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(Theme.muted)
                    }
                    .zfont(12)
                }
            }
            Rule()
        }
    }

    private func title(_ item: StagedItem) -> String {
        if case .tweet(let p) = item.payload { return "\(p.authorName) @\(p.handle)" }
        return item.reviewTitle
    }

    private var hasAnyText: Bool { !textExact.isEmpty || (!isTextKind && !textVerbatim.isEmpty) || !context.isEmpty }

    @ViewBuilder private func fields(_ item: StagedItem) -> some View {
        if hasAnyText || showFields {
            Field(title: "Text", text: $textExact, lines: 2) { save(item) }
            if !isTextKind {
                Field(title: "Verbatim — as written in the meme, typos included", text: $textVerbatim, lines: 2) { save(item) }
            }
            Field(title: "Context", text: $context, lines: 3) { save(item) }
        } else {
            LinkText(text: isTextKind ? "+ Add context" : "+ Add text or context", size: 12) { showFields = true }
        }
    }

    private func tagField(_ title: String, _ line: Binding<String>, _ placeholder: String, _ tint: Color, _ item: StagedItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            Text(title).zfont(12).foregroundStyle(Theme.muted).frame(width: 64 * zoom, alignment: .leading)
            SteadyTextField(text: line, placeholder: placeholder, size: 13, color: tint, onSubmit: { save(item) })
                .fieldChrome()
                .frame(maxWidth: Theme.fieldMaxWidth)
        }
    }

    // MARK: Side column

    private func sideColumn(_ item: StagedItem) -> some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            neighbors(item)
            actions(item)
            details(item)
        }
    }

    @ViewBuilder private func neighbors(_ item: StagedItem) -> some View {
        let prev = library.stagedNeighbor(of: item.id, -1)
        let next = library.stagedNeighbor(of: item.id, 1)
        if prev != nil || next != nil {
            SectionBlock("More from Staging") {
                HStack(alignment: .top, spacing: Space.l) {
                    neighbor(prev, item, next: false)
                    neighbor(next, item, next: true)
                }
            }
        }
    }

    @ViewBuilder private func neighbor(_ other: StagedItem?, _ item: StagedItem, next: Bool) -> some View {
        // Two boxes exactly fill the column: (column − 16 gap) / 2 wide, 4:3.
        let w = ((sideWidth - Space.l) / 2).rounded(.down)
        let box = CGSize(width: w, height: (w * 0.75).rounded())
        VStack(spacing: Space.s) {
            if let other {
                Button { go(item, next ? 1 : -1) } label: {
                    StagedArt(item: other, size: StagedArt.fitted(other, in: box, library: library))
                        .frame(width: box.width, height: box.height)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).linkPointer()
                LinkText(text: next ? "Next ›" : "‹ Previous", size: 12, weight: .bold) { go(item, next ? 1 : -1) }
                    .accessibilityIdentifier(next ? "stagedNext" : "stagedPrevious")
            } else {
                Color.clear.frame(width: box.width, height: box.height)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func actions(_ item: StagedItem) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Button { library.commitAndAdvance(save(item)) } label: {
                HStack(spacing: Space.s) {
                    Image(systemName: "checkmark").font(.system(size: 16, weight: .semibold))
                    Text(item.willConvert && library.canConvert ? "Convert & commit" : "Commit").dfont(18, .regular)
                }
                .foregroundStyle(Theme.goText)
                .padding(.horizontal, Space.l).frame(height: 40)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 4).fill(LinearGradient(colors: [Theme.goTop, Theme.goBottom], startPoint: .top, endPoint: .bottom)))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.goBorder))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).linkPointer()
            .help("Add it to the collection and open the next one (⌘↩)")
            .accessibilityIdentifier("stagedCommit")

            VStack(alignment: .leading, spacing: Space.s) {
                if item.kind == .tweet, !library.tweetModel(staged: item, withQuote: false).media.isEmpty {
                    let asMedia = library.tweetModel(staged: item, withQuote: false).mediaOnly
                    actionLink(asMedia ? "Show as tweet" : "Show as media only", asMedia ? "text.bubble" : "photo.on.rectangle") {
                        library.toggleTweetDisplay(staged: save(item))
                    }
                }
                if item.payload.composite != nil {
                    actionLink("Edit layout…", "rectangle.split.2x1", id: "stagedEditLayout") { library.compositeEditor = .staged(save(item).id) }
                    actionLink("Split into \(library.staging?.parts(item).count ?? 2) pictures", "square.split.2x1", id: "stagedSplit") {
                        library.splitStaged(save(item))
                    }
                } else if Library.combinable(item) {
                    actionLink("Combine with other pictures…", "rectangle.split.2x1", id: "stagedCombineWith") {
                        save(item); library.startCombining(with: item)
                    }
                }
                if MediaEditor.canCrop(item.kind) || MediaEditor.canTrim(item.kind) {
                    actionLink(Self.editTitle(item.kind, edited: item.edit != nil), Self.editSymbol(item.kind), id: "stagedEdit") {
                        library.editTarget = .staged(save(item).id)
                    }
                }
                actionLink("Discard", "trash", danger: true, id: "stagedDiscard") { library.discardAndAdvance(item) }
            }
            .padding(.leading, Space.l)   // icons line up with the Commit icon inside the button above

            Text("⌘↩ commit · ⌘⌫ discard · ⌘← ⌘→ previous / next").zfont(11).foregroundStyle(Theme.muted)
        }
    }

    private func actionLink(_ title: String, _ symbol: String, danger: Bool = false, id: String = "",
                            _ action: @escaping () -> Void) -> some View {
        HStack(spacing: Space.s) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(danger ? Theme.danger : Theme.muted).frame(width: 16)
            LinkText(text: title, color: danger ? Theme.danger : Theme.link, size: 13, weight: .bold, action: action)
                .accessibilityIdentifier(id)
        }
    }

    /// Keyboard review: invisible buttons carrying the shortcuts.
    private func shortcuts(_ item: StagedItem) -> some View {
        ZStack {
            Button("") { library.commitAndAdvance(save(item)) }.keyboardShortcut(.return, modifiers: .command)
            Button("") { library.discardAndAdvance(item) }.keyboardShortcut(.delete, modifiers: .command)
            Button("") { go(item, -1) }.keyboardShortcut(.leftArrow, modifiers: .command)
            Button("") { go(item, 1) }.keyboardShortcut(.rightArrow, modifiers: .command)
        }
        .opacity(0).frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
    }

    private func details(_ item: StagedItem) -> some View {
        SectionBlock("Details") {
            Grid(alignment: .leading, horizontalSpacing: Space.m, verticalSpacing: Space.xs) {
                row("Staged", Date(timeIntervalSince1970: Double(item.addedAt) / 1000).formatted(date: .long, time: .shortened))
                row("From", item.source)
                if let n = item.originalName, item.kind != .tweet { row("File", n) }
                if item.kind != .tweet && item.kind != .text {
                    row("Format", item.formatLabel + (item.compatibility == .popular ? " (popular)" : " (uncommon)"))
                    if let e = item.edit { row("Edited", Self.describe(e, kind: item.kind)) }
                    if let l = item.payload.composite?.layout { row("Combined", "\(library.staging?.parts(item).count ?? 0) pictures, \(l.arrangement.label.lowercased())") }
                }
                if let w = item.info.width, let h = item.info.height, w > 0, h > 0 { row("Resolution", "\(w)×\(h)") }
                if let ms = item.info.durationMs, ms > 0 { row("Duration", Duration.milliseconds(ms).formatted(.time(pattern: .minuteSecond))) }
                if item.kind != .tweet { row("File size", ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)) }
                if case .tweet(let p) = item.payload {
                    row("Tweet", p.url)
                    if let w = p.waybackURL { row("Wayback", w) }
                }
            }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(k + ":").zfont(12).foregroundStyle(Theme.muted)
            Text(v).zfont(12).foregroundStyle(Theme.text).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
        }
    }
}

/// A staged tweet as it will be saved: the thread it replies to (staged with it) above, joined by a line.
struct StagedThreadView: View {
    @Environment(Library.self) private var library
    let item: StagedItem
    var maxMediaHeight: CGFloat = 460

    var body: some View {
        let chain = library.stagedChain(item)
        let ancestors = library.stagedAncestors(of: item, chain: chain)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(ancestors.reversed(), id: \.id) { a in
                TweetCardView(model: library.tweetModel(staged: a, chain: chain), maxMediaHeight: 320)
                Rectangle().fill(Theme.border).frame(width: 2, height: Space.l).padding(.leading, Space.l + 21)
            }
            TweetCardView(model: library.tweetModel(staged: item, chain: chain), maxMediaHeight: maxMediaHeight)
                .id(TweetThreadView.focalID)
        }
        .frame(maxWidth: 600, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}
