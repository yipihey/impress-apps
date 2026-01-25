//
//  URLCommandParserTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-09.
//

import XCTest
@testable import PublicationManagerCore

final class URLCommandParserTests: XCTestCase {

    let parser = URLCommandParser()

    // MARK: - Scheme Validation

    func testInvalidScheme_throwsError() throws {
        let url = URL(string: "http://search?query=test")!
        XCTAssertThrowsError(try parser.parse(url)) { error in
            guard case AutomationError.invalidScheme(let scheme) = error else {
                XCTFail("Expected invalidScheme error")
                return
            }
            XCTAssertEqual(scheme, "http")
        }
    }

    func testValidScheme_parses() throws {
        let url = URL(string: "imbib://search?query=test")!
        let command = try parser.parse(url)
        if case .search(let query, _, _) = command {
            XCTAssertEqual(query, "test")
        } else {
            XCTFail("Expected search command")
        }
    }

    // MARK: - Search Command

    func testSearchCommand_withQuery() throws {
        let url = URL(string: "imbib://search?query=dark%20matter")!
        let command = try parser.parse(url)

        if case .search(let query, let source, let maxResults) = command {
            XCTAssertEqual(query, "dark matter")
            XCTAssertNil(source)
            XCTAssertNil(maxResults)
        } else {
            XCTFail("Expected search command")
        }
    }

    func testSearchCommand_withAllParams() throws {
        let url = URL(string: "imbib://search?query=einstein&source=ads&max=50")!
        let command = try parser.parse(url)

        if case .search(let query, let source, let maxResults) = command {
            XCTAssertEqual(query, "einstein")
            XCTAssertEqual(source, "ads")
            XCTAssertEqual(maxResults, 50)
        } else {
            XCTFail("Expected search command")
        }
    }

    func testSearchCommand_missingQuery_throwsError() throws {
        let url = URL(string: "imbib://search?source=ads")!
        XCTAssertThrowsError(try parser.parse(url)) { error in
            guard case AutomationError.missingParameter(let param) = error else {
                XCTFail("Expected missingParameter error")
                return
            }
            XCTAssertEqual(param, "query")
        }
    }

    // MARK: - Navigation Command

    func testNavigateCommand_library() throws {
        let url = URL(string: "imbib://navigate/library")!
        let command = try parser.parse(url)

        if case .navigate(let target) = command {
            XCTAssertEqual(target, .library)
        } else {
            XCTFail("Expected navigate command")
        }
    }

    func testNavigateCommand_inbox() throws {
        let url = URL(string: "imbib://navigate/inbox")!
        let command = try parser.parse(url)

        if case .navigate(let target) = command {
            XCTAssertEqual(target, .inbox)
        } else {
            XCTFail("Expected navigate command")
        }
    }

    func testNavigateCommand_pdfTab() throws {
        let url = URL(string: "imbib://navigate/pdf-tab")!
        let command = try parser.parse(url)

        if case .navigate(let target) = command {
            XCTAssertEqual(target, .pdfTab)
        } else {
            XCTFail("Expected navigate command")
        }
    }

    func testNavigateCommand_invalidTarget() throws {
        let url = URL(string: "imbib://navigate/invalid")!
        XCTAssertThrowsError(try parser.parse(url)) { error in
            guard case AutomationError.invalidParameter(let param, _) = error else {
                XCTFail("Expected invalidParameter error")
                return
            }
            XCTAssertEqual(param, "target")
        }
    }

    // MARK: - Focus Command

    func testFocusCommand_sidebar() throws {
        let url = URL(string: "imbib://focus/sidebar")!
        let command = try parser.parse(url)

        if case .focus(let target) = command {
            XCTAssertEqual(target, .sidebar)
        } else {
            XCTFail("Expected focus command")
        }
    }

    func testFocusCommand_search() throws {
        let url = URL(string: "imbib://focus/search")!
        let command = try parser.parse(url)

        if case .focus(let target) = command {
            XCTAssertEqual(target, .search)
        } else {
            XCTFail("Expected focus command")
        }
    }

    // MARK: - Paper Command

