//
//  CiteKeyNearMissTests.swift
//  PublicationManagerCoreTests
//
//  The near misses that blank a manuscript: a year cut off, one character
//  wrong, a trailing colon the scanner kept. Each must name the library key.
//  Two equally close keys must not be guessed.
//

import ImbibRustCore
import XCTest
@testable import PublicationManagerCore

@MainActor
final class CiteKeyNearMissTests: XCTestCase {

    func testACutOffYearSuggestsTheLibraryKey() {
        XCTAssertEqual(
            CiteKeyNearMiss.suggest(
                query: "AminJainKarurMocz202",
                candidates: ["AminJainKarurMocz2022", "HuBarkanaGruzinov2000"]),
            "AminJainKarurMocz2022")
    }

    func testOneWrongCharacterSuggestsTheLibraryKey() {
        XCTAssertEqual(
            CiteKeyNearMiss.suggest(
                query: "GosencPaEtAl2023",
                candidates: ["GosencaEtAl2023", "EberhardtGosencaHui2026"]),
            "GosencaEtAl2023")
    }

    func testATrailingColonSuggestsTheCleanKey() {
        let stub = StubSearch(rows: [
            "AlonStreltsovCederbaum2008": row(citeKey: "AlonStreltsovCederbaum2008"),
        ])
        let suggested = CiteKeyNearMiss.suggestion(
            for: "AlonStreltsovCederbaum2008:", in: stub)
        XCTAssertEqual(suggested?.citeKey, "AlonStreltsovCederbaum2008")
    }

    func testAnExactKeyIsNotASuggestion() {
        let stub = StubSearch(rows: [
            "GosencaEtAl2023": row(citeKey: "GosencaEtAl2023"),
        ])
        XCTAssertNil(CiteKeyNearMiss.suggestion(for: "GosencaEtAl2023", in: stub))
        XCTAssertNil(CiteKeyNearMiss.suggestion(for: "@GosencaEtAl2023", in: stub))
    }

    func testAPrefixProbeFindsAKeyTheFullMissDoesNotContain() {
        // `GosencPa…` is not a substring of `Gosenca…`. The six-character
        // probe is what reaches it.
        let stub = StubSearch(rows: [
            "GosencaEtAl2023": row(citeKey: "GosencaEtAl2023", title: "Multifield Ultralight Dark Matter"),
            "EberhardtGosencaHui2026": row(citeKey: "EberhardtGosencaHui2026"),
        ])
        let suggested = CiteKeyNearMiss.suggestion(for: "GosencPaEtAl2023", in: stub)
        XCTAssertEqual(suggested?.citeKey, "GosencaEtAl2023")
    }

    func testTwoEquallyCloseKeysAreNotGuessed() {
        XCTAssertNil(
            CiteKeyNearMiss.suggest(
                query: "Smith202",
                candidates: ["Smith2020", "Smith2021"]))
    }

    func testAShortTokenIsNotASuggestion() {
        XCTAssertNil(
            CiteKeyNearMiss.suggest(
                query: "preview",
                candidates: ["HuBarkanaGruzinov2000"]))
    }

    private func row(citeKey: String, title: String = "A Paper") -> BibliographyRow {
        BibliographyRow(
            id: citeKey,
            citeKey: citeKey,
            title: title,
            authorString: "Author, A.",
            year: 2023,
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
            lastActivityAt: nil,
            einkState: nil
        )
    }

    /// Search answers the way cite-key LIKE does: a candidate whose key
    /// contains the query.
    private final class StubSearch: ManuscriptCitationSearching {
        var rows: [String: BibliographyRow]
        init(rows: [String: BibliographyRow]) { self.rows = rows }

        func findByCiteKey(_ citeKey: String) -> BibliographyRow? { rows[citeKey] }

        func search(_ query: String, limit: Int) -> [BibliographyRow] {
            let needle = query.lowercased()
            return Array(rows.values.filter { $0.citeKey.lowercased().contains(needle) }.prefix(limit))
        }

        func libraryPublicationCount() -> Int? { rows.count }
    }
}
