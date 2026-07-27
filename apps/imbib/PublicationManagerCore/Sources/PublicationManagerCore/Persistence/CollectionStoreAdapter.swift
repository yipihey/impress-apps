#if os(macOS)
// Chassis file — macOS-only in GUI-meld Phase 1 (iOS keeps IOSContentView).
//
//  CollectionStoreAdapter.swift
//  PublicationManagerCore
//
//  WP G2 of ADR-0022: the ONE Swift seam for collection verbs.
//
//  Before this file, every record kind that had sidebar folders re-implemented
//  the folder pattern against a different store surface — manuscripts through
//  `RustStoreAdapter` payload writes (`parent_collection_ref`), figures through
//  `FigureStoreReader` envelope writes (`setParent`) — and the reparent cycle
//  check lived in Swift, once per kind. The Rust collection kernel
//  (`impress-core::collection_ops`, exposed as `SharedStore.collection*`)
//  now owns the verb set, parameterized by a `SharedCollectionBinding`; this
//  adapter maps `CollectionCapability.bindingID` onto that binding and is the
//  only place in Swift that knows a binding exists.
//
//  Two rules govern every method here:
//
//  1. **Lowercase at the boundary.** `UUID().uuidString` is uppercase; the
//     Rust store's canonical id form is lowercase and payload parent refs are
//     matched by string equality (see the imbib CLAUDE.md invariant, and
//     `RustStoreAdapter.createManuscriptCollection`, which has always done
//     this). Every id crossing this file is `.lowercased()` on the way in.
//  2. **Identical notifications.** Callers used to post specific
//     `StoreEvent`s / `dataVersion` bumps per kind; each method below
//     reproduces the event the path it replaced posted, via
//     `RustStoreAdapter.noteExternalMutation` (which honours batches).
//
//  STRANGLER STATE (ADR-0022 G2, closed). EVERY verb runs on the kernel now:
//  `tree`, `memberCounts`, `create`, `rename`, `reorder`, `reparent`,
//  `delete`, `addMembers`, `removeMembers`. The delegation to
//  `RustStoreAdapter`'s field-update / snapshot-delete ops is gone: the
//  kernel returns per-verb inverse information (`collection_ops`' undo
//  contract table — `SharedCollectionMutation.prior`, `SharedDeletedCollection`,
//  the ids membership actually changed), so each mutating verb registers its
//  own exact inverse here instead of re-reading the store to guess one.
//  The remaining G2 debt lives in `ImbibSidebarViewModel` (the two drag-session
//  singletons, the `migratedFolderBindings` gate), not in this file.
//
//  Three rules, then, not two — the third:
//
//  3. **Undo is closure-registered, and its closures call the RAW verbs.**
//     `apply*` performs a kernel verb and posts its event but registers
//     nothing; the public verb wraps it and registers the Undo entry. Undo /
//     redo closures therefore call `apply*`, never the public verb — a redo
//     is already re-registered by `UndoCoordinator.registerUndoClosure`, and
//     a public call inside a closure would push a SECOND entry onto the
//     stack (one ⌘Z needing two ⌘⇧Z).
//

import Foundation
import ImpressKit
import ImpressRustCore
import ImpressStoreKit
import OSLog

/// One collection row, binding-agnostic. Mirrors the kernel's
/// `SharedCollectionRow` minus the fields no Swift caller reads yet.
public struct CollectionKernelRow: Equatable, Sendable {
    /// Lowercase UUID string.
    public let id: String
    public let name: String
    /// Lowercase UUID string of the TREE parent (payload ref or envelope
    /// parent per binding), `nil` for a root. Never the owning library.
    public let parentID: String?
    public let sortOrder: Int64

    init(_ row: SharedCollectionRow) {
        self.id = row.id
        self.name = row.name
        self.parentID = row.parentId
        self.sortOrder = row.sortOrder
    }
}

@MainActor
public final class CollectionStoreAdapter {

    public static let shared = CollectionStoreAdapter()

    private static let logger = Logger(subsystem: "com.imbib.app", category: "collections")

    /// Handle on the shared impress store. Opened exactly like
    /// `FigureStoreReader` (same database as `RustStoreAdapter`'s
    /// `ImbibStore` — `SharedWorkspace.databasePath`; WAL permits concurrent
    /// handles in-process and across processes).
    private var store: SharedStore?

