//
//  DetailPage.swift
//  imbibUITests
//
//  Created by Claude on 2026-01-22.
//

import XCTest

/// Page object for publication detail view interactions
final class DetailPage {
    private let app: XCUIApplication

    init(app: XCUIApplication) {
        self.app = app
    }

    // MARK: - Tab Elements

    var infoTab: XCUIElement {
        app[AccessibilityID.Detail.Tabs.info]
    }

    var pdfTab: XCUIElement {
        app[AccessibilityID.Detail.Tabs.pdf]
    }

    var notesTab: XCUIElement {
        app[AccessibilityID.Detail.Tabs.notes]
    }

    var bibtexTab: XCUIElement {
        app[AccessibilityID.Detail.Tabs.bibtex]
    }

    var referencesTab: XCUIElement {
        app[AccessibilityID.Detail.Tabs.references]
    }

    var annotationsTab: XCUIElement {
        app[AccessibilityID.Detail.Tabs.annotations]
    }

    // MARK: - Info Tab Elements

    var titleField: XCUIElement {
        app[AccessibilityID.Detail.Info.titleField]
    }

    var authorsField: XCUIElement {
        app[AccessibilityID.Detail.Info.authorsField]
    }

    var authorsExpand: XCUIElement {
        app[AccessibilityID.Detail.Info.authorsExpand]
    }

    var yearField: XCUIElement {
        app[AccessibilityID.Detail.Info.yearField]
    }

    var journalField: XCUIElement {
        app[AccessibilityID.Detail.Info.journalField]
    }

    var abstractField: XCUIElement {
        app[AccessibilityID.Detail.Info.abstractField]
    }

    var doiField: XCUIElement {
        app[AccessibilityID.Detail.Info.doiField]
    }

    var doiCopyButton: XCUIElement {
        app[AccessibilityID.Detail.Info.doiCopyButton]
    }

    var doiOpenButton: XCUIElement {
        app[AccessibilityID.Detail.Info.doiOpenButton]
    }

    var arxivField: XCUIElement {
        app[AccessibilityID.Detail.Info.arxivField]
    }

    var arxivOpenButton: XCUIElement {
        app[AccessibilityID.Detail.Info.arxivOpenButton]
    }

    var citationCount: XCUIElement {
        app[AccessibilityID.Detail.Info.citationCount]
    }

    var addToLibraryButton: XCUIElement {
        app[AccessibilityID.Detail.Info.addToLibraryButton]
    }

    var openPDFButton: XCUIElement {
        app[AccessibilityID.Detail.Info.openPDFButton]
    }

    var downloadPDFButton: XCUIElement {
        app[AccessibilityID.Detail.Info.downloadPDFButton]
    }

    var keywordsField: XCUIElement {
        app[AccessibilityID.Detail.Info.keywordsField]
    }

    // MARK: - PDF Tab Elements

    var pdfViewer: XCUIElement {
        app[AccessibilityID.Detail.PDF.viewer]
    }

    var pdfZoomIn: XCUIElement {
        app[AccessibilityID.Detail.PDF.zoomInButton]
    }

    var pdfZoomOut: XCUIElement {
        app[AccessibilityID.Detail.PDF.zoomOutButton]
    }

    var pdfZoomFit: XCUIElement {
        app[AccessibilityID.Detail.PDF.zoomFitButton]
    }

    var pdfPageField: XCUIElement {
        app[AccessibilityID.Detail.PDF.pageField]
    }

    var pdfPreviousPage: XCUIElement {
        app[AccessibilityID.Detail.PDF.previousPageButton]
    }

    var pdfNextPage: XCUIElement {
        app[AccessibilityID.Detail.PDF.nextPageButton]
    }

    var pdfSearchField: XCUIElement {
        app[AccessibilityID.Detail.PDF.searchField]
    }

    var noPDFView: XCUIElement {
        app[AccessibilityID.Detail.PDF.noPDFView]
    }

    var findPDFButton: XCUIElement {
        app[AccessibilityID.Detail.PDF.findPDFButton]
    }

    // MARK: - Notes Tab Elements

    var notesEditor: XCUIElement {
        app[AccessibilityID.Detail.Notes.editor]
    }

    var notesSaveButton: XCUIElement {
        app[AccessibilityID.Detail.Notes.saveButton]
    }

    var notesClearButton: XCUIElement {
        app[AccessibilityID.Detail.Notes.clearButton]
    }

    // MARK: - BibTeX Tab Elements

    var bibtexEditor: XCUIElement {
        app[AccessibilityID.Detail.BibTeX.editor]
    }

    var bibtexCopyButton: XCUIElement {
        app[AccessibilityID.Detail.BibTeX.copyButton]
    }

    var bibtexSaveButton: XCUIElement {
        app[AccessibilityID.Detail.BibTeX.saveButton]
    }

    var bibtexResetButton: XCUIElement {
        app[AccessibilityID.Detail.BibTeX.resetButton]
    }

    var bibtexValidateButton: XCUIElement {
        app[AccessibilityID.Detail.BibTeX.validateButton]
    }

    var bibtexValidationStatus: XCUIElement {
        app[AccessibilityID.Detail.BibTeX.validationStatus]
    }

    // MARK: - References Tab Elements

    var referencesList: XCUIElement {
        app[AccessibilityID.Detail.References.list]
    }

    var referencesRefreshButton: XCUIElement {
        app[AccessibilityID.Detail.References.refreshButton]
    }

