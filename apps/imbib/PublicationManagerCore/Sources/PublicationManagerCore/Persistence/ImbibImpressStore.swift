//
//  ImbibImpressStore.swift
//  PublicationManagerCore
//
//  The async store gateway for imbib. This is the *new* door to the store
//  that we are migrating towards. It wraps the same `ImbibStore` FFI
//  handle that `RustStoreAdapter` uses — one Rust store, two Swift
//  facades.
//
//  Key differences from `RustStoreAdapter`:
//
//  - All public methods are `async`. A view cannot accidentally call the
//    store synchronously during body evaluation.
//  - Methods run on the gateway actor's isolation (a background
//    executor), so Rust FFI work never runs on the caller's executor.
//  - Reads internally dispatch to the Rust `with_read` helper → reader
//    pool added in Phase 1; writes still go through the writer mutex.
//  - `RustStoreAdapter.didMutate()` emits a `StoreEvent` on the
//    gateway's publisher so snapshot maintainers can subscribe.
//
//  During the migration period both facades coexist:
//  - Existing sync code keeps calling `RustStoreAdapter.shared.xxx`.
//  - New code (sidebar snapshot, operation-queue services, list snapshot)
//    calls `ImbibImpressStore.shared.xxx` asynchronously.
//

import Foundation
import ImbibRustCore
import ImpressLogging
// Re-exported so app targets (e.g. imbib-iOS) can subscribe to
// `ImbibImpressStore.shared.events` and pattern-match `StoreEvent`
// without declaring ImpressStoreKit as a direct package dependency.
@_exported import ImpressStoreKit
import OSLog