    private init() {
        do {
            try SharedWorkspace.ensureDirectoryExists()
            store = try SharedStore.open(path: SharedWorkspace.databasePath)
        } catch {
            Self.logger.error("CollectionStoreAdapter failed to open shared store: \(error)")
        }
    }

    public var isReady: Bool { store != nil }

    // MARK: - Binding

    /// Map a descriptor's `CollectionCapability.bindingID` onto the kernel
    /// binding. The only place this mapping exists.
    nonisolated static func binding(for bindingID: String) -> SharedCollectionBinding? {
        switch bindingID {
        case CollectionBindingID.publication: return .publication
        case CollectionBindingID.manuscript: return .manuscript
        case CollectionBindingID.figure: return .figure
        case CollectionBindingID.generic: return .generic
        default: return nil
        }
    }

    /// The `sort_order` a NEW folder of this binding should take, or `nil` to
    /// accept the kernel default.
    ///
    /// `collection_ops::create` writes `sort_order: 0` when passed `nil`,
    /// matching `ImbibStore.create_manuscript_collection`, and manuscript /
    /// publication folders sort by name. `FigureStoreReader.createFolder`
    /// instead wrote `sort_order = folderCount` — read BEFORE the insert,
    /// from `fetchFolders().count` — so figure folders append in creation
    /// order. Preserved verbatim, now as the kernel's `sortOrder` argument
    /// rather than a follow-up `collectionReorder`.
    private static func newFolderSortOrder(
        _ bindingID: String, binding: SharedCollectionBinding, store: SharedStore
    ) -> Int64? {
        guard bindingID == CollectionBindingID.figure else { return nil }
        return Int64((try? store.collectionTree(binding: binding).count) ?? 0)
    }

    // MARK: - Undo action names
    //
    // Preserved EXACTLY as the delegated path registered them, so the Edit
    // menu reads identically after the delegation was dropped. They are the
    // Rust `undo_description` strings the old `UndoInfo`s carried — a
    // `SetPayload("name")` reads "Edit name", not "Rename Folder" — plus the
    // "Move Folder" this file already used for reparent. Renaming them to
    // folder prose is a deliberate UX change for another pass, not a
    // side effect of moving onto the kernel.

    enum UndoActionName {
        /// `RustStoreAdapter.updateField(field: "name")` → `undo_description`
        /// of `SetPayload("name")`.
        static let rename = "Edit name"
        /// `RustStoreAdapter.updateIntField(field: "sort_order")`, once per
        /// moved sibling.
        static let reorder = "Edit sort_order"
        /// `RustStoreAdapter.deleteItem(id:)`.
        static let delete = "Delete"
        /// `RustStoreAdapter.addToCollection` (`ImbibStore` hard-codes it).
        static let addMembers = "Add to Collection"
        /// NEW — the removal path was never undoable before the kernel
        /// returned the ids it actually removed. Named for its
        /// `RustStoreAdapter.removeFromCollection` twin.
        static let removeMembers = "Remove from Collection"
        /// Unchanged: this file has registered reparent undo since G2.
        static let reparent = "Move Folder"
    }

    // MARK: - Reads

    /// All collections of a binding, flat and ordered by `sort_order`.
    /// Callers assemble the tree from `parentID`.
    public func tree(_ bindingID: String) -> [CollectionKernelRow] {
        guard let store, let binding = Self.binding(for: bindingID) else { return [] }
        do {
            return try store.collectionTree(binding: binding).map(CollectionKernelRow.init)
        } catch {
            Self.logger.errorCapture(
                "collectionTree(\(bindingID)) failed: \(error)", category: "collections")
            return []
        }
    }

    /// Member counts aligned index-for-index with `collectionIDs`.
    public func memberCounts(_ bindingID: String, collectionIDs: [String]) -> [Int] {
        guard let store, let binding = Self.binding(for: bindingID),
              !collectionIDs.isEmpty else { return [] }
        do {
            return try store.collectionMemberCounts(
                binding: binding,
                collectionIds: collectionIDs.map { $0.lowercased() }
            ).map(Int.init)
        } catch {
            Self.logger.errorCapture(
                "collectionMemberCounts(\(bindingID)) failed: \(error)", category: "collections")
            return []
        }
    }

