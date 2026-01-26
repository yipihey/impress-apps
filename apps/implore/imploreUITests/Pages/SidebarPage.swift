//
//  SidebarPage.swift
//  imploreUITests
//
//  Page Object for the sidebar.
//

import XCTest
import ImpressTestKit

/// Page Object for the sidebar
struct SidebarPage {

    // MARK: - Properties

    let app: XCUIApplication

    // MARK: - Elements

    /// Sidebar container
    var container: XCUIElement {
        app[ImploreAccessibilityID.Sidebar.container]
    }

    /// Selection count label
    var selectionCount: XCUIElement {
        app[ImploreAccessibilityID.Sidebar.selectionCount]
    }

    /// Edit selection button
    var editSelectionButton: XCUIElement {
        app[ImploreAccessibilityID.Sidebar.editSelectionButton]
    }

    // MARK: - State Checks

    /// Get the current selection count text
    var selectionCountText: String {
        selectionCount.label
    }

    // MARK: - Actions

    /// Click edit selection to open selection grammar
    func clickEditSelection() {
        editSelectionButton.tapWhenReady()
    }

    /// Select a field for an axis
    func selectField(axis: String, field: String) {
        let selector = app[ImploreAccessibilityID.Sidebar.fieldSelector(axis)]
        selector.tapWhenReady()
        app.menuItems[field].click()
    }

    // MARK: - Assertions

    /// Wait for sidebar to be ready
    @discardableResult
    func waitForSidebar(timeout: TimeInterval = 5) -> Bool {
        container.waitForExistence(timeout: timeout)
    }

    /// Assert sidebar exists
    func assertSidebarExists(file: StaticString = #file, line: UInt = #line) {
        XCTAssertTrue(
            container.exists,
            "Sidebar should exist",
            file: file,
            line: line
        )
    }

    /// Assert edit selection button exists
    func assertEditSelectionButtonExists(file: StaticString = #file, line: UInt = #line) {
        XCTAssertTrue(
            editSelectionButton.exists,
            "Edit selection button should exist",
            file: file,
            line: line
        )
    }

    /// Assert selection count shows expected value
    func assertSelectionCount(_ expected: String, file: StaticString = #file, line: UInt = #line) {
        XCTAssertTrue(
            selectionCountText.contains(expected),
            "Selection count should contain '\(expected)', got '\(selectionCountText)'",
            file: file,
            line: line
        )
    }
}
