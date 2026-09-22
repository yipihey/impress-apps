//
//  LayoutPaneRowMapperTests.swift
//  PublicationManagerCoreTests
//
//  The pane row mapping, which is where a layout pane stops looking like a
//  debug list and starts looking like imbib.
//
//  Two of these pin bugs that shipped and were invisible: a payload key read
//  under the wrong spelling (every row's author line said "Publication"), and
//  a kind published in the wrong vocabulary (`imbib/library` where the pane
//  parameter declares `library`, so the list stayed empty with a row
//  selected). Neither produced an error anywhere — which is exactly why they
//  need a test rather than another look at the screen.
//

#if os(macOS)
import ImpressFTUI
import ImpressRustCore
import XCTest

@testable import PublicationManagerCore

@MainActor
final class LayoutPaneRowMapperTests: XCTestCase {

    private func row(
        schemaRef: String = "imbib/bibliography-entry",
        payload: String,
        isRead: Bool = true,
        isStarred: Bool = false,
        tags: [String] = [],
        flagColor: String? = nil
    ) -> SharedItemRow {
        SharedItemRow(
            id: UUID().uuidString,
            schemaRef: schemaRef,
            payloadJson: payload,
            createdMs: 1_700_000_000_000,
            modifiedMs: 1_700_000_500_000,
            parentId: nil,
            isRead: isRead,
            isStarred: isStarred,
            tags: tags,
            flagColor: flagColor)
    }

    // MARK: Publication payloads

    func testAuthorLineComesFromImbibsOwnSpelling() throws {
        // `author_text` is what imbib writes; reading only `authors`/`author`
        // is what made every pane row's header read "Publication".
        let mapped = try XCTUnwrap(
            LayoutPaneRowMapper.kindTaggedRow(
                row(payload: #"{"author_text":"Abbasi, R.; Ackermann, M.","title":"T"}"#)))
        XCTAssertEqual(mapped.headerText, "Abbasi, R.; Ackermann, M.")
        XCTAssertEqual(mapped.titleText, "T")
    }

    func testAuthorsJsonIsParsedWhenTheTextFormIsAbsent() throws {
        let mapped = try XCTUnwrap(
            LayoutPaneRowMapper.kindTaggedRow(
                row(payload: #"{"authors_json":"[\"Bish, H.\",\"Peek, J.\"]","title":"T"}"#)))
        XCTAssertEqual(mapped.headerText, "Bish, H.; Peek, J.")
    }

    func testVenueAndAbstractFillTheSubtitleAndPreview() throws {
        let mapped = try XCTUnwrap(
            LayoutPaneRowMapper.kindTaggedRow(
                row(
                    payload: #"""
                    {"title":"T","venue":"arXiv","abstract_text":"We present a model.","year":"2026"}
                    """#)))
        XCTAssertEqual(mapped.subtitleText, "arXiv")
        XCTAssertEqual(mapped.previewText, "We present a model.")
        XCTAssertEqual(mapped.yearText, "2026")
    }

    func testYearReadsAsAStringWhetherSerdeWroteOneOrANumber() throws {
        let asNumber = try XCTUnwrap(
            LayoutPaneRowMapper.kindTaggedRow(row(payload: #"{"title":"T","year":2026}"#)))
        XCTAssertEqual(asNumber.yearText, "2026")
    }

    // MARK: Envelope fields — the ones that work for EVERY kind

    func testReadStateStarFlagAndTagsComeFromTheEnvelope() throws {
        let mapped = try XCTUnwrap(
            LayoutPaneRowMapper.kindTaggedRow(
                row(
                    payload: #"{"title":"T"}"#,
                    isRead: false,
                    isStarred: true,
                    tags: ["ai/topic/galaxies"],
                    flagColor: "red")))
        XCTAssertFalse(mapped.isRead)
        XCTAssertTrue(mapped.isStarred)
        XCTAssertEqual(mapped.flag?.color, .red)
        XCTAssertEqual(mapped.tagDisplays.map(\.leaf), ["galaxies"])
        XCTAssertEqual(mapped.tagDisplays.first?.path, "ai/topic/galaxies")
    }

    func testAnUnknownFlagColourIsNoFlagRatherThanAnInventedOne() throws {
        let mapped = try XCTUnwrap(
            LayoutPaneRowMapper.kindTaggedRow(
                row(payload: #"{"title":"T"}"#, flagColor: "chartreuse")))
        XCTAssertNil(mapped.flag)
    }

    func testARowWhoseIdIsNotAUUIDIsDropped() {
        let bad = SharedItemRow(
            id: "not-a-uuid",
            schemaRef: "imbib/bibliography-entry",
            payloadJson: #"{"title":"T"}"#,
            createdMs: 0,
            modifiedMs: 0,
            parentId: nil,
            isRead: true,
            isStarred: false,
            tags: [],
            flagColor: nil)
        XCTAssertNil(LayoutPaneRowMapper.kindTaggedRow(bad))
    }

    // MARK: The layout's kind vocabulary

    func testSchemaRefsMapToTheLAYOUTSKindIdsNotTheChassisOnes() {
        // The manifest is Rust's (`impress_core::pane_query::KindManifest`),
        // read over the FFI. `library`, not `imbib/library`: a pane parameter
        // declares the former, and publishing the latter binds nothing.
        XCTAssertEqual(
            LayoutPaneRowMapper.layoutKind(forSchemaRef: "imbib/bibliography-entry"),
            "publication")
        XCTAssertEqual(LayoutPaneRowMapper.layoutKind(forSchemaRef: "imbib/library"), "library")
        XCTAssertEqual(
            LayoutPaneRowMapper.layoutKind(forSchemaRef: "imbib/collection"), "collection")
    }

    func testAVersionedSchemaRefStillResolves() {
        XCTAssertEqual(LayoutPaneRowMapper.layoutKind(forSchemaRef: "task@1.0.0"), "task")
        XCTAssertEqual(LayoutPaneRowMapper.layoutKind(forSchemaRef: "task"), "task")
    }

    func testAnUnclaimedSchemaRefHasNoLayoutKind() {
        XCTAssertNil(LayoutPaneRowMapper.layoutKind(forSchemaRef: "nobody/owns-this"))
    }
}
#endif
