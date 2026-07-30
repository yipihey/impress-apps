//
//  StoreKernelTests.swift
//  PublicationManagerCoreTests
//
//  Stage 4b: the generic store kernels — `StoreKernelScope` (undo plumbing +
//  mutation fan-out), `RecordTriageStoreKernel` (the store half of triage), and
//  `CollectionStoreAdapter` on an INJECTED scope.
//
//  These are the parity proof for the ~540 lines deleted from imprint's
//  `ManuscriptStoreAdapter`. imprint's own `ManuscriptStoreAdapterTests` still
//  exercise the same behaviour end-to-end through the imprint-shaped API (they
//  now run THROUGH these kernels and were not modified — that is the actual
//  demonstration that the dedup is faithful); these pin the kernels themselves,
//  on both undo scopes, so a regression is attributed here rather than in one
//  app's suite.
//
//  UNDO is the delicate part and has regressed before. `NSUndoManager` routes
//  registrations made DURING an undo to the REDO stack, which is only true while
//  it reports `isUndoing` — so the re-registration must be SYNCHRONOUS
//  (`MainActor.assumeIsolated`, not a `Task`). Deferring it lands the redo on the
//  UNDO stack and ⌘Z toggles instead of ⌘⇧Z advancing. Every alternation test
//  below asserts `canRedo` after an undo and `canUndo` after a redo, which is
//  exactly what that bug broke.
//

import Foundation
import ImpressRustCore
import ImpressStoreKit
import XCTest
@testable import PublicationManagerCore

// MARK: - Undo action names

/// The strings the Edit menu says out loud, pinned. imprint's
/// `ManuscriptStoreAdapter.UndoActionName` now READS these instead of restating
/// them; if a rename here is deliberate it has to be deliberate in one place.
final class StoreKernelUndoActionNameTests: XCTestCase {

    func testCollectionActionNamesAreTheDelegatedRustDescriptions() {
        // `RustStoreAdapter.updateField(field: "name")` → `undo_description` of
        // `SetPayload("name")` is "Edit name", NOT "Rename Folder".
        XCTAssertEqual(StoreKernelUndoAction.renameCollection, "Edit name")
        XCTAssertEqual(StoreKernelUndoAction.reorderCollection, "Edit sort_order")
        XCTAssertEqual(StoreKernelUndoAction.deleteCollection, "Delete")
        XCTAssertEqual(StoreKernelUndoAction.reparentCollection, "Move Folder")
        XCTAssertEqual(StoreKernelUndoAction.addMembers, "Add to Collection")
        XCTAssertEqual(StoreKernelUndoAction.removeMembers, "Remove from Collection")
        XCTAssertEqual(StoreKernelUndoAction.createCollection, "New Folder")
    }

    func testTriageActionNames() {
        XCTAssertEqual(StoreKernelUndoAction.star, "Star")
        XCTAssertEqual(StoreKernelUndoAction.flag, "Flag")
        XCTAssertEqual(StoreKernelUndoAction.addTag, "Add Tag")
        XCTAssertEqual(StoreKernelUndoAction.removeTag, "Remove Tag")
        XCTAssertEqual(StoreKernelUndoAction.dismiss, "Dismiss")
        XCTAssertEqual(StoreKernelUndoAction.restore, "Restore")
        XCTAssertEqual(StoreKernelUndoAction.archive, "Archive")
        XCTAssertEqual(StoreKernelUndoAction.changeStatus, "Change Status")
    }

    /// Both kernels' nested enums are views onto the same constants, so the two
    /// GUIs cannot describe the same operation differently.
    @MainActor
    func testKernelEnumsReadTheSharedConstants() {
        XCTAssertEqual(
            CollectionStoreAdapter.UndoActionName.rename, StoreKernelUndoAction.renameCollection)
        XCTAssertEqual(
            CollectionStoreAdapter.UndoActionName.delete, StoreKernelUndoAction.deleteCollection)
        XCTAssertEqual(
            RecordTriageStoreKernel.UndoActionName.star, StoreKernelUndoAction.star)
        XCTAssertEqual(
            RecordTriageStoreKernel.UndoActionName.dismiss, StoreKernelUndoAction.dismiss)
    }
}

