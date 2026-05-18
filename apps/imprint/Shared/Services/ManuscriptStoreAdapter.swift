//
//  ManuscriptStoreAdapter.swift
//
//  @MainActor @Observable facade onto the unified impress store for
//  manuscripts. Modelled byte-for-byte on imbib's `RustStoreAdapter`:
//  views read/write through this adapter; mutations bump `dataVersion`
//  to drive `@Observable` re-evaluation, and fan out through
//  `ImprintImpressStore.postMutation(...)` to background subscribers.
//
//  The body of a manuscript lives in the SQLite payload (per the
//  "single source of truth" decision in
//  /Users/tabel/.claude/plans/one-store-the-store-melodic-wreath.md).
//  Toolchains (LaTeX compile, Veusz render, export) materialize the body
//  via `ManuscriptWorkingDirectory.materialize(...)` at invocation time
//  and clear `.tmp/` afterwards.
//

import CommonCrypto
import Foundation
import ImprintCore
import ImpressKit
import ImpressLogging
import ImpressRustCore
import ImpressStoreKit
import OSLog

// MARK: - Domain model

/// Read-only snapshot of a manuscript item, returned by adapter queries.
///
/// `body` is loaded along with metadata — for large manuscripts this is
/// the same I/O cost as today's `FileDocument` open, and lets the editor
/// hand the string straight into its text binding without a second
/// round-trip.
public struct ManuscriptModel: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let title: String
    public let format: ManuscriptFormat
    public let status: String
    public let authors: [String]
    public let body: String
    public let bodyContentHash: String?
    public let bodyModifiedAt: Date?
    public let createdAt: Date
    public let isStarred: Bool
    public let isRead: Bool
    public let tags: [String]
    public let flagColor: String?
    public let importSource: ImportSource?

    /// imbib bridge fields — mirror the manuscript payload's
    /// `linked_imbib_manuscript_id` / `linked_imbib_library_id`. Maintained
    /// by `ManuscriptLibraryCoordinator` when a draft is linked to an imbib
    /// library entry.
    public let linkedImbibManuscriptID: UUID?
    public let linkedImbibLibraryID: String?

    /// FAIR attribution fields (ADR-0014 D54). All informational; no
    /// enforcement code paths.
    public let orcid: String?
    public let affiliation: String?
    public let funder: String?
    public let license: String?
    public let embargoUntil: Date?
}

public enum ManuscriptFormat: String, Sendable, Codable, Equatable {
    case typst
    case latex

    /// File extension used when materializing the body to disk for a
    /// toolchain invocation.
    public var bodyFileName: String {
        switch self {
        case .typst: return "main.typ"
        case .latex: return "main.tex"
        }
    }

    /// Default plot export format paired with this manuscript format: SVG
    /// for Typst (native), PDF for LaTeX (pdfLaTeX has no native SVG path).
    public var defaultPlotFormat: String {
        switch self {
        case .typst: return "svg"
        case .latex: return "pdf"
        }
    }
}

/// Where this manuscript came from, populated by `ManuscriptImporter`.
/// Powers the "Imported from <path>. Original is detached." banner and
/// the "Reveal original in Finder" affordance.
public struct ImportSource: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable, Equatable {
        case tex
        case imprint
    }
    public let kind: Kind
    public let originalPath: String?
    public let originalPathBookmarkBase64: String?
}

// MARK: - Adapter

@MainActor
@Observable
public final class ManuscriptStoreAdapter {

    // MARK: - Singleton

    /// Shared singleton. Background actors can read the instance pointer
    /// directly because the type is `Sendable` (final `@Observable` class
    /// with only `let`-stored or actor-isolated mutable state). Only
    /// nonisolated members of the returned instance are safe to touch
    /// off-main (e.g., `sharedStore`).
    public static let shared: ManuscriptStoreAdapter = {
        do {
            let isUITesting = ProcessInfo.processInfo.arguments.contains("--ui-testing")
            return try ManuscriptStoreAdapter(inMemory: isUITesting)
        } catch {
            fatalError("Failed to initialize ManuscriptStoreAdapter: \(error)")
        }
    }()

