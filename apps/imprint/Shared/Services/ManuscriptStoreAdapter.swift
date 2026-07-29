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
    case markdown
    case plaintext

    /// File extension used when materializing the body to disk for a
    /// toolchain invocation.
    public var bodyFileName: String {
        switch self {
        case .typst: return "main.typ"
        case .latex: return "main.tex"
        case .markdown: return "main.md"
        case .plaintext: return "main.txt"
        }
    }

    /// Default plot export format paired with this manuscript format: SVG
    /// for Typst (native), PDF for LaTeX (pdfLaTeX has no native SVG path).
    /// Markdown/plaintext have no toolchain — SVG embeds/links fine.
    public var defaultPlotFormat: String {
        switch self {
        case .typst, .markdown, .plaintext: return "svg"
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
        case markdown
        case plaintext
    }
    public let kind: Kind
    public let originalPath: String?
    public let originalPathBookmarkBase64: String?
}

// MARK: - Collections (ADR-0022 collection kernel)

/// One manuscript folder, binding-agnostic. The imprint-side twin of PMC's
/// `CollectionKernelRow` (which is macOS-gated because it ships inside the
/// macOS-only `CollectionStoreAdapter`); both are thin projections of the
/// kernel's `SharedCollectionRow`, so the two GUIs read the same tree.
public struct ManuscriptCollection: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    /// TREE parent (payload `parent_collection_ref` for this binding), `nil`
    /// for a root. NEVER the envelope parent — that is the owning library
    /// (imbib CLAUDE.md invariant, c902a22f postmortem).
    public let parentID: UUID?
    public let sortOrder: Int64

    init?(_ row: SharedCollectionRow) {
        guard let id = UUID(uuidString: row.id) else { return nil }
        self.id = id
        self.name = row.name
        self.parentID = row.parentId.flatMap(UUID.init(uuidString:))
        self.sortOrder = row.sortOrder
    }
}

// MARK: - List scopes

/// What subset of manuscripts a LIST surface shows — the cross-platform twin
/// of the macOS chassis's `ManuscriptListScope` (`.all` / `.status` /
/// `.folder` / `.flagged`), expressed in store primitives so it can live in
/// the shared adapter instead of a macOS-only list wrapper.
public enum ManuscriptStoreScope: Hashable, Sendable {
    case all
    /// A payload `status` value. The reserved ones come from the descriptor
    /// (`ManuscriptStoreAdapter.dismissedStatus` / `.archivedStatus`), never
    /// from a literal at the call site.
    case status(String)
    /// Members of a manuscript folder (a `Contains` edge from the collection).
    case folder(UUID)
    /// Flagged manuscripts; `nil` colour = any flag.
    case flagged(String?)

    /// The status this scope explicitly asks for, if any. Drives the
    /// dismissed-exclusion rule: only a scope that NAMES `dismissed` sees
    /// dismissed rows.
    var explicitStatus: String? {
        if case .status(let s) = self { return s }
        return nil
    }
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

    // MARK: - Listing
    //
    // Two verbs, deliberately named apart, because they answer two different
    // questions and the old single `listManuscripts` conflated them:
    //
    //   `listManuscripts(scope:)` — the LIST SURFACE. Applies the record
    //   kind's dismissal rule, so a dismissed manuscript is absent from every
    //   scope except the one that names it (docs/status-lifecycle.md; the
    //   macOS twin is `ManuscriptListWrapper.reload()`). iOS showed dismissed
    //   manuscripts in its library because it called the raw read.
    //
    //   `allManuscripts(...)` — the INDEX / DEDUP read. Every row, whatever
    //   its status. Spotlight indexing, `/api/documents`, the importer's
    //   body-hash dedup and the AppIntents listing must see dismissed rows or
    //   they re-import and re-index them; those call sites use THIS one and
    //   are byte-identical to the pre-split behaviour.

    /// The page size used when a caller does not ask for one. Previously the
    /// default was `limit: 0`, which the FFI silently turned into 100 — a cap
    /// no call site could see. It is now explicit, and `limit: 0` means
    /// "every row", fetched page by page.
    nonisolated public static let defaultPageLimit: UInt32 = 100

    /// Every manuscript in the store, INCLUDING dismissed and archived ones,
    /// sorted by created descending.
    ///
    /// - Parameter limit: `0` = no cap; the store is walked in
    ///   `defaultPageLimit` pages until it is exhausted.
    public func allManuscripts(
        limit: UInt32 = ManuscriptStoreAdapter.defaultPageLimit,
        offset: UInt32 = 0
    ) -> [ManuscriptModel] {
        fetchPaged(limit: limit, offset: offset, page: { pageLimit, pageOffset in
            (try? sharedStore.queryBySchema(
                schemaRef: Self.manuscriptSchemaRef,
                limit: pageLimit,
                offset: pageOffset
            )) ?? []
        }, include: { _ in true })
    }

