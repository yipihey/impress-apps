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
//  NEWLY TESTABLE (#41): `rename`, `reorder`, `delete` and Contains-edge
//  `addMembers` used to delegate to `RustStoreAdapter`'s undoable ops, and
//  `RustStoreAdapter` is an IN-MEMORY `ImbibStore` in a test process — a
//  different database than this adapter's file-backed handle, so those verbs
//  could not be asserted here at all. With the delegation dropped every verb
//  runs on the file-backed kernel handle and round-trips in-process.
//
//  UNDO: `UndoCoordinator` registers nothing unless it has an `UndoManager`
//  (the window supplies one at runtime), so `withUndoManager` installs a real
//  one for the duration of a test. That makes the ⌘Z path itself testable —
//  action name included — not just the inverse verbs. The undo closure runs
//  in a `Task { @MainActor }` inside the coordinator, hence `settle()`.
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

    // MARK: - Rename (kernel + undo)

    func testRenameRoundTripsThroughTheKernel() throws {
        try XCTSkipIf(!adapter.isReady, "shared store unavailable")
        let binding = CollectionBindingID.manuscript
        let folder = try XCTUnwrap(adapter.create(binding, name: uniqueName("rename")))
        let newName = uniqueName("renamed")

        adapter.rename(binding, id: folder.id, to: newName)
        XCTAssertEqual(row(binding, id: folder.id)?.name, newName)

        // An UPPERCASE id must still resolve (the lowercase-at-the-boundary
        // rule) — the delegated path took a `UUID`, this one takes a string.
        let secondName = uniqueName("renamed-again")
        adapter.rename(binding, id: folder.id.uppercased(), to: secondName)
        XCTAssertEqual(row(binding, id: folder.id)?.name, secondName)
    }

    /// The whole point of #41: the kernel path keeps ⌘Z, with the same Edit
    /// menu wording the delegated `updateField` produced ("Edit name" is the
    /// Rust `undo_description` of `SetPayload("name")`).
    func testRenameUndoRestoresThePriorNameUnderTheLegacyActionName() async throws {
        try XCTSkipIf(!adapter.isReady, "shared store unavailable")
        let binding = CollectionBindingID.manuscript
        let original = uniqueName("undo-rename")
        let folder = try XCTUnwrap(adapter.create(binding, name: original))

        let manager = withUndoManager()
        defer { clearUndoManager() }

        adapter.rename(binding, id: folder.id, to: uniqueName("renamed"))
        XCTAssertNotEqual(row(binding, id: folder.id)?.name, original)
        XCTAssertEqual(manager.undoActionName, CollectionStoreAdapter.UndoActionName.rename)

        manager.undo()
        await settle()
        XCTAssertEqual(row(binding, id: folder.id)?.name, original, "⌘Z must restore the name")

        // `UndoCoordinator` re-registers the other half synchronously inside
        // the undo invocation (while `isUndoing`), so it lands on the REDO
        // stack: ⌘⇧Z reapplies, ⌘Z does not toggle.
        XCTAssertTrue(manager.canRedo, "undoing must arm redo, not a second undo")
        manager.redo()
        await settle()
        XCTAssertNotEqual(row(binding, id: folder.id)?.name, original, "⌘⇧Z reapplies the rename")
        XCTAssertTrue(manager.canUndo, "redoing must re-arm undo")
    }

    // MARK: - Reorder (kernel + undo)

    func testReorderAssignsSiblingPositionsAndUndoRestoresThem() async throws {
        try XCTSkipIf(!adapter.isReady, "shared store unavailable")
        let binding = CollectionBindingID.figure   // append-ordered, so priors differ
        let a = try XCTUnwrap(adapter.create(binding, name: uniqueName("ord-a")))
        let b = try XCTUnwrap(adapter.create(binding, name: uniqueName("ord-b")))
        let priorA = try XCTUnwrap(row(binding, id: a.id)?.sortOrder)
        let priorB = try XCTUnwrap(row(binding, id: b.id)?.sortOrder)

        let manager = withUndoManager()
        defer { clearUndoManager() }

        adapter.reorder(binding, ids: [b.id, a.id])
        XCTAssertEqual(row(binding, id: b.id)?.sortOrder, 0)
        XCTAssertEqual(row(binding, id: a.id)?.sortOrder, 1)
        XCTAssertEqual(manager.undoActionName, CollectionStoreAdapter.UndoActionName.reorder)

        // One Undo entry per moved sibling — exactly what the delegated
        // `updateIntField` loop registered — coalesced by `UndoManager`'s
        // per-event grouping into ONE ⌘Z, so a drag of N siblings is one
        // undo, not N.
        manager.undo()
        await settle()
        XCTAssertEqual(row(binding, id: a.id)?.sortOrder, priorA)
        XCTAssertEqual(row(binding, id: b.id)?.sortOrder, priorB)
    }

    // MARK: - Delete / restore

    /// `collection_delete` hands back a snapshot that `collection_restore`
    /// replays under the ORIGINAL id, re-filing members and re-attaching
    /// child collections — strictly more than the delegated item-snapshot
    /// delete restored.
    ///
    /// Run on the FIGURE binding, whose tree and membership are both the
    /// envelope parent: the delete really does orphan the child folder and
    /// unfile the member (FK `SET NULL`), so the restore has something to
    /// put back. Payload-tree bindings keep a dangling `parent_collection_ref`
    /// instead, which the same restore path re-validates.
    func testDeleteUndoRestoresTheFolderItsMembersAndItsChildren() async throws {
        try XCTSkipIf(!adapter.isReady, "shared store unavailable")
        let binding = CollectionBindingID.figure
        let folder = try XCTUnwrap(adapter.create(binding, name: uniqueName("del")))
        let child = try XCTUnwrap(
            adapter.create(binding, name: uniqueName("del-child"), parentID: folder.id))
        let member = try XCTUnwrap(makeItem(schemaRef: "figure"))
        XCTAssertTrue(adapter.addMembers(binding, collectionID: folder.id, itemIDs: [member]))
        XCTAssertEqual(adapter.memberCounts(binding, collectionIDs: [folder.id]), [1])

        let manager = withUndoManager()
        defer { clearUndoManager() }

        adapter.delete(binding, id: folder.id)
        XCTAssertNil(row(binding, id: folder.id), "the folder row is gone")
        XCTAssertNil(row(binding, id: child.id)?.parentID, "its child is orphaned by the delete")
        XCTAssertEqual(manager.undoActionName, CollectionStoreAdapter.UndoActionName.delete)

        manager.undo()
        await settle()
        let restored = try XCTUnwrap(row(binding, id: folder.id))
        XCTAssertEqual(restored.id, folder.id, "restored under its ORIGINAL id")
        XCTAssertEqual(restored.name, folder.name)
        XCTAssertEqual(row(binding, id: child.id)?.parentID, folder.id, "child re-attached")
        XCTAssertEqual(
            adapter.memberCounts(binding, collectionIDs: [folder.id]), [1], "member re-filed")
    }

    // MARK: - Contains-edge membership (newly reachable)

    /// Manuscript/publication folders record membership as a `Contains` edge.
    /// This path used to run through `RustStoreAdapter` (in-memory in tests,
    /// so unassertable); it is the kernel's now.
    func testContainsMembershipFilesAndUnfiles() throws {
        try XCTSkipIf(!adapter.isReady, "shared store unavailable")
        let binding = CollectionBindingID.manuscript
        let folder = try XCTUnwrap(adapter.create(binding, name: uniqueName("members")))
        let member = try XCTUnwrap(makeItem(schemaRef: "manuscript"))

        XCTAssertTrue(adapter.addMembers(binding, collectionID: folder.id, itemIDs: [member]))
        XCTAssertEqual(adapter.memberCounts(binding, collectionIDs: [folder.id]), [1])

        XCTAssertTrue(adapter.removeMembers(binding, collectionID: folder.id, itemIDs: [member]))
        XCTAssertEqual(adapter.memberCounts(binding, collectionIDs: [folder.id]), [0])
    }

    /// The kernel reports the ids it ACTUALLY changed, and the undo closure
    /// only reverses those — so undoing a drop that re-filed nothing must not
    /// unfile an item that was already a member.
    func testMembershipUndoOnlyReversesWhatActuallyChanged() async throws {
        try XCTSkipIf(!adapter.isReady, "shared store unavailable")
        let binding = CollectionBindingID.manuscript
        let folder = try XCTUnwrap(adapter.create(binding, name: uniqueName("members-undo")))
        let member = try XCTUnwrap(makeItem(schemaRef: "manuscript"))
        XCTAssertTrue(adapter.addMembers(binding, collectionID: folder.id, itemIDs: [member]))

        let manager = withUndoManager()
        defer { clearUndoManager() }

        // Second add changes nothing → nothing to register, nothing to undo.
        XCTAssertTrue(adapter.addMembers(binding, collectionID: folder.id, itemIDs: [member]))
        XCTAssertFalse(manager.canUndo, "a no-op add must not push an Undo entry")
        XCTAssertEqual(adapter.memberCounts(binding, collectionIDs: [folder.id]), [1])

        // A real removal registers, and its undo re-files exactly it.
        XCTAssertTrue(adapter.removeMembers(binding, collectionID: folder.id, itemIDs: [member]))
        XCTAssertEqual(
            manager.undoActionName, CollectionStoreAdapter.UndoActionName.removeMembers)
        XCTAssertEqual(adapter.memberCounts(binding, collectionIDs: [folder.id]), [0])

        manager.undo()
        await settle()
        XCTAssertEqual(adapter.memberCounts(binding, collectionIDs: [folder.id]), [1])
    }

    /// Reparent's undo has existed since G2; it now reads its prior parent
    /// from the kernel's mutation instead of a pre-read tree walk.
    func testReparentUndoMovesTheFolderBack() async throws {
        try XCTSkipIf(!adapter.isReady, "shared store unavailable")
        let binding = CollectionBindingID.manuscript
        let a = try XCTUnwrap(adapter.create(binding, name: uniqueName("rp-a")))
        let b = try XCTUnwrap(adapter.create(binding, name: uniqueName("rp-b")))
        let c = try XCTUnwrap(adapter.create(binding, name: uniqueName("rp-c"), parentID: a.id))

        let manager = withUndoManager()
        defer { clearUndoManager() }

        XCTAssertTrue(adapter.reparent(binding, id: c.id, newParentID: b.id))
        XCTAssertEqual(row(binding, id: c.id)?.parentID, b.id)
        XCTAssertEqual(manager.undoActionName, CollectionStoreAdapter.UndoActionName.reparent)

        manager.undo()
        await settle()
        XCTAssertEqual(row(binding, id: c.id)?.parentID, a.id, "⌘Z moves it back under a")
    }

    /// Undo action names are the ones the delegated path registered — the
    /// Edit menu must read identically now that the delegation is gone.
    func testUndoActionNamesMatchTheDelegatedPath() {
        XCTAssertEqual(CollectionStoreAdapter.UndoActionName.rename, "Edit name")
        XCTAssertEqual(CollectionStoreAdapter.UndoActionName.reorder, "Edit sort_order")
        XCTAssertEqual(CollectionStoreAdapter.UndoActionName.delete, "Delete")
        XCTAssertEqual(CollectionStoreAdapter.UndoActionName.addMembers, "Add to Collection")
        XCTAssertEqual(CollectionStoreAdapter.UndoActionName.reparent, "Move Folder")
    }

    // MARK: - Helpers

    /// A bare `figure` item to file into a folder. Written through the same
    /// SharedStore handle the adapter uses.
    private func makeFigure() -> String? {
        makeItem(schemaRef: "figure")
    }

    /// A bare item of `schemaRef`, written through the same SharedStore
    /// handle the adapter uses. Membership verbs never validate the member's
    /// schema (the kernel files whatever id it is handed).
    private func makeItem(schemaRef: String) -> String? {
        let id = UUID().uuidString.lowercased()
        guard let store = try? ImpressRustCore.SharedStore.open(
            path: SharedWorkspace.databasePath) else { return nil }
        do {
            try store.upsertItemV2(row: SharedItemUpsert(
                id: id, schemaRef: schemaRef,
                payloadJson: #"{"format":"png","title":"G2 fixture"}"#,
                parentId: nil, tags: [],
                createdMs: nil, isRead: nil, isStarred: nil))
            return id
        } catch {
            return nil
        }
    }

    /// Install a real `UndoManager` on the shared coordinator — without one
    /// `registerUndoClosure` is a no-op, which is why the undo half of these
    /// verbs was invisible to tests before.
    private func withUndoManager() -> UndoManager {
        let manager = UndoManager()
        manager.levelsOfUndo = 0
        UndoCoordinator.shared.undoManager = manager
        return manager
    }

    private func clearUndoManager() {
        UndoCoordinator.shared.undoManager = nil
    }

    /// `UndoCoordinator` runs the registered closure inside a
    /// `Task { @MainActor }`; give that task a turn before asserting.
    private func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }
}
#endif
