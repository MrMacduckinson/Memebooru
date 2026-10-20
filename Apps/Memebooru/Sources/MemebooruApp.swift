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
                Button("Добавить файлы…") { library.presentFileImporter = true }.keyboardShortcut("o")
                Button("Открыть коллекцию…") { library.presentCollectionPicker = true }.keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(after: .sidebar) {
                Button("Увеличить") { library.zoomIn() }.keyboardShortcut("+", modifiers: .command)
                Button("Увеличить") { library.zoomIn() }.keyboardShortcut("=", modifiers: .command)
                Button("Уменьшить") { library.zoomOut() }.keyboardShortcut("-", modifiers: .command)
                Button("Исходный размер") { library.zoomReset() }.keyboardShortcut("0", modifiers: .command)
            }
        }
        #endif
    }
}
