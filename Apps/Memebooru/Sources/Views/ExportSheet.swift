import SwiftUI
import MemebooruCore

/// Export a meme: as stored, as its kept original, or converted to any format that makes sense for its
/// kind. Nothing here is saved back into the collection.
struct ExportSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let meme: Meme
    @State private var choice: ExportChoice = .stored
    @State private var initialised = false

    private var primary: Asset? { library.formats(of: meme.id).primary }
    private var original: Asset? { library.formats(of: meme.id).original }
    private var uncommonOnly: Bool { primary.map { $0.compatibility(kind: meme.kind) == .uncommon && $0.sourceLabel == nil } ?? false }
    private var popularTarget: MediaFormat? { primary.flatMap { FormatPolicy.popularTarget(kind: meme.kind, ext: $0.ext, codecs: $0.codecs) } }
    private var formats: [MediaFormat] {
        let hasAudio = primary.flatMap { MediaProbe(codecs: $0.codecs)?.audio } != nil || primary?.codecs == nil
        let converter = library.analyzer.converter
        let stored = [primary, original].compactMap { $0 }
        return FormatPolicy.exportFormats(kind: meme.kind, hasAudio: hasAudio)
            .filter { converter.supports($0) }
            .filter { f in !stored.contains { f.matches(ext: $0.ext, codecs: $0.codecs) } }   // already offered above
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Text("Export").dfont(22).foregroundStyle(Theme.text)
            if uncommonOnly, let p = primary {
                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack(spacing: Space.iconLabel) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(Theme.warnInk)
                        Text("This meme is stored only in an uncommon format (\(p.formatLabel)).").zfont(12, .bold).foregroundStyle(Theme.warnInk)
                    }
                    Text(popularTarget.map { "Convert it to \($0.label) before exporting? It's selected below." } ?? "Most apps may not open it.")
                        .zfont(12).foregroundStyle(Theme.text)
                }
                .padding(Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.warnBackground))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.warnBorder))
            }

            VStack(alignment: .leading, spacing: Space.xs) {
                if let p = primary {
                    radio(.stored, "As stored — \(p.formatLabel)", p.compatibility(kind: meme.kind) == .popular ? "popular" : "uncommon")
                }
                if let o = original { radio(.original, "Original — \(o.formatLabel)", "uncommon") }
            }

            if !formats.isEmpty {
                SectionBlock("Convert to") {
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                              alignment: .leading, spacing: Space.xs) {
                        ForEach(formats, id: \.self) { f in radio(.format(f), f.label, f.isPopular ? "popular" : nil) }
                    }
                }
                Text("A converted copy is only written where you save it — the collection keeps its files as they are.")
                    .zfont(11).foregroundStyle(Theme.muted)
            }

            HStack(spacing: Space.s) {
                Spacer()
                GlassButton(title: "Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                GlassButton(title: "Export…", symbol: "square.and.arrow.down", prominent: true) { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.xl)
        .frame(width: 520)
        .background(Theme.surface)
        .preferredColorScheme(.light)
        .onAppear {
            guard !initialised else { return }
            initialised = true
            if uncommonOnly, let t = popularTarget { choice = .format(t) }   // suggest the safe format
        }
    }

    private func radio(_ value: ExportChoice, _ title: String, _ note: String?) -> some View {
        Button { choice = value } label: {
            HStack(spacing: Space.s) {
                ZStack {
                    Circle().fill(Theme.paper).frame(width: 14, height: 14)
                    Circle().stroke(choice == value ? Theme.link : Theme.buttonBorder).frame(width: 14, height: 14)
                    if choice == value { Circle().fill(Theme.link).frame(width: 7, height: 7) }
                }
                Text(title).zfont(12).foregroundStyle(Theme.text)
                if let note { Text(note).zfont(10).foregroundStyle(note == "uncommon" ? Theme.warnInk : Theme.meta) }
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).linkPointer()
    }

    private var suggestedName: String {
        let base = (primary?.originalName).map { ($0 as NSString).deletingPathExtension } ?? meme.id.rawValue
        let ext: String = switch choice {
        case .stored: primary?.ext ?? "bin"
        case .original: original?.ext ?? "bin"
        case .format(let f): f.ext
        }
        return "\(base).\(ext)"
    }

    private func save() {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        let choice = choice, id = meme.id
        dismiss()
        if panel.runModal() == .OK, let url = panel.url { library.export(id, as: choice, to: url) }
        #else
        let choice = choice, id = meme.id
        dismiss()
        library.exportForSharing(id, as: choice)
        #endif
    }
}

#if os(iOS)
import UIKit

/// The system share sheet (Save to Files, AirDrop, Telegram…).
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ c: UIActivityViewController, context: Context) {}
}
#endif
