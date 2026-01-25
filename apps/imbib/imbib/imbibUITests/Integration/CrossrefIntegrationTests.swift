//
//  CrossrefIntegrationTests.swift
//  imbibUITests
//
//  Integration tests for Crossref search functionality.
//
//  Note: These tests require network access and hit real APIs.
//  Run separately using the IntegrationTests test plan.
//

import XCTest

/// Integration tests for Crossref search.
///
/// These tests verify real Crossref API integration.
final class CrossrefIntegrationTests: XCTestCase {

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

    /// Test Crossref search returns results
    func testCrossrefSearchReturnsResults() throws {
        // Navigate to search sources
        sidebar.selectSearchSources()

        // Select Crossref source
        // (This depends on the UI for source selection)

        // Enter a search query
        let searchField = app.textFields.firstMatch
        if searchField.waitForExistence(timeout: 5) {
            searchField.click()
            searchField.typeText("machine learning")
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
        XCTAssertGreaterThan(resultsList.cells.count, 0, "Should find Crossref results")
    }

    /// Test Crossref DOI lookup
    func testCrossrefDOILookup() throws {
        // Search for specific DOI
        // Should find the exact paper
    }

    /// Test fetching BibTeX from Crossref
    func testFetchBibTeXFromCrossref() throws {
        // Search for a paper
        // Select it
        // Verify BibTeX is fetched correctly
    }

    // MARK: - Metadata Tests

    /// Test Crossref returns complete metadata
    func testCrossrefMetadataComplete() throws {
        // Search for a well-known paper
        // Verify title, authors, year, journal, DOI are present
    }

    /// Test Crossref handles missing fields gracefully
    func testCrossrefMissingFieldsHandled() throws {
        // Some Crossref records have incomplete metadata
        // App should handle this gracefully
    }

    // MARK: - Rate Limiting Tests

    /// Test Crossref rate limiting handling
    func testCrossrefRateLimiting() throws {
        // Make many rapid requests
        // Verify app handles rate limiting gracefully
    }
}
