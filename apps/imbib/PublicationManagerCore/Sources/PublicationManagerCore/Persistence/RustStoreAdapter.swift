//
//  RustStoreAdapter.swift
//  PublicationManagerCore
//
//  Wraps ImbibStore (Rust UniFFI) for Swift consumption.
//  Single source of truth for all data operations — replaces
//  PublicationRepository + PersistenceController + all Core Data services.
//

import Foundation
import ImbibRustCore
import ImpressFTUI
import ImpressKit
import ImpressLogging
import ImpressStoreKit
import OSLog

// MARK: - Rust Store Adapter

/// Wraps the Rust ImbibStore (UniFFI) for Swift consumption.
///
/// All views and services read/write through this adapter.
/// Mutations bump `dataVersion` so `@Observable` views update automatically.
@MainActor
@Observable
public final class RustStoreAdapter: PublicationStoreProtocol {

    /// Shared singleton instance.
    /// When launched with `--ui-testing`, uses an in-memory store for deterministic tests.
    ///
    /// `nonisolated` so it can be accessed from the `ImbibImpressStore`
    /// gateway actor without crossing into the main actor. The instance
    /// itself is `@MainActor`; only the `shared` accessor bypass is
    /// nonisolated. Off-main callers may only touch nonisolated members
    /// of the returned instance (e.g., `imbibStore`).
    public nonisolated(unsafe) static let shared: RustStoreAdapter = {
        do {
            let isUITesting = ProcessInfo.processInfo.arguments.contains("--ui-testing")
            if isUITesting {
                return try RustStoreAdapter(inMemory: true)
            }
            return try RustStoreAdapter()
        } catch {
            fatalError("Failed to initialize RustStoreAdapter: \(error)")
        }
    }()

    /// The underlying Rust store.
    private let store: ImbibStore

    /// Thread-safe handle for background (non-main-actor) read-only FFI calls.
    /// ImbibStore uses Arc<Mutex<Connection>> internally, so concurrent reads are safe.
    public nonisolated(unsafe) let imbibStore: ImbibStore