    func testPaperCommand_openPDF() throws {
        let url = URL(string: "imbib://paper/Einstein1905/open-pdf")!
        let command = try parser.parse(url)

        if case .paper(let citeKey, let action) = command {
            XCTAssertEqual(citeKey, "Einstein1905")
            if case .openPDF = action {
                // Success
            } else {
                XCTFail("Expected openPDF action")
            }
        } else {
            XCTFail("Expected paper command")
        }
    }

    func testPaperCommand_toggleRead() throws {
        let url = URL(string: "imbib://paper/TestKey/toggle-read")!
        let command = try parser.parse(url)

        if case .paper(let citeKey, let action) = command {
            XCTAssertEqual(citeKey, "TestKey")
            if case .toggleRead = action {
                // Success
            } else {
                XCTFail("Expected toggleRead action")
            }
        } else {
            XCTFail("Expected paper command")
        }
    }

    func testPaperCommand_keep() throws {
        let libraryID = UUID()
        let url = URL(string: "imbib://paper/TestKey/keep?library=\(libraryID.uuidString)")!
        let command = try parser.parse(url)

        if case .paper(let citeKey, let action) = command {
            XCTAssertEqual(citeKey, "TestKey")
            if case .keep(let id) = action {
                XCTAssertEqual(id, libraryID)
            } else {
                XCTFail("Expected keep action")
            }
        } else {
            XCTFail("Expected paper command")
        }
    }

    func testPaperCommand_addToCollection() throws {
        let collectionID = UUID()
        let url = URL(string: "imbib://paper/TestKey/add-to-collection?collection=\(collectionID.uuidString)")!
        let command = try parser.parse(url)

        if case .paper(let citeKey, let action) = command {
            XCTAssertEqual(citeKey, "TestKey")
            if case .addToCollection(let id) = action {
                XCTAssertEqual(id, collectionID)
            } else {
                XCTFail("Expected addToCollection action")
            }
        } else {
            XCTFail("Expected paper command")
        }
    }

    // MARK: - Selected Command

    func testSelectedCommand_toggleRead() throws {
        let url = URL(string: "imbib://selected/toggle-read")!
        let command = try parser.parse(url)

        if case .selectedPapers(let action) = command {
            XCTAssertEqual(action, .toggleRead)
        } else {
            XCTFail("Expected selectedPapers command")
        }
    }

    func testSelectedCommand_delete() throws {
        let url = URL(string: "imbib://selected/delete")!
        let command = try parser.parse(url)

        if case .selectedPapers(let action) = command {
            XCTAssertEqual(action, .delete)
        } else {
            XCTFail("Expected selectedPapers command")
        }
    }

    // MARK: - Inbox Command

    func testInboxCommand_show() throws {
        let url = URL(string: "imbib://inbox/show")!
        let command = try parser.parse(url)

        if case .inbox(let action) = command {
            XCTAssertEqual(action, .show)
        } else {
            XCTFail("Expected inbox command")
        }
    }

    func testInboxCommand_keep() throws {
        let url = URL(string: "imbib://inbox/keep")!
        let command = try parser.parse(url)

        if case .inbox(let action) = command {
            XCTAssertEqual(action, .keep)
        } else {
            XCTFail("Expected inbox command")
        }
    }

    func testInboxCommand_defaultToShow() throws {
        let url = URL(string: "imbib://inbox")!
        let command = try parser.parse(url)

        if case .inbox(let action) = command {
            XCTAssertEqual(action, .show)
        } else {
            XCTFail("Expected inbox command")
        }
    }

    // MARK: - PDF Command

    func testPDFCommand_goToPage() throws {
        let url = URL(string: "imbib://pdf/go-to-page?page=42")!
        let command = try parser.parse(url)

        if case .pdf(let action) = command {
            if case .goToPage(let page) = action {
                XCTAssertEqual(page, 42)
            } else {
                XCTFail("Expected goToPage action")
            }
        } else {
            XCTFail("Expected pdf command")
        }
    }