    var referencesLoadingIndicator: XCUIElement {
        app[AccessibilityID.Detail.References.loadingIndicator]
    }

    func referenceRow(index: Int) -> XCUIElement {
        app[AccessibilityID.Detail.References.referenceRow(index)]
    }

    // MARK: - Tab Actions

    @discardableResult
    func selectInfoTab() -> DetailPage {
        infoTab.tapWhenReady()
        return self
    }

    @discardableResult
    func selectPDFTab() -> DetailPage {
        pdfTab.tapWhenReady()
        return self
    }

    @discardableResult
    func selectNotesTab() -> DetailPage {
        notesTab.tapWhenReady()
        return self
    }

    @discardableResult
    func selectBibTeXTab() -> DetailPage {
        bibtexTab.tapWhenReady()
        return self
    }

    @discardableResult
    func selectReferencesTab() -> DetailPage {
        referencesTab.tapWhenReady()
        return self
    }

    // MARK: - Info Actions

    @discardableResult
    func copyDOI() -> DetailPage {
        doiCopyButton.tapWhenReady()
        return self
    }

    @discardableResult
    func openDOI() -> DetailPage {
        doiOpenButton.tapWhenReady()
        return self
    }

    @discardableResult
    func openArXiv() -> DetailPage {
        arxivOpenButton.tapWhenReady()
        return self
    }

    @discardableResult
    func addToLibrary() -> DetailPage {
        addToLibraryButton.tapWhenReady()
        return self
    }

    @discardableResult
    func openPDF() -> DetailPage {
        openPDFButton.tapWhenReady()
        return self
    }

    @discardableResult
    func downloadPDF() -> DetailPage {
        downloadPDFButton.tapWhenReady()
        return self
    }

    // MARK: - PDF Actions

    @discardableResult
    func zoomIn() -> DetailPage {
        pdfZoomIn.tapWhenReady()
        return self
    }

    @discardableResult
    func zoomOut() -> DetailPage {
        pdfZoomOut.tapWhenReady()
        return self
    }

    @discardableResult
    func zoomFit() -> DetailPage {
        pdfZoomFit.tapWhenReady()
        return self
    }

    @discardableResult
    func goToNextPage() -> DetailPage {
        pdfNextPage.tapWhenReady()
        return self
    }

    @discardableResult
    func goToPreviousPage() -> DetailPage {
        pdfPreviousPage.tapWhenReady()
        return self
    }

    func searchInPDF(_ query: String) {
        pdfSearchField.typeTextWhenReady(query)
    }

    // MARK: - Notes Actions

    func typeNotes(_ text: String) {
        notesEditor.typeTextWhenReady(text)
    }

    @discardableResult
    func saveNotes() -> DetailPage {
        notesSaveButton.tapWhenReady()
        return self
    }

    @discardableResult
    func clearNotes() -> DetailPage {
        notesClearButton.tapWhenReady()
        return self
    }

    // MARK: - BibTeX Actions

    @discardableResult
    func copyBibTeX() -> DetailPage {
        bibtexCopyButton.tapWhenReady()
        return self
    }

    @discardableResult
    func saveBibTeX() -> DetailPage {
        bibtexSaveButton.tapWhenReady()
        return self
    }

    @discardableResult
    func resetBibTeX() -> DetailPage {
        bibtexResetButton.tapWhenReady()
        return self
    }

    @discardableResult
    func validateBibTeX() -> DetailPage {
        bibtexValidateButton.tapWhenReady()
        return self
    }

    // MARK: - Verification

    func verifyInfoTabVisible(timeout: TimeInterval = 5) {
        XCTAssertTrue(infoTab.waitForExistence(timeout: timeout), "Info tab should be visible")
    }

    func verifyPDFTabVisible(timeout: TimeInterval = 5) {
        XCTAssertTrue(pdfTab.waitForExistence(timeout: timeout), "PDF tab should be visible")
    }

    func verifyNotesTabVisible(timeout: TimeInterval = 5) {
        XCTAssertTrue(notesTab.waitForExistence(timeout: timeout), "Notes tab should be visible")
    }

    func verifyBibTeXTabVisible(timeout: TimeInterval = 5) {
        XCTAssertTrue(bibtexTab.waitForExistence(timeout: timeout), "BibTeX tab should be visible")
    }

    func verifyAllTabsVisible(timeout: TimeInterval = 5) {
        verifyInfoTabVisible(timeout: timeout)
        verifyPDFTabVisible(timeout: timeout)
        verifyNotesTabVisible(timeout: timeout)
        verifyBibTeXTabVisible(timeout: timeout)
    }

    func verifyTitleDisplayed(expected: String, timeout: TimeInterval = 5) {
        XCTAssertTrue(titleField.waitForExistence(timeout: timeout), "Title field should exist")
        XCTAssertEqual(titleField.value as? String, expected, "Title should match expected value")
    }

    func verifyPDFViewerVisible(timeout: TimeInterval = 5) {
        XCTAssertTrue(pdfViewer.waitForExistence(timeout: timeout), "PDF viewer should be visible")
    }

    func verifyNoPDFState(timeout: TimeInterval = 5) {
        XCTAssertTrue(noPDFView.waitForExistence(timeout: timeout), "No PDF view should be visible")
    }

    func verifyBibTeXEditorVisible(timeout: TimeInterval = 5) {
        XCTAssertTrue(bibtexEditor.waitForExistence(timeout: timeout), "BibTeX editor should be visible")
    }
}
