//
//  DetailViewPage.swift
//  imbibUITests
//
//  Page Object for the detail view panel.
//

import XCTest

/// Page Object for the detail view panel.
///
/// Provides access to publication detail elements and tab navigation.
struct DetailViewPage {

    // MARK: - Properties

    let app: XCUIApplication

    // MARK: - Container Elements

    /// The detail view container
    var container: XCUIElement {
        app.groups[AccessibilityID.Detail.container].firstMatch
    }

    /// The empty state shown when no publication is selected
    var emptyState: XCUIElement {
        app.staticTexts["Select a publication"]
    }

    // MARK: - Tab Elements

    /// PDF tab button
    var pdfTab: XCUIElement {
        app.buttons[AccessibilityID.Detail.Tab.pdf]
    }

    /// BibTeX tab button
    var bibtexTab: XCUIElement {
        app.buttons[AccessibilityID.Detail.Tab.bibtex]
    }

    /// Notes tab button
    var notesTab: XCUIElement {
        app.buttons[AccessibilityID.Detail.Tab.notes]
    }

    /// Info tab button
    var infoTab: XCUIElement {
        app.buttons[AccessibilityID.Detail.Tab.info]
    }

    /// Related tab button
    var relatedTab: XCUIElement {
        app.buttons[AccessibilityID.Detail.Tab.related]
    }

    // MARK: - Metadata Fields

    /// Title field
    var titleField: XCUIElement {
        app.staticTexts[AccessibilityID.Detail.Field.title]
    }

    /// Authors field
    var authorsField: XCUIElement {
        app.staticTexts[AccessibilityID.Detail.Field.authors]
    }

    /// Year field
    var yearField: XCUIElement {
        app.staticTexts[AccessibilityID.Detail.Field.year]
    }

    /// Journal field
    var journalField: XCUIElement {
        app.staticTexts[AccessibilityID.Detail.Field.journal]
    }

    /// Abstract field
    var abstractField: XCUIElement {
        app.staticTexts[AccessibilityID.Detail.Field.abstract]
    }

    /// DOI field
    var doiField: XCUIElement {
        app.staticTexts[AccessibilityID.Detail.Field.doi]
    }

    /// Cite key field
    var citeKeyField: XCUIElement {
        app.staticTexts[AccessibilityID.Detail.Field.citeKey]
    }

    // MARK: - Action Buttons

    /// Open PDF button
    var openPDFButton: XCUIElement {
        app.buttons[AccessibilityID.Detail.Action.openPDF]
    }

    /// Download PDF button
    var downloadPDFButton: XCUIElement {
        app.buttons[AccessibilityID.Detail.Action.downloadPDF]
    }

    /// Copy DOI button
    var copyDOIButton: XCUIElement {
        app.buttons[AccessibilityID.Detail.Action.copyDOI]
    }

    /// Open URL button
    var openURLButton: XCUIElement {
        app.buttons[AccessibilityID.Detail.Action.openURL]
    }

    /// Edit button
    var editButton: XCUIElement {
        app.buttons[AccessibilityID.Detail.Action.edit]
    }

    /// Delete button
    var deleteButton: XCUIElement {
        app.buttons[AccessibilityID.Detail.Action.delete]
    }

    // MARK: - Wait Methods

    /// Wait for the detail view to be visible
    @discardableResult
    func waitForDetailView(timeout: TimeInterval = 5) -> Bool {
        // Either we see the empty state or a publication
        let hasContent = !emptyState.exists || titleField.exists
        return hasContent
    }

    /// Wait for a publication to be displayed
    @discardableResult
    func waitForPublication(timeout: TimeInterval = 5) -> Bool {
        titleField.waitForExistence(timeout: timeout)
    }

    // MARK: - Tab Navigation

    /// Select the PDF tab
    func selectPDFTab() {
        pdfTab.click()
    }

    /// Select the BibTeX tab
    func selectBibTeXTab() {
        bibtexTab.click()
    }

    /// Select the Notes tab
    func selectNotesTab() {
        notesTab.click()
    }

    /// Select the Info tab
    func selectInfoTab() {
        infoTab.click()
    }

    /// Select the Related tab
    func selectRelatedTab() {
        relatedTab.click()
    }

    // MARK: - Keyboard Shortcuts

    /// Show PDF tab via keyboard (Cmd+4)
    func showPDFViaKeyboard() {
        app.typeKey("4", modifierFlags: .command)
    }

    /// Show BibTeX tab via keyboard (Cmd+5)
    func showBibTeXViaKeyboard() {
        app.typeKey("5", modifierFlags: .command)
    }

    /// Show Notes tab via keyboard (Cmd+6)
    func showNotesViaKeyboard() {
        app.typeKey("6", modifierFlags: .command)
    }

