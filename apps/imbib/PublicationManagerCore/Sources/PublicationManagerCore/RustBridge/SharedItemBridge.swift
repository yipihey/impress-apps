//
//  SharedItemBridge.swift
//  PublicationManagerCore
//
//  Mirrors imbib publications into the shared impress-core store as
//  `bibliography-entry@1.0.0` items for cross-app visibility.
//

import Foundation
import ImpressKit
import OSLog
#if canImport(ImpressRustCore)
import ImpressRustCore
#endif

// MARK: - SharedItemBridge

/// Mirrors imbib publications into the shared impress-core store as
/// `bibliography-entry@1.0.0` items for cross-app visibility.
///
/// This is a write-through bridge: imbib-core remains authoritative for
/// publication data; the shared store receives a copy for search/discoverability.
///
/// ## Design
///
/// The bridge is intentionally thin — it establishes the call-site pattern and
/// directory layout for the shared impress-core store without coupling imbib to
/// a specific impress-core UniFFI ABI version. The actual `SqliteItemStore` FFI
/// calls are marked `TODO` and will be wired once the shared UniFFI bindings are
/// stabilised in a follow-up PR.
///
/// ## Threading
///
/// `SharedItemBridge` is an `actor` so all mutations are serialised. Call sites
/// in `RustStoreAdapter` dispatch into it via `Task { await ... }` so they never
/// block the main thread.
public actor SharedItemBridge {

    // MARK: - Singleton

    public static let shared = SharedItemBridge()

    // MARK: - State

    /// Whether the shared workspace directory was successfully prepared at startup.
    private var isAvailable = false

    /// Path to the shared impress-core SQLite database.
    private var sharedStorePath: String = ""

    #if canImport(ImpressRustCore)
    /// Lazily-opened shared store handle.
    private var store: SharedStore?
    #endif

    // MARK: - Initialization

    private init() {
        do {
            try SharedWorkspace.ensureDirectoryExists()
            sharedStorePath = SharedWorkspace.databaseURL.path
            isAvailable = true
            #if canImport(ImpressRustCore)
            store = try SharedStore.open(path: sharedStorePath)
            #endif
            Logger.library.infoCapture(
                "SharedItemBridge: shared workspace ready at \(sharedStorePath)",
                category: "shared-bridge"
            )
        } catch {
            // Non-fatal: imbib continues normally without cross-app visibility.
            isAvailable = false
            Logger.library.error("SharedItemBridge: workspace unavailable — \(error)")
        }
    }

    // MARK: - Schema Registration

    /// Called at app startup to register impress-core schemas in the shared store.
    ///
    /// Must be called before any `sync(…)` calls. Safe to call multiple times.
    public func registerSchemas() {
        guard isAvailable else { return }
        // Schema registration is handled by impress-core's register_core_schemas()
        // which runs automatically when SqliteItemStore is opened.
        Logger.library.infoCapture(
            "SharedItemBridge: store open, schemas registered via impress-core",
            category: "shared-bridge"
        )
    }

    // MARK: - Publication Sync

    /// Sync a publication to the shared store as a `bibliography-entry@1.0.0` item.
    ///
    /// Call this after every imbib publication mutation (create / update / import).
    /// The call is idempotent: re-syncing an existing publication updates it in-place.
    ///
    /// - Parameters:
    ///   - publicationID: The publication's stable UUID string.
    ///   - title: Display title.
    ///   - authors: Author display names (e.g. ["Einstein, A", "Bohr, N"]).
    ///   - year: Publication year, or nil if unknown.
    ///   - doi: DOI string without "https://doi.org/" prefix, or nil.
    ///   - arxivID: arXiv identifier (e.g. "2301.07041"), or nil.
    ///   - abstract: Abstract text, or nil.
    ///   - citeKey: BibTeX cite key, or nil.
    ///   - entryType: BibTeX entry type (e.g. "article", "inproceedings"), or nil.
    public func sync(
        publicationID: String,
        title: String,
        authors: [String],
        year: Int?,
        doi: String?,
        arxivID: String?,
        abstract: String?,
        citeKey: String?,
        entryType: String?
    ) {
        guard isAvailable else { return }

        let payload: [String: Any?] = [
            "title": title,
            "year": year,
            "doi": doi,
            "arxiv_id": arxivID,
            "abstract": abstract,
            "cite_key": citeKey,
            "entry_type": entryType,
            "authors": authors.isEmpty ? nil : authors.joined(separator: "; ")
        ]
        let compacted = payload.compactMapValues { $0 }
        guard let payloadJSON = try? JSONSerialization.data(withJSONObject: compacted),
              let payloadString = String(data: payloadJSON, encoding: .utf8) else {
            Logger.library.error("SharedItemBridge: failed to encode payload for \(publicationID)")
            return
        }

        #if canImport(ImpressRustCore)
        do {
            try store?.upsertItem(id: publicationID, schemaRef: "bibliography-entry", payloadJson: payloadString)
            Logger.library.infoCapture(
                "SharedItemBridge: synced pub \(publicationID) '\(title)'",
                category: "shared-bridge"
            )
        } catch {
            Logger.library.error("SharedItemBridge: upsert failed for \(publicationID) — \(error)")
        }
        #else
        Logger.library.infoCapture(
            "SharedItemBridge: sync pub \(publicationID) '\(title)' (ImpressRustCore not linked)",
            category: "shared-bridge"
        )
        #endif
    }

    /// Remove a publication from the shared store.
    ///
    /// Call this after a publication is deleted from imbib-core.
    ///
    /// - Parameter publicationID: The publication's stable UUID string.
    public func remove(publicationID: String) {
        guard isAvailable else { return }

        #if canImport(ImpressRustCore)
        do {
            try store?.deleteItem(id: publicationID)
            Logger.library.infoCapture(
                "SharedItemBridge: removed pub \(publicationID)",
                category: "shared-bridge"
            )
        } catch {
            Logger.library.error("SharedItemBridge: delete failed for \(publicationID) — \(error)")
        }
        #else
        Logger.library.infoCapture(
            "SharedItemBridge: remove pub \(publicationID) (ImpressRustCore not linked)",
            category: "shared-bridge"
        )
        #endif
    }
}
