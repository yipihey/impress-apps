//
//  SearchPage.swift
//  imbibUITests
//
//  Created by Claude on 2026-01-22.
//

import XCTest

/// Page object for search form interactions
final class SearchPage {
    private let app: XCUIApplication

    init(app: XCUIApplication) {
        self.app = app
    }

    // MARK: - Main Search Elements

    var searchField: XCUIElement {
        app[AccessibilityID.Search.searchField]
    }

    var searchButton: XCUIElement {
        app[AccessibilityID.Search.searchButton]
    }

    var clearButton: XCUIElement {
        app[AccessibilityID.Search.clearButton]
    }

    var resultsList: XCUIElement {
        app[AccessibilityID.Search.resultsList]
    }

    var sourcePicker: XCUIElement {
        app[AccessibilityID.Search.sourcePicker]
    }

    var advancedToggle: XCUIElement {
        app[AccessibilityID.Search.advancedToggle]
    }

    var loadingIndicator: XCUIElement {
        app[AccessibilityID.Search.loadingIndicator]
    }

    func resultRow(index: Int) -> XCUIElement {
        app[AccessibilityID.Search.resultRow(index)]
    }

    // MARK: - ArXiv Elements

    var arxivTitleField: XCUIElement {
        app[AccessibilityID.Search.ArXiv.titleField]
    }

    var arxivAuthorField: XCUIElement {
        app[AccessibilityID.Search.ArXiv.authorField]
    }

    var arxivAbstractField: XCUIElement {
        app[AccessibilityID.Search.ArXiv.abstractField]
    }

    var arxivCategoryPicker: XCUIElement {
        app[AccessibilityID.Search.ArXiv.categoryPicker]
    }

    var arxivCategoryBrowser: XCUIElement {
        app[AccessibilityID.Search.ArXiv.categoryBrowser]
    }

    var arxivDateFromPicker: XCUIElement {
        app[AccessibilityID.Search.ArXiv.dateFromPicker]
    }

    var arxivDateToPicker: XCUIElement {
        app[AccessibilityID.Search.ArXiv.dateToPicker]
    }

    var arxivMaxResultsStepper: XCUIElement {
        app[AccessibilityID.Search.ArXiv.maxResultsStepper]
    }

    var arxivSortByPicker: XCUIElement {
        app[AccessibilityID.Search.ArXiv.sortByPicker]
    }

    // MARK: - ADS Elements

    var adsQueryField: XCUIElement {
        app[AccessibilityID.Search.ADS.queryField]
    }

    var adsAuthorField: XCUIElement {
        app[AccessibilityID.Search.ADS.authorField]
    }

    var adsTitleField: XCUIElement {
        app[AccessibilityID.Search.ADS.titleField]
    }

    var adsAbstractField: XCUIElement {
        app[AccessibilityID.Search.ADS.abstractField]
    }

    var adsYearField: XCUIElement {
        app[AccessibilityID.Search.ADS.yearField]
    }

    var adsYearFromField: XCUIElement {
        app[AccessibilityID.Search.ADS.yearFromField]
    }

    var adsYearToField: XCUIElement {
        app[AccessibilityID.Search.ADS.yearToField]
    }

    var adsBibcodeField: XCUIElement {
        app[AccessibilityID.Search.ADS.bibcodeField]
    }

    var adsDOIField: XCUIElement {
        app[AccessibilityID.Search.ADS.doiField]
    }

    // MARK: - Main Actions

    @discardableResult
    func search(_ query: String) -> SearchPage {
        searchField.typeTextWhenReady(query)
        searchButton.tapWhenReady()
        return self
    }

    @discardableResult
    func clearSearch() -> SearchPage {
        clearButton.tapWhenReady()
        return self
    }

    @discardableResult
    func toggleAdvanced() -> SearchPage {
        advancedToggle.tapWhenReady()
        return self
    }

    @discardableResult
    func selectResult(index: Int) -> SearchPage {
        resultRow(index: index).tapWhenReady()
        return self
    }

    @discardableResult
    func selectSource() -> SearchPage {
        sourcePicker.tapWhenReady()
        return self
    }

    // MARK: - ArXiv Actions

    @discardableResult
    func searchArXivByTitle(_ title: String) -> SearchPage {
        arxivTitleField.typeTextWhenReady(title)
        searchButton.tapWhenReady()
        return self
    }

