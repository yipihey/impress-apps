//
//  AutomationPaperResultTests.swift
//  PublicationManagerCoreTests
//
//  `GET /api/papers/{citeKey}` and `GET /api/search` build their papers with
//  one conversion, and it returned two wrong fields (seen live 2026-09-11 on
//  AminJainKarurMocz2022):
//
//  - `authors` split the store's "Family, Given; Family, Given" author text
//    on the comma, so four authors came back as five fragments;
//  - `libraryIDs` (and `collectionIDs`) were hard-coded `[]`, because the list
//    row carries no membership, although the paper's store parent is a
//    library.
//

import ImbibRustCore
import XCTest

@testable import PublicationManagerCore

final class AutomationPaperResultTests: XCTestCase {

    private let authorText = "Amin, Mustafa A.; Jain, Mudit; Karur, Rohith; Mocz, Philip"
    private let authors = ["Amin, Mustafa A.", "Jain, Mudit", "Karur, Rohith", "Mocz, Philip"]

    // MARK: - The conversion

    func testAuthorTextSplitsOnTheSemicolonNotTheComma() {
        XCTAssertEqual(AutomationService.authorNames(fromAuthorText: authorText), authors)
    }

    func testAuthorTextToleratesMissingSpacesAndEmptyEntries() {
        XCTAssertEqual(
            AutomationService.authorNames(fromAuthorText: "Amin, M.;Jain, M.; ;"),
            ["Amin, M.", "Jain, M."])
        XCTAssertEqual(AutomationService.authorNames(fromAuthorText: ""), [])
    }

    func testDetailSuppliesMembershipAndAuthors() {
        let id = UUID()
        let library = UUID()
        let collection = UUID()
        let row = PublicationRowData(id: id, citeKey: "AminJainKarurMocz2022", authorString: authorText)
        let detail = PublicationModel(from: PublicationDetail(
            id: id.uuidString, citeKey: "AminJainKarurMocz2022", entryType: "article",
            fields: ["author_text": authorText], isRead: false, isStarred: false,
            flagColor: nil, flagStyle: nil, flagLength: nil, tags: [],
            authors: [
                AuthorRow(givenName: "Mustafa A.", familyName: "Amin", suffix: nil, orcid: nil, affiliation: nil),
                AuthorRow(givenName: "Mudit", familyName: "Jain", suffix: nil, orcid: nil, affiliation: nil),
                AuthorRow(givenName: "Rohith", familyName: "Karur", suffix: nil, orcid: nil, affiliation: nil),
                AuthorRow(givenName: "Philip", familyName: "Mocz", suffix: nil, orcid: nil, affiliation: nil),
            ],
            dateAdded: 0, dateModified: 0, linkedFiles: [], citationCount: 0, referenceCount: 0,
            rawBibtex: nil, collections: [collection.uuidString], libraries: [library.uuidString]))

        let paper = AutomationService.toPaperResult(row, detail: detail)

        XCTAssertEqual(paper.authors, authors)
        XCTAssertEqual(paper.libraryIDs, [library])
        XCTAssertEqual(paper.collectionIDs, [collection])
    }

    func testWithoutADetailTheRowTextIsSplitAndNoMembershipIsGuessed() {
        let row = PublicationRowData(id: UUID(), citeKey: "AminJainKarurMocz2022", authorString: authorText)

        let paper = AutomationService.toPaperResult(row, detail: nil)

        XCTAssertEqual(paper.authors, authors)
        XCTAssertEqual(paper.libraryIDs, [])
        XCTAssertEqual(paper.collectionIDs, [])
    }

    // MARK: - Through the store, as the routes run it

    @MainActor
    func testGetPaperAndSearchReportEveryAuthorAndTheLibrary() async throws {
        // AppIntentsIntegrationTests leaves automation DISABLED in the shared
        // defaults, and a disabled service refuses every call.
        let settings = AutomationSettingsStore.shared
        let wasEnabled = await settings.isEnabled
        await settings.setEnabled(true)
        addTeardownBlock { await settings.setEnabled(wasEnabled) }

        let adapter = RustStoreAdapter.shared
        let tag = UUID().uuidString.prefix(8)
        guard let library = adapter.createLibrary(name: "Automation paper result \(tag)") else {
            throw XCTSkip("no writable store in this environment")
        }
        let citeKey = "AminJainKarurMocz2022\(tag)"
        let titleWord = "Soliton\(tag)"
        let ids = adapter.importBibTeX(
            """
            @article{\(citeKey),
              author = {Amin, Mustafa A. and Jain, Mudit and Karur, Rohith and Mocz, Philip},
              title = {\(titleWord) formation in ultralight dark matter},
              year = {2022}
            }
            """,
            libraryId: library.id)
        try XCTSkipIf(ids.isEmpty, "import produced nothing in this environment")
        guard let collection = adapter.createCollection(name: "Solitons \(tag)", libraryId: library.id) else {
            throw XCTSkip("no collection in this environment")
        }
        adapter.addToCollection(publicationIds: ids, collectionId: collection.id)

        let service = AutomationService.shared

        let paper = try await service.getPaper(identifier: .citeKey(citeKey))
        XCTAssertEqual(paper?.authors, authors)
        XCTAssertEqual(paper?.libraryIDs, [library.id], "the paper's store parent is its library")
        XCTAssertEqual(paper?.collectionIDs, [collection.id])

        let hits = try await service.searchLibrary(query: titleWord, filters: nil)
        XCTAssertEqual(hits.map(\.citeKey), [citeKey])
        XCTAssertEqual(hits.first?.authors, authors)
        XCTAssertEqual(hits.first?.libraryIDs, [library.id])
    }
}
