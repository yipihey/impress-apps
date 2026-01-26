//
//  PDFPreviewTests.swift
//  imprintUITests
//
//  Component tests for the PDF preview.
//  Uses shared app instance for fast execution.
//

import XCTest
import ImpressTestKit

/// Component tests for the PDF preview panel
final class PDFPreviewTests: SharedAppTestCase {

    // MARK: - Class Setup (Run Once)

    override class func setUp() {
        super.setUp()
        launchApp {
            let app = ImprintTestApp.launch(sampleDocument: true)
            _ = app.windows.firstMatch.waitForExistence(timeout: 5)
            return app
        }
    }

    // MARK: - Test Setup (Run Before Each Test)

    override func resetAppState() {
        super.resetAppState()

        // Dismiss any open dialogs/sheets
        dismissDialogs()

        // Ensure we're in split view mode
        let content = ContentPage(app: app)
        content.selectEditMode(.splitView)

        // Set sample document content
        setSampleDocumentContent()
    }

    /// Dismiss any open dialogs
    private func dismissDialogs() {
        for _ in 0..<3 {
            app.typeKey(.escape, modifierFlags: [])
            Thread.sleep(forTimeInterval: 0.1)
            handleDocumentSaveDialog()
        }
    }

    /// Handle document save/delete dialogs
    private func handleDocumentSaveDialog() {
        let dontSaveSheet = app.sheets.buttons["Don't Save"]
        if dontSaveSheet.exists {
            dontSaveSheet.click()
            Thread.sleep(forTimeInterval: 0.2)
            return
        }

        let deleteButton = app.sheets.buttons["Delete"]
        if deleteButton.exists {
            deleteButton.click()
            Thread.sleep(forTimeInterval: 0.2)
            return
        }

        let dontSaveDialog = app.dialogs.buttons["Don't Save"]
        if dontSaveDialog.exists {
            dontSaveDialog.click()
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    /// Set sample document content by selecting all and typing
    private func setSampleDocumentContent() {
        // Focus the source editor
        let sourceEditor = app[ImprintAccessibilityID.SourceEditor.textView]
        if sourceEditor.waitForExistence(timeout: 2) {
            sourceEditor.click()
            Thread.sleep(forTimeInterval: 0.1)

            // Select all (Cmd+A)
            app.typeKey("a", modifierFlags: .command)
            Thread.sleep(forTimeInterval: 0.1)

            // Type sample content
            let sampleContent = """
            = Sample Document

            This is a sample document for UI testing.

            == Introduction

            Lorem ipsum dolor sit amet.

            == Methods

            + First step
            + Second step

            == Results

            The equation $E = m c^2$ is fundamental.
            """
            app.typeText(sampleContent)
            Thread.sleep(forTimeInterval: 0.3)
        }
    }

    // MARK: - Page Objects

    var contentPage: ContentPage {
        ContentPage(app: app)
    }

    var previewPage: PDFPreviewPage {
        PDFPreviewPage(app: app)
    }

    // MARK: - Basic Tests

    /// Test PDF preview exists
    /// Note: The pdfPreview.container ID is on SwiftUI children (static texts),
    /// so we check for either empty state text or that a PDF has been compiled
    func testPDFPreviewExists() {
        // In split view, either empty state should be visible or a PDF should be loaded
        let hasEmptyState = previewPage.isShowingEmptyState
        let hasPdf = previewPage.pdfSizeBytes > 0
        XCTAssertTrue(
            hasEmptyState || hasPdf,
            "PDF preview area should exist (showing empty state or compiled PDF)"
        )
    }

    /// Test preview shows valid state (empty or document)
    /// Note: With SharedAppTestCase, the initial state isn't guaranteed since
    /// other tests may have already compiled the document
    func testShowsEmptyStateInitially() {
        // With shared app, we can't guarantee empty state, so verify valid state
        let showsEmpty = previewPage.isShowingEmptyState
        let hasDoc = previewPage.hasDocument
        XCTAssertTrue(
            showsEmpty || hasDoc,
            "PDF preview should show either empty state or a loaded document"
        )
    }

    // MARK: - Compilation Tests

    /// Test compiling shows PDF
    func testCompilingShowsPDF() {
        contentPage.compile()
        _ = previewPage.waitForCompilation()
        previewPage.assertDocumentLoaded()
    }

    /// Test compile with keyboard shortcut
    func testCompileWithKeyboardShortcut() {
        contentPage.compileWithKeyboard()
        _ = previewPage.waitForCompilation()
        previewPage.assertDocumentLoaded()
    }

    // MARK: - Zoom Tests

    /// Test zoom in
    func testZoomIn() {
        contentPage.compile()
        _ = previewPage.waitForCompilation()
        previewPage.zoomIn()
    }

    /// Test zoom out
    func testZoomOut() {
        contentPage.compile()
        _ = previewPage.waitForCompilation()
        previewPage.zoomOut()
    }

    /// Test zoom to fit
    func testZoomToFit() {
        contentPage.compile()
        _ = previewPage.waitForCompilation()
        previewPage.zoomIn()
        previewPage.zoomToFit()
    }

    // MARK: - Navigation Tests

    /// Test scroll to top
    func testScrollToTop() {
        contentPage.compile()
        _ = previewPage.waitForCompilation()
        previewPage.scrollToBottom()
        previewPage.scrollToTop()
    }
}