    /// Whether the Rust store is enabled (feature flag for gradual rollout).
    public static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "useRustStore")
    }

    /// Bumped on every mutation. Views observe this to trigger updates.
    public private(set) var dataVersion: Int = 0

    /// Batch mutation depth counter. When > 0, `didMutate()` bumps `dataVersion`
    /// but suppresses notification posting. One consolidated notification fires
    /// when the outermost batch ends.
    private var batchDepth: Int = 0
    /// Tracks whether any structural mutation occurred during the current batch.
    private var batchHadStructural: Bool = false
    /// Accumulates publication IDs with field changes during a batch, so one coalesced
    /// `.fieldDidChange` notification fires at `endBatchMutation()` instead of per-field.
    private var batchChangedFieldIDs: Set<UUID> = []

    // MARK: - Initialization

    private init() throws {
        try SharedWorkspace.ensureDirectoryExists()
        Self.migrateLegacyDatabaseIfNeeded()
        let dbPath = Self.databasePath()
        let s = try ImbibStore.open(path: dbPath)
        self.store = s
        self.imbibStore = s
        Logger.library.infoCapture("RustStoreAdapter initialized at \(dbPath)", category: "rust-store")
    }

    /// For testing with in-memory store.
    init(inMemory: Bool) throws {
        if inMemory {
            let s = try ImbibStore.openInMemory()
            self.store = s
            self.imbibStore = s
        } else {
            let dbPath = Self.databasePath()
            let s = try ImbibStore.open(path: dbPath)
            self.store = s
            self.imbibStore = s
        }
    }

    /// Returns the path to the shared impress-core database.
    ///
    /// All imbib data lives in the shared store so other impress apps can
    /// read bibliography entries directly.
    private static func databasePath() -> String {
        SharedWorkspace.databasePath
    }

    /// Path to the legacy per-app database used before the shared-store migration.
    private static var legacyDatabasePath: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("com.impress.imbib", isDirectory: true)
        return appDir.appendingPathComponent("imbib.sqlite").path
    }

    /// Copies the legacy imbib.sqlite to the shared workspace if it exists
    /// and the shared database does not. Safe to call multiple times.
    private static func migrateLegacyDatabaseIfNeeded() {
        let legacy = URL(fileURLWithPath: legacyDatabasePath)
        do {
            let migrated = try SharedWorkspace.migrateLegacyDatabase(from: legacy)
            if migrated {
                Logger.library.infoCapture(
                    "RustStoreAdapter: migrated legacy database to shared workspace",
                    category: "rust-store"
                )
            }
        } catch {
            Logger.library.error("RustStoreAdapter: legacy migration failed — \(error)")
        }
    }

    /// Signal that the store was mutated.
    ///
    /// - Parameter structural: `true` (default) for mutations that add, remove, or move
    ///   publications (requiring a full list refresh). `false` for in-place field changes
    ///   (read/star/flag/tag) that are handled by row-level notifications (O(1) updates).
    private func didMutate(
        structural: Bool = true,
        affectedIDs: Set<UUID>? = nil,
        kind: MutationKind? = nil
    ) {
        dataVersion += 1
        if batchDepth > 0 {
            if structural { batchHadStructural = true }
            if let affectedIDs, !affectedIDs.isEmpty {
                batchChangedFieldIDs.formUnion(affectedIDs)
            }
            return  // event deferred until endBatchMutation()
        }
        // Fan out through the ImbibImpressStore event publisher.
        // Subscribers (sidebar snapshot, list view, detail views,
        // tag autocomplete, …) receive a typed StoreEvent instead of
        // a NotificationCenter post.
        ImbibImpressStore.shared.postMutation(
            structural: structural,
            affectedIDs: affectedIDs,
            kind: kind
        )
    }

    /// Begin a batch mutation. While a batch is active, individual `didMutate()` calls
    /// suppress notification posting. Call `endBatchMutation()` when done — one
    /// consolidated notification fires at the end. Supports nesting.
    public func beginBatchMutation() {
        batchDepth += 1
    }

    /// End a batch mutation. When the outermost batch ends, posts a single
    /// `.storeDidMutate` notification and a coalesced `.fieldDidChange` notification
    /// summarizing all mutations in the batch.
    public func endBatchMutation() {
        precondition(batchDepth > 0, "endBatchMutation called without matching beginBatchMutation")
        batchDepth -= 1
        if batchDepth == 0 {
            // Emit a single coalesced field event for the whole batch.
            if !batchChangedFieldIDs.isEmpty {
                let ids = batchChangedFieldIDs
                batchChangedFieldIDs.removeAll()
                ImbibImpressStore.shared.postMutation(
                    structural: false,
                    affectedIDs: ids,
                    kind: .otherField
                )
            }

            let structural = batchHadStructural
            batchHadStructural = false
            // One consolidated StoreEvent for the whole batch.
            ImbibImpressStore.shared.postMutation(structural: structural)
        }
    }

    // MARK: - Publication Queries

    /// Query publications in a library, sorted and paginated.
    public func queryPublications(
        parentId: UUID,
        sort: String = "created",
        ascending: Bool = false,
        limit: UInt32? = nil,
        offset: UInt32? = nil
    ) -> [PublicationRowData] {
        StoreTimings.shared.measure("queryPublications(parentId:)") {
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
                Logger.library.error("queryPublications failed: \(error)")
                return []
            }
        }
    }

    /// Query just the IDs of publications in a library (fast — skips full row conversion).
    public func queryPublicationIDs(parentId: UUID) -> Set<UUID> {
        do {
            let ids = try store.queryPublicationIds(parentId: parentId.uuidString)
            return Set(ids.compactMap { UUID(uuidString: $0) })
        } catch {
            Logger.library.error("queryPublicationIDs failed: \(error)")
            return []
        }
    }

    /// Query recent publications.
    public func queryRecent(limit: UInt32 = 50, parentId: UUID? = nil) -> [PublicationRowData] {
        do {
            let rows = try store.queryRecent(limit: limit, parentId: parentId?.uuidString)
            return rows.compactMap { PublicationRowData(from: $0) }
        } catch {
            Logger.library.error("queryRecent failed: \(error)")
            return []
        }
    }

    /// Query starred publications.
    public func queryStarred(
        parentId: UUID? = nil,
        sort: String = "created",
        ascending: Bool = false,
        limit: UInt32? = nil,
        offset: UInt32? = nil
    ) -> [PublicationRowData] {
        StoreTimings.shared.measure("queryStarred") {
            do {
                let rows = try store.queryStarred(
                    parentId: parentId?.uuidString,
                    sortField: sort,
                    ascending: ascending,
                    limit: limit,
                    offset: offset
                )
                return rows.compactMap { PublicationRowData(from: $0) }
            } catch {
                Logger.library.error("queryStarred failed: \(error)")
                return []
            }
        }
    }

    /// Query unread publications.
    public func queryUnread(
        parentId: UUID? = nil,
        sort: String = "created",
        ascending: Bool = false,
        limit: UInt32? = nil,
        offset: UInt32? = nil
    ) -> [PublicationRowData] {
        do {
            let rows = try store.queryUnread(
                parentId: parentId?.uuidString,
                sortField: sort,
                ascending: ascending,
                limit: limit,
                offset: offset
            )
            return rows.compactMap { PublicationRowData(from: $0) }
        } catch {
            Logger.library.error("queryUnread failed: \(error)")
            return []
        }
    }

    /// Query publications by tag.
    public func queryByTag(
        tagPath: String,
        parentId: UUID? = nil,
        sort: String = "created",
        ascending: Bool = false,
        limit: UInt32? = nil,
        offset: UInt32? = nil
    ) -> [PublicationRowData] {
        do {
            let rows = try store.queryByTag(
                tagPath: tagPath,
                parentId: parentId?.uuidString,
                sortField: sort,
                ascending: ascending,
                limit: limit,
                offset: offset
            )
            return rows.compactMap { PublicationRowData(from: $0) }
        } catch {
            Logger.library.error("queryByTag failed: \(error)")
            return []
        }
    }

    /// Search publications by text query (searches title, authors, abstract, note).
    public func searchPublications(
        query: String,
        parentId: UUID? = nil,
        sort: String = "created",
        ascending: Bool = false,
        limit: UInt32? = nil,
        offset: UInt32? = nil
    ) -> [PublicationRowData] {
        do {
            let rows = try store.searchPublications(
                query: query,
                parentId: parentId?.uuidString,
                sortField: sort,
                ascending: ascending,
                limit: limit,
                offset: offset
            )
            return rows.compactMap { PublicationRowData(from: $0) }
        } catch {
            Logger.library.error("searchPublications failed: \(error)")
            return []
        }
    }

    /// Full-text search (FTS5 in SQLite).
    public func fullTextSearch(
        query: String,
        parentId: UUID? = nil,
        limit: UInt32? = nil,
        offset: UInt32? = nil
    ) -> [PublicationRowData] {
        do {
            let rows = try store.fullTextSearch(
                query: query,
                parentId: parentId?.uuidString,
                limit: limit,
                offset: offset
            )
            return rows.compactMap { PublicationRowData(from: $0) }
        } catch {
            Logger.library.error("fullTextSearch failed: \(error)")
            return []
        }
    }

    /// Get a single publication as row data.
    public func getPublication(id: UUID) -> PublicationRowData? {
        do {
            guard let row = try store.getPublication(id: id.uuidString) else { return nil }
            return PublicationRowData(from: row)
        } catch {
            Logger.library.error("getPublication failed: \(error)")
            return nil
        }
    }

    /// Get full publication detail for detail views.
    public func getPublicationDetail(id: UUID) -> PublicationModel? {
        do {
            guard let detail = try store.getPublicationDetail(id: id.uuidString) else { return nil }
            return PublicationModel(from: detail)
        } catch {
            Logger.library.error("getPublicationDetail failed: \(error)")
            return nil
        }
    }

    /// Get flagged publications.
    public func getFlaggedPublications(
        color: String? = nil,
        sort: String = "created",
        ascending: Bool = false,
        limit: UInt32? = nil,
        offset: UInt32? = nil
    ) -> [PublicationRowData] {
        StoreTimings.shared.measure("getFlaggedPublications") {
            do {
                let rows = try store.getFlaggedPublications(
                    color: color,
                    sortField: sort,
                    ascending: ascending,
                    limit: limit,
                    offset: offset
                )
                return rows.compactMap { PublicationRowData(from: $0) }
            } catch {
                Logger.library.error("getFlaggedPublications failed: \(error)")
                return []
            }
        }
    }

    /// List collection members.
    public func listCollectionMembers(
        collectionId: UUID,
        sort: String = "created",
        ascending: Bool = false,
        limit: UInt32? = nil,
        offset: UInt32? = nil
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
            Logger.library.error("listCollectionMembers failed: \(error)")
            return []
        }
    }

    // MARK: - Deduplication Queries

    /// Find publications by DOI.
    public func findByDoi(doi: String) -> [PublicationRowData] {
        do {
            let rows = try store.findByDoi(doi: doi)
            return rows.compactMap { PublicationRowData(from: $0) }
        } catch {
            Logger.library.error("findByDoi failed: \(error)")
            return []
        }
    }

    /// Find publications by arXiv ID.
    public func findByArxiv(arxivId: String) -> [PublicationRowData] {
        do {
            let rows = try store.findByArxiv(arxivId: arxivId)
            return rows.compactMap { PublicationRowData(from: $0) }
        } catch {
            Logger.library.error("findByArxiv failed: \(error)")
            return []
        }
    }

    /// Find publications by bibcode.
    public func findByBibcode(bibcode: String) -> [PublicationRowData] {
        do {
            let rows = try store.findByBibcode(bibcode: bibcode)
            return rows.compactMap { PublicationRowData(from: $0) }
        } catch {
            Logger.library.error("findByBibcode failed: \(error)")
            return []
        }
    }

    /// Find publications by any combination of identifiers.
    public func findByIdentifiers(doi: String? = nil, arxivId: String? = nil, bibcode: String? = nil, pmid: String? = nil) -> [PublicationRowData] {
        do {
            let rows = try store.findByIdentifiers(doi: doi, arxivId: arxivId, bibcode: bibcode, pmid: pmid)
            return rows.compactMap { PublicationRowData(from: $0) }
        } catch {
            Logger.library.error("findByIdentifiers failed: \(error)")
            return []
        }
    }

    /// Find publication by cite key.
    public func findByCiteKey(citeKey: String, libraryId: UUID? = nil) -> PublicationRowData? {
        do {
            guard let row = try store.findByCiteKey(citeKey: citeKey, libraryId: libraryId?.uuidString) else { return nil }
            return PublicationRowData(from: row)
        } catch {
            Logger.library.error("findByCiteKey failed: \(error)")
            return nil
        }
    }

    /// Deduplicate publications in a library, keeping the oldest copy.
    /// Returns the number of duplicates removed.
    @discardableResult
    public func deduplicateLibrary(id: UUID) -> Int {
        do {
            let count = try store.deduplicateLibrary(libraryId: id.uuidString)
            if count > 0 {
                didMutate()
                Logger.library.infoCapture("Deduplicated library \(id): removed \(count) duplicates", category: "dedup")
            }
            return Int(count)
        } catch {
            Logger.library.error("deduplicateLibrary failed: \(error)")
            return 0
        }
    }

    // MARK: - Publication Mutations

    /// Import BibTeX into a library.
    public func importBibTeX(_ bibtex: String, libraryId: UUID) -> [UUID] {
        StoreTimings.shared.measure("importBibTeX") {
            do {
                let ids = try store.importBibtex(bibtex: bibtex, libraryId: libraryId.uuidString)
                didMutate()
                UserDefaults.standard.set(true, forKey: "needsStartupDedup")
                let imported = ids.compactMap { UUID(uuidString: $0) }
                if !ids.isEmpty {
                    let count = ids.count
                    let desc = count == 1 ? "Import Paper" : "Import \(count) Papers"
                    let capturedStore = store
                    let capturedIds = ids
                    UndoCoordinator.shared.registerUndoClosure(
                        actionName: desc,
                        undo: { [weak self] in
                            do {
                                try capturedStore.deletePublications(ids: capturedIds)
                                self?.didMutate()
                            } catch {
                                Logger.library.error("Undo importBibTeX failed: \(error)")
                            }
                        }
                    )
                }
                Logger.library.infoCapture("importBibTeX: imported \(imported.count) entries", category: "import")
                return imported
            } catch {
                Logger.library.errorCapture("importBibTeX failed: \(error)", category: "import")
                return []
            }
        }
    }

    /// Batch import search results: find existing, optionally filter dismissed, import new.
    /// Single FFI call replaces the batch-find + classify + import-loop pattern.
    /// Returns (existingIDs, importedIDs).
    public func batchImportSearchResults(
        bibtexEntries: [(bibtex: String, doi: String?, arxivId: String?, bibcode: String?)],
        libraryId: UUID,
        filterDismissed: Bool = false
    ) -> (existingIDs: [UUID], importedIDs: [UUID]) {
        let inputs = bibtexEntries.map {
            SearchResultInput(bibtex: $0.bibtex, doi: $0.doi, arxivId: $0.arxivId, bibcode: $0.bibcode)
        }
        do {
            let result = try store.batchImportSearchResults(
                results: inputs,
                libraryId: libraryId.uuidString,
                filterDismissed: filterDismissed
            )
            let existingUUIDs = result.existingIds.compactMap { UUID(uuidString: $0) }
            let importedUUIDs = result.importedIds.compactMap { UUID(uuidString: $0) }
            if !importedUUIDs.isEmpty {
                didMutate()
                UserDefaults.standard.set(true, forKey: "needsStartupDedup")
                let count = importedUUIDs.count
                let desc = count == 1 ? "Import Paper" : "Import \(count) Papers"
                let capturedStore = store
                let capturedIds = result.importedIds
                UndoCoordinator.shared.registerUndoClosure(
                    actionName: desc,
                    undo: { [weak self] in
                        do {
                            try capturedStore.deletePublications(ids: capturedIds)
                            self?.didMutate()
                        } catch {
                            Logger.library.error("Undo batchImport failed: \(error)")
                        }
                    }
                )
            }
            if result.failedCount > 0 {
                Logger.library.warningCapture(
                    "Batch import: \(result.failedCount) entries failed to parse",
                    category: "import"
                )
            }
            return (existingUUIDs, importedUUIDs)
        } catch {
            Logger.library.errorCapture("batchImportSearchResults failed: \(error)", category: "import")
            return ([], [])
        }
    }

    /// Import from a BibTeX file on disk (undoable via importBibTeX).
    public func importFromBibTeXFile(path: String, libraryId: UUID) -> UInt32 {
        guard let bibtex = try? String(contentsOfFile: path, encoding: .utf8) else {
            Logger.library.errorCapture("importFromBibTeXFile: cannot read file \(path)", category: "import")
            return 0
        }
        let imported = importBibTeX(bibtex, libraryId: libraryId)
        Logger.library.infoCapture("importFromBibTeXFile: imported \(imported.count) entries from \(path)", category: "import")
        return UInt32(imported.count)
    }

    /// Set read state for publications.
    public func setRead(ids: [UUID], read: Bool) {
        StoreTimings.shared.measure("setRead") {
            do {
                let info = try store.setRead(ids: ids.map(\.uuidString), read: read)
                didMutate(structural: false, affectedIDs: Set(ids), kind: .readState)
                UndoCoordinator.shared.registerUndo(info: info)
            } catch {
                Logger.library.error("setRead failed: \(error)")
            }
        }
    }

    /// Set starred state for publications.
    public func setStarred(ids: [UUID], starred: Bool) {
        do {
            let info = try store.setStarred(ids: ids.map(\.uuidString), starred: starred)
            didMutate(structural: false, affectedIDs: Set(ids), kind: .starred)
            UndoCoordinator.shared.registerUndo(info: info)
        } catch {
            Logger.library.error("setStarred failed: \(error)")
        }
    }

    /// Set flag on publications.
    public func setFlag(ids: [UUID], color: String?, style: String? = nil, length: String? = nil) {
        do {
            let info = try store.setFlag(ids: ids.map(\.uuidString), color: color, style: style, length: length)
            didMutate(structural: false, affectedIDs: Set(ids), kind: .flag)
            UndoCoordinator.shared.registerUndo(info: info)
        } catch {
            Logger.library.error("setFlag failed: \(error)")
        }
    }

    /// Update a single string field on a publication.
    public func updateField(id: UUID, field: String, value: String?) {
        do {
            let info = try store.updateField(id: id.uuidString, field: field, value: value)
            didMutate(structural: false, affectedIDs: [id], kind: .otherField)
            UndoCoordinator.shared.registerUndo(info: info)
        } catch {
            Logger.library.error("updateField failed: \(error)")
        }
    }

    /// Update a boolean field on any item.
    public func updateBoolField(id: UUID, field: String, value: Bool) {
        do {
            let info = try store.updateBoolField(id: id.uuidString, field: field, value: value)
            didMutate(structural: false, affectedIDs: [id], kind: .otherField)
            UndoCoordinator.shared.registerUndo(info: info)
        } catch {
            Logger.library.error("updateBoolField failed: \(error)")
        }
    }

    /// Update an integer field on any item.
    public func updateIntField(id: UUID, field: String, value: Int64?) {
        do {
            let info = try store.updateIntField(id: id.uuidString, field: field, value: value)
            didMutate(structural: false, affectedIDs: [id], kind: .otherField)
            UndoCoordinator.shared.registerUndo(info: info)
        } catch {
            Logger.library.error("updateIntField failed: \(error)")
        }
    }

    /// Delete publications (undoable — snapshots items before deletion).
    public func deletePublications(ids: [UUID]) {
        do {
            let snapshots = try store.deletePublicationsUndoable(ids: ids.map(\.uuidString))
            didMutate()
            let count = ids.count
            let desc = count == 1 ? "Delete Paper" : "Delete \(count) Papers"
            let capturedStore = store
            UndoCoordinator.shared.registerUndoClosure(
                actionName: desc,
                undo: { [weak self] in
                    do {
                        try capturedStore.restoreSnapshots(snapshots: snapshots)
                        self?.didMutate()
                    } catch {
                        Logger.library.error("Undo deletePublications failed: \(error)")
                    }
                },
                redo: { [weak self] in
                    do {
                        try capturedStore.deletePublications(ids: ids.map(\.uuidString))
                        self?.didMutate()
                    } catch {
                        Logger.library.error("Redo deletePublications failed: \(error)")
                    }
                }
            )
        } catch {
            Logger.library.error("deletePublications failed: \(error)")
        }
    }

    /// Delete any item by ID (undoable — snapshots item before deletion).
    public func deleteItem(id: UUID) {
        do {
            let snapshots = try store.deletePublicationsUndoable(ids: [id.uuidString])
            didMutate()
            let capturedStore = store
            UndoCoordinator.shared.registerUndoClosure(
                actionName: "Delete",
                undo: { [weak self] in
                    do {
                        try capturedStore.restoreSnapshots(snapshots: snapshots)
                        self?.didMutate()
                    } catch {
                        Logger.library.error("Undo deleteItem failed: \(error)")
                    }
                },
                redo: { [weak self] in
                    do {
                        try capturedStore.deleteItem(id: id.uuidString)
                        self?.didMutate()
                    } catch {
                        Logger.library.error("Redo deleteItem failed: \(error)")
                    }
                }
            )
        } catch {
            Logger.library.error("deleteItem failed: \(error)")
        }
    }

    /// Move publications between libraries.
    ///
    /// Moves physical files (PDFs, attachments) **before** the database mutation
    /// so that the viewer can always find the file at the path implied by `parent_id`.
    public func movePublications(ids: [UUID], toLibraryId: UUID) {
        // Move physical files BEFORE database mutation
        let attachmentManager = AttachmentManager.shared
        for pubID in ids {
            if let detail = getPublicationDetail(id: pubID),
               let sourceLibraryID = detail.libraryIDs.first,
               sourceLibraryID != toLibraryId {
                let linkedFiles = listLinkedFiles(publicationId: pubID)
                for file in linkedFiles {
                    do {
                        try attachmentManager.moveLinkedFile(file, from: sourceLibraryID, to: toLibraryId)
                    } catch {
                        Logger.library.error("Failed to move file \(file.filename) for pub \(pubID): \(error)")
                        // Continue — DB move will proceed, health check can repair later
                    }
                }
            }
        }

        do {
            let info = try store.movePublications(ids: ids.map(\.uuidString), toLibraryId: toLibraryId.uuidString)
            didMutate()
            UndoCoordinator.shared.registerUndo(info: info)
        } catch {
            Logger.library.error("movePublications failed: \(error)")
        }
    }

    /// Duplicate publications to another library (undoable).
    public func duplicatePublications(ids: [UUID], toLibraryId: UUID) -> [UUID] {
        do {
            let newIds = try store.duplicatePublications(ids: ids.map(\.uuidString), toLibraryId: toLibraryId.uuidString)
            didMutate()
            let newUUIDs = newIds.compactMap { UUID(uuidString: $0) }
            if !newIds.isEmpty {
                let capturedStore = store
                let capturedNewIds = newIds
                UndoCoordinator.shared.registerUndoClosure(
                    actionName: "Duplicate Papers",
                    undo: { [weak self] in
                        do {
                            try capturedStore.deletePublications(ids: capturedNewIds)
                            self?.didMutate()
                        } catch {
                            Logger.library.error("Undo duplicatePublications failed: \(error)")
                        }
                    }
                )
            }
            return newUUIDs
        } catch {
            Logger.library.error("duplicatePublications failed: \(error)")
            return []
        }
    }

    // MARK: - Library Operations

    /// List all libraries.
    public func listLibraries() -> [LibraryModel] {
        StoreTimings.shared.measure("listLibraries") {
            do {
                return try store.listLibraries().map { LibraryModel(from: $0) }
            } catch {
                Logger.library.error("listLibraries failed: \(error)")
                return []
            }
        }
    }

    /// Get a single library.
    public func getLibrary(id: UUID) -> LibraryModel? {
        do {
            guard let row = try store.getLibrary(id: id.uuidString) else { return nil }
            return LibraryModel(from: row)
        } catch {
            Logger.library.error("getLibrary failed: \(error)")
            return nil
        }
    }

    /// Get the default library.
    public func getDefaultLibrary() -> LibraryModel? {
        StoreTimings.shared.measure("getDefaultLibrary") {
            do {
                guard let row = try store.getDefaultLibrary() else { return nil }
                return LibraryModel(from: row)
            } catch {
                Logger.library.error("getDefaultLibrary failed: \(error)")
                return nil
            }
        }
    }

    /// Get the inbox library.
    public func getInboxLibrary() -> LibraryModel? {
        do {
            guard let row = try store.getInboxLibrary() else { return nil }
            return LibraryModel(from: row)
        } catch {
            Logger.library.error("getInboxLibrary failed: \(error)")
            return nil
        }
    }

    /// Create a new library (undoable).
    public func createLibrary(name: String) -> LibraryModel? {
        do {
            let row = try store.createLibrary(name: name)
            didMutate()
            let newId = row.id
            let capturedStore = store
            UndoCoordinator.shared.registerUndoClosure(
                actionName: "Create Library",
                undo: { [weak self] in
                    do {
                        try capturedStore.deleteLibrary(id: newId)
                        self?.didMutate()
                    } catch {
                        Logger.library.error("Undo createLibrary failed: \(error)")
                    }
                }
            )
            return LibraryModel(from: row)
        } catch {
            Logger.library.error("createLibrary failed: \(error)")
            return nil
        }
    }

    /// Create an inbox library (undoable).
    public func createInboxLibrary(name: String) -> LibraryModel? {
        do {
            let row = try store.createInboxLibrary(name: name)
            didMutate()
            let newId = row.id
            let capturedStore = store
            UndoCoordinator.shared.registerUndoClosure(
                actionName: "Create Inbox Library",
                undo: { [weak self] in
                    do {
                        try capturedStore.deleteLibrary(id: newId)
                        self?.didMutate()
                    } catch {
                        Logger.library.error("Undo createInboxLibrary failed: \(error)")
                    }
                }
            )
            return LibraryModel(from: row)
        } catch {
            Logger.library.error("createInboxLibrary failed: \(error)")
            return nil
        }
    }

    /// Set a library as the default (undoable).
    public func setLibraryDefault(id: UUID) {
        do {
            // Find current default before changing
            let libs = try store.listLibraries()
            let prevDefaultId = libs.first(where: { $0.isDefault })?.id

            try store.setLibraryDefault(id: id.uuidString)
            didMutate()

            if let prevId = prevDefaultId, prevId != id.uuidString {
                let capturedStore = store
                UndoCoordinator.shared.registerUndoClosure(
                    actionName: "Set Default Library",
                    undo: { [weak self] in
                        do {
                            try capturedStore.setLibraryDefault(id: prevId)
                            self?.didMutate()
                        } catch {
                            Logger.library.error("Undo setLibraryDefault failed: \(error)")
                        }
                    },
                    redo: { [weak self] in
                        do {
                            try capturedStore.setLibraryDefault(id: id.uuidString)
                            self?.didMutate()
                        } catch {
                            Logger.library.error("Redo setLibraryDefault failed: \(error)")
                        }
                    }
                )
            }
        } catch {
            Logger.library.error("setLibraryDefault failed: \(error)")
        }
    }

    /// Delete a library (undoable — snapshots library and records child IDs).
    public func deleteLibrary(id: UUID) {
        do {
            let snapshot = try store.deleteLibraryUndoable(id: id.uuidString)
            didMutate()
            let capturedStore = store
            UndoCoordinator.shared.registerUndoClosure(
                actionName: "Delete Library",
                undo: { [weak self] in
                    do {
                        try capturedStore.restoreLibrary(snapshot: snapshot)
                        self?.didMutate()
                    } catch {
                        Logger.library.error("Undo deleteLibrary failed: \(error)")
                    }
                },
                redo: { [weak self] in
                    do {
                        try capturedStore.deleteLibrary(id: id.uuidString)
                        self?.didMutate()
                    } catch {
                        Logger.library.error("Redo deleteLibrary failed: \(error)")
                    }
                }
            )
        } catch {
            Logger.library.error("deleteLibrary failed: \(error)")
        }
    }

    // MARK: - Collection Operations

    /// List collections in a library.
    public func listCollections(libraryId: UUID) -> [CollectionModel] {
        StoreTimings.shared.measure("listCollections") {
            do {
                return try store.listCollections(libraryId: libraryId.uuidString).map { CollectionModel(from: $0) }
            } catch {
                Logger.library.error("listCollections failed: \(error)")
                return []
            }
        }
    }

    /// Create a collection (undoable).
    public func createCollection(name: String, libraryId: UUID, isSmart: Bool = false, query: String? = nil) -> CollectionModel? {
        do {
            let row = try store.createCollection(name: name, libraryId: libraryId.uuidString, isSmart: isSmart, query: query)
            didMutate()
            let newId = row.id
            let capturedStore = store
            UndoCoordinator.shared.registerUndoClosure(
                actionName: "Create Collection",
                undo: { [weak self] in
                    do {
                        try capturedStore.deleteItem(id: newId)
                        self?.didMutate()
                    } catch {
                        Logger.library.error("Undo createCollection failed: \(error)")
                    }
                }
            )
            return CollectionModel(from: row)
        } catch {
            Logger.library.error("createCollection failed: \(error)")
            return nil
        }
    }

    /// Add publications to a collection.
    public func addToCollection(publicationIds: [UUID], collectionId: UUID) {
        StoreTimings.shared.measure("addToCollection") {
            do {
                let info = try store.addToCollection(publicationIds: publicationIds.map(\.uuidString), collectionId: collectionId.uuidString)
                didMutate()
                UndoCoordinator.shared.registerUndo(info: info)
            } catch {
                Logger.library.error("addToCollection failed: \(error)")
            }
        }
    }

    /// Remove publications from a collection.
    public func removeFromCollection(publicationIds: [UUID], collectionId: UUID) {
        do {
            let info = try store.removeFromCollection(publicationIds: publicationIds.map(\.uuidString), collectionId: collectionId.uuidString)
            didMutate()
            UndoCoordinator.shared.registerUndo(info: info)
        } catch {
            Logger.library.error("removeFromCollection failed: \(error)")
        }
    }

    /// Remove all dismissed papers from a collection.
    /// Returns the number of members removed.
    @discardableResult
    public func purgeCollectionDismissed(collectionId: UUID) -> Int {
        do {
            let count = try store.purgeDismissedFromCollection(collectionId: collectionId.uuidString)
            if count > 0 { didMutate() }
            return Int(count)
        } catch {
            Logger.library.error("purgeCollectionDismissed failed: \(error)")
            return 0
        }
    }

    // MARK: - Tag Operations

    /// List all tag definitions (for display).
    public func listTags() -> [TagDisplayData] {
        do {
            return try store.listTags().map { tag in
                TagDisplayData(
                    id: UUID(),
                    path: tag.path,
                    leaf: tag.leafName,
                    colorLight: tag.colorLight,
                    colorDark: tag.colorDark
                )
            }
        } catch {
            Logger.library.error("listTags failed: \(error)")
            return []
        }
    }

    /// List tag definitions with publication counts (for settings/management).
    public func listTagsWithCounts() -> [TagDefinition] {
        StoreTimings.shared.measure("listTagsWithCounts") {
            do {
                return try store.listTagsWithCounts().map { TagDefinition(from: $0) }
            } catch {
                Logger.library.error("listTagsWithCounts failed: \(error)")
                return []
            }
        }
    }

    /// Create a tag definition (undoable).
    public func createTag(path: String, colorLight: String? = nil, colorDark: String? = nil) {
        do {
            try store.createTag(path: path, colorLight: colorLight, colorDark: colorDark)
            didMutate()
            let capturedStore = store
            UndoCoordinator.shared.registerUndoClosure(
                actionName: "Create Tag",
                undo: { [weak self] in
                    do {
                        try capturedStore.deleteTag(path: path)
                        self?.didMutate()
                    } catch {
                        Logger.library.error("Undo createTag failed: \(error)")
                    }
                }
            )
        } catch {
            Logger.library.error("createTag failed: \(error)")
        }
    }

    /// Add a tag to publications.
    public func addTag(ids: [UUID], tagPath: String) {
        do {
            let info = try store.addTag(ids: ids.map(\.uuidString), tagPath: tagPath)
            didMutate(structural: false, affectedIDs: Set(ids), kind: .tag)
            UndoCoordinator.shared.registerUndo(info: info)
        } catch {
            Logger.library.error("addTag failed: \(error)")
        }
    }

    /// Remove a tag from publications.
    public func removeTag(ids: [UUID], tagPath: String) {
        do {
            let info = try store.removeTag(ids: ids.map(\.uuidString), tagPath: tagPath)
            didMutate(structural: false, affectedIDs: Set(ids), kind: .tag)
            UndoCoordinator.shared.registerUndo(info: info)
        } catch {
            Logger.library.error("removeTag failed: \(error)")
        }
    }

    /// Rename a tag definition and all assignments (undoable).
    public func renameTag(oldPath: String, newPath: String) {
        do {
            try store.renameTag(oldPath: oldPath, newPath: newPath)
            didMutate()
            let capturedStore = store
            UndoCoordinator.shared.registerUndoClosure(
                actionName: "Rename Tag",
                undo: { [weak self] in
                    do {
                        try capturedStore.renameTag(oldPath: newPath, newPath: oldPath)
                        self?.didMutate()
                    } catch {
                        Logger.library.error("Undo renameTag failed: \(error)")
                    }
                },
                redo: { [weak self] in
                    do {
                        try capturedStore.renameTag(oldPath: oldPath, newPath: newPath)
                        self?.didMutate()
                    } catch {
                        Logger.library.error("Redo renameTag failed: \(error)")
                    }
                }
            )
        } catch {
            Logger.library.error("renameTag failed: \(error)")
        }
    }

    /// Delete a tag definition and remove from all publications (undoable).
    public func deleteTag(path: String) {
        do {
            let snapshot = try store.deleteTagUndoable(path: path)
            didMutate()
            let capturedStore = store
            UndoCoordinator.shared.registerUndoClosure(
                actionName: "Delete Tag '\(path.split(separator: "/").last ?? Substring(path))'",
                undo: { [weak self] in
                    do {
                        try capturedStore.restoreTag(snapshot: snapshot)
                        self?.didMutate()
                    } catch {
                        Logger.library.error("Undo deleteTag failed: \(error)")
                    }
                },
                redo: { [weak self] in
                    do {
                        try capturedStore.deleteTag(path: path)
                        self?.didMutate()
                    } catch {
                        Logger.library.error("Redo deleteTag failed: \(error)")
                    }
                }
            )
        } catch {
            Logger.library.error("deleteTag failed: \(error)")
        }
    }

    /// Update tag definition colors (undoable).
    public func updateTag(path: String, colorLight: String?, colorDark: String?) {
        do {
            // Snapshot current colors before update
            let tags = try store.listTags()
            let prevTag = tags.first(where: { $0.path == path })
            let prevLight = prevTag?.colorLight
            let prevDark = prevTag?.colorDark

            try store.updateTag(path: path, colorLight: colorLight, colorDark: colorDark)
            didMutate()

            let capturedStore = store
            UndoCoordinator.shared.registerUndoClosure(
                actionName: "Update Tag",
                undo: { [weak self] in
                    do {
                        try capturedStore.updateTag(path: path, colorLight: prevLight, colorDark: prevDark)
                        self?.didMutate()
                    } catch {
                        Logger.library.error("Undo updateTag failed: \(error)")
                    }
                },
                redo: { [weak self] in
                    do {
                        try capturedStore.updateTag(path: path, colorLight: colorLight, colorDark: colorDark)
                        self?.didMutate()
                    } catch {
                        Logger.library.error("Redo updateTag failed: \(error)")
                    }
                }
            )
        } catch {
            Logger.library.error("updateTag failed: \(error)")
        }
    }

    // MARK: - Undo/Redo

    /// Undo a single operation. Returns UndoInfo for the redo action, or nil on failure.
    public func undoOperation(operationId: String) -> UndoInfo? {
        do {
            let info = try store.undoOperation(operationId: operationId)
            didMutate()
            return info
        } catch {
            Logger.library.error("undoOperation failed: \(error)")
            return nil
        }
    }

    /// Undo all operations in a batch. Returns UndoInfo for the redo action, or nil on failure.
    public func undoBatch(batchId: String) -> UndoInfo? {
        do {
            let info = try store.undoBatch(batchId: batchId)
            didMutate()
            return info
        } catch {
            Logger.library.error("undoBatch failed: \(error)")
            return nil
        }
    }

    /// Fetch recent undo groups from the Rust operation log for the undo history panel.
    public func recentUndoGroups(maxEntries: Int = 50) -> [ImbibRustCore.UndoGroupRow] {
        do {
            return try store.recentUndoGroups(maxEntries: UInt32(maxEntries))
        } catch {
            Logger.library.error("recentUndoGroups failed: \(error)")
            return []
        }
    }

    // MARK: - Linked File Operations

    /// List linked files for a publication.
    public func listLinkedFiles(publicationId: UUID) -> [LinkedFileModel] {
        do {
            return try store.listLinkedFiles(publicationId: publicationId.uuidString).map { LinkedFileModel(from: $0) }
        } catch {
            Logger.library.error("listLinkedFiles failed: \(error)")
            return []
        }
    }

    /// Get a single linked file.
    public func getLinkedFile(id: UUID) -> LinkedFileModel? {
        do {
            guard let row = try store.getLinkedFile(id: id.uuidString) else { return nil }
            return LinkedFileModel(from: row)
        } catch {
            Logger.library.error("getLinkedFile failed: \(error)")
            return nil
        }
    }

    /// Add a linked file to a publication.
    public func addLinkedFile(
        publicationId: UUID,
        filename: String,
        relativePath: String? = nil,
        fileType: String? = nil,
        fileSize: Int64 = 0,
        sha256: String? = nil,
        isPdf: Bool = true
    ) -> LinkedFileModel? {
        do {
            let row = try store.addLinkedFile(
                publicationId: publicationId.uuidString,
                filename: filename,
                relativePath: relativePath,
                fileType: fileType,
                fileSize: fileSize,
                sha256: sha256,
                isPdf: isPdf
            )
            didMutate()
            NotificationCenter.default.post(name: .attachmentDidChange, object: nil,
                userInfo: ["publicationID": publicationId])
            return LinkedFileModel(from: row)
        } catch {
            Logger.library.error("addLinkedFile failed: \(error)")
            return nil
        }
    }

    /// Set locally materialized status on a linked file.
    public func setLocallyMaterialized(id: UUID, materialized: Bool) {
        do {
            try store.setLocallyMaterialized(id: id.uuidString, materialized: materialized)
            didMutate()
        } catch {
            Logger.library.error("setLocallyMaterialized failed: \(error)")
        }
    }

    /// Set PDF cloud availability on a linked file.
    public func setPdfCloudAvailable(id: UUID, available: Bool) {
        do {
            try store.setPdfCloudAvailable(id: id.uuidString, available: available)
            didMutate()
        } catch {
            Logger.library.error("setPdfCloudAvailable failed: \(error)")
        }
    }

    /// Count PDFs for a publication.
    public func countPdfs(publicationId: UUID) -> Int {
        do {
            return Int(try store.countPdfs(publicationId: publicationId.uuidString))
        } catch {
            Logger.library.error("countPdfs failed: \(error)")
            return 0
        }
    }

    // MARK: - Annotation Operations

    /// List annotations for a linked file.
    public func listAnnotations(linkedFileId: UUID, pageNumber: Int32? = nil) -> [AnnotationModel] {
        do {
            return try store.listAnnotations(linkedFileId: linkedFileId.uuidString, pageNumber: pageNumber).map { AnnotationModel(from: $0) }
        } catch {
            Logger.library.error("listAnnotations failed: \(error)")
            return []
        }
    }

    /// Create an annotation.
    public func createAnnotation(
        linkedFileId: UUID,
        annotationType: String,
        pageNumber: Int64,
        boundsJson: String? = nil,
        color: String? = nil,
        contents: String? = nil,
        selectedText: String? = nil
    ) -> AnnotationModel? {
        do {
            let row = try store.createAnnotation(
                linkedFileId: linkedFileId.uuidString,
                annotationType: annotationType,
                pageNumber: pageNumber,
                boundsJson: boundsJson,
                color: color,
                contents: contents,
                selectedText: selectedText
            )
            didMutate()
            return AnnotationModel(from: row)
        } catch {
            Logger.library.error("createAnnotation failed: \(error)")
            return nil
        }
    }

    /// Count annotations for a linked file.
    public func countAnnotations(linkedFileId: UUID) -> Int {
        do {
            return Int(try store.countAnnotations(linkedFileId: linkedFileId.uuidString))
        } catch {
            Logger.library.error("countAnnotations failed: \(error)")
            return 0
        }
    }

    // MARK: - Comment Operations

    /// List comments for a publication (backward-compatible).
    public func listComments(publicationId: UUID) -> [Comment] {
        listCommentsForItem(itemId: publicationId)
    }

    /// List comments for any item (publication, artifact, etc.).
    public func listCommentsForItem(itemId: UUID) -> [Comment] {
        do {
            // The Rust listComments accepts any parent item ID
            return try store.listComments(publicationId: itemId.uuidString).map { Comment(from: $0) }
        } catch {
            Logger.library.error("listCommentsForItem failed: \(error)")
            return []
        }
    }

    /// Create a comment on a publication (backward-compatible).
    public func createComment(
        publicationId: UUID,
        text: String,
        authorIdentifier: String? = nil,
        authorDisplayName: String? = nil,
        parentCommentId: UUID? = nil
    ) -> Comment? {
        createCommentOnItem(
            itemId: publicationId,
            text: text,
            authorIdentifier: authorIdentifier,
            authorDisplayName: authorDisplayName,
            parentCommentId: parentCommentId
        )
    }

    /// Create a comment on any item (publication, artifact, etc.).
    public func createCommentOnItem(
        itemId: UUID,
        text: String,
        authorIdentifier: String? = nil,
        authorDisplayName: String? = nil,
        parentCommentId: UUID? = nil
    ) -> Comment? {
        do {
            // The Rust createComment accepts any parent item ID
            let row = try store.createComment(
                publicationId: itemId.uuidString,
                text: text,
                authorIdentifier: authorIdentifier,
                authorDisplayName: authorDisplayName,
                parentCommentId: parentCommentId?.uuidString
            )
            didMutate()
            return Comment(from: row)
        } catch {
            Logger.library.error("createCommentOnItem failed: \(error)")
            return nil
        }
    }

    /// Update a comment's text.
    public func updateComment(id: UUID, text: String) {
        do {
            try store.updateComment(id: id.uuidString, text: text)
            didMutate()
        } catch {
            Logger.library.error("updateComment failed: \(error)")
        }
    }

    // MARK: - Assignment Operations

    /// List assignments.
    public func listAssignments(publicationId: UUID? = nil) -> [Assignment] {
        do {
            return try store.listAssignments(publicationId: publicationId?.uuidString).map { Assignment(from: $0) }
        } catch {
            Logger.library.error("listAssignments failed: \(error)")
            return []
        }
    }

    /// Create an assignment.
    public func createAssignment(
        publicationId: UUID,
        assigneeName: String,
        assignedByName: String? = nil,
        note: String? = nil,
        dueDate: Int64? = nil
    ) -> Assignment? {
        do {
            let row = try store.createAssignment(
                publicationId: publicationId.uuidString,
                assigneeName: assigneeName,
                assignedByName: assignedByName,
                note: note,
                dueDate: dueDate
            )
            didMutate()
            return Assignment(from: row)
        } catch {
            Logger.library.error("createAssignment failed: \(error)")
            return nil
        }
    }

    // MARK: - Smart Search Operations

    /// List smart searches.
    public func listSmartSearches(libraryId: UUID? = nil) -> [SmartSearch] {
        StoreTimings.shared.measure("listSmartSearches") {
            do {
                return try store.listSmartSearches(libraryId: libraryId?.uuidString).map { SmartSearch(from: $0) }
            } catch {
                Logger.library.error("listSmartSearches failed: \(error)")
                return []
            }
        }
    }

    /// Get a smart search.
    public func getSmartSearch(id: UUID) -> SmartSearch? {
        do {
            guard let row = try store.getSmartSearch(id: id.uuidString) else { return nil }
            return SmartSearch(from: row)
        } catch {
            Logger.library.error("getSmartSearch failed: \(error)")
            return nil
        }
    }

    /// Create a smart search.
    public func createSmartSearch(
        name: String,
        query: String,
        libraryId: UUID,
        sourceIdsJson: String? = nil,
        maxResults: Int64 = 100,
        feedsToInbox: Bool = false,
        autoRefreshEnabled: Bool = false,
        refreshIntervalSeconds: Int64 = 3600
    ) -> SmartSearch? {
        do {
            let row = try store.createSmartSearch(
                name: name,
                query: query,
                libraryId: libraryId.uuidString,
                sourceIdsJson: sourceIdsJson,
                maxResults: maxResults,
                feedsToInbox: feedsToInbox,
                autoRefreshEnabled: autoRefreshEnabled,
                refreshIntervalSeconds: refreshIntervalSeconds
            )
            didMutate()
            return SmartSearch(from: row)
        } catch {
            Logger.library.error("createSmartSearch failed: \(error)")
            return nil
        }
    }

    // MARK: - SciX Library Operations

    /// List SciX libraries.
    public func listScixLibraries() -> [SciXLibrary] {
        do {
            return try store.listScixLibraries().map { SciXLibrary(from: $0) }
        } catch {
            Logger.library.error("listScixLibraries failed: \(error)")
            return []
        }
    }

    /// Get a SciX library.
    public func getScixLibrary(id: UUID) -> SciXLibrary? {
        do {
            guard let row = try store.getScixLibrary(id: id.uuidString) else { return nil }
            return SciXLibrary(from: row)
        } catch {
            Logger.library.error("getScixLibrary failed: \(error)")
            return nil
        }
    }

    /// Create a SciX library.
    public func createScixLibrary(
        remoteId: String,
        name: String,
        description: String? = nil,
        isPublic: Bool = false,
        permissionLevel: String = "read",
        ownerEmail: String? = nil
    ) -> SciXLibrary? {
        do {
            let row = try store.createScixLibrary(
                remoteId: remoteId,
                name: name,
                description: description,
                isPublic: isPublic,
                permissionLevel: permissionLevel,
                ownerEmail: ownerEmail
            )
            didMutate()
            return SciXLibrary(from: row)
        } catch {
            Logger.library.error("createScixLibrary failed: \(error)")
            return nil
        }
    }

    /// Add publications to a SciX library.
    public func addToScixLibrary(publicationIds: [UUID], scixLibraryId: UUID) {
        Logger.library.infoCapture("addToScixLibrary: \(publicationIds.count) pubs → library \(scixLibraryId)", category: "scix")
        do {
            try store.addToScixLibrary(publicationIds: publicationIds.map(\.uuidString), scixLibraryId: scixLibraryId.uuidString)
            Logger.library.infoCapture("addToScixLibrary: success — \(publicationIds.count) edges created", category: "scix")
            didMutate()
        } catch {
            Logger.library.errorCapture("addToScixLibrary failed: \(error)", category: "scix")
        }
    }

    /// Remove publications from a SciX library (removes edges, keeps items).
    public func removeFromScixLibrary(publicationIds: [UUID], scixLibraryId: UUID) {
        do {
            let info = try store.removeFromScixLibrary(publicationIds: publicationIds.map(\.uuidString), scixLibraryId: scixLibraryId.uuidString)
            didMutate()
            UndoCoordinator.shared.registerUndo(info: info)
        } catch {
            Logger.library.errorCapture("removeFromScixLibrary failed: \(error)", category: "scix")
        }
    }

    // MARK: - Inbox & Triage

    /// Create a muted item.
    public func createMutedItem(muteType: String, value: String) -> MutedItem? {
        do {
            let row = try store.createMutedItem(muteType: muteType, value: value)
            didMutate()
            return MutedItem(from: row)
        } catch {
            Logger.library.error("createMutedItem failed: \(error)")
            return nil
        }
    }

    /// List muted items.
    public func listMutedItems(muteType: String? = nil) -> [MutedItem] {
        do {
            return try store.listMutedItems(muteType: muteType).map { MutedItem(from: $0) }
        } catch {
            Logger.library.error("listMutedItems failed: \(error)")
            return []
        }
    }

    /// Dismiss a paper from inbox.
    public func dismissPaper(doi: String? = nil, arxivId: String? = nil, bibcode: String? = nil, citeKey: String? = nil) -> DismissedPaper? {
        do {
            let row = try store.dismissPaper(doi: doi, arxivId: arxivId, bibcode: bibcode, citeKey: citeKey)
            didMutate()
            return DismissedPaper(from: row)
        } catch {
            Logger.library.error("dismissPaper failed: \(error)")
            return nil
        }
    }

    /// Check if a paper has been dismissed.
    public func isPaperDismissed(doi: String? = nil, arxivId: String? = nil, bibcode: String? = nil, citeKey: String? = nil) -> Bool {
        StoreTimings.shared.measure("isPaperDismissed") {
            do {
                return try store.isPaperDismissed(doi: doi, arxivId: arxivId, bibcode: bibcode, citeKey: citeKey)
            } catch {
                Logger.library.error("isPaperDismissed failed: \(error)")
                return false
            }
        }
    }

    /// List dismissed papers.
    public func listDismissedPapers(limit: UInt32? = nil, offset: UInt32? = nil) -> [DismissedPaper] {
        do {
            return try store.listDismissedPapers(limit: limit, offset: offset).map { DismissedPaper(from: $0) }
        } catch {
            Logger.library.error("listDismissedPapers failed: \(error)")
            return []
        }
    }

    /// Count unread publications.
    public func countUnread(parentId: UUID? = nil) -> Int {
        do {
            return Int(try store.countUnread(parentId: parentId?.uuidString))
        } catch {
            Logger.library.error("countUnread failed: \(error)")
            return 0
        }
    }

    /// Count unread publications in a collection (via Contains-edge join).
    public func countUnreadInCollection(collectionId: UUID) -> Int {
        StoreTimings.shared.measure("countUnreadInCollection") {
            do {
                return Int(try store.countUnreadInCollection(collectionId: collectionId.uuidString))
            } catch {
                Logger.library.error("countUnreadInCollection failed: \(error)")
                return 0
            }
        }
    }

    /// Count publications (SELECT COUNT — no row deserialization).
    public func countPublications(parentId: UUID? = nil) -> Int {
        do {
            return Int(try store.countPublications(parentId: parentId?.uuidString))
        } catch {
            Logger.library.error("countPublications failed: \(error)")
            return 0
        }
    }

    /// Count starred publications.
    public func countStarred(parentId: UUID? = nil) -> Int {
        do {
            return try store.queryStarred(parentId: parentId?.uuidString, sortField: "created", ascending: false, limit: nil, offset: nil).count
        } catch {
            Logger.library.error("countStarred failed: \(error)")
            return 0
        }
    }

    // MARK: - Activity Records

    /// List activity records for a library.
    public func listActivityRecords(libraryId: UUID, limit: UInt32? = nil, offset: UInt32? = nil) -> [ActivityRecord] {
        do {
            return try store.listActivityRecords(libraryId: libraryId.uuidString, limit: limit, offset: offset).map { ActivityRecord(from: $0) }
        } catch {
            Logger.library.error("listActivityRecords failed: \(error)")
            return []
        }
    }

    /// Create an activity record.
    public func createActivityRecord(
        libraryId: UUID,
        activityType: String,
        actorDisplayName: String? = nil,
        targetTitle: String? = nil,
        targetId: String? = nil,
        detail: String? = nil
    ) -> ActivityRecord? {
        do {
            let row = try store.createActivityRecord(
                libraryId: libraryId.uuidString,
                activityType: activityType,
                actorDisplayName: actorDisplayName,
                targetTitle: targetTitle,
                targetId: targetId,
                detail: detail
            )
            didMutate()
            return ActivityRecord(from: row)
        } catch {
            Logger.library.error("createActivityRecord failed: \(error)")
            return nil
        }
    }

    /// Clear all activity records for a library.
    public func clearActivityRecords(libraryId: UUID) {
        do {
            try store.clearActivityRecords(libraryId: libraryId.uuidString)
            didMutate()
        } catch {
            Logger.library.error("clearActivityRecords failed: \(error)")
        }
    }

    // MARK: - Recommendation Profiles

    /// Get recommendation profile JSON for a library.
    public func getRecommendationProfile(libraryId: UUID) -> String? {
        do {
            return try store.getRecommendationProfile(libraryId: libraryId.uuidString)
        } catch {
            Logger.library.error("getRecommendationProfile failed: \(error)")
            return nil
        }
    }

    /// Create or update a recommendation profile.
    public func createOrUpdateRecommendationProfile(
        libraryId: UUID,
        topicAffinitiesJson: String? = nil,
        authorAffinitiesJson: String? = nil,
        venueAffinitiesJson: String? = nil,
        trainingEventsJson: String? = nil
    ) {
        do {
            try store.createOrUpdateRecommendationProfile(
                libraryId: libraryId.uuidString,
                topicAffinitiesJson: topicAffinitiesJson,
                authorAffinitiesJson: authorAffinitiesJson,
                venueAffinitiesJson: venueAffinitiesJson,
                trainingEventsJson: trainingEventsJson
            )
            didMutate()
        } catch {
            Logger.library.error("createOrUpdateRecommendationProfile failed: \(error)")
        }
    }

    /// Delete a recommendation profile.
    public func deleteRecommendationProfile(libraryId: UUID) {
        do {
            try store.deleteRecommendationProfile(libraryId: libraryId.uuidString)
            didMutate()
        } catch {
            Logger.library.error("deleteRecommendationProfile failed: \(error)")
        }
    }

    // MARK: - Export

    /// Export publications as BibTeX.
    public func exportBibTeX(ids: [UUID]) -> String {
        do {
            return try store.exportBibtex(ids: ids.map(\.uuidString))
        } catch {
            Logger.library.error("exportBibTeX failed: \(error)")
            return ""
        }
    }

    /// Export all publications in a library as BibTeX.
    public func exportAllBibTeX(libraryId: UUID) -> String {
        do {
            return try store.exportAllBibtex(libraryId: libraryId.uuidString)
        } catch {
            Logger.library.error("exportAllBibTeX failed: \(error)")
            return ""
        }
    }

    // MARK: - Source Query Helper

    /// Query publications for a given source — central routing for all list views.
    ///
    /// All parameters are passed through to the underlying Rust queries, which handle
    /// sorting via SQL ORDER BY and pagination via LIMIT/OFFSET.
    public func queryPublications(
        for source: PublicationSource,
        sort: String = "created",
        ascending: Bool = false,
        limit: UInt32? = nil,
        offset: UInt32? = nil
    ) -> [PublicationRowData] {
        switch source {
        case .library(let id):
            return queryPublications(parentId: id, sort: sort, ascending: ascending, limit: limit, offset: offset)
        case .collection(let id):
            return listCollectionMembers(collectionId: id, sort: sort, ascending: ascending, limit: limit, offset: offset)
        case .smartSearch(let id):
            return queryScixLibraryPublications(scixLibraryId: id, sort: sort, ascending: ascending, limit: limit, offset: offset)
        case .flagged(let color):
            return getFlaggedPublications(color: color, sort: sort, ascending: ascending, limit: limit, offset: offset)
        case .scixLibrary(let id):
            return queryScixLibraryPublications(scixLibraryId: id, sort: sort, ascending: ascending, limit: limit, offset: offset)
        case .unread:
            return queryUnread(sort: sort, ascending: ascending, limit: limit, offset: offset)
        case .starred:
            return queryStarred(sort: sort, ascending: ascending, limit: limit, offset: offset)
        case .tag(let path):
            return queryByTag(tagPath: path, sort: sort, ascending: ascending, limit: limit, offset: offset)
        case .inbox(let id):
            return queryPublications(parentId: id, sort: sort, ascending: ascending, limit: limit, offset: offset)
        case .dismissed:
            guard let idStr = UserDefaults.standard.string(forKey: "dismissedLibraryID"),
                  let dismissedID = UUID(uuidString: idStr) else { return [] }
            return queryPublications(parentId: dismissedID, sort: sort, ascending: ascending, limit: limit, offset: offset)
        case .citedInManuscripts:
            return queryCitedInManuscripts(sort: sort, ascending: ascending, limit: limit, offset: offset)
        case .combined(let children):
            return queryCombined(children: children, ascending: ascending, limit: limit, offset: offset)
        }
    }

    /// Query the union of multiple child sources. Fetches each child's rows,
    /// deduplicates by paper UUID (first occurrence wins), sorts by date-added
    /// (descending unless `ascending` is true), then applies paging.
    ///
    /// Honors only the `ascending` flag — `sort` is ignored, matching the
    /// established pattern for pseudo-sources like `.citedInManuscripts`.
    /// At scale (5+ libraries with thousands of papers each) this materialises
    /// the full set in memory; profile and optimise to a Rust-side `Predicate::Or`
    /// query if the client-side dedup proves slow in practice.
    /// Cached merged-sorted result for `queryCombined`. Pagination calls slice
    /// from this cache instead of re-materialising on every page load. The
    /// cache key encodes the deduplicated set of child viewIDs and the store's
    /// `dataVersion` — any mutation bumps `dataVersion` and invalidates the cache.
    private var combinedCache: (key: String, descending: [PublicationRowData])? = nil

    public func queryCombined(
        children: [PublicationSource],
        ascending: Bool = false,
        limit: UInt32? = nil,
        offset: UInt32? = nil
    ) -> [PublicationRowData] {
        StoreTimings.shared.measure("queryCombined") {
            guard !children.isEmpty else { return [] }

            // Cache key: child viewIDs (set semantics, order-independent) + dataVersion.
            // Identical re-queries during a scroll session hit the cached merged set.
            let childKey = children.map { $0.viewID.uuidString }.sorted().joined(separator: "|")
            let key = "\(childKey)#\(dataVersion)"

            let merged: [PublicationRowData]
            if let cache = combinedCache, cache.key == key {
                merged = cache.descending
            } else {
                var seen = Set<UUID>()
                var assembled: [PublicationRowData] = []
                for child in children {
                    let rows = queryPublications(for: child, sort: "created", ascending: false, limit: nil, offset: nil)
                    let label = sourceLabel(for: child)
                    for row in rows where seen.insert(row.id).inserted {
                        var tagged = row
                        if tagged.libraryName == nil { tagged.libraryName = label }
                        assembled.append(tagged)
                    }
                }
                assembled.sort { $0.dateAdded > $1.dateAdded }
                combinedCache = (key, assembled)
                merged = assembled
            }

            // Slice. Caller may want ascending — reverse the descending cache lazily.
            let ordered: [PublicationRowData] = ascending ? merged.reversed() : merged

            let startIndex = Int(offset ?? 0)
            guard startIndex < ordered.count else { return [] }
            let endIndex: Int
            if let limit {
                endIndex = min(ordered.count, startIndex + Int(limit))
            } else {
                endIndex = ordered.count
            }
            return Array(ordered[startIndex..<endIndex])
        }
    }

    /// Display label for a child source in `.combined` rendering. Library
    /// names are looked up directly; collection names are not yet plumbed
    /// (no `getCollection(id:)` API on the store) — fall back to "Collection".
    /// Other source kinds receive a generic label or nil.
    private func sourceLabel(for source: PublicationSource) -> String? {
        switch source {
        case .library(let id):
            return getLibrary(id: id)?.name
        case .collection:
            return "Collection"
        case .inbox(let id):
            return getLibrary(id: id)?.name
        default:
            return nil
        }
    }

    /// Fetch every publication that appears in at least one
    /// `citation-usage@1.0.0` record written by imprint's tracker.
    /// Reads the set of cited paper IDs from the live snapshot and
    /// materializes each via `getPublication(id:)`. Sort/limit/offset
    /// are applied client-side because the set is in-memory.
    public func queryCitedInManuscripts(
        sort: String = "created",
        ascending: Bool = false,
        limit: UInt32? = nil,
        offset: UInt32? = nil
    ) -> [PublicationRowData] {
        StoreTimings.shared.measure("queryCitedInManuscripts") {
            let ids = CitedInManuscriptsSnapshot.shared.citedPaperIDs
            guard !ids.isEmpty else { return [] }
            var rows: [PublicationRowData] = []
            rows.reserveCapacity(ids.count)
            for id in ids {
                if let row = getPublication(id: id) {
                    rows.append(row)
                }
            }
            // Sort by date_modified descending by default; callers
            // rarely pass a different sort for this pseudo-source.
            rows.sort { lhs, rhs in
                let cmp = lhs.dateAdded > rhs.dateAdded
                return ascending ? !cmp : cmp
            }
            // Apply paging semantics if the caller supplied them.
            let startIndex = Int(offset ?? 0)
            guard startIndex < rows.count else { return [] }
            let endIndex: Int
            if let limit {
                endIndex = min(rows.count, startIndex + Int(limit))
            } else {
                endIndex = rows.count
            }
            return Array(rows[startIndex..<endIndex])
        }
    }

    /// Count publications for a given source using SELECT COUNT(*) — no row deserialization.
    public func countPublications(for source: PublicationSource) -> Int {
        do {
            let count: UInt32 = try {
                switch source {
                case .library(let id):
                    return try store.countPublications(parentId: id.uuidString)
                case .collection(let id):
                    return try store.countCollectionMembersPublic(collectionId: id.uuidString)
                case .smartSearch(let id), .scixLibrary(let id):
                    return try store.countScixLibraryPublications(scixLibraryId: id.uuidString)
                case .flagged(let color):
                    return try store.countFlagged(color: color)
                case .unread:
                    return try store.countUnread(parentId: nil)
                case .starred:
                    return try store.countStarred(parentId: nil)
                case .tag(let path):
                    return try store.countByTag(tagPath: path, parentId: nil)
                case .inbox(let id):
                    return try store.countPublications(parentId: id.uuidString)
                case .dismissed:
                    guard let idStr = UserDefaults.standard.string(forKey: "dismissedLibraryID"),
                          let dismissedID = UUID(uuidString: idStr) else { return 0 }
                    return try store.countPublications(parentId: dismissedID.uuidString)
                case .citedInManuscripts:
                    // Snapshot is authoritative — no SQL COUNT needed.
                    return UInt32(CitedInManuscriptsSnapshot.shared.citedPaperIDs.count)
                case .combined(let children):
                    // Reuse queryCombined's cache. Calling with no limit/offset
                    // returns the full merged set; we just need its count, and
                    // the Array slice is cheap (it's the cache's storage).
                    let merged = queryCombined(children: children, ascending: false, limit: nil, offset: nil)
                    return UInt32(merged.count)
                }
            }()
            return Int(count)
        } catch {
            Logger.library.error("countPublications failed: \(error)")
            return 0
        }
    }

    /// Query publications linked to a SciX library via item_references (Contains edges).
    public func queryScixLibraryPublications(
        scixLibraryId: UUID,
        sort: String = "created",
        ascending: Bool = false,
        limit: UInt32? = nil,
        offset: UInt32? = nil
    ) -> [PublicationRowData] {
        StoreTimings.shared.measure("queryScixLibraryPublications") {
            do {
                let rows = try store.queryScixLibraryPublications(
                    scixLibraryId: scixLibraryId.uuidString,
                    sortField: sort,
                    ascending: ascending,
                    limit: limit,
                    offset: offset
                )
                return rows.compactMap { PublicationRowData(from: $0) }
            } catch {
                Logger.library.error("queryScixLibraryPublications failed: \(error)")
                return []
            }
        }
    }

    /// Re-parent an item (e.g. fix orphaned smart searches whose parent was deleted).
    public func reparentItem(id: UUID, newParentId: UUID) {
        do {
            try store.reparentItem(id: id.uuidString, newParentId: newParentId.uuidString)
            didMutate()
        } catch {
            Logger.library.error("reparentItem failed: \(error)")
        }
    }

    // MARK: - Convenience Methods (View Helpers)

    /// Get a smart search by ID. Alias for `getSmartSearch(id:)`.
    public func smartSearch(by id: UUID) -> SmartSearch? {
        getSmartSearch(id: id)
    }

    /// Update a smart search's name, query, and maxResults.
    ///
    /// Since the Rust store doesn't have an `updateSmartSearch` method,
    /// we use generic field updates for individual fields.
    public func updateSmartSearch(_ id: UUID, name: String, query: String, maxResults: Int16) {
        updateField(id: id, field: "name", value: name)
        updateField(id: id, field: "query", value: query)
        updateIntField(id: id, field: "max_results", value: Int64(maxResults))
    }

    /// Update a smart search with optional source IDs and max results.
    public func updateSmartSearch(
        id: UUID,
        name: String,
        query: String,
        sourceIdsJson: String?,
        maxResults: Int64
    ) {
        updateField(id: id, field: "name", value: name)
        updateField(id: id, field: "query", value: query)
        if let sourceIdsJson {
            updateField(id: id, field: "source_ids_json", value: sourceIdsJson)
        }
        updateIntField(id: id, field: "max_results", value: maxResults)
    }

    /// Update a smart search's feed settings (save target, retention, etc.).
    public func updateSmartSearchFeedSettings(
        id: UUID,
        saveTargetID: UUID?,
        showDismissed: Bool,
        retentionDays: Int?,
        autoRemoveRead: Bool
    ) {
        updateField(id: id, field: "save_target_id", value: saveTargetID?.uuidString)
        updateBoolField(id: id, field: "show_dismissed", value: showDismissed)
        updateIntField(id: id, field: "retention_days", value: retentionDays.map { Int64($0) })
        updateBoolField(id: id, field: "auto_remove_read", value: autoRemoveRead)
    }

    /// Update just the save target for a smart search.
    public func updateSmartSearchSaveTarget(id: UUID, saveTargetID: UUID?) {
        updateField(id: id, field: "save_target_id", value: saveTargetID?.uuidString)
    }

    /// Create an inbox feed smart search.
    public func createInboxFeed(
        name: String,
        query: String,
        sourceIDs: [String],
        maxResults: Int16? = nil,
        refreshIntervalSeconds: Int64 = 3600
    ) -> SmartSearch? {
        // Get or create inbox library
        guard let inboxLib = getInboxLibrary() else {
            Logger.library.error("createInboxFeed: no inbox library")
            return nil
        }
        let sourceIdsJson = sourceIDs.isEmpty ? nil : {
            if let data = try? JSONEncoder().encode(sourceIDs) {
                return String(data: data, encoding: .utf8)
            }
            return nil as String?
        }()
        return createSmartSearch(
            name: name,
            query: query,
            libraryId: inboxLib.id,
            sourceIdsJson: sourceIdsJson,
            maxResults: Int64(maxResults ?? 500),
            feedsToInbox: true,
            autoRefreshEnabled: true,
            refreshIntervalSeconds: refreshIntervalSeconds
        )
    }

    /// Create a library smart search.
    public func createLibrarySmartSearch(
        name: String,
        query: String,
        sourceIDs: [String],
        libraryID: UUID,
        maxResults: Int16? = nil
    ) -> SmartSearch? {
        let sourceIdsJson = sourceIDs.isEmpty ? nil : {
            if let data = try? JSONEncoder().encode(sourceIDs) {
                return String(data: data, encoding: .utf8)
            }
            return nil as String?
        }()
        return createSmartSearch(
            name: name,
            query: query,
            libraryId: libraryID,
            sourceIdsJson: sourceIdsJson,
            maxResults: Int64(maxResults ?? 100),
            autoRefreshEnabled: false,
            refreshIntervalSeconds: 86400
        )
    }

    /// Create an auto-refreshing feed in a non-inbox library.
    ///
    /// Unlike inbox feeds, these don't set `feedsToInbox`. FeedScheduler picks them up
    /// automatically since they have `autoRefreshEnabled = true`.
    public func createLibraryFeed(
        name: String,
        query: String,
        sourceIDs: [String],
        libraryID: UUID,
        maxResults: Int16? = nil,
        refreshIntervalSeconds: Int64 = 3600,
        saveTargetID: UUID? = nil
    ) -> SmartSearch? {
        let sourceIdsJson = sourceIDs.isEmpty ? nil : {
            if let data = try? JSONEncoder().encode(sourceIDs) {
                return String(data: data, encoding: .utf8)
            }
            return nil as String?
        }()
        guard let ss = createSmartSearch(
            name: name,
            query: query,
            libraryId: libraryID,
            sourceIdsJson: sourceIdsJson,
            maxResults: Int64(maxResults ?? 500),
            feedsToInbox: false,
            autoRefreshEnabled: true,
            refreshIntervalSeconds: refreshIntervalSeconds
        ) else { return nil }

        if let saveTargetID {
            updateSmartSearchSaveTarget(id: ss.id, saveTargetID: saveTargetID)
        }
        return ss
    }

    /// Create an exploration search.
    public func createExplorationSearch(
        name: String,
        query: String,
        sourceIDs: [String],
        maxResults: Int16? = nil
    ) -> SmartSearch? {
        // Use a designated exploration library — just use the default library for now
        guard let defaultLib = getDefaultLibrary() else {
            Logger.library.error("createExplorationSearch: no default library")
            return nil
        }
        let sourceIdsJson = sourceIDs.isEmpty ? nil : {
            if let data = try? JSONEncoder().encode(sourceIDs) {
                return String(data: data, encoding: .utf8)
            }
            return nil as String?
        }()
        return createSmartSearch(
            name: name,
            query: query,
            libraryId: defaultLib.id,
            sourceIdsJson: sourceIdsJson,
            maxResults: Int64(maxResults ?? 100),
            autoRefreshEnabled: false,
            refreshIntervalSeconds: 86400
        )
    }

    /// List recent activity for a library.
    public func recentActivity(libraryID: UUID, limit: Int) -> [ActivityRecord] {
        listActivityRecords(libraryId: libraryID, limit: UInt32(limit))
    }

    /// List comments for a publication.
    public func comments(for publicationID: UUID) -> [Comment] {
        listCommentsForItem(itemId: publicationID)
    }

    /// List comments for any item (publication, artifact, etc.).
    public func commentsForItem(_ itemID: UUID) -> [Comment] {
        listCommentsForItem(itemId: itemID)
    }

    /// Add a comment to a publication.
    ///
    /// `authorDisplayName` is the human-readable origin of the comment
    /// (typically `ImpressKit.CurrentDeviceAuthor.displayName`). Callers
    /// in the UI layer must pass it explicitly; Rule 7 of ADR-023
    /// keeps the data layer free of platform-specific lookups.
    public func addComment(
        text: String,
        to publicationID: UUID,
        authorDisplayName: String?,
        parentCommentID: UUID? = nil
    ) {
        addCommentToItem(
            text: text,
            itemID: publicationID,
            authorDisplayName: authorDisplayName,
            parentCommentID: parentCommentID
        )
    }

    /// Add a comment to any item (publication, artifact, etc.).
    ///
    /// `authorDisplayName` is the human-readable origin of the comment.
    /// Pass `ImpressKit.CurrentDeviceAuthor.displayName` from the UI
    /// layer. See `addComment(text:to:authorDisplayName:)` for the
    /// rationale.
    public func addCommentToItem(
        text: String,
        itemID: UUID,
        authorDisplayName: String?,
        parentCommentID: UUID? = nil
    ) {
        _ = createCommentOnItem(
            itemId: itemID,
            text: text,
            authorDisplayName: authorDisplayName,
            parentCommentId: parentCommentID
        )
    }

    /// Edit a comment's text.
    public func editComment(_ id: UUID, newText: String) {
        updateComment(id: id, text: newText)
    }

    /// Delete a comment.
    public func deleteComment(_ id: UUID) {
        deleteItem(id: id)
    }

    // MARK: - Sync Support (CloudKit)

    /// Set canonical_id on an item (maps to CKRecord.recordID).
    public func setItemCanonicalId(id: UUID, canonicalId: String) {
        do {
            try store.setItemCanonicalId(id: id.uuidString, canonicalId: canonicalId)
        } catch {
            Logger.library.error("setItemCanonicalId failed: \(error)")
        }
    }

    /// Set origin on an item (for sync provenance tracking).
    public func setItemOrigin(id: UUID, origin: String) {
        do {
            try store.setItemOrigin(id: id.uuidString, origin: origin)
        } catch {
            Logger.library.error("setItemOrigin failed: \(error)")
        }
    }

    /// Find an item by its canonical_id.
    public func findByCanonicalId(canonicalId: String) -> String? {
        do {
            return try store.findByCanonicalId(canonicalId: canonicalId)
        } catch {
            Logger.library.error("findByCanonicalId failed: \(error)")
            return nil
        }
    }

    /// List all assignments for a library.
    public func assignments(libraryID: UUID) -> [Assignment] {
        listAssignments().filter { $0.libraryID == libraryID }
    }

    /// List assignments whose `assigneeName` matches the provided
    /// `currentUserName`. Callers from the UI layer should pass
    /// `ImpressKit.CurrentDeviceAuthor.displayName ?? ""` — keeping
    /// the platform lookup out of the data layer (ADR-023 Rule 7).
    public func myAssignments(libraryID: UUID, currentUserName: String) -> [Assignment] {
        listAssignments().filter { $0.assigneeName == currentUserName }
    }

    /// Remove an assignment.
    public func removeAssignment(_ id: UUID) {
        deleteItem(id: id)
    }

    /// Get participant names for a library.
    public func participantNames(libraryID: UUID) -> [String] {
        // Derive participant names from activity records
        let records = listActivityRecords(libraryId: libraryID, limit: 500)
        let names = Set(records.compactMap { $0.actorDisplayName })
        return Array(names).sorted()
    }

    /// Suggest a publication to a participant.
    ///
    /// `assignedByName` is the human-readable author stamp for the
    /// assignment (typically `ImpressKit.CurrentDeviceAuthor.displayName`).
    /// Callers in the UI layer must pass it explicitly — ADR-023
    /// Rule 7 keeps the data layer free of platform lookups.
    public func suggestPublication(
        publicationID: UUID,
        to assigneeName: String,
        libraryID: UUID,
        assignedByName: String?,
        note: String? = nil,
        dueDate: Date? = nil
    ) throws {
        let dueDateTimestamp: Int64? = dueDate.map { Int64($0.timeIntervalSince1970 * 1000) }
        _ = createAssignment(
            publicationId: publicationID,
            assigneeName: assigneeName,
            assignedByName: assignedByName,
            note: note,
            dueDate: dueDateTimestamp
        )
    }
}

