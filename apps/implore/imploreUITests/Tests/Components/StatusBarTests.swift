//
//  StatusBarTests.swift
//  imploreUITests
//
//  Component tests for the status bar.
//  Uses shared app instance for fast execution.
//

import XCTest
import ImpressTestKit

/// Component tests for the status bar
final class StatusBarTests: SharedAppTestCase {

    // MARK: - Class Setup (Run Once)

    override class func setUp() {
        super.setUp()
        launchApp { ImploreTestApp.launchWithSampleDataset() }
    }

    // MARK: - Page Objects

    var vizPage: VisualizationPage {
        VisualizationPage(app: app)
    }

    // MARK: - Basic Tests

    /// Test status bar exists
    func testStatusBarExists() {
        XCTAssertTrue(
            vizPage.statusBar.waitForExistence(timeout: 5),
            "Status bar should exist"
        )
    }

    /// Test status bar shows point count
    func testStatusBarShowsPointCount() {
        vizPage.assertPointsVisible()
    }

    /// Test status bar shows mode
    func testStatusBarShowsMode() {
        let status = vizPage.statusText
        XCTAssertTrue(
            status.contains("Mode"),
            "Status bar should show current mode"
        )
    }

    /// Test status bar shows selection info
    func testStatusBarShowsSelection() {
        let status = vizPage.statusText
        XCTAssertTrue(
            status.contains("Selection") || status.contains("selection"),
            "Status bar should show selection info"
        )
    }
}
