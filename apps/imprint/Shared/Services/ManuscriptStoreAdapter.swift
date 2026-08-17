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
// `UITestingEnvironment` (the ONE scratch-database path every handle in a
// UI-testing process shares — see `shared`).
import PublicationManagerCore

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

    /// The raw `external_source` JSON, or nil for an ordinary manuscript
    /// (ADR-0023 D4). Decoded on demand by `ManuscriptModel.externalSource` in
    /// `ManuscriptStoreAdapter+External.swift`; carried raw here so a read that
    /// never asks the question pays nothing for it, which matters because
    /// EVERY list read decodes every row.
    public let externalSourceJSON: String?

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

    init?(_ row: CollectionKernelRow) {
        guard let id = UUID(uuidString: row.id) else { return nil }
        self.id = id
        self.name = row.name
        self.parentID = row.parentID.flatMap(UUID.init(uuidString:))
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
    /// Every manuscript carrying one tag path (ADR-0023 W3).
    ///
    /// The scope a watched folder's row resolves to, reusing W2's answer
    /// verbatim: a folder's records ARE its provenance tag
    /// (`watched/<folder name>`), so the folder row needs no new store concept
    /// — no per-folder collection, no new query, no second membership truth.
    /// A tag is also what the user can already see, remove and re-apply.
    case tag(String)

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
            // ADR-0023 W3: under UI testing this opens the ONE scratch FILE
            // every other handle in the process opens, not `openInMemory()`.
            //
            // Two `openInMemory()` calls are two DATABASES, not two handles on
            // one — the "imprint seed lesson" `RustStoreAdapter.init(inMemory:)`
            // names, and the provenance bug W2 fixed on the imbib side. It
            // matters here because attribution is a CROSS-HANDLE claim: the
            // watched-folder kernel refuses to record that a file produced a
            // manuscript row it cannot see, and `WatchedFolderStoreAdapter`
            // already opens the scratch file. The path is keyed by process id,
            // so each launch still gets a fresh, hermetic database — the
            // property `openInMemory()` was chosen for is kept, and the one it
            // accidentally also had (isolation from the app's OTHER adapter) is
            // exactly what had to go.
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                UITestingEnvironment.prepareScratchDatabaseDirectory()
                return try ManuscriptStoreAdapter(
                    path: UITestingEnvironment.scratchDatabasePath)
            }
            return try ManuscriptStoreAdapter(inMemory: false)
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

    /// `listTags()`'s memo, invalidated by `dataVersion`. Not `@Observable`
    /// state: it is a cache OF observable state, and publishing it would make
    /// reading the tag list re-render every view that reads the adapter.
    @ObservationIgnored private var cachedTagPaths: [String]?
    @ObservationIgnored private var cachedTagPathsVersion: Int = -1

    // MARK: - The generic store kernels

    @ObservationIgnored private var cachedCollectionKernel: CollectionStoreAdapter?

    /// PMC's collection kernel (`CollectionStoreAdapter`), bound to THIS
    /// adapter's store handle, mutation fan-out and undo target. Built once and
    /// held, because `UndoManager.removeAllActions(withTarget:)` keys on the
    /// target and the kernel's `apply*` closures capture it weakly.
    var collectionKernel: CollectionStoreAdapter {
        if let cachedCollectionKernel { return cachedCollectionKernel }
        let kernel = CollectionStoreAdapter(scope: kernelScope())
        cachedCollectionKernel = kernel
        return kernel
    }

    /// PMC's triage kernel, on the same scope. A struct, so it is built per call
    /// rather than held.
    var triageKernel: RecordTriageStoreKernel {
        RecordTriageStoreKernel(
            descriptor: Self.descriptor,
            scope: kernelScope(),
            schemaRef: Self.manuscriptSchemaRef)
    }

    /// The three host hooks PMC's generic kernels run on inside imprint: this
    /// adapter's own `SharedStore` handle (never imbib's `RustStoreAdapter`,
    /// which would boot a SECOND store facade in-process), its `didMutate` fan-out
    /// (so batching, `dataVersion` and `ImprintImpressStore.postMutation` keep
    /// working unchanged), and this adapter as the undo target — which is what
    /// the hand-rolled `registerReversible` registered against, and what
    /// `removeAllActions(withTarget:)` keys on.
    private func kernelScope() -> StoreKernelScope {
        StoreKernelScope(
            store: sharedStore,
            undoTarget: self,
            defaultUndo: .disabled,
            noteMutation: { [weak self] structural, affectedIDs, kind in
                self?.didMutate(structural: structural, affectedIDs: affectedIDs, kind: kind)
            }
        )
    }

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
    /// A handle on ONE named database file — the UI-testing lane (see
    /// `shared`). Separate from `init(inMemory:)` because "a file that is not
    /// the workspace's" is a third case, and folding it into a Bool would make
    /// the call site read as its opposite.
    private nonisolated init(path: String) throws {
        self.sharedStore = try SharedStore.open(path: path)
        Logger.sharedStore.infoCapture(
            "ManuscriptStoreAdapter initialized (scratch file: \(path))",
            category: "manuscript-store")
    }

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

    /// `didMutate` for the reference-in-place verbs, which live in
    /// `ManuscriptStoreAdapter+External.swift` because they are ADR-0023's
    /// surface and not the CRUD surface. An extension cannot reach a private
    /// method; this is the one line of access it needs, and it is narrow on
    /// purpose — an external write is never a metadata edit and never a body
    /// edit, it is a re-read.
    func noteExternalMutation(id: UUID, structural: Bool) {
        didMutate(structural: structural, affectedIDs: [id], kind: .otherField)
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

    /// Update a manuscript's body content — through the collaborative
    /// document (ADR-0027 D6), never as a raw payload write: an unknown-base
    /// commit diffs `text` against the current document and merges, and the
    /// kernel rewrites `body_content` / hash / `body_modified_at` itself.
    /// Callers that track heads should use `commitBody` and adopt its outcome.
    public func setBody(id: UUID, text: String) throws {
        _ = try commitBody(id: id, text: text, baseHeads: [])
    }

    /// Commit `text` against the heads this editor last saw and return the
    /// MERGED body + the heads to pin next (`mergedExternal` = adopt `body`).
    @discardableResult
    public func commitBody(
        id: UUID, text: String, baseHeads: [String]
    ) throws -> SharedManuscriptCommitOutcome {
        let outcome = try sharedStore.commitManuscriptBody(
            id: id.uuidString, baseHeads: baseHeads, body: text, author: "user:local")
        didMutate(structural: false, affectedIDs: [id], kind: .otherField)
        return outcome
    }

    /// The document's current heads — an editor's first commit base.
    public func collabHeads(id: UUID) -> [String] {
        (try? sharedStore.manuscriptCollabHeads(id: id.uuidString)) ?? []
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
            // Tags live on the ENVELOPE (`row.tags`), not the payload, so this
            // is a post-filter rather than a `payloadEq` — the same shape the
            // flag filter above already takes, for the same reason.
            if case .tag(let path) = scope {
                // DESCENDANT-INCLUSIVE, through the chassis's one authority:
                // selecting `reading` must list `reading/queue` too, or every
                // interior row of the Tags tree reads as empty while its
                // children show rows. `contains(path)` was exact — invisible
                // while the only constructor was a watched folder's leaf tag
                // (ADR-0023 W3), wrong the moment a tree could select a parent.
                guard TagPathMatch.anyMatches(model.tags, scopePath: path) else { return false }
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

    /// `"manuscript@1.2.0"` → `"manuscript"`, via PMC's ONE implementation
    /// (`RecordKindSchemaRef.baseName`, re-exported in
    /// PMCManuscriptReexports.swift). This used to be a local copy "so this
    /// file needs no PMC import" — a justification that expired the moment the
    /// adapter started reading `ManuscriptRecordKind.descriptor` for its schema
    /// ref and status lifecycle.
    static func baseSchemaRef(_ schemaRef: String) -> String {
        RecordKindSchemaRef.baseName(schemaRef)
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
            externalSourceJSON: payload["external_source"] as? String,
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

    // The descriptor-binding-id → `SharedCollectionBinding` map used to be
    // duplicated here, next to a comment calling itself "the only two places in
    // Swift that know a `SharedCollectionBinding` exists". Stage 4b made that
    // one place: `CollectionStoreAdapter.binding(for:)`, which this adapter now
    // reaches through `collectionKernel` by passing `collectionBindingID`.
}

// MARK: - The generic store kernels, READ (not retyped)
//
// Stage 4b. Everything between here and the search section used to be a
// hand-rolled second implementation of two PMC kernels — `CollectionStoreAdapter`
// (already kind-generic over `CollectionBindingID`) and the store half of the
// shared triage grammar. This file's own comments admitted it: "Mirrors
// `CollectionStoreAdapter`'s three rules (ADR-0022 G2)", "This is imprint's
// cross-platform twin of that".
//
// The SOLE reason the copy existed was that both kernels named imbib's
// singletons: `RustStoreAdapter.shared` for the mutation fan-out (reaching it
// from imprint boots a SECOND store facade in-process) and `UndoCoordinator.shared`
// for undo (which re-pins the code to macOS). `StoreKernelScope` makes those two
// facts plus the store handle injectable, so what survives here is only the
// imprint-SHAPED surface over the shared verbs:
//
//   * `UUID` in, `UUID` out, instead of the kernel's lowercase id strings;
//   * `ManuscriptCollection` instead of `CollectionKernelRow`;
//   * a per-call `UndoManager?` instead of a `StoreUndoScope`, because that is
//     what imprint's views pass (iOS: `SceneUndoManager.shared.manager`).
//
// Rule 3 of `CollectionStoreAdapter`'s header still holds, it just holds inside
// the kernel now: the raw verbs post the mutation event and register nothing,
// the public verbs register the inverse, and undo/redo closures call the raw
// verbs — so one ⌘Z never needs two ⌘⇧Z.

extension ManuscriptStoreAdapter {

    /// Undo action names, READ from the kernels that register them rather than
    /// restated. Same strings as before Stage 4b, so imprint's Edit menu reads
    /// identically; `StoreKernelUndoActionNamesTests` pins them.
    public enum UndoActionName {
        public static let createCollection = StoreKernelUndoAction.createCollection
        public static let renameCollection = StoreKernelUndoAction.renameCollection
        public static let reparentCollection = StoreKernelUndoAction.reparentCollection
        public static let deleteCollection = StoreKernelUndoAction.deleteCollection
        public static let addMembers = StoreKernelUndoAction.addMembers
        public static let removeMembers = StoreKernelUndoAction.removeMembers
        public static let star = StoreKernelUndoAction.star
        public static let flag = StoreKernelUndoAction.flag
        public static let addTag = StoreKernelUndoAction.addTag
        public static let removeTag = StoreKernelUndoAction.removeTag
        public static let dismiss = StoreKernelUndoAction.dismiss
        public static let restore = StoreKernelUndoAction.restore
        public static let archive = StoreKernelUndoAction.archive
    }

    /// A caller-supplied `UndoManager` as the kernels' undo scope.
    private static func undoScope(_ undoManager: UndoManager?) -> StoreUndoScope {
        .manager(undoManager)
    }
}

// MARK: - Collections, through the ADR-0022 kernel

extension ManuscriptStoreAdapter {

    /// The kernel binding id this kind organises through — the descriptor's.
    private var bindingID: String { Self.collectionBindingID }

    // MARK: Reads

    /// Every manuscript folder, flat and ordered by `sort_order`. Callers
    /// assemble the tree from `parentID`.
    public func listCollections() -> [ManuscriptCollection] {
        collectionKernel.tree(bindingID).compactMap(ManuscriptCollection.init)
    }

    /// Member counts aligned index-for-index with `collectionIDs`.
    public func collectionMemberCounts(collectionIDs: [UUID]) -> [Int] {
        collectionKernel.memberCounts(
            bindingID, collectionIDs: collectionIDs.map { $0.uuidString.lowercased() })
    }

    // MARK: Structure

    /// Create a manuscript folder under `parentID` (nil = root).
    ///
    /// `isWorkspace` is not a kernel concept; when set it is written as an
    /// additive follow-up field, so the flag survives without the structure
    /// leaving the kernel. The schema is read back off the row the KERNEL just
    /// wrote rather than naming `manuscript-collection`: WP G7 converges this
    /// binding onto `collection@1.0.0`, and a literal here would start writing a
    /// second item under the old schema the day it flips.
    @discardableResult
    public func createCollection(
        name: String,
        parentID: UUID? = nil,
        isWorkspace: Bool = false,
        undoManager: UndoManager? = nil
    ) throws -> UUID {
        guard let row = collectionKernel.create(
            bindingID,
            name: name,
            parentID: parentID?.uuidString.lowercased(),
            undo: Self.undoScope(undoManager)
        ) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "collection_create failed for '\(name)'")
            )
        }
        if isWorkspace {
            let schemaRef = (try? sharedStore.getItem(id: row.id))??.schemaRef
                ?? "manuscript-collection"
            try sharedStore.upsertItem(
                id: row.id,
                schemaRef: schemaRef,
                payloadJson: Self.encodeJSON(["is_workspace": true])
            )
        }
        guard let id = UUID(uuidString: row.id) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "kernel returned invalid id \(row.id)")
            )
        }
        return id
    }

    /// Rename a folder. The kernel's `prior` carries the previous name, so the
    /// inverse is exact — no racy re-read.
    @discardableResult
    public func renameCollection(
        id: UUID, to name: String, undoManager: UndoManager? = nil
    ) -> Bool {
        collectionKernel.rename(
            bindingID, id: id.uuidString.lowercased(), to: name,
            undo: Self.undoScope(undoManager))
    }

    /// Move a folder under `newParentID` (nil = make it a root). The cycle
    /// check is the KERNEL's; a rejection is logged and returns `false`.
    @discardableResult
    public func reparentCollection(
        id: UUID, newParentID: UUID?, undoManager: UndoManager? = nil
    ) -> Bool {
        collectionKernel.reparent(
            bindingID,
            id: id.uuidString.lowercased(),
            newParentID: newParentID?.uuidString.lowercased(),
            undo: Self.undoScope(undoManager))
    }

    /// Delete a folder. Members are never deleted — `Contains` edges vanish
    /// with the row. `collection_delete` returns the full snapshot (original
    /// id, envelope parent, dropped members, orphaned children) and
    /// `collection_restore` puts all of it back, so undo is lossless.
    @discardableResult
    public func deleteCollection(id: UUID, undoManager: UndoManager? = nil) -> Bool {
        collectionKernel.delete(
            bindingID, id: id.uuidString.lowercased(), undo: Self.undoScope(undoManager))
    }

    // MARK: Membership

    /// File manuscripts into a folder. Returns the ids that ACTUALLY became
    /// members, so undoing never unfiles something that was already there.
    @discardableResult
    public func addToCollection(
        manuscriptIDs: [UUID], collectionID: UUID, undoManager: UndoManager? = nil
    ) -> [UUID] {
        let changed = collectionKernel.addMembersReportingChanges(
            bindingID,
            collectionID: collectionID.uuidString.lowercased(),
            itemIDs: manuscriptIDs.map { $0.uuidString.lowercased() },
            undo: Self.undoScope(undoManager)) ?? []
        return changed.compactMap(UUID.init(uuidString:))
    }

    /// Remove manuscripts from a folder without touching the manuscripts.
    /// Returns the ids that were actually removed.
    @discardableResult
    public func removeFromCollection(
        manuscriptIDs: [UUID], collectionID: UUID, undoManager: UndoManager? = nil
    ) -> [UUID] {
        let changed = collectionKernel.removeMembersReportingChanges(
            bindingID,
            collectionID: collectionID.uuidString.lowercased(),
            itemIDs: manuscriptIDs.map { $0.uuidString.lowercased() },
            undo: Self.undoScope(undoManager)) ?? []
        return changed.compactMap(UUID.init(uuidString:))
    }
}

