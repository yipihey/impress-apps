// Persistence SEAM file — CROSS-PLATFORM (macOS + iOS).
//
// De-gated from `#if os(macOS)` in Stage 4b. Nothing in this file was ever
// AppKit: it is Foundation + the `SharedStore` FFI, and the two things that
// pinned it to imbib's macOS chassis — `RustStoreAdapter.shared` for the
// mutation fan-out and `UndoCoordinator.shared` for undo — are now injected as a
// `StoreKernelScope`. That is what lets imprint (macOS AND iOS) run its
// manuscript folders through this file instead of the ~350-line hand-rolled
// second client it carried in `ManuscriptStoreAdapter`.
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
//     matched by string equality (see the imbib CLAUDE.md invariant, which
//     `RustStoreAdapter.createManuscriptCollection` used to exemplify before
//     ADR-0022 F3 deleted it as the last legacy manuscript-folder writer —
//     this file is now the only place that does it). Every id crossing this
//     file is `.lowercased()` on the way in.
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
    /// Lowercase UUID string of the OWNING CONTAINER — imbib's library — for
    /// bindings with a container axis (ADR-0022 C2); `nil` for manuscript and
    /// figure folders, which are global. NEVER the tree parent: that is
    /// `parentID`, and conflating the two is the c902a22f regression.
    public let containerID: String?
    /// Is this a SMART (query-defined) collection? The per-row predicate
    /// `CollectionCapability.allowsOrganize(isSmart:tier:)` consumes; `false`
    /// for bindings whose schema has no such field.
    public let isSmart: Bool
    /// Member count — the outgoing `Contains`-edge count for edge-membership
    /// bindings (exactly imbib-core `list_collections`' `publication_count`),
    /// the filed-children count for envelope bindings. Carried on the row so a
    /// kernel tree read is a drop-in for the legacy per-kind list exports.
    public let memberCount: Int

    init(_ row: SharedCollectionRow) {
        self.id = row.id
        self.name = row.name
        self.parentID = row.parentId
        self.sortOrder = row.sortOrder
        self.containerID = row.containerId
        self.isSmart = row.isSmart
        self.memberCount = Int(row.memberCount)
    }
}

@MainActor
public final class CollectionStoreAdapter {

    public static let shared = CollectionStoreAdapter()

    private static let logger = Logger(subsystem: "com.imbib.app", category: "collections")

    /// The host hooks every verb runs on: store handle, mutation fan-out, undo.
    /// `shared`'s scope is imbib's historical behaviour verbatim (own
    /// `SharedStore` handle, `RustStoreAdapter.noteExternalMutation`,
    /// `UndoCoordinator`); a sibling app hands its own.
    public private(set) var scope: StoreKernelScope

    /// Handle on the shared impress store.
    private var store: SharedStore? { scope.store }

    /// imbib's adapter. Opens its own handle exactly like `FigureStoreReader`
    /// (same database as `RustStoreAdapter`'s `ImbibStore` —
    /// `SharedWorkspace.databasePath`; WAL permits concurrent handles
    /// in-process and across processes).
    private init() {
        var opened: SharedStore?
        do {
            try SharedWorkspace.ensureDirectoryExists()
            opened = try SharedStore.open(path: SharedWorkspace.databasePath)
        } catch {
            Self.logger.error("CollectionStoreAdapter failed to open shared store: \(error)")
        }
        self.scope = StoreKernelScope(
            store: opened,
            undoTarget: nil,
            defaultUndo: .coordinator,
            noteMutation: { structural, affectedIDs, kind in
                RustStoreAdapter.shared.noteExternalMutation(
                    structural: structural, affectedIDs: affectedIDs, kind: kind)
            }
        )
        self.scope.undoTarget = self
    }