// MARK: - StoreUndoScope

@MainActor
final class StoreUndoScopeTests: XCTestCase {

    /// Undo target stand-in. `UndoManager.registerUndo(withTarget:)` keys its
    /// entries by target, so the kernels take one rather than using a shared
    /// token — otherwise one adapter's `removeAllActions(withTarget:)` would
    /// clear another's stack.
    private final class Target {}

    func testDisabledScopeRegistersNothing() {
        let manager = UndoManager()
        StoreUndoScope.disabled.registerReversible(
            target: Target(), actionName: "Nope", undo: {}, redo: {})
        XCTAssertFalse(manager.canUndo)
        XCTAssertFalse(StoreUndoScope.disabled.isActive)
    }

    func testManagerScopeWithNilManagerIsInactiveAndSafe() {
        XCTAssertFalse(StoreUndoScope.manager(nil).isActive)
        // Must not trap: hosts pass `.manager(undoManager)` unconditionally and
        // an iOS view's `@Environment(\.undoManager)` is legitimately nil.
        StoreUndoScope.manager(nil).registerReversible(
            target: Target(), actionName: "Nope", undo: {}, redo: {})
    }

    /// The alternation contract: ONE registration yields ⌘Z/⌘⇧Z forever.
    func testReversiblePairAlternatesIndefinitelyAndKeepsItsActionName() {
        let manager = UndoManager()
        let target = Target()
        var value = 1

        StoreUndoScope.manager(manager).registerReversible(
            target: target, actionName: "Set Value",
            undo: { value = 0 }, redo: { value = 1 })
        XCTAssertEqual(manager.undoActionName, "Set Value")

        manager.undo()
        XCTAssertEqual(value, 0)
        // The regression this guards: the re-registration happens while the
        // manager reports `isUndoing`, so it lands on the REDO stack. Deferring
        // it into a Task put it on the UNDO stack and ⌘Z toggled.
        XCTAssertTrue(manager.canRedo, "undo must arm redo")
        XCTAssertEqual(manager.redoActionName, "Set Value")

        manager.redo()
        XCTAssertEqual(value, 1)
        XCTAssertTrue(manager.canUndo, "redo must re-arm undo")

        // …and it keeps going, from that single registration.
        manager.undo()
        XCTAssertEqual(value, 0)
        manager.redo()
        XCTAssertEqual(value, 1)
    }

    /// `registerAlternating` with no captured value: the row EXISTS, so ⌘Z runs
    /// the producing side (delete → snapshot) and ⌘⇧Z consumes it. A FRESH value
    /// is produced on each cycle — the generalisation of the mutually-recursive
    /// exists/deleted pair imprint hand-rolled.
    func testAlternatingProducesAFreshValueOnEveryCycle() {
        let manager = UndoManager()
        let target = Target()
        var produced: [Int] = []
        var consumed: [Int] = []
        var counter = 0

        let scope = StoreKernelScope(
            store: nil, undoTarget: target, defaultUndo: .manager(manager),
            noteMutation: { _, _, _ in })

        scope.registerAlternating(
            nil, actionName: "Delete", capturedValue: nil as Int?,
            produce: {
                counter += 1
                produced.append(counter)
                return counter
            },
            consume: { consumed.append($0) })

        manager.undo()                       // produce → 1
        XCTAssertEqual(produced, [1])
        manager.redo()                       // consume 1
        XCTAssertEqual(consumed, [1])
        manager.undo()                       // produce → 2 (FRESH, not 1 again)
        XCTAssertEqual(produced, [1, 2])
        manager.redo()                       // consume 2
        XCTAssertEqual(consumed, [1, 2])
    }