    // MARK: - Store handle

    /// The underlying impress-core handle. `nonisolated(unsafe)` because
    /// `SharedStore` is internally synchronized (Arc<Mutex<...>>) — safe to
    /// read from any actor.
    public nonisolated(unsafe) let sharedStore: SharedStore

    // MARK: - Observable state

    /// Bumped on every mutation. Views observe this to trigger
    /// `@Observable` re-evaluation.
    public private(set) var dataVersion: Int = 0

    // MARK: - Batch mutation API

    private var batchDepth: Int = 0
    private var batchHadStructural: Bool = false
    private var batchChangedFieldIDs: Set<UUID> = []

    /// Begin a batch mutation. While a batch is active, individual
    /// `didMutate()` calls suppress notification posting. Call
    /// `endBatchMutation()` when done — one consolidated event fires.
    /// Supports nesting.
    public func beginBatchMutation() {
        batchDepth += 1
    }

    /// Force a `dataVersion` bump + structural event without going through
    /// a typed mutation method. Used by services that talk to the FFI
    /// directly (e.g. `ManuscriptImporter` when preserving a bundle's
    /// pre-assigned UUID through a raw `upsertItem`).
    public func refresh() {
        didMutate(structural: true)
    }

    /// End a batch mutation. When the outermost batch ends, posts a single
    /// coalesced `.structural` (or `.itemsMutated`) event summarizing all
    /// mutations during the batch.
    public func endBatchMutation() {
        precondition(batchDepth > 0, "endBatchMutation called without matching begin")
        batchDepth -= 1
        guard batchDepth == 0 else { return }

        if !batchChangedFieldIDs.isEmpty {
            let ids = batchChangedFieldIDs
            batchChangedFieldIDs.removeAll()
            ImprintImpressStore.shared.postMutation(
                structural: false,
                affectedIDs: ids,
                kind: .otherField
            )
        }
        let structural = batchHadStructural
        batchHadStructural = false
        ImprintImpressStore.shared.postMutation(structural: structural)
    }

    // MARK: - Init

    /// Factory for tests: a fresh adapter backed by an in-memory
    /// `SharedStore`. Each call returns an independent instance — they do
    /// not share state with the singleton or with each other.
    public static func forTesting() throws -> ManuscriptStoreAdapter {
        try ManuscriptStoreAdapter(inMemory: true)
    }

    /// `nonisolated` so the `shared` singleton initializer (which runs in a
    /// nonisolated context) can call this without crossing actor boundaries.
    /// The work here is FFI-only — opening a SharedStore handle — and the
    /// resulting instance is then accessed on `@MainActor` like any other
    /// `@Observable` class.
    private nonisolated init(inMemory: Bool) throws {
        if inMemory {
            self.sharedStore = try SharedStore.openInMemory()
        } else {
            try SharedWorkspace.ensureDirectoryExists()
            self.sharedStore = try SharedStore.open(path: SharedWorkspace.databasePath)
        }
        Logger.sharedStore.infoCapture(
            "ManuscriptStoreAdapter initialized (in-memory: \(inMemory))",
            category: "manuscript-store"
        )
    }

    // MARK: - Mutation tracking

