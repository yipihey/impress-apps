//
//  ManuscriptBridge.swift
//  PublicationManagerCore
//
//  Phase 2 of the impress journal pipeline (per docs/plan-journal-pipeline.md
//  §3.2 + ADR-0011 D1/D3/D6).
//
//  Read-and-write actor for the journal item types in the unified
//  impress-core SQLite store. Mirrors the `CitationUsageReader` pattern:
//  opens its own `SharedStore` handle on the shared workspace SQLite
//  (WAL mode permits concurrent readers/writers across processes and
//  across handles within a process).
//
//  Why this lives here and not in `RustStoreAdapter`:
//  RustStoreAdapter's underlying `ImbibStore` (UniFFI) only exposes
//  publication-typed operations. The journal pipeline writes
//  `manuscript@1.0.0`, `manuscript-revision@1.0.0`, and
//  `manuscript-submission@1.0.0` items — none of which `ImbibStore`
//  knows about. ManuscriptBridge is the imbib-side companion to impel's
//  `JournalSubmissionService`, both writing to the same shared SQLite.
//
//  Per Tom's Phase 2 UX decisions (2026-05-05):
//  - "New Manuscript" creates only the manuscript@1.0.0 item; no imprint
//    document yet (avoids orphan .imprint packages).
//  - "Open in imprint" lazily fires `imprint://create?title=...` on first
//    click for an unbridged manuscript, then writes the bridge edge in
//    the response handler. Subsequent clicks fire `imprint://open?...`.
//  - Accept on a Scout-proposed submission creates the manuscript item
//    (defers compile to Phase 3 when Archivist exists). Submission state
//    advances to `accepted`; the placeholder current_revision_ref is the
//    all-zero UUID until Archivist backfills the real revision.
//

import Foundation
import ImpressKit
import ImpressLogging
import ImpressRustCore
import OSLog

private let bridgeLog = Logger(subsystem: "com.imbib.app", category: "manuscript-bridge")

/// All-zero UUID used as a placeholder `current_revision_ref` when a
/// manuscript exists but its first revision hasn't been snapshotted yet.
/// Phase 3's Archivist replaces this with a real revision item ID.
public let JournalRevisionPlaceholderID: String = "00000000-0000-0000-0000-000000000000"

/// Schema string for journal manuscripts. Centralized so both `ManuscriptBridge`
/// and external query callers reference the same constant.
public enum JournalSchema {
    public static let manuscript          = "manuscript"
    public static let manuscriptRevision  = "manuscript-revision"
    public static let manuscriptSubmission = "manuscript-submission"
    public static let review              = "review"
    public static let revisionNote        = "revision-note"
}

// MARK: - Errors

public enum ManuscriptBridgeError: Error, LocalizedError {
    case storeUnavailable
    case notFound(String)
    case invalidPayload(String)
    case writeFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .storeUnavailable:
            return "Shared impress-core store is not available"
        case .notFound(let id):
            return "Item not found: \(id)"
        case .invalidPayload(let msg):
            return "Invalid manuscript payload: \(msg)"
        case .writeFailed(let err):
            return "Write to shared store failed: \(err.localizedDescription)"
        }
    }
}

// MARK: - ManuscriptBridge

