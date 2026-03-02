import CryptoKit
import Foundation

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

    /// Filesystem path to the shared SQLite database (informational).
    ///
    /// Uses the `group.com.impress.suite` App Group container when available,
    /// falling back to a temp directory in non-sandboxed / test environments.
    public var databasePath: String {
        let groupID = "group.com.impress.suite"
        let root = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupID)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("com.impress.suite-dev")
        return root.appendingPathComponent("implore-store.sqlite").path
    }

    /// Content-addressed storage directory for binary assets.
    public var contentStoreDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/impress/content")
    }

    private init() {
        setup()
    }

    // MARK: - Initialisation

    private func setup() {
        do {
            try FileManager.default.createDirectory(
                at: contentStoreDirectory,
                withIntermediateDirectories: true
            )
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

        // TODO: Call impress-core UniFFI to upsert a "figure@1.0.0" item.
        // Payload keys: format, title, caption, data_hash, script_hash
        // Schema: "figure"  version: "1.0.0"
        // Example (once XCFramework is available):
        //
        //   let payload: [String: String?] = [
        //       "format": format,
        //       "title": title,
        //       "caption": caption,
        //       "data_hash": dataHash,
        //       "script_hash": scriptHash,
        //   ]
        //   ImpressCoreStore.shared.upsert(id: figureID, schema: "figure", payload: payload)
        _ = dataHash

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

        // TODO: Call impress-core UniFFI to upsert a "dataset@1.0.0" item.
        // Payload keys: name, format, row_count, column_count, data_hash, description
        // Schema: "dataset"  version: "1.0.0"
        _ = dataHash

        didMutate()
    }

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