    func testPDFCommand_zoomIn() throws {
        let url = URL(string: "imbib://pdf/zoom-in")!
        let command = try parser.parse(url)

        if case .pdf(let action) = command {
            if case .zoomIn = action {
                // Success
            } else {
                XCTFail("Expected zoomIn action")
            }
        } else {
            XCTFail("Expected pdf command")
        }
    }

    // MARK: - App Command

    func testAppCommand_refresh() throws {
        let url = URL(string: "imbib://app/refresh")!
        let command = try parser.parse(url)

        if case .app(let action) = command {
            XCTAssertEqual(action, .refresh)
        } else {
            XCTFail("Expected app command")
        }
    }

    func testAppCommand_toggleSidebar() throws {
        let url = URL(string: "imbib://app/toggle-sidebar")!
        let command = try parser.parse(url)

        if case .app(let action) = command {
            XCTAssertEqual(action, .toggleSidebar)
        } else {
            XCTFail("Expected app command")
        }
    }

    // MARK: - Import Command

    func testImportCommand_bibtex() throws {
        let url = URL(string: "imbib://import?format=bibtex")!
        let command = try parser.parse(url)

        if case .importBibTeX = command {
            // Success
        } else {
            XCTFail("Expected importBibTeX command")
        }
    }

    func testImportCommand_ris() throws {
        let url = URL(string: "imbib://import?format=ris")!
        let command = try parser.parse(url)

        if case .importRIS = command {
            // Success
        } else {
            XCTFail("Expected importRIS command")
        }
    }

    func testImportCommand_withLibrary() throws {
        let libraryID = UUID()
        let url = URL(string: "imbib://import?format=bibtex&library=\(libraryID.uuidString)")!
        let command = try parser.parse(url)

        if case .importBibTeX(_, _, let id) = command {
            XCTAssertEqual(id, libraryID)
        } else {
            XCTFail("Expected importBibTeX command")
        }
    }

    // MARK: - Export Command

    func testExportCommand_bibtex() throws {
        let url = URL(string: "imbib://export?format=bibtex")!
        let command = try parser.parse(url)

        if case .exportLibrary(_, let format) = command {
            XCTAssertEqual(format, .bibtex)
        } else {
            XCTFail("Expected exportLibrary command")
        }
    }

    func testExportCommand_ris() throws {
        let url = URL(string: "imbib://export?format=ris")!
        let command = try parser.parse(url)

        if case .exportLibrary(_, let format) = command {
            XCTAssertEqual(format, .ris)
        } else {
            XCTFail("Expected exportLibrary command")
        }
    }

    // MARK: - Unknown Command

    func testUnknownCommand_throwsError() throws {
        let url = URL(string: "imbib://unknown-command")!
        XCTAssertThrowsError(try parser.parse(url)) { error in
            guard case AutomationError.unknownCommand(let cmd) = error else {
                XCTFail("Expected unknownCommand error")
                return
            }
            XCTAssertEqual(cmd, "unknown-command")
        }
    }

    // MARK: - Search Category Command

    func testSearchCategoryCommand() throws {
        let url = URL(string: "imbib://search-category?category=astro-ph.CO")!
        let command = try parser.parse(url)

        if case .searchCategory(let category) = command {
            XCTAssertEqual(category, "astro-ph.CO")
        } else {
            XCTFail("Expected searchCategory command")
        }
    }

    // MARK: - Collection Command

    func testCollectionCommand_show() throws {
        let collectionID = UUID()
        let url = URL(string: "imbib://collection/\(collectionID.uuidString)/show")!
        let command = try parser.parse(url)

        if case .collection(let id, let action) = command {
            XCTAssertEqual(id, collectionID)
            XCTAssertEqual(action, .show)
        } else {
            XCTFail("Expected collection command")
        }
    }

    func testCollectionCommand_addSelected() throws {
        let collectionID = UUID()
        let url = URL(string: "imbib://collection/\(collectionID.uuidString)/add-selected")!
        let command = try parser.parse(url)

        if case .collection(let id, let action) = command {
            XCTAssertEqual(id, collectionID)
            XCTAssertEqual(action, .addSelected)
        } else {
            XCTFail("Expected collection command")
        }
    }
}
