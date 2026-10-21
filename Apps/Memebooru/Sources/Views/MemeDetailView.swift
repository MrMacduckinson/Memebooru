import SwiftUI
import AVKit
import MemebooruCore

/// Post page: media on top, tags and fields underneath — like a booru post.
struct MemeDetailView: View {
    @Environment(Library.self) private var library
    @Environment(\.zoom) private var zoom
    let id: MemeID
    @State private var meme: Meme?
    @State private var tags: [Tag] = []
    @State private var generalLine = ""
    @State private var metaLine = ""
    @State private var textExact = ""
    @State private var textVerbatim = ""
    @State private var context = ""
    @State private var editingTags = false
    @State private var showFields = false
    @State private var showOriginal = false
    @State private var keepOriginalOnConvert = true
    @State private var exporting = false

    var body: some View {
        // Render straight from the model on the first frame (a cheap indexed read); `.task` then seeds
        // the editable @State. No spinner flash while a synchronous load runs after the first frame.
        Group {
        if let meme = meme ?? library.meme(id) {
            GeometryReader { geo in
              ScrollViewReader { proxy in
                ScrollView {
                    // deviantART's deviation page: artwork + title + description on the left,
                    // actions / "More from" / Details in a 300pt column on the right.
                    // Narrow windows stack the column under the main one.
                    let wide = geo.size.width >= 900
                    let side = sideWidth
                    let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: Space.xxl))
                                      : AnyLayout(VStackLayout(alignment: .leading, spacing: Space.xl))
                    // Breadcrumb spans the page; below it both columns start on one line (art top = Share top).
                    VStack(alignment: .leading, spacing: Space.l) {
                        breadcrumb(meme)
                        layout {
                            mainColumn(meme, geo)
                            sideColumn(meme)
                                .frame(width: wide ? side : nil)
                                .frame(maxWidth: wide ? nil : .infinity, alignment: .leading)
                        }
                    }
                    .pageInsets()
                }
                // A reply opens on the tweet itself; the thread above is a scroll up (as on x.com).
                .task(id: id) {
                    guard meme.kind == .tweet, !library.replyAncestors(of: id).isEmpty else { return }
                    try? await Task.sleep(for: .milliseconds(30))
                    proxy.scrollTo(TweetThreadView.focalID, anchor: .top)
                }
              }
            }
            .pageBackground()
        } else {
            Color.clear
        }
        }
        .task(id: id) {
            load()
            if UserDefaults.standard.bool(forKey: "openExport") { exporting = true }   // debug: -openExport YES
        }
    }

    private func load() {
        meme = library.meme(id)
        tags = library.tags(of: id)
        generalLine = tags.filter { $0.kind == .normal }.map(\.name).joined(separator: " ")
        metaLine = tags.filter { $0.kind == .meta }.map(\.name).joined(separator: " ")
        textExact = meme?.textExact ?? ""; textVerbatim = meme?.textVerbatim ?? ""; context = meme?.context ?? ""
    }

    private func saveFields() {
        guard var m = meme else { return }
        m.textExact = textExact.isEmpty ? nil : textExact
        m.textVerbatim = textVerbatim.isEmpty ? nil : textVerbatim
        m.context = context.isEmpty ? nil : context
        library.update(m); meme = library.meme(id)
    }

    private func saveTags() {
        library.setTags(id, normal: generalLine, meta: metaLine)
        editingTags = false; load()
    }

    // MARK: Main column

    private var sideWidth: CGFloat { Theme.detailSidebarWidth * min(zoom, 1.2) }

    private func breadcrumb(_ meme: Meme) -> some View {
        HStack(spacing: Space.xs) {
            LinkText(text: "‹ Posts", size: 12) { library.popDetail() }.accessibilityIdentifier("postBack")
            Text("/").zfont(12).foregroundStyle(Theme.faint)
            LinkText(text: meme.kind.categoryName, size: 12) { library.search(tag: meme.kind.kindTag) }
        }
    }

    private func mainColumn(_ meme: Meme, _ geo: GeometryProxy) -> some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            VStack(alignment: .leading, spacing: Space.m) {
                mediaStage(meme, geo)
                formatBanner(meme)
            }
            titleBlock(meme)
            VStack(alignment: .leading, spacing: Space.m) { fields }
            tagsBlock
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $exporting) { ExportSheet(meme: meme) }
    }

    /// The artwork, sized to its medium: pictures centered on the page with the site's shadow; audio a
    /// compact player; text a sheet of paper you can edit in place.
    @ViewBuilder private func mediaStage(_ meme: Meme, _ geo: GeometryProxy) -> some View {
        switch meme.kind {
        case .tweet:
            // Header, text and date need ~260pt; the media gets the rest of the window.
            TweetThreadView(meme: meme, maxMediaHeight: max(260, geo.size.height - 300))
        case .image, .gif, .video:
            let aspect = max(0.2, library.aspect(for: meme))
            MediaViewer(meme: meme, showing: shownOriginal(meme))
                .aspectRatio(aspect, contentMode: .fit)
                .frame(maxHeight: min(geo.size.height * 0.68, 760))
                .thumbShadow()
                .frame(maxWidth: .infinity)
        case .audio:
            MediaViewer(meme: meme, showing: shownOriginal(meme)).id(showOriginal)
        case .text, .article:
            TextField("", text: $textVerbatim, axis: .vertical)
                .lineLimit(1...)
                .textFieldStyle(.plain)
                .zfont(17)
                .lineSpacing(4)
                .foregroundStyle(Color(hex: 0x222222))
                .onSubmit(saveFields)
                .frame(maxWidth: Theme.fieldMaxWidth, alignment: .leading)
                .padding(.horizontal, Space.xl).padding(.vertical, Space.xl)
                .background(Theme.paper)
                .overlay(Rectangle().stroke(Theme.border))
                .thumbShadow()
                .frame(maxWidth: .infinity)
        }
    }

    private func shownOriginal(_ meme: Meme) -> Asset? { showOriginal ? library.formats(of: meme.id).original : nil }

    /// Where the shown file came from, or a warning when it's only in an uncommon format.
    @ViewBuilder private func formatBanner(_ meme: Meme) -> some View {
        let (primary, original) = library.formats(of: meme.id)
        if let p = primary, let source = p.sourceLabel {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 11)).foregroundStyle(Theme.link)
                if showOriginal, let o = original {
                    Text("Showing the original \(o.formatLabel), an uncommon format.").zfont(12).foregroundStyle(Theme.text)
                    Spacer(minLength: Space.s)
                    LinkText(text: "Back to \(p.formatLabel)", size: 12, weight: .bold) { showOriginal = false }
                } else {
                    Text(original != nil ? "Converted from \(source). The original is kept too."
                                         : "Converted from \(source) (the original wasn't kept).").zfont(12).foregroundStyle(Theme.text)
                    Spacer(minLength: Space.s)
                    if original != nil { LinkText(text: "View original", size: 12, weight: .bold) { showOriginal = true } }
                }
            }
            .padding(Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color(hex: 0xE4EEF1)))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(hex: 0xB9CDD4)))
        } else if let p = primary, p.compatibility(kind: meme.kind) == .uncommon,
                  let target = FormatPolicy.popularTarget(kind: meme.kind, ext: p.ext, codecs: p.codecs) {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(alignment: .firstTextBaseline, spacing: Space.iconLabel) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(Theme.warnInk)
                    Text("Stored only in an uncommon format: \(p.formatLabel)").zfont(12, .bold).foregroundStyle(Theme.warnInk)
                }
                Text("Telegram, phones and browsers may not open it. Convert it to \(target.label) to be safe.").zfont(12).foregroundStyle(Theme.text)
                if library.canConvert {
                    HStack(spacing: Space.l) {
                        GlassButton(title: "Convert to \(target.label)", symbol: "arrow.triangle.2.circlepath", prominent: true) {
                            library.convertMeme(meme.id, keepOriginal: keepOriginalOnConvert) { load() }
                        }
                        MBToggle(isOn: $keepOriginalOnConvert, label: "Keep the original \(p.formatLabel)")
                    }
                    .padding(.top, Space.xs)
                }
            }
            .padding(Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.warnBackground))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.warnBorder))
        }
    }

    /// Kind tile + Trebuchet title + "in Category" line + date — the deviation title block.
    private func titleBlock(_ meme: Meme) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .top, spacing: Space.m) {
                RoundedRectangle(cornerRadius: 3).fill(Theme.surface)
                    .frame(width: 44, height: 44)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.border))
                    .overlay(Image(systemName: meme.kind.symbol).font(.system(size: 18)).foregroundStyle(Theme.muted))
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(title(meme)).dfont(24).foregroundStyle(Theme.text).lineLimit(2)
                        .accessibilityIdentifier("postTitle")
                        .shadow(color: .white.opacity(0.7), radius: 0, x: 0, y: 1)
                    HStack(spacing: Space.xs) {
                        Text("in").foregroundStyle(Theme.text)
                        LinkText(text: meme.kind.categoryName, size: 12) { library.search(tag: meme.kind.kindTag) }
                        Text("· added " + Date(timeIntervalSince1970: Double(meme.createdAt) / 1000).formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(Theme.muted)
                    }
                    .zfont(12)
                }
            }
            Rule()
        }
    }

    private func title(_ meme: Meme) -> String {
        switch meme.kind {
        case .tweet: if case .tweet(let p) = meme.payload { return "\(p.authorName) @\(p.handle)" }
        default: break   // a text post's words are the artwork above; the title names it instead
        }
        let general = tags.filter { $0.kind == .normal }.prefix(4).map(\.name)
        if !general.isEmpty { return general.joined(separator: " ") }
        if let n = library.primaryAsset(of: meme.id)?.originalName { return (n as NSString).deletingPathExtension }
        return meme.kind.categoryName
    }

    /// Verbatim doesn't count for text memes — it is the page itself, so alone it shouldn't unfold empty boxes.
    private var hasAnyText: Bool { !textExact.isEmpty || (!isTextKind && !textVerbatim.isEmpty) || !context.isEmpty }
    private var isTextKind: Bool {
        let k = (meme ?? library.meme(id))?.kind
        return k == .text || k == .article
    }

    @ViewBuilder private var fields: some View {
        // No empty boxes for media without text — one quiet affordance instead.
        if hasAnyText || showFields {
            Field(title: "Text", text: $textExact, lines: 2, onCommit: saveFields)
            if !isTextKind {
                Field(title: "Verbatim — as written in the meme, typos included", text: $textVerbatim, lines: 2, onCommit: saveFields)
            }
            Field(title: "Context", text: $context, lines: 3, onCommit: saveFields)
            HStack { Spacer(); GlassButton(title: "Save", prominent: true) { saveFields() } }
                .frame(maxWidth: Theme.fieldMaxWidth)
        } else {
            LinkText(text: isTextKind ? "+ Add context" : "+ Add text or context", size: 12) { showFields = true }
        }
    }

    private var tagsBlock: some View {
        SectionBlock(title: "Tags") {
            if editingTags {
                HStack(spacing: Space.s) {
                    GlassButton(title: "Cancel") { editingTags = false; load() }
                    GlassButton(title: "Save tags", prominent: true) { saveTags() }
                }
            } else {
                LinkText(text: "Edit", size: 12) { editingTags = true }
            }
        } content: {
            tagRow("General", tags.filter { $0.kind == .normal }, $generalLine, "stalin child glasses", Theme.general)
            tagRow("Meta", tags.filter { $0.kind == .meta }, $metaLine, "2022 picture source_unknown", Theme.meta)
            if !editingTags && tags.isEmpty {
                Text("No tags yet.").zfont(12).foregroundStyle(Theme.muted)
            }
        }
    }

    @ViewBuilder private func tagRow(_ title: String, _ list: [Tag], _ line: Binding<String>, _ placeholder: String, _ tint: Color) -> some View {
        // In read mode an empty row is just noise.
        if editingTags || !list.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                Text(title).zfont(12).foregroundStyle(Theme.muted).frame(width: 64 * zoom, alignment: .leading)
                if editingTags {
                    SteadyTextField(text: line, placeholder: placeholder, size: 13, color: tint, onSubmit: saveTags)
                        .fieldChrome()
                        .frame(maxWidth: Theme.fieldMaxWidth)
                } else {
                    TagLine(tags: list, size: 13, onRemove: { library.removeTag(id, $0.name); tags = library.tags(of: id) })
                }
            }
        }
    }

    // MARK: Side column

    private func sideColumn(_ meme: Meme) -> some View {
        // Previous / Next first: same spot on every post, so they can be clicked through quickly.
        VStack(alignment: .leading, spacing: Space.xl) {
            moreFrom(meme)
            actions(meme)
            related(meme)
            details(meme)
        }
    }

    /// The big "Add to Favourites"-style button (Share) and a list of icon links under it.
    @ViewBuilder private func actions(_ meme: Meme) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            if let url = meme.kind == .tweet ? library.tweetShareURL(meme) : library.primaryAsset(of: meme.id).flatMap({ library.fileURL($0) }) {
                ShareLink(item: url) {
                    HStack(spacing: Space.s) {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 16, weight: .medium))
                        Text("Share").dfont(18, .regular)
                    }
                    .foregroundStyle(Theme.link)
                    .padding(.horizontal, Space.l).frame(height: 40)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 4).fill(LinearGradient(colors: [Color(hex: 0xE3EDDB), Color(hex: 0xCCDBC2)], startPoint: .top, endPoint: .bottom)))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.buttonBorder))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).linkPointer()
            }
            VStack(alignment: .leading, spacing: Space.s) {
                actionLink("Edit tags", "tag") { editingTags = true }
                if !hasAnyText && !showFields { actionLink(isTextKind ? "Add context" : "Add text or context", "text.alignleft") { showFields = true } }
                if meme.kind == .tweet {
                    if hasTweetMedia(meme) {
                        let asMedia = library.tweetModel(meme, withQuote: false).mediaOnly
                        actionLink(asMedia ? "Show as tweet" : "Show as media only", asMedia ? "text.bubble" : "photo.on.rectangle") {
                            library.toggleTweetDisplay(meme.id); load()
                        }
                        actionLink("Add media as meme", "square.and.arrow.down.on.square") { _ = library.extractTweetMedia(meme.id) }
                    }
                    actionLink("Export as PNG", "photo") { exportTweetPNG(meme) }
                }
                if meme.payload.composite != nil { actionLink("Edit layout…", "rectangle.split.2x1") { library.compositeEditor = .meme(meme.id) } }
                if MediaEditor.canCrop(meme.kind) || MediaEditor.canTrim(meme.kind), meme.payload.composite == nil {
                    actionLink(StagedDetailView.editTitle(meme.kind, edited: library.primaryAsset(of: meme.id)?.edit != nil),
                               StagedDetailView.editSymbol(meme.kind)) { library.editTarget = .meme(meme.id) }
                }
                if library.formats(of: meme.id).primary != nil { actionLink("Export…", "square.and.arrow.down") { exporting = true } }
                actionLink("Delete", "trash", danger: true) { library.delete(meme.id); library.popDetailImmediate() }
            }
            .padding(.leading, Space.l)   // icons line up with the Share icon inside the button above
        }
    }

    private func actionLink(_ title: String, _ symbol: String, danger: Bool = false, _ action: @escaping () -> Void) -> some View {
        HStack(spacing: Space.s) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(danger ? Theme.danger : Theme.muted).frame(width: 16)
            LinkText(text: title, color: danger ? Theme.danger : Theme.link, size: 13, weight: .bold, action: action)
        }
    }

    /// "More from Posts": the previous / next post as real thumbnails you can read.
    @ViewBuilder private func moreFrom(_ meme: Meme) -> some View {
        let prev = library.neighbor(of: meme.id, -1).flatMap { library.meme($0) }
        let next = library.neighbor(of: meme.id, 1).flatMap { library.meme($0) }
        if prev != nil || next != nil {
            SectionBlock(library.query.isEmpty ? "More from Posts" : "More from this search") {
                HStack(alignment: .top, spacing: Space.l) {
                    neighbor(prev, next: false)
                    neighbor(next, next: true)
                }
            }
        }
    }

    @ViewBuilder private func neighbor(_ m: Meme?, next: Bool) -> some View {
        // Two boxes exactly fill the column: (column − 16 gap) / 2 wide, 4:3.
        let w = ((sideWidth - Space.l) / 2).rounded(.down)
        let box = CGSize(width: w, height: (w * 0.75).rounded())
        VStack(spacing: Space.s) {
            if let m {
                Button { library.openDetailReplacing(m.id) } label: {
                    ThumbCell(meme: m, size: neighborSize(m, box)).frame(width: box.width, height: box.height)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).linkPointer()
                LinkText(text: next ? "Next ›" : "‹ Previous", size: 12, weight: .bold) { library.openDetailReplacing(m.id) }
            } else {
                Color.clear.frame(width: box.width, height: box.height)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func neighborSize(_ m: Meme, _ box: CGSize) -> CGSize {
        if let a = library.mediaOnlyAspect(m) {
            return a > box.width / box.height ? CGSize(width: box.width, height: (box.width / a).rounded())
                                              : CGSize(width: (box.height * a).rounded(), height: box.height)
        }
        switch m.kind {
        case .text, .article, .audio, .tweet: return box
        default:
            let a = max(0.2, library.aspect(for: m))
            return a > box.width / box.height ? CGSize(width: box.width, height: (box.width / a).rounded())
                                              : CGSize(width: (box.height * a).rounded(), height: box.height)
        }
    }

    /// "Featured in:" — related posts with their relation.
    @ViewBuilder private func related(_ meme: Meme) -> some View {
        let rels = library.relations(of: meme.id)
        if !rels.isEmpty {
            SectionBlock("Related") {
                ForEach(rels, id: \.to.rawValue) { r in
                    let other = r.from == meme.id ? r.to : r.from
                    if let m = library.meme(other) {
                        Button { library.openDetail(other) } label: {
                            HStack(spacing: Space.m) {
                                ThumbMini(meme: m).thumbShadow()
                                VStack(alignment: .leading, spacing: Space.xs / 2) {
                                    Text(r.from == meme.id ? r.kind.rawValue.capitalized : "\(r.kind.rawValue.capitalized) of this").dfont(15).foregroundStyle(Theme.link)
                                    Text(m.kind.categoryName).zfont(11).foregroundStyle(Theme.muted)
                                }
                            }
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain).linkPointer()
                    }
                }
            }
        }
    }

    @ViewBuilder private func details(_ meme: Meme) -> some View {
        SectionBlock("Details") {
            Grid(alignment: .leading, horizontalSpacing: Space.m, verticalSpacing: Space.xs) {
                row("Added", Date(timeIntervalSince1970: Double(meme.createdAt) / 1000).formatted(date: .long, time: .shortened))
                if let a = library.primaryAsset(of: meme.id) {
                    if let n = a.originalName { row("File", n) }
                    row("Format", a.formatLabel + (a.compatibility(kind: meme.kind) == .popular ? " (popular)" : " (uncommon)"))
                    if let e = a.edit { row("Edited", StagedDetailView.describe(e, kind: meme.kind)) }
                    if let l = meme.payload.composite?.layout {
                        row("Combined", "\(library.assets(of: meme.id).filter { $0.role == .part }.count) pictures, \(l.arrangement.label.lowercased())")
                    }
                    if let o = library.formats(of: meme.id).original {
                        row("Original", "\(o.formatLabel) · \(ByteCountFormatter.string(fromByteCount: o.bytes, countStyle: .file))")
                    }
                    if let w = a.width, let h = a.height, w > 0, h > 0 { row("Resolution", "\(w)×\(h)") }
                    if let ms = a.durationMs, ms > 0 { row("Duration", Duration.milliseconds(ms).formatted(.time(pattern: .minuteSecond))) }
                    row("File size", ByteCountFormatter.string(fromByteCount: a.bytes, countStyle: .file) + " · " + a.ext)
                    row("SHA-256", String(a.sha256.prefix(12)) + "…")
                }
                if case .tweet(let p) = meme.payload {
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

    private func hasTweetMedia(_ meme: Meme) -> Bool {
        library.assets(of: meme.id).contains { $0.role == .media && MediaType.detect(ext: $0.ext) != nil }
    }

    /// The same picture the Telegram bot sends (drawn by the core, stored as the tweet's render).
    private func exportTweetPNG(_ meme: Meme) {
        #if os(macOS)
        guard let asset = library.tweetRender(meme), let src = library.fileURL(asset) else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "tweet.\(asset.ext)"
        if panel.runModal() == .OK, let url = panel.url { try? FileManager.default.removeItem(at: url); try? FileManager.default.copyItem(at: src, to: url) }
        #endif
    }
}

struct ThumbMini: View {
    @Environment(Library.self) private var library
    @Environment(\.zoom) private var zoom
    let meme: Meme
    var body: some View {
        Group {
            if meme.kind == .tweet {
                // A tweet this small: its first picture, else its author.
                let m = library.tweetModel(meme, withQuote: false)
                if let url = m.media.first?.url ?? m.avatar {
                    LoadedImage(key: "poster:" + url.path, load: { await $0.loadPoster(url) }) { _ in Theme.surfaceSunk }
                } else { Theme.surfaceSunk.overlay(Image(systemName: "text.bubble").foregroundStyle(Theme.muted)) }
            } else if let img = library.thumbnail(for: meme) { Image(platform: img).resizable().scaledToFill() }
            else { CardPreview(meme: meme) }
        }.frame(width: 56 * zoom, height: 56 * zoom).clipped()
    }
}

/// Kind-specific viewer.
struct MediaViewer: View {
    @Environment(Library.self) private var library
    let meme: Meme
    /// Show this file instead of the primary one (the kept original).
    var showing: Asset? = nil

    var body: some View {
        let asset = showing ?? library.primaryAsset(of: meme.id)
        let url = asset.flatMap { library.fileURL($0) }
        switch meme.kind {
        case .gif:
            if let url { AnimatedGif(url: url) }   // plays in place, like the gallery tile
            else { Text("Cannot load image").foregroundStyle(Theme.muted).frame(height: 200) }
        case .image:
            if let url, let img = library.displayImage(url) {
                Image(platform: img).resizable().scaledToFit()
            } else { Text("Cannot load image").foregroundStyle(Theme.muted).frame(height: 200) }
        case .video:
            if let asset, let playable = library.playableURL(for: asset) {
                // The still underneath shows until the player has its first frame (no black flash).
                ZStack {
                    if let poster = library.thumbnail(for: meme) { Image(platform: poster).resizable().scaledToFit() }
                    StablePlayer(url: playable).id(playable)
                }
            } else if let asset {
                PreparingPreview(meme: meme, asset: asset)
            } else { Text("Missing video file").foregroundStyle(Theme.muted) }
        case .audio:
            if let url { StablePlayer(url: url, isAudio: true) }
            else { Text("Missing audio file").foregroundStyle(Theme.muted) }
        case .text, .article:
            // Card hugs the text (up to a readable width), left-aligned — not a full-width void.
            Text((meme.textVerbatim ?? meme.textExact ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
                .zfont(15).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Theme.fieldMaxWidth, alignment: .leading)
                .padding(Space.l)
                .background(Theme.paper)
                .overlay(Rectangle().stroke(Theme.border))
        case .tweet:
            TweetCard(meme: meme).frame(maxWidth: 600)
        }
    }
}


/// Reply chain (ancestors, oldest first) above the tweet, with buttons to fetch more.
struct TweetThreadView: View {
    static let focalID = "tweet-focal"
    @Environment(Library.self) private var library
    let meme: Meme
    var maxMediaHeight: CGFloat = 460

    var body: some View {
        let _ = library.threadVersion
        let ancestors = library.replyAncestors(of: meme.id)       // nearest first
        let pending = library.threadPending(of: meme.id)
        VStack(alignment: .leading, spacing: 0) {
            if pending.parent {
                HStack(spacing: Space.s) {
                    GlassButton(title: "Load the whole thread", symbol: "arrow.up.to.line") { library.loadReplyChain(of: meme.id) }
                    GlassButton(title: "Previous tweet only", symbol: "arrow.up") { library.loadReplyParent(of: meme.id) }
                }
                .padding(.bottom, Space.m)
            }
            // The thread above, oldest first, each tweet joined to the next by a line from its avatar.
            ForEach(ancestors.reversed(), id: \.id) { a in
                Button { library.openDetail(a.id) } label: {
                    TweetCard(meme: a, maxMediaHeight: 320)
                }.buttonStyle(.plain).linkPointer()
                Rectangle().fill(Theme.border).frame(width: 2, height: Space.l).padding(.leading, Space.l + 21)
            }
            TweetCard(meme: meme, maxMediaHeight: maxMediaHeight).id(Self.focalID)
        }
        .frame(maxWidth: 600, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

/// Stand-in while an uncommon video is turned into a playable preview: the poster frame and a note.
struct PreparingPreview: View {
    @Environment(Library.self) private var library
    let meme: Meme
    let asset: Asset
    var body: some View {
        ZStack {
            Theme.surfaceSunk
            if let img = library.thumbnail(for: meme) { Image(platform: img).resizable().scaledToFit().opacity(0.55) }
            VStack(spacing: Space.s) {
                if library.canConvert {
                    MBSpinner(size: 22)
                    Text("Preparing a playable preview of \(asset.formatLabel)…").zfont(12, .bold).foregroundStyle(Theme.text)
                } else {
                    Image(systemName: "film").font(.system(size: 22)).foregroundStyle(Theme.faint)
                    Text("This Mac can't play \(asset.formatLabel) without the media tools.").zfont(12).foregroundStyle(Theme.text)
                }
            }
            .padding(Space.m)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.paper.opacity(0.9)))
        }
        .task(id: asset.sha256) { library.requestPreview(asset) }
    }
}
