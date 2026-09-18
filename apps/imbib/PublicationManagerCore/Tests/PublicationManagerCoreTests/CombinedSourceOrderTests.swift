//
//  CombinedSourceOrderTests.swift
//  PublicationManagerCoreTests
//
//  A multi-library selection (`PublicationSource.combined`) is an ordinary
//  list, so its sort menu has to mean what it means everywhere else. It did
//  not: `queryCombined` merged the children and sorted by date-added whatever
//  the caller asked for, so picking "Recently Used" (or Title, or Year) in a
//  combined scope silently changed nothing — the worst kind of option.
//
//  Every case ends at dateAdded and then id, so the order is TOTAL: a paper
//  with no value for the field keeps a stable place instead of reshuffling
//  between pages of a scrolling list.
//

import XCTest
@testable import PublicationManagerCore

final class CombinedSourceOrderTests: XCTestCase {

    private func row(
        _ label: String,
        added: TimeInterval,
        activity: TimeInterval? = nil,
        title: String = "Untitled",
        year: Int? = nil,
        citations: Int = 0,
        starred: Bool = false
    ) -> PublicationRowData {
        PublicationRowData(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000\(label)")
                ?? UUID(),
            citeKey: "key\(label)",
            title: title,
            year: year,
            isStarred: starred,
            citationCount: citations,
            dateAdded: Date(timeIntervalSince1970: added),
            dateModified: Date(timeIntervalSince1970: added),
            lastActivityAt: activity.map { Date(timeIntervalSince1970: $0) }
        )
    }

    /// Descending order under `sort`, the way `queryCombined` builds its cache.
    private func ordered(_ rows: [PublicationRowData], sort: String) -> [String] {
        rows.sorted { RustStoreAdapter.combinedIsBefore($0, $1, sort: sort) }
            .map(\.citeKey)
    }

    func testRecentlyUsedPutsTouchedPapersFirstAndUntouchedLast() {
        let rows = [
            row("01", added: 300, activity: nil),
            row("02", added: 100, activity: 900),
            row("03", added: 200, activity: 500),
        ]
        XCTAssertEqual(
            ordered(rows, sort: "last_activity"), ["key02", "key03", "key01"],
            "most recently used first; never-touched last, as SQLite's NULLs-last DESC gives")
        // The other spellings the Rust layer accepts must behave identically,
        // because the caller passes whichever its enum produced.
        XCTAssertEqual(ordered(rows, sort: "recent"), ["key02", "key03", "key01"])
        XCTAssertEqual(ordered(rows, sort: "lastActivity"), ["key02", "key03", "key01"])
    }

    func testUntouchedPapersKeepADeterministicOrderAmongThemselves() {
        let rows = [
            row("04", added: 100, activity: nil),
            row("05", added: 300, activity: nil),
            row("06", added: 200, activity: nil),
        ]
        // Falls through to date-added, so the tail of a recency sort is stable
        // across page loads rather than arbitrary.
        XCTAssertEqual(ordered(rows, sort: "last_activity"), ["key05", "key06", "key04"])
    }

    func testTheOtherSortsAreHonouredToo() {
        let rows = [
            row("07", added: 100, title: "Beta", year: 2001, citations: 5),
            row("08", added: 200, title: "Alpha", year: 2020, citations: 1),
            row("09", added: 300, title: "Gamma", year: nil, citations: 9, starred: true),
        ]
        XCTAssertEqual(ordered(rows, sort: "year"), ["key08", "key07", "key09"],
                       "no year sorts last, like a NULL")
        XCTAssertEqual(ordered(rows, sort: "citation_count"), ["key09", "key07", "key08"])
        XCTAssertEqual(ordered(rows, sort: "starred"), ["key09", "key08", "key07"],
                       "starred first, then date-added within each group")
        // Title's cache is built descending and reversed for the ascending
        // default, so the cache itself reads Z→A.
        XCTAssertEqual(ordered(rows, sort: "title"), ["key09", "key07", "key08"])
        XCTAssertEqual(ordered(rows, sort: "created"), ["key09", "key08", "key07"])
    }

    func testAnUnknownSortFallsBackToDateAddedRatherThanAnArbitraryOrder() {
        let rows = [
            row("10", added: 100),
            row("11", added: 300),
            row("12", added: 200),
        ]
        XCTAssertEqual(ordered(rows, sort: "no-such-field"), ["key11", "key12", "key10"])
    }
}
