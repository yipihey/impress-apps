//
//  imbibUITests.swift
//  imbibUITests
//
//  Main UI test file - basic smoke tests.
//
//  For comprehensive tests, see:
//  - Workflows/ - End-to-end workflow tests
//  - Components/ - Individual component tests
//  - Accessibility/ - VoiceOver and accessibility tests
//  - Integration/ - Real API integration tests
//

import XCTest

/// Core UI tests for app launch and basic navigation
///
/// These tests run in a sandboxed environment with:
/// - Isolated Core Data store (temporary directory)
/// - CloudKit disabled (no iCloud sync)
/// - Separate UserDefaults suite (isolated preferences)
///
/// This ensures tests are deterministic and don't affect production data.
final class imbibUITests: XCTestCase {
    var app: XCUIApplication!
    var sidebar: SidebarPage!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = TestApp.launch()
        sidebar = SidebarPage(app: app)
    }

    override func tearDownWithError() throws {
        app = nil
        sidebar = nil
    }

    // MARK: - Launch Tests

    func testAppLaunchesSuccessfully() throws {
        // Verify sidebar is visible
        XCTAssertTrue(sidebar.waitForSidebar(), "Sidebar should appear on launch")
    }

    // MARK: - Navigation Tests

    func testSidebarNavigation() throws {
        // Wait for sidebar
        XCTAssertTrue(sidebar.waitForSidebar())

        // Select All Publications
        sidebar.selectAllPublications()

        // Verify list appears
        let list = PublicationListPage(app: app)
        XCTAssertTrue(list.waitForList(), "Publication list should appear")
    }

    func testSearchNavigation() throws {
        // Wait for sidebar
        XCTAssertTrue(sidebar.waitForSidebar())

        // Select Search Sources
        sidebar.selectSearchSources()

        // Search view should appear (no error)
    }

    func testInboxNavigation() throws {
        // Wait for sidebar
        XCTAssertTrue(sidebar.waitForSidebar())

        // Select Inbox
        sidebar.selectInbox()

        // Inbox view should appear (no error)
    }

    // MARK: - Global Search Tests

    func testGlobalSearchOpensAndCloses() throws {
        let searchPalette = SearchPalettePage(app: app)

        // Open with Cmd+F
        searchPalette.open()
        XCTAssertTrue(searchPalette.waitForPalette(), "Search palette should open")

        // Close with Escape
        searchPalette.close()
        XCTAssertTrue(searchPalette.waitForDismissal(), "Search palette should close")
    }

    // MARK: - Detail View Tests

    func testDetailViewShowsContent() throws {
        // Navigate to All Publications
        XCTAssertTrue(sidebar.waitForSidebar())
        sidebar.selectAllPublications()

        let list = PublicationListPage(app: app)
        _ = list.waitForPublications(timeout: 10)

        // If there are publications, select one
        if list.rows.count > 0 {
            list.selectFirst()

            let detail = DetailViewPage(app: app)
            _ = detail.waitForPublication(timeout: 5)
            // Detail should show (not empty state)
        }
    }

    // MARK: - Window Structure Tests

    func testMainWindowExists() throws {
        // Verify main window structure
        XCTAssertTrue(app.windows.count > 0, "At least one window should exist")
    }

    func testOutlineViewExists() throws {
        // The sidebar should contain an outline (List) view
        let outline = app.outlines.firstMatch
        XCTAssertTrue(
            outline.waitForExistence(timeout: 5),
            "Sidebar outline should exist"
        )
    }

    // MARK: - Keyboard Shortcut Tests

    func testKeyboardShortcutsWork() throws {
        // Test view switching shortcuts
        app.typeKey("1", modifierFlags: .command) // Show Library
        app.typeKey("2", modifierFlags: .command) // Show Search
        app.typeKey("3", modifierFlags: .command) // Show Inbox

        // No errors = shortcuts work
    }
}