    /// Is `ancestorID` an ancestor of `descendantID` in the binding's tree?
    ///
    /// Swift-side pre-check ONLY, so the drag feedback can refuse a cycle
    /// before the drop (`canAcceptDrop`). The authoritative check is the
    /// kernel's, inside `reparent` — this returning `false` incorrectly costs
    /// a rejected reparent, never a corrupted tree.
    public func isAncestor(_ bindingID: String, ancestorID: String, of descendantID: String) -> Bool {
        let rows = tree(bindingID)
        let ancestor = ancestorID.lowercased()
        var current: String? = descendantID.lowercased()
        var hops = 0
        while let cid = current {
            guard let parentID = rows.first(where: { $0.id == cid })?.parentID else { return false }
            if parentID == ancestor { return true }
            current = parentID
            hops += 1
            if hops > 256 { return false }   // matches the kernel's MAX_TREE_DEPTH
        }
        return false
    }

    // MARK: - Structure

    /// Create a collection under `parentID` (nil = root).
    ///
    /// Posts a structural mutation, matching both paths this replaces
    /// (`RustStoreAdapter.createManuscriptCollection` → `didMutate()`,
    /// `FigureStoreReader.createFolder` → `postMutation(structural: true)`).
    @discardableResult
    public func create(
        _ bindingID: String,
        name: String,
        parentID: String? = nil
    ) -> CollectionKernelRow? {
        guard let store, let binding = Self.binding(for: bindingID) else { return nil }
        do {
            // Computed BEFORE the insert (the count must not include the new
            // row) and handed to the kernel, which used to need a follow-up
            // `collectionReorder` to emulate it.
            let sortOrder = Self.newFolderSortOrder(bindingID, binding: binding, store: store)
            let row = try store.collectionCreate(
                binding: binding,
                name: name,
                parentId: parentID?.lowercased(),
                kindScope: nil,
                sortOrder: sortOrder
            )
            RustStoreAdapter.shared.noteExternalMutation(structural: true)
            Self.logger.infoCapture(
                "created \(bindingID) collection '\(row.name)' (\(row.id)) "
                    + "parent=\(parentID ?? "root")",
                category: "collections")
            return CollectionKernelRow(row)
        } catch {
            Self.logger.errorCapture(
                "collectionCreate(\(bindingID)) failed: \(error)", category: "collections")
            return nil
        }
    }

    /// Rename a collection.
    ///
    /// Kernel `collection_rename`, whose `SharedCollectionMutation.prior`
    /// carries the name the row held before — the exact inverse, without the
    /// racy re-read the delegated path needed. Posts the SAME event the
    /// delegated `RustStoreAdapter.updateField` posted (non-structural, this
    /// id, `.otherField`) and registers the same Undo action name.
    public func rename(_ bindingID: String, id: String, to name: String) {
        guard let mutation = applyRename(bindingID, id: id, to: name) else { return }
        guard case .name(let priorName) = mutation.prior else { return }
        registerRenameUndo(
            bindingID, id: mutation.row.id, from: priorName, to: mutation.row.name)
    }

    /// Assign `ids` positions 0…n-1 among their siblings.
    ///
    /// One kernel `collection_reorder` per id, each with its own prior
    /// `sort_order` and its own Undo entry — matching the delegated loop,
    /// which registered one `updateIntField` undo per id and posted one
    /// non-structural event per id.
    public func reorder(_ bindingID: String, ids: [String]) {
        for (index, id) in ids.enumerated() {
            guard let mutation = applyReorder(bindingID, id: id, sortOrder: Int64(index)),
                  case .sortOrder(let priorOrder) = mutation.prior else { continue }
            registerReorderUndo(
                bindingID, id: mutation.row.id, from: priorOrder, to: Int64(index))
        }
    }

    /// Move a collection under `newParentID` (nil = make it a root).
    ///
    /// The cycle check is the KERNEL's (ADR-0022 D1) — Swift keeps only the
    /// drag-feedback pre-check in `isAncestor`. A rejection here is logged as
    /// a warning and returns `false`; it must never crash the sidebar.
    /// Registers an Undo entry that moves the collection back.
    @discardableResult
    public func reparent(_ bindingID: String, id: String, newParentID: String?) -> Bool {
        guard let mutation = applyReparent(bindingID, id: id, newParentID: newParentID) else {
            return false
        }
        guard case .parent(let previousParent) = mutation.prior else { return true }
        registerReparentUndo(
            bindingID, id: mutation.row.id, from: previousParent, to: newParentID?.lowercased())
        return true
    }

