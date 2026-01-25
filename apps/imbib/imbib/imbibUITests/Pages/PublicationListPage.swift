//
//  PublicationListPage.swift
//  imbibUITests
//
//  Page Object for the publication list view.
//

import XCTest

/// Page Object for the publication list view.
///
/// Provides access to publication list elements and common actions.
struct PublicationListPage {

    // MARK: - Properties

    let app: XCUIApplication

    // MARK: - Elements

    /// The main list container
    var listContainer: XCUIElement {
        app.scrollViews[AccessibilityID.PublicationList.container].firstMatch
    }

    /// The list (table or collection view)
    var list: XCUIElement {
        // Try table first (macOS List), then collection view
        let table = app.tables.firstMatch
        if table.exists {
            return table
        }
        return app.collectionViews.firstMatch
    }

    /// All visible rows in the list
    var rows: XCUIElementQuery {
        list.cells
    }

    /// The search/filter field
    var searchField: XCUIElement {
        app.searchFields.firstMatch
    }

    /// The empty state view
    var emptyState: XCUIElement {
        app.staticTexts["No Publications"]
    }

    /// The first row in the list
    var firstRow: XCUIElement {
        rows.firstMatch
    }

    /// The last row in the list
    var lastRow: XCUIElement {
        rows.element(boundBy: rows.count - 1)
    }

    // MARK: - Wait Methods

    /// Wait for the list to be visible
    @discardableResult
    func waitForList(timeout: TimeInterval = 5) -> Bool {
        list.waitForExistence(timeout: timeout)
    }

