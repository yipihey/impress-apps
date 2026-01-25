//
//  AppIntentsTests.swift
//  PublicationManagerCoreTests
//
//  Tests for AppIntents Siri Shortcuts integration.
//

import XCTest
@testable import PublicationManagerCore

@available(iOS 16.0, macOS 13.0, *)
final class AppIntentsTests: XCTestCase {

    // MARK: - Search Intents

    func testSearchPapersIntent_automationCommand() {
        let intent = SearchPapersIntent(query: "dark matter", source: .arxiv, maxResults: 25)

        if case .search(let query, let source, let maxResults) = intent.automationCommand {
            XCTAssertEqual(query, "dark matter")
            XCTAssertEqual(source, "arxiv")
            XCTAssertEqual(maxResults, 25)
        } else {
            XCTFail("Expected search command")
        }
    }

    func testSearchPapersIntent_allSources() {
        let intent = SearchPapersIntent(query: "cosmology", source: .all, maxResults: 50)

        if case .search(let query, let source, _) = intent.automationCommand {
            XCTAssertEqual(query, "cosmology")
            XCTAssertNil(source, "All sources should produce nil source ID")
        } else {
            XCTFail("Expected search command")
        }
    }

    func testSearchSourceOption_sourceIDs() {
        XCTAssertNil(SearchSourceOption.all.sourceID)
        XCTAssertEqual(SearchSourceOption.arxiv.sourceID, "arxiv")
        XCTAssertEqual(SearchSourceOption.ads.sourceID, "ads")
        XCTAssertEqual(SearchSourceOption.crossref.sourceID, "crossref")
        XCTAssertEqual(SearchSourceOption.pubmed.sourceID, "pubmed")
        XCTAssertEqual(SearchSourceOption.semanticScholar.sourceID, "semantic_scholar")
        XCTAssertEqual(SearchSourceOption.openAlex.sourceID, "openalex")
        XCTAssertEqual(SearchSourceOption.dblp.sourceID, "dblp")
    }

    func testSearchCategoryIntent_automationCommand() {
        let intent = SearchCategoryIntent(category: "astro-ph.CO")

        if case .searchCategory(let category) = intent.automationCommand {
            XCTAssertEqual(category, "astro-ph.CO")
        } else {
            XCTFail("Expected searchCategory command")
        }
    }

    // MARK: - Navigation Intents

    func testShowInboxIntent_automationCommand() {
        let intent = ShowInboxIntent()

        if case .navigate(let target) = intent.automationCommand {
            XCTAssertEqual(target, .inbox)
        } else {
            XCTFail("Expected navigate command")
        }
    }

    func testShowLibraryIntent_automationCommand() {
        let intent = ShowLibraryIntent()

        if case .navigate(let target) = intent.automationCommand {
            XCTAssertEqual(target, .library)
        } else {
            XCTFail("Expected navigate command")
        }
    }

    func testShowSearchIntent_automationCommand() {
        let intent = ShowSearchIntent()

        if case .navigate(let target) = intent.automationCommand {
            XCTAssertEqual(target, .search)
        } else {
            XCTFail("Expected navigate command")
        }
    }

    func testShowPDFTabIntent_automationCommand() {
        let intent = ShowPDFTabIntent()

        if case .navigate(let target) = intent.automationCommand {
            XCTAssertEqual(target, .pdfTab)
        } else {
            XCTFail("Expected navigate command")
        }
    }

    func testShowBibTeXTabIntent_automationCommand() {
        let intent = ShowBibTeXTabIntent()

        if case .navigate(let target) = intent.automationCommand {
            XCTAssertEqual(target, .bibtexTab)
        } else {
            XCTFail("Expected navigate command")
        }
    }

    func testShowNotesTabIntent_automationCommand() {
        let intent = ShowNotesTabIntent()

        if case .navigate(let target) = intent.automationCommand {
            XCTAssertEqual(target, .notesTab)
        } else {
            XCTFail("Expected navigate command")
        }
    }

    // MARK: - Focus Intents

    func testFocusSidebarIntent_automationCommand() {
        let intent = FocusSidebarIntent()

        if case .focus(let target) = intent.automationCommand {
            XCTAssertEqual(target, .sidebar)
        } else {
            XCTFail("Expected focus command")
        }
    }

    func testFocusListIntent_automationCommand() {
        let intent = FocusListIntent()

        if case .focus(let target) = intent.automationCommand {
            XCTAssertEqual(target, .list)
        } else {
            XCTFail("Expected focus command")
        }
    }

    func testFocusDetailIntent_automationCommand() {
        let intent = FocusDetailIntent()

        if case .focus(let target) = intent.automationCommand {
            XCTAssertEqual(target, .detail)
        } else {
            XCTFail("Expected focus command")
        }
    }

