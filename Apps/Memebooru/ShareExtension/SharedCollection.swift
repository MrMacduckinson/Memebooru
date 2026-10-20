import Foundation
import MemebooruCore

/// Where the default collection lives so the app and its extensions see the same one.
/// iOS: App Group container. macOS: ~/Documents/Memebooru (no sandbox yet).
enum SharedCollection {
    static let groupID = "group.dev.mrmacduckinson.memebooru"

    /// Point the core's machine id at the app group too, so the app and the extension are one install.
    static func shareMachineID() {
        #if os(iOS)
        if let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) {
            Collection.machineIDDirectory = base.appendingPathComponent("Library/Application Support/Memebooru", isDirectory: true)
        }
        #endif
    }

    static var url: URL? {
        #if os(iOS)
        guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else { return nil }
        return base.appendingPathComponent("Default.memebooru", isDirectory: true)
        #else
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Memebooru/Default.memebooru", isDirectory: true)
        #endif
    }
}
