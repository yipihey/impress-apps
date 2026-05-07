//
//  JournalSnapshotJob.swift
//  CounselEngine
//
//  Phase 3 of the impress journal pipeline (per docs/plan-journal-pipeline.md
//  §3.3 + ADR-0011 D5/D7).
//
//  Archivist's worker. Given a manuscript ID and source content, creates a
//  manuscript-revision@1.0.0 item and updates the parent manuscript's
//  current_revision_ref. Idempotent: if the source bytes hash to the
//  current revision's content_hash, the call is a no-op.
//
//  Phase 3 deliberately does NOT shell out to imprint compile (per the
//  Implementation Plan §8 Risk #2: imprint compile API is unwired). The
//  snapshot stores the source archive in BlobStore and creates a revision
//  item with a placeholder pdf_artifact_ref. When the compile API lands,
//  Archivist will be extended to call it and write the real PDF.
//

import CryptoKit
import Foundation
import ImpressKit
import OSLog

#if canImport(ImpressRustCore)
import ImpressRustCore
#endif

// MARK: - Errors

public enum JournalSnapshotError: Error, LocalizedError {
    case storeUnavailable
    case manuscriptNotFound(String)
    case writeFailed(Error)
    case encodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .storeUnavailable:
            return "Shared impress-core store is not available"
        case .manuscriptNotFound(let id):
            return "Manuscript not found: \(id)"
        case .writeFailed(let err):
            return "Snapshot write failed: \(err.localizedDescription)"
        case .encodingFailed(let msg):
            return "Snapshot payload encoding failed: \(msg)"
        }
    }
}

// MARK: - Result

public struct JournalSnapshotResult: Sendable {
    /// The newly created revision's stable item ID. nil if the snapshot
    /// was a no-op (source hash matched the current revision).
    public let revisionID: String?
    /// SHA-256 of the source content (always populated, even on no-op).
    public let contentHash: String
    /// True when this was a no-op (idempotent skip).
    public let wasNoOp: Bool

    public init(revisionID: String?, contentHash: String, wasNoOp: Bool) {
        self.revisionID = revisionID
        self.contentHash = contentHash
        self.wasNoOp = wasNoOp
    }
}

// MARK: - Service

