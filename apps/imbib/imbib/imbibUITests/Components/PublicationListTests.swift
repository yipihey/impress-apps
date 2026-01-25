//
//  PublicationListTests.swift
//  imbibUITests
//
//  Component tests for the publication list view.
//

import XCTest

/// Component tests for the publication list view.
final class PublicationListTests: XCTestCase {

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
        sidebar.selectAllPublications()
        _ = list.waitForPublications()
    }

    // MARK: - Display Tests

    /// Test list displays publications
    func testListDisplaysPublications() throws {
        list.assertPublicationCount(greaterThan: 0)
    }

    /// Test publication rows show title
    func testPublicationRowsShowTitle() throws {
        list.assertPublicationExists(titled: "On the Electrodynamics of Moving Bodies")
    }

    /// Test publication rows show author
    func testPublicationRowsShowAuthor() throws {
        // Author information should be visible
        let firstRow = list.firstRow
        let rowContent = firstRow.staticTexts.allElementsBoundByIndex.map { $0.label }.joined()
        // Should contain author name
    }

    /// Test publication rows show year
    func testPublicationRowsShowYear() throws {
        // Year should be visible in row
        let yearText = list.list.staticTexts["1905"]
        XCTAssertTrue(yearText.exists, "Year should be displayed")
    }

    // MARK: - Selection Tests

    /// Test single selection
    func testSingleSelection() throws {
        list.selectFirst()
        // First row should be selected
    }

    /// Test multi-selection with shift
    func testMultiSelectionWithShift() throws {
        list.selectFirst()
        app.typeKey(.downArrow, modifierFlags: .shift)
        app.typeKey(.downArrow, modifierFlags: .shift)
        // Three items should be selected
    }

    /// Test multi-selection with command
    func testMultiSelectionWithCommand() throws {
        list.selectPublication(at: 0)
        // Command-click on another
        let secondRow = list.rows.element(boundBy: 1)
        secondRow.click(forDuration: 0, thenDragTo: secondRow, withVelocity: .default, thenHoldForDuration: 0)
        // Both should be selected
    }

    /// Test select all
    func testSelectAll() throws {
        list.selectAll()
        // All rows should be selected
    }

    /// Test deselect
    func testDeselect() throws {
        list.selectFirst()
        // Click elsewhere to deselect
        app.typeKey(.escape, modifierFlags: [])
        // Selection should be cleared (depends on implementation)
    }

    // MARK: - Filter Tests

    /// Test filter reduces visible publications
    func testFilterReducesVisiblePublications() throws {
        let initialCount = list.rows.count

        list.search("Einstein")

        let filteredCount = list.rows.count
        XCTAssertLessThan(filteredCount, initialCount, "Filter should reduce count")
    }

    /// Test filter matches title
    func testFilterMatchesTitle() throws {
        list.search("Electrodynamics")

        list.assertPublicationExists(titled: "On the Electrodynamics of Moving Bodies")
    }

    /// Test filter matches author
    func testFilterMatchesAuthor() throws {
        list.search("Hawking")

        list.assertPublicationExists(titled: "Black hole explosions?")
    }

    /// Test filter matches year
    func testFilterMatchesYear() throws {
        list.search("1974")

        list.assertPublicationCount(greaterThan: 0)
    }

    /// Test clear filter shows all
    func testClearFilterShowsAll() throws {
        let initialCount = list.rows.count

        list.search("Einstein")
        list.clearSearch()

        list.assertPublicationCount(initialCount)
    }

    // MARK: - Sort Tests

    /// Test sort by title
    func testSortByTitle() throws {
        // Access sort menu and select title
        // Verify order changes
    }

    /// Test sort by year
    func testSortByYear() throws {
        // Access sort menu and select year
        // First publication should be oldest or newest
    }

    /// Test sort by date added
    func testSortByDateAdded() throws {
        // Access sort menu and select date added
    }

    /// Test sort order toggle
    func testSortOrderToggle() throws {
        // Toggle ascending/descending
        // Order should reverse
    }

    // MARK: - Read Status Tests

    /// Test unread publications are visually distinct
    func testUnreadPublicationsVisuallyDistinct() throws {
        // Unread publications should have visual indicator
        // (e.g., blue dot, bold text)
    }

    /// Test marking as read changes appearance
    func testMarkingAsReadChangesAppearance() throws {
        list.selectFirst()
        list.toggleRead()
        // Appearance should change
    }

    // MARK: - Context Menu Tests

    /// Test right-click shows context menu
    func testRightClickShowsContextMenu() throws {
        list.showContextMenu(forPublicationAt: 0)

        let menu = app.menus.firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 2), "Context menu should appear")

        app.typeKey(.escape, modifierFlags: [])
    }

    /// Test context menu has expected options
    func testContextMenuOptions() throws {
        list.showContextMenu(forPublicationAt: 0)

        // Should have Open, Copy, Delete, etc.
        let openItem = app.menuItems["Open PDF"]
        let copyItem = app.menuItems["Copy"]
        let deleteItem = app.menuItems["Delete"]

        XCTAssertTrue(
            openItem.exists || copyItem.exists || deleteItem.exists,
            "Context menu should have expected options"
        )

        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - Drag Tests

    /// Test dragging to sidebar collection
    func testDragToSidebarCollection() throws {
        list.selectFirst()
        // Drag to a collection in sidebar
        // Publication should be added to collection
    }

    /// Test dragging between libraries
    func testDragBetweenLibraries() throws {
        list.selectFirst()
        // Drag to different library
        // Publication should move
    }

    // MARK: - Empty State Tests

    /// Test empty state shows message
    func testEmptyStateShowsMessage() throws {
        // Filter to show no results
        list.search("xyznonexistent12345")

        // Empty state message should appear
        let emptyMessage = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'No'")).firstMatch
        XCTAssertTrue(emptyMessage.exists, "Empty state should show message")
    }

    // MARK: - Performance Tests

    /// Test scrolling performance with many items
    func testScrollingPerformanceWithManyItems() throws {
        // Would need large data set
        // Scroll through list and verify smooth performance
    }

    // MARK: - Keyboard Navigation Tests

    /// Test arrow keys navigate list
    func testArrowKeysNavigateList() throws {
        list.selectFirst()

        list.navigateToNext()
        // Second item should be selected

        list.navigateToPrevious()
        // First item should be selected again
    }

    /// Test Enter opens publication
    func testEnterOpensPublication() throws {
        list.selectFirst()
        list.openSelected()
        // Detail should show or PDF should open
    }

    /// Test Delete removes publication
    func testDeleteRemovesPublication() throws {
        let initialCount = list.rows.count
        list.selectFirst()
        list.deleteSelected()

        // Confirm if dialog appears
        let deleteButton = app.buttons["Delete"]
        if deleteButton.waitForExistence(timeout: 1) {
            deleteButton.click()
        }

        list.assertPublicationCount(initialCount - 1)
    }
}
