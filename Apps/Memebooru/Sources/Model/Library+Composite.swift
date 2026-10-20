import SwiftUI
import MemebooruCore

/// What the combined-picture editor works on.
enum CompositeTarget: Identifiable, Equatable {
    /// Staged pictures to combine into a new staged item, in this order.
    case new([String])
    /// A combined staged item.
    case staged(String)
    /// A saved combined post.
    case meme(MemeID)

    var id: String {
        switch self {
        case .new(let ids): "new:" + ids.joined(separator: ",")
        case .staged(let id): "staged:" + id
        case .meme(let id): "meme:" + id.rawValue
        }
    }
}

extension Library {
    // MARK: Selection (Staging grid)

    func toggleSelected(_ item: StagedItem) {
        if let i = stagingSelection.firstIndex(of: item.id) { stagingSelection.remove(at: i) } else { stagingSelection.append(item.id) }
    }

    var selectedStaged: [StagedItem] { stagingSelection.compactMap { id in stagedItems.first { $0.id == id } } }

    /// Only plain pictures can go into a combined picture (not GIFs, videos, tweets, or one that's combined already).
    static func combinable(_ item: StagedItem) -> Bool { item.kind == .image && item.payload.composite == nil }

    func commitSelected() {
        let items = selectedStaged
        stagingSelecting = false
        for i in items { commit(i) }
    }

    func discardSelected() {
        guard let c = collection else { return }
        let items = selectedStaged
        stagingSelecting = false
        do { lastUndoLabel = try c.discardStaged(items); reloadStaging(); refreshUndo() } catch { errorMessage = "\(error)" }
    }

    /// From a picture's page: back to the grid, choosing pictures to combine it with.
    func startCombining(with item: StagedItem) {
        openStaged = nil
        stagingKind = nil
        stagingSelecting = true
        stagingSelection = [item.id]
    }

    // MARK: Editor

    /// The pictures the editor lays out, in their current order.
    func compositeParts(_ target: CompositeTarget) -> [URL] {
        switch target {
        case .new(let ids): return ids.compactMap { id in stagedItems.first { $0.id == id }.flatMap { stagedFileURL($0) } }
        case .staged(let id): return stagedItems.first { $0.id == id }.map { staging?.parts($0) ?? [] } ?? []
        case .meme(let id): return ((try? collection?.parts(of: id)) ?? []).compactMap { fileURL($0) }
        }
    }

    func currentLayout(_ target: CompositeTarget) -> CompositeLayout? {
        switch target {
        case .new: return nil
        case .staged(let id): return stagedItems.first { $0.id == id }?.payload.composite?.layout
        case .meme(let id): return meme(id)?.payload.composite?.layout
        }
    }

    /// Makes (or redraws) the combined picture in the background; `order` indexes `compositeParts(target)`.
    func applyComposite(_ target: CompositeTarget, layout: CompositeLayout, order: [Int]) {
        guard let staging, let c = collection else { return }
        compositeEditor = nil
        busy = "Собираем коллаж…"
        let analyzer = analyzer
        let reordered = order == Array(order.indices) ? nil : order
        Task {
            switch target {
            case .new(let ids):
                let chosen = order.map { ids[$0] }
                let result = await MediaLoader.run { Result { try staging.combine(chosen, layout: layout) } }
                busy = nil
                switch result {
                case .success(let item):
                    stagingSelecting = false
                    lastUndoLabel = "Объединено изображений: \(ids.count)"
                    reloadStaging(); refreshUndo()
                    section = .staging
                    openStaged = item.id
                case .failure(let e): errorMessage = "\(e)"
                }
            case .staged(let id):
                let result = await MediaLoader.run { Result { try staging.recombine(id, layout: layout, order: reordered) } }
                busy = nil
                if case .failure(let e) = result { errorMessage = "\(e)" }
                reloadStaging()
            case .meme(let id):
                let result = await MediaLoader.run { Result { try c.recombine(id, layout: layout, order: reordered, analyzer: analyzer) } }
                busy = nil
                if case .failure(let e) = result { errorMessage = "\(e)" }
                forgetAspect(id)
                runSearch(reset: true)
                threadVersion += 1          // open post pages redraw
            }
        }
    }

    /// A combined staged item back into its pictures (one undo step).
    func splitStaged(_ item: StagedItem) {
        guard let staging else { return }
        do {
            let parts = try staging.split(item.id)
            lastUndoLabel = "Разделить на изображения: \(parts.count)"
            reloadStaging(); refreshUndo()
            openStaged = parts.first?.id
        } catch { errorMessage = "\(error)" }
    }

    /// "Добавить › Коллаж…": stage the chosen files, then lay them out.
    func combineFiles(_ urls: [URL]) {
        stage(urls: urls) { [weak self] staged in
            let pictures = staged.filter(Library.combinable)
            guard pictures.count >= 2 else {
                if !staged.isEmpty { self?.errorMessage = "Выберите хотя бы два изображения для коллажа." }
                return
            }
            self?.compositeEditor = .new(pictures.map(\.id))
        }
    }
}

extension CompositeLayout.Arrangement {
    var label: String {
        switch self { case .row: "В ряд"; case .column: "В колонку"; case .grid: "Сетка"; case .feature: "Главное и колонка" }
    }
}
