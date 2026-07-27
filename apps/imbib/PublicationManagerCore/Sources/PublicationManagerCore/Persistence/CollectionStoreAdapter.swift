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
//  STRANGLER STATE (ADR-0022 G2). `create`, `reparent`, `addMembers`,
//  `removeMembers`, `tree` and `memberCounts` run on the kernel. `rename`,
//  `reorder` and `delete` still delegate to `RustStoreAdapter`'s field-update
//  / snapshot-delete ops because the kernel FFI returns no `UndoInfo` and
//  `collection_delete` cannot restore a deleted row — routing them through
//  the kernel today would silently drop ⌘Z. Each carries a
//  `// G2-strangler TODO`. The sidebar view model does not know the
//  difference: it only ever calls this adapter.
//

import Foundation
import ImpressKit
import ImpressRustCore
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

    /// Bindings whose new folders append to the END of the sibling order
    /// rather than sorting alphabetically.
    ///
    /// `collection_ops::create` always writes `sort_order: 0`, matching
    /// `ImbibStore.create_manuscript_collection`. `FigureStoreReader
    /// .createFolder` instead wrote `sort_order = folderCount`, so figure
    /// folders appended in creation order. Preserved verbatim here.
    ///
    /// G2-strangler TODO: fold this into the kernel by giving
    /// `collection_ops::create` an explicit sort-order argument, then delete
    /// the set.
    private static let appendsNewFoldersToEnd: Set<String> = [CollectionBindingID.figure]

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
            var row = try store.collectionCreate(
                binding: binding,
                name: name,
                parentId: parentID?.lowercased(),
                kindScope: nil
            )
            if Self.appendsNewFoldersToEnd.contains(bindingID) {
                // Sibling count BEFORE the insert — the legacy figure path
                // read `fetchFolders().count` ahead of creating the row.
                let total = (try? store.collectionTree(binding: binding).count) ?? 1
                let position = Int64(max(0, total - 1))
                row = (try? store.collectionReorder(
                    binding: binding, id: row.id, sortOrder: position)) ?? row
            }
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
    /// G2-strangler TODO: `SharedStore.collectionRename` performs the same
    /// `SetPayload("name")` but returns no `UndoInfo`, so calling it here
    /// would drop the Undo entry every rename registers today. Delegated to
    /// the undoable generic field update until the kernel FFI carries undo
    /// information.
    public func rename(_ bindingID: String, id: String, to name: String) {
        guard Self.binding(for: bindingID) != nil,
              let uuid = UUID(uuidString: id) else { return }
        RustStoreAdapter.shared.updateField(id: uuid, field: "name", value: name)
    }

    /// Assign `ids` positions 0…n-1 among their siblings.
    ///
    /// G2-strangler TODO: `SharedStore.collectionReorder` is the kernel twin
    /// of this loop, but — like rename — returns no `UndoInfo`. Delegated to
    /// the undoable generic int-field update.
    public func reorder(_ bindingID: String, ids: [String]) {
        guard Self.binding(for: bindingID) != nil else { return }
        for (index, id) in ids.enumerated() {
            guard let uuid = UUID(uuidString: id) else { continue }
            RustStoreAdapter.shared.updateIntField(
                id: uuid, field: "sort_order", value: Int64(index))
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
        guard let store, let binding = Self.binding(for: bindingID) else { return false }
        let lowerID = id.lowercased()
        let previousParent = tree(bindingID).first { $0.id == lowerID }?.parentID
        do {
            _ = try store.collectionReparent(
                binding: binding, id: lowerID, newParentId: newParentID?.lowercased())
            RustStoreAdapter.shared.noteExternalMutation(structural: true)
            Self.logger.infoCapture(
                "reparented \(bindingID) collection \(lowerID) → \(newParentID ?? "root")",
                category: "collections")
            registerReparentUndo(bindingID, id: lowerID, from: previousParent, to: newParentID)
            return true
        } catch {
            // The Rust cycle check is the backstop behind `canAcceptDrop`'s
            // pre-check; a rejection here means the two disagreed (stale
            // tree, concurrent edit). Log and carry on.
            Self.logger.warningCapture(
                "collectionReparent(\(bindingID), \(lowerID) → \(newParentID ?? "root")) "
                    + "rejected: \(error)",
                category: "collections")
            return false
        }
    }

    private func registerReparentUndo(
        _ bindingID: String, id: String, from previousParent: String?, to newParent: String?
    ) {
        UndoCoordinator.shared.registerUndoClosure(
            actionName: "Move Folder",
            undo: { [weak self] in
                _ = self?.reparent(bindingID, id: id, newParentID: previousParent)
            },
            redo: { [weak self] in
                _ = self?.reparent(bindingID, id: id, newParentID: newParent)
            }
        )
    }

    /// Delete a collection. Members are NEVER deleted — `Contains` edges
    /// vanish with the row (FK CASCADE) and envelope-filed members are
    /// unfiled (`parent_id … ON DELETE SET NULL`), which is exactly what the
    /// figure path used to do by hand before deleting.
    ///
    /// G2-strangler TODO: `SharedStore.collectionDelete` is the kernel twin,
    /// but it cannot restore a deleted row, so it would drop the undoable
    /// delete every folder deletion registers today. Delegated to the
    /// snapshotting generic delete until the kernel grows a restore verb.
    public func delete(_ bindingID: String, id: String) {
        guard Self.binding(for: bindingID) != nil,
              let uuid = UUID(uuidString: id) else { return }
        RustStoreAdapter.shared.deleteItem(id: uuid)
        Self.logger.infoCapture("deleted \(bindingID) collection \(id)", category: "collections")
    }

    // MARK: - Membership

    /// File `itemIDs` into `collectionID`. Membership mechanics (Contains
    /// edge vs. envelope parent) are the kernel's business.
    ///
    /// Contains-edge bindings delegate to the undoable
    /// `RustStoreAdapter.addToCollection` (G2-strangler TODO: the kernel's
    /// `collection_add_members` returns no `UndoInfo`); envelope bindings —
    /// which have never been undoable — run on the kernel.
    @discardableResult
    public func addMembers(_ bindingID: String, collectionID: String, itemIDs: [String]) -> Bool {
        guard let store, let binding = Self.binding(for: bindingID), !itemIDs.isEmpty else {
            return false
        }
        if Self.usesContainsEdge(bindingID) {
            guard let collectionUUID = UUID(uuidString: collectionID) else { return false }
            let members = itemIDs.compactMap { UUID(uuidString: $0) }
            guard !members.isEmpty else { return false }
            RustStoreAdapter.shared.addToCollection(
                publicationIds: members, collectionId: collectionUUID)
            return true
        }
        do {
            _ = try store.collectionAddMembers(
                binding: binding,
                collectionId: collectionID.lowercased(),
                itemIds: itemIDs.map { $0.lowercased() })
            RustStoreAdapter.shared.noteExternalMutation(structural: true)
            return true
        } catch {
            Self.logger.errorCapture(
                "collectionAddMembers(\(bindingID)) failed: \(error)", category: "collections")
            return false
        }
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
    @discardableResult
    public func removeMembers(_ bindingID: String, collectionID: String, itemIDs: [String]) -> Bool {
        guard let store, let binding = Self.binding(for: bindingID), !itemIDs.isEmpty else {
            return false
        }
        do {
            _ = try store.collectionRemoveMembers(
                binding: binding,
                collectionId: collectionID.lowercased(),
                itemIds: itemIDs.map { $0.lowercased() })
            RustStoreAdapter.shared.noteExternalMutation(structural: true)
            return true
        } catch {
            Self.logger.errorCapture(
                "collectionRemoveMembers(\(bindingID)) failed: \(error)", category: "collections")
            return false
        }
    }

    /// Whether a binding records membership as a `Contains` edge (as opposed
    /// to the envelope parent). Mirrors `collection_ops::Membership`.
    private static func usesContainsEdge(_ bindingID: String) -> Bool {
        bindingID != CollectionBindingID.figure
    }
}
#endif