    /// `registerAlternating` WITH a captured value: the row was just deleted, so
    /// ⌘Z consumes the snapshot (restore) and ⌘⇧Z re-produces one.
    func testAlternatingStartsOnTheConsumingSideWhenAValueIsCaptured() {
        let manager = UndoManager()
        let target = Target()
        var log: [String] = []

        let scope = StoreKernelScope(
            store: nil, undoTarget: target, defaultUndo: .manager(manager),
            noteMutation: { _, _, _ in })

        scope.registerAlternating(
            nil, actionName: "Delete", capturedValue: 7,
            produce: { log.append("delete"); return 8 },
            consume: { log.append("restore(\($0))") })

        manager.undo()
        XCTAssertEqual(log, ["restore(7)"], "⌘Z after a delete must restore")
        manager.redo()
        XCTAssertEqual(log, ["restore(7)", "delete"])
        manager.undo()
        XCTAssertEqual(log, ["restore(7)", "delete", "restore(8)"], "the fresh snapshot is used")
    }

    func testPerCallScopeOverridesTheScopeDefault() {
        let managerA = UndoManager()
        let managerB = UndoManager()
        let target = Target()
        let scope = StoreKernelScope(
            store: nil, undoTarget: target, defaultUndo: .manager(managerA),
            noteMutation: { _, _, _ in })

        scope.registerReversible(
            .manager(managerB), actionName: "B", undo: {}, redo: {})
        XCTAssertFalse(managerA.canUndo, "the per-call scope must win")
        XCTAssertTrue(managerB.canUndo)

        scope.registerReversible(nil, actionName: "A", undo: {}, redo: {})
        XCTAssertTrue(managerA.canUndo, "nil falls back to the scope default")
    }
}

// MARK: - RecordTriageStoreKernel

/// The store half of triage, on an in-memory `SharedStore` and a caller-supplied
/// `UndoManager` — the configuration imprint runs (macOS window manager, iOS
/// `SceneUndoManager`, a fresh one here).
@MainActor
final class RecordTriageStoreKernelTests: XCTestCase {

    private var store: SharedStore!
    private var manager: UndoManager!
    private var mutations: [(structural: Bool, ids: Set<UUID>?, kind: MutationKind?)] = []

    private var kernel: RecordTriageStoreKernel {
        RecordTriageStoreKernel(descriptor: ManuscriptRecordKind.descriptor, scope: scope)
    }

    private var scope: StoreKernelScope {
        StoreKernelScope(
            store: store, undoTarget: self, defaultUndo: .manager(manager),
            noteMutation: { [weak self] structural, ids, kind in
                self?.mutations.append((structural, ids, kind))
            })
    }

    override func setUp() async throws {
        try await super.setUp()
        store = try SharedStore.openInMemory()
        manager = UndoManager()
        mutations = []
    }

    override func tearDown() async throws {
        store = nil
        manager = nil
        try await super.tearDown()
    }

    private func makeRecord(status: String = "draft") throws -> UUID {
        let id = UUID()
        let json = try XCTUnwrap(
            String(
                data: JSONSerialization.data(
                    withJSONObject: ["title": "T", "status": status], options: [.sortedKeys]),
                encoding: .utf8))
        try store.upsertItem(
            id: id.uuidString,
            schemaRef: ManuscriptRecordKind.descriptor.schemaRefs.first ?? "manuscript",
            payloadJson: json)
        return id
    }

    private func row(_ id: UUID) throws -> SharedItemRow {
        try XCTUnwrap(try store.getItem(id: id.uuidString.lowercased()))
    }

    private func status(_ id: UUID) throws -> String? {
        let payload = try JSONSerialization.jsonObject(
            with: Data(try row(id).payloadJson.utf8)) as? [String: Any]
        return payload?["status"] as? String
    }

    // MARK: Lifecycle read off the descriptor

    func testLifecycleStatusesComeFromTheDescriptorNotLiterals() {
        let triage = ManuscriptRecordKind.descriptor.triage
        guard case .statusChange(let dismissed, let restoreTo) = triage.dismissal else {
            return XCTFail("manuscript dismissal must be .statusChange")
        }
        XCTAssertEqual(kernel.dismissedStatus, dismissed)
        XCTAssertEqual(kernel.restoreStatus, restoreTo)
        XCTAssertEqual(kernel.archivedStatus, triage.archiveStatus)
    }

