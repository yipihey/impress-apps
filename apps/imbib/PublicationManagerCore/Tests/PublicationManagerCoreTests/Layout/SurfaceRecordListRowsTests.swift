#if os(macOS)
//
//  SurfaceRecordListRowsTests.swift
//  PublicationManagerCoreTests
//
//  A surface list row's date is the row's own (review PH-L5): a row with only
//  `created` was dated "now", so every such row read as today.
//

import XCTest

@testable import PublicationManagerCore

@MainActor
final class SurfaceRecordListRowsTests: XCTestCase {

    func testARowWithOnlyACreatedDateIsDatedByIt() throws {
        let id = UUID().uuidString.lowercased()
        let json = """
            [{"id": "\(id)", "schema": "figure", "title": "Old figure",
              "created": "2020-01-02T03:04:05Z"}]
            """
        let rows = try XCTUnwrap(SurfaceRecordListRows.map(json))
        XCTAssertEqual(rows.count, 1)
        let expected = try XCTUnwrap(ISO8601DateFormatter().date(from: "2020-01-02T03:04:05Z"))
        XCTAssertEqual(rows[0].date, expected, "the row was dated when it was read, not when it was made")
    }

    func testAnUnmappableRowKeepsTheWholeListPlain() {
        XCTAssertNil(SurfaceRecordListRows.map(#"[{"id": "x", "title": "no schema"}]"#))
    }
}
#endif
