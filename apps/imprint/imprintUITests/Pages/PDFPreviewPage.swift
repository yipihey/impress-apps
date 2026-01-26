//
//  PDFPreviewPage.swift
//  imprintUITests
//
//  Page Object for the PDF preview panel.
//

import XCTest
import ImpressTestKit

/// Page Object for the PDF preview panel
struct PDFPreviewPage {

    // MARK: - Properties

    let app: XCUIApplication

    // MARK: - Elements

    /// PDF preview container
    var container: XCUIElement {
        app[ImprintAccessibilityID.PDFPreview.container]
    }

    /// The PDF document view
    var document: XCUIElement {
        app[ImprintAccessibilityID.PDFPreview.document]
    }

    /// Empty state view (shown when no PDF is compiled)
    var emptyState: XCUIElement {
        app.staticTexts["No Preview"].firstMatch
    }

    /// Compiling overlay
    var compilingOverlay: XCUIElement {
        app.staticTexts["Compiling..."].firstMatch
    }

    /// Debug label showing PDF size (only in DEBUG builds)
    var debugPdfSize: XCUIElement {
        app.staticTexts["debug.pdfSize"].firstMatch
    }

    // MARK: - State Checks

    /// Check if PDF preview has a document loaded
    var hasDocument: Bool {
        !isShowingEmptyState && !isCompiling
    }

    /// Check if showing empty state
    var isShowingEmptyState: Bool {
        emptyState.exists
    }

    /// Check if compilation is in progress
    var isCompiling: Bool {
        compilingOverlay.exists
    }

    /// Get PDF size from debug label (returns 0 if not found or not compiled)
    var pdfSizeBytes: Int {
        guard debugPdfSize.exists,
              let value = debugPdfSize.value as? String else {
            return 0
        }
        // Parse "pdf=X,XXXb" format
        let cleaned = value
            .replacingOccurrences(of: "pdf=", with: "")
            .replacingOccurrences(of: "b", with: "")
            .replacingOccurrences(of: ",", with: "")
        return Int(cleaned) ?? 0
    }

    // MARK: - Actions

    /// Wait for compilation to complete
    @discardableResult
    func waitForCompilation(timeout: TimeInterval = 30) -> Bool {
        Thread.sleep(forTimeInterval: 0.5)

        let startTime = Date()
        while Date().timeIntervalSince(startTime) < timeout {
            // Check if compilation succeeded
            if !isShowingEmptyState && !isCompiling && pdfSizeBytes > 0 {
                return true
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    /// Zoom in on the PDF
    func zoomIn() {
        app.typeKey("+", modifierFlags: .command)
    }

    /// Zoom out on the PDF
    func zoomOut() {
        app.typeKey("-", modifierFlags: .command)
    }

    /// Reset zoom to fit
    func zoomToFit() {
        app.typeKey("0", modifierFlags: .command)
    }

    /// Scroll to top of document
    func scrollToTop() {
        app.typeKey(.home, modifierFlags: [])
    }

    /// Scroll to bottom of document
    func scrollToBottom() {
        app.typeKey(.end, modifierFlags: [])
    }

    // MARK: - Assertions

    /// Wait for preview to be ready
    @discardableResult
    func waitForPreview(timeout: TimeInterval = 5) -> Bool {
        container.waitForExistence(timeout: timeout)
    }

    /// Assert PDF preview exists
    func assertPreviewExists(file: StaticString = #file, line: UInt = #line) {
        XCTAssertTrue(
            container.exists,
            "PDF preview should exist",
            file: file,
            line: line
        )
    }

    /// Assert document is loaded
    func assertDocumentLoaded(file: StaticString = #file, line: UInt = #line) {
        XCTAssertFalse(
            isShowingEmptyState,
            "PDF preview should not show empty state after compilation",
            file: file,
            line: line
        )
        XCTAssertFalse(
            isCompiling,
            "PDF preview should not be compiling",
            file: file,
            line: line
        )
        XCTAssertGreaterThan(
            pdfSizeBytes,
            0,
            "PDF should have been generated (pdfSizeBytes > 0)",
            file: file,
            line: line
        )
    }

    /// Assert empty state is shown
    func assertEmptyState(file: StaticString = #file, line: UInt = #line) {
        XCTAssertTrue(
            isShowingEmptyState,
            "PDF preview should show empty state",
            file: file,
            line: line
        )
    }

    /// Assert not compiling
    func assertNotCompiling(file: StaticString = #file, line: UInt = #line) {
        XCTAssertFalse(
            isCompiling,
            "PDF preview should not be compiling",
            file: file,
            line: line
        )
    }
}
