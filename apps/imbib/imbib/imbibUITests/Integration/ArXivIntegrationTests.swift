//
//  ArXivIntegrationTests.swift
//  imbibUITests
//
//  Integration tests for arXiv search functionality.
//
//  Note: These tests require network access and hit real APIs.
//  Run separately from unit tests using the IntegrationTests test plan.
//

import XCTest

/// Integration tests for arXiv search.
///
/// These tests verify real arXiv API integration.
/// They are slower and should be run separately from regular UI tests.
final class ArXivIntegrationTests: XCTestCase {

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

    /// Test searching arXiv returns results
    func testArXivSearchReturnsResults() throws {
        // Navigate to search sources
        sidebar.selectSearchSources()

        // Select arXiv source
        // (This depends on the UI for source selection)

        // Enter a search query
        let searchField = app.textFields.firstMatch
        if searchField.waitForExistence(timeout: 5) {
            searchField.click()
            searchField.typeText("quantum computing")
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
        XCTAssertGreaterThan(resultsList.cells.count, 0, "Should find arXiv results")
    }

    /// Test arXiv search with author
    func testArXivSearchByAuthor() throws {
        // Search by author name
        // Verify results are from that author
    }

    /// Test fetching BibTeX from arXiv
    func testFetchBibTeXFromArXiv() throws {
        // Search for a paper
        // Select it
        // Verify BibTeX is fetched and displayed correctly
    }

    /// Test arXiv ID lookup
    func testArXivIDLookup() throws {
        // Search for specific arXiv ID
        // Should find the exact paper
    }

    // MARK: - Error Handling Tests

    /// Test arXiv search with no network
    func testArXivSearchNoNetwork() throws {
        // This would require network mocking at the system level
        // Skip in real integration tests
    }

    /// Test arXiv search timeout handling
    func testArXivSearchTimeoutHandling() throws {
        // Verify the app handles slow responses gracefully
    }
}