// MARK: - Artifact Operations

extension RustStoreAdapter {

    /// Create a new research artifact.
    @discardableResult
    public func createArtifact(
        type: ArtifactType,
        title: String,
        sourceURL: String? = nil,
        notes: String? = nil,
        artifactSubtype: String? = nil,
        fileName: String? = nil,
        fileHash: String? = nil,
        fileSize: Int64? = nil,
        fileMimeType: String? = nil,
        captureContext: String? = nil,
        originalAuthor: String? = nil,
        eventName: String? = nil,
        eventDate: String? = nil,
        tags: [String] = []
    ) -> ResearchArtifact? {
        do {
            let row = try store.createArtifact(
                schema: type.rawValue,
                title: title,
                sourceUrl: sourceURL,
                notes: notes,
                artifactSubtype: artifactSubtype,
                fileName: fileName,
                fileHash: fileHash,
                fileSize: fileSize,
                fileMimeType: fileMimeType,
                captureContext: captureContext,
                originalAuthor: originalAuthor,
                eventName: eventName,
                eventDate: eventDate,
                tags: tags
            )
            didMutate()
            Logger.library.infoCapture("Created artifact '\(title)' (\(type.displayName))", category: "artifacts")
            return ResearchArtifact(from: row)
        } catch {
            Logger.library.errorCapture("Failed to create artifact: \(error)", category: "artifacts")
            return nil
        }
    }