    /// Wait for publications to load (list has rows)
    @discardableResult
    func waitForPublications(timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "count > 0")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: rows)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    // MARK: - Selection Actions

    /// Select the first publication in the list
    func selectFirst() {
        firstRow.click()
    }

    /// Select the last publication in the list
    func selectLast() {
        lastRow.click()
    }

    /// Select a publication by its cite key
    func selectPublication(citeKey: String) {
        let row = rows.containing(.staticText, identifier: citeKey).firstMatch
        if row.waitForExistence(timeout: 2) {
            row.click()
        }
    }

    /// Select a publication by title
    func selectPublication(titled title: String) {
        let row = rows.containing(.staticText, identifier: title).firstMatch
        if row.waitForExistence(timeout: 2) {
            row.click()
        }
    }

    /// Select publication at a specific index
    func selectPublication(at index: Int) {
        let row = rows.element(boundBy: index)
        if row.waitForExistence(timeout: 2) {
            row.click()
        }
    }

    /// Select multiple publications by index
    func selectPublications(at indices: [Int]) {
        for (i, index) in indices.enumerated() {
            let row = rows.element(boundBy: index)
            if i == 0 {
                row.click()
            } else {
                // Command-click for additional selections
                row.click(forDuration: 0.1, thenDragTo: row, withVelocity: .default, thenHoldForDuration: 0)
            }
        }
    }

    /// Select all publications
    func selectAll() {
        app.typeKey("a", modifierFlags: .command)
    }

    // MARK: - Navigation Actions

    /// Navigate to the next publication using keyboard
    func navigateToNext() {
        app.typeKey(.downArrow, modifierFlags: [])
    }

    /// Navigate to the previous publication using keyboard
    func navigateToPrevious() {
        app.typeKey(.upArrow, modifierFlags: [])
    }

    /// Navigate to the first publication using keyboard
    func navigateToFirst() {
        app.typeKey(.upArrow, modifierFlags: .command)
    }

    /// Navigate to the last publication using keyboard
    func navigateToLast() {
        app.typeKey(.downArrow, modifierFlags: .command)
    }

    /// Open the selected publication (press Enter)
    func openSelected() {
        app.typeKey(.return, modifierFlags: [])
    }

    // MARK: - Search/Filter Actions

    /// Focus the search field
    func focusSearch() {
        app.typeKey("f", modifierFlags: .command)
    }

    /// Search/filter publications by text
    func search(_ query: String) {
        focusSearch()
        searchField.typeText(query)
    }

    /// Clear the search filter
    func clearSearch() {
        if searchField.exists {
            searchField.click()
            searchField.typeKey("a", modifierFlags: .command)
            searchField.typeKey(.delete, modifierFlags: [])
        }
    }

    // MARK: - Context Menu Actions

    /// Right-click on a publication to show context menu
    func showContextMenu(forPublicationAt index: Int) {
        let row = rows.element(boundBy: index)
        row.rightClick()
    }

    /// Delete the selected publication via keyboard
    func deleteSelected() {
        app.typeKey(.delete, modifierFlags: .command)
    }

    /// Copy the selected publication via keyboard
    func copySelected() {
        app.typeKey("c", modifierFlags: .command)
    }

    /// Paste publications from clipboard
    func paste() {
        app.typeKey("v", modifierFlags: .command)
    }

    // MARK: - Triage Actions (Inbox)

    /// Keep the selected paper (Inbox triage)
    func keepSelected() {
        app.typeKey("k", modifierFlags: [])
    }

    /// Dismiss the selected paper (Inbox triage)
    func dismissSelected() {
        app.typeKey("d", modifierFlags: [])
    }

    /// Toggle star on selected paper
    func toggleStar() {
        app.typeKey("s", modifierFlags: [])
    }

    /// Toggle read status on selected paper
    func toggleRead() {
        app.typeKey("u", modifierFlags: [.command, .shift])
    }

    // MARK: - Assertions

    /// Assert the list has a specific number of publications
    func assertPublicationCount(_ count: Int, file: StaticString = #file, line: UInt = #line) {
        XCTAssertEqual(
            rows.count,
            count,
            "Expected \(count) publications, found \(rows.count)",
            file: file,
            line: line
        )
    }

    /// Assert the list has at least a specific number of publications
    func assertPublicationCount(greaterThan count: Int, file: StaticString = #file, line: UInt = #line) {
        XCTAssertGreaterThan(
            rows.count,
            count,
            "Expected more than \(count) publications, found \(rows.count)",
            file: file,
            line: line
        )
    }

    /// Assert a publication with the given title exists
    func assertPublicationExists(titled title: String, file: StaticString = #file, line: UInt = #line) {
        let titleText = list.staticTexts[title]
        XCTAssertTrue(
            titleText.waitForExistence(timeout: 2),
            "Publication with title '\(title)' should exist",
            file: file,
            line: line
        )
    }

    /// Assert a publication with the given cite key exists
    func assertPublicationExists(citeKey: String, file: StaticString = #file, line: UInt = #line) {
        let citeKeyText = list.staticTexts[citeKey]
        XCTAssertTrue(
            citeKeyText.waitForExistence(timeout: 2),
            "Publication with cite key '\(citeKey)' should exist",
            file: file,
            line: line
        )
    }

    /// Assert the list is empty (shows empty state)
    func assertEmpty(file: StaticString = #file, line: UInt = #line) {
        XCTAssertTrue(
            emptyState.waitForExistence(timeout: 2),
            "List should be empty",
            file: file,
            line: line
        )
    }

    /// Assert the first publication has changed (useful for triage tests)
    func assertFirstPublicationChanged(previousTitle: String, file: StaticString = #file, line: UInt = #line) {
        let firstTitle = firstRow.staticTexts.firstMatch.label
        XCTAssertNotEqual(
            firstTitle,
            previousTitle,
            "First publication should have changed",
            file: file,
            line: line
        )
    }

    /// Get the title of the first publication
    func getFirstPublicationTitle() -> String {
        firstRow.staticTexts.firstMatch.label
    }

    /// Assert a publication is marked as read
    func assertPublicationRead(at index: Int, file: StaticString = #file, line: UInt = #line) {
        let row = rows.element(boundBy: index)
        // Unread publications typically have a blue dot or bold text
        // This is a simplified check - adjust based on actual UI
        let unreadIndicator = row.images["unread"]
        XCTAssertFalse(
            unreadIndicator.exists,
            "Publication should be marked as read",
            file: file,
            line: line
        )
    }

    /// Assert a publication is marked as unread
    func assertPublicationUnread(at index: Int, file: StaticString = #file, line: UInt = #line) {
        let row = rows.element(boundBy: index)
        let unreadIndicator = row.images["unread"]
        XCTAssertTrue(
            unreadIndicator.exists,
            "Publication should be marked as unread",
            file: file,
            line: line
        )
    }
}