    func testFocusSearchFieldIntent_automationCommand() {
        let intent = FocusSearchFieldIntent()

        if case .focus(let target) = intent.automationCommand {
            XCTAssertEqual(target, .search)
        } else {
            XCTFail("Expected focus command")
        }
    }

    // MARK: - Paper Intents

    func testToggleReadStatusIntent_automationCommand() {
        let intent = ToggleReadStatusIntent()

        if case .selectedPapers(let action) = intent.automationCommand {
            XCTAssertEqual(action, .toggleRead)
        } else {
            XCTFail("Expected selectedPapers command")
        }
    }

    func testMarkAllReadIntent_automationCommand() {
        let intent = MarkAllReadIntent()

        if case .selectedPapers(let action) = intent.automationCommand {
            XCTAssertEqual(action, .markAllRead)
        } else {
            XCTFail("Expected selectedPapers command")
        }
    }

    func testMarkSelectedReadIntent_automationCommand() {
        let intent = MarkSelectedReadIntent()

        if case .selectedPapers(let action) = intent.automationCommand {
            XCTAssertEqual(action, .markRead)
        } else {
            XCTFail("Expected selectedPapers command")
        }
    }

    func testMarkSelectedUnreadIntent_automationCommand() {
        let intent = MarkSelectedUnreadIntent()

        if case .selectedPapers(let action) = intent.automationCommand {
            XCTAssertEqual(action, .markUnread)
        } else {
            XCTFail("Expected selectedPapers command")
        }
    }

    func testCopyBibTeXIntent_automationCommand() {
        let intent = CopyBibTeXIntent()

        if case .selectedPapers(let action) = intent.automationCommand {
            XCTAssertEqual(action, .copy)
        } else {
            XCTFail("Expected selectedPapers command")
        }
    }

    func testCopyCitationIntent_automationCommand() {
        let intent = CopyCitationIntent()

        if case .selectedPapers(let action) = intent.automationCommand {
            XCTAssertEqual(action, .copyAsCitation)
        } else {
            XCTFail("Expected selectedPapers command")
        }
    }

    func testCopyIdentifierIntent_automationCommand() {
        let intent = CopyIdentifierIntent()

        if case .selectedPapers(let action) = intent.automationCommand {
            XCTAssertEqual(action, .copyIdentifier)
        } else {
            XCTFail("Expected selectedPapers command")
        }
    }

    func testOpenSelectedPapersIntent_automationCommand() {
        let intent = OpenSelectedPapersIntent()

        if case .selectedPapers(let action) = intent.automationCommand {
            XCTAssertEqual(action, .open)
        } else {
            XCTFail("Expected selectedPapers command")
        }
    }

    func testDeleteSelectedPapersIntent_automationCommand() {
        let intent = DeleteSelectedPapersIntent()

        if case .selectedPapers(let action) = intent.automationCommand {
            XCTAssertEqual(action, .delete)
        } else {
            XCTFail("Expected selectedPapers command")
        }
    }

    func testKeepSelectedPapersIntent_automationCommand() {
        let intent = KeepSelectedPapersIntent()

        if case .selectedPapers(let action) = intent.automationCommand {
            XCTAssertEqual(action, .keep)
        } else {
            XCTFail("Expected selectedPapers command")
        }
    }

    func testSharePapersIntent_automationCommand() {
        let intent = SharePapersIntent()

        if case .selectedPapers(let action) = intent.automationCommand {
            XCTAssertEqual(action, .share)
        } else {
            XCTFail("Expected selectedPapers command")
        }
    }

    // MARK: - Inbox Intents

    func testKeepInboxItemIntent_automationCommand() {
        let intent = KeepInboxItemIntent()

        if case .inbox(let action) = intent.automationCommand {
            XCTAssertEqual(action, .keep)
        } else {
            XCTFail("Expected inbox command")
        }
    }

    func testDismissInboxItemIntent_automationCommand() {
        let intent = DismissInboxItemIntent()

        if case .inbox(let action) = intent.automationCommand {
            XCTAssertEqual(action, .dismiss)
        } else {
            XCTFail("Expected inbox command")
        }
    }

    func testToggleStarIntent_automationCommand() {
        let intent = ToggleStarIntent()

        if case .inbox(let action) = intent.automationCommand {
            XCTAssertEqual(action, .toggleStar)
        } else {
            XCTFail("Expected inbox command")
        }
    }

    func testMarkInboxReadIntent_automationCommand() {
        let intent = MarkInboxReadIntent()

        if case .inbox(let action) = intent.automationCommand {
            XCTAssertEqual(action, .markRead)
        } else {
            XCTFail("Expected inbox command")
        }
    }

