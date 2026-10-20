import SwiftUI

#if os(macOS)
import AppKit

/// A single-line text field with a rock-steady baseline. SwiftUI's `.plain` TextField draws its
/// placeholder/value through the cell when idle and through the field editor when focused, and those two
/// have a ~2px different vertical inset — so the text visibly jumps up the moment you click in. Driving one
/// `NSTextField` ourselves (same metrics idle and focused, no focus ring) removes the jump entirely.
struct SteadyTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var size: CGFloat = 13
    var weight: NSFont.Weight = .regular
    var monospacedDigit: Bool = false
    var color: Color = Theme.text
    var onSubmit: () -> Void = {}
    @Environment(\.zoom) private var zoom

    private var font: NSFont {
        let s = size * zoom
        if monospacedDigit { return .monospacedDigitSystemFont(ofSize: s, weight: weight) }
        let base = NSFont(name: Theme.bodyFamily, size: s) ?? .systemFont(ofSize: s)
        return weight >= .semibold ? NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask) : base
    }

    func makeNSView(context: Context) -> NSTextField {
        let tf = SteadyNSTextField()
        tf.isBordered = false
        tf.isBezeled = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.usesSingleLineMode = true
        tf.maximumNumberOfLines = 1
        tf.lineBreakMode = .byClipping
        tf.cell?.usesSingleLineMode = true
        tf.cell?.wraps = false
        tf.cell?.isScrollable = true
        tf.allowsEditingTextAttributes = false
        tf.textColor = NSColor(color)
        tf.delegate = context.coordinator
        tf.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return tf
    }

    func updateNSView(_ tf: NSTextField, context: Context) {
        context.coordinator.parent = self
        if tf.font != font { tf.font = font }
        tf.textColor = NSColor(color)
        if tf.stringValue != text { tf.stringValue = text }
        if tf.placeholderString != placeholder { tf.placeholderString = placeholder }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SteadyTextField
        init(_ p: SteadyTextField) { parent = p }
        func controlTextDidChange(_ note: Notification) {
            guard let tf = note.object as? NSTextField else { return }
            parent.text = tf.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.insertNewline(_:)) { parent.onSubmit(); return true }
            return false
        }
    }
}

/// No focus ring; we style focus with the surrounding container instead.
private final class SteadyNSTextField: NSTextField {
    override var focusRingMaskBounds: NSRect { .zero }
    override func drawFocusRingMask() {}
}
#else
struct SteadyTextField: View {   // iOS has no such baseline jump; a plain field is fine.
    @Binding var text: String
    var placeholder: String = ""
    var size: CGFloat = 13
    var weight: Font.Weight = .regular
    var monospacedDigit: Bool = false
    var color: Color = Theme.text
    var onSubmit: () -> Void = {}
    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .foregroundStyle(color)
            .onSubmit(onSubmit)
    }
}
#endif
