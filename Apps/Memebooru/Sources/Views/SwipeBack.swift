import SwiftUI

#if os(macOS)
import AppKit

/// Reports a live two-finger horizontal trackpad gesture (began / delta-x per event / ended), so the
/// navigator can move the top page with the fingers in real time. A local scroll-wheel monitor is used
/// because the content's `ScrollView` consumes `scrollWheel` before any background view sees it.
struct SwipeTracker: NSViewRepresentable {
    var enabled: Bool
    /// Return true to start tracking this gesture as a back-swipe (its events are then consumed).
    var onBegan: () -> Bool
    var onChanged: (CGFloat) -> Void
    var onEnded: () -> Void

    func makeNSView(context: Context) -> NSView {
        context.coordinator.bind(self)
        context.coordinator.install()
        return NSView(frame: .zero)
    }
    func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.bind(self) }
    func makeCoordinator() -> Coordinator { Coordinator() }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.remove() }

    final class Coordinator {
        private var owner: SwipeTracker?
        private var monitor: Any?
        private var tracking = false
        func bind(_ o: SwipeTracker) { owner = o }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event) ?? event
            }
        }
        func remove() {
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
            tracking = false
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let owner, owner.enabled else { return event }

            if tracking {
                switch event.phase {
                case .changed:
                    owner.onChanged(event.scrollingDeltaX)
                    return nil
                case .ended, .cancelled:
                    tracking = false
                    owner.onEnded()
                    return nil
                default:
                    return nil   // swallow momentum tail of the tracked gesture
                }
            }

            // Not yet tracking: only a decisive rightward horizontal start counts as "back".
            guard event.phase == .began, event.hasPreciseScrollingDeltas else { return event }
            let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
            guard dx > 0, abs(dx) > abs(dy) * 1.4, owner.onBegan() else { return event }
            tracking = true
            owner.onChanged(dx)
            return nil
        }
    }
}
#else
struct SwipeTracker: View {   // iOS uses the built-in interactive pop gesture
    var enabled: Bool
    var onBegan: () -> Bool
    var onChanged: (CGFloat) -> Void
    var onEnded: () -> Void
    var body: some View { Color.clear.allowsHitTesting(false) }
}
#endif
