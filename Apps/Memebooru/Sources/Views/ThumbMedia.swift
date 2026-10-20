import SwiftUI
import AVKit
import MemebooruCore

// MARK: - Animated GIF (autoplays in thumbnails)

#if os(macOS)
import AppKit

/// NSImageView animates a multi-frame GIF for free. Fills the tile (thumbnails are sized to the gif's
/// aspect, so there is no letterbox).
struct AnimatedGif: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> NSImageView {
        let iv = NSImageView()
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.animates = true
        iv.canDrawSubviewsIntoLayer = true
        iv.image = NSImage(contentsOf: url)
        return iv
    }
    func updateNSView(_ iv: NSImageView, context: Context) {
        if iv.image == nil { iv.image = NSImage(contentsOf: url) }
        iv.animates = true
    }
}
#else
struct AnimatedGif: View {   // iOS: fall back to the static poster
    let url: URL
    var body: some View { Color.black }
}
#endif

// MARK: - Hover-to-play video preview (YouTube style)

/// Shows the static poster; on hover it plays the video (muted, looping) in place, like a YouTube
/// thumbnail preview. Only the hovered tile ever has a live player. The video is cropped exactly like the
/// poster under it (so nothing shifts when it starts) and loops gaplessly (no seek back to the start).
struct HoverVideo: View {
    /// nil until an uncommon video's playable preview exists: the poster alone is shown.
    let url: URL?
    let poster: PlatformImage?

    @State private var hovering = false
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?

    var body: some View {
        ZStack {
            // No poster: whatever is underneath shows (a still that's still loading, or the tile's colour).
            if let poster { Image(platform: poster).resizable().scaledToFill() }
            if let player {
                BarePlayerView(player: player, fill: true).allowsHitTesting(false).opacity(hovering ? 1 : 0)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if !hovering {
                Image(systemName: "play.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    .padding(5).background(Theme.menu.opacity(0.75), in: Circle()).padding(Space.s)
            }
        }
        .onHover { h in
            hovering = h
            if h { start() } else { player?.pause() }
        }
        .onDisappear { teardown() }
    }

    private func start() {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        if player == nil {
            let p = AVQueuePlayer()
            p.isMuted = true
            looper = AVPlayerLooper(player: p, templateItem: AVPlayerItem(url: url))
            player = p
        }
        player?.play()
    }
    private func teardown() {
        player?.pause()
        looper?.disableLooping()
        looper = nil
        player = nil
    }
}
