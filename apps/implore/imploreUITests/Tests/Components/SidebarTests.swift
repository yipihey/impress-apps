//
//  SidebarTests.swift
//  imploreUITests
//
//  Component tests for the sidebar.
//  Uses shared app instance for fast execution.
//

import XCTest
import ImpressTestKit

/// Component tests for the sidebar
final class SidebarTests: SharedAppTestCase {

    // MARK: - Class Setup (Run Once)

    override class func setUp() {
        super.setUp()
        launchApp { ImploreTestApp.launchWithSampleDataset() }
    }

    // MARK: - Page Objects

    var sidebarPage: SidebarPage {
        SidebarPage(app: app)
    }

    // MARK: - Basic Tests

    /// Test sidebar exists
    func testSidebarExists() {
        sidebarPage.assertSidebarExists()
    }

    /// Test edit selection button exists
    func testEditSelectionButtonExists() {
        sidebarPage.assertEditSelectionButtonExists()
    }

    // MARK: - Selection Tests

    /// Test clicking edit selection opens grammar sheet
    func testEditSelectionOpensSheet() {
        sidebarPage.clickEditSelection()

        let selectionPage = SelectionGrammarPage(app: app)
        XCTAssertTrue(
            selectionPage.waitForSheet(),
            "Selection grammar sheet should open"
        )

        selectionPage.cancel()
    }

    /// Test selection count is displayed
    func testSelectionCountDisplayed() {
        sidebarPage.assertSelectionCount("points")
    }
}
