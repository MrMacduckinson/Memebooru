import XCTest
import Carbon

/// The app driven through its windows: each test seeds a throwaway collection, launches the UI-test host
/// on it (`-uiTestCollection`) and reviews staging the way a person does — clicks and ⌘-shortcuts.
@MainActor
final class MemebooruUITests: XCTestCase {
    private var seeded: SeededCollection?
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        app?.terminate()
        seeded?.remove()
    }

    private func launch(_ collection: SeededCollection) {
        seeded = collection
        app = XCUIApplication()
        app.launchArguments = ["-uiTestCollection", collection.url.path,
                               "-ApplePersistenceIgnoreState", "YES"]   // no restored windows from an earlier run
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20), "the window never appeared")
    }

    // MARK: - Queries

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func all(_ id: String) -> XCUIElementQuery { app.descendants(matching: .any).matching(identifier: id) }
    private var stagedCells: XCUIElementQuery { app.buttons.matching(identifier: "stagedCell") }
    private var postCells: XCUIElementQuery { app.buttons.matching(identifier: "postCell") }
    private func stagedCell(_ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == 'stagedCell' AND label == %@", title)).firstMatch
    }

    /// A text element's words (macOS puts them in `value`, labels in `label`).
    private func text(_ e: XCUIElement) -> String {
        if let v = e.value as? String, !v.isEmpty { return v }
        return e.label
    }

    private func wait(_ what: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line,
                      _ check: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if check() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
    }

    private func waitText(_ id: String, _ expected: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        wait("\(id) == “\(expected)”", timeout: timeout, file: file, line: line) { el(id).exists && text(el(id)) == expected }
    }

    private func waitGone(_ e: XCUIElement, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        wait(what, file: file, line: line) { !e.exists }
    }

    private func goToStaging() {
        el("nav.Staging").click()
        waitText("pageTitle", "Входящие")
    }

    private func key(_ k: XCUIKeyboardKey) { app.typeKey(k, modifierFlags: .command) }

    /// Types into a field. XCUITest types letters through the current keyboard layout, so with a
    /// non-Latin one (Russian) nothing arrives — or a letter turns into a ⌘-shortcut. Switch to the
    /// ASCII layout for the typing and back to the user's afterwards.
    private func type(_ text: String, into field: XCUIElement, replacing: Bool = false) {
        let previous = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        TISSelectInputSource(TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue())
        defer { TISSelectInputSource(previous) }
        field.click()
        if replacing {
            field.typeKey("a", modifierFlags: .command)
            field.typeKey(.delete, modifierFlags: [])
        }
        if !text.isEmpty { field.typeText(text) }
    }

    // MARK: - Tests

    func testLaunchShowsEmptyPosts() throws {
        launch(try .standard())
        waitText("pageTitle", "Коллекция")
        waitText("emptyState", "В коллекции пока пусто")
        XCTAssertTrue(el("nav.Posts").isSelected)
        XCTAssertEqual(postCells.count, 0)
    }

    func testStagingGridShowsTheSeededItems() throws {
        launch(try .standard())
        goToStaging()
        waitText("pageSubtitle", "5 pending")
        wait("five cells") { stagedCells.count == 5 }
        for name in SeededCollection.pictures { XCTAssertTrue(stagedCell(name).exists, name) }
        XCTAssertTrue(stagedCell(SeededCollection.text).exists)
        XCTAssertTrue(stagedCell("@" + SeededCollection.tweetHandle).exists)
        XCTAssertTrue(el("nav.Staging").isSelected)
    }

    func testGridAndListLayouts() throws {
        launch(try .standard())
        goToStaging()
        wait("grid") { stagedCells.count == 5 }
        XCTAssertTrue(el("layout.grid").isSelected)

        el("layout.list").click()
        wait("rows") { all("stagedRow").count >= 1 }
        XCTAssertEqual(stagedCells.count, 0)
        XCTAssertTrue(el("layout.list").isSelected)

        el("layout.grid").click()
        wait("grid again") { stagedCells.count == 5 }
        XCTAssertFalse(el("stagedRow").exists)
    }

    func testKindTabsFilterTheGrid() throws {
        launch(try .standard())
        goToStaging()
        wait("all") { stagedCells.count == 5 }
        XCTAssertTrue(el("kindTab.all").isSelected)

        el("kindTab.image").click()
        wait("pictures only") { stagedCells.count == 3 }
        XCTAssertTrue(el("kindTab.image").isSelected)
        el("kindTab.tweet").click()
        wait("the tweet") { stagedCells.count == 1 && stagedCell("@dril").exists }
        el("kindTab.text").click()
        wait("the text") { stagedCells.count == 1 && stagedCell(SeededCollection.text).exists }
        el("kindTab.all").click()
        wait("all again") { stagedCells.count == 5 }
    }

    func testFindInStaging() throws {
        launch(try .standard())
        goToStaging()
        wait("all") { stagedCells.count == 5 }
        let field = el("stagingFilter")
        type("frog", into: field)
        wait("one match") { stagedCells.count == 1 && stagedCell("frog-gamma").exists }

        type(" nothing-like-this", into: field)
        waitText("emptyState", "Нет совпадений")
        XCTAssertEqual(stagedCells.count, 0)

        type("", into: field, replacing: true)
        wait("everything back") { stagedCells.count == 5 }
    }

    /// Open → ⌘→ / ⌘← → ⌘↩ commits and opens the next → ⌘⌫ discards, Undo restores → back to the grid →
    /// the committed picture is a post → its page opens.
    func testReviewingStagedItems() throws {
        launch(try .standard())
        goToStaging()
        wait("grid") { stagedCells.count == 5 }

        stagedCell("cat-alpha").click()
        waitText("stagedTitle", "cat-alpha")
        waitText("stagedPosition", "· 1 of 5")

        key(.rightArrow)
        waitText("stagedTitle", "dog-beta")
        waitText("stagedPosition", "· 2 of 5")
        key(.leftArrow)
        waitText("stagedTitle", "cat-alpha")
        key(.leftArrow)                                                   // nothing before the first: stays
        waitText("stagedTitle", "cat-alpha")

        // The links in the side column do the same.
        el("stagedNext").click()
        waitText("stagedTitle", "dog-beta")
        el("stagedPrevious").click()
        waitText("stagedTitle", "cat-alpha")

        // Commit: straight on to the next one, which is now first of four.
        key(.return)
        waitText("stagedTitle", "dog-beta")
        waitText("stagedPosition", "· 1 of 4")

        // Discard: on to the next, with an undo strip.
        key(.delete)
        waitText("stagedTitle", "frog-gamma")
        waitText("stagedPosition", "· 1 of 3")
        XCTAssertTrue(el("undoLabel").waitForExistence(timeout: 5))
        el("undoButton").click()
        waitGone(el("undoButton"), "the undo strip to close")

        // Back to the grid: the discarded one is back, the committed one is gone.
        el("stagedBack").click()
        waitGone(el("stagedTitle"), "the staged page to close")
        waitText("pageSubtitle", "4 pending")
        wait("four cells") { stagedCells.count == 4 }
        XCTAssertTrue(stagedCell("dog-beta").exists)
        XCTAssertFalse(stagedCell("cat-alpha").exists)

        // The committed picture is a post now.
        el("nav.Posts").click()
        waitText("pageTitle", "Коллекция")
        wait("one post") { postCells.count == 1 }
        XCTAssertEqual(postCells.firstMatch.label, "cat-alpha")
        postCells.firstMatch.click()
        XCTAssertTrue(el("postTitle").waitForExistence(timeout: 5))
        el("postBack").click()
        waitGone(el("postTitle"), "the post page to close")
        XCTAssertEqual(postCells.count, 1)
    }

    /// The commit button and the discard link (not only the shortcuts), and the last item closing the page.
    func testButtonsOnTheStagedPage() throws {
        launch(try SeededCollection.make { s in
            try s.picture("only-one", pattern: 1)
            try s.picture("and-another", pattern: 2)
        })
        goToStaging()
        wait("grid") { stagedCells.count == 2 }
        stagedCell("only-one").click()
        waitText("stagedTitle", "only-one")
        el("stagedDiscard").click()
        waitText("stagedTitle", "and-another")
        el("stagedCommit").click()
        waitGone(el("stagedTitle"), "the page to close when nothing is left")
        waitText("pageSubtitle", "0 pending")
        waitText("emptyState", "Входящие пусты")
    }

    func testSearchBox() throws {
        launch(try SeededCollection.make { s in
            try s.commit(s.picture("tagged-frog", pattern: 1, tags: ["froggy"]))
            try s.commit(s.picture("plain-cat", pattern: 2))
            try s.commit(s.text("a committed text"))
        })
        waitText("pageTitle", "Коллекция")
        wait("three posts") { postCells.count == 3 }

        let search = el("searchField")
        type("froggy\r", into: search)
        waitText("pageTitle", "Поиск")
        wait("one result") { postCells.count == 1 }
        XCTAssertEqual(postCells.firstMatch.label, "froggy")          // a post's title is its tags

        // Searching from another page brings Posts back.
        goToStaging()
        type("text\r", into: search, replacing: true)                  // the kind tag
        waitText("pageTitle", "Поиск")
        wait("the text post") { postCells.count == 1 }

        type("no_such_tag\r", into: search, replacing: true)
        waitText("emptyState", "Ничего не найдено")

        type("", into: search, replacing: true)
        waitText("pageTitle", "Коллекция")
        wait("all posts") { postCells.count == 3 }

        // A post opens from the grid and its breadcrumb goes back.
        postCells.firstMatch.click()
        XCTAssertTrue(el("postTitle").waitForExistence(timeout: 5))
        el("postBack").click()
        waitGone(el("postTitle"), "the post page to close")
    }

    /// Layout sanity from element frames (no pixel goldens): grid cells are one size, in rows, inside the
    /// window and not overlapping; the staged page puts its side column to the right of the picture.
    func testLayoutOfGridAndStagedPage() throws {
        launch(try .standard())
        goToStaging()
        wait("grid") { stagedCells.count == 5 }
        let window = app.windows.firstMatch.frame
        let frames = stagedCells.allElementsBoundByIndex.map(\.frame)
        for (i, f) in frames.enumerated() {
            XCTAssertTrue(window.contains(f), "cell \(i) \(f) outside the window \(window)")
            XCTAssertEqual(f.width, frames[0].width, accuracy: 1, "cells are one width")
            for g in frames[(i + 1)...] { XCTAssertFalse(f.insetBy(dx: 1, dy: 1).intersects(g), "cells \(f) and \(g) overlap") }
        }
        XCTAssertGreaterThan(Set(frames.map { Int($0.minX) }).count, 1, "cells sit side by side, not in one column")
        add(XCTAttachment(screenshot: app.windows.firstMatch.screenshot()))

        stagedCell("cat-alpha").click()
        waitText("stagedTitle", "cat-alpha")
        let title = el("stagedTitle").frame, commit = el("stagedCommit").frame
        XCTAssertTrue(window.contains(commit), "the commit button is on screen")
        XCTAssertGreaterThan(commit.minX, title.minX, "the side column is to the right of the main one")
        add(XCTAttachment(screenshot: app.windows.firstMatch.screenshot()))
    }
}
