import UIKit
import SwiftUI
import UniformTypeIdentifiers
import MemebooruCore
import MemebooruPlatformApple

/// Share sheet target: images, videos, text and tweet URLs land in the shared collection's staging.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareSheetView(model: model, done: { [weak self] in self?.finish() }))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        Task { await model.ingest(extensionContext?.inputItems as? [NSExtensionItem] ?? []) }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}

@Observable @MainActor
final class ShareModel {
    var status = "Сохраняем…"
    var staged: [StagedItem] = []
    var failed: [String] = []
    var done = false

    func ingest(_ items: [NSExtensionItem]) async {
        SharedCollection.shareMachineID()
        guard let url = SharedCollection.url, let collection = try? Collection.openOrCreate(at: url) else {
            status = "Не удалось открыть коллекцию"; done = true; return
        }
        let platform = PlatformApple.make()
        let staging = StagingArea(collection: collection, analyzer: MediaAnalyzer(platform: platform))
        for item in items {
            for provider in item.attachments ?? [] {
                do { try await ingest(provider, staging: staging, platform: platform, text: item.attributedContentText?.string) }
                catch { failed.append("\(error)") }
            }
        }
        status = staged.isEmpty ? "Ничего не сохранено" : "Добавлено во входящие"
        done = true
    }

    @MainActor private func ingest(_ p: NSItemProvider, staging: StagingArea, platform: Platform, text: String?) async throws {
        if p.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            let url = try await p.file(for: .movie)
            staged.append(try staging.add(file: url, source: "share", originalName: p.suggestedName ?? url.lastPathComponent, extraTags: ["source_unknown"]))
        } else if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            let url = try await p.file(for: .image)
            staged.append(try staging.add(file: url, source: "share", originalName: p.suggestedName ?? url.lastPathComponent, extraTags: ["source_unknown"]))
        } else if p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            let url = try await p.item(of: URL.self, for: .url)
            if TweetImporter.tweetID(from: url.absoluteString) != nil {
                let importer = TweetImporter(staging: staging, source: FxTwitterSource(http: platform.http), http: platform.http)
                staged.append(try await importer.importTweet(url.absoluteString))
            } else {
                staged.append(try staging.add(text: url.absoluteString, source: "share", context: text))
            }
        } else if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            let s = try await p.item(of: String.self, for: .plainText)
            staged.append(try staging.add(text: s, source: "share"))
        } else if let text, !text.isEmpty {
            staged.append(try staging.add(text: text, source: "share"))
        }
    }
}

extension NSItemProvider {
    /// Copy the shared file into a temp location we own (the provider's URL dies with the callback).
    @MainActor func file(for type: UTType) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            _ = loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                guard let url else { cont.resume(throwing: error ?? CollectionError("нет файла")); return }
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
                do { try FileManager.default.copyItem(at: url, to: dest); cont.resume(returning: dest) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    @MainActor func item<T: Sendable>(of: T.Type, for type: UTType) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            loadItem(forTypeIdentifier: type.identifier) { item, error in
                let value: T? = (item as? T) ?? ((item as? Data).flatMap { String(data: $0, encoding: .utf8) } as? T)
                if let value { cont.resume(returning: value) }
                else { cont.resume(throwing: error ?? CollectionError("неподдерживаемый элемент для импорта")) }
            }
        }
    }
}

struct ShareSheetView: View {
    let model: ShareModel
    let done: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Text("memebooru").font(.title2.bold())
            if model.done {
                Text(model.status)
                ForEach(model.staged, id: \.id) { i in
                    Text("\(i.kind.rawValue) · \(i.originalName ?? "")  →  \(i.effectiveTags.joined(separator: " "))").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.failed, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
                Button("Готово", action: done).buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
            } else {
                ProgressView(model.status)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.15, green: 0.145, blue: 0.135))
        .preferredColorScheme(.dark)
    }
}