    /// Get a single artifact by ID.
    public func getArtifact(id: UUID) -> ResearchArtifact? {
        do {
            guard let row = try store.getArtifact(id: id.uuidString) else {
                return nil
            }
            return ResearchArtifact(from: row)
        } catch {
            Logger.library.errorCapture("Failed to get artifact \(id): \(error)", category: "artifacts")
            return nil
        }
    }

    /// List artifacts, optionally filtered by type.
    public func listArtifacts(
        type: ArtifactType? = nil,
        sort: String = "created",
        ascending: Bool = false,
        limit: UInt32? = nil,
        offset: UInt32? = nil
    ) -> [ResearchArtifact] {
        do {
            let rows = try store.listArtifacts(
                schemaFilter: type?.rawValue,
                sortField: sort,
                ascending: ascending,
                limit: limit,
                offset: offset
            )
            return rows.map { ResearchArtifact(from: $0) }
        } catch {
            Logger.library.errorCapture("Failed to list artifacts: \(error)", category: "artifacts")
            return []
        }
    }

    /// Search artifacts by text query.
    public func searchArtifacts(query: String, type: ArtifactType? = nil) -> [ResearchArtifact] {
        do {
            let rows = try store.searchArtifacts(
                query: query,
                schemaFilter: type?.rawValue
            )
            return rows.map { ResearchArtifact(from: $0) }
        } catch {
            Logger.library.errorCapture("Failed to search artifacts: \(error)", category: "artifacts")
            return []
        }
    }

