//
//  SearchPalettePage.swift
//  imbibUITests
//
//  Page Object for the global search palette (Cmd+F).
//

import XCTest

/// Page Object for the global search palette.
///
/// Provides access to the Cmd+F search overlay and its elements.
struct SearchPalettePage {

    // MARK: - Properties

    let app: XCUIApplication

    // MARK: - Elements

    /// The search palette container (sheet or popover)
    var container: XCUIElement {
        // Try sheets first, then popovers
        let sheet = app.sheets.firstMatch
        if sheet.exists { return sheet }
        let popover = app.popovers.firstMatch
        if popover.exists { return popover }
        // Fall back to groups with search-related identifiers
        return app.groups.firstMatch
    }

    /// The search text field - look for the "Search papers..." text field
    var searchField: XCUIElement {
        // Look for text field by placeholder
        let searchPapers = app.textFields["Search papers..."]
        if searchPapers.exists { return searchPapers }

        // Try search fields
        let searchFields = app.searchFields
        if searchFields.count > 0 {
            return searchFields.firstMatch
        }
        // Try regular text fields
        return app.textFields.firstMatch
    }

    /// The results list
    var resultsList: XCUIElement {
        // Results might be in a table, list, or scroll view
        let tables = app.tables
        if tables.count > 0 {
            return tables.firstMatch
        }
        return app.scrollViews.firstMatch
    }

    /// All result rows
    var results: XCUIElementQuery {
        app.tables.cells
    }

    /// The clear button in the search field
    var clearButton: XCUIElement {
        app.buttons["Clear"]
    }

    /// The close button
    var closeButton: XCUIElement {
        app.buttons["Close"]
    }

    // MARK: - Visibility

    /// Check if the search palette is visible
    var isVisible: Bool {
        // Check if any search field or the container is visible
        app.searchFields.count > 0 || app.sheets.count > 0 || app.popovers.count > 0
    }

    // MARK: - Open/Close

    /// Open the search palette using Cmd+F
    func open() {
        app.typeKey("f", modifierFlags: .command)
    }

    /// Close the search palette using Escape
    func close() {
        app.typeKey(.escape, modifierFlags: [])
    }

    /// Wait for the search palette to appear
    @discardableResult
    func waitForPalette(timeout: TimeInterval = 5) -> Bool {
        // Try waiting for search fields, sheets, or popovers
        if app.searchFields.firstMatch.waitForExistence(timeout: timeout) {
            return true
        }
        if app.sheets.firstMatch.waitForExistence(timeout: 1) {
            return true
        }
        if app.popovers.firstMatch.waitForExistence(timeout: 1) {
            return true
        }
        return false
    }

    /// Wait for the search palette to disappear
    @discardableResult
    func waitForDismissal(timeout: TimeInterval = 2) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: searchField)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    // MARK: - Search Actions

    /// Type a search query
    func search(_ query: String) {
        searchField.click()
        searchField.typeText(query)
    }

    /// Clear the search field
    func clearSearch() {
        if clearButton.exists {
            clearButton.click()
        } else {
            searchField.click()
            searchField.typeKey("a", modifierFlags: .command)
            searchField.typeKey(.delete, modifierFlags: [])
        }
    }

    /// Wait for results to appear
    @discardableResult
    func waitForResults(timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "count > 0")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: results)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    // MARK: - Result Selection

    /// Select a result at the given index
    func selectResult(at index: Int) {
        let result = results.element(boundBy: index)
        if result.waitForExistence(timeout: 2) {
            result.click()
        }
    }

    /// Select the first result
    func selectFirstResult() {
        selectResult(at: 0)
    }

    /// Navigate to next result using arrow key
    func navigateToNextResult() {
        app.typeKey(.downArrow, modifierFlags: [])
    }

    /// Navigate to previous result using arrow key
    func navigateToPreviousResult() {
        app.typeKey(.upArrow, modifierFlags: [])
    }

    /// Select the currently highlighted result using Enter
    func selectHighlightedResult() {
        app.typeKey(.return, modifierFlags: [])
    }

    // MARK: - Result Information

    /// Get the number of results
    var resultCount: Int {
        results.count
    }

    /// Get the title of a result at the given index
    func getResultTitle(at index: Int) -> String {
        let result = results.element(boundBy: index)
        return result.staticTexts.firstMatch.label
    }

    // MARK: - Assertions

    /// Assert the search palette is visible
    func assertVisible(file: StaticString = #file, line: UInt = #line) {
        XCTAssertTrue(
            isVisible,
            "Search palette should be visible",
            file: file,
            line: line
        )
    }

    /// Assert the search palette is not visible
    func assertNotVisible(file: StaticString = #file, line: UInt = #line) {
        XCTAssertFalse(
            isVisible,
            "Search palette should not be visible",
            file: file,
            line: line
        )
    }

    /// Assert the result count matches
    func assertResultCount(_ count: Int, file: StaticString = #file, line: UInt = #line) {
        XCTAssertEqual(
            resultCount,
            count,
            "Expected \(count) results, found \(resultCount)",
            file: file,
            line: line
        )
    }

    /// Assert there are results
    func assertHasResults(file: StaticString = #file, line: UInt = #line) {
        XCTAssertGreaterThan(
            resultCount,
            0,
            "Should have at least one result",
            file: file,
            line: line
        )
    }

    /// Assert a result with the given title exists
    func assertResultExists(titled title: String, file: StaticString = #file, line: UInt = #line) {
        let titleText = resultsList.staticTexts[title]
        XCTAssertTrue(
            titleText.exists,
            "Result with title '\(title)' should exist",
            file: file,
            line: line
        )
    }

    /// Assert the search field contains the expected text
    func assertSearchFieldText(_ expected: String, file: StaticString = #file, line: UInt = #line) {
        let actualText = searchField.value as? String ?? ""
        XCTAssertEqual(
            actualText,
            expected,
            "Search field should contain '\(expected)'",
            file: file,
            line: line
        )
    }
}

// MARK: - Search Flow Helpers

extension SearchPalettePage {

    /// Perform a complete search and select first result.
    ///
    /// Opens palette, types query, waits for results, selects first.
    /// - Parameter query: The search query
    func searchAndSelectFirst(_ query: String) {
        open()
        _ = waitForPalette()
        search(query)
        _ = waitForResults()
        selectFirstResult()
    }

    /// Perform a search and navigate results with keyboard.
    ///
    /// - Parameters:
    ///   - query: The search query
    ///   - resultIndex: Which result to select (0-indexed)
    func searchAndSelectWithKeyboard(_ query: String, resultIndex: Int) {
        open()
        _ = waitForPalette()
        search(query)
        _ = waitForResults()

        // Navigate down to the desired result
        for _ in 0..<resultIndex {
            navigateToNextResult()
        }

        selectHighlightedResult()
    }
}
