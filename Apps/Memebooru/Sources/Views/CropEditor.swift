import SwiftUI
import AVFoundation
import MemebooruCore

/// Cropping a picture, GIF or video (and trimming a video's ends); for sounds, `TrimEditor`.
/// Opens with plain borders already found; the frame can then be moved by its edges and corners or
/// typed in pixel by pixel. Zoomed in far, a pixel grid shows where each pixel is.
struct EditSheet: View {
    @Environment(Library.self) private var library
    let target: EditTarget
    var body: some View {
        if let s = library.editSource(target) {
            if s.kind == .audio { TrimEditor(target: target, source: s) } else { CropEditor(target: target, source: s) }
        } else {
            Text("Этот файл нельзя редактировать.").padding(Space.xl)
        }
    }
}

struct CropEditor: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.compactLayout) private var compact
    let target: EditTarget
    let source: EditSource

    @State private var image: PlatformImage?
    @State private var size = PixelSize(width: 1, height: 1)
    @State private var rect = PixelRect(x: 0, y: 0, width: 1, height: 1)
    @State private var zoom: CGFloat = 1             // 1 = the whole picture fits
    @State private var pan: CGSize = .zero
    @State private var zoomAtPinch: CGFloat?
    /// The stage's size, to know how many points a pixel is.
    @State private var area: CGSize = CGSize(width: 600, height: 400)
    private var fit: CGFloat { min(area.width / CGFloat(size.width), area.height / CGFloat(size.height)) * 0.94 }
    @State private var drag: DragState?
    @State private var note = ""
    @State private var detecting = false
    // Videos: which moment is shown, and the stretch kept.
    @State private var fraction = 0.1
    @State private var duration: Int64 = 0
    @State private var trim = TimeRange(startMs: 0, endMs: 0)
    @State private var peaks: [Float]?
    @State private var loadingSound = false

    private struct DragState { var mode: Mode; var startRect: PixelRect; var startPan: CGSize }
    private enum Mode { case move, pan, edge(left: Bool, top: Bool, right: Bool, bottom: Bool) }

    private var full: PixelRect { PixelRect(x: 0, y: 0, width: size.width, height: size.height) }
    private var isVideo: Bool { source.kind == .video }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            HStack(alignment: .firstTextBaseline) {
                Text(isVideo ? "Обрезка кадра и длительности" : "Обрезка").dfont(22).foregroundStyle(Theme.text)
                Spacer()
                Text("\(rect.width) × \(rect.height) из \(size.width) × \(size.height)").zfont(12).foregroundStyle(Theme.muted).monospacedDigit()
            }
            Rule()
            let stack = compact ? AnyLayout(VStackLayout(spacing: Space.l)) : AnyLayout(HStackLayout(alignment: .top, spacing: Space.xl))
            stack {
                VStack(spacing: Space.s) {
                    stage.frame(maxWidth: .infinity, maxHeight: .infinity)
                    zoomBar
                }
                controls.frame(width: compact ? nil : 280)
            }
            if isVideo && duration > 0 {
                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack(spacing: Space.m) {
                        SectionLabel(text: "Оставить")
                        if peaks == nil { Text(loadingSound ? "Читаем звуковую дорожку…" : "Без звука").zfont(11).foregroundStyle(Theme.muted) }
                        Spacer()
                        if peaks != nil {
                            LinkText(text: "Найти тишину по краям", size: 12) { Task { await findQuietEnds() } }
                        }
                    }
                    TrimBar(durationMs: duration, range: $trim, peaks: peaks) { ms in
                        let f = Double(ms) / Double(max(1, duration))
                        if abs(f - fraction) > 0.002 { fraction = f; Task { await loadFrame() } }
                    }
                }
            }
            HStack {
                Text(note).zfont(12).foregroundStyle(Theme.muted)
                Spacer()
                GlassButton(title: "Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                GlassButton(title: "Применить", symbol: "checkmark", prominent: true) { library.applyEdit(target, currentEdit) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(image == nil)
            }
        }
        .padding(Space.xl)
        .frame(minWidth: compact ? nil : 980, minHeight: compact ? nil : 680)
        .background(Theme.background)
        .task { await start() }
    }

    private var currentEdit: MediaEdit? {
        let c = rect == full ? nil : rect
        let t = isVideo && duration > 0 && (trim.startMs > 0 || trim.endMs < duration) ? trim : nil
        let e = MediaEdit(crop: c, trim: t)
        return e.isEmpty ? nil : e
    }

    private func start() async {
        if isVideo, let d = await library.durationMs(source) {
            duration = d
            trim = source.edit?.trim ?? TimeRange(startMs: 0, endMs: d)
            Task { await loadSound() }
        }
        await loadFrame()
        if let c = source.edit?.crop {
            rect = c.clamped(width: size.width, height: size.height)
            note = "Уже обрезано. Измените границы или выберите «Без обрезки»."
        } else {
            await detect()
        }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "editCorner") { focus(onX: rect.x, y: rect.y) }   // screenshots of the pixel grid
        #endif
    }

    /// The video's sound as a waveform under the Keep bar (loud moments tall).
    private func loadSound() async {
        loadingSound = true
        defer { loadingSound = false }
        if let w = await library.waveform(source, count: 4000), !w.peaks.isEmpty, (w.peaks.max() ?? 0) > 0 { peaks = w.peaks }
    }

    private func findQuietEnds() async {
        if let r = await library.detectSilence(source) {
            trim = r
            note = "Тишина: \(TimeField.format(r.startMs)) в начале и \(TimeField.format(duration - r.endMs)) в конце."
        } else {
            note = "Тишина по краям не найдена."
        }
    }

    private func loadFrame() async {
        guard let f = await library.editFrame(source, at: fraction) else { note = "Не удалось прочитать файл."; return }
        let first = image == nil
        image = f.image; size = f.size
        if first { rect = full }
    }

    private func detect() async {
        detecting = true
        defer { detecting = false }
        if let r = await library.detectBorders(source) {
            rect = r
            note = "Однотонные края: слева \(r.x), сверху \(r.y), справа \(size.width - r.x - r.width), снизу \(size.height - r.y - r.height)."
        } else {
            rect = full
            note = "Однотонные края не найдены. Укажите границы вручную."
        }
    }

    // MARK: Stage

    private var stage: some View {
        GeometryReader { geo in
            let fit = min(geo.size.width / CGFloat(size.width), geo.size.height / CGFloat(size.height)) * 0.94
            let s = fit * zoom
            let ox = (geo.size.width - CGFloat(size.width) * s) / 2 + pan.width
            let oy = (geo.size.height - CGFloat(size.height) * s) / 2 + pan.height
            let r = CGRect(x: ox + CGFloat(rect.x) * s, y: oy + CGFloat(rect.y) * s, width: CGFloat(rect.width) * s, height: CGFloat(rect.height) * s)
            ZStack(alignment: .topLeading) {
                Color(hex: 0x2B302C)
                if let image {
                    Image(platform: image)
                        .interpolation(s >= 3 ? .none : .high)          // close up: real pixels, not a blur
                        .resizable()
                        .frame(width: CGFloat(size.width) * s, height: CGFloat(size.height) * s)
                        .offset(x: ox, y: oy)
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                }
                Canvas { ctx, area in
                    // Everything outside the frame dimmed.
                    var outside = Path(CGRect(origin: .zero, size: area))
                    outside.addRect(r)
                    ctx.fill(outside, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))
                    // Pixel grid, once a pixel is big enough to see.
                    if s >= 8 {
                        var grid = Path()
                        let x0 = max(0, Int(((0 - ox) / s).rounded(.down))), x1 = min(size.width, Int(((area.width - ox) / s).rounded(.up)))
                        let y0 = max(0, Int(((0 - oy) / s).rounded(.down))), y1 = min(size.height, Int(((area.height - oy) / s).rounded(.up)))
                        if x1 - x0 < 600 && y1 - y0 < 600 {
                            for i in x0...x1 { let x = ox + CGFloat(i) * s; grid.move(to: CGPoint(x: x, y: max(0, oy + CGFloat(y0) * s))); grid.addLine(to: CGPoint(x: x, y: min(area.height, oy + CGFloat(y1) * s))) }
                            for j in y0...y1 { let y = oy + CGFloat(j) * s; grid.move(to: CGPoint(x: max(0, ox + CGFloat(x0) * s), y: y)); grid.addLine(to: CGPoint(x: min(area.width, ox + CGFloat(x1) * s), y: y)) }
                            // Dark and light together, so the lines show on any colour.
                            ctx.stroke(grid, with: .color(.black.opacity(0.45)), lineWidth: 1)
                            ctx.stroke(grid, with: .color(.white.opacity(0.45)), lineWidth: 0.5)
                        }
                    }
                    // The frame, its thirds, its handles.
                    ctx.stroke(Path(r), with: .color(.white), lineWidth: 1.5)
                    var thirds = Path()
                    for k in 1...2 {
                        let fx = r.minX + r.width * CGFloat(k) / 3, fy = r.minY + r.height * CGFloat(k) / 3
                        thirds.move(to: CGPoint(x: fx, y: r.minY)); thirds.addLine(to: CGPoint(x: fx, y: r.maxY))
                        thirds.move(to: CGPoint(x: r.minX, y: fy)); thirds.addLine(to: CGPoint(x: r.maxX, y: fy))
                    }
                    ctx.stroke(thirds, with: .color(.white.opacity(0.3)), lineWidth: 0.5)
                    for p in handlePoints(r) {
                        let h = CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)
                        ctx.fill(Path(h), with: .color(.white)); ctx.stroke(Path(h), with: .color(.black.opacity(0.5)), lineWidth: 1)
                    }
                }
                // As large as the view, not as the zoomed picture (which can be tens of thousands of points).
                .frame(width: geo.size.width, height: geo.size.height)
                .allowsHitTesting(false)
                if detecting { MBSpinner(size: 22, color: .white).frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
            .clipped()
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { v in onDrag(v, r: r, s: s) }
                .onEnded { _ in drag = nil })
            .simultaneousGesture(MagnifyGesture()
                .onChanged { v in
                    let base = zoomAtPinch ?? zoom
                    if zoomAtPinch == nil { zoomAtPinch = zoom }
                    setZoom(base * v.magnification)
                }
                .onEnded { _ in zoomAtPinch = nil })
            .onTapGesture(count: 2) { setZoom(zoom > 1.01 ? 1 : 4) }
        }
        .frame(minHeight: 360)
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { area = $0 }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border))
    }

    private func handlePoints(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.maxX, y: r.midY),
         CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
    }

    private func onDrag(_ v: DragGesture.Value, r: CGRect, s: CGFloat) {
        if drag == nil {
            // What was grabbed: an edge / corner (within 10 pt), the inside, or the picture around it.
            let p = v.startLocation, near: CGFloat = 10
            let l = abs(p.x - r.minX) < near, rt = abs(p.x - r.maxX) < near
            let t = abs(p.y - r.minY) < near, b = abs(p.y - r.maxY) < near
            let inY = p.y > r.minY - near && p.y < r.maxY + near, inX = p.x > r.minX - near && p.x < r.maxX + near
            let mode: Mode
            if (l || rt) && inY || (t || b) && inX { mode = .edge(left: l && inY, top: t && inX, right: rt && inY, bottom: b && inX) }
            else if r.contains(p) { mode = .move }
            else { mode = .pan }
            drag = DragState(mode: mode, startRect: rect, startPan: pan)
        }
        guard let d = drag else { return }
        let dx = Int((v.translation.width / s).rounded()), dy = Int((v.translation.height / s).rounded())
        let o = d.startRect
        switch d.mode {
        case .pan:
            pan = CGSize(width: d.startPan.width + v.translation.width, height: d.startPan.height + v.translation.height)
        case .move:
            rect = PixelRect(x: min(max(0, o.x + dx), size.width - o.width), y: min(max(0, o.y + dy), size.height - o.height),
                             width: o.width, height: o.height)
        case .edge(let left, let top, let right, let bottom):
            var x0 = o.x, y0 = o.y, x1 = o.x + o.width, y1 = o.y + o.height
            if left { x0 = min(max(0, o.x + dx), x1 - 1) }
            if right { x1 = max(min(size.width, x1 + dx), x0 + 1) }
            if top { y0 = min(max(0, o.y + dy), y1 - 1) }
            if bottom { y1 = max(min(size.height, y1 + dy), y0 + 1) }
            rect = PixelRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        }
    }

    /// Zooms around the middle of the view (what's in the middle stays there).
    private func setZoom(_ z: CGFloat) {
        let new = min(max(1, z), 200)
        pan = CGSize(width: pan.width * new / zoom, height: pan.height * new / zoom)
        zoom = new
    }

    /// Zooms in on a point of the picture (a corner of the frame), close enough that a pixel is 20 points.
    private func focus(onX x: Int, y: Int) {
        zoom = min(200, max(1, 20 / max(fit, 0.0001)))
        let s = fit * zoom
        pan = CGSize(width: (CGFloat(size.width) / 2 - CGFloat(x)) * s, height: (CGFloat(size.height) / 2 - CGFloat(y)) * s)
    }

    private var zoomBar: some View {
        HStack(spacing: Space.m) {
            GlassIconButton(symbol: "minus.magnifyingglass") { setZoom(zoom / 2) }.help("Уменьшить")
            GlassIconButton(symbol: "plus.magnifyingglass") { setZoom(zoom * 2) }.help("Увеличить жестом или двойным нажатием")
            GlassButton(title: "Вписать") { zoom = 1; pan = .zero }
            Text(zoom <= 1.001 ? "Всё изображение" : String(format: "%.0f×", zoom)).zfont(11).foregroundStyle(Theme.muted).monospacedDigit()
            Spacer()
            Text("Рассмотреть").zfont(11).foregroundStyle(Theme.muted)
            GlassButton(title: "Сверху слева") { focus(onX: rect.x, y: rect.y) }
            GlassButton(title: "Снизу справа") { focus(onX: rect.x + rect.width, y: rect.y + rect.height) }
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            SectionLabel(text: "Обрезать, пиксели")
            Grid(alignment: .leading, horizontalSpacing: Space.m, verticalSpacing: Space.s) {
                GridRow {
                    MarginField(title: "Слева", value: marginBinding(\.left))
                    MarginField(title: "Справа", value: marginBinding(\.right))
                }
                GridRow {
                    MarginField(title: "Сверху", value: marginBinding(\.top))
                    MarginField(title: "Снизу", value: marginBinding(\.bottom))
                }
            }
            Text("Перетаскивайте рамку, её края или углы. За пределами рамки перемещается изображение. Жестом или лупой можно увеличить масштаб до отдельных пикселей.")
                .zfont(11).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: Space.s) {
                GlassButton(title: "Найти однотонные края", symbol: "wand.and.rays") { Task { await detect() } }.disabled(detecting)
                GlassButton(title: "Без обрезки", symbol: "arrow.uturn.backward") { rect = full; note = "Изображение сохранится целиком." }
            }
            if source.edit != nil {
                LinkText(text: "Отменить все изменения и вернуть оригинал", color: Theme.danger, size: 12) { library.applyEdit(target, nil) }
            }
            Spacer(minLength: 0)
        }
    }

    private struct Margins { var left: Int; var top: Int; var right: Int; var bottom: Int }

    private var margins: Margins {
        Margins(left: rect.x, top: rect.y, right: size.width - rect.x - rect.width, bottom: size.height - rect.y - rect.height)
    }

    private func marginBinding(_ k: WritableKeyPath<Margins, Int>) -> Binding<Int> {
        Binding(get: { margins[keyPath: k] }, set: { v in
            var m = margins
            m[keyPath: k] = max(0, v)
            // Never less than one pixel left in either direction.
            let w = size.width - m.left - m.right, h = size.height - m.top - m.bottom
            guard w >= 1, h >= 1 else { return }
            rect = PixelRect(x: m.left, y: m.top, width: w, height: h)
        })
    }
}

/// "Left [ 24 ] − +" — a number of pixels, typed or stepped one at a time.
private struct MarginField: View {
    let title: String
    @Binding var value: Int
    @State private var text = ""
    /// Typed into since it last showed the value: only then does leaving the field set it (a sheet
    /// focuses its first field on its own — that alone must not write a stale number back).
    @State private var dirty = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(title).zfont(11, .bold).foregroundStyle(Theme.muted)
            HStack(spacing: Space.xs) {
                TextField("", text: Binding(get: { text }, set: { if $0 != text { text = $0; dirty = true } }))
                    .textFieldStyle(.plain).zfont(13).monospacedDigit().frame(width: 52)
                    .focused($focused).fieldChrome(focused: focused)
                    .onSubmit { commit() }
                    .onChange(of: focused) { _, f in if !f { commit() } }
                Stepper("", value: $value, in: 0...100_000).labelsHidden()
            }
        }
        .onAppear { text = "\(value)" }
        .onChange(of: value) { _, v in if !dirty { text = "\(v)" } }
    }

    private func commit() {
        if dirty, let v = Int(text.trimmingCharacters(in: .whitespaces)) { value = v }
        dirty = false
        text = "\(value)"
    }
}
