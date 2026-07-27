import CryptoKit
import Foundation
import ImpressKit
import OSLog
#if canImport(ImpressRustCore)
import ImpressRustCore
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

    /// Bumped on every mutation. Views can observe this to trigger updates.
    public private(set) var dataVersion: Int = 0

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
    private var store: SharedStore?
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
            store = try SharedStore.open(path: databasePath)
            #endif
            isReady = true
        } catch {
            isReady = false
        }
    }

    // MARK: - Mutation Tracking

    /// Call after every successful mutation to bump `dataVersion`.
    public func didMutate() {
        dataVersion += 1
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

        let figurePayload: [String: Any?] = [
            "format": format,
            "title": title,
            "caption": caption,
            "data_hash": dataHash,
            "script_hash": scriptHash
        ]
        let compactedFigure = figurePayload.compactMapValues { $0 }
        if let payloadJSON = try? JSONSerialization.data(withJSONObject: compactedFigure),
           let payloadString = String(data: payloadJSON, encoding: .utf8) {
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

        let datasetPayload: [String: Any?] = [
            "name": name,
            "format": format,
            "row_count": rowCount,
            "column_count": columnCount,
            "data_hash": dataHash,
            "description": description
        ]
        let compactedDataset = datasetPayload.compactMapValues { $0 }
        if let payloadJSON = try? JSONSerialization.data(withJSONObject: compactedDataset),
           let payloadString = String(data: payloadJSON, encoding: .utf8) {
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
        var rows: [SharedItemUpsert] = []
        for f in folders {
            let payload: [String: Any] = [
                "name": f.name, "sort_order": f.sortOrder, "is_collapsed": f.isCollapsed,
            ]
            guard let json = try? JSONSerialization.data(withJSONObject: payload),
                  let jsonString = String(data: json, encoding: .utf8) else { continue }
            rows.append(SharedItemUpsert(
                id: f.id.lowercased(), schemaRef: "figure-collection",
                payloadJson: jsonString, parentId: nil, tags: [],
                createdMs: nil, isRead: nil, isStarred: nil))
        }
        for f in figures {
            let payload: [String: Any] = ["title": f.title, "format": f.format]
            guard let json = try? JSONSerialization.data(withJSONObject: payload),
                  let jsonString = String(data: json, encoding: .utf8) else { continue }
            rows.append(SharedItemUpsert(
                id: f.id.lowercased(), schemaRef: "figure",
                payloadJson: jsonString,
                parentId: f.folderID?.lowercased(), tags: [],
                createdMs: nil, isRead: nil, isStarred: nil))
        }
        do {
            let result = try store.upsertItems(rows: rows)
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
    /// All figure folders (store-native read path).
    public func fetchFolders() -> [SharedItemRow] {
        guard isReady, let store else { return [] }
        return (try? store.queryItems(query: SharedItemQuery(
            schemaRef: "figure-collection", parentId: nil, payloadEq: [],
            modifiedAfterMs: nil, sortField: "payload.sort_order",
            ascending: true, limit: 1000, offset: 0))) ?? []
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
    public func setFigureFolder(figureID: String, folderID: String?) {
        guard isReady, let store else { return }
        try? store.setParent(id: figureID.lowercased(), parentId: folderID?.lowercased())
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