// MARK: - Triage, through the shared kernel

extension ManuscriptStoreAdapter {

    /// Star / unstar. The inverse restores each item's PRIOR value, so
    /// undoing a mixed selection does not flatten it.
    public func setStarred(ids: [UUID], starred: Bool, undoManager: UndoManager? = nil) {
        triageKernel.setStarred(
            ids: ids, starred: starred, undo: Self.undoScope(undoManager))
    }

    /// Set (or clear, with `nil`) the flag colour.
    public func setFlag(ids: [UUID], color: String?, undoManager: UndoManager? = nil) {
        triageKernel.setFlag(ids: ids, color: color, undo: Self.undoScope(undoManager))
    }

    /// Every tag path in use on a manuscript, sorted, de-duplicated.
    ///
    /// The derivation is the kernel's (`tagPathsInUse`, which walks the kind's
    /// own rows because there is no tag-listing FFI verb — see its doc comment);
    /// the memo is imprint's, keyed on `dataVersion` so opening a context menu
    /// does not re-walk the store on every render pass.
    public func listTags() -> [String] {
        if let cached = cachedTagPaths, cachedTagPathsVersion == dataVersion {
            return cached
        }
        let paths = triageKernel.tagPathsInUse(pageSize: Self.defaultPageLimit)
        cachedTagPaths = paths
        cachedTagPathsVersion = dataVersion
        return paths
    }

