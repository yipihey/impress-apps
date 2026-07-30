import CryptoKit
import Foundation
import ImpressKit
import ImpressStoreKit
import OSLog
#if canImport(ImpressRustCore)
import ImpressRustCore
#endif

#if canImport(ImpressRustCore)
// MARK: - SharedStore backend

/// The mechanical bridge from the generic mirror kernel to the UniFFI store.
/// Field-for-field; no logic. (impart has the same twelve lines next to its own
/// guarded FFI import — see the note in `StoreMirrorKernel.swift` for why this
/// cannot live in ImpressStoreKit: the XCFramework is a local build artefact and
/// the kernel's own tests must run without it.)
private struct SharedStoreMirrorBackend: StoreMirrorBackend, @unchecked Sendable {
    let store: SharedStore

    func upsertBatch(_ rows: [StoreMirrorUpsert]) throws -> StoreMirrorBatchOutcome {
        let result = try store.upsertItems(rows: rows.map(\.sharedItemUpsert))
        return StoreMirrorBatchOutcome(
            inserted: Int(result.inserted),
            updated: Int(result.updated)
        )
    }

    func upsertOne(_ row: StoreMirrorUpsert) throws {
        try store.upsertItemV2(row: row.sharedItemUpsert)
    }

    func setRead(id: String, isRead: Bool) throws {
        try store.setRead(id: id, isRead: isRead)
    }

    func setParent(id: String, parentId: String?) throws {
        try store.setParent(id: id, parentId: parentId)
    }
}

extension StoreMirrorUpsert {
    /// Convert to the FFI row type at the write site.
    var sharedItemUpsert: SharedItemUpsert {
        SharedItemUpsert(
            id: id,
            schemaRef: schemaRef,
            payloadJson: payloadJson,
            parentId: parentId,
            tags: tags,
            createdMs: createdMs,
            isRead: isRead,
            isStarred: isStarred
        )
    }
}
#endif

/// Stores implore figures and datasets in the shared impress-core store.
///
/// Binary assets (SVG, PNG, PDF, CSV) are stored content-addressed at
/// `~/.local/share/impress/content/{sha256}` with the hash recorded in the
/// item payload so they can be resolved across apps.
///
/// This adapter is scaffolding for Phase 1 of the unified item protocol
/// integration. The TODO comments mark where UniFFI calls to impress-core
/// will be wired once the XCFramework is built for implore.
@MainActor
@Observable
public final class ImploreStoreAdapter {

    /// Shared singleton instance.
    public static let shared = ImploreStoreAdapter()

    /// The shared mutation signal (`ImpressStoreKit`) — one copy of "bump a
    /// version, fan out a typed event" instead of one per store adapter.
    /// implore has no store gateway to fan out to yet, so it uses the counter
    /// half only; wiring `emit:` is all it takes when it grows one.
    private let signal = StoreMutationSignal()

    /// Bumped on every mutation. Views can observe this to trigger updates.
    ///
    /// Reads through to `signal.version`. `StoreMutationSignal` is itself
    /// `@Observable`, so a SwiftUI `body` touching `dataVersion` registers the
    /// same dependency it did when the counter was stored here.
    public var dataVersion: Int { signal.version }

    /// Whether the adapter has successfully initialised its storage directories.
    public private(set) var isReady = false

    /// Filesystem path to the shared SQLite database.
    ///
    /// All impress apps share this path via `SharedWorkspace`.
    public var databasePath: String {
        SharedWorkspace.databasePath
    }