    // MARK: Star

    /// The inverse restores each item's OWN prior value — undoing a mixed
    /// selection must not flatten it.
    func testStarUndoRestoresPriorPerItemState() throws {
        let a = try makeRecord()
        let b = try makeRecord()
        kernel.setStarred(ids: [a], starred: true, undo: .disabled)   // a starred, b not

        kernel.setStarred(ids: [a, b], starred: true)
        XCTAssertTrue(try row(a).isStarred)
        XCTAssertTrue(try row(b).isStarred)
        XCTAssertEqual(manager.undoActionName, StoreKernelUndoAction.star)

        manager.undo()
        XCTAssertTrue(try row(a).isStarred, "a was ALREADY starred; undo must not unstar it")
        XCTAssertFalse(try row(b).isStarred)

        XCTAssertTrue(manager.canRedo)
        manager.redo()
        XCTAssertTrue(try row(b).isStarred)
        XCTAssertTrue(manager.canUndo)
    }

    // MARK: Flag

    func testFlagUndoRestoresThePriorColour() throws {
        let id = try makeRecord()
        kernel.setFlag(ids: [id], color: "red", undo: .disabled)

        kernel.setFlag(ids: [id], color: "blue")
        XCTAssertEqual(try row(id).flagColor, "blue")
        XCTAssertEqual(manager.undoActionName, StoreKernelUndoAction.flag)

        manager.undo()
        XCTAssertEqual(try row(id).flagColor, "red")
        manager.redo()
        XCTAssertEqual(try row(id).flagColor, "blue")
    }

    func testClearingAFlagIsUndoable() throws {
        let id = try makeRecord()
        kernel.setFlag(ids: [id], color: "red", undo: .disabled)
        kernel.setFlag(ids: [id], color: nil)
        XCTAssertNil(try row(id).flagColor)
        manager.undo()
        XCTAssertEqual(try row(id).flagColor, "red")
    }

    // MARK: Tags

    func testTagUndoOnlyTouchesTheItemsThatActuallyChanged() throws {
        let already = try makeRecord()
        let fresh = try makeRecord()
        kernel.addTag(ids: [already], tagPath: "projects/reionization", undo: .disabled)

        kernel.addTag(ids: [already, fresh], tagPath: "projects/reionization")
        XCTAssertTrue(try row(fresh).tags.contains("projects/reionization"))
        XCTAssertEqual(manager.undoActionName, StoreKernelUndoAction.addTag)

        manager.undo()
        XCTAssertTrue(
            try row(already).tags.contains("projects/reionization"),
            "the item that already carried the tag must keep it")
        XCTAssertFalse(try row(fresh).tags.contains("projects/reionization"))

        manager.redo()
        XCTAssertTrue(try row(fresh).tags.contains("projects/reionization"))
    }

    func testRemoveTagUndoAddsItBackOnlyWhereItWasPresent() throws {
        let tagged = try makeRecord()
        let untagged = try makeRecord()
        kernel.addTag(ids: [tagged], tagPath: "t", undo: .disabled)

        kernel.removeTag(ids: [tagged, untagged], tagPath: "t")
        XCTAssertFalse(try row(tagged).tags.contains("t"))
        XCTAssertEqual(manager.undoActionName, StoreKernelUndoAction.removeTag)

        manager.undo()
        XCTAssertTrue(try row(tagged).tags.contains("t"))
        XCTAssertFalse(try row(untagged).tags.contains("t"), "never present, never re-added")
    }

    func testTagPathsInUseAreDerivedFromTheItemsThemselves() throws {
        let a = try makeRecord()
        let b = try makeRecord()
        kernel.addTag(ids: [a], tagPath: "zeta", undo: .disabled)
        kernel.addTag(ids: [b], tagPath: "Alpha", undo: .disabled)
        // Sorted case-insensitively, de-duplicated. This is what is USED, not
        // what has been DEFINED — there is no tag-listing FFI verb.
        XCTAssertEqual(kernel.tagPathsInUse(), ["Alpha", "zeta"])
    }