    /// Update an artifact's fields.
    public func updateArtifact(
        id: UUID,
        title: String? = nil,
        sourceURL: String? = nil,
        notes: String? = nil,
        artifactSubtype: String? = nil,
        captureContext: String? = nil,
        originalAuthor: String? = nil,
        eventName: String? = nil,
        eventDate: String? = nil
    ) {
        do {
            let info = try store.updateArtifact(
                id: id.uuidString,
                title: title,
                sourceUrl: sourceURL,
                notes: notes,
                artifactSubtype: artifactSubtype,
                captureContext: captureContext,
                originalAuthor: originalAuthor,
                eventName: eventName,
                eventDate: eventDate
            )
            didMutate()
            UndoCoordinator.shared.registerUndo(info: info)
        } catch {
            Logger.library.errorCapture("Failed to update artifact \(id): \(error)", category: "artifacts")
        }
    }

    /// Delete an artifact.
    public func deleteArtifact(id: UUID) {
        do {
            try store.deleteArtifact(id: id.uuidString)
            didMutate()
            Logger.library.infoCapture("Deleted artifact \(id)", category: "artifacts")
        } catch {
            Logger.library.errorCapture("Failed to delete artifact \(id): \(error)", category: "artifacts")
        }
    }

    /// Link an artifact to a publication.
    public func linkArtifactToPublication(artifactID: UUID, publicationID: UUID) {
        do {
            let info = try store.linkArtifactToPublication(
                artifactId: artifactID.uuidString,
                publicationId: publicationID.uuidString
            )
            didMutate()
            UndoCoordinator.shared.registerUndo(info: info)
        } catch {
            Logger.library.errorCapture("Failed to link artifact: \(error)", category: "artifacts")
        }
    }

