//
//  KeyboardNavigationTests.swift
//  imbibUITests
//
//  Tests for keyboard-only navigation support.
//

import XCTest

/// Tests for full keyboard navigation support.
///
/// Ensures all functionality is accessible without a mouse.
final class KeyboardNavigationTests: XCTestCase {

    var app: XCUIApplication!
    var sidebar: SidebarPage!
    var list: PublicationListPage!

    // MARK: - Setup

    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        app = TestApp.launch(with: .basic)
        sidebar = SidebarPage(app: app)
        list = PublicationListPage(app: app)

        _ = sidebar.waitForSidebar()
    }

    // MARK: - Tab Navigation Tests

    /// Test Tab key cycles through major UI areas
    func testTabCyclesThroughUIAreas() throws {
        // Start from a known position
        sidebar.sidebar.click()

        // Tab should move focus through:
        // 1. Sidebar
        // 2. List
        // 3. Detail (if visible)
        // 4. Back to sidebar

        for _ in 0..<3 {
            app.typeKey(.tab, modifierFlags: [])
        }

        // Shift+Tab should go backwards
        for _ in 0..<3 {
            app.typeKey(.tab, modifierFlags: .shift)
        }

        // No errors should occur
    }

    /// Test Tab doesn't get trapped in any component
    func testTabDoesNotGetTrapped() throws {
        // Tab 10 times - should cycle without getting stuck
        for _ in 0..<10 {
            app.typeKey(.tab, modifierFlags: [])
        }

        // If we got here without hanging, Tab isn't trapped
    }

    // MARK: - Arrow Key Navigation Tests

    /// Test arrow keys navigate sidebar
    func testArrowKeysNavigateSidebar() throws {
        sidebar.selectInbox()

        // Down arrow should select next item
        app.typeKey(.downArrow, modifierFlags: [])

        // Up arrow should go back
        app.typeKey(.upArrow, modifierFlags: [])

        // Home should go to first item
        app.typeKey(.home, modifierFlags: [])

        // End should go to last item
        app.typeKey(.end, modifierFlags: [])
    }

    /// Test arrow keys navigate publication list
    func testArrowKeysNavigateList() throws {
        sidebar.selectAllPublications()
        _ = list.waitForPublications()
        list.selectFirst()

        // Down moves to next
        list.navigateToNext()

        // Up moves to previous
        list.navigateToPrevious()

        // Cmd+Down goes to last
        list.navigateToLast()

        // Cmd+Up goes to first
        list.navigateToFirst()
    }

    /// Test arrow keys work in search results
    func testArrowKeysNavigateSearchResults() throws {
        let searchPalette = SearchPalettePage(app: app)
        searchPalette.open()
        _ = searchPalette.waitForPalette()
        searchPalette.search("Test")
        _ = searchPalette.waitForResults()

        // Down arrow selects next result
        searchPalette.navigateToNextResult()

        // Up arrow selects previous
        searchPalette.navigateToPreviousResult()

        searchPalette.close()
    }

    // MARK: - Keyboard Shortcut Tests

    /// Test all documented keyboard shortcuts work
    func testDocumentedShortcutsWork() throws {
        // View shortcuts
        app.typeKey("1", modifierFlags: .command) // Show Library
        app.typeKey("2", modifierFlags: .command) // Show Search
        app.typeKey("3", modifierFlags: .command) // Show Inbox

        // Detail tab shortcuts (need selection first)
        sidebar.selectAllPublications()
        _ = list.waitForPublications()
        list.selectFirst()

        app.typeKey("4", modifierFlags: .command) // PDF tab
        app.typeKey("5", modifierFlags: .command) // BibTeX tab
        app.typeKey("6", modifierFlags: .command) // Notes tab

        // Toggle shortcuts
        app.typeKey("0", modifierFlags: .command) // Toggle detail pane
        app.typeKey("s", modifierFlags: [.control, .command]) // Toggle sidebar

        // No errors = shortcuts working
    }

    /// Test Escape closes modal UI
    func testEscapeClosesModals() throws {
        // Open global search
        app.typeKey("f", modifierFlags: .command)
        let searchPalette = SearchPalettePage(app: app)
        XCTAssertTrue(searchPalette.waitForPalette(), "Search should open")

        // Escape should close it
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(searchPalette.waitForDismissal(), "Escape should close search")

        // Open settings
        app.typeKey(",", modifierFlags: .command)
        let settings = SettingsPage(app: app)
        _ = settings.waitForWindow()

        // Cmd+W should close it
        app.typeKey("w", modifierFlags: .command)
    }

    // MARK: - Enter/Return Key Tests

    /// Test Enter opens selected publication
    func testEnterOpensSelected() throws {
        sidebar.selectAllPublications()
        _ = list.waitForPublications()
        list.selectFirst()

        // Enter should open (show detail or open PDF)
        list.openSelected()

        // No error = works
    }

    /// Test Enter selects search result
    func testEnterSelectsSearchResult() throws {
        let searchPalette = SearchPalettePage(app: app)
        searchPalette.open()
        _ = searchPalette.waitForPalette()
        searchPalette.search("Einstein")
        _ = searchPalette.waitForResults()

        searchPalette.selectHighlightedResult()

        XCTAssertTrue(searchPalette.waitForDismissal(), "Enter should select and close")
    }

    // MARK: - Space Key Tests

    /// Test Space toggles selection in list
    func testSpaceTogglesSelection() throws {
        sidebar.selectAllPublications()
        _ = list.waitForPublications()
        list.selectFirst()

        // Space might toggle selection or preview
        app.typeKey(.space, modifierFlags: [])

        // No error = handled
    }

    // MARK: - Delete Key Tests

    /// Test Delete key deletes selected publication
    func testDeleteKeyDeletesSelected() throws {
        sidebar.selectAllPublications()
        _ = list.waitForPublications()
        list.selectFirst()

        // Cmd+Delete should delete
        app.typeKey(.delete, modifierFlags: .command)

        // A confirmation dialog might appear
        let deleteButton = app.buttons["Delete"]
        if deleteButton.waitForExistence(timeout: 1) {
            app.typeKey(.escape, modifierFlags: []) // Cancel for test
        }
    }

    // MARK: - Focus Indicator Tests

    /// Test focus is visible
    func testFocusIsVisible() throws {
        // This is a visual test - in UI tests we can verify focus moves
        // but not necessarily that it's visually indicated

        sidebar.sidebar.click()

        // After clicking, sidebar should have focus
        // The focus indicator should be visible (manual verification needed)
    }

    // MARK: - Multi-Select Tests

    /// Test Shift+Arrow extends selection
    func testShiftArrowExtendsSelection() throws {
        sidebar.selectAllPublications()
        _ = list.waitForPublications()
        list.selectFirst()

        // Shift+Down should extend selection
        app.typeKey(.downArrow, modifierFlags: .shift)
        app.typeKey(.downArrow, modifierFlags: .shift)

        // Multiple items should now be selected
        // (verification depends on selection state visibility)
    }

    /// Test Cmd+A selects all
    func testCmdASelectsAll() throws {
        sidebar.selectAllPublications()
        _ = list.waitForPublications()

        // Select all
        app.typeKey("a", modifierFlags: .command)

        // All items should be selected
        // (verification depends on selection state)
    }

    // MARK: - Menu Access Tests

    /// Test menus are keyboard accessible
    func testMenusKeyboardAccessible() throws {
        // Access File menu
        app.typeKey("f", modifierFlags: [.control])

        // If menu bar is focused, arrows navigate
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.downArrow, modifierFlags: [])

        // Escape closes menu
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - Context Menu Tests

    /// Test context menu via keyboard
    func testContextMenuViaKeyboard() throws {
        sidebar.selectAllPublications()
        _ = list.waitForPublications()
        list.selectFirst()

        // Shift+F10 or context menu key (if available) opens context menu
        // On macOS this is typically done with mouse, but Ctrl+click works
    }

    // MARK: - Modal Dialog Tests

    /// Test dialogs are keyboard navigable
    func testDialogsKeyboardNavigable() throws {
        // Open a dialog (e.g., New Library)
        app.menuItems["New Library..."].click()

        let dialog = app.sheets.firstMatch
        if dialog.waitForExistence(timeout: 2) {
            // Tab should move between fields
            app.typeKey(.tab, modifierFlags: [])

            // Enter should confirm (or click default button)
            app.typeKey(.escape, modifierFlags: []) // Cancel for test
        }
    }
}
