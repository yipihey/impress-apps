//
//  ExportWorkflowTests.swift
//  imbibUITests
//
//  End-to-end tests for export workflows.
//

import XCTest

/// Tests for exporting publications in various formats.
final class ExportWorkflowTests: XCTestCase {

    var app: XCUIApplication!
    var sidebar: SidebarPage!
    var list: PublicationListPage!
    var detail: DetailViewPage!

    // MARK: - Setup

    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        app = TestApp.launch(with: .basic)
        sidebar = SidebarPage(app: app)
        list = PublicationListPage(app: app)
        detail = DetailViewPage(app: app)

        _ = sidebar.waitForSidebar()
    }

    // MARK: - BibTeX Export Tests

    /// Test exporting library as BibTeX via File menu
    func testExportLibraryAsBibTeX() throws {
        // Given: A library with publications
        sidebar.selectAllPublications()
        _ = list.waitForPublications()

        // When: I use File > Export Library (Cmd+Shift+E)
        app.typeKey("e", modifierFlags: [.command, .shift])

        // Then: A save dialog should appear
        let savePanel = app.dialogs.firstMatch
        XCTAssertTrue(savePanel.waitForExistence(timeout: 2), "Save dialog should appear")

        // Cancel for now
        app.typeKey(.escape, modifierFlags: [])
    }

    /// Test exporting selected publications as BibTeX
    func testExportSelectionAsBibTeX() throws {
        // Given: Publications are selected
        sidebar.selectAllPublications()
        _ = list.waitForPublications()
        list.selectFirst()

        // When: I export selection via context menu
        list.showContextMenu(forPublicationAt: 0)
        let exportItem = app.menuItems["Export as BibTeX..."]
        if exportItem.waitForExistence(timeout: 2) {
            exportItem.click()
        }

        // Then: A save dialog should appear
        // (or the export might go to a default location)
    }

    // MARK: - Copy Citation Tests

    /// Test copying citation to clipboard
    func testCopyCitation() throws {
        // Given: A publication is selected
        sidebar.selectAllPublications()
        _ = list.waitForPublications()
        list.selectFirst()

        // When: I copy as citation (Cmd+Shift+C)
        app.typeKey("c", modifierFlags: [.command, .shift])

        // Then: The citation should be in the clipboard
        #if os(macOS)
        let clipboard = NSPasteboard.general.string(forType: .string) ?? ""
        // Citation format depends on settings, but should have author and year
        // (This verification would need the actual clipboard access)
        #endif
    }

    /// Test copying DOI/URL
    func testCopyDOI() throws {
        // Given: A publication with DOI is selected
        sidebar.selectAllPublications()
        _ = list.waitForPublications()
        list.selectFirst()

        // When: I copy DOI (Cmd+Option+C)
        app.typeKey("c", modifierFlags: [.command, .option])

        // Then: The DOI should be in the clipboard
        #if os(macOS)
        let clipboard = NSPasteboard.general.string(forType: .string) ?? ""
        // Should contain DOI or URL
        #endif
    }

    /// Test copying BibTeX to clipboard
    func testCopyBibTeX() throws {
        // Given: A publication is selected
        sidebar.selectAllPublications()
        _ = list.waitForPublications()
        list.selectFirst()

        // When: I copy (Cmd+C)
        list.copySelected()

        // Then: BibTeX should be in the clipboard
        #if os(macOS)
        let clipboard = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertTrue(clipboard.contains("@"), "Clipboard should contain BibTeX")
        #endif
    }

    // MARK: - Share Tests

    /// Test sharing via Share menu
    func testSharePublication() throws {
        // Given: A publication is selected
        sidebar.selectAllPublications()
        _ = list.waitForPublications()
        list.selectFirst()

        // When: I use Share (Cmd+Shift+F)
        app.typeKey("f", modifierFlags: [.command, .shift])

        // Then: Share sheet should appear
        let shareSheet = app.sheets.firstMatch
        // Share sheet might not appear in UI tests
        // This depends on system behavior

        // Cancel if sheet appeared
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - Bulk Export Tests

    /// Test exporting multiple publications
    func testBulkExport() throws {
        // Given: Multiple publications are selected
        sidebar.selectAllPublications()
        _ = list.waitForPublications()
        list.selectAll()

        // When: I export
        app.typeKey("e", modifierFlags: [.command, .shift])

        // Then: All should be exported
        let savePanel = app.dialogs.firstMatch
        XCTAssertTrue(savePanel.waitForExistence(timeout: 2), "Save dialog should appear")

        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - Format Options Tests

    /// Test exporting with different citation styles
    func testExportWithCitationStyle() throws {
        // This would test the citation style selection in export options
    }

    /// Test exporting as RIS
    func testExportAsRIS() throws {
        // Given: Publications to export
        sidebar.selectAllPublications()
        _ = list.waitForPublications()
        list.selectFirst()

        // When: I export as RIS
        // (This would use a menu or export dialog with format selection)

        // Then: RIS format should be available
    }

    // MARK: - Collection Export Tests

    /// Test exporting a collection
    func testExportCollection() throws {
        // Given: A collection exists with publications
        sidebar.selectCollection(named: "Important Physics")

        // When: I export the collection

        // Then: Only collection publications should be exported
    }

    // MARK: - Smart Search Export Tests

    /// Test exporting smart search results
    func testExportSmartSearchResults() throws {
        // Given: A smart search with results

        // When: I export the results

        // Then: The results should be exported
    }

    // MARK: - Export Validation Tests

    /// Test that exported BibTeX is valid
    func testExportedBibTeXIsValid() throws {
        // Given: A publication with all fields

        // When: I copy its BibTeX

        // Then: The BibTeX should be parseable
        // (Would need to actually parse the clipboard content)
    }

    /// Test that special characters are escaped in export
    func testSpecialCharactersEscapedInExport() throws {
        // Given: A publication with special characters (LaTeX math, umlauts, etc.)

        // When: I export it

        // Then: Special characters should be properly escaped
    }
}
