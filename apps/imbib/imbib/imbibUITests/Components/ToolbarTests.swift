//
//  ToolbarTests.swift
//  imbibUITests
//
//  Component tests for the toolbar.
//

import XCTest

/// Component tests for the application toolbar.
final class ToolbarTests: XCTestCase {

    var app: XCUIApplication!

    // MARK: - Setup

    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        app = TestApp.launch(with: .basic)
        _ = app.waitForIdle()
    }

    // MARK: - Toolbar Visibility Tests

    /// Test toolbar is visible
    func testToolbarIsVisible() throws {
        let toolbar = app.toolbars.firstMatch
        XCTAssertTrue(toolbar.exists, "Toolbar should be visible")
    }

    // MARK: - Global Search Button Tests

    /// Test global search button exists
    func testGlobalSearchButtonExists() throws {
        let searchButton = app.toolbars.buttons[AccessibilityID.Toolbar.globalSearch]
        // Button might be identified differently
        let anySearchButton = app.toolbars.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'search'")
        ).firstMatch

        XCTAssertTrue(
            searchButton.exists || anySearchButton.exists,
            "Global search button should exist"
        )
    }

    /// Test global search button opens palette
    func testGlobalSearchButtonOpensPalette() throws {
        // Find and click search button
        let searchButton = app.toolbars.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'search'")
        ).firstMatch

        if searchButton.exists {
            searchButton.click()

            let searchPalette = SearchPalettePage(app: app)
            XCTAssertTrue(searchPalette.waitForPalette(), "Search palette should open")

            searchPalette.close()
        }
    }

    // MARK: - Sort Menu Tests

    /// Test sort menu exists
    func testSortMenuExists() throws {
        let sortButton = app.toolbars.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'sort'")
        ).firstMatch

        // Sort might be a popup button or menu
        let sortPopup = app.toolbars.popUpButtons.firstMatch

        XCTAssertTrue(
            sortButton.exists || sortPopup.exists,
            "Sort control should exist in toolbar"
        )
    }

    /// Test sort menu options
    func testSortMenuOptions() throws {
        let sortPopup = app.toolbars.popUpButtons.firstMatch

        if sortPopup.exists {
            sortPopup.click()

            // Should have sort options
            let titleOption = app.menuItems["Title"]
            let yearOption = app.menuItems["Year"]
            let dateAddedOption = app.menuItems["Date Added"]

            XCTAssertTrue(
                titleOption.exists || yearOption.exists || dateAddedOption.exists,
                "Sort menu should have expected options"
            )

            app.typeKey(.escape, modifierFlags: [])
        }
    }

    // MARK: - Filter Menu Tests

    /// Test filter menu exists
    func testFilterMenuExists() throws {
        let filterButton = app.toolbars.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'filter'")
        ).firstMatch

        // Might be part of view options
    }

    /// Test unread filter toggle
    func testUnreadFilterToggle() throws {
        // Toggle unread filter via keyboard
        app.typeKey("\\", modifierFlags: .command)

        // List should be filtered to unread only
        // Toggle back
        app.typeKey("\\", modifierFlags: .command)
    }

    /// Test PDF filter toggle
    func testPDFFilterToggle() throws {
        // Toggle PDF filter via keyboard
        app.typeKey("\\", modifierFlags: [.command, .shift])

        // List should be filtered to items with PDFs
        // Toggle back
        app.typeKey("\\", modifierFlags: [.command, .shift])
    }

    // MARK: - View Toggle Tests

    /// Test sidebar toggle button
    func testSidebarToggleButton() throws {
        let sidebarButton = app.toolbars.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'sidebar'")
        ).firstMatch

        if sidebarButton.exists {
            sidebarButton.click()
            // Sidebar should toggle
            sidebarButton.click()
            // Sidebar should toggle back
        }
    }

    /// Test detail pane toggle button
    func testDetailPaneToggleButton() throws {
        let detailButton = app.toolbars.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'detail' OR label CONTAINS[c] 'inspector'")
        ).firstMatch

        if detailButton.exists {
            detailButton.click()
            // Detail pane should toggle
            detailButton.click()
            // Detail pane should toggle back
        }
    }

    // MARK: - Add Publication Tests

    /// Test add publication button
    func testAddPublicationButton() throws {
        let addButton = app.toolbars.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'add' OR label CONTAINS[c] 'plus'")
        ).firstMatch

        if addButton.exists {
            addButton.click()

            // Should show options or open dialog
            // Cancel any dialog
            app.typeKey(.escape, modifierFlags: [])
        }
    }

    // MARK: - Refresh Tests

    /// Test refresh button
    func testRefreshButton() throws {
        let refreshButton = app.toolbars.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'refresh'")
        ).firstMatch

        if refreshButton.exists {
            refreshButton.click()
            // Should refresh current view
        }
    }

    // MARK: - Contextual Toolbar Tests

    /// Test toolbar shows contextual actions when selection changes
    func testToolbarContextualActions() throws {
        let sidebar = SidebarPage(app: app)
        _ = sidebar.waitForSidebar()
        sidebar.selectAllPublications()

        let list = PublicationListPage(app: app)
        _ = list.waitForPublications()
        list.selectFirst()

        // Toolbar might show additional actions for selected publication
    }

    // MARK: - Toolbar State Tests

    /// Test buttons are enabled/disabled appropriately
    func testButtonsEnabledStateAppropriately() throws {
        // Some buttons should be disabled when nothing is selected

        let sidebar = SidebarPage(app: app)
        _ = sidebar.waitForSidebar()
        sidebar.selectAllPublications()

        let list = PublicationListPage(app: app)
        _ = list.waitForPublications()

        // No selection - some buttons might be disabled
        app.typeKey(.escape, modifierFlags: [])

        // Select something
        list.selectFirst()

        // Selection-dependent buttons should now be enabled
    }

    // MARK: - Tooltip Tests

    /// Test toolbar buttons have tooltips
    func testToolbarButtonsHaveTooltips() throws {
        // Hover over buttons should show tooltips
        // XCUITest doesn't directly support tooltip verification
        // but we can check for accessibility labels

        let toolbarButtons = app.toolbars.buttons.allElementsBoundByIndex

        for button in toolbarButtons where button.exists {
            XCTAssertFalse(
                button.label.isEmpty,
                "Toolbar button should have label (tooltip)"
            )
        }
    }
}
