import SwiftUI
import MemebooruCore
#if os(macOS)
import AppKit
#endif

/// Chromium/Helium-style interactive back. The page stays put; a small floating back-arrow chip slides in
/// from the left edge and tracks the two-finger swipe. A short travel "arms" it (chip brightens + a light
/// haptic); releasing while armed navigates back instantly. Releasing early retracts the chip. Light and
/// fast — nothing like Safari's whole-page slide.
struct DetailNavigator<Base: View>: View {
    @Environment(Library.self) private var library
    @ViewBuilder var base: Base

    @State private var drag: CGFloat = 0        // accumulated horizontal travel of the current gesture
    @State private var wasArmed = false

    private static var armDistance: CGFloat { 68 }   // short travel to trigger back
    private static var maxDrag: CGFloat { 108 }
    private var stack: [MemeID] { library.detailStack }
    private var swiping: Bool { drag > 0 }
    private var open: Bool { !stack.isEmpty || library.openStaged != nil }
    private var progress: CGFloat { min(1, drag / Self.armDistance) }
    private var armed: Bool { drag >= Self.armDistance }

    var body: some View {
        ZStack(alignment: .leading) {
            base

            // A staged item's page sits under any post opened from it (e.g. a duplicate's).
            if let staged = library.openStaged {
                StagedDetailView(id: staged).id(staged)
                    .background(Theme.background)
                    .zIndex(0.5)
            }

            ForEach(Array(stack.enumerated()), id: \.offset) { i, id in
                MemeDetailView(id: id)
                    .background(Theme.background)
                    .zIndex(Double(i + 1))
            }

            if swiping, open { chip.zIndex(1000) }
        }
        .background(
            SwipeTracker(enabled: open,
                         onBegan: { open },
                         onChanged: { dx in
                             drag = min(Self.maxDrag, max(0, drag + dx))
                             updateHaptic()
                         },
                         onEnded: { endDrag() })
        )
        .onChange(of: library.popToken) { _, _ in library.popDetailImmediate() }
        .onChange(of: open) { _, o in if !o { drag = 0; wasArmed = false } }
        .ignoresSafeArea()
    }

    private var chip: some View {
        ZStack {
            Circle().fill(.ultraThinMaterial)
            Circle().stroke(Color.white.opacity(0.12), lineWidth: 1)
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(armed ? Theme.accent : Theme.text)
        }
        .frame(width: 42, height: 42)
        .scaleEffect(armed ? 1.12 : 0.9 + 0.1 * progress)
        .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 2)
        .opacity(Double(min(1, progress * 1.4)))
        .offset(x: -14 + 34 * progress)
        .padding(.leading, 8)
        .frame(maxHeight: .infinity, alignment: .center)
        .animation(.spring(response: 0.22, dampingFraction: 0.7), value: armed)
        .allowsHitTesting(false)
    }

    private func endDrag() {
        if armed {
            library.popDetailImmediate()
            drag = 0; wasArmed = false
        } else {
            withAnimation(.easeOut(duration: 0.16)) { drag = 0 }
            wasArmed = false
        }
    }

    private func updateHaptic() {
        guard armed != wasArmed else { return }
        wasArmed = armed
        #if os(macOS)
        if armed { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        #endif
    }
}