    /// The list surface: manuscripts in `scope`, sorted by created
    /// descending, with the descriptor's dismissal rule applied.
    ///
    /// - Parameter limit: `0` = no cap (paged internally). Filtering happens
    ///   AFTER each page is read, and pages keep being read until `limit`
    ///   surviving rows exist or the store runs out — so a page is never
    ///   short just because it contained dismissed rows.
    /// - Parameter offset: a STORE offset, applied before filtering.
    public func listManuscripts(
        scope: ManuscriptStoreScope = .all,
        limit: UInt32 = ManuscriptStoreAdapter.defaultPageLimit,
        offset: UInt32 = 0
    ) -> [ManuscriptModel] {
        // Folder membership is an edge walk, not a predicate query — the
        // kernel records it as a `Contains` edge from the collection.
        if case .folder(let collectionID) = scope {
            let members = folderMembers(collectionID: collectionID)
                .filter { survivesDismissalRule($0, scope: scope) }
                .sorted { $0.createdAt > $1.createdAt }
            let start = min(Int(offset), members.count)
            let tail = Array(members[start...])
            return limit == 0 ? tail : Array(tail.prefix(Int(limit)))
        }

        var payloadEq: [SharedFieldEq] = []
        if let status = scope.explicitStatus {
            payloadEq.append(
                SharedFieldEq(field: "status", valueJson: Self.jsonString(status)))
        }

        return fetchPaged(limit: limit, offset: offset, page: { pageLimit, pageOffset in
            (try? sharedStore.queryItems(query: SharedItemQuery(
                schemaRef: Self.manuscriptSchemaRef,
                parentId: nil,
                payloadEq: payloadEq,
                modifiedAfterMs: nil,
                sortField: "created",
                ascending: false,
                limit: pageLimit,
                offset: pageOffset
            ))) ?? []
        }, include: { model in
            guard survivesDismissalRule(model, scope: scope) else { return false }
            if case .flagged(let color) = scope {
                guard let flag = model.flagColor else { return false }
                if let color, flag != color { return false }
            }
            return true
        })
    }

    /// The one place the dismissal rule is spelled out. The status value
    /// itself is the DESCRIPTOR's (`dismissedStatus`), never a literal.
    private func survivesDismissalRule(
        _ model: ManuscriptModel, scope: ManuscriptStoreScope
    ) -> Bool {
        guard let dismissed = Self.dismissedStatus else { return true }
        if scope.explicitStatus == dismissed { return true }
        return model.status != dismissed
    }

    /// Manuscripts filed into `collectionID` — the kernel's `Contains` edges
    /// out of the collection, resolved to items and filtered to this kind.
    private func folderMembers(collectionID: UUID) -> [ManuscriptModel] {
        let id = collectionID.uuidString.lowercased()
        guard let refs = try? sharedStore.getItemReferences(id: id) else { return [] }
        return refs
            .filter { $0.edgeType == "Contains" }
            .compactMap { ref -> ManuscriptModel? in
                guard let row = try? sharedStore.getItem(id: ref.targetId),
                      Self.baseSchemaRef(row.schemaRef) == Self.manuscriptSchemaRef
                else { return nil }
                return try? Self.decode(row: row)
            }
    }

    /// Read pages of `page(limit:offset:)` until `limit` rows survive
    /// `include` (or the store is exhausted). `limit == 0` reads everything.
    private func fetchPaged(
        limit: UInt32,
        offset: UInt32,
        page: (UInt32, UInt32) -> [SharedItemRow],
        include: (ManuscriptModel) -> Bool
    ) -> [ManuscriptModel] {
        let wanted = limit == 0 ? Int.max : Int(limit)
        // A bounded request asks the store for exactly that many rows, so the
        // unfiltered path stays ONE FFI call (byte-identical to the previous
        // `queryBySchema(limit:)`); a second page is read only when filtering
        // actually removed rows.
        let pageSize = limit == 0 ? Self.defaultPageLimit : limit
        var cursor = offset
        var kept: [ManuscriptModel] = []
        while kept.count < wanted {
            let rows = page(pageSize, cursor)
            if rows.isEmpty { break }
            cursor &+= UInt32(rows.count)
            kept.append(contentsOf: rows.compactMap { try? Self.decode(row: $0) }.filter(include))
            if rows.count < Int(pageSize) { break }
        }
        return wanted == .max ? kept : Array(kept.prefix(wanted))
    }

    /// `"manuscript@1.2.0"` → `"manuscript"`. The store hands out versioned
    /// refs; the descriptor declares the bare one (PMC's
    /// `RecordKindSchemaRef.baseName`, kept local so this file needs no PMC
    /// import).
    static func baseSchemaRef(_ schemaRef: String) -> String {
        String(schemaRef.prefix { $0 != "@" })
    }