    // MARK: Status lifecycle

    func testDismissRestoreAndArchiveRoundTripUnderTheirOwnActionNames() throws {
        let dismissed = try XCTUnwrap(kernel.dismissedStatus)
        let restoreTo = try XCTUnwrap(kernel.restoreStatus)
        let archived = try XCTUnwrap(kernel.archivedStatus)
        let id = try makeRecord(status: restoreTo)

        XCTAssertTrue(kernel.dismiss(ids: [id]))
        XCTAssertEqual(try status(id), dismissed)
        XCTAssertEqual(manager.undoActionName, StoreKernelUndoAction.dismiss)
        manager.undo()
        XCTAssertEqual(try status(id), restoreTo)
        manager.redo()
        XCTAssertEqual(try status(id), dismissed)

        let restoreManager = UndoManager()
        XCTAssertTrue(kernel.restore(ids: [id], undo: .manager(restoreManager)))
        XCTAssertEqual(try status(id), restoreTo)
        XCTAssertEqual(restoreManager.undoActionName, StoreKernelUndoAction.restore)
        restoreManager.undo()
        XCTAssertEqual(try status(id), dismissed)

        let archiveManager = UndoManager()
        XCTAssertTrue(kernel.archive(ids: [id], undo: .manager(archiveManager)))
        XCTAssertEqual(try status(id), archived)
        XCTAssertEqual(archiveManager.undoActionName, StoreKernelUndoAction.archive)
        archiveManager.undo()
        XCTAssertEqual(try status(id), dismissed)
    }

    /// The schema has no validation, so this guard is the only gate.
    func testSetStatusRefusesAStatusTheDescriptorNeverDeclares() throws {
        let id = try makeRecord()
        XCTAssertFalse(kernel.setStatus(ids: [id], to: "obliterated"))
        XCTAssertNotEqual(try status(id), "obliterated")
        XCTAssertFalse(manager.canUndo, "a refused write must register no undo entry")
    }

    /// A dismissed record LEAVES every unscoped list, so a status write has to
    /// post a STRUCTURAL mutation — a field-only refresh leaves a stale row on
    /// screen. Envelope writes (star/flag/tag) stay non-structural.
    func testMutationNoticesMatchWhatEachVerbHasAlwaysPosted() throws {
        let id = try makeRecord()

        kernel.setStarred(ids: [id], starred: true, undo: .disabled)
        let star = try XCTUnwrap(mutations.last)
        XCTAssertFalse(star.structural)
        XCTAssertEqual(star.ids, [id])
        XCTAssertEqual(star.kind, .otherField)

        mutations = []
        XCTAssertTrue(kernel.dismiss(ids: [id], undo: .disabled))
        let dismiss = try XCTUnwrap(mutations.last)
        XCTAssertTrue(dismiss.structural, "a dismissed row leaves every unscoped list")
        XCTAssertEqual(dismiss.ids, [id])
    }

    func testAMissingStoreHandleNoOpsRatherThanTrapping() {
        let noStore = RecordTriageStoreKernel(
            descriptor: ManuscriptRecordKind.descriptor,
            scope: StoreKernelScope(
                store: nil, undoTarget: self, defaultUndo: .manager(manager),
                noteMutation: { _, _, _ in }))
        noStore.setStarred(ids: [UUID()], starred: true)
        noStore.applyStatus([UUID(): "draft"])
        XCTAssertEqual(noStore.tagPathsInUse(), [])
    }
}

// MARK: - CollectionStoreAdapter on an injected scope

/// The same kernel imbib's sidebar runs on, but pointed at a foreign store
/// handle, a foreign mutation sink and a caller-supplied `UndoManager` — which is
/// exactly how imprint uses it, on macOS and iOS alike.
@MainActor
final class InjectedScopeCollectionKernelTests: XCTestCase {

