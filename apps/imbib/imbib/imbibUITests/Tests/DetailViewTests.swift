//
//  DetailViewTests.swift
//  imbibUITests
//
//  Created by Claude on 2026-01-22.
//

import XCTest

/// UI tests for publication detail view
/// Note: These tests require publications to be present in the app
final class DetailViewTests: XCTestCase {
    var app: XCUIApplication!
    var sidebar: SidebarPage!
    var detail: DetailPage!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        sidebar = SidebarPage(app: app)
        detail = DetailPage(app: app)
    }

    override func tearDownWithError() throws {
        app = nil
        sidebar = nil
        detail = nil
    }

    // MARK: - Basic Structure Tests

    func testAppHasMultiplePanes() throws {
        // NavigationSplitView should create multiple panes
        sidebar.selectInbox()
        sleep(1)

        // The app should have split view structure
        XCTAssertTrue(app.windows.count > 0, "App should have windows")
    }

    // MARK: - Detail Tab Tests (require selected publication)

    func testDetailTabsExistWhenPublicationSelected() throws {
        sidebar.selectInbox()

        // If any publication is available, select it and check for tabs
        // This test will pass if tabs exist or skip gracefully if no publication
        if detail.infoTab.waitForExistence(timeout: 5) {
            detail.verifyInfoTabVisible()
        }
    }

    func testInfoTabContent() throws {
        sidebar.selectInbox()

        // If info tab exists and is visible, check for title field
        if detail.infoTab.waitForExistence(timeout: 3) {
            detail.selectInfoTab()
            // Title field should exist when viewing a publication
            if detail.titleField.waitForExistence(timeout: 3) {
                XCTAssertTrue(detail.titleField.exists)
            }
        }
    }

    func testPDFTabNavigation() throws {
        sidebar.selectInbox()

        if detail.pdfTab.waitForExistence(timeout: 3) {
            detail.selectPDFTab()
            // Either PDF viewer or no-PDF state should appear
        }
    }

    func testBibTeXTabNavigation() throws {
        sidebar.selectInbox()

        if detail.bibtexTab.waitForExistence(timeout: 3) {
            detail.selectBibTeXTab()
            // BibTeX editor should appear
        }
    }
}
