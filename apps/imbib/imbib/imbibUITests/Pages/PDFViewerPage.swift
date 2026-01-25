//
//  PDFViewerPage.swift
//  imbibUITests
//
//  Page Object for the PDF viewer.
//

import XCTest

/// Page Object for the PDF viewer.
///
/// Provides access to PDF viewing and annotation elements.
struct PDFViewerPage {

    // MARK: - Properties

    let app: XCUIApplication

    // MARK: - Container Elements

    /// The PDF viewer container
    var container: XCUIElement {
        app.groups[AccessibilityID.PDFViewer.container].firstMatch
    }

    /// The PDF document view
    var documentView: XCUIElement {
        // PDFView is typically represented as a scroll view
        app.scrollViews.firstMatch
    }

    /// The page indicator (e.g., "Page 1 of 10")
    var pageIndicator: XCUIElement {
        app.staticTexts[AccessibilityID.PDFViewer.pageIndicator]
    }

    /// The zoom slider
    var zoomSlider: XCUIElement {
        app.sliders[AccessibilityID.PDFViewer.zoomSlider]
    }

    /// The search field in the PDF viewer
    var searchField: XCUIElement {
        app.searchFields[AccessibilityID.PDFViewer.searchField]
    }

    // MARK: - Annotation Toolbar

    /// Highlight tool button
    var highlightButton: XCUIElement {
        app.buttons[AccessibilityID.PDFViewer.Annotation.highlight]
    }

    /// Underline tool button
    var underlineButton: XCUIElement {
        app.buttons[AccessibilityID.PDFViewer.Annotation.underline]
    }

    /// Strikethrough tool button
    var strikethroughButton: XCUIElement {
        app.buttons[AccessibilityID.PDFViewer.Annotation.strikethrough]
    }

    /// Note tool button
    var noteButton: XCUIElement {
        app.buttons[AccessibilityID.PDFViewer.Annotation.note]
    }

    /// Color picker for annotations
    var colorPicker: XCUIElement {
        app.colorWells[AccessibilityID.PDFViewer.Annotation.colorPicker]
    }

    // MARK: - Visibility

    /// Check if the PDF viewer is visible
    var isVisible: Bool {
        documentView.exists
    }

    // MARK: - Wait Methods

    /// Wait for the PDF viewer to be visible
    @discardableResult
    func waitForViewer(timeout: TimeInterval = 5) -> Bool {
        documentView.waitForExistence(timeout: timeout)
    }