    private var store: SharedStore!
    private var manager: UndoManager!
    private var adapter: CollectionStoreAdapter!
    private var structuralNotices = 0

    private let binding = CollectionBindingID.manuscript

    override func setUp() async throws {
        try await super.setUp()
        store = try SharedStore.openInMemory()
        manager = UndoManager()
        structuralNotices = 0
        adapter = CollectionStoreAdapter(
            scope: StoreKernelScope(
                store: store,
                undoTarget: nil,
                defaultUndo: .disabled,
                noteMutation: { [weak self] structural, _, _ in
                    if structural { self?.structuralNotices += 1 }
                }))
    }

    override func tearDown() async throws {
        adapter = nil
        store = nil
        manager = nil
        try await super.tearDown()
    }

    private func row(_ id: String) -> CollectionKernelRow? {
        adapter.tree(binding).first { $0.id == id }
    }

    /// The whole point of the scope: none of this touched `RustStoreAdapter` or
    /// `UndoCoordinator`, so no second store facade is booted inside a sibling
    /// app and nothing is pinned to macOS.
    func testCreateRenameReparentAndDeleteRunOnTheInjectedHandle() throws {
        let a = try XCTUnwrap(adapter.create(binding, name: "A"))
        let b = try XCTUnwrap(adapter.create(binding, name: "B"))
        XCTAssertEqual(row(a.id)?.name, "A")
        XCTAssertTrue(structuralNotices >= 2, "creates post structural mutations to the HOST sink")

        XCTAssertTrue(adapter.rename(binding, id: a.id, to: "Alpha"))
        XCTAssertEqual(row(a.id)?.name, "Alpha")

        XCTAssertTrue(adapter.reparent(binding, id: b.id, newParentID: a.id))
        XCTAssertEqual(row(b.id)?.parentID, a.id)

        // The cycle check is the KERNEL's; a rejection returns false, never traps.
        XCTAssertFalse(adapter.reparent(binding, id: a.id, newParentID: b.id))

        XCTAssertTrue(adapter.delete(binding, id: b.id))
        XCTAssertNil(row(b.id))
    }

    /// `.disabled` is the default so that adopting a shared verb never silently
    /// adds an Edit-menu entry: imbib's sidebar has never made "New Folder"
    /// undoable, and this file's `create` must not change that.
    func testCreateRegistersNoUndoUnlessAsked() throws {
        _ = try XCTUnwrap(adapter.create(binding, name: "Quiet"))
        XCTAssertFalse(manager.canUndo)

        let loud = try XCTUnwrap(
            adapter.create(binding, name: "Loud", undo: .manager(manager)))
        XCTAssertEqual(manager.undoActionName, StoreKernelUndoAction.createCollection)
        manager.undo()
        XCTAssertNil(row(loud.id), "⌘Z after a create deletes the folder")
        XCTAssertTrue(manager.canRedo)
        manager.redo()
        XCTAssertEqual(row(loud.id)?.name, "Loud", "⌘⇧Z restores it under the ORIGINAL id")
    }

    func testRenameUndoRestoresThePriorNameThroughTheInjectedManager() throws {
        let folder = try XCTUnwrap(adapter.create(binding, name: "Before"))
        XCTAssertTrue(
            adapter.rename(binding, id: folder.id, to: "After", undo: .manager(manager)))
        XCTAssertEqual(manager.undoActionName, StoreKernelUndoAction.renameCollection)

        manager.undo()
        XCTAssertEqual(row(folder.id)?.name, "Before")
        XCTAssertTrue(manager.canRedo, "undo must arm redo, not a second undo")
        manager.redo()
        XCTAssertEqual(row(folder.id)?.name, "After")
        XCTAssertTrue(manager.canUndo)
    }

