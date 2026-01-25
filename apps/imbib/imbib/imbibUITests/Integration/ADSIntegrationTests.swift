//
//  ADSIntegrationTests.swift
//  imbibUITests
//
//  Integration tests for NASA ADS search functionality.
//
//  Note: These tests require an ADS API key and network access.
//  Run separately using the IntegrationTests test plan.
//

import XCTest

/// Integration tests for NASA ADS search.
///
/// These tests verify real ADS API integration.
/// Requires ADS_API_KEY environment variable to be set.
final class ADSIntegrationTests: XCTestCase {

    var app: XCUIApplication!
    var sidebar: SidebarPage!

    // MARK: - Setup

    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        // Launch WITHOUT mock services for integration tests
        app = TestApp.launchForIntegration()
        sidebar = SidebarPage(app: app)

        _ = sidebar.waitForSidebar()
    }

    // MARK: - Search Tests

    /// Test ADS search returns results
    func testADSSearchReturnsResults() throws {
        // Navigate to search sources
        sidebar.selectSearchSources()

        // Select ADS source
        // (This depends on the UI for source selection)

        // Enter a search query
        let searchField = app.textFields.firstMatch
        if searchField.waitForExistence(timeout: 5) {
            searchField.click()
            searchField.typeText("gravitational waves")
            searchField.typeKey(.return, modifierFlags: [])
        }

        // Wait for results
        let resultsList = app.tables.firstMatch
        let expectation = expectation(
            for: NSPredicate(format: "count > 0"),
            evaluatedWith: resultsList.cells
        )
        wait(for: [expectation], timeout: 30)

        // Should have results
        XCTAssertGreaterThan(resultsList.cells.count, 0, "Should find ADS results")
    }

    /// Test ADS search with bibcode
    func testADSSearchByBibcode() throws {
        // Search for specific bibcode
        // Should find the exact paper
    }

    /// Test ADS search with author
    func testADSSearchByAuthor() throws {
        // Search by author name
        // Verify results are from that author
    }

    /// Test fetching BibTeX from ADS
    func testFetchBibTeXFromADS() throws {
        // Search for a paper
        // Select it
        // Verify BibTeX is fetched correctly
    }

    // MARK: - API Key Tests

    /// Test behavior without API key
    func testADSWithoutAPIKey() throws {
        // Clear API key
        // Try to search
        // Should show appropriate error or prompt
    }

    /// Test behavior with invalid API key
    func testADSWithInvalidAPIKey() throws {
        // Set invalid API key
        // Try to search
        // Should show authentication error
    }

    // MARK: - Advanced Search Tests

    /// Test ADS advanced query syntax
    func testADSAdvancedQuery() throws {
        // Use ADS query syntax (author:"Einstein" year:1905)
        // Verify correct results
    }
}