    /// Count all artifacts, optionally filtered by type.
    public func countArtifacts(type: ArtifactType? = nil) -> Int {
        StoreTimings.shared.measure("countArtifacts") {
            do {
                return Int(try store.countArtifacts(schemaFilter: type?.rawValue))
            } catch {
                return 0
            }
        }
    }

    /// Set read state on artifacts.
    public func setArtifactRead(ids: [UUID], read: Bool) {
        do {
            try store.setRead(ids: ids.map(\.uuidString), read: read)
            didMutate()
        } catch {
            Logger.library.errorCapture("Failed to set artifact read: \(error)", category: "artifacts")
        }
    }

    /// Set starred state on artifacts.
    public func setArtifactStarred(ids: [UUID], starred: Bool) {
        do {
            try store.setStarred(ids: ids.map(\.uuidString), starred: starred)
            didMutate()
        } catch {
            Logger.library.errorCapture("Failed to set artifact starred: \(error)", category: "artifacts")
        }
    }

    /// Add a tag to artifacts.
    public func addArtifactTag(ids: [UUID], tagPath: String) {
        do {
            try store.addTag(ids: ids.map(\.uuidString), tagPath: tagPath)
            didMutate()
        } catch {
            Logger.library.errorCapture("Failed to add artifact tag: \(error)", category: "artifacts")
        }
    }

