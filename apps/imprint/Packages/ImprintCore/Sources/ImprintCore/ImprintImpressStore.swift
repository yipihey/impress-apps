//
//  ImprintImpressStore.swift
//  ImprintCore
//
//  The async store gateway for imprint. Parallels imbib's
//  `ImbibImpressStore`. This is the new door that views and services
//  will migrate towards — async-only, runs on the gateway actor's
//  background executor, publishes typed `StoreEvent`s for snapshot
//  maintainers to subscribe to.
//
//  ## Store handle
//
//  The gateway opens its *own* `SharedStore` handle pointing at the
//  same SQLite file that `ImprintStoreAdapter` uses. Two Swift handles
//  against one WAL-mode database is safe — WAL coordinates reader and
//  writer connections across the process, and `SharedStore` is marked
//  `Sync + Send` at the Rust layer.
//
//  Opening a second handle (as opposed to sharing the adapter's)
//  avoids restructuring `ImprintStoreAdapter`'s main-actor isolation
//  and keeps the migration additive. When a future phase retires
//  `ImprintStoreAdapter`, the gateway's handle becomes the sole one.
//
//  ## Read API
//
//  - `loadSection(id:)` — fetch a single section by UUID, body already
//    rehydrated from the content-addressed store if needed.
//  - `listSectionsForDocument(documentID:)` — all sections for a given
//    parent document, sorted by `orderIndex`.
//  - `countSectionsForDocument(documentID:)` — O(N) on the section
//    count (no server-side payload filter in SharedStore yet).
//  - `listDocumentIDs()` — distinct document ids seen in the store.
//  - `listAllSections(limit:offset:)` — paginated schema listing,
//    used by diagnostics and bulk indexing.
//
//  All methods are `nonisolated` so callers don't have to `await` the
//  gateway actor just to issue a read. Each is instrumented with
//  `StoreTimings` so the `/api/store-timings` endpoint shows imprint
//  store calls alongside imbib's.
//

import Foundation
import ImpressLogging
import ImpressStoreKit
#if canImport(ImpressRustCore)
import ImpressRustCore
#endif
import ImpressKit
import OSLog

private let gatewayLog = Logger(subsystem: "com.imprint.app", category: "impress-store")

