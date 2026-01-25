//
//  DetailPanelTests.swift
//  imbibUITests
//
//  Component tests for the detail panel view.
//

import XCTest

/// Component tests for the publication detail panel.
final class DetailPanelTests: XCTestCase {

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
        sidebar.selectAllPublications()
        _ = list.waitForPublications()
    }

    // MARK: - Empty State Tests

    /// Test detail shows empty state when nothing selected
    func testDetailShowsEmptyState() throws {
        // Don't select any publication
        app.typeKey(.escape, modifierFlags: [])

        detail.assertEmptyState()
    }

    // MARK: - Content Display Tests

    /// Test detail shows publication info
    func testDetailShowsPublicationInfo() throws {
        list.selectPublication(titled: "On the Electrodynamics of Moving Bodies")

        _ = detail.waitForPublication()

        detail.assertPublicationDisplayed(titled: "On the Electrodynamics of Moving Bodies")
    }

    /// Test detail shows title
    func testDetailShowsTitle() throws {
        list.selectFirst()
        _ = detail.waitForPublication()

        // Title should be visible
        let titles = app.staticTexts.allElementsBoundByIndex
        let hasTitle = titles.contains { $0.label.count > 10 } // Some substantial text
        XCTAssertTrue(hasTitle, "Detail should show title")
    }

    /// Test detail shows authors
    func testDetailShowsAuthors() throws {
        list.selectFirst()
        _ = detail.waitForPublication()

        // Authors should be visible
    }

    /// Test detail shows year
    func testDetailShowsYear() throws {
        list.selectPublication(titled: "On the Electrodynamics of Moving Bodies")
        _ = detail.waitForPublication()

        detail.assertYear(1905)
    }

    /// Test detail shows abstract
    func testDetailShowsAbstract() throws {
        list.selectFirst()
        _ = detail.waitForPublication()

        // Abstract should be visible if available
    }

    // MARK: - Tab Navigation Tests

    /// Test PDF tab exists
    func testPDFTabExists() throws {
        list.selectFirst()
        _ = detail.waitForPublication()

        // PDF tab should exist
        // (might show Download PDF or Open PDF depending on state)
    }

    /// Test BibTeX tab shows content
    func testBibTeXTabShowsContent() throws {
        list.selectFirst()
        _ = detail.waitForPublication()

        detail.selectBibTeXTab()

        let content = detail.getBibTeXContent()
        XCTAssertTrue(content.contains("@"), "BibTeX should contain entry marker")
    }

    /// Test Notes tab is editable
    func testNotesTabIsEditable() throws {
        list.selectFirst()
        _ = detail.waitForPublication()

        detail.selectNotesTab()

        // Should be able to edit notes
        detail.editNotes("Test note content")

        let content = detail.getNotesContent()
        XCTAssertTrue(content.contains("Test"), "Notes should be editable")
    }

    /// Test keyboard shortcuts switch tabs
    func testKeyboardShortcutsSwitchTabs() throws {
        list.selectFirst()
        _ = detail.waitForPublication()

        // Cmd+4 for PDF
        detail.showPDFViaKeyboard()

        // Cmd+5 for BibTeX
        detail.showBibTeXViaKeyboard()
        detail.assertBibTeXTabActive()

        // Cmd+6 for Notes
        detail.showNotesViaKeyboard()
        detail.assertNotesTabActive()
    }

    // MARK: - Action Button Tests

    /// Test Copy DOI button
    func testCopyDOIButton() throws {
        list.selectFirst()
        _ = detail.waitForPublication()

        if detail.copyDOIButton.exists {
            detail.copyDOI()
            // DOI should be copied to clipboard
        }
    }

    /// Test Open URL button
    func testOpenURLButton() throws {
        list.selectFirst()
        _ = detail.waitForPublication()

        if detail.openURLButton.exists {
            // Clicking should open URL in browser
            // (Can't easily verify in UI test)
        }
    }

    // MARK: - PDF Display Tests

    /// Test PDF displays when available
    func testPDFDisplaysWhenAvailable() throws {
        // This test needs a publication with a linked PDF
        // Using test data that includes PDFs
    }

    /// Test Download PDF button when no local PDF
    func testDownloadPDFButtonWhenNoLocalPDF() throws {
        list.selectFirst()
        _ = detail.waitForPublication()

        // Publications without local PDF should show download button
        // (depends on test data)
    }

    // MARK: - Edit Tests

    /// Test editing BibTeX
    func testEditingBibTeX() throws {
        list.selectFirst()
        _ = detail.waitForPublication()

        detail.selectBibTeXTab()

        let originalContent = detail.getBibTeXContent()

        // Edit the BibTeX
        let editor = app.textViews.firstMatch
        editor.click()
        editor.typeKey(.end, modifierFlags: .command)
        editor.typeText("\n% Test comment")

        let newContent = detail.getBibTeXContent()
        XCTAssertNotEqual(originalContent, newContent, "Content should be editable")
    }

    // MARK: - Selection Change Tests

    /// Test detail updates when selection changes
    func testDetailUpdatesOnSelectionChange() throws {
        // Select first publication
        list.selectPublication(titled: "On the Electrodynamics of Moving Bodies")
        _ = detail.waitForPublication()
        detail.assertPublicationDisplayed(titled: "On the Electrodynamics of Moving Bodies")

        // Select a different publication
        list.selectPublication(titled: "Black hole explosions?")
        _ = detail.waitForPublication()
        detail.assertPublicationDisplayed(titled: "Black hole explosions?")
    }

    // MARK: - Multi-Selection Tests

    /// Test detail with multiple selections
    func testDetailWithMultipleSelections() throws {
        list.selectAll()

        // Detail might show:
        // - First selected item
        // - Multi-selection summary
        // - Empty state

        // Behavior depends on implementation
    }

    // MARK: - Toggle Detail Pane Tests

    /// Test hiding detail pane
    func testHidingDetailPane() throws {
        list.selectFirst()
        _ = detail.waitForPublication()

        // Toggle detail pane off
        app.typeKey("0", modifierFlags: .command)

        // Detail should be hidden
        // (verification depends on layout)

        // Toggle back
        app.typeKey("0", modifierFlags: .command)
    }

    // MARK: - Related Papers Tests

    /// Test Related tab shows related papers
    func testRelatedTabShowsRelatedPapers() throws {
        list.selectFirst()
        _ = detail.waitForPublication()

        detail.selectRelatedTab()

        // Should show related papers or recommendation
        // (depends on implementation and data)
    }
}