    /// Add a tag path. The inverse removes it only from the items that did
    /// not already carry it.
    public func addTag(ids: [UUID], tagPath: String, undoManager: UndoManager? = nil) {
        triageKernel.addTag(ids: ids, tagPath: tagPath, undo: Self.undoScope(undoManager))
    }

    /// Remove a tag path, inverse-adding it back only where it was present.
    public func removeTag(ids: [UUID], tagPath: String, undoManager: UndoManager? = nil) {
        triageKernel.removeTag(ids: ids, tagPath: tagPath, undo: Self.undoScope(undoManager))
    }

    /// Sweep manuscripts out of the working set. The status value and the
    /// action are the DESCRIPTOR's `DismissalSemantics.statusChange`; a kind
    /// that declares `.none` is a no-op here rather than a silent wrong write.
    @discardableResult
    public func dismiss(ids: [UUID], undoManager: UndoManager? = nil) -> Bool {
        triageKernel.dismiss(ids: ids, undo: Self.undoScope(undoManager))
    }

    /// Return dismissed manuscripts to the descriptor's restore status
    /// (`draft`) — not to whatever they held before, which is what the
    /// declared contract says and what the macOS grammar does.
    @discardableResult
    public func restore(ids: [UUID], undoManager: UndoManager? = nil) -> Bool {
        triageKernel.restore(ids: ids, undo: Self.undoScope(undoManager))
    }

    /// Move to the deliberate end-state (`archived`), when the kind declares
    /// an `archiveStatus`.
    @discardableResult
    public func archive(ids: [UUID], undoManager: UndoManager? = nil) -> Bool {
        triageKernel.archive(ids: ids, undo: Self.undoScope(undoManager))
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
        triageKernel.setStatus(
            ids: ids, to: status, actionName: actionName,
            undo: Self.undoScope(undoManager))
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
