// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS): a `SharedStore`
// reader (Foundation + ImpressRustCore). While it was gated iOS could not read
// figures from the shared store AT ALL.
//
//  FigureStoreReader.swift
//  PublicationManagerCore
//
//  Stage 2-B (ADR-0021): store access for the Figures section. Figure and
//  figure-collection items live in the SHARED impress store (written by
//  implore, Stage 0), but the imbib-core FFI has no typed figure queries —
//  so this reader opens its own `SharedStore` handle on the same database
//  (pattern: apps/imprint/macOS/Services/ImprintPublicationService.start())
//  and uses the flat `queryItems` API (SharedItemQuery/SharedItemRow).
//
//  Scope discipline: reads + the two envelope mutations the sidebar needs
//  (`setParent` for figure/folder moves, folder creation via upsertItemV2).
//  Everything the generic imbib-core ops already cover — star/flag/tag,
//  payload field updates, delete — goes through `RustStoreAdapter.shared`
//  so undo + StoreEvent fan-out keep working unchanged.
//

import Foundation
import ImpressKit
import ImpressRustCore
import OSLog

/// Decoded `figure@…` payload fields (all optional except format by schema,
/// but decode defensively — Stage-0 backfill rows carry only title/format).
struct FigurePayload: Decodable {
    var format: String?
    var title: String?
    var caption: String?
    var dataHash: String?
    var scriptHash: String?

    enum CodingKeys: String, CodingKey {
        case format, title, caption
        case dataHash = "data_hash"
        case scriptHash = "script_hash"
    }
}

/// Decoded `figure-collection@…` payload fields.
struct FigureCollectionPayload: Decodable {
    var name: String?
    var sortOrder: Int?
    var isCollapsed: Bool?

    enum CodingKeys: String, CodingKey {
        case name
        case sortOrder = "sort_order"
        case isCollapsed = "is_collapsed"
    }
}

@MainActor
public final class FigureStoreReader {

    public static let shared = FigureStoreReader()

    private static let logger = Logger(subsystem: "com.imbib.app", category: "figures")

    private var store: SharedStore?

    /// Content-addressed storage directory for figure binaries
    /// (`~/.local/share/impress/content/{sha256}`, keyed by payload data_hash).
    ///
    /// Delegated to `BlobStore.defaultRootURL()` rather than re-deriving the
    /// path: `homeDirectoryForCurrentUser` is unavailable on iOS, and BlobStore
    /// already owns the one per-platform answer for this exact directory
    /// (macOS `~/.local/share/impress/content`, byte-identical to what this
    /// property returned before; iOS `<AppSupport>/impress/content`). Two
    /// derivations of one path is the drift, not the fix.
    public var contentStoreDirectory: URL {
        BlobStore.defaultRootURL()
    }

    private init() {
        do {
            try SharedWorkspace.ensureDirectoryExists()
            store = try SharedStore.open(path: SharedWorkspace.databasePath)
        } catch {
            Self.logger.error("FigureStoreReader failed to open shared store: \(error)")
        }
    }

    public var isReady: Bool { store != nil }

    // MARK: - Reads

    /// All figure folders (figure-collection items), sorted by payload sort_order.
    public func fetchFolders() -> [SharedItemRow] {
        guard let store else { return [] }
        return (try? store.queryItems(query: SharedItemQuery(
            schemaRef: "figure-collection", parentId: nil, payloadEq: [],
            modifiedAfterMs: nil, sortField: "payload.sort_order",
            ascending: true, limit: 1000, offset: 0))) ?? []
    }

    /// Figures, optionally scoped to one folder; `nil` returns ALL figures
    /// (filter `parentId == nil` client-side for Unfiled — fine at implore scale).
    public func fetchFigures(inFolder folderID: String? = nil) -> [SharedItemRow] {
        guard let store else { return [] }
        return (try? store.queryItems(query: SharedItemQuery(
            schemaRef: "figure", parentId: folderID?.lowercased(), payloadEq: [],
            modifiedAfterMs: nil, sortField: "modified",
            ascending: false, limit: 5000, offset: 0))) ?? []
    }

    /// One figure row by store id.
    public func fetchFigure(id: String) -> SharedItemRow? {
        guard let store else { return nil }
        guard let row = try? store.getItem(id: id.lowercased()) else { return nil }
        // The tolerant registry lookup, which is base-name equality on BOTH
        // sides — not `hasPrefix`. The two prefix checks this replaces were a
        // hand-rolled version of exactly that, including the special case for
        // `figure-collection` (a prefix check matches it; base-name equality
        // never did). `SchemaRefKindLookup` documents that rule as the reason
        // it exists, so a second copy of it here was the bug waiting to happen.
        guard BuiltinRecordKinds.registry.kind(forStoreSchemaRef: row.schemaRef) == .figure
        else { return nil }
        return row
    }

    /// Raw bytes of a CAS artifact by its sha256 data_hash, if present.
    public func contentData(hash: String) -> Data? {
        let url = contentStoreDirectory.appendingPathComponent(hash)
        return try? Data(contentsOf: url)
    }

    // MARK: - Envelope mutations (figures + folders nest via envelope `parent`)

    /// Move a figure into a folder (nil = Unfiled) or reparent a folder.
    /// Posts a structural StoreEvent so the chassis sidebar/lists reload.
    public func setParent(itemID: String, parentID: String?) {
        guard let store else { return }
        do {
            try store.setParent(id: itemID.lowercased(), parentId: parentID?.lowercased())
            Self.logger.infoCapture(
                "figure setParent \(itemID) → \(parentID ?? "root")", category: "figures")
            ImbibImpressStore.shared.postMutation(structural: true)
        } catch {
            Self.logger.errorCapture("figure setParent failed: \(error)", category: "figures")
        }
    }

    /// Create a figure folder. There is no createFigureCollection FFI on
    /// RustStoreAdapter — create via upsertItemV2 with the figure-collection
    /// schema (name payload; nesting via envelope parent). Returns the new
    /// folder's lowercase store id.
    @discardableResult
    public func createFolder(name: String, parentID: String? = nil) -> String? {
        guard let store else { return nil }
        let id = UUID().uuidString.lowercased()
        let sortOrder = fetchFolders().count
        let payload: [String: Any] = ["name": name, "sort_order": sortOrder]
        guard let json = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: json, encoding: .utf8) else { return nil }
        do {
            try store.upsertItemV2(row: SharedItemUpsert(
                id: id, schemaRef: "figure-collection",
                payloadJson: jsonString, parentId: parentID?.lowercased(), tags: [],
                createdMs: nil, isRead: nil, isStarred: nil))
            Self.logger.infoCapture(
                "created figure folder '\(name)' (\(id)) parent=\(parentID ?? "root")",
                category: "figures")
            ImbibImpressStore.shared.postMutation(structural: true)
            return id
        } catch {
            Self.logger.errorCapture("createFolder failed: \(error)", category: "figures")
            return nil
        }
    }

    // MARK: - Payload decoding helpers

    nonisolated static func figurePayload(from row: SharedItemRow) -> FigurePayload? {
        guard let data = row.payloadJson.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(FigurePayload.self, from: data)
    }

    nonisolated static func folderPayload(from row: SharedItemRow) -> FigureCollectionPayload? {
        guard let data = row.payloadJson.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(FigureCollectionPayload.self, from: data)
    }
}
