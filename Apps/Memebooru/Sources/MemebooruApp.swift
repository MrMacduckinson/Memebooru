import SwiftUI
import MemebooruCore

@main
struct MemebooruApp: App {
    @State private var library = Library()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .task { library.openLastOrDefault() }
                .onChange(of: scenePhase) { _, phase in
                    // Share Extension may have staged items while we were in the background.
                    if phase == .active { library.reloadStaging(); library.runSearch(reset: true) }
                }
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 860)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Files…") { library.presentFileImporter = true }.keyboardShortcut("o")
                Button("Open Collection…") { library.presentCollectionPicker = true }.keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(after: .sidebar) {
                Button("Zoom In") { library.zoomIn() }.keyboardShortcut("+", modifiers: .command)
                Button("Zoom In") { library.zoomIn() }.keyboardShortcut("=", modifiers: .command)
                Button("Zoom Out") { library.zoomOut() }.keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") { library.zoomReset() }.keyboardShortcut("0", modifiers: .command)
            }
        }
        #endif
    }
}