    // MARK: - Actions

    /// Open the PDF (if available)
    func openPDF() {
        if openPDFButton.exists {
            openPDFButton.click()
        }
    }

    /// Download the PDF (if available)
    func downloadPDF() {
        if downloadPDFButton.exists {
            downloadPDFButton.click()
        }
    }

    /// Copy the DOI to clipboard
    func copyDOI() {
        if copyDOIButton.exists {
            copyDOIButton.click()
        }
    }

    /// Open the web URL
    func openURL() {
        if openURLButton.exists {
            openURLButton.click()
        }
    }

    /// Enter edit mode
    func edit() {
        editButton.click()
    }

    /// Delete the publication
    func delete() {
        deleteButton.click()
    }

    // MARK: - BibTeX Tab

    /// Get the BibTeX editor content
    func getBibTeXContent() -> String {
        // Switch to BibTeX tab first
        selectBibTeXTab()

        // Find the text editor
        let editor = app.textViews.firstMatch
        return editor.value as? String ?? ""
    }

    /// Edit the BibTeX content
    func editBibTeX(_ newContent: String) {
        selectBibTeXTab()

        let editor = app.textViews.firstMatch
        editor.click()
        editor.typeKey("a", modifierFlags: .command) // Select all
        editor.typeText(newContent)
    }

    // MARK: - Notes Tab

    /// Get the notes content
    func getNotesContent() -> String {
        selectNotesTab()

        let editor = app.textViews.firstMatch
        return editor.value as? String ?? ""
    }

    /// Edit the notes content
    func editNotes(_ content: String) {
        selectNotesTab()

        let editor = app.textViews.firstMatch
        editor.click()
        editor.typeKey("a", modifierFlags: .command) // Select all
        editor.typeText(content)
    }

    // MARK: - Assertions

    /// Assert the detail view is showing the empty state
    func assertEmptyState(file: StaticString = #file, line: UInt = #line) {
        XCTAssertTrue(
            emptyState.exists,
            "Detail view should show empty state",
            file: file,
            line: line
        )
    }

    /// Assert a publication is displayed with the given title
    func assertPublicationDisplayed(titled title: String, file: StaticString = #file, line: UInt = #line) {
        let titleText = app.staticTexts[title]
        XCTAssertTrue(
            titleText.waitForExistence(timeout: 2),
            "Publication with title '\(title)' should be displayed",
            file: file,
            line: line
        )
    }

    /// Assert the displayed year matches
    func assertYear(_ year: Int, file: StaticString = #file, line: UInt = #line) {
        let yearText = app.staticTexts["\(year)"]
        XCTAssertTrue(
            yearText.exists,
            "Year \(year) should be displayed",
            file: file,
            line: line
        )
    }

    /// Assert the PDF tab is showing
    func assertPDFTabActive(file: StaticString = #file, line: UInt = #line) {
        // Check for PDF viewer elements
        let pdfView = app.scrollViews.firstMatch
        XCTAssertTrue(
            pdfView.exists,
            "PDF view should be visible",
            file: file,
            line: line
        )
    }

    /// Assert the BibTeX tab is showing
    func assertBibTeXTabActive(file: StaticString = #file, line: UInt = #line) {
        // Check for BibTeX editor
        let editor = app.textViews.firstMatch
        let content = editor.value as? String ?? ""
        XCTAssertTrue(
            content.contains("@") || editor.exists,
            "BibTeX editor should be visible",
            file: file,
            line: line
        )
    }

    /// Assert the Notes tab is showing
    func assertNotesTabActive(file: StaticString = #file, line: UInt = #line) {
        // Check for notes editor
        let editor = app.textViews.firstMatch
        XCTAssertTrue(
            editor.exists,
            "Notes editor should be visible",
            file: file,
            line: line
        )
    }

    /// Assert the PDF button is visible (publication has PDF)
    func assertHasPDF(file: StaticString = #file, line: UInt = #line) {
        XCTAssertTrue(
            openPDFButton.exists,
            "Open PDF button should be visible",
            file: file,
            line: line
        )
    }

    /// Assert the Download PDF button is visible (no local PDF)
    func assertNeedsPDFDownload(file: StaticString = #file, line: UInt = #line) {
        XCTAssertTrue(
            downloadPDFButton.exists,
            "Download PDF button should be visible",
            file: file,
            line: line
        )
    }

    /// Assert the DOI is displayed
    func assertDOI(_ doi: String, file: StaticString = #file, line: UInt = #line) {
        let doiText = app.staticTexts[doi]
        XCTAssertTrue(
            doiText.exists,
            "DOI '\(doi)' should be displayed",
            file: file,
            line: line
        )
    }
}