    /// Remove a tag from artifacts.
    public func removeArtifactTag(ids: [UUID], tagPath: String) {
        do {
            try store.removeTag(ids: ids.map(\.uuidString), tagPath: tagPath)
            didMutate()
        } catch {
            Logger.library.errorCapture("Failed to remove artifact tag: \(error)", category: "artifacts")
        }
    }
}

// MARK: - Background (nonisolated) Read Methods

extension RustStoreAdapter {

    /// Batch find by identifiers — runs off the main thread via the thread-safe imbibStore handle.
    /// Returns all publications matching any of the given DOIs, arXiv IDs, or bibcodes in a single query.
    nonisolated public func findByIdentifiersBatchBackground(
        dois: [String],
        arxivIds: [String],
        bibcodes: [String]
    ) -> [PublicationRowData] {
        StoreTimings.shared.measure("findByIdentifiersBatchBackground") {
            do {
                let rows = try imbibStore.findByIdentifiersBatch(
                    dois: dois,
                    arxivIds: arxivIds,
                    bibcodes: bibcodes
                )
                return rows.compactMap { PublicationRowData(from: $0) }
            } catch {
                return []
            }
        }
    }

    /// Check if a paper has been dismissed — runs off the main thread.
    nonisolated public func isPaperDismissedBackground(
        doi: String? = nil,
        arxivId: String? = nil,
        bibcode: String? = nil,
        citeKey: String? = nil
    ) -> Bool {
        do {
            return try imbibStore.isPaperDismissed(doi: doi, arxivId: arxivId, bibcode: bibcode, citeKey: citeKey)
        } catch {
            return false
        }
    }