    func testMarkInboxUnreadIntent_automationCommand() {
        let intent = MarkInboxUnreadIntent()

        if case .inbox(let action) = intent.automationCommand {
            XCTAssertEqual(action, .markUnread)
        } else {
            XCTFail("Expected inbox command")
        }
    }

    func testNextInboxItemIntent_automationCommand() {
        let intent = NextInboxItemIntent()

        if case .inbox(let action) = intent.automationCommand {
            XCTAssertEqual(action, .next)
        } else {
            XCTFail("Expected inbox command")
        }
    }

    func testPreviousInboxItemIntent_automationCommand() {
        let intent = PreviousInboxItemIntent()

        if case .inbox(let action) = intent.automationCommand {
            XCTAssertEqual(action, .previous)
        } else {
            XCTFail("Expected inbox command")
        }
    }

    func testOpenInboxItemIntent_automationCommand() {
        let intent = OpenInboxItemIntent()

        if case .inbox(let action) = intent.automationCommand {
            XCTAssertEqual(action, .open)
        } else {
            XCTFail("Expected inbox command")
        }
    }

    // MARK: - App Action Intents

    func testRefreshDataIntent_automationCommand() {
        let intent = RefreshDataIntent()

        if case .app(let action) = intent.automationCommand {
            XCTAssertEqual(action, .refresh)
        } else {
            XCTFail("Expected app command")
        }
    }

    func testExportLibraryIntent_automationCommand() {
        let intent = ExportLibraryIntent(format: .ris)

        if case .exportLibrary(let libraryID, let format) = intent.automationCommand {
            XCTAssertNil(libraryID)
            XCTAssertEqual(format, .ris)
        } else {
            XCTFail("Expected exportLibrary command")
        }
    }

    func testExportLibraryIntent_defaultFormat() {
        let intent = ExportLibraryIntent()

        if case .exportLibrary(_, let format) = intent.automationCommand {
            XCTAssertEqual(format, .bibtex)
        } else {
            XCTFail("Expected exportLibrary command")
        }
    }

    func testExportFormatOption_exportFormats() {
        XCTAssertEqual(ExportFormatOption.bibtex.exportFormat, .bibtex)
        XCTAssertEqual(ExportFormatOption.ris.exportFormat, .ris)
        XCTAssertEqual(ExportFormatOption.csv.exportFormat, .csv)
    }

    func testToggleSidebarIntent_automationCommand() {
        let intent = ToggleSidebarIntent()

        if case .app(let action) = intent.automationCommand {
            XCTAssertEqual(action, .toggleSidebar)
        } else {
            XCTFail("Expected app command")
        }
    }

    func testToggleDetailPaneIntent_automationCommand() {
        let intent = ToggleDetailPaneIntent()

        if case .app(let action) = intent.automationCommand {
            XCTAssertEqual(action, .toggleDetailPane)
        } else {
            XCTFail("Expected app command")
        }
    }

    func testToggleUnreadFilterIntent_automationCommand() {
        let intent = ToggleUnreadFilterIntent()

        if case .app(let action) = intent.automationCommand {
            XCTAssertEqual(action, .toggleUnreadFilter)
        } else {
            XCTFail("Expected app command")
        }
    }

    func testTogglePDFFilterIntent_automationCommand() {
        let intent = TogglePDFFilterIntent()

        if case .app(let action) = intent.automationCommand {
            XCTAssertEqual(action, .togglePDFFilter)
        } else {
            XCTFail("Expected app command")
        }
    }

    func testShowKeyboardShortcutsIntent_automationCommand() {
        let intent = ShowKeyboardShortcutsIntent()

        if case .app(let action) = intent.automationCommand {
            XCTAssertEqual(action, .showKeyboardShortcuts)
        } else {
            XCTFail("Expected app command")
        }
    }

    // MARK: - Intent Error

    func testIntentError_localizedDescriptions() {
        let disabledError = IntentError.automationDisabled
        let executionError = IntentError.executionFailed("test error")
        let paramError = IntentError.invalidParameter("query")
        let notFoundError = IntentError.paperNotFound("Einstein1905")

        // Verify they have non-empty descriptions
        XCTAssertFalse(String(localized: disabledError.localizedStringResource).isEmpty)
        XCTAssertFalse(String(localized: executionError.localizedStringResource).isEmpty)
        XCTAssertFalse(String(localized: paramError.localizedStringResource).isEmpty)
        XCTAssertFalse(String(localized: notFoundError.localizedStringResource).isEmpty)
    }

    // MARK: - Shortcuts Provider

    func testImbibShortcuts_hasShortcuts() {
        let shortcuts = ImbibShortcuts.appShortcuts
        XCTAssertFalse(shortcuts.isEmpty, "Should have at least one shortcut")
    }
}
