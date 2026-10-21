import SwiftUI
import MemebooruCore

/// Lays out the pictures of a combined meme: side by side, one above the other, in a grid, or one large
/// with the rest stacked beside it; how big (never larger than the largest picture) and how far apart;
/// in what order. The preview is drawn with the same geometry the combined picture is made with.
struct CompositeEditor: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.compactLayout) private var compact
    let target: CompositeTarget

    @State private var parts: [URL] = []
    @State private var sizes: [PixelSize] = []
    @State private var order: [Int] = []
    @State private var layout = CompositeLayout(.row)
    @State private var ready = false

    private var ordered: [PixelSize] { order.map { sizes[$0] } }
    private var isNew: Bool { if case .new = target { true } else { false } }

    var body: some View {
        let stack = compact ? AnyLayout(VStackLayout(spacing: Space.l)) : AnyLayout(HStackLayout(alignment: .top, spacing: Space.xl))
        VStack(alignment: .leading, spacing: Space.l) {
            HStack(alignment: .firstTextBaseline) {
                Text(isNew ? "Combine \(parts.count) pictures" : "Layout of \(parts.count) pictures").dfont(22).foregroundStyle(Theme.text)
                Spacer()
                if ready {
                    let g = layout.geometry(for: ordered)
                    Text("Result: \(g.width) × \(g.height)").zfont(12).foregroundStyle(Theme.muted).monospacedDigit()
                }
            }
            Rule()
            if ready {
                stack {
                    preview.frame(maxWidth: .infinity, maxHeight: .infinity)
                    controls.frame(width: compact ? nil : 300)
                }
            } else {
                MBSpinner(size: 22).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Spacer()
                GlassButton(title: "Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                GlassButton(title: isNew ? "Combine" : "Save layout", symbol: "checkmark", prominent: true) {
                    library.applyComposite(target, layout: layout, order: order)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!ready || parts.count < 2)
            }
        }
        .padding(Space.xl)
        .frame(minWidth: compact ? nil : 900, minHeight: compact ? nil : 600)
        .background(Theme.background)
        .task { load() }
    }

    private func load() {
        parts = library.compositeParts(target)
        // Measured the way the combined picture will be made (EXIF rotation, SVG…).
        sizes = library.staging?.partSizes(parts) ?? parts.map { _ in PixelSize(width: 1, height: 1) }
        order = Array(parts.indices)
        layout = library.currentLayout(target) ?? .suggested(for: sizes)
        ready = true
    }

    // MARK: Preview

    private var preview: some View {
        GeometryReader { geo in
            let g = layout.geometry(for: ordered)
            let k = min(geo.size.width / CGFloat(max(1, g.width)), geo.size.height / CGFloat(max(1, g.height)), 1)
            ZStack(alignment: .topLeading) {
                Color.white
                ForEach(Array(order.enumerated()), id: \.element) { pos, idx in
                    let f = g.frames[pos]
                    picture(parts[idx])
                        .frame(width: CGFloat(f.width) * k, height: CGFloat(f.height) * k)
                        .clipped()
                        .offset(x: CGFloat(f.x) * k, y: CGFloat(f.y) * k)
                }
            }
            .frame(width: CGFloat(g.width) * k, height: CGFloat(g.height) * k)
            .thumbShadow()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeOut(duration: 0.18), value: layout)
            .animation(.easeOut(duration: 0.18), value: order)
        }
        .frame(minHeight: 320)
    }

    @ViewBuilder private func picture(_ url: URL) -> some View {
        if let img = library.displayImage(url) { Image(platform: img).resizable().scaledToFill() } else { Theme.surfaceSunk }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            SectionLabel(text: "Arrangement")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.s), GridItem(.flexible(), spacing: Space.s)], spacing: Space.s) {
                ForEach(arrangements, id: \.self) { a in ArrangementTile(arrangement: a, on: layout.arrangement == a) { set(a) } }
            }
            if layout.arrangement == .grid {
                HStack {
                    Text("Pictures per row").zfont(12).foregroundStyle(Theme.text)
                    Spacer()
                    Stepper(value: Binding(get: { layout.columns }, set: { layout.columns = $0; layout.size = nil }),
                            in: 1...max(1, parts.count - 1)) {
                        Text("\(layout.columns)").zfont(13, .bold).monospacedDigit()
                    }
                    .fixedSize()
                }
            }

            let range = layout.sizeRange(for: ordered)
            let current = min(layout.size ?? range.upperBound, range.upperBound)
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack {
                    Text(sizeTitle).zfont(12).foregroundStyle(Theme.text)
                    Spacer()
                    Text(layout.size == nil || current == range.upperBound ? "\(current) px (largest)" : "\(current) px")
                        .zfont(12).foregroundStyle(Theme.muted).monospacedDigit()
                }
                MBSlider(value: Binding(get: { current }, set: { layout.size = $0 >= range.upperBound ? nil : $0 }), range: range)
                Text(sizeHint).zfont(11).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: Space.xs) {
                HStack {
                    Text("Space between").zfont(12).foregroundStyle(Theme.text)
                    Spacer()
                    Text("\(layout.gap) px").zfont(12).foregroundStyle(Theme.muted).monospacedDigit()
                }
                MBSlider(value: $layout.gap, range: 0...48)
            }

            SectionLabel(text: "Order")
            orderStrip
            Spacer(minLength: 0)
        }
    }

    private var arrangements: [CompositeLayout.Arrangement] {
        parts.count >= 3 ? [.row, .column, .grid, .feature] : [.row, .column]
    }

    private func set(_ a: CompositeLayout.Arrangement) {
        guard layout.arrangement != a else { return }
        layout.arrangement = a
        layout.size = nil                    // what "largest" means changes with the arrangement
        if a == .grid { layout.columns = min(max(2, layout.columns), max(2, parts.count - 1)) }
    }

    private var sizeTitle: String {
        switch layout.arrangement { case .row, .feature: "Height"; case .column, .grid: "Width" }
    }

    private var sizeHint: String {
        switch layout.arrangement {
        case .row: "All pictures get this height; the largest sets the most it can be."
        case .column: "All pictures get this width; the largest sets the most it can be."
        case .grid: "Every row fills this width."
        case .feature: "The first picture's height; the others stack beside it."
        }
    }

    /// Thumbnails in the current order, each with buttons to move it earlier or later.
    private var orderStrip: some View {
        FlowLayout(spacing: Space.s) {
            ForEach(Array(order.enumerated()), id: \.element) { pos, idx in
                VStack(spacing: Space.xs) {
                    picture(parts[idx]).frame(width: 56, height: 56).clipped().thumbShadow()
                        .overlay(alignment: .topLeading) {
                            Text("\(pos + 1)").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Theme.menu.opacity(0.85), in: RoundedRectangle(cornerRadius: 2)).padding(2)
                        }
                    HStack(spacing: Space.s) {
                        moveButton("chevron.left", enabled: pos > 0) { order.swapAt(pos, pos - 1) }
                        moveButton("chevron.right", enabled: pos < order.count - 1) { order.swapAt(pos, pos + 1) }
                    }
                }
            }
        }
    }

    private func moveButton(_ symbol: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(enabled ? Theme.link : Theme.faint)
                .frame(width: 18, height: 16).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!enabled).linkPointer()
        .accessibilityLabel(symbol == "chevron.left" ? "Move earlier" : "Move later")
    }
}