    /// Content-addressed storage directory for binary assets.
    public var contentStoreDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/impress/content")
    }

    // MARK: - Shared Store

    #if canImport(ImpressRustCore)
    /// The store handle: `ImpressStoreKit`'s `LazyStoreHandle` — opened at most
    /// once, under a lock, failure remembered rather than retried. `setup()`
    /// forces the open eagerly so `isReady` keeps meaning what it always meant
    /// (the adapter is usable *now*), which the `guard isReady` at the head of
    /// every write depends on.
    private let handle = LazyStoreHandle<SharedStore> {
        try SharedWorkspace.ensureDirectoryExists()
        return try SharedStore.open(path: SharedWorkspace.databasePath)
    }

    /// The current store handle, or `nil` if it never opened.
    private var store: SharedStore? { handle.get() }
    #endif

    private init() {
        setup()
    }

    // MARK: - Initialisation

    private func setup() {
        do {
            try SharedWorkspace.ensureDirectoryExists()
            try FileManager.default.createDirectory(
                at: contentStoreDirectory,
                withIntermediateDirectories: true
            )
            #if canImport(ImpressRustCore)
            // Force the lazy open here: `isReady` promises the store is
            // available, not merely openable.
            isReady = handle.isReady
            #else
            isReady = true
            #endif
        } catch {
            isReady = false
        }
    }

    // MARK: - Mutation Tracking

    /// Call after every successful mutation to bump `dataVersion`.
    public func didMutate() {
        signal.didMutate()
    }

    // MARK: - Figure Storage

    /// Store a figure in the shared impress-core store.
    ///
    /// If `assetData` is provided, writes it to content-addressed storage and
    /// records the SHA-256 hex hash as `data_hash` in the item payload.
    ///
    /// - Parameters:
    ///   - figureID:     Stable identifier for this figure (e.g. `LibraryFigure.id`).
    ///   - format:       File format string — "svg", "png", "pdf", "typst".
    ///   - title:        Human-readable title for the figure.
    ///   - caption:      Optional figure caption / description.
    ///   - assetData:    Raw bytes of the rendered figure asset.
    ///   - scriptHash:   SHA-256 of the generator script, for reproducibility tracking.
    public func storeFigure(
        figureID: String,
        format: String,
        title: String?,
        caption: String?,
        assetData: Data?,
        scriptHash: String?
    ) {
        guard isReady else { return }

        let dataHash: String? = assetData.map { storeContentAddressed(data: $0) }

        // `StoreMirrorPayload` drops the nil entries and sorts the keys —
        // sorted keys keep a re-upsert of an unchanged figure byte-identical,
        // so it does not churn the row's `modified` timestamp.
        if let payloadString = StoreMirrorPayload.encodeJSONIfValid([
            "format": format,
            "title": title,
            "caption": caption,
            "data_hash": dataHash,
            "script_hash": scriptHash
        ] as [String: Any?]) {
            #if canImport(ImpressRustCore)
            try? store?.upsertItem(id: figureID, schemaRef: "figure", payloadJson: payloadString)
            #endif
        }

        didMutate()
    }

    // MARK: - Dataset Storage

    /// Store a dataset in the shared impress-core store.
    ///
    /// If `data` is provided, writes it content-addressed and records the hash.
    ///
    /// - Parameters:
    ///   - datasetID:     Stable identifier for this dataset.
    ///   - name:          Human-readable dataset name.
    ///   - format:        File format — "csv", "parquet", "hdf5", "fits", "generated".
    ///   - rowCount:      Number of rows, if known.
    ///   - columnCount:   Number of columns / fields, if known.
    ///   - data:          Raw bytes of the dataset file (optional; large files may be skipped).
    ///   - description:   Optional free-text description of the dataset.
    public func storeDataset(
        datasetID: String,
        name: String,
        format: String,
        rowCount: Int?,
        columnCount: Int?,
        data: Data?,
        description: String?
    ) {
        guard isReady else { return }

        let dataHash: String? = data.map { storeContentAddressed(data: $0) }

        if let payloadString = StoreMirrorPayload.encodeJSONIfValid([
            "name": name,
            "format": format,
            "row_count": rowCount,
            "column_count": columnCount,
            "data_hash": dataHash,
            "description": description
        ] as [String: Any?]) {
            #if canImport(ImpressRustCore)
            try? store?.upsertItem(id: datasetID, schemaRef: "dataset", payloadJson: payloadString)
            #endif
        }

        didMutate()
    }

    // MARK: - Stage 0: library backfill + store reads

    /// Watermark key marking the one-time JSON-library → store backfill.
    public static let backfillKey = "implore.libraryImported"

    /// Transfer rows so this package stays decoupled from ImploreRustCore's
    /// FigureLibrary types (the app maps its models into these).
    public struct FolderBackfillRow: Sendable {
        public let id: String
        public let name: String
        public let sortOrder: Int
        public let isCollapsed: Bool
        public init(id: String, name: String, sortOrder: Int, isCollapsed: Bool) {
            self.id = id
            self.name = name
            self.sortOrder = sortOrder
            self.isCollapsed = isCollapsed
        }
    }

    public struct FigureBackfillRow: Sendable {
        public let id: String
        public let title: String
        public let folderID: String?
        public let format: String
        public init(id: String, title: String, folderID: String?, format: String) {
            self.id = id
            self.title = title
            self.folderID = folderID
            self.format = format
        }
    }

    /// One-time backfill of the JSON library into the store: folders become
    /// `figure-collection` items, figures carry their folder as envelope
    /// `parent`. Idempotent (deterministic ids; watermark in sync_metadata).
    /// The JSON file remains the shadow export until the read flag flips.
    @discardableResult
    public func migrateLibraryIfNeeded(
        folders: [FolderBackfillRow],
        figures: [FigureBackfillRow]
    ) -> Bool {
        #if canImport(ImpressRustCore)
        guard isReady, let store else { return false }
        if (try? store.syncMetadataGet(key: Self.backfillKey)) ?? nil != nil {
            return false
        }
        // Rows are the shared mirror-kernel row type; the folder rows come
        // first so every figure's envelope parent already exists.
        var rows: [StoreMirrorUpsert] = []
        for f in folders {
            guard let jsonString = StoreMirrorPayload.encodeJSONIfValid([
                "name": f.name, "sort_order": f.sortOrder, "is_collapsed": f.isCollapsed,
            ]) else { continue }
            rows.append(StoreMirrorUpsert(
                id: f.id.lowercased(),
                schemaRef: "figure-collection",
                payloadJson: jsonString))
        }
        for f in figures {
            guard let jsonString = StoreMirrorPayload.encodeJSONIfValid([
                "title": f.title, "format": f.format,
            ]) else { continue }
            rows.append(StoreMirrorUpsert(
                id: f.id.lowercased(),
                schemaRef: "figure",
                payloadJson: jsonString,
                parentId: f.folderID?.lowercased()))
        }
        do {
            let result = try SharedStoreMirrorBackend(store: store).upsertBatch(rows)
            try store.syncMetadataSet(
                key: Self.backfillKey,
                value: ISO8601DateFormatter().string(from: Date()))
            didMutate()
            Logger(subsystem: "com.impress.implore", category: "library").info(
                "backfill: \(result.inserted) inserted, \(result.updated) updated (\(folders.count) folders, \(figures.count) figures)")
            return true
        } catch {
            Logger(subsystem: "com.impress.implore", category: "library")
                .error("backfill failed: \(error)")
            return false
        }
        #else
        return false
        #endif
    }

    #if canImport(ImpressRustCore)
    /// All figure folders (store-native read path), ordered by `sort_order`.
    ///
    /// Reads through the ADR-0022 collection kernel, not a `schemaRef:
    /// "figure-collection"` literal (F3). The literal is the spelling
    /// `collection_migration` rewrites away, so this returned NOTHING once the
    /// `collections.unified` marker went on — the folders were all still there.
    /// `collectionTree` resolves the marker per call and answers identically on
    /// both sides of the flip, and its row already carries the tree parent the
    /// way the binding defines it (post-flip a figure folder nests through
    /// payload `parent_id`, mirrored from the envelope the migration leaves
    /// alone).
    ///
    /// The one-time `migrateLibraryIfNeeded` backfill above still WRITES
    /// `figure-collection` rows, and deliberately so: it is watermarked in
    /// `sync_metadata`, runs at most once per store, and its rows are exactly
    /// the shape this read expects pre-flip — so rows it has ALREADY written are
    /// converged by the G7 migration like any other legacy row. The residual
    /// case is narrow and named rather than fixed: a store flipped BEFORE the
    /// backfill has ever run would take one `figure-collection` batch the kernel
    /// cannot see, recoverable with a second `migrate_collections` (idempotent,
    /// `skipped_already_generic`). Converging the backfill itself means routing
    /// a bulk mirror upsert through per-row kernel creates, which is implore's
    /// Stage-1 work, not a marker fix.
    public func fetchFolders() -> [SharedCollectionRow] {
        guard isReady, let store else { return [] }
        return (try? store.collectionTree(binding: .figure)) ?? []
    }

    /// Figures, optionally scoped to one folder; `nil` returns ALL figures
    /// (filter `parentId == nil` client-side for Unfiled).
    public func fetchFigures(inFolder folderID: String? = nil) -> [SharedItemRow] {
        guard isReady, let store else { return [] }
        return (try? store.queryItems(query: SharedItemQuery(
            schemaRef: "figure", parentId: folderID?.lowercased(), payloadEq: [],
            modifiedAfterMs: nil, sortField: "modified",
            ascending: false, limit: 5000, offset: 0))) ?? []
    }

    /// Folder moves on the store mirror (Stage 0 keeps JSON authoritative for
    /// the GUI; this keeps the mirror consistent for other apps).
    ///
    /// The envelope write goes through the shared `StoreMirrorBackend` verb, so
    /// implore reparents rows through the same seam as every other mirror.
    public func setFigureFolder(figureID: String, folderID: String?) {
        guard isReady, let store else { return }
        try? SharedStoreMirrorBackend(store: store).setParent(
            id: figureID.lowercased(),
            parentId: folderID?.lowercased()
        )
        didMutate()
    }
    #endif

    // MARK: - Content-Addressed Storage

    /// Write `data` to the content store under its SHA-256 hex name.
    ///
    /// Skips the write if the file already exists (idempotent).
    ///
    /// - Returns: SHA-256 hex string that can be used as `data_hash`.
    @discardableResult
    private func storeContentAddressed(data: Data) -> String {
        let hash = SHA256.hash(data: data)
        let hashString = hash.compactMap { String(format: "%02x", $0) }.joined()
        let fileURL = contentStoreDirectory.appendingPathComponent(hashString)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? data.write(to: fileURL, options: .atomic)
        }
        return hashString
    }
}