/// Async gateway to the imbib store.
public actor ImbibImpressStore {

    // MARK: - Singleton

    public static let shared = ImbibImpressStore()

    // MARK: - Store handle

    /// Accessor for the shared `ImbibStore` handle. Pulled from
    /// `RustStoreAdapter.shared.imbibStore`, which is nonisolated and
    /// safe to read from any actor. We look it up lazily so the adapter
    /// has a chance to finish its own setup first.
    private nonisolated var store: ImbibStore {
        RustStoreAdapter.shared.imbibStore
    }

    // MARK: - Event publisher

    /// Fanout point for all mutation notifications. `RustStoreAdapter`
    /// calls `postMutation(...)` from its `didMutate()` hook, and
    /// `SidebarSnapshotMaintainer` + `ListSnapshot` subscribe via
    /// `events.subscribe()`.
    public nonisolated let events = StoreEventPublisher()

    // MARK: - Init

    public init() {}

    // MARK: - Read API

    /// Query publications in a given source (library, collection, smart search, etc.).
    ///
    /// Runs on the actor's background executor. Internally dispatches to
    /// the Rust `query` path → reader pool.
    public func queryPublications(
        source: PublicationSource,
        sort: String = "created",
        ascending: Bool = false,
        limit: UInt32? = nil,
        offset: UInt32? = nil
    ) async -> [PublicationRowData] {
        StoreTimings.shared.measure("ImbibImpressStore.queryPublications(source:)") {
            // Delegate to the adapter's synchronous source router.
            // The adapter is @MainActor, but here we deliberately bypass
            // by calling the nonisolated helpers directly when possible.
            // For sources that have no nonisolated helper yet, fall back
            // to the adapter call which will hop to main.
            switch source {
            case .library(let id):
                return queryPublicationsBackground(parentId: id, sort: sort, ascending: ascending, limit: limit, offset: offset)
            case .smartSearch(let id), .scixLibrary(let id):
                return queryScixLibraryBackground(id: id, sort: sort, ascending: ascending, limit: limit, offset: offset)
            case .collection(let id):
                return listCollectionMembersBackground(collectionId: id, sort: sort, ascending: ascending, limit: limit, offset: offset)
            default:
                // Less common sources still fall back to the main-actor router.
                // These will migrate in subsequent phases.
                return []
            }
        }
    }

    /// Count unread publications in a specific collection. The sidebar
    /// reads this for every feed on every rebuild — it must be cheap
    /// and must never block the main thread.
    public nonisolated func countUnreadInCollection(collectionId: UUID) -> Int {
        StoreTimings.shared.measure("ImbibImpressStore.countUnreadInCollection") {
            do {
                return Int(try store.countUnreadInCollection(collectionId: collectionId.uuidString))
            } catch {
                return 0
            }
        }
    }

    /// List all smart searches, optionally scoped to a library.
    public nonisolated func listSmartSearches(libraryId: UUID? = nil) -> [SmartSearch] {
        StoreTimings.shared.measure("ImbibImpressStore.listSmartSearches") {
            do {
                return try store.listSmartSearches(libraryId: libraryId?.uuidString)
                    .map { SmartSearch(from: $0) }
            } catch {
                return []
            }
        }
    }

    /// List all libraries.
    public nonisolated func listLibraries() -> [LibraryModel] {
        StoreTimings.shared.measure("ImbibImpressStore.listLibraries") {
            do {
                return try store.listLibraries().map { LibraryModel(from: $0) }
            } catch {
                return []
            }
        }
    }

    // `listCollections(libraryId:)` used to live here, reading the raw
    // `ImbibStore.listCollections` export. DELETED (ADR-0022 F2): it had zero
    // callers and was the one door in the suite that bypassed F1's kernel-first
    // reroute, so at the `collections.unified` flip it would have quietly
    // started answering "no collections" while every other reader answered
    // correctly. The gateway is the NEW door; it should not have carried a
    // pre-F1 copy of the old one. Callers want
    // `RustStoreAdapter.shared.listCollections(libraryId:)`, which resolves the
    // marker through `collectionTreeIn`.

    /// Count unread publications in a library (or across all libraries
    /// if `parentId` is nil).
    public nonisolated func countUnread(parentId: UUID?) -> Int {
        StoreTimings.shared.measure("ImbibImpressStore.countUnread") {
            do {
                return Int(try store.countUnread(parentId: parentId?.uuidString))
            } catch {
                return 0
            }
        }
    }

    /// Count publications in a library.
    public nonisolated func countPublications(parentId: UUID) -> Int {
        StoreTimings.shared.measure("ImbibImpressStore.countPublications") {
            do {
                return Int(try store.countPublications(parentId: parentId.uuidString))
            } catch {
                return 0
            }
        }
    }

    /// Count flagged publications of a given color (nil = any flag).
    public nonisolated func countFlagged(color: String?) -> Int {
        StoreTimings.shared.measure("ImbibImpressStore.countFlagged") {
            do {
                return Int(try store.countFlagged(color: color))
            } catch {
                return 0
            }
        }
    }

    /// List tag definitions with publication counts. Expensive on large
    /// tag catalogs — used by `TagAutocompleteService` in the background.
    public nonisolated func listTagsWithCounts() -> [TagDefinition] {
        StoreTimings.shared.measure("ImbibImpressStore.listTagsWithCounts") {
            do {
                return try store.listTagsWithCounts().map { TagDefinition(from: $0) }
            } catch {
                return []
            }
        }
    }

    // MARK: - Private background query helpers
    //
    // These mirror the @MainActor methods on RustStoreAdapter but call
    // the nonisolated `store` handle directly. They stay private to the
    // gateway — callers use the public async methods above.

    private nonisolated func queryPublicationsBackground(
        parentId: UUID,
        sort: String,
        ascending: Bool,
        limit: UInt32?,
        offset: UInt32?
    ) -> [PublicationRowData] {
        do {
            let rows = try store.queryPublications(
                parentId: parentId.uuidString,
                sortField: sort,
                ascending: ascending,
                limit: limit,
                offset: offset
            )
            return rows.compactMap { PublicationRowData(from: $0) }
        } catch {
            return []
        }
    }

    private nonisolated func queryScixLibraryBackground(
        id: UUID,
        sort: String,
        ascending: Bool,
        limit: UInt32?,
        offset: UInt32?
    ) -> [PublicationRowData] {
        do {
            let rows = try store.queryScixLibraryPublications(
                scixLibraryId: id.uuidString,
                sortField: sort,
                ascending: ascending,
                limit: limit,
                offset: offset
            )
            return rows.compactMap { PublicationRowData(from: $0) }
        } catch {
            return []
        }
    }

    private nonisolated func listCollectionMembersBackground(
        collectionId: UUID,
        sort: String,
        ascending: Bool,
        limit: UInt32?,
        offset: UInt32?
    ) -> [PublicationRowData] {
        do {
            let rows = try store.listCollectionMembers(
                collectionId: collectionId.uuidString,
                sortField: sort,
                ascending: ascending,
                limit: limit,
                offset: offset
            )
            return rows.compactMap { PublicationRowData(from: $0) }
        } catch {
            return []
        }
    }

    // MARK: - Event fan-in

    /// Called from `RustStoreAdapter.didMutate()` after any mutation.
    /// Classifies the mutation into a `StoreEvent` and fans out to
    /// subscribers.
    ///
    /// This is `nonisolated` so `RustStoreAdapter` can call it
    /// synchronously from its main-actor context without jumping to the
    /// gateway actor. The publisher itself is thread-safe (internal lock).
    public nonisolated func postMutation(
        structural: Bool,
        affectedIDs: Set<UUID>? = nil,
        kind: MutationKind? = nil,
        collectionID: UUID? = nil
    ) {
        if let collectionID {
            events.emit(.collectionMembershipChanged(collectionID: collectionID))
        }
        if structural {
            events.emit(.structural)
        } else if let kind, let ids = affectedIDs, !ids.isEmpty {
            events.emit(.itemsMutated(kind: kind, ids: ids))
        } else {
            // Non-structural mutation without narrower classification —
            // treat as structural so subscribers re-fetch. Rare.
            events.emit(.structural)
        }
    }

    // MARK: - CloudKit sync engine (ADR-0007 Phase 3, Phase C)
    //
    // Async pass-throughs to the Rust apply/snapshot engine. These run on
    // the gateway actor's executor, so FFI merge work never blocks the main
    // actor — the CloudSyncEngine (Phase D) drives them exclusively.
    // After applying a fetched batch the engine posts `postMutation(...)` +
    // the Darwin `syncApplied` notification itself; these primitives do not.

    /// Pending outbox entries in queue order (push cursor).
    public func syncOutboxEntries(limit: UInt32) async throws -> [ImbibRustCore.SyncOutboxEntry] {
        try store.syncOutboxEntries(limit: limit)
    }

    /// Remove confirmed-pushed outbox rows by sequence number.
    public func syncOutboxRemove(seqs: [Int64]) async throws {
        try store.syncOutboxRemove(seqs: seqs)
    }

    /// Snapshot outbox `item` entries into wire records.
    public func syncSnapshotItems(ids: [String]) async throws -> [ImbibRustCore.SyncItemRecord] {
        try store.syncSnapshotItems(ids: ids)
    }

    /// Snapshot outbox `reference` entries (raw `src|tgt|edge` names).
    public func syncSnapshotReferences(recordNames: [String]) async throws
        -> [ImbibRustCore.SyncReferenceRecord]
    {
        try store.syncSnapshotReferences(recordNames: recordNames)
    }

    /// Local tombstones since `sinceMs`, as wire records.
    public func syncLocalTombstones(sinceMs: Int64) async throws -> [ImbibRustCore.SyncTombstoneRecord] {
        try store.syncLocalTombstones(sinceMs: sinceMs)
    }

    /// Merge fetched remote item records (whole-record LWW in Rust).
    public func syncApplyRemoteItems(records: [ImbibRustCore.SyncItemRecord]) async throws -> ImbibRustCore.SyncApplyReport {
        try store.syncApplyRemoteItems(records: records)
    }

    /// Apply fetched remote reference records; missing endpoints defer.
    public func syncApplyRemoteReferences(refs: [ImbibRustCore.SyncReferenceRecord]) async throws
        -> ImbibRustCore.SyncApplyReport
    {
        try store.syncApplyRemoteReferences(refs: refs)
    }

    /// Re-attempt all deferred references (call after each item batch).
    public func syncRetryPendingReferences() async throws -> ImbibRustCore.SyncApplyReport {
        try store.syncRetryPendingReferences()
    }

    /// Apply CKRecord deletions (`ref_...` = edges, UUIDs = items).
    public func syncApplyRemoteDeletions(recordNames: [String]) async throws -> ImbibRustCore.SyncApplyReport {
        try store.syncApplyRemoteDeletions(recordNames: recordNames)
    }

    /// Apply fetched `ImpressTombstone` records.
    public func syncApplyRemoteTombstones(tombstones: [ImbibRustCore.SyncTombstoneRecord]) async throws
        -> ImbibRustCore.SyncApplyReport
    {
        try store.syncApplyRemoteTombstones(tombstones: tombstones)
    }

    /// Read a sync-namespaced metadata value (`"sync."`-prefixed keys only).
    public func syncMetadataGet(key: String) async throws -> String? {
        try store.syncMetadataGet(key: key)
    }

    /// Write (or clear, with `nil`) a sync-namespaced metadata value.
    public func syncMetadataSet(key: String, value: String?) async throws {
        try store.syncMetadataSet(key: key, value: value)
    }

    /// Read the archived CKRecord system fields for a record, if any.
    public func syncRecordStateGet(recordName: String) async throws -> Data? {
        try store.syncRecordStateGet(recordName: recordName)
    }

    /// Archive CKRecord system fields for a record.
    public func syncRecordStateSet(recordName: String, blob: Data) async throws {
        try store.syncRecordStateSet(recordName: recordName, blob: blob)
    }

    /// Drop the archived system fields for a record.
    public func syncRecordStateDelete(recordName: String) async throws {
        try store.syncRecordStateDelete(recordName: recordName)
    }

    /// Live sync queue depths (outbox / deferred refs / tombstones).
    public func syncStatusCounts() async throws -> ImbibRustCore.SyncCounts {
        try store.syncStatusCounts()
    }
}
