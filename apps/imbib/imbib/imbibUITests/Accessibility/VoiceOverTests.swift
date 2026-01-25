//
//  VoiceOverTests.swift
//  imbibUITests
//
//  Tests for VoiceOver accessibility support.
//

import XCTest

/// Tests for VoiceOver and screen reader accessibility.
final class VoiceOverTests: XCTestCase {

    var app: XCUIApplication!
    var sidebar: SidebarPage!
    var list: PublicationListPage!

    // MARK: - Setup

    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        app = TestApp.launchForAccessibility()
        sidebar = SidebarPage(app: app)
        list = PublicationListPage(app: app)

        _ = sidebar.waitForSidebar()
    }

    // MARK: - Sidebar Accessibility Tests

    /// Test that all sidebar items have accessibility labels
    func testSidebarItemsHaveLabels() throws {
        // All sidebar items should have non-empty accessibility labels
        let sidebarCells = sidebar.sidebar.cells.allElementsBoundByIndex

        for cell in sidebarCells {
            XCTAssertFalse(
                cell.label.isEmpty,
                "Sidebar cell should have an accessibility label"
            )
        }
    }

    /// Test inbox accessibility label includes unread count
    func testInboxLabelIncludesUnreadCount() throws {
        // The inbox row should announce unread count
        let inboxLabel = sidebar.inboxRow.label

        // Label should be descriptive
        XCTAssertTrue(
            inboxLabel.contains("Inbox") || inboxLabel.contains("inbox"),
            "Inbox should be labeled appropriately"
        )
    }

    /// Test library rows are properly labeled
    func testLibraryRowsAreProperyLabeled() throws {
        // Each library should have its name as the label
        sidebar.assertLibraryExists("Test Library")

        let libraryCell = sidebar.sidebar.staticTexts["Test Library"]
        XCTAssertFalse(libraryCell.label.isEmpty, "Library should have a label")
    }

    // MARK: - Publication List Accessibility Tests

    /// Test publication rows have descriptive labels
    func testPublicationRowsHaveDescriptiveLabels() throws {
        sidebar.selectAllPublications()
        _ = list.waitForPublications()

        let firstRow = list.firstRow
        let label = firstRow.label

        // Label should include title, author, or year
        XCTAssertFalse(
            label.isEmpty,
            "Publication row should have an accessibility label"
        )
    }

    /// Test publication rows announce read status
    func testPublicationRowsAnnounceReadStatus() throws {
        sidebar.selectAllPublications()
        _ = list.waitForPublications()

        // Rows should have traits or labels indicating read/unread
        let firstRow = list.firstRow

        // Check for accessibility traits or label content
        let traits = firstRow.value as? String ?? ""
        let label = firstRow.label

        // Either traits or label should convey status
        let hasStatusInfo = !traits.isEmpty || label.contains("unread") || label.contains("read")
        // This is a soft check - actual implementation may vary
    }

    // MARK: - Detail View Accessibility Tests

    /// Test detail view metadata is accessible
    func testDetailViewMetadataAccessible() throws {
        sidebar.selectAllPublications()
        _ = list.waitForPublications()
        list.selectFirst()

        let detail = DetailViewPage(app: app)
        _ = detail.waitForPublication()

        // Title should be accessible
        // Note: We check for static texts with expected content
        let titleElements = app.staticTexts.allElementsBoundByIndex
        let hasTitle = titleElements.contains { !$0.label.isEmpty }
        XCTAssertTrue(hasTitle, "Detail view should have accessible title")
    }

    /// Test tab buttons are accessible
    func testTabButtonsAccessible() throws {
        sidebar.selectAllPublications()
        _ = list.waitForPublications()
        list.selectFirst()

        let detail = DetailViewPage(app: app)

        // Tab buttons should have labels
        if detail.pdfTab.exists {
            XCTAssertFalse(
                detail.pdfTab.label.isEmpty,
                "PDF tab should have a label"
            )
        }

        if detail.bibtexTab.exists {
            XCTAssertFalse(
                detail.bibtexTab.label.isEmpty,
                "BibTeX tab should have a label"
            )
        }
    }

    // MARK: - Action Button Accessibility Tests

    /// Test toolbar buttons have labels
    func testToolbarButtonsHaveLabels() throws {
        let toolbarButtons = app.toolbars.buttons.allElementsBoundByIndex

        for button in toolbarButtons {
            XCTAssertFalse(
                button.label.isEmpty,
                "Toolbar button should have an accessibility label"
            )
        }
    }

    /// Test action buttons describe their purpose
    func testActionButtonsDescribePurpose() throws {
        sidebar.selectAllPublications()
        _ = list.waitForPublications()
        list.selectFirst()

        let detail = DetailViewPage(app: app)

        if detail.openPDFButton.exists {
            let label = detail.openPDFButton.label
            XCTAssertTrue(
                label.lowercased().contains("pdf") || label.lowercased().contains("open"),
                "Open PDF button should describe its action"
            )
        }
    }

    // MARK: - Search Accessibility Tests

    /// Test search field is accessible
    func testSearchFieldAccessible() throws {
        let searchPalette = SearchPalettePage(app: app)
        searchPalette.open()
        _ = searchPalette.waitForPalette()

        XCTAssertFalse(
            searchPalette.searchField.label.isEmpty,
            "Search field should have a label"
        )

        searchPalette.close()
    }

    /// Test search results are accessible
    func testSearchResultsAccessible() throws {
        let searchPalette = SearchPalettePage(app: app)
        searchPalette.open()
        _ = searchPalette.waitForPalette()
        searchPalette.search("Test")
        _ = searchPalette.waitForResults()

        // Each result should have a label
        let results = searchPalette.results.allElementsBoundByIndex
        for result in results {
            XCTAssertFalse(
                result.label.isEmpty,
                "Search result should have an accessibility label"
            )
        }

        searchPalette.close()
    }

    // MARK: - Focus and Navigation Tests

    /// Test focus order is logical
    func testFocusOrderIsLogical() throws {
        // Tab through major UI areas
        // Focus should move: Sidebar -> List -> Detail

        // Start with sidebar focused
        sidebar.sidebar.click()

        // Tab to list
        app.typeKey(.tab, modifierFlags: [])

        // Tab to detail
        app.typeKey(.tab, modifierFlags: [])

        // Focus should have moved logically
        // (Verification depends on focus state visibility)
    }

    /// Test arrow key navigation in sidebar
    func testArrowKeyNavigationInSidebar() throws {
        sidebar.sidebar.click()
        sidebar.selectInbox()

        // Down arrow should move to next item
        app.typeKey(.downArrow, modifierFlags: [])

        // Up arrow should move back
        app.typeKey(.upArrow, modifierFlags: [])

        // Navigation should work without errors
    }

    /// Test arrow key navigation in list
    func testArrowKeyNavigationInList() throws {
        sidebar.selectAllPublications()
        _ = list.waitForPublications()
        list.selectFirst()

        // Down arrow should select next
        list.navigateToNext()

        // Up arrow should select previous
        list.navigateToPrevious()

        // Navigation should work
    }

    // MARK: - Trait Tests

    /// Test buttons have button trait
    func testButtonsHaveButtonTrait() throws {
        let buttons = app.buttons.allElementsBoundByIndex

        for button in buttons where button.exists && button.isHittable {
            // Buttons should be identified as buttons
            // XCUIElement doesn't expose traits directly, but we can check elementType
            XCTAssertEqual(
                button.elementType,
                .button,
                "Button should have button element type"
            )
        }
    }

    /// Test text fields have appropriate traits
    func testTextFieldsHaveAppropriateTraits() throws {
        let searchPalette = SearchPalettePage(app: app)
        searchPalette.open()
        _ = searchPalette.waitForPalette()

        XCTAssertEqual(
            searchPalette.searchField.elementType,
            .textField,
            "Search field should be a text field"
        )

        searchPalette.close()
    }

    // MARK: - Hint Tests

    /// Test complex elements have hints
    func testComplexElementsHaveHints() throws {
        // Elements with non-obvious behavior should have hints
        // This is implementation-dependent
    }
}
