import SwiftUI
import MemebooruCore

/// A thumbnail at an exact size: pictures at their own aspect with the site's soft shadow; text and
/// audio as "literature" cards (the site's grey-green lit thumb with a vertical label strip).
/// GIFs autoplay, video previews on hover, audio plays inline.
struct ThumbCell: View {
    @Environment(Library.self) private var library
    let meme: Meme
    let size: CGSize
    @State private var image: PlatformImage?

    private var fileURL: URL? { library.primaryAsset(of: meme.id).flatMap { library.fileURL($0) } }

    var body: some View {
        content
            .frame(width: size.width, height: size.height)
            .clipped()
            .overlay(alignment: .topTrailing) {
                if meme.kind == .gif {
                    Text("GIF").font(.system(size: 8, weight: .heavy)).foregroundStyle(.white)
                        .padding(.horizontal, 3).padding(.vertical, 1)
                        .background(Theme.menu.opacity(0.8), in: RoundedRectangle(cornerRadius: 2)).padding(Space.xs)
                }
            }
            .thumbShadow()
            .task(id: meme.id) {
                if meme.kind == .image || meme.kind == .video, image == nil { image = await library.loadThumbnail(meme) }
            }
    }

    @ViewBuilder private var content: some View {
        switch meme.kind {
        case .image:
            if let img = image ?? library.thumbnail(for: meme) { Image(platform: img).resizable().scaledToFill() } else { Theme.surfaceSunk }
        case .gif:
            if let url = fileURL { AnimatedGif(url: url) } else { Theme.surfaceSunk }
        case .video:
            if let a = library.primaryAsset(of: meme.id) {
                HoverVideo(url: library.playableURL(for: a), poster: image ?? library.thumbnail(for: meme))
                    .background(Theme.surfaceSunk)
                    .onHover { if $0 { library.requestPreview(a) } }   // uncommon video: make its preview on first hover
            } else { Theme.surfaceSunk }
        case .audio:
            LitCard(label: "АУДИО") {
                VStack(spacing: Space.s) {
                    Button { library.toggleAudioPreview(meme.id) } label: {
                        Image(systemName: library.audioPlayingID == meme.id ? "pause.fill" : "play.fill")
                            .font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.goText)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(LinearGradient(colors: [Theme.goTop, Theme.goBottom], startPoint: .top, endPoint: .bottom)))
                            .overlay(Circle().stroke(Theme.goBorder))
                    }
                    .buttonStyle(.plain).linkPointer()
                    Image(systemName: "waveform").font(.system(size: 22)).foregroundStyle(Theme.faint)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .text, .article:
            LitCard(label: meme.kind == .article ? "ARTICLE" : "TEXT") {
                Text((meme.textVerbatim ?? meme.textExact ?? "…").trimmingCharacters(in: .whitespacesAndNewlines))
                    .zfont(12).foregroundStyle(Color(hex: 0x222222))
                    .lineSpacing(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(Space.s)
            }
        case .tweet:
            TweetCard(meme: meme, compact: true)
        }
    }
}

/// deviantART's literature thumbnail: grey-green card, a narrow strip on the left with the
/// category written sideways, the text itself on the right.
struct LitCard<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 0) {
            Text(label).font(.custom("Georgia", fixedSize: 8)).kerning(1.2).foregroundStyle(Color(hex: 0x7E8B7F))
                .fixedSize().rotationEffect(.degrees(-90))
                .frame(width: 16).frame(maxHeight: .infinity)
                .background(Color(hex: 0xB9C3B5))
                .overlay(alignment: .trailing) { Color(hex: 0xA6B2A6).frame(width: 1) }
            content
        }
        .background(Color(hex: 0xCDD5C9))
    }
}

/// Non-image kinds as a card that fills its frame — used where a small preview of any meme is needed.
struct CardPreview: View {
    let meme: Meme
    var body: some View {
        switch meme.kind {
        case .tweet:
            TweetCard(meme: meme, compact: true)
        case .text, .article:
            LitCard(label: meme.kind == .article ? "ARTICLE" : "TEXT") {
                Text((meme.textVerbatim ?? meme.textExact ?? "…").trimmingCharacters(in: .whitespacesAndNewlines))
                    .zfont(11).foregroundStyle(Color(hex: 0x222222)).minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(Space.xs)
            }
        case .audio:
            LitCard(label: "АУДИО") {
                Image(systemName: "waveform").font(.system(size: 22)).foregroundStyle(Theme.faint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        default:
            ZStack { Theme.surfaceSunk; MBSpinner() }
        }
    }
}