    /// A sibling app's adapter, on ITS store handle, ITS mutation fan-out and
    /// ITS undo plumbing. `undoTarget` defaults to this adapter, which is what
    /// `UndoManager.removeAllActions(withTarget:)` keys on; a host that
    /// registered against a different object before adopting this file (imprint
    /// registered against `ManuscriptStoreAdapter`) passes that object so its
    /// undo stack stays keyed the way it always was.
    public init(scope: StoreKernelScope) {
        self.scope = scope
        if self.scope.undoTarget == nil { self.scope.undoTarget = self }
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

    public enum UndoActionName {
        /// The folder-creation inverse. imbib's sidebar has never registered
        /// one (its `create` defaults to `.disabled`, preserving that); imprint
        /// has, under this exact string, since it hand-rolled the kernel.
        public static let create = StoreKernelUndoAction.createCollection
        /// `RustStoreAdapter.updateField(field: "name")` → `undo_description`
        /// of `SetPayload("name")`.
        public static let rename = StoreKernelUndoAction.renameCollection
        /// `RustStoreAdapter.updateIntField(field: "sort_order")`, once per
        /// moved sibling.
        public static let reorder = StoreKernelUndoAction.reorderCollection
        /// `RustStoreAdapter.deleteItem(id:)`.
        public static let delete = StoreKernelUndoAction.deleteCollection
        /// `RustStoreAdapter.addToCollection` (`ImbibStore` hard-codes it).
        public static let addMembers = StoreKernelUndoAction.addMembers
        /// NEW — the removal path was never undoable before the kernel
        /// returned the ids it actually removed. Named for its
        /// `RustStoreAdapter.removeFromCollection` twin.
        public static let removeMembers = StoreKernelUndoAction.removeMembers
        /// Unchanged: this file has registered reparent undo since G2.
        public static let reparent = StoreKernelUndoAction.reparentCollection
    }

    // MARK: - Reads

    /// All collections of a binding, flat and ordered by `sort_order`.
    /// Callers assemble the tree from `parentID`.
    public func tree(_ bindingID: String) -> [CollectionKernelRow] {
        tree(bindingID, in: nil)
    }

    /// The collections of ONE owning container, flat and ordered by
    /// `sort_order` (ADR-0022 C2). `containerID: nil`, or a binding with no
    /// container axis, answers exactly as `tree(_:)` does.
    ///
    /// **This is the migration-safe read.** `RustStoreAdapter.listCollections(libraryId:)`
    /// goes through imbib-core's `list_collections`, which hard-codes
    /// `schema_ref = "imbib/collection"` and returns NOTHING once the
    /// `collections.unified` flag is flipped (WP G7). This resolves the binding
    /// against the marker and filters on the envelope, which the migration
    /// never touches — so it answers identically on both sides of the flip.
    public func tree(_ bindingID: String, in containerID: String?) -> [CollectionKernelRow] {
        guard let store, let binding = Self.binding(for: bindingID) else { return [] }
        do {
            return try store.collectionTreeIn(
                binding: binding, containerId: containerID?.lowercased()
            ).map(CollectionKernelRow.init)
        } catch {
            Self.logger.errorCapture(
                "collectionTree(\(bindingID)) failed: \(error)", category: "collections")
            return []
        }
    }

    /// One row by id, from the binding's tree. Convenience for the sidebar
    /// sites that need a row's `isSmart` / `containerID` to decide what to
    /// offer, without each of them re-implementing the lookup.
    public func row(_ bindingID: String, id: String) -> CollectionKernelRow? {
        let wanted = id.lowercased()
        return tree(bindingID).first { $0.id == wanted }
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
    /// - Parameter undo: defaults to `.disabled`, NOT to the scope default —
    ///   imbib's sidebar has never made "New Folder" undoable, and adopting a
    ///   shared verb must not silently add an Edit-menu entry. imprint passes
    ///   its `UndoManager` and gets the "New Folder" inverse it always had.
    /// - Parameter containerID: the OWNING CONTAINER the new collection belongs
    ///   to (ADR-0022 C2) — imbib's library, which a ROOT collection cannot
    ///   inherit from a parent because it has none. `nil` keeps the historical
    ///   inherit-from-parent rule, and is what manuscript and figure folders
    ///   (which have no container axis) always pass.
    @discardableResult
    public func create(
        _ bindingID: String,
        name: String,
        parentID: String? = nil,
        kindScope: String? = nil,
        containerID: String? = nil,
        undo: StoreUndoScope = .disabled
    ) -> CollectionKernelRow? {
        guard let store, let binding = Self.binding(for: bindingID) else { return nil }
        do {
            // Computed BEFORE the insert (the count must not include the new
            // row) and handed to the kernel, which used to need a follow-up
            // `collectionReorder` to emulate it.
            let sortOrder = Self.newFolderSortOrder(bindingID, binding: binding, store: store)
            let row = try store.collectionCreateIn(
                binding: binding,
                name: name,
                parentId: parentID?.lowercased(),
                kindScope: kindScope,
                sortOrder: sortOrder,
                containerId: containerID?.lowercased()
            )
            scope.noteMutation(true, nil, nil)
            Self.logger.infoCapture(
                "created \(bindingID) collection '\(row.name)' (\(row.id)) "
                    + "parent=\(parentID ?? "root")",
                category: "collections")
            registerExistenceUndo(bindingID, id: row.id, deletedSnapshot: nil, undo: undo)
            return CollectionKernelRow(row)
        } catch {
            Self.logger.errorCapture(
                "collectionCreate(\(bindingID)) failed: \(error)", category: "collections")
            return nil
        }
    }

    /// The create/delete inverse, as ONE alternating registration.
    ///
    /// Delete and restore cannot use a symmetric closure pair: the snapshot only
    /// exists after a delete has run, so the two directions are mutually
    /// recursive rather than closures over one captured value.
    /// `StoreKernelScope.registerAlternating` carries the produced snapshot in a
    /// box, which is `ManuscriptStoreAdapter`'s mutually-recursive
    /// `registerCollection{Exists,Deleted}Undo` pair generalised.
    ///
    /// - Parameter deletedSnapshot: `nil` when the row currently EXISTS (⌘Z must
    ///   delete it), the delete snapshot when it has just been removed (⌘Z must
    ///   restore it).
    private func registerExistenceUndo(
        _ bindingID: String,
        id: String,
        deletedSnapshot: SharedDeletedCollection?,
        undo: StoreUndoScope?
    ) {
        scope.registerAlternating(
            undo,
            actionName: deletedSnapshot == nil
                ? UndoActionName.create : UndoActionName.delete,
            capturedValue: deletedSnapshot,
            produce: { [weak self] in self?.applyDelete(bindingID, id: id) },
            consume: { [weak self] snapshot in
                _ = self?.applyRestore(bindingID, snapshot: snapshot)
            }
        )
    }

    /// Rename a collection.
    ///
    /// Kernel `collection_rename`, whose `SharedCollectionMutation.prior`
    /// carries the name the row held before — the exact inverse, without the
    /// racy re-read the delegated path needed. Posts the SAME event the
    /// delegated `RustStoreAdapter.updateField` posted (non-structural, this
    /// id, `.otherField`) and registers the same Undo action name.
    @discardableResult
    public func rename(
        _ bindingID: String, id: String, to name: String, undo: StoreUndoScope? = nil
    ) -> Bool {
        guard let mutation = applyRename(bindingID, id: id, to: name) else { return false }
        guard case .name(let priorName) = mutation.prior else { return true }
        let rowID = mutation.row.id
        let newName = mutation.row.name
        scope.registerReversible(
            undo,
            actionName: UndoActionName.rename,
            undo: { [weak self] in _ = self?.applyRename(bindingID, id: rowID, to: priorName) },
            redo: { [weak self] in _ = self?.applyRename(bindingID, id: rowID, to: newName) }
        )
        return true
    }

    /// Assign `ids` positions 0…n-1 among their siblings.
    ///
    /// One kernel `collection_reorder` per id, each with its own prior
    /// `sort_order` and its own Undo entry — matching the delegated loop,
    /// which registered one `updateIntField` undo per id and posted one
    /// non-structural event per id.
    public func reorder(_ bindingID: String, ids: [String], undo: StoreUndoScope? = nil) {
        for (index, id) in ids.enumerated() {
            guard let mutation = applyReorder(bindingID, id: id, sortOrder: Int64(index)),
                  case .sortOrder(let priorOrder) = mutation.prior else { continue }
            let rowID = mutation.row.id
            let newOrder = Int64(index)
            scope.registerReversible(
                undo,
                actionName: UndoActionName.reorder,
                undo: { [weak self] in
                    _ = self?.applyReorder(bindingID, id: rowID, sortOrder: priorOrder)
                },
                redo: { [weak self] in
                    _ = self?.applyReorder(bindingID, id: rowID, sortOrder: newOrder)
                }
            )
        }
    }

    /// Move a collection under `newParentID` (nil = make it a root).
    ///
    /// The cycle check is the KERNEL's (ADR-0022 D1) — Swift keeps only the
    /// drag-feedback pre-check in `isAncestor`. A rejection here is logged as
    /// a warning and returns `false`; it must never crash the sidebar.
    /// Registers an Undo entry that moves the collection back.
    /// - Parameter newContainerID: the container to move INTO (ADR-0022 C2).
    ///   `nil` means "leave the owning container alone", which is what a
    ///   same-library move wants: the legacy Swift path skipped its
    ///   `reparentItem` write entirely when the library did not change, and so
    ///   does this. A cross-library move passes the destination library and the
    ///   kernel performs both writes in one `store.update`.
    @discardableResult
    public func reparent(
        _ bindingID: String, id: String, newParentID: String?,
        newContainerID: String? = nil, undo: StoreUndoScope? = nil
    ) -> Bool {
        guard let mutation = applyReparent(
            bindingID, id: id, newParentID: newParentID, newContainerID: newContainerID)
        else {
            return false
        }
        // Two priors, two inverses. `.parent` means the container did not move,
        // so its inverse must not start writing one; `.parentInContainer`
        // carries both fields and restores both. Same action name either way —
        // the Edit menu still reads "Move Folder".
        let rowID = mutation.row.id
        let newParent = newParentID?.lowercased()
        let newContainer = newContainerID?.lowercased()
        let priorParent: String?
        let priorContainer: String?
        switch mutation.prior {
        case .parent(let previousParent):
            priorParent = previousParent
            priorContainer = nil
        case .parentInContainer(let previousParent, let previousContainer):
            priorParent = previousParent
            priorContainer = previousContainer
        default:
            return true
        }
        scope.registerReversible(
            undo,
            actionName: UndoActionName.reparent,
            undo: { [weak self] in
                _ = self?.applyReparent(
                    bindingID, id: rowID, newParentID: priorParent,
                    newContainerID: priorContainer)
            },
            redo: { [weak self] in
                _ = self?.applyReparent(
                    bindingID, id: rowID, newParentID: newParent,
                    newContainerID: newContainer)
            }
        )
        return true
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
    @discardableResult
    public func delete(_ bindingID: String, id: String, undo: StoreUndoScope? = nil) -> Bool {
        guard let snapshot = applyDelete(bindingID, id: id) else { return false }
        registerExistenceUndo(
            bindingID, id: snapshot.row.id, deletedSnapshot: snapshot, undo: undo)
        return true
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
    public func addMembers(
        _ bindingID: String, collectionID: String, itemIDs: [String],
        undo: StoreUndoScope? = nil
    ) -> Bool {
        guard let changed = applyAddMembers(
            bindingID, collectionID: collectionID, itemIDs: itemIDs) else { return false }
        if !changed.isEmpty {
            registerMembershipUndo(
                bindingID, collectionID: collectionID.lowercased(),
                itemIDs: changed, wasAdd: true, undo: undo)
        }
        return true
    }

    /// Ids that ACTUALLY became members, so an item already filed is never
    /// unfiled by undoing someone else's drop. Returns `nil` when the verb
    /// failed or was refused before it ran.
    @discardableResult
    public func addMembersReportingChanges(
        _ bindingID: String, collectionID: String, itemIDs: [String],
        undo: StoreUndoScope? = nil
    ) -> [String]? {
        guard let changed = applyAddMembers(
            bindingID, collectionID: collectionID, itemIDs: itemIDs) else { return nil }
        if !changed.isEmpty {
            registerMembershipUndo(
                bindingID, collectionID: collectionID.lowercased(),
                itemIDs: changed, wasAdd: true, undo: undo)
        }
        return changed
    }

    /// Ids that were ACTUALLY removed (`nil` = the verb failed).
    @discardableResult
    public func removeMembersReportingChanges(
        _ bindingID: String, collectionID: String, itemIDs: [String],
        undo: StoreUndoScope? = nil
    ) -> [String]? {
        guard let changed = applyRemoveMembers(
            bindingID, collectionID: collectionID, itemIDs: itemIDs) else { return nil }
        if !changed.isEmpty {
            registerMembershipUndo(
                bindingID, collectionID: collectionID.lowercased(),
                itemIDs: changed, wasAdd: false, undo: undo)
        }
        return changed
    }

    private func registerMembershipUndo(
        _ bindingID: String, collectionID: String, itemIDs: [String], wasAdd: Bool,
        undo: StoreUndoScope?
    ) {
        let add: @MainActor () -> Void = { [weak self] in
            _ = self?.applyAddMembers(bindingID, collectionID: collectionID, itemIDs: itemIDs)
        }
        let remove: @MainActor () -> Void = { [weak self] in
            _ = self?.applyRemoveMembers(bindingID, collectionID: collectionID, itemIDs: itemIDs)
        }
        scope.registerReversible(
            undo,
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
        if moved { scope.noteMutation(true, nil, nil) }
        return moved
    }

    /// Remove `itemIDs` from `collectionID` without touching the items.
    ///
    /// Undoable since the kernel started reporting the ids it actually
    /// removed — re-filing a non-member was the reason this path had no undo
    /// before.
    @discardableResult
    public func removeMembers(
        _ bindingID: String, collectionID: String, itemIDs: [String],
        undo: StoreUndoScope? = nil
    ) -> Bool {
        guard let changed = applyRemoveMembers(
            bindingID, collectionID: collectionID, itemIDs: itemIDs) else { return false }
        if !changed.isEmpty {
            registerMembershipUndo(
                bindingID, collectionID: collectionID.lowercased(),
                itemIDs: changed, wasAdd: false, undo: undo)
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
        _ bindingID: String, id: String, newParentID: String?, newContainerID: String? = nil
    ) -> SharedCollectionMutation? {
        guard let store, let binding = Self.binding(for: bindingID) else { return nil }
        let lowerID = id.lowercased()
        do {
            let mutation = try store.collectionReparentIn(
                binding: binding, id: lowerID,
                newParentId: newParentID?.lowercased(),
                newContainerId: newContainerID?.lowercased())
            scope.noteMutation(true, nil, nil)
            Self.logger.infoCapture(
                "reparented \(bindingID) collection \(lowerID) → \(newParentID ?? "root")"
                    + (newContainerID.map { " (container \($0))" } ?? ""),
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
            scope.noteMutation(true, nil, nil)
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
            scope.noteMutation(true, nil, nil)
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
            scope.noteMutation(true, nil, nil)
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
            scope.noteMutation(true, nil, nil)
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
        scope.noteMutation(false, UUID(uuidString: lowercasedID).map { [$0] }, .otherField)
    }
}
