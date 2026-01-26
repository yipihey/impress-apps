//
//  DocumentWorkflowTests.swift
//  imprintUITests
//
//  Consolidated workflow tests for document operations.
//  Uses shared app instance for fast execution.
//

import XCTest
import ImpressTestKit

/// Workflow tests for document operations (compilation, citations, versioning)
final class DocumentWorkflowTests: SharedAppTestCase {

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

    // MARK: - Test Setup (Run Before Each Test)

    override func resetAppState() {
        super.resetAppState()
        // Start in split view for most workflow tests
        let content = ContentPage(app: app)
        content.selectEditMode(.splitView)
    }

    // MARK: - Page Objects

    var contentPage: ContentPage { ContentPage(app: app) }
    var editorPage: SourceEditorPage { SourceEditorPage(app: app) }
    var previewPage: PDFPreviewPage { PDFPreviewPage(app: app) }
    var citationPage: CitationPickerPage { CitationPickerPage(app: app) }
    var versionHistoryPage: VersionHistoryPage { VersionHistoryPage(app: app) }

    // MARK: - Compilation Workflow Tests

    /// Test basic compilation workflow
    func testBasicCompilationWorkflow() {
        editorPage.typeText("= Hello World\n\nThis is my document.")
        contentPage.compile()

        XCTAssertTrue(
            previewPage.waitForCompilation(timeout: 15),
            "Compilation should complete"
        )
        previewPage.assertDocumentLoaded()
    }

    /// Test compilation with keyboard shortcut
    func testCompilationWithKeyboard() {
        editorPage.typeText("= Test\n\nContent")
        contentPage.compileWithKeyboard()

        XCTAssertTrue(
            previewPage.waitForCompilation(timeout: 15),
            "Compilation via keyboard should complete"
        )
    }

    /// Test recompilation after edits
    func testRecompilationAfterEdits() {
        editorPage.typeText("= First Version")
        contentPage.compile()
        _ = previewPage.waitForCompilation()

        editorPage.typeText("\n\nAdditional content.")
        contentPage.compile()

        XCTAssertTrue(
            previewPage.waitForCompilation(timeout: 15),
            "Recompilation should complete"
        )
    }

    /// Test compilation with headings
    func testCompilationWithHeadings() {
        let content = "= Main Title\n\n== Introduction\n\nSome intro text.\n\n== Methods\n\nMethod description."
        editorPage.typeText(content)
        contentPage.compile()

        XCTAssertTrue(
            previewPage.waitForCompilation(timeout: 15),
            "Document with headings should compile"
        )
    }

    /// Test compilation with math
    func testCompilationWithMath() {
        let content = "= Math Document\n\nThe famous equation is $ E = m c^2 $."
        editorPage.typeText(content)
        contentPage.compile()

        XCTAssertTrue(
            previewPage.waitForCompilation(timeout: 15),
            "Document with math should compile"
        )
    }

    // MARK: - Citation Workflow Tests

    /// Test opening citation picker
    func testOpenCitationPicker() {
        // Ensure window is focused
        app.windows.firstMatch.click()

        XCTAssertTrue(
            contentPage.openCitationPickerAndWait(),
            "Citation picker should be open"
        )
        citationPage.assertSearchFieldExists()

        citationPage.cancel()
        _ = citationPage.waitForClose()
    }

    /// Test searching for citations
    func testSearchCitations() {
        app.windows.firstMatch.click()
        XCTAssertTrue(contentPage.openCitationPickerAndWait(), "Picker should open")

        citationPage.search("einstein")

        XCTAssertTrue(
            citationPage.waitForResults(timeout: 5),
            "Should show search results"
        )

        citationPage.cancel()
        _ = citationPage.waitForClose()
    }

    /// Test inserting a citation
    func testInsertCitation() {
        app.windows.firstMatch.click()
        editorPage.typeText("According to ")

        XCTAssertTrue(contentPage.openCitationPickerAndWait(), "Picker should open")

        citationPage.search("einstein")
        _ = citationPage.waitForResults()

        citationPage.selectResult(at: 0)
        citationPage.assertCanInsert()

        citationPage.insertSelected()
        _ = citationPage.waitForClose()
    }

    /// Test insert button is disabled without selection
    func testInsertDisabledWithoutSelection() {
        app.windows.firstMatch.click()
        XCTAssertTrue(contentPage.openCitationPickerAndWait(), "Picker should open")

        citationPage.assertCannotInsert()
        citationPage.cancel()
        _ = citationPage.waitForClose()
    }

    // MARK: - Version History Workflow Tests

    /// Test opening version history
    func testOpenVersionHistory() {
        XCTAssertTrue(
            versionHistoryPage.openAndWait(),
            "Version history should open"
        )

        versionHistoryPage.assertTimelineExists()
        versionHistoryPage.close()
        _ = versionHistoryPage.waitForClose()
    }

    /// Test closing version history
    func testCloseVersionHistory() {
        XCTAssertTrue(versionHistoryPage.openAndWait(), "Should open")

        versionHistoryPage.close()

        XCTAssertTrue(
            versionHistoryPage.waitForClose(),
            "Version history should close"
        )
    }

    /// Test restore button disabled without selection
    func testRestoreDisabledWithoutSelection() {
        XCTAssertTrue(versionHistoryPage.openAndWait(), "Should open")

        versionHistoryPage.assertCannotRestore()
        versionHistoryPage.close()
        _ = versionHistoryPage.waitForClose()
    }

    // MARK: - Document Lifecycle Tests

    /// Test creating a new document
    func testCreateNewDocument() {
        app.typeKey("n", modifierFlags: .command)
        _ = app.waitForIdle()
    }

    /// Test save with keyboard shortcut
    func testSaveDocument() {
        editorPage.typeText("= My Document\n\nContent here.")
        app.typeKey("s", modifierFlags: .command)
        _ = app.waitForIdle()
        // Cancel any save dialog
        app.typeKey(.escape, modifierFlags: [])
    }
}