    private func registerReparentUndo(
        _ bindingID: String, id: String, from previousParent: String?, to newParent: String?
    ) {
        UndoCoordinator.shared.registerUndoClosure(
            actionName: UndoActionName.reparent,
            undo: { [weak self] in
                _ = self?.applyReparent(bindingID, id: id, newParentID: previousParent)
            },
            redo: { [weak self] in
                _ = self?.applyReparent(bindingID, id: id, newParentID: newParent)
            }
        )
    }

    private func registerRenameUndo(
        _ bindingID: String, id: String, from previousName: String, to newName: String
    ) {
        UndoCoordinator.shared.registerUndoClosure(
            actionName: UndoActionName.rename,
            undo: { [weak self] in
                _ = self?.applyRename(bindingID, id: id, to: previousName)
            },
            redo: { [weak self] in
                _ = self?.applyRename(bindingID, id: id, to: newName)
            }
        )
    }

    private func registerReorderUndo(
        _ bindingID: String, id: String, from previousOrder: Int64, to newOrder: Int64
    ) {
        UndoCoordinator.shared.registerUndoClosure(
            actionName: UndoActionName.reorder,
            undo: { [weak self] in
                _ = self?.applyReorder(bindingID, id: id, sortOrder: previousOrder)
            },
            redo: { [weak self] in
                _ = self?.applyReorder(bindingID, id: id, sortOrder: newOrder)
            }
        )
    }

    /// Delete a collection. Members are NEVER deleted — `Contains` edges
    /// vanish with the row (FK CASCADE) and envelope-filed members are
    /// unfiled (`parent_id … ON DELETE SET NULL`), which is exactly what the
    /// figure path used to do by hand before deleting.
    ///
    /// Kernel `collection_delete` returns the `SharedDeletedCollection`
    /// snapshot — original id, envelope parent, dropped members, orphaned
    /// child collections — and `collection_restore` puts all of it back. That
    /// is strictly MORE than the delegated `RustStoreAdapter.deleteItem`
    /// restored (an item snapshot, no membership, no re-attached children),
    /// under the same "Delete" action name.
    public func delete(_ bindingID: String, id: String) {
        guard let snapshot = applyDelete(bindingID, id: id) else { return }
        registerDeleteUndo(bindingID, snapshot: snapshot)
    }

    private func registerDeleteUndo(_ bindingID: String, snapshot: SharedDeletedCollection) {
        UndoCoordinator.shared.registerUndoClosure(
            actionName: UndoActionName.delete,
            undo: { [weak self] in
                _ = self?.applyRestore(bindingID, snapshot: snapshot)
            },
            redo: { [weak self] in
                _ = self?.applyDelete(bindingID, id: snapshot.row.id)
            }
        )
    }

    // MARK: - Membership

    /// File `itemIDs` into `collectionID`. Membership mechanics (Contains
    /// edge vs. envelope parent) are the kernel's business — ONE path for
    /// both now that `collection_add_members` reports the ids it actually
    /// changed and the Contains bindings no longer need
    /// `RustStoreAdapter.addToCollection` for their undo entry.
    ///
    /// The undo removes only what was actually added, so an item that was
    /// already a member is never unfiled by undoing someone else's drop.
    @discardableResult
    public func addMembers(_ bindingID: String, collectionID: String, itemIDs: [String]) -> Bool {
        guard let changed = applyAddMembers(
            bindingID, collectionID: collectionID, itemIDs: itemIDs) else { return false }
        if !changed.isEmpty {
            registerMembershipUndo(
                bindingID, collectionID: collectionID.lowercased(),
                itemIDs: changed, wasAdd: true)
        }
        return true
    }

    private func registerMembershipUndo(
        _ bindingID: String, collectionID: String, itemIDs: [String], wasAdd: Bool
    ) {
        let add: @MainActor () -> Void = { [weak self] in
            _ = self?.applyAddMembers(bindingID, collectionID: collectionID, itemIDs: itemIDs)
        }
        let remove: @MainActor () -> Void = { [weak self] in
            _ = self?.applyRemoveMembers(bindingID, collectionID: collectionID, itemIDs: itemIDs)
        }
        UndoCoordinator.shared.registerUndoClosure(
            actionName: wasAdd ? UndoActionName.addMembers : UndoActionName.removeMembers,
            undo: wasAdd ? remove : add,
            redo: wasAdd ? add : remove
        )
    }