    /// Find by cite key — runs off the main thread.
    nonisolated public func findByCiteKeyBackground(
        citeKey: String,
        libraryId: UUID? = nil
    ) -> PublicationRowData? {
        do {
            guard let row = try imbibStore.findByCiteKey(citeKey: citeKey, libraryId: libraryId?.uuidString) else { return nil }
            return PublicationRowData(from: row)
        } catch {
            return nil
        }
    }

    // MARK: - Background Mutation Methods (for SmartSearchProvider)

    /// Batch import search results off the main thread. Skips undo and notification posting.
    /// Caller is responsible for posting mutation notifications via `notifyMutationFromBackground()`.
    nonisolated public func batchImportSearchResultsBackground(
        bibtexEntries: [(bibtex: String, doi: String?, arxivId: String?, bibcode: String?)],
        libraryId: UUID,
        filterDismissed: Bool = false
    ) -> (existingIDs: [UUID], importedIDs: [UUID]) {
        let inputs = bibtexEntries.map {
            SearchResultInput(bibtex: $0.bibtex, doi: $0.doi, arxivId: $0.arxivId, bibcode: $0.bibcode)
        }
        do {
            let result = try imbibStore.batchImportSearchResults(
                results: inputs,
                libraryId: libraryId.uuidString,
                filterDismissed: filterDismissed
            )
            let existingUUIDs = result.existingIds.compactMap { UUID(uuidString: $0) }
            let importedUUIDs = result.importedIds.compactMap { UUID(uuidString: $0) }
            return (existingUUIDs, importedUUIDs)
        } catch {
            return ([], [])
        }
    }

    /// Import BibTeX string off the main thread. Skips undo and notification posting.
    nonisolated public func importBibTeXBackground(_ bibtex: String, libraryId: UUID) -> [UUID] {
        do {
            let ids = try imbibStore.importBibtex(bibtex: bibtex, libraryId: libraryId.uuidString)
            return ids.compactMap { UUID(uuidString: $0) }
        } catch {
            return []
        }
    }

    /// Add publications to a collection off the main thread. Skips undo and notification posting.
    nonisolated public func addToCollectionBackground(publicationIds: [UUID], collectionId: UUID) {
        do {
            _ = try imbibStore.addToCollection(publicationIds: publicationIds.map(\.uuidString), collectionId: collectionId.uuidString)
        } catch {
            // Logged at call site if needed
        }
    }

    /// Duplicate publications to a library off the main thread. Skips undo and notification posting.
    nonisolated public func duplicatePublicationsBackground(ids: [UUID], toLibraryId: UUID) -> [UUID] {
        do {
            let newIds = try imbibStore.duplicatePublications(ids: ids.map(\.uuidString), toLibraryId: toLibraryId.uuidString)
            return newIds.compactMap { UUID(uuidString: $0) }
        } catch {
            return []
        }
    }

    /// Set read status off the main thread. Skips undo and notification posting.
    nonisolated public func setReadBackground(ids: [UUID], read: Bool) {
        do {
            _ = try imbibStore.setRead(ids: ids.map(\.uuidString), read: read)
        } catch {
            // Logged at call site if needed
        }
    }

    /// Query publication IDs in a parent container off the main thread.
    nonisolated public func queryPublicationIDsBackground(parentId: UUID) -> Set<UUID> {
        do {
            let ids = try imbibStore.queryPublicationIds(parentId: parentId.uuidString)
            return Set(ids.compactMap { UUID(uuidString: $0) })
        } catch {
            return []
        }
    }

    /// Get the inbox library off the main thread.
    nonisolated public func getInboxLibraryBackground() -> LibraryModel? {
        do {
            guard let row = try imbibStore.getInboxLibrary() else { return nil }
            return LibraryModel(from: row)
        } catch {
            return nil
        }
    }

    /// Get a smart search by ID off the main thread.
    nonisolated public func getSmartSearchBackground(id: UUID) -> SmartSearch? {
        do {
            guard let row = try imbibStore.getSmartSearch(id: id.uuidString) else { return nil }
            return SmartSearch(from: row)
        } catch {
            return nil
        }
    }

    /// Reparent an item off the main thread. Skips undo and notification posting.
    nonisolated public func reparentItemBackground(id: UUID, newParentId: UUID) {
        do {
            try imbibStore.reparentItem(id: id.uuidString, newParentId: newParentId.uuidString)
        } catch {
            // Logged at call site if needed
        }
    }

    /// List all libraries off the main thread.
    nonisolated public func listLibrariesBackground() -> [LibraryModel] {
        do {
            return try imbibStore.listLibraries().map { LibraryModel(from: $0) }
        } catch {
            return []
        }
    }

    /// Query publications in a parent container off the main thread.
    nonisolated public func queryPublicationsBackground(parentId: UUID) -> [PublicationRowData] {
        do {
            let rows = try imbibStore.queryPublications(
                parentId: parentId.uuidString,
                sortField: "dateAdded",
                ascending: false,
                limit: nil,
                offset: nil
            )
            return rows.compactMap { PublicationRowData(from: $0) }
        } catch {
            return []
        }
    }

    /// List collections for a library off the main thread.
    nonisolated public func listCollectionsBackground(libraryId: UUID) -> [CollectionModel] {
        do {
            return try imbibStore.listCollections(libraryId: libraryId.uuidString).map { CollectionModel(from: $0) }
        } catch {
            return []
        }
    }

    /// List collection members off the main thread.
    nonisolated public func listCollectionMembersBackground(collectionId: UUID) -> [PublicationRowData] {
        do {
            let rows = try imbibStore.listCollectionMembers(
                collectionId: collectionId.uuidString,
                sortField: "dateAdded",
                ascending: false,
                limit: nil,
                offset: nil
            )
            return rows.compactMap { PublicationRowData(from: $0) }
        } catch {
            return []
        }
    }

    /// List SciX libraries off the main thread.
    nonisolated public func listScixLibrariesBackground() -> [SciXLibrary] {
        do {
            return try imbibStore.listScixLibraries().map { SciXLibrary(from: $0) }
        } catch {
            return []
        }
    }

    /// List SciX library members off the main thread.
    nonisolated public func listScixLibraryMembersBackground(scixLibraryId: UUID) -> [PublicationRowData] {
        do {
            let rows = try imbibStore.queryScixLibraryPublications(
                scixLibraryId: scixLibraryId.uuidString,
                sortField: "dateAdded",
                ascending: false,
                limit: nil,
                offset: nil
            )
            return rows.compactMap { PublicationRowData(from: $0) }
        } catch {
            return []
        }
    }

    /// Get a single publication off the main thread.
    nonisolated public func getPublicationBackground(id: UUID) -> PublicationRowData? {
        do {
            guard let row = try imbibStore.getPublication(id: id.uuidString) else { return nil }
            return PublicationRowData(from: row)
        } catch {
            return nil
        }
    }

    /// Deduplicate a library off the main thread. Skips didMutate/notifications.
    nonisolated public func deduplicateLibraryBackground(id: UUID) -> Int {
        do {
            return Int(try imbibStore.deduplicateLibrary(libraryId: id.uuidString))
        } catch {
            return 0
        }
    }

    /// List tag definitions with publication counts off the main thread.
    nonisolated public func listTagsWithCountsBackground() -> [TagDefinition] {
        StoreTimings.shared.measure("listTagsWithCountsBackground") {
            do {
                return try imbibStore.listTagsWithCounts().map { TagDefinition(from: $0) }
            } catch {
                return []
            }
        }
    }

    /// Count unread publications in a collection off the main thread (Contains-edge join).
    nonisolated public func countUnreadInCollectionBackground(collectionId: UUID) -> Int {
        StoreTimings.shared.measure("countUnreadInCollectionBackground") {
            do {
                return Int(try imbibStore.countUnreadInCollection(collectionId: collectionId.uuidString))
            } catch {
                return 0
            }
        }
    }

    /// Bump dataVersion and post a single storeDidMutate notification from background work.
    /// Must be called on @MainActor after all background mutations are complete.
    @MainActor public func notifyMutationFromBackground() {
        dataVersion += 1
        ImbibImpressStore.shared.postMutation(structural: true)
    }
}

// MARK: - PublicationRowData Extension

nonisolated extension PublicationRowData {

    /// Initialize from Rust-shaped BibliographyRow — direct field mapping, no Core Data.
    public init?(from row: BibliographyRow) {
        guard let id = UUID(uuidString: row.id) else {
            return nil
        }

        self.id = id
        self.citeKey = row.citeKey
        self.title = row.title.isEmpty ? "Untitled" : row.title
        self.authorString = row.authorString.isEmpty ? "Unknown Author" : row.authorString
        self.year = row.year.map { Int($0) }
        self.abstract = row.abstractText
        self.isRead = row.isRead
        self.isStarred = row.isStarred

        // Map flag from Rust strings to PublicationFlag
        if let colorName = row.flagColor,
           let flagColor = FlagColor(rawValue: colorName) {
            let flagStyle = row.flagStyle.flatMap { FlagStyle(rawValue: $0) } ?? .solid
            let flagLength = row.flagLength.flatMap { FlagLength(rawValue: $0) } ?? .full
            self.flag = PublicationFlag(color: flagColor, style: flagStyle, length: flagLength)
        } else {
            self.flag = nil
        }

        self.hasDownloadedPDF = row.hasDownloadedPdf
        self.hasOtherAttachments = row.hasOtherAttachments
        self.citationCount = Int(row.citationCount)
        self.referenceCount = Int(row.referenceCount)
        self.doi = row.doi
        self.arxivID = row.arxivId
        self.bibcode = row.bibcode
        self.venue = row.venue
        self.note = row.note
        self.dateAdded = Date(timeIntervalSince1970: TimeInterval(row.dateAdded) / 1000.0)
        self.dateModified = Date(timeIntervalSince1970: TimeInterval(row.dateModified) / 1000.0)
        self.primaryCategory = row.primaryCategory
        self.categories = row.categories

        // Map tags from Rust TagDisplayRow to Swift TagDisplayData
        self.tagDisplays = row.tags.map { tag in
            TagDisplayData(
                id: UUID(),
                path: tag.path,
                leaf: tag.leafName,
                colorLight: tag.colorLight,
                colorDark: tag.colorDark
            )
        }

        self.enrichmentDate = row.enrichmentDate
        self.libraryName = row.libraryName
    }
}
