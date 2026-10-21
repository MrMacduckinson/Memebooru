import SwiftUI
import AVKit

// MARK: - Spinner (replaces the native ProgressView)

struct MBSpinner: View {
    var size: CGFloat = 14
    var color: Color = Theme.link
    @State private var spin = false
    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 0.85).repeatForever(autoreverses: false), value: spin)
            .onAppear { spin = true }
    }
}

// MARK: - Checkbox (replaces the native .checkbox)

/// Paper box with a sage border; teal check when on.
struct MBToggle: View {
    @Binding var isOn: Bool
    var label: String
    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: Space.s) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Theme.paper)
                    .frame(width: 14, height: 14)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(isOn ? Theme.link : Theme.buttonBorder))
                    .overlay(isOn ? Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(Theme.link) : nil)
                Text(label).zfont(12).foregroundStyle(Theme.text)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .linkPointer()
    }
}

// MARK: - Empty state (consistent across pages)

/// Centered in the free space below a page header: a quiet glyph, a Trebuchet line, one hint.
struct EmptyState: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(spacing: Space.s) {
            Image(systemName: icon).font(.system(size: 34, weight: .light)).foregroundStyle(Theme.faint)
                .padding(.bottom, Space.xs)
            Text(title).dfont(18).foregroundStyle(Theme.text).accessibilityIdentifier("emptyState")
            if let subtitle {
                Text(subtitle).zfont(12).foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center).frame(maxWidth: 380)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, Space.xxl * 2)
    }
}

// MARK: - Media player with fully custom controls (no native transport UI)

/// AVKit renders the frames (via `AVPlayerView` with its controls turned OFF, or a bare audio surface),
/// and we draw our own play button + scrubber + timecodes on top — so nothing looks like a macOS control.
struct MediaPlayer: View {
    let url: URL
    var isAudio = false
    /// Start playing on appear (tweet videos, as on x.com).
    var autoplay = false
    /// Start without sound; the speaker button turns it on.
    var startMuted = false

    @State private var player = AVPlayer()
    @State private var playing = false
    @State private var cur: Double = 0
    @State private var dur: Double = 0
    @State private var scrubbing = false
    @State private var observer: Any?
    @State private var muted = false

    var body: some View {
        Group {
            if isAudio {
                HStack(spacing: Space.m) {
                    Image(systemName: "waveform").font(.system(size: 18)).foregroundStyle(Theme.link).frame(width: 24)
                    transport
                }
                .padding(.horizontal, Space.m).padding(.vertical, Space.s + 2)
                .frame(maxWidth: 520, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Theme.border))
            } else {
                ZStack(alignment: .bottom) {
                    BarePlayerView(player: player)
                    transport
                        .padding(.horizontal, Space.m).padding(.vertical, Space.s)
                        .background(Theme.menu.opacity(0.85))
                }
            }
        }
        .onAppear {
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            // Back on screen (a list scrolled it away and back): carry on where it was, don't restart.
            if (player.currentItem?.asset as? AVURLAsset)?.url == url {
                if playing { player.play() }
                if observer == nil { observe() }
                return
            }
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            muted = startMuted
            player.isMuted = muted
            if autoplay { player.play(); playing = true }
            // Show the real length before the first play (the item reports it only once loaded).
            Task { if let d = try? await AVURLAsset(url: url).load(.duration), d.seconds.isFinite { dur = d.seconds } }
            observe()
        }
        .onDisappear {
            player.pause()
            if let o = observer { player.removeTimeObserver(o); observer = nil }
        }
    }

    private func observe() {
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { t in
            // Whole seconds only reach the labels; the scrubber moves in steps too small to redraw the page.
            if !scrubbing, abs(t.seconds - cur) >= 0.2 { cur = t.seconds }
            if let d = player.currentItem?.duration.seconds, d.isFinite, d != dur { dur = d }
            if let d = player.currentItem?.duration.seconds, d.isFinite, t.seconds >= d - 0.05, playing { playing = false }
        }
    }

    private var transport: some View {
        HStack(spacing: Space.m) {
            Button { toggle() } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 14)).foregroundStyle(ink).frame(width: 18)
            }.buttonStyle(.plain).linkPointer()
            Text(fmt(cur)).zfont(11).monospacedDigit().foregroundStyle(inkMuted).fixedSize()
            scrubber
            Text(fmt(dur)).zfont(11).monospacedDigit().foregroundStyle(inkMuted).fixedSize()
            if !isAudio {
                Button { muted.toggle(); player.isMuted = muted } label: {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.system(size: 12)).foregroundStyle(ink).frame(width: 18)
                }.buttonStyle(.plain).linkPointer().help(muted ? "Sound on" : "Sound off")
            }
        }
    }

    // Audio sits in a sage box (dark ink); video controls float on a dark strip (light ink).
    private var ink: Color { isAudio ? Theme.text : Theme.headerText }
    private var inkMuted: Color { isAudio ? Theme.muted : Theme.headerMuted }

    private var scrubber: some View {
        GeometryReader { g in
            let frac = dur > 0 ? min(1, max(0, cur / dur)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(isAudio ? Theme.rule : Color.white.opacity(0.2)).frame(height: 4)
                Capsule().fill(Theme.accent).frame(width: g.size.width * frac, height: 4)
                Circle().fill(isAudio ? Theme.paper : Theme.headerText).frame(width: 11, height: 11)
                    .overlay(Circle().stroke(Theme.buttonBorder, lineWidth: isAudio ? 1 : 0))
                    .offset(x: g.size.width * frac - 5.5)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                scrubbing = true
                let f = max(0, min(1, v.location.x / g.size.width))
                cur = f * dur
            }.onEnded { _ in
                player.seek(to: CMTime(seconds: cur, preferredTimescale: 600))
                scrubbing = false
            })
        }
        .frame(height: 16)
    }

    private func toggle() {
        if playing { player.pause() } else {
            if dur > 0, cur >= dur - 0.05 { player.seek(to: .zero); cur = 0 }
            player.play()
        }
        playing.toggle()
    }
    private func fmt(_ s: Double) -> String {
        let t = max(0, Int(s.rounded())); return String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// Video surface with no controls (we draw our own). A bare AVPlayerLayer on a clear background:
/// until the first frame is decoded it shows nothing, so the poster underneath stays visible instead of
/// a black flash; it never takes the mouse, so hover and clicks stay with the SwiftUI views.
struct BarePlayerView: View {
    let player: AVPlayer
    /// Crop to fill the frame (GIF tiles) instead of letterboxing.
    var fill = false
    var body: some View { PlayerLayerView(player: player, gravity: fill ? .resizeAspectFill : .resizeAspect) }
}

#if os(macOS)
private final class PlayerLayerNSView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func makeBackingLayer() -> CALayer {
        let l = AVPlayerLayer()
        l.backgroundColor = .clear
        return l
    }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    let gravity: AVLayerVideoGravity
    func makeNSView(context: Context) -> PlayerLayerNSView {
        let v = PlayerLayerNSView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = gravity
        return v
    }
    func updateNSView(_ v: PlayerLayerNSView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
        v.playerLayer.videoGravity = gravity
    }
}
#else
private final class PlayerLayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    let gravity: AVLayerVideoGravity
    func makeUIView(context: Context) -> PlayerLayerUIView {
        let v = PlayerLayerUIView()
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = false
        v.playerLayer.player = player
        v.playerLayer.videoGravity = gravity
        return v
    }
    func updateUIView(_ v: PlayerLayerUIView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
        v.playerLayer.videoGravity = gravity
    }
}
#endif
