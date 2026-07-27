//
//  CollectionStoreAdapterTests.swift
//  PublicationManagerCoreTests
//
//  ADR-0022 WP G2: the sidebar's folder verbs now run through ONE adapter
//  over the Rust collection kernel. `ImbibSidebarViewModel` has no tests (it
//  is a macOS NSOutlineView view model), so these exercise the seam it calls:
//  the kernel-backed verbs, against a real SharedStore on the test-process
//  workspace path (`ImpressRuntime.isUnitTestProcess` diverts
//  `SharedWorkspace` away from the App Group container).
//
//  NOT covered here: `rename`, `reorder` and `delete`, which still delegate
//  to `RustStoreAdapter`'s undoable ops — and `RustStoreAdapter` is an
//  IN-MEMORY `ImbibStore` in a test process, i.e. a different database than
//  this adapter's file-backed handle. See the G2-strangler TODOs in
//  CollectionStoreAdapter; the same split predates this WP on the figure
//  path (FigureStoreReader wrote envelopes, RustStoreAdapter wrote payloads).
//

import ImpressKit
import ImpressRustCore
import XCTest
@testable import PublicationManagerCore

#if os(macOS)
@MainActor
final class CollectionStoreAdapterTests: XCTestCase {

    private var adapter: CollectionStoreAdapter { CollectionStoreAdapter.shared }

    /// Unique per test method so methods stay order-independent (the test
    /// workspace database is shared across the process).
    private func uniqueName(_ label: String) -> String {
        "G2-\(label)-\(UUID().uuidString.prefix(8))"
    }

    private func row(_ bindingID: String, id: String) -> CollectionKernelRow? {
        adapter.tree(bindingID).first { $0.id == id }
    }

    // MARK: - Binding mapping

    func testEveryBindingIDResolvesToAKernelBinding() {
        XCTAssertEqual(CollectionStoreAdapter.binding(for: "manuscript"), .manuscript)
        XCTAssertEqual(CollectionStoreAdapter.binding(for: "figure"), .figure)
        XCTAssertEqual(CollectionStoreAdapter.binding(for: "publication"), .publication)
        XCTAssertEqual(CollectionStoreAdapter.binding(for: "generic"), .generic)
        XCTAssertNil(CollectionStoreAdapter.binding(for: "manuscript-collection"))
    }

    // MARK: - Create / tree (both bindings)

    /// Manuscript folders nest through payload `parent_collection_ref`;
    /// figure folders through the ENVELOPE parent. The sidebar sees one
    /// `parentID` either way — that uniformity is the whole point of D3.
    func testCreateAndTreeAgreeAcrossBothBindings() throws {
        for bindingID in [CollectionBindingID.manuscript, CollectionBindingID.figure] {
            try XCTSkipIf(!adapter.isReady, "shared store unavailable")
            let parentName = uniqueName("root-\(bindingID)")
            let childName = uniqueName("child-\(bindingID)")

            let parent = try XCTUnwrap(adapter.create(bindingID, name: parentName))
            let child = try XCTUnwrap(
                adapter.create(bindingID, name: childName, parentID: parent.id))

            XCTAssertEqual(parent.name, parentName)
            XCTAssertNil(parent.parentID, "a folder created at root has no tree parent")
            XCTAssertEqual(
                child.parentID, parent.id,
                "\(bindingID): the tree parent must be the folder, never the owning library"
            )
            XCTAssertEqual(row(bindingID, id: child.id)?.parentID, parent.id)
        }
    }

    /// The lowercase invariant: ids come back canonical, and an UPPERCASE id
    /// handed in (Swift's `UUID().uuidString` shape) still resolves.
    func testIDsAreLowercasedAtTheBoundary() throws {
        try XCTSkipIf(!adapter.isReady, "shared store unavailable")
        let parent = try XCTUnwrap(
            adapter.create(CollectionBindingID.manuscript, name: uniqueName("case")))
        XCTAssertEqual(parent.id, parent.id.lowercased())

        let child = try XCTUnwrap(adapter.create(
            CollectionBindingID.manuscript,
            name: uniqueName("case-child"),
            parentID: parent.id.uppercased()))
        XCTAssertEqual(
            child.parentID, parent.id,
            "an uppercase parent ref must resolve to the canonical lowercase id"
        )
    }

    // MARK: - Reparent + cycle check

    func testReparentMovesAndUnparents() throws {
        try XCTSkipIf(!adapter.isReady, "shared store unavailable")
        let binding = CollectionBindingID.manuscript
        let a = try XCTUnwrap(adapter.create(binding, name: uniqueName("a")))
        let b = try XCTUnwrap(adapter.create(binding, name: uniqueName("b")))

        XCTAssertTrue(adapter.reparent(binding, id: b.id, newParentID: a.id))
        XCTAssertEqual(row(binding, id: b.id)?.parentID, a.id)

        XCTAssertTrue(adapter.reparent(binding, id: b.id, newParentID: nil))
        XCTAssertNil(row(binding, id: b.id)?.parentID, "nil parent makes it a root again")
    }

