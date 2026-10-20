import Foundation
@testable import MemebooruCore

/// Fresh collection in a temp dir, removed on deinit.
final class TempCollection: @unchecked Sendable {
    let url: URL
    let collection: Collection
    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("memebooru-test-\(UUID().uuidString).memebooru")
        collection = try Collection.create(at: url)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}