    func testReparentUndoMovesTheFolderBack() throws {
        let parent = try XCTUnwrap(adapter.create(binding, name: "Parent"))
        let child = try XCTUnwrap(adapter.create(binding, name: "Child"))
        XCTAssertTrue(
            adapter.reparent(
                binding, id: child.id, newParentID: parent.id, undo: .manager(manager)))
        XCTAssertEqual(manager.undoActionName, StoreKernelUndoAction.reparentCollection)

        manager.undo()
        XCTAssertNil(row(child.id)?.parentID)
        manager.redo()
        XCTAssertEqual(row(child.id)?.parentID, parent.id)
    }

    /// `collection_delete` hands back a snapshot `collection_restore` replays
    /// under the ORIGINAL id, re-filing members — losslessly, which is strictly
    /// more than an item-snapshot delete restored.
    func testDeleteUndoRestoresTheFolderAndItsMembership() throws {
        let folder = try XCTUnwrap(adapter.create(binding, name: "Doomed"))
        let member = UUID().uuidString.lowercased()
        try store.upsertItem(id: member, schemaRef: "manuscript", payloadJson: "{}")
        XCTAssertTrue(
            adapter.addMembers(binding, collectionID: folder.id, itemIDs: [member]))
        XCTAssertEqual(adapter.memberCounts(binding, collectionIDs: [folder.id]), [1])

        XCTAssertTrue(adapter.delete(binding, id: folder.id, undo: .manager(manager)))
        XCTAssertNil(row(folder.id))
        XCTAssertEqual(manager.undoActionName, StoreKernelUndoAction.deleteCollection)

        manager.undo()
        XCTAssertEqual(row(folder.id)?.name, "Doomed")
        XCTAssertEqual(
            adapter.memberCounts(binding, collectionIDs: [folder.id]), [1],
            "collection_restore puts the dropped membership back too")

        XCTAssertTrue(manager.canRedo)
        manager.redo()
        XCTAssertNil(row(folder.id))
    }

    func testMembershipUndoOnlyUnfilesWhatItActuallyFiled() throws {
        let folder = try XCTUnwrap(adapter.create(binding, name: "Folder"))
        let existing = UUID().uuidString.lowercased()
        let fresh = UUID().uuidString.lowercased()
        for id in [existing, fresh] {
            try store.upsertItem(id: id, schemaRef: "manuscript", payloadJson: "{}")
        }
        _ = adapter.addMembersReportingChanges(
            binding, collectionID: folder.id, itemIDs: [existing])

        let changed = adapter.addMembersReportingChanges(
            binding, collectionID: folder.id, itemIDs: [existing, fresh],
            undo: .manager(manager))
        XCTAssertEqual(changed, [fresh], "only the ids that ACTUALLY became members")
        XCTAssertEqual(manager.undoActionName, StoreKernelUndoAction.addMembers)

        manager.undo()
        XCTAssertEqual(
            adapter.memberCounts(binding, collectionIDs: [folder.id]), [1],
            "the already-filed item must survive undoing someone else's drop")

        let removeManager = UndoManager()
        let removed = adapter.removeMembersReportingChanges(
            binding, collectionID: folder.id, itemIDs: [existing, fresh],
            undo: .manager(removeManager))
        XCTAssertEqual(removed, [existing])
        XCTAssertEqual(removeManager.undoActionName, StoreKernelUndoAction.removeMembers)
        removeManager.undo()
        XCTAssertEqual(adapter.memberCounts(binding, collectionIDs: [folder.id]), [1])
    }

    /// The Swift-side drag pre-check. Authoritative check is the kernel's inside
    /// `reparent`; this returning false wrongly costs a rejected drop, never a
    /// corrupted tree.
    func testIsAncestorWalksTheInjectedTree() throws {
        let root = try XCTUnwrap(adapter.create(binding, name: "Root"))
        let mid = try XCTUnwrap(
            adapter.create(binding, name: "Mid", parentID: root.id))
        let leaf = try XCTUnwrap(
            adapter.create(binding, name: "Leaf", parentID: mid.id))
        XCTAssertTrue(adapter.isAncestor(binding, ancestorID: root.id, of: leaf.id))
        XCTAssertFalse(adapter.isAncestor(binding, ancestorID: leaf.id, of: root.id))
    }
}