    /// Unfile `itemIDs` from whatever collection of this binding holds them.
    /// Only meaningful for envelope bindings (the Figures "Unfiled" drop
    /// target); Contains bindings have no such sidebar affordance today.
    @discardableResult
    public func unfile(_ bindingID: String, itemIDs: [String]) -> Bool {
        guard let store, Self.binding(for: bindingID) != nil,
              !Self.usesContainsEdge(bindingID), !itemIDs.isEmpty else { return false }
        var moved = false
        for itemID in itemIDs {
            do {
                try store.setParent(id: itemID.lowercased(), parentId: nil)
                moved = true
            } catch {
                Self.logger.errorCapture(
                    "unfile(\(bindingID), \(itemID)) failed: \(error)", category: "collections")
            }
        }
        if moved { RustStoreAdapter.shared.noteExternalMutation(structural: true) }
        return moved
    }

    /// Remove `itemIDs` from `collectionID` without touching the items.
    ///
    /// Undoable since the kernel started reporting the ids it actually
    /// removed — re-filing a non-member was the reason this path had no undo
    /// before.
    @discardableResult
    public func removeMembers(_ bindingID: String, collectionID: String, itemIDs: [String]) -> Bool {
        guard let changed = applyRemoveMembers(
            bindingID, collectionID: collectionID, itemIDs: itemIDs) else { return false }
        if !changed.isEmpty {
            registerMembershipUndo(
                bindingID, collectionID: collectionID.lowercased(),
                itemIDs: changed, wasAdd: false)
        }
        return true
    }

    /// Whether a binding records membership as a `Contains` edge (as opposed
    /// to the envelope parent). Mirrors `collection_ops::Membership`.
    private static func usesContainsEdge(_ bindingID: String) -> Bool {
        bindingID != CollectionBindingID.figure
    }

    // MARK: - Raw kernel verbs (event-posting, NOT undo-registering)
    //
    // Rule 3 in the file header: the public verbs above register the Undo
    // entry, these perform the mutation and post the event. Undo/redo
    // closures call THESE. Each posts exactly the event the path it replaced
    // posted — non-structural + affected id + `.otherField` where the
    // delegated `updateField`/`updateIntField` did, structural otherwise.

    @discardableResult
    private func applyRename(
        _ bindingID: String, id: String, to name: String
    ) -> SharedCollectionMutation? {
        guard let store, let binding = Self.binding(for: bindingID) else { return nil }
        let lowerID = id.lowercased()
        do {
            let mutation = try store.collectionRename(
                binding: binding, id: lowerID, name: name)
            noteFieldMutation(lowerID)
            Self.logger.infoCapture(
                "renamed \(bindingID) collection \(lowerID) → '\(mutation.row.name)'",
                category: "collections")
            return mutation
        } catch {
            Self.logger.errorCapture(
                "collectionRename(\(bindingID), \(lowerID)) failed: \(error)",
                category: "collections")
            return nil
        }
    }

    @discardableResult
    private func applyReorder(
        _ bindingID: String, id: String, sortOrder: Int64
    ) -> SharedCollectionMutation? {
        guard let store, let binding = Self.binding(for: bindingID) else { return nil }
        let lowerID = id.lowercased()
        do {
            let mutation = try store.collectionReorder(
                binding: binding, id: lowerID, sortOrder: sortOrder)
            noteFieldMutation(lowerID)
            return mutation
        } catch {
            Self.logger.errorCapture(
                "collectionReorder(\(bindingID), \(lowerID)) failed: \(error)",
                category: "collections")
            return nil
        }
    }

    @discardableResult
    private func applyReparent(
        _ bindingID: String, id: String, newParentID: String?
    ) -> SharedCollectionMutation? {
        guard let store, let binding = Self.binding(for: bindingID) else { return nil }
        let lowerID = id.lowercased()
        do {
            let mutation = try store.collectionReparent(
                binding: binding, id: lowerID, newParentId: newParentID?.lowercased())
            RustStoreAdapter.shared.noteExternalMutation(structural: true)
            Self.logger.infoCapture(
                "reparented \(bindingID) collection \(lowerID) → \(newParentID ?? "root")",
                category: "collections")
            return mutation
        } catch {
            // The Rust cycle check is the backstop behind `canAcceptDrop`'s
            // pre-check; a rejection here means the two disagreed (stale
            // tree, concurrent edit). Log and carry on.
            Self.logger.warningCapture(
                "collectionReparent(\(bindingID), \(lowerID) → \(newParentID ?? "root")) "
                    + "rejected: \(error)",
                category: "collections")
            return nil
        }
    }

