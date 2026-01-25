//
//  TriageWorkflowTests.swift
//  imbibUITests
//
//  End-to-end tests for inbox triage workflows.
//

import XCTest

/// Tests for the inbox triage workflow (keep/dismiss papers).
final class TriageWorkflowTests: XCTestCase {

    var app: XCUIApplication!
    var sidebar: SidebarPage!
    var list: PublicationListPage!
    var detail: DetailViewPage!

    // MARK: - Setup

    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        // Launch with inbox triage test data
        app = TestApp.launch(with: .inboxTriage)
        sidebar = SidebarPage(app: app)
        list = PublicationListPage(app: app)
        detail = DetailViewPage(app: app)

        // Wait for app to be ready and navigate to inbox
        _ = sidebar.waitForSidebar()
    }

    // MARK: - Keep/Dismiss Tests

    /// Test keeping a paper using the K key
    func testKeepPaperWithKeyboard() throws {
        // Given: I'm viewing the inbox with papers
        sidebar.selectInbox()
        _ = list.waitForPublications()

        let initialCount = list.rows.count
        XCTAssertGreaterThan(initialCount, 0, "Should have papers in inbox")

        // Select the first paper
        list.selectFirst()
        let firstTitle = list.getFirstPublicationTitle()

        // When: I press K to keep
        list.keepSelected()

        // Then: The paper should be moved to the keep library
        // and the first publication should change
        list.assertFirstPublicationChanged(previousTitle: firstTitle)
    }

    /// Test dismissing a paper using the D key
    func testDismissPaperWithKeyboard() throws {
        // Given: I'm viewing the inbox with papers
        sidebar.selectInbox()
        _ = list.waitForPublications()

        let initialCount = list.rows.count
        XCTAssertGreaterThan(initialCount, 0, "Should have papers in inbox")

        list.selectFirst()
        let firstTitle = list.getFirstPublicationTitle()

        // When: I press D to dismiss
        list.dismissSelected()

        // Then: The paper should be removed from inbox
        list.assertFirstPublicationChanged(previousTitle: firstTitle)
    }

    /// Test rapid triage with keyboard
    func testRapidKeyboardTriage() throws {
        // Given: Multiple papers in inbox
        sidebar.selectInbox()
        _ = list.waitForPublications()

        let initialCount = list.rows.count
        XCTAssertGreaterThan(initialCount, 3, "Need at least 3 papers for this test")

        list.selectFirst()

        // When: I rapidly triage multiple papers
        list.keepSelected()    // K - keep first
        list.dismissSelected() // D - dismiss second
        list.keepSelected()    // K - keep third

        // Then: The inbox should have 3 fewer papers
        let expectedCount = initialCount - 3
        list.assertPublicationCount(expectedCount)
    }

    // MARK: - Star Tests

    /// Test starring a paper
    func testStarPaper() throws {
        // Given: A paper in the inbox
        sidebar.selectInbox()
        _ = list.waitForPublications()
        list.selectFirst()

        // When: I toggle star (S key)
        list.toggleStar()

        // Then: The paper should be starred
        // (verification would need accessibility identifier for star icon)
    }

    // MARK: - Read Status Tests

    /// Test marking a paper as read
    func testMarkPaperAsRead() throws {
        // Given: An unread paper in the inbox
        sidebar.selectInbox()
        _ = list.waitForPublications()
        list.selectFirst()

        // When: I toggle read status
        list.toggleRead()

        // Then: The paper should be marked as read
        list.assertPublicationRead(at: 0)
    }

    /// Test marking all papers as read
    func testMarkAllAsRead() throws {
        // Given: Multiple unread papers
        sidebar.selectInbox()
        _ = list.waitForPublications()

        // When: I use mark all as read (Cmd+Option+U)
        app.typeKey("u", modifierFlags: [.command, .option])

        // Then: All papers should be marked as read
        // (would need to verify each row)
    }

    // MARK: - Bulk Triage Tests

    /// Test bulk keeping multiple papers
    func testBulkKeep() throws {
        // Given: Multiple papers selected in inbox
        sidebar.selectInbox()
        _ = list.waitForPublications()

        let initialCount = list.rows.count
        XCTAssertGreaterThan(initialCount, 2, "Need at least 2 papers")

        // Select first two papers
        list.selectPublication(at: 0)
        // Shift-click to extend selection
        let secondRow = list.rows.element(boundBy: 1)
        secondRow.click(forDuration: 0.1, thenDragTo: secondRow)

        // When: I keep them
        list.keepSelected()

        // Then: Both should be moved
        list.assertPublicationCount(initialCount - 2)
    }

    // MARK: - Navigation During Triage Tests

    /// Test that after keeping, the next paper is automatically selected
    func testAutoAdvanceAfterKeep() throws {
        // Given: Multiple papers in inbox
        sidebar.selectInbox()
        _ = list.waitForPublications()
        list.selectFirst()

        // When: I keep the first paper
        list.keepSelected()

        // Then: The next paper should be automatically selected
        // (the first row should now be selected)
        // This depends on the app's behavior
    }

    // MARK: - Triage to Specific Library Tests

    /// Test keeping to a specific library
    func testKeepToSpecificLibrary() throws {
        // Given: Papers in inbox and multiple libraries exist
        sidebar.selectInbox()
        _ = list.waitForPublications()
        list.selectFirst()

        // When: I use Ctrl+Cmd+K to keep with library picker
        app.typeKey("k", modifierFlags: [.control, .command])

        // Then: A library picker should appear
        let picker = app.sheets.firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 2), "Library picker should appear")

        // Cancel for now
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - Undo Tests

    /// Test undoing a keep action
    func testUndoKeep() throws {
        // Given: I kept a paper
        sidebar.selectInbox()
        _ = list.waitForPublications()

        let initialCount = list.rows.count
        list.selectFirst()
        list.keepSelected()

        // When: I undo (Cmd+Z)
        app.typeKey("z", modifierFlags: .command)

        // Then: The paper should be back in inbox
        list.assertPublicationCount(initialCount)
    }

    /// Test undoing a dismiss action
    func testUndoDismiss() throws {
        // Given: I dismissed a paper
        sidebar.selectInbox()
        _ = list.waitForPublications()

        let initialCount = list.rows.count
        list.selectFirst()
        list.dismissSelected()

        // When: I undo
        app.typeKey("z", modifierFlags: .command)

        // Then: The paper should be back in inbox
        list.assertPublicationCount(initialCount)
    }
}
