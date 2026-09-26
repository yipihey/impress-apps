#if os(macOS)
//
//  SurfaceRecordListRowsTests.swift
//  PublicationManagerCoreTests
//
//  A surface list row's date is the row's own (review PH-L5): a row with only
//  `created` was dated "now", so every such row read as today. A row with no
//  date at all shows none (wave 8, U3).
//

import ImpressMailStyle
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
        XCTAssertTrue(rows[0].isDated)
        XCTAssertTrue(rows[0].mailStyleConfiguration.showDate)
    }

    func testModifiedWinsAndFractionalSecondsParse() throws {
        let id = UUID().uuidString.lowercased()
        let json = """
            [{"id": "\(id)", "schema": "figure", "title": "Edited figure",
              "created": "2020-01-02T03:04:05Z", "modified": "2021-06-07T08:09:10.250Z"}]
            """
        let rows = try XCTUnwrap(SurfaceRecordListRows.map(json))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expected = try XCTUnwrap(formatter.date(from: "2021-06-07T08:09:10.250Z"))
        XCTAssertEqual(rows[0].date.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertTrue(rows[0].isDated)
    }

    /// No date, or none that parses: the row shows NO date — not "now".
    func testARowWithNoParseableDateShowsNoDate() throws {
        let json = """
            [{"id": "\(UUID().uuidString.lowercased())", "schema": "figure", "title": "No date"},
             {"id": "\(UUID().uuidString.lowercased())", "schema": "figure", "title": "Bad date",
              "modified": "last Tuesday"}]
            """
        let rows = try XCTUnwrap(SurfaceRecordListRows.map(json))
        XCTAssertEqual(rows.count, 2)
        for row in rows {
            XCTAssertFalse(row.isDated, "\(row.titleText) claims a date it does not have")
            XCTAssertFalse(
                row.mailStyleConfiguration.showDate, "\(row.titleText) would render a date column")
            XCTAssertGreaterThan(
                Date().timeIntervalSince(row.date), 86_400 * 365,
                "\(row.titleText)'s placeholder date reads as recent")
        }
    }

    /// Every other row keeps its date column: `isDated` defaults to true.
    func testARowBuiltWithoutSayingIsDated() {
        let row = KindTaggedRow(
            id: UUID(), kind: RecordKindID("figure"), headerText: "h", titleText: "t", date: Date())
        XCTAssertTrue(row.isDated)
        XCTAssertEqual(row.mailStyleConfiguration, .default)
    }

    func testAnUnmappableRowKeepsTheWholeListPlain() {
        XCTAssertNil(SurfaceRecordListRows.map(#"[{"id": "x", "title": "no schema"}]"#))
    }
}
#endif
