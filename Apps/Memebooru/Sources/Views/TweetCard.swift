import SwiftUI
import AVKit
import MemebooruCore

/// A saved tweet as a card. `compact` is the fixed-size tile (gallery, Previous / Next, Related);
/// the full card is the post page.
struct TweetCard: View {
    @Environment(Library.self) private var library
    let meme: Meme
    var compact = false
    /// Full card: the tallest its media may get, so the whole tweet fits in the window (as on x.com).
    var maxMediaHeight: CGFloat = 460

    var body: some View {
        TweetCardView(model: library.tweetModel(meme), compact: compact, maxMediaHeight: maxMediaHeight,
                      onLoadQuote: { library.loadQuoted(of: meme.id) })
    }
}

/// Draws a `TweetCardModel` — the same look for saved and staged tweets.
struct TweetCardView: View {
    @Environment(Library.self) private var library
    @Environment(\.zoom) private var zoom
    let model: TweetCardModel
    var compact = false
    var maxMediaHeight: CGFloat = 460
    /// Shown instead of a missing quote ("Load quoted tweet"); nil hides the button.
    var onLoadQuote: (() -> Void)? = nil

    var body: some View {
        if model.mediaOnly { bare } else if compact { tile } else { full }
    }

    // MARK: Media only

    /// Just the tweet's photos / videos, like a picture post: no frame, author or date.
    @ViewBuilder private var bare: some View {
        if compact {
            TweetMediaGrid(media: model.media, style: .tile, bare: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            TweetMediaGrid(media: model.media, style: .full(maxHeight: maxMediaHeight + 160), bare: true)
                .thumbShadow()
        }
    }

    // MARK: Tile

    /// Fills whatever frame it's given: header, a few lines of text, then the media (or the quote)
    /// taking the rest — cropped at the bottom, never squeezed.
    private var tile: some View {
        VStack(alignment: .leading, spacing: 6 * zoom) {
            TweetHeader(model: model, size: .tile)
            if let r = model.replyTo, !r.isEmpty {
                Text("Replying to @\(r)").zfont(10).foregroundStyle(Theme.link).lineLimit(1)
            }
            if !model.text.isEmpty {
                Text(model.text).zfont(12).foregroundStyle(Theme.text).lineSpacing(1)
                    .lineLimit(model.media.isEmpty && model.quoted.isEmpty ? 8 : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.media.isEmpty {
                TweetMediaGrid(media: model.media, style: .tile)
                    .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            } else if let q = model.quoted.first {
                QuoteBox(model: q, style: .tile).frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .padding(8 * zoom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.tweetBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Theme.border))
    }

    // MARK: Full

    private var full: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            TweetHeader(model: model, size: .full)
            if let r = model.replyTo, !r.isEmpty {
                Text("Replying to @\(r)").zfont(13).foregroundStyle(Theme.link)
            }
            if !model.text.isEmpty {
                Text(model.text).zfont(17).foregroundStyle(Theme.text).lineSpacing(2)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if !model.media.isEmpty {
                TweetMediaGrid(media: model.media, style: .full(maxHeight: maxMediaHeight))
            }
            if let q = model.quoted.first {
                QuoteBox(model: q, style: .full)
            } else if model.quoteMissing, let onLoadQuote {
                GlassButton(title: "Load quoted tweet", symbol: "quote.bubble", action: onLoadQuote)
            }
            if let d = model.postedAt {
                Text(Date(timeIntervalSince1970: Double(d) / 1000), format: .dateTime.hour().minute().day().month().year())
                    .zfont(13).foregroundStyle(Theme.muted)
            }
        }
        .padding(Space.l)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.tweetBackground))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Theme.border))
    }

    /// PNG of the card at 2x, for sharing (stills only — players don't render offscreen).
    @MainActor func renderPNG(width: CGFloat = 600) -> Data? {
        let renderer = ImageRenderer(content: self.environment(library).frame(width: width))
        renderer.scale = 2
        #if os(macOS)
        guard let cg = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        #else
        return renderer.uiImage?.pngData()
        #endif
    }
}

/// Avatar, name and @handle. Tiles put name and handle on one line to leave room for the media.
struct TweetHeader: View {
    @Environment(Library.self) private var library
    @Environment(\.zoom) private var zoom
    enum Size { case tile, quote, full }
    let model: TweetCardModel
    let size: Size