/// One arrangement choice: a small drawing of it and its name.
private struct ArrangementTile: View {
    let arrangement: CompositeLayout.Arrangement
    let on: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: Space.xs) {
                glyph.frame(width: 44, height: 30)
                Text(title).zfont(11, on ? .bold : .regular).foregroundStyle(on ? Theme.text : Theme.link)
            }
            .frame(maxWidth: .infinity).padding(.vertical, Space.s)
            .background(RoundedRectangle(cornerRadius: 4).fill(on ? Theme.paper : (hover ? Theme.surface : .clear)))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(on ? Theme.link : Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).linkPointer().onHover { hover = $0 }
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var title: String { arrangement.label }

    /// The arrangement drawn with plain blocks.
    @ViewBuilder private var glyph: some View {
        let c = on ? Theme.link : Theme.muted
        let r = RoundedRectangle(cornerRadius: 1.5)
        switch arrangement {
        case .row: HStack(spacing: 2) { r.fill(c); r.fill(c) }
        case .column: VStack(spacing: 2) { r.fill(c); r.fill(c) }
        case .grid: VStack(spacing: 2) { HStack(spacing: 2) { r.fill(c); r.fill(c) }; HStack(spacing: 2) { r.fill(c); r.fill(c) } }
        case .feature: HStack(spacing: 2) { r.fill(c).frame(width: 26); VStack(spacing: 2) { r.fill(c); r.fill(c) } }
        }
    }
}

/// A slider drawn like the player's scrubber: whole numbers, no native control chrome.
struct MBSlider: View {
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        GeometryReader { g in
            let span = max(1, range.upperBound - range.lowerBound)
            let frac = CGFloat(min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / CGFloat(span)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.rule).frame(height: 4)
                Capsule().fill(Theme.link).frame(width: g.size.width * frac, height: 4)
                Circle().fill(Theme.paper).frame(width: 14, height: 14)
                    .overlay(Circle().stroke(Theme.buttonBorder))
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
                    .offset(x: g.size.width * frac - 7)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let f = max(0, min(1, v.location.x / max(1, g.size.width)))
                value = range.lowerBound + Int((f * CGFloat(span)).rounded())
            })
        }
        .frame(height: 18)
        .accessibilityElement()
        .accessibilityValue("\(value)")
        .accessibilityAdjustableAction { dir in
            let step = max(1, (range.upperBound - range.lowerBound) / 20)
            value = dir == .increment ? min(range.upperBound, value + step) : max(range.lowerBound, value - step)
        }
    }
}
