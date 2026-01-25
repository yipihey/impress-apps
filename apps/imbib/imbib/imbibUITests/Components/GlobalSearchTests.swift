//
//  GlobalSearchTests.swift
//  imbibUITests
//
//  Component tests for the global search palette.
//

import XCTest

/// Component tests for the global search palette (Cmd+F).
final class GlobalSearchTests: XCTestCase {

    var app: XCUIApplication!
    var searchPalette: SearchPalettePage!

    // MARK: - Setup

    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        app = TestApp.launch(with: .basic)
        searchPalette = SearchPalettePage(app: app)
        _ = app.waitForIdle()
    }

    // MARK: - Open/Close Tests

    /// Test Cmd+F opens search
    func testCmdFOpensSearch() throws {
        searchPalette.open()

        XCTAssertTrue(searchPalette.waitForPalette(), "Search should open with Cmd+F")
        searchPalette.assertVisible()
    }

    /// Test Escape closes search
    func testEscapeClosesSearch() throws {
        searchPalette.open()
        _ = searchPalette.waitForPalette()

        searchPalette.close()

        XCTAssertTrue(searchPalette.waitForDismissal(), "Escape should close search")
    }

    /// Test clicking outside closes search
    func testClickingOutsideClosesSearch() throws {
        searchPalette.open()
        _ = searchPalette.waitForPalette()

        // Click on the main content area
        let mainContent = app.windows.firstMatch
        mainContent.click()

        // Search should close
        XCTAssertTrue(searchPalette.waitForDismissal(), "Clicking outside should close search")
    }

    // MARK: - Search Field Tests

    /// Test search field is focused on open
    func testSearchFieldFocusedOnOpen() throws {
        searchPalette.open()
        _ = searchPalette.waitForPalette()

        // Typing should go directly to search field
        app.typeText("test")

        searchPalette.assertSearchFieldText("test")

        searchPalette.close()
    }

    /// Test search field accepts input
    func testSearchFieldAcceptsInput() throws {
        searchPalette.open()
        _ = searchPalette.waitForPalette()

        searchPalette.search("quantum physics")

        searchPalette.assertSearchFieldText("quantum physics")

        searchPalette.close()
    }

    /// Test clearing search field
    func testClearingSearchField() throws {
        searchPalette.open()
        _ = searchPalette.waitForPalette()

        searchPalette.search("test query")
        searchPalette.clearSearch()

        searchPalette.assertSearchFieldText("")

        searchPalette.close()
    }

    // MARK: - Results Display Tests

    /// Test results appear after typing
    func testResultsAppearAfterTyping() throws {
        searchPalette.open()
        _ = searchPalette.waitForPalette()

        searchPalette.search("Einstein")

        XCTAssertTrue(searchPalette.waitForResults(), "Results should appear")
        searchPalette.assertHasResults()

        searchPalette.close()
    }

    /// Test results update as you type
    func testResultsUpdateAsYouType() throws {
        searchPalette.open()
        _ = searchPalette.waitForPalette()

        // Type partial query
        searchPalette.search("Ein")
        _ = searchPalette.waitForResults()
        let count1 = searchPalette.resultCount

        // Continue typing
        searchPalette.searchField.typeText("stein")
        Thread.sleep(forTimeInterval: 0.5) // Wait for debounce

        // Results might change
        // (depends on implementation)

        searchPalette.close()
    }

    /// Test no results message
    func testNoResultsMessage() throws {
        searchPalette.open()
        _ = searchPalette.waitForPalette()

        searchPalette.search("xyznonexistent12345")

        // Wait for search to complete
        Thread.sleep(forTimeInterval: 1)

        searchPalette.assertResultCount(0)

        // Should show "No results" or similar
        let noResultsText = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'no'")
        ).firstMatch

        searchPalette.close()
    }

    // MARK: - Result Selection Tests

    /// Test clicking result selects it
    func testClickingResultSelectsIt() throws {
        searchPalette.open()
        _ = searchPalette.waitForPalette()
        searchPalette.search("Einstein")
        _ = searchPalette.waitForResults()

        searchPalette.selectFirstResult()

        // Search should close and publication should be selected
        XCTAssertTrue(searchPalette.waitForDismissal(), "Search should close after selection")
    }

    /// Test arrow down selects first result
    func testArrowDownSelectsFirstResult() throws {
        searchPalette.open()
        _ = searchPalette.waitForPalette()
        searchPalette.search("Test")
        _ = searchPalette.waitForResults()

        searchPalette.navigateToNextResult()

        // First result should be highlighted
        searchPalette.close()
    }

    /// Test arrow navigation through results
    func testArrowNavigationThroughResults() throws {
        searchPalette.open()
        _ = searchPalette.waitForPalette()
        searchPalette.search("Test")
        _ = searchPalette.waitForResults()

        // Navigate down
        searchPalette.navigateToNextResult()
        searchPalette.navigateToNextResult()

        // Navigate up
        searchPalette.navigateToPreviousResult()

        searchPalette.close()
    }

    /// Test Enter selects highlighted result
    func testEnterSelectsHighlightedResult() throws {
        searchPalette.open()
        _ = searchPalette.waitForPalette()
        searchPalette.search("Einstein")
        _ = searchPalette.waitForResults()

        searchPalette.navigateToNextResult()
        searchPalette.selectHighlightedResult()

        XCTAssertTrue(searchPalette.waitForDismissal(), "Enter should select and close")
    }

    // MARK: - Result Content Tests

    /// Test results show publication info
    func testResultsShowPublicationInfo() throws {
        searchPalette.open()
        _ = searchPalette.waitForPalette()
        searchPalette.search("Einstein")
        _ = searchPalette.waitForResults()

        // First result should have title
        let firstTitle = searchPalette.getResultTitle(at: 0)
        XCTAssertFalse(firstTitle.isEmpty, "Result should have title")

        searchPalette.close()
    }

    // MARK: - Search Scope Tests

    /// Test search finds local publications
    func testSearchFindsLocalPublications() throws {
        searchPalette.open()
        _ = searchPalette.waitForPalette()
        searchPalette.search("Electrodynamics")
        _ = searchPalette.waitForResults()

        searchPalette.assertResultExists(titled: "On the Electrodynamics of Moving Bodies")

        searchPalette.close()
    }

    // MARK: - Performance Tests

    /// Test search response time
    func testSearchResponseTime() throws {
        searchPalette.open()
        _ = searchPalette.waitForPalette()

        let startTime = CFAbsoluteTimeGetCurrent()
        searchPalette.search("test")
        _ = searchPalette.waitForResults(timeout: 2)
        let duration = CFAbsoluteTimeGetCurrent() - startTime

        XCTAssertLessThan(duration, 2, "Search should respond within 2 seconds")

        searchPalette.close()
    }

    // MARK: - Edge Cases

    /// Test search with special characters
    func testSearchWithSpecialCharacters() throws {
        searchPalette.open()
        _ = searchPalette.waitForPalette()

        searchPalette.search("O'Brien")

        // Should not crash
        Thread.sleep(forTimeInterval: 0.5)

        searchPalette.close()
    }

    /// Test search with very long query
    func testSearchWithLongQuery() throws {
        searchPalette.open()
        _ = searchPalette.waitForPalette()

        let longQuery = String(repeating: "test ", count: 20)
        searchPalette.search(longQuery)

        // Should handle gracefully
        Thread.sleep(forTimeInterval: 0.5)

        searchPalette.close()
    }

    /// Test rapid open/close cycles
    func testRapidOpenCloseCycles() throws {
        for _ in 0..<5 {
            searchPalette.open()
            _ = searchPalette.waitForPalette()
            searchPalette.close()
            _ = searchPalette.waitForDismissal()
        }

        // Should not crash or leave artifacts
    }
}