    /// `SharedFieldEq.valueJson` is a JSON *value*, so a string predicate must
    /// arrive quoted and escaped. Encoded through JSONSerialization (as a
    /// one-element array, then unwrapped) rather than string interpolation so
    /// a folder or status containing a quote cannot corrupt the predicate.
    static func jsonString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
              let text = String(data: data, encoding: .utf8),
              text.count >= 2
        else { return "\"\(value)\"" }
        return String(text.dropFirst().dropLast())
    }

    // MARK: - Publication queries (cross-app, read-only)

    /// Query imbib publications (`bibliography-entry` items) from the shared
    /// store. An empty `query` lists recent entries; a non-empty query runs
    /// FTS across title/author/abstract. Runs synchronously on the main
    /// actor like the other adapter reads — the underlying SQLite lookup is
    /// fast and the row count is bounded by `limit`.
    /// The schema ref imbib actually writes for publications.
    static let publicationSchemaRef = "imbib/bibliography-entry"

    public func queryPublications(matching query: String, limit: UInt32 = 200) -> [SharedItemRow] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            // "imbib/bibliography-entry", NOT "bibliography-entry": imbib
            // writes the namespaced form (imbib-core conversion.rs) and the
            // store matches schema_ref by EQUALITY, not prefix (sql_query.rs).
            // The unprefixed spelling matched zero rows on every platform,
            // which is why the iOS citation picker always reported an empty
            // imbib library.
            if trimmed.isEmpty {
                return try sharedStore.queryBySchema(
                    schemaRef: Self.publicationSchemaRef,
                    limit: limit,
                    offset: 0
                )
            } else {
                return try sharedStore.search(
                    query: trimmed,
                    schemaFilter: Self.publicationSchemaRef,
                    limit: limit
                )
            }
        } catch {
            Logger.sharedStore.error(
                "queryPublications failed: \(error.localizedDescription)"
            )
            return []
        }
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
        let formatRaw = payload["format"] as? String ?? ""
        let body = payload["body_content"] as? String ?? ""
        // Missing/unrecognized format: infer from content + title rather than
        // reporting "typst" for a Markdown document (which is what made the
        // list badge and /api/documents disagree with the actual body).
        let format = ManuscriptFormat(rawValue: formatRaw)
            ?? ManuscriptFormat(rawValue: DocumentFormat.detect(from: body, title: title).rawValue)
            ?? .typst
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

    /// The `body_content_hash` for a body string — the same SHA-256 scheme
    /// the adapter stores in the manuscript payload. Exposed so range-anchored
    /// comment code (`CommentService`) can stamp anchors with a hash that
    /// matches the manuscript's persisted body when the editor buffer is in
    /// sync, letting `RangeAnchoredComments` detect Exact vs Moved ranges.
    public static func bodyContentHash(_ text: String) -> String {
        sha256Hex(text)
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

// MARK: - The record-kind contract, read (not retyped)
//
// ADR-0021 made the chassis contract DATA; the iOS foundation pass made that
// data cross-platform. Everything below therefore READS
// `ManuscriptRecordKind.descriptor` — schema ref, dismissal statuses, archive
// status, deletion semantics, collection binding — instead of restating them.
// A literal `"dismissed"` in this file would be a second source of truth that
// drifts the first time the descriptor changes, which is precisely the class
// of bug the descriptors exist to prevent.

extension ManuscriptStoreAdapter {

    /// The manuscript record kind's declarative contract.
    ///
    /// Internal, not public: `RecordKindDescriptor` reaches imprint through
    /// the module-internal typealias in `PMCManuscriptReexports.swift` (which
    /// is what keeps PMC's `Logger` category extensions out of every file).
    /// The DERIVED values below — plain `String`s — are the public surface.
    nonisolated static var descriptor: RecordKindDescriptor {
        ManuscriptRecordKind.descriptor
    }

    /// The store schema this adapter reads and writes — the descriptor's own
    /// declaration, not a repeated literal.
    nonisolated public static let manuscriptSchemaRef: String =
        ManuscriptRecordKind.descriptor.schemaRefs.first ?? "manuscript"

    /// Reserved `dismissed` status for this kind (docs/status-lifecycle.md),
    /// or nil when the kind has no status-based dismissal.
    nonisolated public static var dismissedStatus: String? {
        if case .statusChange(let dismissed, _) = descriptor.triage.dismissal { return dismissed }
        return nil
    }

    /// Status a restore returns a dismissed manuscript to (`draft`).
    nonisolated public static var restoreStatus: String? {
        if case .statusChange(_, let restoreTo) = descriptor.triage.dismissal { return restoreTo }
        return nil
    }

    /// Reserved `archived` status, or nil when the kind has no archive.
    nonisolated public static var archivedStatus: String? {
        descriptor.triage.archiveStatus
    }

    /// Whether deleting is a hard delete behind a confirmation (`.confirmHard`
    /// for manuscripts) — hosts read this instead of assuming.
    nonisolated public static var deletionIsHard: Bool {
        descriptor.triage.deletion == .confirmHard
    }

    /// The collection-kernel binding id this kind organises through.
    nonisolated public static var collectionBindingID: String {
        descriptor.collection?.bindingID ?? CollectionBindingID.manuscript
    }

    /// Map a descriptor binding id onto the kernel binding. Mirrors
    /// `CollectionStoreAdapter.binding(for:)` — the only two places in Swift
    /// that know a `SharedCollectionBinding` exists.
    nonisolated static func kernelBinding(_ bindingID: String) -> SharedCollectionBinding? {
        switch bindingID {
        case CollectionBindingID.publication: return .publication
        case CollectionBindingID.manuscript: return .manuscript
        case CollectionBindingID.figure: return .figure
        case CollectionBindingID.generic: return .generic
        default: return nil
        }
    }

    nonisolated static var binding: SharedCollectionBinding {
        kernelBinding(collectionBindingID) ?? .manuscript
    }
}

// MARK: - Undo plumbing
//
// Mirrors `CollectionStoreAdapter`'s three rules (ADR-0022 G2), adapted from
// PMC's macOS `UndoCoordinator` to a plain Foundation `UndoManager` the
// CALLER supplies — an iOS view passes the responder chain's manager
// (`SceneUndoManager`), a macOS view can pass `UndoCoordinator`'s, and a test
// passes its own. The adapter deliberately owns none: reaching for a macOS
// singleton is exactly what would have kept this code macOS-only.
//
// Rule 3 verbatim: `apply*` performs the kernel verb and posts the mutation
// event but registers nothing; the PUBLIC verb wraps it and registers the
// inverse. Undo/redo closures therefore call `apply*`, never the public verb.

extension ManuscriptStoreAdapter {

    /// Undo action names. Folder verbs reuse the strings PMC's
    /// `CollectionStoreAdapter.UndoActionName` registers so the two GUIs
    /// describe the same operation identically.
    public enum UndoActionName {
        public static let createCollection = "New Folder"
        public static let renameCollection = "Edit name"
        public static let reparentCollection = "Move Folder"
        public static let deleteCollection = "Delete"
        public static let addMembers = "Add to Collection"
        public static let removeMembers = "Remove from Collection"
        public static let star = "Star"
        public static let flag = "Flag"
        public static let addTag = "Add Tag"
        public static let removeTag = "Remove Tag"
        public static let dismiss = "Dismiss"
        public static let restore = "Restore"
        public static let archive = "Archive"
    }

    /// Register a self-inverting pair. Undoing runs `undo` and re-registers
    /// the mirror; because that registration happens WHILE the manager is
    /// undoing, `UndoManager` puts it on the redo stack — so ⌘Z/⌘⇧Z alternate
    /// indefinitely from a single call here.
    func registerReversible(
        _ undoManager: UndoManager?,
        actionName: String,
        undo: @escaping @MainActor (ManuscriptStoreAdapter) -> Void,
        redo: @escaping @MainActor (ManuscriptStoreAdapter) -> Void
    ) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { [weak undoManager] target in
            MainActor.assumeIsolated {
                undo(target)
                target.registerReversible(
                    undoManager, actionName: actionName, undo: redo, redo: undo)
            }
        }
        undoManager.setActionName(actionName)
    }
}

