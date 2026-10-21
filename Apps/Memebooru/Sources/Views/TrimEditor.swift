import SwiftUI
import AVFoundation
import MemebooruCore

/// The stretch of a video or sound to keep: a bar (with the waveform for sounds) and two handles,
/// zoomable so the ends can be put to the millisecond; the times can be typed too.
struct TrimBar: View {
    let durationMs: Int64
    @Binding var range: TimeRange
    let peaks: [Float]?
    /// Where the playhead is (or nil); also told when a handle moves, to show that moment.
    var playhead: Int64? = nil
    var onScrub: (Int64) -> Void = { _ in }

    @State private var zoom: CGFloat = 1
    @State private var grabbed: Bool?        // true = start handle, false = end handle

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            GeometryReader { outer in
                let width = max(outer.size.width, outer.size.width * zoom)
                ScrollView(.horizontal, showsIndicators: zoom > 1) {
                    bar(width: width, height: outer.size.height)
                }
            }
            .frame(height: peaks == nil ? 44 : 96)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color(hex: 0x2B302C)))
            .clipShape(RoundedRectangle(cornerRadius: 4))

            HStack(spacing: Space.m) {
                TimeField(title: "Start", ms: Binding(get: { range.startMs }, set: { range.startMs = min(max(0, $0), range.endMs - 1) }))
                TimeField(title: "End", ms: Binding(get: { range.endMs }, set: { range.endMs = max(min(durationMs, $0), range.startMs + 1) }))
                Text("Keeps \(TimeField.format(range.durationMs)) of \(TimeField.format(durationMs))").zfont(11).foregroundStyle(Theme.muted)
                Spacer()
                GlassIconButton(symbol: "minus.magnifyingglass") { zoom = max(1, zoom / 2) }.help("Zoom out")
                GlassIconButton(symbol: "plus.magnifyingglass") { zoom = min(256, zoom * 2) }.help("Zoom in, to place the ends to the millisecond")
                Text(zoom <= 1 ? "Whole" : "\(Int(zoom))×").zfont(11).foregroundStyle(Theme.muted).monospacedDigit().frame(width: 40, alignment: .leading)
            }
        }
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        let k = width / CGFloat(max(1, durationMs))
        let x0 = CGFloat(range.startMs) * k, x1 = CGFloat(range.endMs) * k
        return ZStack(alignment: .topLeading) {
            Canvas { ctx, size in
                if let peaks, !peaks.isEmpty {
                    // Each bar as tall as the loudest moment in its stretch, against the loudest of all
                    // (so a quiet recording still shows its shape); more bars as it's zoomed in.
                    let step = max(1, Int(CGFloat(peaks.count) / size.width))
                    let top = max(peaks.max() ?? 1, 0.0001)
                    var p = Path()
                    for i in stride(from: 0, to: peaks.count, by: step) {
                        let x = CGFloat(i) / CGFloat(peaks.count) * size.width
                        let loudest = peaks[i..<min(peaks.count, i + step)].max() ?? 0
                        let h = max(1, CGFloat(loudest / top) * (size.height - 8))
                        p.addRect(CGRect(x: x, y: (size.height - h) / 2, width: max(1, size.width / CGFloat(peaks.count) * CGFloat(step) - 0.5), height: h))
                    }
                    ctx.fill(p, with: .color(Color(hex: 0xA8C99A)))
                } else {
                    ctx.fill(Path(CGRect(x: 0, y: size.height / 2 - 2, width: size.width, height: 4)), with: .color(Color(hex: 0xA8C99A)))
                }
                // Cut parts dimmed.
                ctx.fill(Path(CGRect(x: 0, y: 0, width: x0, height: size.height)), with: .color(.black.opacity(0.6)))
                ctx.fill(Path(CGRect(x: x1, y: 0, width: size.width - x1, height: size.height)), with: .color(.black.opacity(0.6)))
                ctx.stroke(Path(CGRect(x: x0, y: 0.5, width: x1 - x0, height: size.height - 1)), with: .color(.white), lineWidth: 1.5)
                for x in [x0, x1] { ctx.fill(Path(CGRect(x: x - 3, y: 0, width: 6, height: size.height)), with: .color(.white)) }
                if let playhead { let x = CGFloat(playhead) * k; ctx.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: size.height)), with: .color(Theme.accent)) }
            }
            .frame(width: width, height: height)
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { v in
                if grabbed == nil { grabbed = abs(v.startLocation.x - x0) <= abs(v.startLocation.x - x1) }
                let ms = Int64(max(0, min(width, v.location.x)) / k)
                if grabbed == true { range.startMs = min(ms, range.endMs - 1) } else { range.endMs = max(ms, range.startMs + 1) }
                onScrub(grabbed == true ? range.startMs : range.endMs)
            }
            .onEnded { _ in grabbed = nil })
    }
}

/// "1:02.345" — minutes, seconds and milliseconds; typed the same way.
struct TimeField: View {
    let title: String
    @Binding var ms: Int64
    @State private var text = ""
    @State private var dirty = false
    @FocusState private var focused: Bool