    @discardableResult
    private func applyDelete(_ bindingID: String, id: String) -> SharedDeletedCollection? {
        guard let store, let binding = Self.binding(for: bindingID) else { return nil }
        let lowerID = id.lowercased()
        do {
            let snapshot = try store.collectionDelete(binding: binding, id: lowerID)
            RustStoreAdapter.shared.noteExternalMutation(structural: true)
            Self.logger.infoCapture(
                "deleted \(bindingID) collection \(lowerID) "
                    + "(members unfiled: \(snapshot.memberIds.count), "
                    + "children re-rooted: \(snapshot.childCollectionIds.count))",
                category: "collections")
            return snapshot
        } catch {
            Self.logger.errorCapture(
                "collectionDelete(\(bindingID), \(lowerID)) failed: \(error)",
                category: "collections")
            return nil
        }
    }

    @discardableResult
    private func applyRestore(
        _ bindingID: String, snapshot: SharedDeletedCollection
    ) -> CollectionKernelRow? {
        guard let store, let binding = Self.binding(for: bindingID) else { return nil }
        do {
            let row = try store.collectionRestore(binding: binding, snapshot: snapshot)
            RustStoreAdapter.shared.noteExternalMutation(structural: true)
            Self.logger.infoCapture(
                "restored \(bindingID) collection '\(row.name)' (\(row.id))",
                category: "collections")
            return CollectionKernelRow(row)
        } catch {
            Self.logger.errorCapture(
                "collectionRestore(\(bindingID), \(snapshot.row.id)) failed: \(error)",
                category: "collections")
            return nil
        }
    }

    /// Returns the ids that ACTUALLY became members (`nil` = the verb failed
    /// or was refused before it ran).
    @discardableResult
    private func applyAddMembers(
        _ bindingID: String, collectionID: String, itemIDs: [String]
    ) -> [String]? {
        guard let store, let binding = Self.binding(for: bindingID), !itemIDs.isEmpty else {
            return nil
        }
        do {
            let changed = try store.collectionAddMembers(
                binding: binding,
                collectionId: collectionID.lowercased(),
                itemIds: itemIDs.map { $0.lowercased() })
            RustStoreAdapter.shared.noteExternalMutation(structural: true)
            Self.logger.infoCapture(
                "filed \(changed.count)/\(itemIDs.count) item(s) into "
                    + "\(bindingID) collection \(collectionID.lowercased())",
                category: "collections")
            return changed
        } catch {
            Self.logger.errorCapture(
                "collectionAddMembers(\(bindingID)) failed: \(error)", category: "collections")
            return nil
        }
    }

    /// Returns the ids that were ACTUALLY removed (`nil` = the verb failed).
    @discardableResult
    private func applyRemoveMembers(
        _ bindingID: String, collectionID: String, itemIDs: [String]
    ) -> [String]? {
        guard let store, let binding = Self.binding(for: bindingID), !itemIDs.isEmpty else {
            return nil
        }
        do {
            let changed = try store.collectionRemoveMembers(
                binding: binding,
                collectionId: collectionID.lowercased(),
                itemIds: itemIDs.map { $0.lowercased() })
            RustStoreAdapter.shared.noteExternalMutation(structural: true)
            Self.logger.infoCapture(
                "unfiled \(changed.count)/\(itemIDs.count) item(s) from "
                    + "\(bindingID) collection \(collectionID.lowercased())",
                category: "collections")
            return changed
        } catch {
            Self.logger.errorCapture(
                "collectionRemoveMembers(\(bindingID)) failed: \(error)", category: "collections")
            return nil
        }
    }

    /// The event the delegated `RustStoreAdapter.updateField` /
    /// `updateIntField` posted for a single-field write: non-structural, one
    /// affected id, `.otherField`. A non-UUID id (never produced by the
    /// kernel) degrades to the id-less form rather than dropping the event.
    private func noteFieldMutation(_ lowercasedID: String) {
        RustStoreAdapter.shared.noteExternalMutation(
            structural: false,
            affectedIDs: UUID(uuidString: lowercasedID).map { [$0] },
            kind: .otherField
        )
    }
}
#endif