    /// The cycle check is the KERNEL's now. A rejection must be reported as
    /// `false` (logged as a warning), never crash, and must leave the tree
    /// untouched — the Swift `isAncestor` pre-check is only drag feedback.
    func testReparentUnderOwnDescendantIsRejectedByTheKernel() throws {
        try XCTSkipIf(!adapter.isReady, "shared store unavailable")
        let binding = CollectionBindingID.manuscript
        let grandparent = try XCTUnwrap(adapter.create(binding, name: uniqueName("gp")))
        let parent = try XCTUnwrap(
            adapter.create(binding, name: uniqueName("p"), parentID: grandparent.id))
        let child = try XCTUnwrap(
            adapter.create(binding, name: uniqueName("c"), parentID: parent.id))

        XCTAssertTrue(adapter.isAncestor(binding, ancestorID: grandparent.id, of: child.id))
        XCTAssertFalse(adapter.isAncestor(binding, ancestorID: child.id, of: grandparent.id))

        XCTAssertFalse(
            adapter.reparent(binding, id: grandparent.id, newParentID: child.id),
            "moving a folder under its own grandchild must be refused"
        )
        XCTAssertNil(
            row(binding, id: grandparent.id)?.parentID,
            "a rejected reparent must leave the tree untouched"
        )

        XCTAssertFalse(
            adapter.reparent(binding, id: parent.id, newParentID: parent.id),
            "a folder cannot be its own parent"
        )
    }

    func testReparentOfAnUnknownIDFailsSoftly() throws {
        try XCTSkipIf(!adapter.isReady, "shared store unavailable")
        XCTAssertFalse(adapter.reparent(
            CollectionBindingID.manuscript,
            id: UUID().uuidString.lowercased(),
            newParentID: nil))
        XCTAssertFalse(adapter.reparent(
            CollectionBindingID.manuscript, id: "not-a-uuid", newParentID: nil))
    }

    // MARK: - Membership (envelope binding)

    /// Figure membership IS the envelope parent, so filing a figure into a
    /// folder and unfiling it are both `setParent` in the kernel. This is the
    /// drop path the sidebar's generic `handleRecordDrop` drives.
    func testEnvelopeMembershipFilesAndUnfiles() throws {
        try XCTSkipIf(!adapter.isReady, "shared store unavailable")
        let binding = CollectionBindingID.figure
        let folder = try XCTUnwrap(adapter.create(binding, name: uniqueName("figures")))
        let figureID = try XCTUnwrap(makeFigure())

        XCTAssertTrue(adapter.addMembers(binding, collectionID: folder.id, itemIDs: [figureID]))
        XCTAssertEqual(adapter.memberCounts(binding, collectionIDs: [folder.id]), [1])

        XCTAssertTrue(adapter.unfile(binding, itemIDs: [figureID]))
        XCTAssertEqual(adapter.memberCounts(binding, collectionIDs: [folder.id]), [0])
    }

    /// Sub-folders nest through the same envelope parent as figures do, but
    /// they are tree nodes — never members. A regression here would double
    /// count every figure folder's badge.
    func testSubfoldersAreNotCountedAsMembers() throws {
        try XCTSkipIf(!adapter.isReady, "shared store unavailable")
        let binding = CollectionBindingID.figure
        let parent = try XCTUnwrap(adapter.create(binding, name: uniqueName("outer")))
        _ = try XCTUnwrap(
            adapter.create(binding, name: uniqueName("inner"), parentID: parent.id))
        XCTAssertEqual(adapter.memberCounts(binding, collectionIDs: [parent.id]), [0])
    }

    /// New figure folders append to the end of the sibling order (the legacy
    /// `FigureStoreReader.createFolder` behavior), while manuscript folders
    /// keep `sort_order: 0` and sort by name.
    func testFigureFoldersKeepAppendOrderingAndManuscriptFoldersDoNot() throws {
        try XCTSkipIf(!adapter.isReady, "shared store unavailable")
        let figureA = try XCTUnwrap(
            adapter.create(CollectionBindingID.figure, name: uniqueName("order-a")))
        let figureB = try XCTUnwrap(
            adapter.create(CollectionBindingID.figure, name: uniqueName("order-b")))
        XCTAssertLessThan(
            figureA.sortOrder, figureB.sortOrder,
            "figure folders append in creation order"
        )

        let manuscript = try XCTUnwrap(
            adapter.create(CollectionBindingID.manuscript, name: uniqueName("order-m")))
        XCTAssertEqual(
            manuscript.sortOrder, 0,
            "manuscript folders keep sort_order 0 and sort by name (unchanged)"
        )
    }

    // MARK: - Helpers

    /// A bare `figure` item to file into a folder. Written through the same
    /// SharedStore handle the adapter uses.
    private func makeFigure() -> String? {
        let id = UUID().uuidString.lowercased()
        guard let store = try? ImpressRustCore.SharedStore.open(
            path: SharedWorkspace.databasePath) else { return nil }
        do {
            try store.upsertItemV2(row: SharedItemUpsert(
                id: id, schemaRef: "figure",
                payloadJson: #"{"format":"png","title":"G2 fixture"}"#,
                parentId: nil, tags: [],
                createdMs: nil, isRead: nil, isStarred: nil))
            return id
        } catch {
            return nil
        }
    }
}
#endif
