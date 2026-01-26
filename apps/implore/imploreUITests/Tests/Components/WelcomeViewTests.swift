//
//  WelcomeViewTests.swift
//  imploreUITests
//
//  Component tests for the welcome view.
//  Uses shared app instance for fast execution.
//

import XCTest
import ImpressTestKit

/// Component tests for the welcome view
final class WelcomeViewTests: SharedAppTestCase {

    // MARK: - Class Setup (Run Once)

    override class func setUp() {
        super.setUp()
        launchApp { ImploreTestApp.launchWithWelcomeScreen() }
    }

    // MARK: - Page Objects

    var welcomePage: WelcomePage {
        WelcomePage(app: app)
    }

    // MARK: - Basic Tests

    /// Test welcome screen is visible
    func testWelcomeScreenVisible() {
        welcomePage.assertVisible()
    }

    /// Test open button exists
    func testOpenButtonExists() {
        welcomePage.assertOpenButtonExists()
    }

    /// Test supported formats are listed
    func testSupportedFormatsListed() {
        welcomePage.assertFormatsListed()
    }

    // MARK: - Format Tests

    /// Test HDF5 format is listed
    func testHDF5FormatListed() {
        let hdf5 = app.staticTexts["HDF5"]
        XCTAssertTrue(
            hdf5.exists,
            "HDF5 format should be listed"
        )
    }

    /// Test FITS format is listed
    func testFITSFormatListed() {
        let fits = app.staticTexts["FITS"]
        XCTAssertTrue(
            fits.exists,
            "FITS format should be listed"
        )
    }

    /// Test CSV format is listed
    func testCSVFormatListed() {
        let csv = app.staticTexts["CSV"]
        XCTAssertTrue(
            csv.exists,
            "CSV format should be listed"
        )
    }

    // MARK: - Interaction Tests

    /// Test clicking open button opens file dialog
    func testOpenButtonOpensFileDialog() {
        welcomePage.clickOpen()

        // File dialog should appear
        let fileDialog = app.sheets.firstMatch
        XCTAssertTrue(
            fileDialog.waitForExistence(timeout: 2),
            "File dialog should appear"
        )

        // Cancel the dialog
        app.typeKey(.escape, modifierFlags: [])
    }

    /// Test keyboard shortcut opens file dialog
    func testKeyboardShortcutOpensFileDialog() {
        welcomePage.openWithKeyboard()

        // File dialog should appear
        let fileDialog = app.sheets.firstMatch
        XCTAssertTrue(
            fileDialog.waitForExistence(timeout: 2),
            "File dialog should appear via keyboard"
        )

        // Cancel the dialog
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - Drag and Drop Tests

    /// Test drag and drop zone exists
    func testDragAndDropZone() {
        XCTAssertTrue(
            welcomePage.waitForWelcome(),
            "Welcome screen should be visible for drag and drop"
        )
    }
}
