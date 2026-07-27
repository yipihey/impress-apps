//
//  RelatedItemsSectionTests.swift
//  PublicationManagerCoreTests
//
//  ADR-0022 WP G5 / D8: the generic Related section. Everything between
//  "the kernel answered" and "the pane renders" is pure — grouping, the
//  schemaRef → RecordKindID fallback, the direction symbols — so it is
//  asserted here without a store or a view host.
//

import XCTest
@testable import PublicationManagerCore

#if os(macOS)
final class RelatedItemsSectionTests: XCTestCase {

    private func row(
        _ edgeType: String,
        schemaRef: String = "imbib/bibliography-entry",
        title: String = "t",
        direction: RelatedDirection = .outgoing
    ) -> RelatedItemRow {
        RelatedItemRow(
            id: UUID(), schemaRef: schemaRef, title: title,
            edgeType: edgeType, direction: direction)
    }

    // MARK: - Grouping

    /// Group order and within-group order both follow the store's answer.
    /// Sorting alphabetically here would make the pane's layout depend on
    /// edge NAMES, so renaming an edge type would reshuffle unrelated panes.
    func testGroupingKeepsFirstAppearanceOrder() {
        let rows = [
            row("Cites", title: "a"),
            row("Contains", title: "b"),
            row("Cites", title: "c"),
            row("ProducedBy", title: "d"),
            row("Contains", title: "e"),
        ]
        let groups = RelatedItemsModel.groups(rows)
        XCTAssertEqual(groups.map(\.edgeType), ["Cites", "Contains", "ProducedBy"])
        XCTAssertEqual(groups[0].items.map(\.title), ["a", "c"])
        XCTAssertEqual(groups[1].items.map(\.title), ["b", "e"])
        XCTAssertEqual(groups[2].items.map(\.title), ["d"])
    }

    func testGroupingIsStableAcrossRepeatedCalls() {
        let rows = (0..<50).map { row($0.isMultiple(of: 2) ? "Cites" : "Contains") }
        let first = RelatedItemsModel.groups(rows).map(\.edgeType)
        for _ in 0..<5 {
            XCTAssertEqual(RelatedItemsModel.groups(rows).map(\.edgeType), first)
        }
    }

    func testNoRowsProducesNoGroups() {
        // The section hides itself entirely on an empty group list — there is
        // no "empty Related header" state to render.
        XCTAssertTrue(RelatedItemsModel.groups([]).isEmpty)
    }

    func testEdgeTypeDisplayNameSplitsCamelCaseAndPassesCustomNamesThrough() {
        XCTAssertEqual(RelatedItemsModel.displayName(forEdgeType: "InResponseTo"), "In Response To")
        XCTAssertEqual(RelatedItemsModel.displayName(forEdgeType: "ProducedBy"), "Produced By")
        XCTAssertEqual(RelatedItemsModel.displayName(forEdgeType: "Cites"), "Cites")
        XCTAssertEqual(RelatedItemsModel.displayName(forEdgeType: "my_custom"), "my_custom")
        XCTAssertEqual(RelatedItemsModel.displayName(forEdgeType: ""), "")
    }

    // MARK: - Direction

    func testDirectionSymbolsAndParsing() {
        XCTAssertEqual(RelatedDirection.outgoing.symbolName, "arrow.right")
        XCTAssertEqual(RelatedDirection.incoming.symbolName, "arrow.left")
        XCTAssertEqual(RelatedDirection(ffi: "incoming"), .incoming)
        XCTAssertEqual(RelatedDirection(ffi: "outgoing"), .outgoing)
        // An unrecognised direction keeps the row rather than dropping it.
        XCTAssertEqual(RelatedDirection(ffi: "sideways"), .outgoing)
    }

    // MARK: - schemaRef → kind

    /// The store hands out VERSIONED refs while several descriptors declare
    /// the bare form; the lookup tolerates a version suffix on either side.
    func testSchemaRefResolvesAcrossVersionSuffixes() {
        let registry = BuiltinRecordKinds.registry
        XCTAssertEqual(registry.kind(forStoreSchemaRef: "figure"), .figure)
        XCTAssertEqual(registry.kind(forStoreSchemaRef: "figure@1.0.0"), .figure)
        XCTAssertEqual(registry.kind(forStoreSchemaRef: "manuscript@2.3.4"), .manuscript)
        XCTAssertEqual(registry.kind(forStoreSchemaRef: "task@1.0.0"), .task)
        XCTAssertEqual(registry.kind(forStoreSchemaRef: "task"), .task)
        XCTAssertEqual(registry.kind(forStoreSchemaRef: "email-message"), .message)
        XCTAssertEqual(
            registry.kind(forStoreSchemaRef: "imbib/bibliography-entry"), .publication)
    }

    /// Base-name equality, never `hasPrefix`: a figure FOLDER is not a figure.
    func testUnknownSchemaRefFallsBackToNoKindAndTheUnknownIcon() {
        let registry = BuiltinRecordKinds.registry
        XCTAssertNil(registry.kind(forStoreSchemaRef: "figure-collection"))
        XCTAssertNil(registry.kind(forStoreSchemaRef: "imbib/collection"))
        XCTAssertNil(registry.kind(forStoreSchemaRef: "not-a-schema@9.9.9"))
        XCTAssertNil(registry.kind(forStoreSchemaRef: ""))

        XCTAssertEqual(
            RelatedItemsModel.symbolName(forSchemaRef: "figure-collection"),
            RecordKindIconography.unknownSymbolName)
        XCTAssertEqual(
            RelatedItemsModel.symbolName(forSchemaRef: "figure@1.0.0"), "photo")
        XCTAssertEqual(
            row("Cites", schemaRef: "agent-run@1.0.0").symbolName, "bolt")
    }

    func testBaseNameStripsTheVersionSuffix() {
        XCTAssertEqual(RecordKindSchemaRef.baseName("figure@1.0.0"), "figure")
        XCTAssertEqual(RecordKindSchemaRef.baseName("figure"), "figure")
        XCTAssertEqual(RecordKindSchemaRef.baseName("@1.0.0"), "")
    }
}
#endif