// MARK: - Collections, through the ADR-0022 kernel
//
// Every verb here is `SharedStore.collection*` — the Rust kernel that owns
// the tree (including the reparent cycle check) and RETURNS the inverse
// information each undo needs: `SharedCollectionMutation.prior` for
// rename/reparent, `SharedDeletedCollection` for delete, and the
// actually-changed id lists for add/remove members.
//
// Before this, `createCollection` hand-rolled a raw `upsertItem` of a
// `manuscript-collection` payload while every other collection path in the
// suite went through the kernel. Two writers to one tree is the inconsistency
// ADR-0022 D1 exists to remove.

extension ManuscriptStoreAdapter {

    /// Ids crossing the FFI are lowercased: the Rust store's canonical id form
    /// is lowercase and payload parent refs are matched by string equality,
    /// while `UUID().uuidString` is uppercase (imbib CLAUDE.md invariant).
    private static func lower(_ id: UUID) -> String { id.uuidString.lowercased() }

    // MARK: Reads

    /// Every manuscript folder, flat and ordered by `sort_order`. Callers
    /// assemble the tree from `parentID`.
    public func listCollections() -> [ManuscriptCollection] {
        do {
            return try sharedStore.collectionTree(binding: Self.binding)
                .compactMap(ManuscriptCollection.init)
        } catch {
            Logger.sharedStore.error("listCollections failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Member counts aligned index-for-index with `collectionIDs`.
    public func collectionMemberCounts(collectionIDs: [UUID]) -> [Int] {
        guard !collectionIDs.isEmpty else { return [] }
        do {
            return try sharedStore.collectionMemberCounts(
                binding: Self.binding,
                collectionIds: collectionIDs.map(Self.lower)
            ).map(Int.init)
        } catch {
            Logger.sharedStore.error(
                "collectionMemberCounts failed: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: Structure

    /// Create a manuscript folder under `parentID` (nil = root).
    ///
    /// Routed through `collection_create`, which also gives the new row its
    /// parent's ENVELOPE parent (the owning library) — something the previous
    /// hand-rolled `upsertItem` never did, so kernel-created folders stay
    /// visible to the legacy `HasParent` listings.
    ///
    /// `isWorkspace` is not a kernel concept; when set it is written as an
    /// additive follow-up field, so the flag survives without the structure
    /// leaving the kernel.
    @discardableResult
    public func createCollection(
        name: String,
        parentID: UUID? = nil,
        isWorkspace: Bool = false,
        undoManager: UndoManager? = nil
    ) throws -> UUID {
        let row = try sharedStore.collectionCreate(
            binding: Self.binding,
            name: name,
            parentId: parentID.map(Self.lower),
            kindScope: nil,
            sortOrder: nil
        )
        if isWorkspace {
            // Read the schema back off the row the KERNEL just wrote rather
            // than naming `manuscript-collection`: WP G7 converges this
            // binding onto `collection@1.0.0`, and a literal here would start
            // writing a second item under the old schema the day it flips.
            let schemaRef = (try? sharedStore.getItem(id: row.id))??.schemaRef
                ?? "manuscript-collection"
            try sharedStore.upsertItem(
                id: row.id,
                schemaRef: schemaRef,
                payloadJson: Self.encodeJSON(["is_workspace": true])
            )
        }
        didMutate(structural: true)
        Logger.sharedStore.infoCapture(
            "Created manuscript collection '\(row.name)' (\(row.id)) "
                + "parent=\(parentID?.uuidString.lowercased() ?? "root")",
            category: "manuscript-store"
        )
        guard let id = UUID(uuidString: row.id) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "kernel returned invalid id \(row.id)")
            )
        }
        registerCollectionExistsUndo(
            undoManager, actionName: UndoActionName.createCollection, id: row.id)
        return id
    }

    /// Rename a folder. The kernel's `prior` carries the previous name, so the
    /// inverse is exact — no racy re-read.
    @discardableResult
    public func renameCollection(
        id: UUID, to name: String, undoManager: UndoManager? = nil
    ) -> Bool {
        guard let mutation = applyRenameCollection(id: Self.lower(id), to: name) else {
            return false
        }
        guard case .name(let priorName) = mutation.prior else { return true }
        let rowID = mutation.row.id
        let newName = mutation.row.name
        registerReversible(
            undoManager,
            actionName: UndoActionName.renameCollection,
            undo: { _ = $0.applyRenameCollection(id: rowID, to: priorName) },
            redo: { _ = $0.applyRenameCollection(id: rowID, to: newName) }
        )
        return true
    }

    /// Move a folder under `newParentID` (nil = make it a root). The cycle
    /// check is the KERNEL's; a rejection is logged and returns `false`.
    @discardableResult
    public func reparentCollection(
        id: UUID, newParentID: UUID?, undoManager: UndoManager? = nil
    ) -> Bool {
        let lowerID = Self.lower(id)
        let newParent = newParentID.map(Self.lower)
        guard let mutation = applyReparentCollection(id: lowerID, newParentID: newParent) else {
            return false
        }
        guard case .parent(let priorParent) = mutation.prior else { return true }
        registerReversible(
            undoManager,
            actionName: UndoActionName.reparentCollection,
            undo: { _ = $0.applyReparentCollection(id: lowerID, newParentID: priorParent) },
            redo: { _ = $0.applyReparentCollection(id: lowerID, newParentID: newParent) }
        )
        return true
    }

    /// Delete a folder. Members are never deleted — `Contains` edges vanish
    /// with the row. `collection_delete` returns the full snapshot (original
    /// id, envelope parent, dropped members, orphaned children) and
    /// `collection_restore` puts all of it back, so undo is lossless.
    @discardableResult
    public func deleteCollection(id: UUID, undoManager: UndoManager? = nil) -> Bool {
        guard let snapshot = applyDeleteCollection(id: Self.lower(id)) else { return false }
        registerCollectionDeletedUndo(
            undoManager, actionName: UndoActionName.deleteCollection, snapshot: snapshot)
        return true
    }

    // Delete/restore cannot use `registerReversible`: the snapshot only exists
    // after a delete has run, so the two directions are mutually recursive
    // rather than symmetric closures over one captured value.

    /// The collection currently EXISTS; its inverse is delete-then-restore.
    private func registerCollectionExistsUndo(
        _ undoManager: UndoManager?, actionName: String, id: String
    ) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { [weak undoManager] target in
            MainActor.assumeIsolated {
                guard let snapshot = target.applyDeleteCollection(id: id) else { return }
                target.registerCollectionDeletedUndo(
                    undoManager, actionName: actionName, snapshot: snapshot)
            }
        }
        undoManager.setActionName(actionName)
    }

    /// The collection is currently DELETED; its inverse is restore-then-delete.
    private func registerCollectionDeletedUndo(
        _ undoManager: UndoManager?, actionName: String, snapshot: SharedDeletedCollection
    ) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { [weak undoManager] target in
            MainActor.assumeIsolated {
                guard let row = target.applyRestoreCollection(snapshot: snapshot) else { return }
                target.registerCollectionExistsUndo(
                    undoManager, actionName: actionName, id: row.id)
            }
        }
        undoManager.setActionName(actionName)
    }

    // MARK: Membership

    /// File manuscripts into a folder. Returns the ids that ACTUALLY became
    /// members, so undoing never unfiles something that was already there.
    @discardableResult
    public func addToCollection(
        manuscriptIDs: [UUID], collectionID: UUID, undoManager: UndoManager? = nil
    ) -> [UUID] {
        let collection = Self.lower(collectionID)
        let ids = manuscriptIDs.map(Self.lower)
        guard let changed = applyAddMembers(collectionID: collection, itemIDs: ids),
              !changed.isEmpty
        else { return [] }
        registerMembershipUndo(
            undoManager, collectionID: collection, itemIDs: changed, wasAdd: true)
        return changed.compactMap(UUID.init(uuidString:))
    }

    /// Remove manuscripts from a folder without touching the manuscripts.
    /// Returns the ids that were actually removed.
    @discardableResult
    public func removeFromCollection(
        manuscriptIDs: [UUID], collectionID: UUID, undoManager: UndoManager? = nil
    ) -> [UUID] {
        let collection = Self.lower(collectionID)
        let ids = manuscriptIDs.map(Self.lower)
        guard let changed = applyRemoveMembers(collectionID: collection, itemIDs: ids),
              !changed.isEmpty
        else { return [] }
        registerMembershipUndo(
            undoManager, collectionID: collection, itemIDs: changed, wasAdd: false)
        return changed.compactMap(UUID.init(uuidString:))
    }

    private func registerMembershipUndo(
        _ undoManager: UndoManager?, collectionID: String, itemIDs: [String], wasAdd: Bool
    ) {
        let add: @MainActor (ManuscriptStoreAdapter) -> Void = {
            _ = $0.applyAddMembers(collectionID: collectionID, itemIDs: itemIDs)
        }
        let remove: @MainActor (ManuscriptStoreAdapter) -> Void = {
            _ = $0.applyRemoveMembers(collectionID: collectionID, itemIDs: itemIDs)
        }
        registerReversible(
            undoManager,
            actionName: wasAdd ? UndoActionName.addMembers : UndoActionName.removeMembers,
            undo: wasAdd ? remove : add,
            redo: wasAdd ? add : remove
        )
    }

    // MARK: Raw kernel verbs (event-posting, NOT undo-registering)

    @discardableResult
    fileprivate func applyRenameCollection(
        id: String, to name: String
    ) -> SharedCollectionMutation? {
        do {
            let mutation = try sharedStore.collectionRename(
                binding: Self.binding, id: id, name: name)
            didMutate(
                structural: false,
                affectedIDs: UUID(uuidString: id).map { [$0] },
                kind: .otherField)
            return mutation
        } catch {
            Logger.sharedStore.error(
                "collectionRename(\(id)) failed: \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    fileprivate func applyReparentCollection(
        id: String, newParentID: String?
    ) -> SharedCollectionMutation? {
        do {
            let mutation = try sharedStore.collectionReparent(
                binding: Self.binding, id: id, newParentId: newParentID)
            didMutate(structural: true)
            return mutation
        } catch {
            // The kernel's cycle check is the backstop behind any Swift-side
            // drag pre-check; a rejection means the two disagreed.
            let target = newParentID ?? "root"
            Logger.sharedStore.error(
                "collectionReparent(\(id) → \(target)) rejected: \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    fileprivate func applyDeleteCollection(id: String) -> SharedDeletedCollection? {
        do {
            let snapshot = try sharedStore.collectionDelete(binding: Self.binding, id: id)
            didMutate(structural: true)
            Logger.sharedStore.infoCapture(
                "Deleted manuscript collection \(id) "
                    + "(members unfiled: \(snapshot.memberIds.count), "
                    + "children re-rooted: \(snapshot.childCollectionIds.count))",
                category: "manuscript-store")
            return snapshot
        } catch {
            Logger.sharedStore.error(
                "collectionDelete(\(id)) failed: \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    fileprivate func applyRestoreCollection(
        snapshot: SharedDeletedCollection
    ) -> SharedCollectionRow? {
        do {
            let row = try sharedStore.collectionRestore(
                binding: Self.binding, snapshot: snapshot)
            didMutate(structural: true)
            return row
        } catch {
            Logger.sharedStore.error(
                "collectionRestore(\(snapshot.row.id)) failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Ids that ACTUALLY became members (`nil` = the verb failed / was refused).
    @discardableResult
    fileprivate func applyAddMembers(collectionID: String, itemIDs: [String]) -> [String]? {
        guard !itemIDs.isEmpty else { return nil }
        do {
            let changed = try sharedStore.collectionAddMembers(
                binding: Self.binding, collectionId: collectionID, itemIds: itemIDs)
            didMutate(structural: true)
            return changed
        } catch {
            Logger.sharedStore.error(
                "collectionAddMembers failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Ids that were ACTUALLY removed (`nil` = the verb failed).
    @discardableResult
    fileprivate func applyRemoveMembers(collectionID: String, itemIDs: [String]) -> [String]? {
        guard !itemIDs.isEmpty else { return nil }
        do {
            let changed = try sharedStore.collectionRemoveMembers(
                binding: Self.binding, collectionId: collectionID, itemIds: itemIDs)
            didMutate(structural: true)
            return changed
        } catch {
            Logger.sharedStore.error(
                "collectionRemoveMembers failed: \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - Triage
//
// The store side is schema-agnostic (star/flag/tag live on the item
// envelope; dismiss/restore/archive are payload `status` writes), which is
// why PMC can serve every kind from one `RecordTriageActions.storeBacked`.
// This is imprint's cross-platform twin of that, with two differences: the
// undo manager is injected rather than a macOS singleton, and every status
// string comes from the descriptor.

extension ManuscriptStoreAdapter {

    /// Star / unstar. The inverse restores each item's PRIOR value, so
    /// undoing a mixed selection does not flatten it.
    public func setStarred(
        ids: [UUID], starred: Bool, undoManager: UndoManager? = nil
    ) {
        let priors = ids.reduce(into: [UUID: Bool]()) { acc, id in
            acc[id] = (try? sharedStore.getItem(id: Self.lower(id)))??.isStarred ?? !starred
        }
        let next = ids.reduce(into: [UUID: Bool]()) { $0[$1] = starred }
        applyStarred(next)
        registerReversible(
            undoManager,
            actionName: UndoActionName.star,
            undo: { $0.applyStarred(priors) },
            redo: { $0.applyStarred(next) }
        )
    }

    /// Set (or clear, with `nil`) the flag colour.
    public func setFlag(
        ids: [UUID], color: String?, undoManager: UndoManager? = nil
    ) {
        var priors: [UUID: String?] = [:]
        for id in ids {
            priors[id] = (try? sharedStore.getItem(id: Self.lower(id)))??.flagColor
        }
        let next = ids.reduce(into: [UUID: String?]()) { $0[$1] = color }
        applyFlag(next)
        registerReversible(
            undoManager,
            actionName: UndoActionName.flag,
            undo: { $0.applyFlag(priors) },
            redo: { $0.applyFlag(next) }
        )
    }

    /// Add a tag path. The inverse removes it only from the items that did
    /// not already carry it.
    public func addTag(ids: [UUID], tagPath: String, undoManager: UndoManager? = nil) {
        let changed = ids.filter { id in
            let tags = (try? sharedStore.getItem(id: Self.lower(id)))??.tags ?? []
            return !tags.contains(tagPath)
        }
        guard !changed.isEmpty else { return }
        applyTag(changed, tagPath: tagPath, add: true)
        registerReversible(
            undoManager,
            actionName: UndoActionName.addTag,
            undo: { $0.applyTag(changed, tagPath: tagPath, add: false) },
            redo: { $0.applyTag(changed, tagPath: tagPath, add: true) }
        )
    }

    /// Remove a tag path, inverse-adding it back only where it was present.
    public func removeTag(ids: [UUID], tagPath: String, undoManager: UndoManager? = nil) {
        let changed = ids.filter { id in
            let tags = (try? sharedStore.getItem(id: Self.lower(id)))??.tags ?? []
            return tags.contains(tagPath)
        }
        guard !changed.isEmpty else { return }
        applyTag(changed, tagPath: tagPath, add: false)
        registerReversible(
            undoManager,
            actionName: UndoActionName.removeTag,
            undo: { $0.applyTag(changed, tagPath: tagPath, add: true) },
            redo: { $0.applyTag(changed, tagPath: tagPath, add: false) }
        )
    }

    /// Sweep manuscripts out of the working set. The status value and the
    /// action are the DESCRIPTOR's `DismissalSemantics.statusChange`; a kind
    /// that declares `.none` is a no-op here rather than a silent wrong write.
    @discardableResult
    public func dismiss(ids: [UUID], undoManager: UndoManager? = nil) -> Bool {
        guard let dismissed = Self.dismissedStatus else { return false }
        return setStatus(
            ids: ids, to: dismissed,
            actionName: UndoActionName.dismiss, undoManager: undoManager)
    }

    /// Return dismissed manuscripts to the descriptor's restore status
    /// (`draft`) — not to whatever they held before, which is what the
    /// declared contract says and what the macOS grammar does.
    @discardableResult
    public func restore(ids: [UUID], undoManager: UndoManager? = nil) -> Bool {
        guard let restoreTo = Self.restoreStatus else { return false }
        return setStatus(
            ids: ids, to: restoreTo,
            actionName: UndoActionName.restore, undoManager: undoManager)
    }

    /// Move to the deliberate end-state (`archived`), when the kind declares
    /// an `archiveStatus`.
    @discardableResult
    public func archive(ids: [UUID], undoManager: UndoManager? = nil) -> Bool {
        guard let archived = Self.archivedStatus else { return false }
        return setStatus(
            ids: ids, to: archived,
            actionName: UndoActionName.archive, undoManager: undoManager)
    }

    /// Free-form status write, validated against the descriptor's declared
    /// lifecycle. A status the kind never declares is refused rather than
    /// written — the schema has no validation, so this is the only gate.
    @discardableResult
    public func setStatus(
        ids: [UUID], to status: String,
        actionName: String? = nil,
        undoManager: UndoManager? = nil
    ) -> Bool {
        let declared = Self.descriptor.triage.statuses
        guard declared.isEmpty || declared.contains(status) else {
            Logger.sharedStore.error(
                "setStatus refused undeclared status '\(status)' for manuscript")
            return false
        }
        var priors: [UUID: String] = [:]
        for id in ids {
            priors[id] = manuscript(id: id)?.status ?? Self.restoreStatus ?? status
        }
        let next = ids.reduce(into: [UUID: String]()) { $0[$1] = status }
        applyStatus(next)
        Logger.sharedStore.infoCapture(
            "status → '\(status)' for \(ids.count) manuscript(s)",
            category: "manuscript-store")
        registerReversible(
            undoManager,
            actionName: actionName ?? "Change Status",
            undo: { $0.applyStatus(priors) },
            redo: { $0.applyStatus(next) }
        )
        return true
    }

    // MARK: Raw triage verbs (event-posting, NOT undo-registering)

    fileprivate func applyStarred(_ states: [UUID: Bool]) {
        for (id, value) in states {
            try? sharedStore.setStarred(id: Self.lower(id), isStarred: value)
        }
        didMutate(structural: false, affectedIDs: Set(states.keys), kind: .otherField)
    }

    fileprivate func applyFlag(_ states: [UUID: String?]) {
        for (id, value) in states {
            try? sharedStore.setFlag(
                id: Self.lower(id), color: value, style: nil, length: nil)
        }
        didMutate(structural: false, affectedIDs: Set(states.keys), kind: .otherField)
    }

    fileprivate func applyTag(_ ids: [UUID], tagPath: String, add: Bool) {
        for id in ids {
            if add {
                try? sharedStore.addTag(id: Self.lower(id), tag: tagPath)
            } else {
                try? sharedStore.removeTag(id: Self.lower(id), tag: tagPath)
            }
        }
        didMutate(structural: false, affectedIDs: Set(ids), kind: .otherField)
    }

    fileprivate func applyStatus(_ states: [UUID: String]) {
        for (id, status) in states {
            guard let json = try? Self.encodeJSON(["status": status]) else { continue }
            try? sharedStore.upsertItem(
                id: id.uuidString,
                schemaRef: Self.manuscriptSchemaRef,
                payloadJson: json
            )
        }
        // Structural: a dismissed manuscript LEAVES every unscoped list, so a
        // field-only refresh would leave a stale row on screen.
        didMutate(structural: true, affectedIDs: Set(states.keys), kind: .otherField)
    }
}

// MARK: - Search

extension ManuscriptStoreAdapter {

    /// Full-text search across manuscripts (`items_fts`), newest-relevance
    /// first. Dismissed manuscripts are excluded, exactly as they are from an
    /// unscoped list — search is a listing surface, not an index read.
    public func searchManuscripts(
        query: String,
        limit: UInt32 = ManuscriptStoreAdapter.defaultPageLimit,
        includeDismissed: Bool = false
    ) -> [ManuscriptModel] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return listManuscripts(limit: limit)
        }
        do {
            let rows = try sharedStore.search(
                query: trimmed,
                schemaFilter: Self.manuscriptSchemaRef,
                limit: limit
            )
            let models = rows.compactMap { try? Self.decode(row: $0) }
            guard !includeDismissed, let dismissed = Self.dismissedStatus else { return models }
            return models.filter { $0.status != dismissed }
        } catch {
            Logger.sharedStore.error(
                "searchManuscripts failed: \(error.localizedDescription)")
            return []
        }
    }
}