    static func format(_ ms: Int64) -> String {
        let t = max(0, ms)
        return String(format: "%d:%02d.%03d", t / 60_000, (t / 1000) % 60, t % 1000)
    }
    static func parse(_ s: String) -> Int64? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard (1...2).contains(parts.count), let sec = Double(parts.last!.replacingOccurrences(of: ",", with: ".")) else { return nil }
        let min = parts.count == 2 ? Double(parts[0]) ?? -1 : 0
        guard min >= 0, sec >= 0 else { return nil }
        return Int64(((min * 60 + sec) * 1000).rounded())
    }

    var body: some View {
        HStack(spacing: Space.xs) {
            Text(title).zfont(11, .bold).foregroundStyle(Theme.muted)
            TextField("", text: Binding(get: { text }, set: { if $0 != text { text = $0; dirty = true } })).textFieldStyle(.plain).zfont(12).monospacedDigit().frame(width: 72)
                .focused($focused).fieldChrome(focused: focused)
                .onSubmit { commit() }
                .onChange(of: focused) { _, f in if !f { commit() } }
        }
        .onAppear { text = Self.format(ms) }
        .onChange(of: ms) { _, v in if !dirty { text = Self.format(v) } }
    }

    private func commit() {
        if dirty, let v = Self.parse(text) { ms = v }
        dirty = false
        text = Self.format(ms)
    }
}

/// Trimming a sound: its waveform, the quiet ends already found, a player for the kept part.
struct TrimEditor: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let target: EditTarget
    let source: EditSource

    @State private var peaks: [Float] = []
    @State private var duration: Int64 = 0
    @State private var range = TimeRange(startMs: 0, endMs: 1)
    @State private var note = ""
    @State private var working = true
    @State private var player = AVPlayer()
    @State private var playing = false
    @State private var playhead: Int64?
    @State private var observers: [Any] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            HStack(alignment: .firstTextBaseline) {
                Text("Trim").dfont(22).foregroundStyle(Theme.text)
                Spacer()
                if working { MBSpinner() }
            }
            Rule()
            if duration > 0 {
                TrimBar(durationMs: duration, range: $range, peaks: peaks, playhead: playhead)
            } else if !working {
                Text("Couldn't read the sound in this file.").zfont(12).foregroundStyle(Theme.muted)
            }
            HStack(spacing: Space.s) {
                GlassButton(title: playing ? "Stop" : "Play what's kept", symbol: playing ? "stop.fill" : "play.fill") { togglePlay() }
                    .disabled(duration == 0)
                GlassButton(title: "Find quiet ends", symbol: "wand.and.rays") { Task { await detect() } }.disabled(working)
                GlassButton(title: "Keep it all", symbol: "arrow.uturn.backward") { range = TimeRange(startMs: 0, endMs: duration); note = "The whole sound is kept." }
                if source.edit != nil {
                    LinkText(text: "Undo all edits (back to the original)", color: Theme.danger, size: 12) { library.applyEdit(target, nil) }
                }
            }
            Spacer(minLength: 0)
            HStack {
                Text(note).zfont(12).foregroundStyle(Theme.muted)
                Spacer()
                GlassButton(title: "Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                GlassButton(title: "Apply", symbol: "checkmark", prominent: true) {
                    let whole = range.startMs <= 0 && range.endMs >= duration
                    library.applyEdit(target, whole ? nil : MediaEdit(trim: range))
                }
                .keyboardShortcut(.defaultAction).disabled(duration == 0)
            }
        }
        .padding(Space.xl)
        .frame(minWidth: 820, minHeight: 360)
        .background(Theme.background)
        .task { await start() }
        .onDisappear { stop() }
    }

    private func start() async {
        if let w = await library.waveform(source, count: 4000) {
            peaks = w.peaks; duration = w.durationMs
            range = source.edit?.trim ?? TimeRange(startMs: 0, endMs: w.durationMs)
        }
        player.replaceCurrentItem(with: AVPlayerItem(url: source.url))
        if source.edit?.trim != nil { note = "Trimmed earlier; change it, or choose Keep it all."; working = false } else { await detect() }
    }

    private func detect() async {
        working = true
        defer { working = false }
        if let r = await library.detectSilence(source) {
            range = r
            note = "Cut \(TimeField.format(r.startMs)) of quiet at the start and \(TimeField.format(duration - r.endMs)) at the end."
        } else {
            note = "No quiet ends found — drag the handles to trim."
        }
    }

    private func togglePlay() {
        if playing { stop(); return }
        let start = CMTime(value: range.startMs, timescale: 1000), end = CMTime(value: range.endMs, timescale: 1000)
        player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero)
        observers.append(player.addBoundaryTimeObserver(forTimes: [NSValue(time: end)], queue: .main) { Task { @MainActor in stop() } })
        observers.append(player.addPeriodicTimeObserver(forInterval: CMTime(value: 50, timescale: 1000), queue: .main) { t in
            Task { @MainActor in playhead = Int64(t.seconds * 1000) }
        })
        player.play(); playing = true
    }

    private func stop() {
        player.pause(); playing = false; playhead = nil
        for o in observers { player.removeTimeObserver(o) }
        observers = []
    }
}
