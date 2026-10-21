import Foundation
import Testing
import MemebooruCore
@testable import Memebooru

/// Combining pictures the way the Staging screens do it.
@MainActor
@Suite(.serialized) struct CompositeAppTests {
    @Test func chooseCombineAndLandOnTheNewItem() async throws {
        let f = try AppFixture(); defer { f.tearDown() }
        let a = try f.picture("a.png", width: 40, height: 80), b = try f.picture("b.png", width: 40, height: 80)
        let text = try f.text("words")
        f.library.reloadStaging()
        f.library.go(.staging)

        f.library.stagingSelecting = true
        f.library.toggleSelected(b); f.library.toggleSelected(a); f.library.toggleSelected(text)
        #expect(f.library.stagingSelection == [b.id, a.id, text.id])          // in the order they were clicked
        #expect(f.library.selectedStaged.filter(Library.combinable).count == 2)
        f.library.toggleSelected(text)                                          // a second click takes it back out
        #expect(f.library.stagingSelection == [b.id, a.id])

        let target = CompositeTarget.new(f.library.stagingSelection)
        #expect(f.library.compositeParts(target).count == 2)
        f.library.applyComposite(target, layout: CompositeLayout(.column), order: [1, 0])   // a above b after all
        try await f.eventually("the combined item") { f.library.stagedItems.contains { $0.payload.composite != nil } }
        let c = try #require(f.library.stagedItems.first { $0.payload.composite != nil })
        #expect(f.library.openStaged == c.id)
        #expect(!f.library.stagingSelecting && f.library.stagingSelection.isEmpty)
        #expect(c.info.width == 40 && c.info.height == 160)
        #expect(f.library.stagedItems.count == 2)                                // the combined one and the text
        #expect(f.library.lastUndoLabel == "Combined 2 pictures")
    }

    @Test func relayoutAndSplitAStagedOne() async throws {
        let f = try AppFixture(); defer { f.tearDown() }
        let a = try f.picture("a.png", width: 50, height: 50), b = try f.picture("b.png", width: 50, height: 50)
        let c = try f.staging.combine([a.id, b.id], layout: CompositeLayout(.row))
        f.library.reloadStaging()
        #expect(f.library.currentLayout(.staged(c.id)) == CompositeLayout(.row))
        f.library.applyComposite(.staged(c.id), layout: CompositeLayout(.column, gap: 4), order: [0, 1])
        try await f.eventually("the new layout") { f.library.stagedItems.first { $0.id == c.id }?.info.height == 104 }

        let item = try #require(f.library.stagedItems.first { $0.id == c.id })
        f.library.splitStaged(item)
        #expect(f.library.stagedItems.count == 2 && f.library.stagedItems.allSatisfy { $0.payload.composite == nil })
        #expect(f.library.openStaged.map { id in f.library.stagedItems.contains { $0.id == id } } == true)
        f.library.undoLast()
        #expect(f.library.stagedItems.map(\.id) == [c.id])
    }

    @Test func savedPostsCanBeRelaidOut() async throws {
        let f = try AppFixture(); defer { f.tearDown() }
        let a = try f.picture("a.png", width: 60, height: 30), b = try f.picture("b.png", width: 60, height: 30)
        let c = try f.staging.combine([a.id, b.id])
        let meme = try f.staging.commit(c.id)
        f.library.runSearch(reset: true)
        #expect(f.library.compositeParts(.meme(meme.id)).count == 2)
        #expect(f.library.currentLayout(.meme(meme.id))?.arrangement == .column)     // two wide pictures: stacked
        f.library.applyComposite(.meme(meme.id), layout: CompositeLayout(.row), order: [1, 0])
        try await f.eventually("the new picture") { (try f.collection.memes.primaryAsset(of: meme.id))?.width == 120 }
        #expect(f.library.aspect(for: try #require(f.library.meme(meme.id))) == 4)
    }

    @Test func combiningFromAPicturesPage() throws {
        let f = try AppFixture(); defer { f.tearDown() }
        let a = try f.picture("a.png")
        f.library.reloadStaging()
        f.library.stagingKind = .image
        f.library.openStaged = a.id
        f.library.startCombining(with: a)
        #expect(f.library.openStaged == nil && f.library.stagingSelecting && f.library.stagingSelection == [a.id])
        #expect(f.library.stagingKind == nil)                                       // every kind of item shows, to pick from
        f.library.stagingSelecting = false
        #expect(f.library.stagingSelection.isEmpty)
    }

    @Test func onlyPlainPicturesCombine() throws {
        let f = try AppFixture(); defer { f.tearDown() }
        let a = try f.picture("a.png"), b = try f.picture("b.png")
        let c = try f.staging.combine([a.id, b.id])
        #expect(!Library.combinable(c))                                           // already combined
        #expect(!Library.combinable(try f.text("t")))
        #expect(!Library.combinable(try f.tweet("1", handle: "x", text: "y")))
        #expect(Library.combinable(try f.picture("d.png")))
    }
}
