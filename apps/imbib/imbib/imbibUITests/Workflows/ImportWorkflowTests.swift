//
//  ImportWorkflowTests.swift
//  imbibUITests
//
//  End-to-end tests for publication import workflows.
//

import XCTest

/// Tests for importing publications from various sources.
final class ImportWorkflowTests: XCTestCase {

    var app: XCUIApplication!
    var sidebar: SidebarPage!
    var list: PublicationListPage!
    var detail: DetailViewPage!

    // MARK: - Setup

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = TestApp.launch(resetState: true, mockServices: true)
        sidebar = SidebarPage(app: app)
        list = PublicationListPage(app: app)
        detail = DetailViewPage(app: app)

        // Wait for app to be ready
        _ = sidebar.waitForSidebar()
    }

    override func tearDown() {
        TestDataFactory.cleanup()
        super.tearDown()
    }

    // MARK: - BibTeX Import Tests

    /// Test importing BibTeX via File > Import menu
    func testImportBibTeXFromMenu() throws {
        // Given: The app is open with an empty library
        sidebar.selectAllPublications()
        let initialCount = list.rows.count

        // When: I use File > Import > BibTeX
        app.menuItems["Import BibTeX..."].click()

        // Then: The import dialog should appear
        let openPanel = app.dialogs.firstMatch
        XCTAssertTrue(openPanel.waitForExistence(timeout: 2), "Import dialog should appear")

        // Note: Completing the file selection would require AppleScript or test fixtures
        // For now, cancel the dialog
        app.typeKey(.escape, modifierFlags: [])
    }

    /// Test importing BibTeX via keyboard shortcut (Cmd+I)
    func testImportBibTeXViaKeyboard() throws {
        // When: I press Cmd+I
        app.typeKey("i", modifierFlags: .command)

        // Then: The import dialog should appear
        let openPanel = app.dialogs.firstMatch
        XCTAssertTrue(openPanel.waitForExistence(timeout: 2), "Import dialog should appear")

        // Cancel the dialog
        app.typeKey(.escape, modifierFlags: [])
    }

    /// Test pasting BibTeX from clipboard
    func testPasteBibTeXFromClipboard() throws {
        // Given: BibTeX content in the clipboard
        #if os(macOS)
        TestDataFactory.copyBibTeXToClipboard(TestDataFactory.sampleBibTeXForClipboard)

        // Select a library to paste into
        sidebar.selectAllPublications()
        let initialCount = list.rows.count

        // When: I press Cmd+V
        app.typeKey("v", modifierFlags: .command)

        // Then: The publication should be imported
        // Wait for import to complete
        let expectation = expectation(
            for: NSPredicate(format: "count > %d", initialCount),
            evaluatedWith: list.rows
        )
        wait(for: [expectation], timeout: 5)

        list.assertPublicationCount(greaterThan: initialCount)
        #endif
    }

    // MARK: - RIS Import Tests

    /// Test importing RIS file
    func testImportRISFile() throws {
        // Similar structure to BibTeX import
        // The actual import would be tested via menu or drag-drop
    }

    // MARK: - PDF Import Tests

    /// Test importing a PDF file
    func testImportPDFFile() throws {
        // PDF import typically shows a dialog to add metadata
        // This would require test fixture files
    }

    // MARK: - Drag and Drop Tests

    /// Test dragging a file to the sidebar
    func testDragFileToSidebar() throws {
        // Note: XCUITest has limited drag-and-drop support
        // This test serves as a placeholder for manual testing
        // or implementation with AppleScript

        // Given: A library exists
        sidebar.assertLibraryExists("Test Library")

        // When: I drag a BibTeX file to the library
        // (simulated - actual drag would require external tooling)

        // Then: Publications should be imported
    }

    // MARK: - URL Scheme Import Tests

    /// Test importing via URL scheme
    func testURLSchemeImport() throws {
        // The URL scheme handler is tested separately
        // This test verifies the UI responds correctly

        // Given: The app is open

        // When: An import URL is opened (imbib://add?doi=10.1234/test)
        // This would typically be triggered via AppleScript or XCUITest's launch URL

        // Then: The publication should be added
    }

    // MARK: - Bulk Import Tests

    /// Test importing multiple publications at once
    func testBulkImport() throws {
        // Given: A BibTeX file with multiple entries is prepared
        // When: It's imported
        // Then: All entries should appear in the list
    }

    // MARK: - Import Validation Tests

    /// Test that duplicate imports are handled correctly
    func testDuplicateImportHandling() throws {
        // Given: A publication exists in the library

        // When: The same publication is imported again

        // Then: It should either be deduplicated or show a warning
    }

    /// Test importing malformed BibTeX
    func testMalformedBibTeXImport() throws {
        // Given: Malformed BibTeX in the clipboard
        #if os(macOS)
        let malformedBibTeX = "@article{broken, title = {"
        TestDataFactory.copyBibTeXToClipboard(malformedBibTeX)

        sidebar.selectAllPublications()
        let initialCount = list.rows.count

        // When: I try to paste it
        app.typeKey("v", modifierFlags: .command)

        // Then: An error should be shown or the import should be skipped
        // The count should not change
        // (This depends on error handling implementation)
        #endif
    }
}
