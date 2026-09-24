#if os(macOS)
//
//  LayoutPaneScopeTests.swift
//  PublicationManagerCoreTests
//
//  A `list` pane's row menu runs the legacy list's delete / dismiss / save
//  sequences, which differ by scope (plan wave 6, W4). The scope is read off
//  the pane's query — these pin that reading, with the query JSON spelled as
//  `impress_pane_query::PaneQuery` serializes it.
//
//  FFI-free: `LayoutPaneScope` is a pure function of the query.
//

import XCTest
@testable import PublicationManagerCore

final class LayoutPaneScopeTests: XCTestCase {

    private let inbox = UUID(uuidString: "800E8F6E-983F-4F34-98F1-52DB1113EDB4")!
    private let dismissed = UUID(uuidString: "2B0FA9E6-07BA-45CD-A049-B0D00B4C18E4")!
    private let library = UUID(uuidString: "1AD5E936-0F53-4FDC-BE37-D1217D2D33FA")!
    private let collection = UUID(uuidString: "446BA33C-0000-4000-8000-000000000001")!

    private func query(_ json: String) -> LayoutJSONValue {
        try! LayoutJSONValue.decode(json)
    }

    private func source(_ json: String, bindings: [String: String] = [:]) -> PublicationSource {
        LayoutPaneScope.source(
            query: query(json),
            bindings: bindings,
            isInboxLibrary: { $0 == self.inbox },
            dismissedLibraryID: dismissed)
    }

    /// Lowercase, as the store writes ids.
    private func id(_ uuid: UUID) -> String { uuid.uuidString.lowercased() }

    func testALibraryParentIsThatLibrary() {
        let json = #"{"kinds":["publication"],"scope":{"scope":"parent","id":{"ref":"id","id":"\#(id(library))"}},"filters":[]}"#
        XCTAssertEqual(source(json), .library(library))
        // A figure folder is a parent scope too.
        XCTAssertEqual(LayoutPaneScope.parentID(query: query(json), bindings: [:]), library)
        XCTAssertNil(LayoutPaneScope.collectionID(query: query(json), bindings: [:]))
    }

    /// The Inbox is a library, and its list is the one with Save and Mute.
    func testTheInboxLibraryIsTheInbox() {
        let json = #"{"kinds":["publication"],"scope":{"scope":"parent","id":{"ref":"id","id":"\#(id(inbox))"}},"filters":[{"filter":"read","read":false}]}"#
        XCTAssertEqual(source(json), .inbox(inbox))
    }

    /// Dismissed is where Delete is permanent.
    func testTheDismissedLibraryIsDismissed() {
        let json = #"{"kinds":["publication"],"scope":{"scope":"parent","id":{"ref":"id","id":"\#(id(dismissed))"}},"filters":[]}"#
        XCTAssertEqual(source(json), .dismissed)
    }

    /// A delete in a collection also removes its `Contains` edge.
    func testACollectionScopeIsThatCollection() {
        let json = #"{"kinds":["publication"],"scope":{"scope":"collection","id":{"ref":"id","id":"\#(id(collection))"}},"filters":[]}"#
        XCTAssertEqual(source(json), .collection(collection))
        XCTAssertEqual(
            LayoutPaneScope.collectionID(query: query(json), bindings: [:]), collection)
    }

    /// A parameter is read from the pane's bindings.
    func testAParameterScopeReadsTheBinding() {
        let json = #"{"kinds":["publication"],"scope":{"scope":"parent","id":{"ref":"param","name":"library"}},"filters":[]}"#
        XCTAssertEqual(source(json, bindings: ["library": id(library)]), .library(library))
        // Unbound: no container, so no container's steps.
        XCTAssertEqual(source(json), .combined([]))
    }

    func testFiltersOverEverythingMapToTheirVirtualScopes() {
        XCTAssertEqual(
            source(#"{"kinds":["publication"],"scope":{"scope":"all"},"filters":[{"filter":"flag","color":"red"}]}"#),
            .flagged("red"))
        XCTAssertEqual(
            source(#"{"kinds":["publication"],"scope":{"scope":"all"},"filters":[{"filter":"flag","color":null}]}"#),
            .flagged(nil))
        XCTAssertEqual(
            source(#"{"kinds":["publication"],"scope":{"scope":"all"},"filters":[{"filter":"starred","starred":true}]}"#),
            .starred)
        XCTAssertEqual(
            source(#"{"kinds":["publication"],"scope":{"scope":"all"},"filters":[{"filter":"tag","path":"projects/uldm"}]}"#),
            .tag("projects/uldm"))
    }

    /// Every publication: no single container, and no pretending to one.
    func testEverythingHasNoContainer() {
        XCTAssertEqual(source(#"{"kinds":["publication"],"scope":{"scope":"all"},"filters":[]}"#), .combined([]))
        XCTAssertNil(
            LayoutPaneScope.collectionID(
                query: query(#"{"kinds":["manuscript"],"scope":{"scope":"all"},"filters":[]}"#),
                bindings: [:]))
    }
}
#endif
