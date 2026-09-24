#if os(macOS)
//
//  LayoutPlotTargetTests.swift
//  PublicationManagerCoreTests
//
//  The `plot` view kind's dispatch, decided from the pane alone (FFI-free):
//  a figure pane with an id looks the figure up; nothing bound is the
//  "select a figure" state; a pane over another kind, or a value that is
//  not an id, is a NAMED empty state — never the placeholder and never a
//  blank. Resolution is `info`'s: `single_item`, else the `item` binding,
//  which `LayoutPlotPaneView` passes in as `rawItem`.
//

import XCTest

@testable import PublicationManagerCore

final class LayoutPlotTargetTests: XCTestCase {

    private let id = UUID(uuidString: "7813BE3B-0000-4000-8000-000000000001")!

    func testAFigurePaneWithAnIDDrawsThatFigure() {
        XCTAssertEqual(
            LayoutPlotTarget(primaryKind: "figure", rawItem: id.uuidString), .figure(id))
        // The store's canonical form is lower case; the pane accepts both.
        XCTAssertEqual(
            LayoutPlotTarget(primaryKind: "figure", rawItem: id.uuidString.lowercased()),
            .figure(id))
    }

    func testNothingBoundIsTheSelectAFigureState() {
        XCTAssertEqual(LayoutPlotTarget(primaryKind: "figure", rawItem: nil), .noSelection)
    }

    /// A plot pane over publications says so by name, whatever is bound.
    func testAnotherKindIsNamed() {
        XCTAssertEqual(
            LayoutPlotTarget(primaryKind: "publication", rawItem: id.uuidString),
            .wrongKind("publication"))
        XCTAssertEqual(
            LayoutPlotTarget(primaryKind: "manuscript", rawItem: nil), .wrongKind("manuscript"))
    }

    func testAValueThatIsNotAnIDIsNamed() {
        XCTAssertEqual(
            LayoutPlotTarget(primaryKind: "figure", rawItem: "fig-1"), .notAnID("fig-1"))
    }

    /// A pane with no query kinds (an `item(id)` pane over anything) is let
    /// through: the store row decides whether it is a figure.
    func testAKindlessPaneDefersToTheStoreRow() {
        XCTAssertEqual(LayoutPlotTarget(primaryKind: nil, rawItem: id.uuidString), .figure(id))
        XCTAssertEqual(LayoutPlotTarget(primaryKind: nil, rawItem: nil), .noSelection)
    }

    /// The kind is spelled as the pane query and the `select` verb spell it
    /// — the manifest's short id, which is `RecordKindID.figure`'s raw value.
    func testTheFigureKindIsTheManifestSpelling() {
        XCTAssertEqual(RecordKindID.figure.rawValue, "figure")
    }
}
#endif