/// Async gateway to imprint's store. See file header for the design
/// decisions behind opening a second `SharedStore` handle.
public actor ImprintImpressStore {

    // MARK: - Singleton

    public static let shared = ImprintImpressStore()

    // MARK: - Event publisher

    /// Fan-out point for mutation notifications. Imprint's existing
    /// `ImprintStoreAdapter.didMutate()` calls `postMutation(...)`
    /// from its main-actor context; subscribers receive events on an
    /// `AsyncStream`.
    public nonisolated let events = StoreEventPublisher()

    // MARK: - Shared store handle

    #if canImport(ImpressRustCore)
    /// The gateway's own handle on the shared impress-core database.
    /// Opened lazily on first access to avoid racing with
    /// `ImprintStoreAdapter.setup()` during app launch. `nil` means
    /// the workspace directory could not be created, or the FFI layer
    /// reported an error — all read methods return empty in that state.
    nonisolated(unsafe) private var _store: SharedStore?
    nonisolated(unsafe) private var storeOpenAttempted = false
    private let storeLock = NSLock()

    /// Lazily open (or return the already-opened) shared store handle.
    /// Thread-safe — multiple concurrent calls cooperate via the lock.
    nonisolated private func handle() -> SharedStore? {
        storeLock.lock()
        defer { storeLock.unlock() }
        if let s = _store { return s }
        if storeOpenAttempted { return nil }
        storeOpenAttempted = true
        do {
            try SharedWorkspace.ensureDirectoryExists()
            let path = SharedWorkspace.databaseURL.path
            let s = try SharedStore.open(path: path)
            _store = s
            gatewayLog.infoCapture(
                "ImprintImpressStore: opened SharedStore at \(path)",
                category: "impress-store"
            )
            return s
        } catch {
            gatewayLog.errorCapture(
                "ImprintImpressStore: failed to open SharedStore — \(error.localizedDescription)",
                category: "impress-store"
            )
            return nil
        }
    }
    #endif

    // MARK: - Init

    public init() {}

    #if canImport(ImpressRustCore)
    /// Test-only initializer that injects a preopened `SharedStore`
    /// (typically `SharedStore.openInMemory()`). Not meant for use
    /// outside `ImprintCoreTests`.
    public init(testStore: SharedStore) {
        self._store = testStore
        self.storeOpenAttempted = true
    }
    #endif

    // MARK: - Event fan-in

    /// Called from `ImprintStoreAdapter.didMutate()` after any mutation.
    ///
    /// Currently emits a single `.structural` event because the adapter
    /// doesn't yet classify mutations into narrower kinds. A follow-up
    /// can refine this so section-level writes emit
    /// `itemsMutated(kind: .otherField, ids:)` instead.
    public nonisolated func postMutation(
        structural: Bool = true,
        affectedIDs: Set<UUID>? = nil,
        kind: MutationKind? = nil
    ) {
        if structural {
            events.emit(.structural)
        } else if let kind, let ids = affectedIDs, !ids.isEmpty {
            events.emit(.itemsMutated(kind: kind, ids: ids))
        } else {
            events.emit(.structural)
        }
    }

    // MARK: - Read API

    #if canImport(ImpressRustCore)

    /// Fetch a single manuscript section by its UUID. Returns `nil`
    /// if the id is unknown, the schema mismatches, the payload JSON
    /// is malformed, or the underlying FFI reports an error.
    ///
    /// The returned section has its body already rehydrated — if the
    /// on-disk payload stored a `content_hash`, the gateway reads the
    /// content-addressed file at
    /// `~/.local/share/impress/content/{hash}` and puts its contents
    /// in `body`. If the file is missing, `body` is `nil` but other
    /// fields still populate.
    public nonisolated func loadSection(id: UUID) -> ManuscriptSection? {
        StoreTimings.shared.measure("ImprintImpressStore.loadSection") {
            guard let store = handle() else { return nil }
            do {
                guard let row = try store.getItem(id: id.uuidString) else { return nil }
                guard var section = ManuscriptSection(row: row) else { return nil }
                section = rehydrateBody(section)
                return section
            } catch {
                gatewayLog.errorCapture(
                    "loadSection(\(id)) failed: \(error.localizedDescription)",
                    category: "impress-store"
                )
                return nil
            }
        }
    }

    /// List every section belonging to the given document, sorted by
    /// `orderIndex`. Body rehydration is skipped — the returned
    /// sections carry whatever inline `body` was in the payload (which
    /// is empty for content-addressed sections). Callers who need the
    /// full body should iterate the returned ids and call
    /// `loadSection(id:)` on each, which does rehydrate.
    ///
    /// The client-side filter is O(all manuscript sections in the
    /// store) — `SharedStore.queryBySchema` does not filter by payload
    /// fields. For imprint's realistic scale (tens to hundreds of
    /// sections per user) this is fine.
    public nonisolated func listSectionsForDocument(
        documentID: UUID
    ) -> [ManuscriptSection] {
        StoreTimings.shared.measure("ImprintImpressStore.listSectionsForDocument") {
            let all = allManuscriptSections()
            return all
                .filter { $0.documentID == documentID }
                .sorted { lhs, rhs in
                    if lhs.orderIndex != rhs.orderIndex {
                        return lhs.orderIndex < rhs.orderIndex
                    }
                    return lhs.title < rhs.title
                }
        }
    }

    /// Count sections for a document. Uses the same client-side filter
    /// as `listSectionsForDocument` — equivalent cost.
    public nonisolated func countSectionsForDocument(documentID: UUID) -> Int {
        StoreTimings.shared.measure("ImprintImpressStore.countSectionsForDocument") {
            allManuscriptSections().lazy
                .filter { $0.documentID == documentID }
                .count
        }
    }

    /// Distinct document UUIDs seen in the manuscript-section store.
    /// Useful for diagnostics and for discovering which documents have
    /// any persisted content.
    public nonisolated func listDocumentIDs() -> Set<UUID> {
        StoreTimings.shared.measure("ImprintImpressStore.listDocumentIDs") {
            var seen = Set<UUID>()
            for section in allManuscriptSections() {
                if let id = section.documentID {
                    seen.insert(id)
                }
            }
            return seen
        }
    }

    /// List all manuscript sections with schema-level pagination.
    /// The underlying FFI default limit is 100 — pass an explicit
    /// limit for full scans.
    public nonisolated func listAllSections(limit: UInt32 = 1000, offset: UInt32 = 0) -> [ManuscriptSection] {
        StoreTimings.shared.measure("ImprintImpressStore.listAllSections") {
            guard let store = handle() else { return [] }
            do {
                let rows = try store.queryBySchema(
                    schemaRef: "manuscript-section@1.0.0",
                    limit: limit,
                    offset: offset
                )
                return rows.compactMap { ManuscriptSection(row: $0) }
            } catch {
                gatewayLog.errorCapture(
                    "listAllSections failed: \(error.localizedDescription)",
                    category: "impress-store"
                )
                return []
            }
        }
    }

    // MARK: - Citation Usage reads

    /// List every `citation-usage@1.0.0` record currently in the store.
    /// Each record links a manuscript section to the paper it cites.
    /// Imbib can call this (via the shared SQLite) to build a
    /// "papers cited in my manuscripts" view without touching imprint's
    /// internals.
    public nonisolated func listCitationUsages(limit: UInt32 = 5000, offset: UInt32 = 0) -> [CitationUsageRecord] {
        StoreTimings.shared.measure("ImprintImpressStore.listCitationUsages") {
            guard let store = handle() else { return [] }
            do {
                let rows = try store.queryBySchema(
                    schemaRef: "citation-usage@1.0.0",
                    limit: limit,
                    offset: offset
                )
                return rows.compactMap { CitationUsageRecord(row: $0) }
            } catch {
                gatewayLog.errorCapture(
                    "listCitationUsages failed: \(error.localizedDescription)",
                    category: "impress-store"
                )
                return []
            }
        }
    }

    // MARK: - Internals

    /// Fetch every manuscript section currently in the store, without
    /// body rehydration. Used by document-scoped queries that only
    /// need metadata (id, title, orderIndex, wordCount, documentID).
    private nonisolated func allManuscriptSections() -> [ManuscriptSection] {
        // Pull a large upper bound in one call. Imprint's realistic
        // scale is well under this — if a user ever has more than
        // 10,000 sections across all documents we'll paginate.
        guard let store = handle() else { return [] }
        do {
            let rows = try store.queryBySchema(
                schemaRef: "manuscript-section@1.0.0",
                limit: 10_000,
                offset: 0
            )
            return rows.compactMap { ManuscriptSection(row: $0) }
        } catch {
            gatewayLog.errorCapture(
                "allManuscriptSections failed: \(error.localizedDescription)",
                category: "impress-store"
            )
            return []
        }
    }

    /// If the section's `contentHash` is set, replace its `body` with
    /// the content-addressed file's contents. Returns the section
    /// unchanged if there is no hash. On read failure, the returned
    /// section has `body = nil` so the caller can detect the failure.
    private nonisolated func rehydrateBody(_ section: ManuscriptSection) -> ManuscriptSection {
        guard let hash = section.contentHash, !hash.isEmpty else {
            return section
        }

        let url = Self.contentStoreDirectory.appendingPathComponent(hash)
        do {
            let bytes = try Data(contentsOf: url)
            let body = String(data: bytes, encoding: .utf8)
            return ManuscriptSection(
                id: section.id,
                documentID: section.documentID,
                title: section.title,
                body: body,
                sectionType: section.sectionType,
                orderIndex: section.orderIndex,
                wordCount: section.wordCount,
                contentHash: section.contentHash,
                createdAt: section.createdAt
            )
        } catch {
            gatewayLog.warningCapture(
                "rehydrateBody: content file missing for \(section.id) hash=\(hash): \(error.localizedDescription)",
                category: "impress-store"
            )
            return ManuscriptSection(
                id: section.id,
                documentID: section.documentID,
                title: section.title,
                body: nil,
                sectionType: section.sectionType,
                orderIndex: section.orderIndex,
                wordCount: section.wordCount,
                contentHash: section.contentHash,
                createdAt: section.createdAt
            )
        }
    }

    /// Directory containing content-addressed section bodies. Must
    /// match what `ImprintStoreAdapter.writeContentAddressed` writes to.
    private nonisolated static var contentStoreDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/impress/content", isDirectory: true)
    }

    #endif // canImport(ImpressRustCore)
}
