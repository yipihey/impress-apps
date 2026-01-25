//
//  SearchWorkflowTests.swift
//  imbibUITests
//
//  End-to-end tests for search workflows.
//

import XCTest

/// Tests for search functionality including global search and source searches.
final class SearchWorkflowTests: XCTestCase {

    var app: XCUIApplication!
    var sidebar: SidebarPage!
    var list: PublicationListPage!
    var searchPalette: SearchPalettePage!

    // MARK: - Setup

    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        // Launch with basic test data
        app = TestApp.launch(with: .basic)
        sidebar = SidebarPage(app: app)
        list = PublicationListPage(app: app)
        searchPalette = SearchPalettePage(app: app)

        _ = sidebar.waitForSidebar()
    }

    // MARK: - Global Search (Cmd+F) Tests

    /// Test opening global search with Cmd+F
    func testGlobalSearchOpensWithCmdF() throws {
        // When: I press Cmd+F
        searchPalette.open()

        // Then: The search palette should appear
        XCTAssertTrue(searchPalette.waitForPalette(), "Search palette should appear")
        searchPalette.assertVisible()
    }

    /// Test closing global search with Escape
    func testGlobalSearchClosesWithEscape() throws {
        // Given: The search palette is open
        searchPalette.open()
        _ = searchPalette.waitForPalette()

        // When: I press Escape
        searchPalette.close()

        // Then: The palette should close
        XCTAssertTrue(searchPalette.waitForDismissal(), "Search palette should close")
        searchPalette.assertNotVisible()
    }

    /// Test searching for publications in the library
    func testGlobalSearchFindsLocalPublications() throws {
        // Given: The search palette is open
        searchPalette.open()
        _ = searchPalette.waitForPalette()

        // When: I search for a known publication
        searchPalette.search("Einstein")

        // Then: Results should appear
        XCTAssertTrue(searchPalette.waitForResults(timeout: 5), "Should find results")
        searchPalette.assertHasResults()
    }

    /// Test navigating search results with arrow keys
    func testNavigateSearchResultsWithArrows() throws {
        // Given: Search results are displayed
        searchPalette.open()
        _ = searchPalette.waitForPalette()
        searchPalette.search("Test")
        _ = searchPalette.waitForResults()

        // When: I press down arrow
        searchPalette.navigateToNextResult()

        // Then: The next result should be highlighted
        // (verification would need accessibility state checking)
    }

    /// Test selecting a search result with Enter
    func testSelectSearchResultWithEnter() throws {
        // Given: Search results are displayed
        searchPalette.open()
        _ = searchPalette.waitForPalette()
        searchPalette.search("Einstein")
        _ = searchPalette.waitForResults()

        // When: I press Enter
        searchPalette.selectHighlightedResult()

        // Then: The palette should close and the publication should be selected
        XCTAssertTrue(searchPalette.waitForDismissal(), "Palette should close after selection")

        // The detail view should show the selected publication
        let detail = DetailViewPage(app: app)
        detail.assertPublicationDisplayed(titled: "On the Electrodynamics of Moving Bodies")
    }

    /// Test clicking on a search result
    func testClickSearchResult() throws {
        // Given: Search results are displayed
        searchPalette.open()
        _ = searchPalette.waitForPalette()
        searchPalette.search("Hawking")
        _ = searchPalette.waitForResults()

        // When: I click on a result
        searchPalette.selectFirstResult()

        // Then: The palette should close and the publication should be selected
        XCTAssertTrue(searchPalette.waitForDismissal(), "Palette should close")
    }

    // MARK: - Local Filter Search Tests

    /// Test filtering the publication list with Cmd+F
    func testLocalFilterSearch() throws {
        // Given: Publications are displayed
        sidebar.selectAllPublications()
        _ = list.waitForPublications()

        let initialCount = list.rows.count

        // When: I filter with Cmd+F and type
        list.search("1905")

        // Then: The list should be filtered
        let filteredCount = list.rows.count
        XCTAssertLessThan(filteredCount, initialCount, "List should be filtered")
    }

    /// Test clearing the filter
    func testClearFilterSearch() throws {
        // Given: A filter is active
        sidebar.selectAllPublications()
        _ = list.waitForPublications()
        let initialCount = list.rows.count

        list.search("Einstein")
        let filteredCount = list.rows.count
        XCTAssertLessThan(filteredCount, initialCount, "Filter should reduce count")

        // When: I clear the filter
        list.clearSearch()

        // Then: All publications should be visible again
        list.assertPublicationCount(initialCount)
    }

    // MARK: - Source Search Tests

    /// Test navigating to search sources
    func testNavigateToSearchSources() throws {
        // When: I click on Search Sources in sidebar
        sidebar.selectSearchSources()

        // Then: The search sources view should appear
        // (this would show source selection UI)
    }

    /// Test searching via ADS (mock)
    func testADSSearch() throws {
        // Given: I'm in the search sources view
        sidebar.selectSearchSources()

        // When: I search ADS for a term
        // (this depends on the UI for source selection)

        // Then: Results should appear from ADS
    }

    // MARK: - Search History Tests

    /// Test that recent searches are remembered
    func testSearchHistoryRemembered() throws {
        // Given: I performed a search
        searchPalette.open()
        _ = searchPalette.waitForPalette()
        searchPalette.search("quantum physics")
        searchPalette.close()

        // When: I open search again
        searchPalette.open()
        _ = searchPalette.waitForPalette()

        // Then: Recent searches might be shown
        // (depends on implementation)
    }

    // MARK: - Fulltext Search Tests

    /// Test fulltext search finds content in PDFs
    func testFulltextSearch() throws {
        // This test would require PDFs with searchable text
        // Given: Publications with indexed PDFs

        // When: I search for text that only appears in PDFs

        // Then: Those publications should be found
    }

    // MARK: - Semantic Search Tests

    /// Test semantic/similar search
    func testSemanticSearch() throws {
        // This tests the AI-powered semantic search
        // Given: Publications exist

        // When: I search for conceptually related terms

        // Then: Semantically similar publications should be found
    }

    // MARK: - Empty State Tests

    /// Test search with no results
    func testSearchNoResults() throws {
        // Given: Search palette is open
        searchPalette.open()
        _ = searchPalette.waitForPalette()

        // When: I search for something that doesn't exist
        searchPalette.search("xyznonexistent12345")

        // Then: No results message should be shown
        // Wait a bit for search to complete
        Thread.sleep(forTimeInterval: 1)

        searchPalette.assertResultCount(0)
    }

    /// Test search with empty query
    func testSearchEmptyQuery() throws {
        // Given: Search palette is open
        searchPalette.open()
        _ = searchPalette.waitForPalette()

        // When: The query is empty

        // Then: Recent items or suggestions might be shown
        // (depends on implementation)
    }
}
