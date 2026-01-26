//
//  CitationPickerPage.swift
//  imprintUITests
//
//  Page Object for the citation picker modal.
//

import XCTest
import ImpressTestKit

/// Page Object for the citation picker modal
struct CitationPickerPage {

    // MARK: - Properties

    let app: XCUIApplication

    // MARK: - Elements

    /// Citation picker container (the sheet)
    var container: XCUIElement {
        app[ImprintAccessibilityID.CitationPicker.container]
    }

    /// Search field - try multiple ways to find it
    var searchField: XCUIElement {
        // Try by accessibility identifier
        let byId = app[ImprintAccessibilityID.CitationPicker.searchField]
        if byId.exists { return byId }
        // Try finding in sheets
        let inSheet = app.sheets.firstMatch.textFields.firstMatch
        if inSheet.exists { return inSheet }
        // Try in the container
        let inContainer = container.textFields.firstMatch
        if inContainer.exists { return inContainer }
        // Try any text field with placeholder
        let withPlaceholder = app.textFields["Search papers..."]
        if withPlaceholder.exists { return withPlaceholder }
        return byId
    }

    /// Results list
    var resultsList: XCUIElement {
        let byId = app[ImprintAccessibilityID.CitationPicker.resultsList]
        if byId.exists { return byId }
        // Try finding in container
        let inContainer = container.tables.firstMatch
        if inContainer.exists { return inContainer }
        return byId
    }

    /// Insert button - try multiple ways to find it
    var insertButton: XCUIElement {
        // Try by accessibility identifier first
        let byId = app[ImprintAccessibilityID.CitationPicker.insertButton]
        if byId.exists {
            return byId
        }
        // Try by label within sheets
        let sheetButton = app.sheets.firstMatch.buttons["Insert"]
        if sheetButton.exists {
            return sheetButton
        }
        // Try by label in the whole app
        let appButton = app.buttons["Insert"]
        if appButton.exists {
            return appButton
        }
        // Return the identifier-based query (will fail if not found)
        return byId
    }

    /// Cancel button - try multiple ways to find it
    var cancelButton: XCUIElement {
        // Try by accessibility identifier first
        let byId = app[ImprintAccessibilityID.CitationPicker.cancelButton]
        if byId.exists {
            return byId
        }
        // Try by label within sheets
        let sheetButton = app.sheets.firstMatch.buttons["Cancel"]
        if sheetButton.exists {
            return sheetButton
        }
        // Try by label in the whole app
        let appButton = app.buttons["Cancel"]
        if appButton.exists {
            return appButton
        }
        // Return the identifier-based query (will fail if not found)
        return byId
    }

    // MARK: - State Checks

    /// Check if the citation picker is open
    var isOpen: Bool {
        container.exists
    }

    /// Get the number of search results
    var resultCount: Int {
        resultsList.cells.count
    }

    /// Check if insert button is enabled
    var canInsert: Bool {
        insertButton.isEnabled
    }

    // MARK: - Actions

    /// Search for citations
    func search(_ query: String) {
        searchField.tapWhenReady()
        searchField.clearAndTypeText(query)
    }

    /// Select a result by index
    func selectResult(at index: Int) {
        let cells = resultsList.cells.allElementsBoundByIndex
        guard index < cells.count else { return }
        cells[index].tap()
    }

    /// Select a result by cite key
    func selectResult(citeKey: String) {
        let cell = resultsList.cells.containing(.staticText, identifier: citeKey).firstMatch
        cell.tapWhenReady()
    }

    /// Insert the selected citation
    func insertSelected() {
        insertButton.tapWhenReady()
    }

    /// Cancel and close the picker
    func cancel() {
        cancelButton.tapWhenReady()
    }

    /// Close using escape key
    func closeWithEscape() {
        app.typeKey(.escape, modifierFlags: [])
    }

    /// Search and insert a citation in one action
    func searchAndInsert(_ query: String, resultIndex: Int = 0) {
        search(query)
        // Wait for results
        _ = waitForResults()
        selectResult(at: resultIndex)
        insertSelected()
    }

    // MARK: - Assertions

    /// Wait for citation picker to appear
    @discardableResult
    func waitForPicker(timeout: TimeInterval = 5) -> Bool {
        container.waitForExistence(timeout: timeout)
    }

    /// Wait for search results to appear
    @discardableResult
    func waitForResults(timeout: TimeInterval = 5) -> Bool {
        resultsList.cells.firstMatch.waitForExistence(timeout: timeout)
    }

    /// Wait for picker to close
    @discardableResult
    func waitForClose(timeout: TimeInterval = 5) -> Bool {
        container.waitForDisappearance(timeout: timeout)
    }

    /// Assert picker is open
    func assertOpen(file: StaticString = #file, line: UInt = #line) {
        XCTAssertTrue(
            isOpen,
            "Citation picker should be open",
            file: file,
            line: line
        )
    }

    /// Assert picker is closed
    func assertClosed(file: StaticString = #file, line: UInt = #line) {
        XCTAssertFalse(
            isOpen,
            "Citation picker should be closed",
            file: file,
            line: line
        )
    }

    /// Assert search field exists (with wait)
    func assertSearchFieldExists(file: StaticString = #file, line: UInt = #line) {
        let exists = searchField.waitForExistence(timeout: 3)
        XCTAssertTrue(
            exists,
            "Search field should exist",
            file: file,
            line: line
        )
    }

    /// Assert result count
    func assertResultCount(_ expected: Int, file: StaticString = #file, line: UInt = #line) {
        XCTAssertEqual(
            resultCount,
            expected,
            "Expected \(expected) results, found \(resultCount)",
            file: file,
            line: line
        )
    }

    /// Assert insert button is enabled
    func assertCanInsert(file: StaticString = #file, line: UInt = #line) {
        XCTAssertTrue(
            canInsert,
            "Insert button should be enabled",
            file: file,
            line: line
        )
    }

    /// Assert insert button is disabled
    func assertCannotInsert(file: StaticString = #file, line: UInt = #line) {
        XCTAssertFalse(
            canInsert,
            "Insert button should be disabled",
            file: file,
            line: line
        )
    }
}