    @discardableResult
    func searchArXivByAuthor(_ author: String) -> SearchPage {
        arxivAuthorField.typeTextWhenReady(author)
        searchButton.tapWhenReady()
        return self
    }

    @discardableResult
    func setArXivTitle(_ title: String) -> SearchPage {
        arxivTitleField.typeTextWhenReady(title)
        return self
    }

    @discardableResult
    func setArXivAuthor(_ author: String) -> SearchPage {
        arxivAuthorField.typeTextWhenReady(author)
        return self
    }

    @discardableResult
    func setArXivAbstract(_ text: String) -> SearchPage {
        arxivAbstractField.typeTextWhenReady(text)
        return self
    }

    @discardableResult
    func selectArXivCategory() -> SearchPage {
        arxivCategoryPicker.tapWhenReady()
        return self
    }

    // MARK: - ADS Actions

    @discardableResult
    func searchADSByQuery(_ query: String) -> SearchPage {
        adsQueryField.typeTextWhenReady(query)
        searchButton.tapWhenReady()
        return self
    }

    @discardableResult
    func searchADSByAuthor(_ author: String) -> SearchPage {
        adsAuthorField.typeTextWhenReady(author)
        searchButton.tapWhenReady()
        return self
    }

    @discardableResult
    func setADSQuery(_ query: String) -> SearchPage {
        adsQueryField.typeTextWhenReady(query)
        return self
    }

    @discardableResult
    func setADSAuthor(_ author: String) -> SearchPage {
        adsAuthorField.typeTextWhenReady(author)
        return self
    }

    @discardableResult
    func setADSTitle(_ title: String) -> SearchPage {
        adsTitleField.typeTextWhenReady(title)
        return self
    }

    @discardableResult
    func setADSYear(_ year: String) -> SearchPage {
        adsYearField.typeTextWhenReady(year)
        return self
    }

    @discardableResult
    func setADSYearRange(from: String, to: String) -> SearchPage {
        adsYearFromField.typeTextWhenReady(from)
        adsYearToField.typeTextWhenReady(to)
        return self
    }

    @discardableResult
    func setADSBibcode(_ bibcode: String) -> SearchPage {
        adsBibcodeField.typeTextWhenReady(bibcode)
        return self
    }

    @discardableResult
    func setADSDOI(_ doi: String) -> SearchPage {
        adsDOIField.typeTextWhenReady(doi)
        return self
    }

    @discardableResult
    func performSearch() -> SearchPage {
        searchButton.tapWhenReady()
        return self
    }

    // MARK: - Verification

    func verifySearchFieldVisible(timeout: TimeInterval = 5) {
        XCTAssertTrue(searchField.waitForExistence(timeout: timeout), "Search field should be visible")
    }

    func verifyResultsVisible(timeout: TimeInterval = 10) {
        XCTAssertTrue(resultsList.waitForExistence(timeout: timeout), "Results list should be visible")
    }

    func verifyResultExists(index: Int, timeout: TimeInterval = 10) {
        XCTAssertTrue(resultRow(index: index).waitForExistence(timeout: timeout), "Result at index \(index) should exist")
    }

    func verifyLoading(timeout: TimeInterval = 5) {
        XCTAssertTrue(loadingIndicator.waitForExistence(timeout: timeout), "Loading indicator should be visible")
    }

    func verifyNotLoading(timeout: TimeInterval = 10) {
        XCTAssertFalse(loadingIndicator.waitForExistence(timeout: timeout), "Loading indicator should not be visible")
    }

    func verifyArXivFieldsVisible(timeout: TimeInterval = 5) {
        XCTAssertTrue(arxivTitleField.waitForExistence(timeout: timeout), "ArXiv title field should be visible")
        XCTAssertTrue(arxivAuthorField.waitForExistence(timeout: timeout), "ArXiv author field should be visible")
    }

    func verifyADSFieldsVisible(timeout: TimeInterval = 5) {
        XCTAssertTrue(adsQueryField.waitForExistence(timeout: timeout), "ADS query field should be visible")
        XCTAssertTrue(adsAuthorField.waitForExistence(timeout: timeout), "ADS author field should be visible")
    }

    func getResultCount() -> Int {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "search.result."))
            .count
    }

    func waitForResults(timeout: TimeInterval = 30) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                self.getResultCount() > 0
            },
            object: nil
        )
        _ = XCTWaiter.wait(for: [expectation], timeout: timeout)
    }
}