    /// Signal that the store was mutated. Bumps `dataVersion` and (unless
    /// inside an active batch) fans out via the impress store gateway.
    ///
    /// - Parameter structural: `true` for create/delete/reparent (full
    ///   refresh); `false` for in-place field changes (O(k) row updates).
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
            return
        }
        ImprintImpressStore.shared.postMutation(
            structural: structural,
            affectedIDs: affectedIDs,
            kind: kind
        )
    }

    // MARK: - Manuscript CRUD

    /// Create a new manuscript and return its ID.
    @discardableResult
    public func createManuscript(
        title: String,
        format: ManuscriptFormat,
        body: String = "",
        authors: [String] = []
    ) throws -> UUID {
        let id = UUID()
        let now = ISO8601DateFormatter().string(from: Date())
        let bodyHash = Self.sha256Hex(body)
        let payload: [String: Any] = [
            "title": title,
            "status": "draft",
            "current_revision_ref": id.uuidString,  // self-ref until first revision
            "authors": authors,
            "format": format.rawValue,
            "body_content": body,
            "body_content_hash": bodyHash,
            "body_modified_at": now,
            "format_schema_version": 140,  // mirrors current DocumentSchemaVersion.v1_4
        ]
        let json = try Self.encodeJSON(payload)
        try sharedStore.upsertItem(
            id: id.uuidString,
            schemaRef: "manuscript",
            payloadJson: json
        )
        Logger.sharedStore.infoCapture(
            "Created manuscript \(id) (\(format.rawValue), \(body.count) bytes)",
            category: "manuscript-store"
        )
        didMutate(structural: true)
        return id
    }

    /// Fetch a single manuscript by ID. Returns nil if not found.
    public func manuscript(id: UUID) -> ManuscriptModel? {
        do {
            guard let row = try sharedStore.getItem(id: id.uuidString) else {
                return nil
            }
            return try Self.decode(row: row)
        } catch {
            Logger.sharedStore.error(
                "manuscript(id:) failed for \(id): \(error.localizedDescription)"
            )
            return nil
        }
    }

    /// Update a manuscript's body content. Recomputes
    /// `body_content_hash` and `body_modified_at` in the same call.
    public func setBody(id: UUID, text: String) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let payload: [String: Any] = [
            "body_content": text,
            "body_content_hash": Self.sha256Hex(text),
            "body_modified_at": now,
        ]
        let json = try Self.encodeJSON(payload)
        try sharedStore.upsertItem(
            id: id.uuidString,
            schemaRef: "manuscript",
            payloadJson: json
        )
        didMutate(structural: false, affectedIDs: [id], kind: .otherField)
    }

    /// Update top-level manuscript metadata (title, status, authors,
    /// import_source, imbib bridges, FAIR attribution). Body edits go
    /// through `setBody(id:text:)`. Pass nil to leave a field unchanged.
    public func updateMetadata(
        id: UUID,
        title: String? = nil,
        status: String? = nil,
        authors: [String]? = nil,
        importSource: ImportSource? = nil,
        linkedImbibManuscriptID: UUID? = nil,
        linkedImbibLibraryID: String? = nil,
        orcid: String? = nil,
        affiliation: String? = nil,
        funder: String? = nil,
        license: String? = nil,
        embargoUntil: Date? = nil
    ) throws {
        var payload: [String: Any] = [:]
        if let title { payload["title"] = title }
        if let status { payload["status"] = status }
        if let authors { payload["authors"] = authors }
        if let importSource {
            payload["import_source"] = try Self.encodeJSON(importSource)
        }
        if let linkedImbibManuscriptID {
            payload["linked_imbib_manuscript_id"] = linkedImbibManuscriptID.uuidString
        }
        if let linkedImbibLibraryID {
            payload["linked_imbib_library_id"] = linkedImbibLibraryID
        }
        if let orcid { payload["orcid"] = orcid }
        if let affiliation { payload["affiliation"] = affiliation }
        if let funder { payload["funder"] = funder }
        if let license { payload["license"] = license }
        if let embargoUntil {
            payload["embargo_until"] = ISO8601DateFormatter().string(from: embargoUntil)
        }
        guard !payload.isEmpty else { return }
        let json = try Self.encodeJSON(payload)
        try sharedStore.upsertItem(
            id: id.uuidString,
            schemaRef: "manuscript",
            payloadJson: json
        )
        didMutate(structural: false, affectedIDs: [id], kind: .otherField)
    }

    /// Delete a manuscript and its working directory.
    public func deleteManuscript(id: UUID) throws {
        try sharedStore.deleteItem(id: id.uuidString)
        // Best-effort working-dir cleanup. Not fatal if it fails — the next
        // launch can prune orphaned dirs.
        ManuscriptWorkingDirectory().clear(manuscriptID: id)
        Logger.sharedStore.infoCapture(
            "Deleted manuscript \(id)",
            category: "manuscript-store"
        )
        didMutate(structural: true)
    }

    /// List all manuscripts, sorted by created descending. `limit = 0`
    /// uses the FFI default (100).
    public func listManuscripts(limit: UInt32 = 0, offset: UInt32 = 0) -> [ManuscriptModel] {
        do {
            let rows = try sharedStore.queryBySchema(
                schemaRef: "manuscript",
                limit: limit,
                offset: offset
            )
            return rows.compactMap { try? Self.decode(row: $0) }
        } catch {
            Logger.sharedStore.error("listManuscripts failed: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Collection CRUD (minimal — fleshed out in phase 3)

    /// Create a new collection. Returns its UUID.
    @discardableResult
    public func createCollection(
        name: String,
        parentID: UUID? = nil,
        isWorkspace: Bool = false
    ) throws -> UUID {
        let id = UUID()
        var payload: [String: Any] = [
            "name": name,
            "is_workspace": isWorkspace,
        ]
        if let parentID {
            payload["parent_collection_ref"] = parentID.uuidString
        }
        let json = try Self.encodeJSON(payload)
        try sharedStore.upsertItem(
            id: id.uuidString,
            schemaRef: "manuscript-collection",
            payloadJson: json
        )
        didMutate(structural: true)
        return id
    }

    // MARK: - Decoding

    /// Decode a `SharedItemRow` into a `ManuscriptModel`. Throws if the
    /// payload JSON is malformed or required fields are missing.
    private static func decode(row: SharedItemRow) throws -> ManuscriptModel {
        guard let id = UUID(uuidString: row.id) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "invalid UUID: \(row.id)")
            )
        }
        let payloadData = Data(row.payloadJson.utf8)
        let payload = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any] ?? [:]

        let title = payload["title"] as? String ?? "Untitled"
        let status = payload["status"] as? String ?? "draft"
        let authors = payload["authors"] as? [String] ?? []
        let formatRaw = payload["format"] as? String ?? "typst"
        let format = ManuscriptFormat(rawValue: formatRaw) ?? .typst
        let body = payload["body_content"] as? String ?? ""
        let bodyHash = payload["body_content_hash"] as? String
        let bodyModifiedAt = (payload["body_modified_at"] as? String)
            .flatMap { ISO8601DateFormatter().date(from: $0) }
        let createdAt = Date(timeIntervalSince1970: TimeInterval(row.createdMs) / 1000.0)

        var importSource: ImportSource?
        if let importJSON = payload["import_source"] as? String,
           let data = importJSON.data(using: .utf8) {
            importSource = try? JSONDecoder().decode(ImportSource.self, from: data)
        }

        let linkedImbibManuscriptID = (payload["linked_imbib_manuscript_id"] as? String)
            .flatMap(UUID.init(uuidString:))
        let linkedImbibLibraryID = payload["linked_imbib_library_id"] as? String
        let orcid = payload["orcid"] as? String
        let affiliation = payload["affiliation"] as? String
        let funder = payload["funder"] as? String
        let license = payload["license"] as? String
        let embargoUntil = (payload["embargo_until"] as? String)
            .flatMap { ISO8601DateFormatter().date(from: $0) }

        return ManuscriptModel(
            id: id,
            title: title,
            format: format,
            status: status,
            authors: authors,
            body: body,
            bodyContentHash: bodyHash,
            bodyModifiedAt: bodyModifiedAt,
            createdAt: createdAt,
            isStarred: row.isStarred,
            isRead: row.isRead,
            tags: row.tags,
            flagColor: row.flagColor,
            importSource: importSource,
            linkedImbibManuscriptID: linkedImbibManuscriptID,
            linkedImbibLibraryID: linkedImbibLibraryID,
            orcid: orcid,
            affiliation: affiliation,
            funder: funder,
            license: license,
            embargoUntil: embargoUntil
        )
    }

    // MARK: - Encoding helpers

    private static func encodeJSON(_ payload: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                payload,
                .init(codingPath: [], debugDescription: "payload not UTF-8")
            )
        }
        return text
    }

    private static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                value,
                .init(codingPath: [], debugDescription: "encoded value not UTF-8")
            )
        }
        return text
    }

    private static func sha256Hex(_ text: String) -> String {
        let data = Data(text.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buf in
            _ = CC_SHA256(buf.baseAddress, CC_LONG(buf.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