/// Owns a SharedStore handle for journal-pipeline reads and writes.
public actor ManuscriptBridge {

    public static let shared = ManuscriptBridge()

    private var store: SharedStore?
    private var openAttempted = false

    public init() {}

    /// Test seam: open against a specific path (e.g., a temp dir for unit tests).
    public init(testStorePath: String) throws {
        let s = try SharedStore.open(path: testStorePath)
        self.store = s
        self.openAttempted = true
    }

    // MARK: - Manuscripts (read)

    /// List manuscripts, optionally filtered by status. Newest first.
    public func listManuscripts(status: JournalManuscriptStatus? = nil, limit: Int = 1000) -> [JournalManuscript] {
        guard let store = handle() else { return [] }
        do {
            let rows = try store.queryBySchema(
                schemaRef: JournalSchema.manuscript,
                limit: UInt32(max(0, limit)),
                offset: 0
            )
            return rows.compactMap { row in
                guard let m = JournalManuscript.decode(itemID: row.id, payloadJSON: row.payloadJson) else {
                    return nil
                }
                if let status, m.status != status { return nil }
                return m
            }
        } catch {
            bridgeLog.errorCapture(
                "listManuscripts failed: \(error.localizedDescription)",
                category: "manuscript-bridge"
            )
            return []
        }
    }

    /// Fetch a single manuscript by ID, or nil if missing.
    public func getManuscript(id: String) -> JournalManuscript? {
        guard let store = handle() else { return nil }
        guard let row = try? store.getItem(id: id) else { return nil }
        return JournalManuscript.decode(itemID: row.id, payloadJSON: row.payloadJson)
    }

    // MARK: - Manuscripts (write)

    /// Create a brand-new manuscript with `status: .draft` and a placeholder
    /// `current_revision_ref`. No imprint document is created — the bridge
    /// edge stays empty until the user opens the manuscript in imprint
    /// (per Phase 2 UX decision).
    ///
    /// Returns the new manuscript's stable ID (lowercase UUID).
    @discardableResult
    public func createManuscript(title: String, topicTags: [String] = []) throws -> String {
        guard let store = handle() else { throw ManuscriptBridgeError.storeUnavailable }
        let id = UUID().uuidString.lowercased()

        var payload: [String: Any] = [
            "title": title,
            "status": JournalManuscriptStatus.draft.rawValue,
            "current_revision_ref": JournalRevisionPlaceholderID,
        ]
        if !topicTags.isEmpty { payload["topic_tags"] = topicTags }

        try writeItem(store: store, id: id, schema: JournalSchema.manuscript, payload: payload)
        bridgeLog.infoCapture(
            "Created manuscript \(id) — title=\"\(title.prefix(80))\"",
            category: "manuscript-bridge"
        )
        postChangeNotification(event: ImpressNotification.manuscriptStatusChanged, ids: [id])
        return id
    }

    /// Update a manuscript's lifecycle status. Per ADR-0011 D1 the status
    /// transitions are: draft → internal-review → submitted → in-revision
    /// → published → archived (and any can go to archived).
    public func setStatus(manuscriptID: String, status: JournalManuscriptStatus) throws {
        guard let store = handle() else { throw ManuscriptBridgeError.storeUnavailable }
        guard let row = try store.getItem(id: manuscriptID) else {
            throw ManuscriptBridgeError.notFound(manuscriptID)
        }
        var payload = try parsePayload(row.payloadJson)
        payload["status"] = status.rawValue
        try writeItem(store: store, id: manuscriptID, schema: JournalSchema.manuscript, payload: payload)
        postChangeNotification(event: ImpressNotification.manuscriptStatusChanged, ids: [manuscriptID])
    }

    // MARK: - imprint source bridge

    /// Add a `Contains` edge with `kind: "imprint-source"` metadata
    /// linking a manuscript to an imprint document. Called by the URL-scheme
    /// response handler after `imprint://create?...` returns.
    ///
    /// `SharedStore` doesn't currently expose typed-edge writes via UniFFI.
    /// For Phase 2 we encode the bridge as fields on the manuscript payload
    /// (`imprint_document_uuid`, `imprint_library_uuid`, `imprint_package_path`)
    /// — semantically equivalent to a Contains edge with structured metadata
    /// per ADR-0011 D3, queryable via the same item read.
    public func attachImprintSource(
        manuscriptID: String,
        documentUUID: String,
        libraryUUID: String,
        packagePath: String?
    ) throws {
        guard let store = handle() else { throw ManuscriptBridgeError.storeUnavailable }
        guard let row = try store.getItem(id: manuscriptID) else {
            throw ManuscriptBridgeError.notFound(manuscriptID)
        }
        var payload = try parsePayload(row.payloadJson)
        payload["imprint_document_uuid"] = documentUUID
        payload["imprint_library_uuid"]  = libraryUUID
        if let path = packagePath { payload["imprint_package_path"] = path }
        try writeItem(store: store, id: manuscriptID, schema: JournalSchema.manuscript, payload: payload)
        bridgeLog.infoCapture(
            "Attached imprint source: manuscript \(manuscriptID) → doc \(documentUUID)",
            category: "manuscript-bridge"
        )
    }

    /// Returns the imprint document UUID bridged to this manuscript, or nil
    /// if no bridge exists yet.
    public func imprintDocumentUUID(forManuscript id: String) -> String? {
        guard let m = getManuscriptPayloadDict(id: id) else { return nil }
        return m["imprint_document_uuid"] as? String
    }

    // MARK: - Submissions (read)

    /// All submissions in `pending` state, newest first. Used by the
    /// Submissions inbox UI.
    public func listPendingSubmissions(limit: Int = 200) -> [JournalSubmissionRecord] {
        guard let store = handle() else { return [] }
        do {
            let rows = try store.queryBySchema(
                schemaRef: JournalSchema.manuscriptSubmission,
                limit: UInt32(max(0, limit)),
                offset: 0
            )
            return rows.compactMap { row in
                guard let rec = JournalSubmissionRecord.decode(itemID: row.id, payloadJSON: row.payloadJson) else {
                    return nil
                }
                return rec.state == .pending ? rec : nil
            }
        } catch {
            bridgeLog.errorCapture(
                "listPendingSubmissions failed: \(error.localizedDescription)",
                category: "manuscript-bridge"
            )
            return []
        }
    }

    public func getSubmission(id: String) -> JournalSubmissionRecord? {
        guard let store = handle() else { return nil }
        guard let row = try? store.getItem(id: id) else { return nil }
        return JournalSubmissionRecord.decode(itemID: row.id, payloadJSON: row.payloadJson)
    }

    // MARK: - Revisions (read)

    /// All revisions for a manuscript, returned newest-first by created time.
    /// Phase 3 filters in-Swift by parent_manuscript_ref since SharedStore
    /// doesn't yet expose typed-edge queries via the FFI.
    public func listRevisions(manuscriptID: String, limit: Int = 200) -> [JournalRevision] {
        guard let store = handle() else { return [] }
        do {
            let rows = try store.queryBySchema(
                schemaRef: JournalSchema.manuscriptRevision,
                limit: UInt32(max(0, limit)),
                offset: 0
            )
            return rows.compactMap { row -> JournalRevision? in
                guard let rev = JournalRevision.decode(itemID: row.id, payloadJSON: row.payloadJson) else {
                    return nil
                }
                return rev.parentManuscriptRef == manuscriptID ? rev : nil
            }
        } catch {
            bridgeLog.errorCapture(
                "listRevisions(\(manuscriptID)) failed: \(error.localizedDescription)",
                category: "manuscript-bridge"
            )
            return []
        }
    }

    /// Fetch a single revision by ID, or nil if missing.
    public func getRevision(id: String) -> JournalRevision? {
        guard let store = handle() else { return nil }
        guard let row = try? store.getItem(id: id) else { return nil }
        return JournalRevision.decode(itemID: row.id, payloadJSON: row.payloadJson)
    }

    /// Resolve the on-disk PDF URL for a revision, or nil if the revision
    /// hasn't been compiled yet (Phase 6 / docs/plan-imprint-compile.md).
    ///
    /// Recognizes two `pdf_artifact_ref` formats:
    /// - `"blob:sha256:{hex}"` — Phase 6 compile output. Resolved through
    ///   the same content-addressed BlobStore tree both impel (writer) and
    ///   imbib (reader) use.
    /// - any other UUID-shaped string is treated as a placeholder (Phase 3
    ///   "deferred" state). Returns nil so callers can show a "compile
    ///   pending" UI affordance.
    public func getRevisionPDFURL(revisionID: String) -> URL? {
        guard let revision = getRevision(id: revisionID) else { return nil }
        let ref = revision.pdfArtifactRef
        let prefix = "blob:sha256:"
        guard ref.hasPrefix(prefix) else { return nil }
        let sha = String(ref.dropFirst(prefix.count))
        guard sha.count == 64 else { return nil }
        // BlobStore.locate is async-actor; reach into the on-disk path
        // computation directly (no async needed for a path lookup).
        return BlobStore.staticLocateOnDisk(sha256: sha, ext: "pdf")
    }

    /// Phase 8: resolve the on-disk URL of a revision's bundle archive
    /// (`.tar.zst`), or nil when the revision is not a bundle or the
    /// archive is missing from the local content-addressed store.
    ///
    /// `source_archive_ref` for Phase 8 bundles is a string of the form
    /// `"blob:sha256:<sha>.tar.zst"`. Phase 7-era inline-text revisions
    /// use the form `"blob:sha256:<sha>"` (no `.tar.zst` suffix); those
    /// return nil here — callers should check `JournalRevision.isBundle`.
    public func getRevisionBundleArchiveURL(revisionID: String) -> URL? {
        guard let revision = getRevision(id: revisionID), revision.isBundle else { return nil }
        let ref = revision.sourceArchiveRef
        let prefix = "blob:sha256:"
        guard ref.hasPrefix(prefix) else { return nil }
        var rest = String(ref.dropFirst(prefix.count))
        // Strip any trailing extension to recover the bare hash, then
        // probe for the .tar.zst on disk.
        if let dot = rest.firstIndex(of: ".") {
            rest = String(rest[..<dot])
        }
        guard rest.count == 64 else { return nil }
        return BlobStore.staticLocateOnDisk(sha256: rest, ext: "tar.zst")
    }

    /// Phase 8: list the bundle entries (path + role) for a revision.
    /// Returns nil for inline-text revisions; empty array for bundles
    /// whose manifest is malformed (logged via the store).
    public func listRevisionBundleEntries(revisionID: String) -> [JournalBundleEntry]? {
        getRevision(id: revisionID)?.bundleEntries()
    }

    // MARK: - Reviews (read, Phase 4)

    /// All reviews for a manuscript — collects reviews whose `subject_ref`
    /// is any of the manuscript's revisions. Newest-first by created time
    /// (SharedStore orders by created desc).
    public func listReviews(manuscriptID: String, limit: Int = 200) -> [JournalReview] {
        guard let store = handle() else { return [] }
        // Collect the IDs of all revisions of this manuscript.
        let revisionIDs = Set(listRevisions(manuscriptID: manuscriptID).map(\.id))
        guard !revisionIDs.isEmpty else { return [] }
        do {
            let rows = try store.queryBySchema(
                schemaRef: JournalSchema.review,
                limit: UInt32(max(0, limit)),
                offset: 0
            )
            return rows.compactMap { row -> JournalReview? in
                guard let r = JournalReview.decode(itemID: row.id, payloadJSON: row.payloadJson) else {
                    return nil
                }
                return revisionIDs.contains(r.subjectRef) ? r : nil
            }
        } catch {
            bridgeLog.errorCapture(
                "listReviews(\(manuscriptID)) failed: \(error.localizedDescription)",
                category: "manuscript-bridge"
            )
            return []
        }
    }

    /// All revision-notes for a manuscript. Filtered the same way as reviews.
    public func listRevisionNotes(manuscriptID: String, limit: Int = 200) -> [JournalRevisionNote] {
        guard let store = handle() else { return [] }
        let revisionIDs = Set(listRevisions(manuscriptID: manuscriptID).map(\.id))
        guard !revisionIDs.isEmpty else { return [] }
        do {
            let rows = try store.queryBySchema(
                schemaRef: JournalSchema.revisionNote,
                limit: UInt32(max(0, limit)),
                offset: 0
            )
            return rows.compactMap { row -> JournalRevisionNote? in
                guard let n = JournalRevisionNote.decode(itemID: row.id, payloadJSON: row.payloadJson) else {
                    return nil
                }
                return revisionIDs.contains(n.subjectRef) ? n : nil
            }
        } catch {
            bridgeLog.errorCapture(
                "listRevisionNotes(\(manuscriptID)) failed: \(error.localizedDescription)",
                category: "manuscript-bridge"
            )
            return []
        }
    }

    // MARK: - Submissions (write)

    /// Outcome of a Scout triage that the user wants to apply by clicking
    /// "Accept" in the Submissions inbox. Mirrors `ScoutOutcome` from
    /// CounselEngine but is re-declared here so PublicationManagerCore
    /// doesn't depend on CounselEngine.
    public enum AcceptOutcome: Sendable {
        case newManuscript
        case newRevisionOf(manuscriptID: String)
        case fragmentOf(manuscriptID: String)
    }

    /// Accept a pending submission per Phase 2's UX decision (creates the
    /// manuscript item where applicable; defers compile to Phase 3).
    /// Returns the resulting manuscript ID for `.newManuscript`, or nil
    /// for the other outcomes (which annotate an existing manuscript).
    @discardableResult
    public func acceptSubmission(id submissionID: String, outcome: AcceptOutcome) throws -> String? {
        guard let store = handle() else { throw ManuscriptBridgeError.storeUnavailable }
        guard let row = try? store.getItem(id: submissionID) else {
            throw ManuscriptBridgeError.notFound(submissionID)
        }

        var payload = try parsePayload(row.payloadJson)
        payload["state"] = JournalSubmissionState.accepted.rawValue

        switch outcome {
        case .newManuscript:
            let title = (payload["title"] as? String) ?? "Untitled"
            let manuscriptID = try createManuscript(title: title)
            payload["accepted_manuscript_ref"] = manuscriptID
            try writeItem(store: store, id: submissionID, schema: JournalSchema.manuscriptSubmission, payload: payload)
            bridgeLog.infoCapture(
                "Accepted submission \(submissionID) → new manuscript \(manuscriptID)",
                category: "manuscript-bridge"
            )
            return manuscriptID

        case .newRevisionOf(let parentID):
            // Defer revision creation to Phase 3. Annotate parent with the
            // pending revision so the parent's detail view can show it.
            payload["accepted_manuscript_ref"] = parentID
            payload["accepted_outcome"] = "new-revision"
            try writeItem(store: store, id: submissionID, schema: JournalSchema.manuscriptSubmission, payload: payload)
            postChangeNotification(event: ImpressNotification.manuscriptStatusChanged, ids: [parentID])
            bridgeLog.infoCapture(
                "Accepted submission \(submissionID) as pending revision of \(parentID)",
                category: "manuscript-bridge"
            )
            return nil

        case .fragmentOf(let parentID):
            payload["accepted_manuscript_ref"] = parentID
            payload["accepted_outcome"] = "fragment"
            try writeItem(store: store, id: submissionID, schema: JournalSchema.manuscriptSubmission, payload: payload)
            postChangeNotification(event: ImpressNotification.manuscriptStatusChanged, ids: [parentID])
            bridgeLog.infoCapture(
                "Accepted submission \(submissionID) as fragment of \(parentID)",
                category: "manuscript-bridge"
            )
            return nil
        }
    }

    /// Reject a pending submission. Advances state to `cancelled` and
    /// stamps an optional reason. The item itself is not deleted — it
    /// stays in the store as audit trail (per ADR-0003 / ADR-0011 D10).
    public func rejectSubmission(id submissionID: String, reason: String? = nil) throws {
        guard let store = handle() else { throw ManuscriptBridgeError.storeUnavailable }
        guard let row = try? store.getItem(id: submissionID) else {
            throw ManuscriptBridgeError.notFound(submissionID)
        }
        var payload = try parsePayload(row.payloadJson)
        payload["state"] = JournalSubmissionState.cancelled.rawValue
        if let reason { payload["rejection_reason"] = reason }
        try writeItem(store: store, id: submissionID, schema: JournalSchema.manuscriptSubmission, payload: payload)
        bridgeLog.infoCapture(
            "Rejected submission \(submissionID) — reason=\(reason ?? "<none>")",
            category: "manuscript-bridge"
        )
    }

    // MARK: - Internals

    private func handle() -> SharedStore? {
        if let store { return store }
        if openAttempted { return nil }
        openAttempted = true
        do {
            try SharedWorkspace.ensureDirectoryExists()
            let path = SharedWorkspace.databaseURL.path
            let s = try SharedStore.open(path: path)
            self.store = s
            bridgeLog.infoCapture(
                "ManuscriptBridge opened SharedStore at \(path)",
                category: "manuscript-bridge"
            )
            return s
        } catch {
            bridgeLog.warningCapture(
                "ManuscriptBridge could not open SharedStore: \(error.localizedDescription)",
                category: "manuscript-bridge"
            )
            return nil
        }
    }

    private func getManuscriptPayloadDict(id: String) -> [String: Any]? {
        guard let store = handle() else { return nil }
        guard let row = try? store.getItem(id: id) else { return nil }
        return try? parsePayload(row.payloadJson)
    }

    private func parsePayload(_ json: String) throws -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ManuscriptBridgeError.invalidPayload("payload is not a JSON object") }
        return obj
    }

    private func writeItem(
        store: SharedStore,
        id: String,
        schema: String,
        payload: [String: Any]
    ) throws {
        let json: Data
        do {
            json = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        } catch {
            throw ManuscriptBridgeError.invalidPayload(
                "could not encode payload: \(error.localizedDescription)"
            )
        }
        guard let s = String(data: json, encoding: .utf8) else {
            throw ManuscriptBridgeError.invalidPayload("payload data is not valid UTF-8")
        }
        do {
            try store.upsertItem(id: id, schemaRef: schema, payloadJson: s)
        } catch {
            throw ManuscriptBridgeError.writeFailed(error)
        }
    }

    /// Post a Darwin notification on `ImpressNotification` so other parts of
    /// imbib (sidebar, detail view) can observe journal-store mutations
    /// without polling.
    private func postChangeNotification(event: String, ids: [String]) {
        ImpressNotification.post(event, from: .imbib, resourceIDs: ids)
    }
}