    var body: some View {
        let side: CGFloat = (size == .full ? 44 : size == .quote ? 20 : 24) * zoom
        HStack(spacing: size == .full ? Space.m : Space.s) {
            avatar.frame(width: side, height: side).clipShape(Circle())
            if size == .full {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.authorName).zfont(16, .bold).foregroundStyle(Theme.text).lineLimit(1)
                    Text("@\(model.handle)").zfont(14).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer(minLength: Space.s)
                if let s = model.url, let url = URL(string: s) {
                    Link(destination: url) {
                        Image(systemName: "arrow.up.right.square").font(.system(size: 15)).foregroundStyle(Theme.muted)
                    }.help("Open on x.com").linkPointer()
                }
            } else {
                // One line: the name gives way first, the handle keeps a few characters.
                HStack(spacing: Space.xs) {
                    Text(model.authorName).zfont(size == .quote ? 11 : 12, .bold).foregroundStyle(Theme.text)
                        .lineLimit(1).layoutPriority(1)
                    Text("@\(model.handle)").zfont(size == .quote ? 11 : 11).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder private var avatar: some View {
        if let url = model.avatar, let img = library.avatarImage(url) {
            Image(platform: img).resizable().scaledToFill()
        } else {
            Circle().fill(Theme.surface).overlay(Image(systemName: "person.fill").font(.system(size: 10)).foregroundStyle(Theme.muted))
        }
    }
}

/// The quoted tweet, framed inside the one that quotes it (as on x.com).
struct QuoteBox: View {
    enum Style { case tile, full }
    @Environment(\.zoom) private var zoom
    let model: TweetCardModel
    let style: Style

    var body: some View {
        VStack(alignment: .leading, spacing: style == .full ? Space.s : 4 * zoom) {
            TweetHeader(model: model, size: .quote)
            if !model.text.isEmpty {
                Text(model.text).zfont(style == .full ? 14 : 11).foregroundStyle(Theme.text)
                    .lineLimit(style == .full ? 14 : 3).fixedSize(horizontal: false, vertical: true)
            }
            if !model.media.isEmpty {
                if style == .full { TweetMediaGrid(media: model.media, style: .quote) }
                else { TweetMediaGrid(media: model.media, style: .tile).frame(maxHeight: .infinity) }
            }
        }
        .padding(style == .full ? Space.m : 6 * zoom)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
    }
}

// MARK: - Media

/// A tweet's photos and videos laid out like x.com: one at its own shape; two side by side; three as
/// one tall plus two stacked; four in a square grid.
struct TweetMediaGrid: View {
    enum Style: Equatable { case tile, quote, full(maxHeight: CGFloat) }
    @Environment(Library.self) private var library
    let media: [TweetCardModel.Media]
    let style: Style
    /// Shown as a picture post: square corners, no outline.
    var bare = false

    private var radius: CGFloat { bare ? 0 : style == .tile ? 6 : 14 }
    private var outline: Color { bare ? .clear : Theme.border.opacity(0.7) }
    private var gap: CGFloat { style == .tile ? 2 : 3 }

    var body: some View {
        if media.count == 1, case .full(let maxH) = style {
            single(media[0], maxHeight: maxH)
        } else if media.count == 1, style == .quote {
            single(media[0], maxHeight: 260)
        } else {
            // Tiles fill what the card leaves them; full cards get x.com's fixed grid height.
            Color.clear
                .frame(height: style == .tile ? nil : 280)
                .overlay { grid }
                .clipShape(RoundedRectangle(cornerRadius: radius))
                .overlay(RoundedRectangle(cornerRadius: radius).stroke(outline))
        }
    }

    /// One item at its own aspect, as large as the width allows but no taller than `maxHeight`.
    private func single(_ m: TweetCardModel.Media, maxHeight: CGFloat) -> some View {
        // Sizes come from x.com or the file's header, so the box has its final shape on the first frame.
        let posterAspect: CGFloat? = library.cachedPoster(m.url).map { $0.size.width / max(1, $0.size.height) }
        let aspect: CGFloat = m.aspect ?? posterAspect ?? 16.0 / 9.0
        return AspectFitBox(aspect: max(0.3, aspect), maxHeight: maxHeight) {
            TweetMediaTile(media: m, live: style != .tile, fill: true)
                .clipShape(RoundedRectangle(cornerRadius: radius))
                .overlay(RoundedRectangle(cornerRadius: radius).stroke(outline))
        }
    }

    @ViewBuilder private var grid: some View {
        let shown = Array(media.prefix(4))
        switch shown.count {
        case 1:
            TweetMediaTile(media: shown[0], live: false, fill: true)
        case 2:
            HStack(spacing: gap) { ForEach(shown) { tile($0) } }
        case 3:
            HStack(spacing: gap) {
                tile(shown[0])
                VStack(spacing: gap) { tile(shown[1]); tile(shown[2]) }
            }
        default:
            VStack(spacing: gap) {
                HStack(spacing: gap) { tile(shown[0]); tile(shown[1]) }
                HStack(spacing: gap) { tile(shown[2]); tile(shown[3]) }
            }
        }
    }

    private func tile(_ m: TweetCardModel.Media) -> some View {
        Color.clear.overlay { TweetMediaTile(media: m, live: style != .tile, fill: true) }.clipped()
    }
}

/// Full width, height = width ÷ aspect but at most `maxHeight`; the content is centred at its own
/// shape inside. Reports exactly the height it draws — so cards and rows around it get even padding.
struct AspectFitBox: Layout {
    let aspect: CGFloat
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        Self.size(width: proposal.width, aspect: aspect, maxHeight: maxHeight)
    }

    static func size(width: CGFloat?, aspect: CGFloat, maxHeight: CGFloat) -> CGSize {
        let width = width ?? maxHeight * aspect
        return CGSize(width: width, height: min(width / aspect, maxHeight).rounded())
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let w = min(bounds.width, bounds.height * aspect).rounded()
        for s in subviews {
            s.place(at: CGPoint(x: bounds.midX, y: bounds.minY), anchor: .top, proposal: ProposedViewSize(width: w, height: bounds.height))
        }
    }
}

/// One photo / video / GIF. `live`: GIFs loop and videos play (muted, with controls); otherwise a still
/// with a play or GIF badge.
struct TweetMediaTile: View {
    @Environment(Library.self) private var library
    let media: TweetCardModel.Media
    let live: Bool
    var fill = true

    var body: some View {
        // The colour sets the size; the picture only fills it (a scaled-to-fill image must not grow the tile).
        Theme.surfaceSunk.overlay { still }.clipped().overlay {
            if live {
                switch media.kind {
                case .gif:
                    if media.url.pathExtension.lowercased() == "gif" { AnimatedGif(url: media.url) } else { LoopingVideo(url: media.url) }
                case .video:
                    MediaPlayer(url: media.url, autoplay: true, startMuted: true)
                case .photo:
                    EmptyView()
                }
            }
        }
        .overlay(alignment: .bottomLeading) { if !live { badge } }
    }

    @ViewBuilder private var still: some View {
        // Live photos use the full picture; everything else the card-sized still.
        if media.kind == .photo, live, let img = library.displayImage(media.url) {
            Image(platform: img).resizable().scaledToFill()
        } else {
            let url = media.url
            LoadedImage(key: "poster:" + url.path, load: { await $0.loadPoster(url) }) { _ in Color.clear }
        }
    }

    @ViewBuilder private var badge: some View {
        switch media.kind {
        case .video:
            Image(systemName: "play.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                .padding(5).background(Theme.menu.opacity(0.75), in: Circle()).padding(Space.xs)
        case .gif:
            Text("GIF").font(.system(size: 8, weight: .heavy)).foregroundStyle(.white)
                .padding(.horizontal, 3).padding(.vertical, 1)
                .background(Theme.menu.opacity(0.8), in: RoundedRectangle(cornerRadius: 2)).padding(Space.xs)
        case .photo:
            EmptyView()
        }
    }
}

/// x.com "GIF": a silent MP4 that loops on its own, no controls.
struct LoopingVideo: View {
    let url: URL
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?

    var body: some View {
        ZStack { if let player { BarePlayerView(player: player, fill: true).allowsHitTesting(false) } }
            .onAppear {
                guard player == nil, FileManager.default.fileExists(atPath: url.path) else { player?.play(); return }
                let p = AVQueuePlayer()
                p.isMuted = true
                looper = AVPlayerLooper(player: p, templateItem: AVPlayerItem(url: url))
                player = p
                p.play()
            }
            .onDisappear { player?.pause() }
    }
}

/// Video/audio with our own custom transport controls (see MediaPlayer). Kept as `StablePlayer` for call sites.
struct StablePlayer: View {
    let url: URL
    var isAudio = false
    var body: some View { MediaPlayer(url: url, isAudio: isAudio) }
}

#if os(macOS)
typealias PlatformViewRepresentable = NSViewRepresentable
#else
typealias PlatformViewRepresentable = UIViewControllerRepresentable
#endif
