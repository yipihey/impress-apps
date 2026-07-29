//
//  ManuscriptCitationResolverTests.swift
//  PublicationManagerCoreTests
//
//  The resolve path behind imprint's citation inspection — and specifically the
//  part that has burned this project before: telling "no paper with that cite
//  key" apart from "no papers on this device at all".
//
//  On a fresh iOS install the publication table is EMPTY (imbib's CloudKit sync
//  ships default-off), so the second case is the common one. A resolver that
//  collapsed them would make the app tell users their citations are wrong.
//

import ImbibRustCore
import XCTest
@testable import PublicationManagerCore

@MainActor
final class ManuscriptCitationResolverTests: XCTestCase {

    // MARK: - Stub library

    /// A citation search with a known, tiny library.
    private final class StubSearch: ManuscriptCitationSearching {
        var rows: [String: BibliographyRow] = [:]
        /// nil models a host that installed a search but can't count.
        var count: Int?
        private(set) var lookups: [String] = []

        init(rows: [String: BibliographyRow] = [:], count: Int?) {
            self.rows = rows
            self.count = count
        }

        func findByCiteKey(_ citeKey: String) -> BibliographyRow? {
            lookups.append(citeKey)
            return rows[citeKey]
        }
        func search(_ query: String, limit: Int) -> [BibliographyRow] { [] }
        func libraryPublicationCount() -> Int? { count }
    }

    private func row(citeKey: String, title: String = "A Paper") -> BibliographyRow {
        BibliographyRow(
            id: UUID().uuidString,
            citeKey: citeKey,
            title: title,
            authorString: "Author, A.",
            year: 1905,
            abstractText: nil,
            isRead: false,
            isStarred: false,
            flagColor: nil,
            flagStyle: nil,
            flagLength: nil,
            hasDownloadedPdf: false,
            hasOtherAttachments: false,
            citationCount: 0,
            referenceCount: 0,
            doi: nil,
            arxivId: nil,
            bibcode: nil,
            venue: nil,
            note: nil,
            dateAdded: 0,
            dateModified: 0,
            primaryCategory: nil,
            categories: [],
            tags: [],
            libraryName: nil,
            enrichmentDate: nil,
            lastActivityAt: nil
        )
    }

    private var savedSearch: (any ManuscriptCitationSearching)?

    override func setUp() {
        super.setUp()
        savedSearch = ManuscriptEditorEnvironment.shared.citationSearch
    }

    override func tearDown() {
        ManuscriptEditorEnvironment.shared.citationSearch = savedSearch
        super.tearDown()
    }

    private func install(_ search: (any ManuscriptCitationSearching)?) {
        ManuscriptEditorEnvironment.shared.citationSearch = search
    }

    // MARK: - Hit

    func testResolvedReturnsTheRow() {
        let paper = row(citeKey: "einstein1905", title: "Zur Elektrodynamik bewegter Körper")
        install(StubSearch(rows: ["einstein1905": paper], count: 12))

        let resolution = ManuscriptCitationResolver.resolve("einstein1905")
        XCTAssertEqual(resolution.status, "resolved")
        XCTAssertEqual(resolution.row?.title, "Zur Elektrodynamik bewegter Körper")
        XCTAssertEqual(resolution.citeKey, "einstein1905")
    }

    func testLeadingSigilAndWhitespaceAreStrippedBeforeLookup() {
        let stub = StubSearch(rows: ["einstein1905": row(citeKey: "einstein1905")], count: 12)
        install(stub)

        // A key lifted straight out of Typst source arrives with its `@`.
        XCTAssertEqual(ManuscriptCitationResolver.resolve("@einstein1905").status, "resolved")
        XCTAssertEqual(ManuscriptCitationResolver.resolve("  einstein1905 \n").status, "resolved")
        XCTAssertEqual(
            stub.lookups, ["einstein1905", "einstein1905"],
            "the store must never be asked for a key with a sigil on it")
    }

    // MARK: - The two misses

    func testUnknownKeyInANonEmptyLibraryReportsTheCount() {
        install(StubSearch(rows: ["einstein1905": row(citeKey: "einstein1905")], count: 12))

        let resolution = ManuscriptCitationResolver.resolve("missing2099")
        XCTAssertEqual(resolution.status, "unknown-key")
        XCTAssertNil(resolution.row)
        guard case .unknownKey(let key, let count) = resolution else {
            return XCTFail("expected .unknownKey, got \(resolution)")
        }
        XCTAssertEqual(key, "missing2099")
        XCTAssertEqual(count, 12, "the claim comes with the evidence for it")
    }

    func testEmptyLibraryIsNotReportedAsAnUnknownKey() {
        // THE regression this file exists for. An empty store means the key was
        // never really tested — saying "not in your library" would be a lie.
        install(StubSearch(rows: [:], count: 0))

        let resolution = ManuscriptCitationResolver.resolve("einstein1905")
        XCTAssertEqual(resolution.status, "empty-library")
        XCTAssertNotEqual(resolution.status, "unknown-key")
        guard case .emptyLibrary(let key) = resolution else {
            return XCTFail("expected .emptyLibrary, got \(resolution)")
        }
        XCTAssertEqual(key, "einstein1905")
    }

    func testAnUncountableLibraryDegradesToUnknownKeyWithoutAFalseClaim() {
        // A host that wires search but not counting must not be reported as
        // empty — "unknown key, count unknown" is the only honest answer.
        install(StubSearch(rows: [:], count: nil))

        let resolution = ManuscriptCitationResolver.resolve("einstein1905")
        XCTAssertEqual(resolution.status, "unknown-key")
        guard case .unknownKey(_, let count) = resolution else {
            return XCTFail("expected .unknownKey, got \(resolution)")
        }
        XCTAssertNil(count)
    }

    func testNoCitationSearchInstalledIsItsOwnAnswer() {
        install(nil)
        let resolution = ManuscriptCitationResolver.resolve("einstein1905")
        XCTAssertEqual(resolution.status, "unavailable")
        XCTAssertNil(resolution.row)
    }

    // MARK: - Vocabulary parity with the Rust service

    func testStatusVocabularyMatchesTheRustServiceMethod() {
        // `imbib-search-service_resolve-cite-key` reports exactly these
        // strings. An agent and a human must be able to compare notes about the
        // same citation without a translation table.
        install(StubSearch(rows: ["k": row(citeKey: "k")], count: 3))
        XCTAssertEqual(ManuscriptCitationResolver.resolve("k").status, "resolved")
        install(StubSearch(rows: [:], count: 3))
        XCTAssertEqual(ManuscriptCitationResolver.resolve("k").status, "unknown-key")
        install(StubSearch(rows: [:], count: 0))
        XCTAssertEqual(ManuscriptCitationResolver.resolve("k").status, "empty-library")
    }

    // MARK: - Normalization

    func testNormalizeIsIdempotentAndSigilFree() {
        XCTAssertEqual(ManuscriptCitationResolver.normalize("@abc"), "abc")
        XCTAssertEqual(ManuscriptCitationResolver.normalize(" @abc "), "abc")
        XCTAssertEqual(ManuscriptCitationResolver.normalize("abc"), "abc")
        XCTAssertEqual(
            ManuscriptCitationResolver.normalize(ManuscriptCitationResolver.normalize("@@abc")),
            "abc",
            "a doubled sigil is not a cite key with an @ in it")
    }
}
