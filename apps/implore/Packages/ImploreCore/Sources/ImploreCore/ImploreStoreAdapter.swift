import CryptoKit
import Foundation
import ImploreRustCore
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
/// Binary assets are stored content-addressed in the workspace's one blob
/// store, `<workspace>/content/{sha256}` (ADR-0030 D3), with the hash
/// recorded in the item payload so every app resolves the same bytes. (They
/// used to go to `~/.local/share/impress/content`, which inside the sandbox
/// is implore's CONTAINER home: no other app could ever read them.)
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

    /// The workspace directory: the database's parent. Rust derives
    /// `content/` and `exports/figures/` from it, exactly as the store does.
    public var workspaceDirectory: URL {
        URL(fileURLWithPath: databasePath).deletingLastPathComponent()
    }

    /// Content-addressed storage directory for binary assets: the store's
    /// own blob root, so readers asking the store find the same files.
    public var contentStoreDirectory: URL {
        #if canImport(ImpressRustCore)
        if let root = store?.manuscriptProjectBlobRoot() {
            return URL(fileURLWithPath: root, isDirectory: true)
        }
        #endif
        return workspaceDirectory.appendingPathComponent("content", isDirectory: true)
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

    /// What a figure write did, for the caller's three-point trace.
    public struct FigureWrite: Sendable {
        /// The rendered artifact, or nil when rendering failed (the row is
        /// still written, keeping whatever `data_hash` it had).
        public let artifact: StoredFigureArtifact?
        /// Why rendering failed, if it did.
        public let renderError: String?
        /// Whether the row upsert succeeded.
        public let saved: Bool
        /// The previous artifact's hash, when an edit replaced it and no
        /// other row still named it (so its blob was removed).
        public let releasedHash: String?
    }

    /// THE figure write: render the figure's artifact, store it, and upsert
    /// the `figure` row with `data_hash` pointing at it.
    ///
    /// Every writer goes through here — `POST`/`PATCH /api/figures`, the
    /// `create-figure` verb (which reaches implore over HTTP), and implore's
    /// own "Save as Figure" — so a figure is never stored without the image
    /// other apps draw. What the image IS is decided in Rust
    /// (`implore_core::figure_artifact`); this maps the answer into the row.
    ///
    /// - Parameters:
    ///   - figureID:      Stable identifier (`LibraryFigure.id`).
    ///   - title:         Human-readable title for the figure.
    ///   - caption:       Optional caption.
    ///   - viewStateJSON: The figure's `viewStateSnapshot`: type, columns,
    ///                    size, and optional `series`/`spec`/`svg` data.
    ///   - scriptHash:    SHA-256 of the generator script, if any.
    @discardableResult
    public func storeFigure(
        figureID: String,
        title: String?,
        caption: String?,
        viewStateJSON: String,
        scriptHash: String? = nil
    ) -> FigureWrite {
        guard isReady else {
            return FigureWrite(
                artifact: nil, renderError: "store not ready", saved: false, releasedHash: nil)
        }

        var artifact: StoredFigureArtifact?
        var renderError: String?
        do {
            artifact = try storeFigureArtifact(
                workspaceDir: workspaceDirectory.path,
                viewStateJson: viewStateJSON
            )
        } catch {
            renderError = "\(error)"
        }

        // `StoreMirrorPayload` drops the nil entries and sorts the keys —
        // sorted keys keep a re-upsert of an unchanged figure byte-identical,
        // so it does not churn the row's `modified` timestamp. The upsert is
        // additive per field, so a failed render leaves the old artifact.
        let previousHash = figureDataHash(figureID: figureID)
        var saved = false
        if let payloadString = StoreMirrorPayload.encodeJSONIfValid([
            "format": artifact?.format ?? "png",
            "title": title,
            "caption": caption,
            "data_hash": artifact?.dataHash,
            "width": artifact.map { Int($0.width) },
            "height": artifact.map { Int($0.height) },
            "script_hash": scriptHash
        ] as [String: Any?]) {
            #if canImport(ImpressRustCore)
            saved = (try? store?.upsertItem(
                id: figureID, schemaRef: "figure", payloadJson: payloadString)) != nil
            #endif
        }

        // An edit is a new artifact: let the old bytes go unless another row
        // (another figure, a manuscript) still names them.
        var releasedHash: String?
        #if canImport(ImpressRustCore)
        if saved, let old = previousHash, let new = artifact?.dataHash, old != new,
           (try? store?.releaseBlob(hash: old)) == true {
            releasedHash = old
        }
        #endif

        didMutate()
        return FigureWrite(
            artifact: artifact, renderError: renderError, saved: saved, releasedHash: releasedHash)
    }

    /// The `data_hash` a figure row carries now, if any.
    public func figureDataHash(figureID: String) -> String? {
        #if canImport(ImpressRustCore)
        guard isReady, let store,
              let row = try? store.getItem(id: figureID.lowercased()),
              let payload = try? JSONSerialization.jsonObject(
                  with: Data(row.payloadJson.utf8)) as? [String: Any]
        else { return nil }
        return payload["data_hash"] as? String
        #else
        return nil
        #endif
    }

    /// Export a figure to `<workspace>/exports/figures/<id>.<png|svg>`,
    /// rendered by the same Rust path as the stored artifact (a default PNG
    /// export is byte-for-byte the blob under `data_hash`).
    public func exportFigure(
        figureID: String,
        viewStateJSON: String,
        format: String,
        width: Double? = nil,
        height: Double? = nil,
        scale: Double? = nil
    ) throws -> ExportedFigure {
        try exportFigureArtifact(
            workspaceDir: workspaceDirectory.path,
            figureId: figureID,
            viewStateJson: viewStateJSON,
            format: format,
            width: width,
            height: height,
            scale: scale
        )
    }

    /// What deleting a figure removed, for the caller's trace.
    public struct FigureDeletion: Sendable {
        public let rowDeleted: Bool
        /// The artifact's hash, if the row had one.
        public let dataHash: String?
        /// Whether the blob went (false when another row still names it).
        public let blobReleased: Bool
        public let exportsRemoved: Int
    }

    /// Delete a figure's store row, then its artifact blob unless another
    /// row still references it, then its exported files.
    @discardableResult
    public func deleteFigure(figureID: String) -> FigureDeletion {
        let dataHash = figureDataHash(figureID: figureID)
        var rowDeleted = false
        var blobReleased = false
        #if canImport(ImpressRustCore)
        if isReady, let store {
            let id = figureID.lowercased()
            rowDeleted = (try? store.deleteItem(id: id)) != nil
            if rowDeleted, let hash = dataHash {
                blobReleased = (try? store.releaseBlob(hash: hash)) ?? false
            }
        }
        #endif
        let exportsRemoved = (try? removeFigureExports(
            workspaceDir: workspaceDirectory.path, figureId: figureID)).map(Int.init) ?? 0
        if rowDeleted { didMutate() }
        return FigureDeletion(
            rowDeleted: rowDeleted, dataHash: dataHash,
            blobReleased: blobReleased, exportsRemoved: exportsRemoved)
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
