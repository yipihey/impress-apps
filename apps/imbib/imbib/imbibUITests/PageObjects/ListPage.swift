//
//  ListPage.swift
//  imbibUITests
//
//  Created by Claude on 2026-01-22.
//

import XCTest

/// Page object for publication list interactions
final class ListPage {
    private let app: XCUIApplication

    init(app: XCUIApplication) {
        self.app = app
    }

    // MARK: - Elements

    var searchField: XCUIElement {
        app[AccessibilityID.List.searchField]
    }

    var sortButton: XCUIElement {
        app[AccessibilityID.List.sortButton]
    }

    var filterButton: XCUIElement {
        app[AccessibilityID.List.filterButton]
    }

    var selectAllButton: XCUIElement {
        app[AccessibilityID.List.selectAllButton]
    }

    var deleteButton: XCUIElement {
        app[AccessibilityID.List.deleteButton]
    }

    var emptyStateView: XCUIElement {
        app[AccessibilityID.List.emptyStateView]
    }

    // MARK: - Dynamic Elements

    func publicationRow(citeKey: String) -> XCUIElement {
        app[AccessibilityID.List.publicationRow(citeKey)]
    }

    func toggleReadButton(citeKey: String) -> XCUIElement {
        app[AccessibilityID.List.publicationToggleRead(citeKey)]
    }

    func toggleFlaggedButton(citeKey: String) -> XCUIElement {
        app[AccessibilityID.List.publicationToggleFlagged(citeKey)]
    }

    func pdfButton(citeKey: String) -> XCUIElement {
        app[AccessibilityID.List.publicationPDFButton(citeKey)]
    }

    // MARK: - Actions

    @discardableResult
    func search(_ query: String) -> ListPage {
        searchField.typeTextWhenReady(query)
        return self
    }

    @discardableResult
    func clearSearch() -> ListPage {
        searchField.tapWhenReady()
        searchField.clearAndTypeText("")
        return self
    }

    @discardableResult
    func tapSort() -> ListPage {
        sortButton.tapWhenReady()
        return self
    }

    @discardableResult
    func tapFilter() -> ListPage {
        filterButton.tapWhenReady()
        return self
    }

    @discardableResult
    func tapSelectAll() -> ListPage {
        selectAllButton.tapWhenReady()
        return self
    }

    @discardableResult
    func tapDelete() -> ListPage {
        deleteButton.tapWhenReady()
        return self
    }

    @discardableResult
    func selectPublication(citeKey: String) -> ListPage {
        publicationRow(citeKey: citeKey).tapWhenReady()
        return self
    }

    @discardableResult
    func doubleClickPublication(citeKey: String) -> ListPage {
        publicationRow(citeKey: citeKey).doubleClick()
        return self
    }

    @discardableResult
    func toggleRead(citeKey: String) -> ListPage {
        toggleReadButton(citeKey: citeKey).tapWhenReady()
        return self
    }

    @discardableResult
    func toggleFlagged(citeKey: String) -> ListPage {
        toggleFlaggedButton(citeKey: citeKey).tapWhenReady()
        return self
    }

    @discardableResult
    func openPDF(citeKey: String) -> ListPage {
        pdfButton(citeKey: citeKey).tapWhenReady()
        return self
    }

    // MARK: - Verification

    func verifySearchFieldVisible(timeout: TimeInterval = 5) {
        XCTAssertTrue(searchField.waitForExistence(timeout: timeout), "Search field should be visible")
    }

    func verifyPublicationExists(citeKey: String, timeout: TimeInterval = 5) {
        XCTAssertTrue(publicationRow(citeKey: citeKey).waitForExistence(timeout: timeout), "Publication \(citeKey) should exist")
    }

    func verifyPublicationNotExists(citeKey: String, timeout: TimeInterval = 2) {
        XCTAssertFalse(publicationRow(citeKey: citeKey).waitForExistence(timeout: timeout), "Publication \(citeKey) should not exist")
    }

    func verifyEmptyState(timeout: TimeInterval = 5) {
        XCTAssertTrue(emptyStateView.waitForExistence(timeout: timeout), "Empty state should be visible")
    }

    func verifyNotEmpty(timeout: TimeInterval = 2) {
        XCTAssertFalse(emptyStateView.waitForExistence(timeout: timeout), "List should not be empty")
    }

    func getPublicationCount() -> Int {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "list.publication."))
            .count
    }
}