    /// Wait for a PDF document to load
    @discardableResult
    func waitForDocument(timeout: TimeInterval = 10) -> Bool {
        // A loaded PDF typically has scrollable content
        let predicate = NSPredicate(format: "isHittable == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: documentView)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    // MARK: - Navigation

    /// Go to the next page
    func nextPage() {
        app.typeKey(.pageDown, modifierFlags: [])
    }

    /// Go to the previous page
    func previousPage() {
        app.typeKey(.pageUp, modifierFlags: [])
    }

    /// Go to a specific page
    func goToPage(_ pageNumber: Int) {
        app.typeKey("g", modifierFlags: .command)

        // Type the page number in the dialog
        let dialog = app.sheets.firstMatch
        if dialog.waitForExistence(timeout: 2) {
            let textField = dialog.textFields.firstMatch
            textField.click()
            textField.typeText("\(pageNumber)")
            textField.typeKey(.return, modifierFlags: [])
        }
    }

    /// Go to the first page
    func goToFirstPage() {
        app.typeKey(.home, modifierFlags: .command)
    }

    /// Go to the last page
    func goToLastPage() {
        app.typeKey(.end, modifierFlags: .command)
    }

    // MARK: - Zoom

    /// Zoom in
    func zoomIn() {
        app.typeKey("=", modifierFlags: .command)
    }

    /// Zoom out
    func zoomOut() {
        app.typeKey("-", modifierFlags: .command)
    }

    /// Fit to width
    func fitToWidth() {
        app.typeKey("0", modifierFlags: [.command, .option])
    }

    /// Fit to page
    func fitToPage() {
        app.typeKey("0", modifierFlags: .command)
    }

    // MARK: - Search

    /// Focus the PDF search field
    func focusSearch() {
        app.typeKey("f", modifierFlags: .command)
    }

    /// Search for text in the PDF
    func searchPDF(_ query: String) {
        focusSearch()
        if searchField.waitForExistence(timeout: 2) {
            searchField.typeText(query)
            searchField.typeKey(.return, modifierFlags: [])
        }
    }

    /// Find next occurrence
    func findNext() {
        app.typeKey("g", modifierFlags: .command)
    }

    /// Find previous occurrence
    func findPrevious() {
        app.typeKey("g", modifierFlags: [.command, .shift])
    }

    // MARK: - Annotation Actions

    /// Select the highlight tool
    func selectHighlightTool() {
        if highlightButton.exists {
            highlightButton.click()
        } else {
            // Use keyboard shortcut
            app.typeKey("h", modifierFlags: .control)
        }
    }

    /// Select the underline tool
    func selectUnderlineTool() {
        if underlineButton.exists {
            underlineButton.click()
        } else {
            app.typeKey("u", modifierFlags: .control)
        }
    }

    /// Select the strikethrough tool
    func selectStrikethroughTool() {
        if strikethroughButton.exists {
            strikethroughButton.click()
        } else {
            app.typeKey("t", modifierFlags: .control)
        }
    }

    /// Select the note tool
    func selectNoteTool() {
        if noteButton.exists {
            noteButton.click()
        } else {
            app.typeKey("n", modifierFlags: .control)
        }
    }

    /// Highlight the current selection
    func highlightSelection() {
        app.typeKey("h", modifierFlags: .control)
    }

    /// Underline the current selection
    func underlineSelection() {
        app.typeKey("u", modifierFlags: .control)
    }

    /// Add a note at the current selection
    func addNoteAtSelection() {
        app.typeKey("n", modifierFlags: .control)
    }

    // MARK: - Text Selection

    /// Select text by clicking and dragging
    /// Note: This is a simplified version - actual text selection may be more complex
    func selectText(from start: CGPoint, to end: CGPoint) {
        let startCoordinate = documentView.coordinate(withNormalizedOffset: CGVector(dx: start.x, dy: start.y))
        let endCoordinate = documentView.coordinate(withNormalizedOffset: CGVector(dx: end.x, dy: end.y))
        startCoordinate.press(forDuration: 0.1, thenDragTo: endCoordinate)
    }

    /// Select all text on the current page
    func selectAll() {
        app.typeKey("a", modifierFlags: .command)
    }

    /// Copy selected text
    func copySelection() {
        app.typeKey("c", modifierFlags: .command)
    }

    // MARK: - Assertions

    /// Assert the PDF viewer is visible
    func assertVisible(file: StaticString = #file, line: UInt = #line) {
        XCTAssertTrue(
            isVisible,
            "PDF viewer should be visible",
            file: file,
            line: line
        )
    }

    /// Assert a document is loaded
    func assertDocumentLoaded(file: StaticString = #file, line: UInt = #line) {
        XCTAssertTrue(
            documentView.isHittable,
            "PDF document should be loaded",
            file: file,
            line: line
        )
    }

    /// Assert the current page number
    func assertCurrentPage(_ page: Int, file: StaticString = #file, line: UInt = #line) {
        let pageText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Page \(page)'")).firstMatch
        XCTAssertTrue(
            pageText.exists,
            "Should be on page \(page)",
            file: file,
            line: line
        )
    }

    /// Assert annotation tools are visible
    func assertAnnotationToolsVisible(file: StaticString = #file, line: UInt = #line) {
        XCTAssertTrue(
            highlightButton.exists || underlineButton.exists,
            "Annotation tools should be visible",
            file: file,
            line: line
        )
    }
}

// MARK: - Annotation Flow Helpers

extension PDFViewerPage {

    /// Highlight text with a specific color.
    ///
    /// - Parameters:
    ///   - text: Text to search and highlight
    ///   - color: Color name (yellow, green, blue, pink, purple)
    func highlightText(_ text: String, color: String = "yellow") {
        // Search for the text first to ensure it's visible
        searchPDF(text)

        // Select the text (simplified - in practice would need actual coordinates)
        selectAll()

        // Apply highlight with color
        let colorInfo = ["color": color]
        NotificationCenter.default.post(
            name: Notification.Name("highlightSelection"),
            object: nil,
            userInfo: colorInfo
        )
    }
}
