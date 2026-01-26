//
//  ToolbarTests.swift
//  imprintUITests
//
//  Tests for the main toolbar functionality.
//  Uses shared app instance for fast execution.
//

import XCTest
import ImpressTestKit

/// Tests for the main toolbar - includes edit mode tests
final class ToolbarTests: SharedAppTestCase {

    // MARK: - Class Setup (Run Once)

    override class func setUp() {
        super.setUp()
        launchApp {
            let app = ImprintTestApp.launch(sampleDocument: true)
            // Wait for the document window to be ready
            _ = app.windows.firstMatch.waitForExistence(timeout: 5)
            return app
        }
    }

    // MARK: - Page Objects

    var contentPage: ContentPage {
        ContentPage(app: app)
    }

    // MARK: - Toolbar Element Tests

    /// Test compile button exists
    func testCompileButtonExists() {
        contentPage.assertCompileButtonExists()
    }

    /// Test citation button exists
    func testCitationButtonExists() {
        contentPage.assertCitationButtonExists()
    }

    /// Test edit mode picker exists
    func testEditModePickerExists() {
        contentPage.assertEditModePickerExists()
    }

    // MARK: - Compile Button Tests

    /// Test compile button triggers compilation
    func testCompileButtonTriggersCompilation() {
        contentPage.selectEditMode(.splitView)
        contentPage.compile()

        let preview = PDFPreviewPage(app: app)
        XCTAssertTrue(
            preview.waitForCompilation(timeout: 30),
            "Compilation should complete"
        )
        preview.assertDocumentLoaded()
    }

    /// Test compile keyboard shortcut works
    func testCompileKeyboardShortcut() {
        contentPage.selectEditMode(.splitView)
        contentPage.compileWithKeyboard()

        let preview = PDFPreviewPage(app: app)
        XCTAssertTrue(
            preview.waitForCompilation(timeout: 30),
            "Compilation should complete via keyboard"
        )
        preview.assertDocumentLoaded()
    }

    // MARK: - Citation Button Tests

    /// Test citation button opens picker
    func testCitationButtonOpensPicker() {
        // Ensure document window is focused
        app.windows.firstMatch.click()

        XCTAssertTrue(
            contentPage.openCitationPickerAndWait(),
            "Citation picker should open"
        )

        let picker = CitationPickerPage(app: app)
        picker.cancel()
        _ = picker.waitForClose()
    }

    /// Test citation keyboard shortcut works
    func testCitationKeyboardShortcut() {
        // Ensure document window is focused
        app.windows.firstMatch.click()

        contentPage.openCitationPickerWithKeyboard()

        let picker = CitationPickerPage(app: app)
        XCTAssertTrue(
            picker.waitForPicker(),
            "Citation picker should open via keyboard"
        )

        picker.cancel()
        _ = picker.waitForClose()
    }

    // MARK: - Edit Mode Tests

    /// Test switching to Direct PDF mode
    func testSwitchToDirectPDFMode() {
        contentPage.selectEditMode(.directPdf)
        let directPdfContainer = app[ImprintAccessibilityID.DirectPDF.container]
        _ = directPdfContainer.waitForExistence(timeout: 2)
    }

    /// Test switching to Split View mode
    func testSwitchToSplitViewMode() {
        contentPage.selectEditMode(.splitView)
        let editor = app[ImprintAccessibilityID.SourceEditor.container]
        let preview = app[ImprintAccessibilityID.PDFPreview.container]
        _ = editor.waitForExistence(timeout: 2)
        _ = preview.waitForExistence(timeout: 2)
    }

    /// Test switching to Text Only mode
    func testSwitchToTextOnlyMode() {
        contentPage.selectEditMode(.textOnly)
        let editor = app[ImprintAccessibilityID.SourceEditor.container]
        _ = editor.waitForExistence(timeout: 2)
    }

    /// Test cycling through modes with Tab key
    func testCycleModeWithTab() {
        contentPage.selectEditMode(.directPdf)
        contentPage.cycleEditMode()
        contentPage.cycleEditMode()
        contentPage.cycleEditMode()
    }

    // MARK: - Share Button Tests

    /// Test share button exists
    func testShareButtonExists() {
        XCTAssertTrue(
            contentPage.shareButton.exists,
            "Share button should exist"
        )
    }
}