/// Singleton actor that creates manuscript-revision items.
///
/// Mirrors the JournalSubmissionService pattern: opens its own SharedStore
/// handle on the unified workspace SQLite. Concurrency is safe via SQLite
/// WAL mode plus actor serialization.
public actor JournalSnapshotJob {

    public static let shared = JournalSnapshotJob()

    private let logger = Logger(subsystem: "com.impress.impel", category: "journal-snapshot")
    private var isAvailable = false

    #if canImport(ImpressRustCore)
    private var store: SharedStore?
    #endif

    /// Compile client. Phase 6 wires real PDF compilation through imprint;
    /// nil disables compile attempts and keeps the placeholder behavior
    /// (used by tests that don't want to involve compile at all).
    private let compileClient: ImprintCompileClient?

    /// Where compiled PDFs land on disk. Defaults to the impress
    /// content-addressed convention documented in
    /// `crates/impress-core/src/schemas/manuscript_section.rs:11–15`:
    /// `~/.local/share/impress/content/{prefix}/{prefix2}/{sha256}.{ext}`.
    /// Tests inject a temp path.
    private let blobRootURL: URL

    private init() {
        do {
            try SharedWorkspace.ensureDirectoryExists()
            #if canImport(ImpressRustCore)
            self.store = try SharedStore.open(path: SharedWorkspace.databaseURL.path)
            #endif
            self.isAvailable = true
            logger.info("JournalSnapshotJob: ready at \(SharedWorkspace.databaseURL.path)")
        } catch {
            self.isAvailable = false
            logger.error("JournalSnapshotJob: store unavailable — \(error.localizedDescription)")
        }
        self.compileClient = ImprintCompileClient.shared
        self.blobRootURL = JournalSnapshotJob.defaultBlobRoot
    }

    /// Internal initializer for tests.
    internal init(
        testStorePath: String,
        compileClient: ImprintCompileClient? = nil,
        blobRootURL: URL = JournalSnapshotJob.defaultBlobRoot
    ) throws {
        #if canImport(ImpressRustCore)
        self.store = try SharedStore.open(path: testStorePath)
        #endif
        self.isAvailable = true
        self.compileClient = compileClient
        self.blobRootURL = blobRootURL
    }

    /// Default content-addressed blob root, matching imbib's BlobStore.
    public static var defaultBlobRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("impress", isDirectory: true)
            .appendingPathComponent("content", isDirectory: true)
    }

    // MARK: - Snapshot

    /// The source carried by a snapshot request.
    public enum SnapshotSource: Sendable {
        /// Inline source text (Phase 3 path; one-file submissions).
        case inlineText(String)
        /// A directory bundle archived as `.tar.zst`. The SHA-256 is the
        /// archive's content hash; the manifest mirrors what's stored in
        /// the submission/revision payload's `bundle_manifest_json`.
        case bundle(sha256: String, manifest: ManuscriptBundleManifest)
    }

    /// Create a manuscript-revision item from inline source text. Backward-
    /// compatible wrapper over the source-spec API.
    public func snapshot(
        manuscriptID: String,
        sourceContent: String,
        revisionTag: String,
        reason: String
    ) async throws -> JournalSnapshotResult {
        try await snapshot(
            manuscriptID: manuscriptID,
            source: .inlineText(sourceContent),
            revisionTag: revisionTag,
            reason: reason
        )
    }

    /// Create a manuscript-revision item.
    ///
    /// - Parameters:
    ///   - manuscriptID: Stable item ID of the parent manuscript.
    ///   - source: Either inline text or a bundle archive ref + manifest.
    ///   - revisionTag: User-meaningful tag (e.g. "v1", "submitted", "referee-response-1").
    ///   - reason: Why this snapshot was triggered (per ADR-0011 D5):
    ///             "status-change" | "user-tag" | "stable-churn" | "manual" | "submission-accept".
    /// - Returns: A `JournalSnapshotResult` describing the outcome.
    public func snapshot(
        manuscriptID: String,
        source: SnapshotSource,
        revisionTag: String,
        reason: String
    ) async throws -> JournalSnapshotResult {
        guard isAvailable else { throw JournalSnapshotError.storeUnavailable }
        #if canImport(ImpressRustCore)
        guard let store = store else { throw JournalSnapshotError.storeUnavailable }

        // 1. Resolve content hash + source-archive ref + manifest JSON
        //    from the source spec.
        let contentHash: String
        let sourceArchiveRef: String
        let bundleManifestJSON: String?
        let inlineWordCount: Int?
        switch source {
        case .inlineText(let text):
            contentHash = computeHash(of: text)
            // Phase 7-era inline path: source_archive_ref points at the
            // text blob (no .tar.zst suffix). Phase 8 leaves this path
            // unchanged so existing items stay valid.
            sourceArchiveRef = "blob:sha256:\(contentHash)"
            bundleManifestJSON = nil
            inlineWordCount = text.split(whereSeparator: \.isWhitespace).count
        case .bundle(let sha256, let manifest):
            contentHash = sha256
            // Phase 8: source_archive_ref now resolves to a real .tar.zst
            // bundle in BlobStore (no more placeholder text-blob ref).
            sourceArchiveRef = "blob:sha256:\(sha256).tar.zst"
            bundleManifestJSON = try? manifest.canonicalJSONString()
            inlineWordCount = nil
        }

        // 2. Load the parent manuscript.
        guard let parentRow = try? store.getItem(id: manuscriptID) else {
            throw JournalSnapshotError.manuscriptNotFound(manuscriptID)
        }
        var parentPayload = try parsePayload(parentRow.payloadJson)
        let currentRevRef = parentPayload["current_revision_ref"] as? String

        // 3. Idempotency: if there's a current revision with the same hash, no-op.
        if let currentRevRef, currentRevRef != JournalSnapshotJob.placeholderRevisionRef,
           let curRow = try? store.getItem(id: currentRevRef),
           let curPayload = try? parsePayload(curRow.payloadJson),
           let curHash = curPayload["content_hash"] as? String,
           curHash == contentHash
        {
            logger.info(
                "JournalSnapshotJob: snapshot for \(manuscriptID) is no-op (hash matches current revision \(currentRevRef))"
            )
            return JournalSnapshotResult(revisionID: nil, contentHash: contentHash, wasNoOp: true)
        }

        // 4. Generate revision ID + predecessor link.
        let revisionID = UUID().uuidString.lowercased()
        let predecessorRef = (currentRevRef == JournalSnapshotJob.placeholderRevisionRef) ? nil : currentRevRef

        // 5. Compile via imprint (Phase 6 / docs/plan-imprint-compile.md).
        //    Per the failure-mode contract: compile failures don't block the
        //    snapshot — we fall back to the placeholder PDF ref + record
        //    `compile_status` so the UI can show the deferred state.
        //    Phase 8 extension: bundle compile is wired in Phase 8.10/8.11;
        //    until then, bundles defer compile (engine != .none) or skip it
        //    (engine == .none for markdown/html). Inline text retains the
        //    original Phase 6 behaviour.
        var pdfArtifactRef = JournalSnapshotJob.placeholderPDFRef
        var compileStatus: String? = nil
        var compileError: String? = nil
        var compileWarnings: [String]? = nil
        var compilePageCount: Int? = nil
        var compileMs: Int? = nil

        switch source {
        case .inlineText(let text):
            if let client = compileClient {
                do {
                    let result = try await client.compileTypst(source: text)
                    let pdfHash = JournalSnapshotJob.sha256Hex(of: result.pdfData)
                    let pdfURL = try writeBlob(data: result.pdfData, sha256: pdfHash, ext: "pdf")
                    pdfArtifactRef = "blob:sha256:\(pdfHash)"
                    compileStatus = "ok"
                    compileWarnings = result.warnings.isEmpty ? nil : result.warnings
                    compilePageCount = result.pageCount
                    compileMs = result.compileMs
                    logger.info(
                        "JournalSnapshotJob: compile ok — pdf=\(pdfHash.prefix(12))… (\(result.pdfData.count) bytes, \(result.pageCount) pages, \(result.compileMs)ms) at \(pdfURL.path)"
                    )
                } catch let ImprintCompileError.unreachable(_, _) {
                    compileStatus = "deferred"
                    compileError = "imprint not reachable"
                    logger.info("JournalSnapshotJob: compile deferred — imprint unreachable")
                } catch let ImprintCompileError.compileError(msg, warnings, ms) {
                    compileStatus = "error"
                    compileError = msg
                    compileWarnings = warnings.isEmpty ? nil : warnings
                    compileMs = ms
                    logger.error("JournalSnapshotJob: source compile error — \(msg)")
                } catch let ImprintCompileError.imprintError(status, body) {
                    compileStatus = "imprint-error"
                    compileError = "imprint HTTP \(status): \(body.prefix(120))"
                    logger.error("JournalSnapshotJob: imprint compile route error \(status)")
                } catch {
                    compileStatus = "imprint-error"
                    compileError = "compile failed: \(error.localizedDescription)"
                    logger.error("JournalSnapshotJob: compile failed — \(error.localizedDescription)")
                }
            } else {
                compileStatus = "deferred"
                compileError = "compile client not configured"
            }
        case .bundle(let sha, let manifest):
            // Phase 8.11 routing: route to imprint's bundle compile endpoint.
            // imprint dispatches internally — typst projects via imprint-core,
            // LaTeX projects via LaTeXCompilationService — so this client
            // call is engine-agnostic.
            switch manifest.compile.engine {
            case .none:
                compileStatus = "skipped"
                logger.info(
                    "JournalSnapshotJob: bundle revision \(revisionID) compile skipped (engine=none, format=\(manifest.sourceFormat.rawValue))"
                )
            case .typst, .pdflatex, .xelatex, .lualatex, .latexmk:
                if let client = compileClient {
                    do {
                        let result = try await client.compileBundle(
                            bundleSHA256: sha,
                            mainFile: manifest.mainSource,
                            engine: manifest.compile.engine.rawValue
                        )
                        let pdfHash = JournalSnapshotJob.sha256Hex(of: result.pdfData)
                        let pdfURL = try writeBlob(data: result.pdfData, sha256: pdfHash, ext: "pdf")
                        pdfArtifactRef = "blob:sha256:\(pdfHash)"
                        compileStatus = "ok"
                        compileWarnings = result.warnings.isEmpty ? nil : result.warnings
                        compilePageCount = result.pageCount
                        compileMs = result.compileMs
                        logger.info(
                            "JournalSnapshotJob: bundle compile ok — engine=\(manifest.compile.engine.rawValue) pdf=\(pdfHash.prefix(12))… (\(result.pdfData.count) bytes, \(result.pageCount) pages, \(result.compileMs)ms) at \(pdfURL.path)"
                        )
                    } catch let ImprintCompileError.unreachable(_, _) {
                        compileStatus = "deferred"
                        compileError = "imprint not reachable"
                        logger.info("JournalSnapshotJob: bundle compile deferred — imprint unreachable")
                    } catch let ImprintCompileError.engineUnavailable(msg) {
                        compileStatus = "engine-unavailable"
                        compileError = msg
                        logger.info("JournalSnapshotJob: bundle compile deferred — engine \(manifest.compile.engine.rawValue) not installed")
                    } catch let ImprintCompileError.compileError(msg, warnings, ms) {
                        compileStatus = "error"
                        compileError = msg
                        compileWarnings = warnings.isEmpty ? nil : warnings
                        compileMs = ms
                        logger.error("JournalSnapshotJob: bundle source compile error — \(msg)")
                    } catch let ImprintCompileError.imprintError(status, body) {
                        compileStatus = "imprint-error"
                        compileError = "imprint HTTP \(status): \(body.prefix(120))"
                        logger.error("JournalSnapshotJob: imprint bundle compile route error \(status)")
                    } catch let ImprintCompileError.malformedResponse(msg) {
                        compileStatus = "imprint-error"
                        compileError = "imprint malformed response: \(msg)"
                        logger.error("JournalSnapshotJob: imprint bundle compile malformed — \(msg)")
                    } catch {
                        compileStatus = "imprint-error"
                        compileError = "compile failed: \(error.localizedDescription)"
                        logger.error("JournalSnapshotJob: bundle compile failed — \(error.localizedDescription)")
                    }
                } else {
                    compileStatus = "deferred"
                    compileError = "compile client not configured"
                }
            }
        }

        // 6. Build the revision payload.
        var revisionPayload: [String: Any] = [
            "parent_manuscript_ref": manuscriptID,
            "revision_tag":          revisionTag,
            "content_hash":          contentHash,
            "pdf_artifact_ref":      pdfArtifactRef,
            "source_archive_ref":    sourceArchiveRef,
            "snapshot_reason":       reason,
        ]
        if let predecessorRef { revisionPayload["predecessor_revision_ref"] = predecessorRef }
        if let inlineWordCount, inlineWordCount > 0 {
            revisionPayload["word_count"] = inlineWordCount
        }
        if let bundleManifestJSON {
            revisionPayload["bundle_manifest_json"] = bundleManifestJSON
        }
        if let compileStatus  { revisionPayload["compile_status"]   = compileStatus }
        if let compileError   { revisionPayload["compile_error"]    = compileError }
        if let compileWarnings { revisionPayload["compile_warnings"] = compileWarnings }
        if let compilePageCount { revisionPayload["page_count"]      = compilePageCount }
        if let compileMs      { revisionPayload["compile_ms"]       = compileMs }

        // 6. Persist the revision.
        try writeItem(
            store: store,
            id: revisionID,
            schema: "manuscript-revision",
            payload: revisionPayload
        )

        // 7. Update the parent's current_revision_ref to point at the new revision.
        parentPayload["current_revision_ref"] = revisionID
        try writeItem(
            store: store,
            id: manuscriptID,
            schema: "manuscript",
            payload: parentPayload
        )

        // 8. Post the cross-app event so subscribers (imbib detail view, etc.) refresh.
        ImpressNotification.post(
            ImpressNotification.manuscriptSnapshotCreated,
            from: .impel,
            resourceIDs: [manuscriptID, revisionID]
        )
        ImpressNotification.post(
            ImpressNotification.manuscriptStatusChanged,
            from: .impel,
            resourceIDs: [manuscriptID]
        )

        logger.info(
            "JournalSnapshotJob: snapshot \(revisionID) for \(manuscriptID) tag=\(revisionTag) reason=\(reason)"
        )
        return JournalSnapshotResult(revisionID: revisionID, contentHash: contentHash, wasNoOp: false)
        #else
        throw JournalSnapshotError.storeUnavailable
        #endif
    }

    // MARK: - Helpers

    /// All-zero UUID placeholder used by ManuscriptBridge.createManuscript
    /// to mean "no revision yet". Phase 3 replaces this with a real revision
    /// ID on the first snapshot.
    private static let placeholderRevisionRef = "00000000-0000-0000-0000-000000000000"

    /// Placeholder for the pdf_artifact_ref field until imprint compile is
    /// wired (per ADR-0011 OQ-10 / Implementation Plan §8 Risk #2).
    private static let placeholderPDFRef = "00000000-0000-0000-0000-000000000001"

    private nonisolated func computeHash(of text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .compactMap { String(format: "%02x", $0) }
            .joined()
    }

    nonisolated static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data)
            .compactMap { String(format: "%02x", $0) }
            .joined()
    }

    /// Write `data` to `{blobRoot}/{sha[0..2]}/{sha[2..4]}/{sha}.{ext}`.
    /// Idempotent: if the file already exists, returns the existing URL.
    /// Mirrors the convention used by imbib's BlobStore so both apps
    /// read/write to the same on-disk content-addressed tree.
    private func writeBlob(data: Data, sha256: String, ext: String) throws -> URL {
        precondition(sha256.count == 64, "expected 64-char SHA-256, got \(sha256.count)")
        let prefix1 = String(sha256.prefix(2))
        let prefix2 = String(sha256.dropFirst(2).prefix(2))
        let dir = blobRootURL
            .appendingPathComponent(prefix1, isDirectory: true)
            .appendingPathComponent(prefix2, isDirectory: true)
        let url = dir.appendingPathComponent("\(sha256).\(ext)")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return url
    }

    private nonisolated func parsePayload(_ json: String) throws -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw JournalSnapshotError.encodingFailed("payload is not a JSON object")
        }
        return obj
    }

    #if canImport(ImpressRustCore)
    private nonisolated func writeItem(
        store: SharedStore,
        id: String,
        schema: String,
        payload: [String: Any]
    ) throws {
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        } catch {
            throw JournalSnapshotError.encodingFailed(
                "could not encode payload: \(error.localizedDescription)"
            )
        }
        guard let s = String(data: data, encoding: .utf8) else {
            throw JournalSnapshotError.encodingFailed("payload data is not valid UTF-8")
        }
        do {
            try store.upsertItem(id: id, schemaRef: schema, payloadJson: s)
        } catch {
            throw JournalSnapshotError.writeFailed(error)
        }
    }
    #endif
}
