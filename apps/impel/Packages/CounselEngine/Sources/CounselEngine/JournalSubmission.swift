//
//  JournalSubmission.swift
//  CounselEngine
//
//  Phase 1 of the impress journal pipeline (per docs/plan-journal-pipeline.md
//  §3.6 / ADR-0011 D6).
//
//  Provides the canonical Swift entry point for submitting manuscripts to
//  the journal: validates the payload, computes a content hash, and writes
//  a `manuscript-submission@1.0.0` item to the unified impress-core store
//  via SharedStore. The HTTP route, MCP tool, and CLI command all funnel
//  through `JournalSubmissionService.submit(_:)`.
//

import CryptoKit
import Foundation
import ImpressKit
import OSLog

#if canImport(ImpressRustCore)
import ImpressRustCore
#endif

// MARK: - DTOs

/// Submission kind — controls how Scout routes the submission.
///
/// See ADR-0011 D6 for the routing semantics.
public enum SubmissionKind: String, Codable, Sendable {
    /// First revision of a brand-new manuscript.
    case newManuscript = "new-manuscript"
    /// New revision of an existing manuscript.
    case newRevision = "new-revision"
    /// Source fragment to be attached to an existing manuscript (not a full revision).
    case fragment
}

/// Source format of the submitted content.
///
/// Phase 8 extension: added `markdown` and `html` to support manuscript
/// bundles whose main entry is `.md` or `.html`. Compile dispatch uses
/// the format to pick an engine — `tex` → pdflatex (via imprint's
/// LaTeXCompilationService), `typst` → imprint-core typst renderer,
/// `markdown` and `html` → store-only (no compile in v1).
public enum SourceFormat: String, Codable, Sendable {
    case tex
    case typst
    case markdown
    case html
}

/// A manuscript submission payload accepted by the journal pipeline.
///
/// Field shapes match the `manuscript-submission@1.0.0` schema in
/// `crates/impress-core/src/schemas/manuscript_submission.rs`. JSON keys
/// match the on-the-wire format (snake_case) for HTTP and MCP entry points.
public struct ManuscriptSubmission: Codable, Sendable {
    public let submissionKind: SubmissionKind
    public let title: String
    public let sourceFormat: SourceFormat

    /// Either inline source text, or a reference of the form
    /// `"blob:sha256:<hex>"` pointing to a pre-stored blob in BlobStore.
    /// For directory bundles, the form is
    /// `"blob:sha256:<hex>.tar.zst"` (matching the on-disk filename) and
    /// `bundleManifestJSON` is populated.
    public let sourcePayload: String

    public let parentManuscriptRef: String?
    public let parentRevisionRef: String?
    public let submitterPersonaID: String?
    public let originConversationRef: String?
    public let metadataJSON: String?
    public let bibliographyPayload: String?
    public let similarityHint: String?

    /// JSON-encoded `manuscript-bundle-manifest@1.0.0` describing the
    /// bundle's main source, format, per-file roles, and compile spec.
    /// Required when `sourcePayload` is a `.tar.zst` bundle ref. Phase 8.
    public let bundleManifestJSON: String?

    public init(
        submissionKind: SubmissionKind,
        title: String,
        sourceFormat: SourceFormat,
        sourcePayload: String,
        parentManuscriptRef: String? = nil,
        parentRevisionRef: String? = nil,
        submitterPersonaID: String? = nil,
        originConversationRef: String? = nil,
        metadataJSON: String? = nil,
        bibliographyPayload: String? = nil,
        similarityHint: String? = nil,
        bundleManifestJSON: String? = nil
    ) {
        self.submissionKind = submissionKind
        self.title = title
        self.sourceFormat = sourceFormat
        self.sourcePayload = sourcePayload
        self.parentManuscriptRef = parentManuscriptRef
        self.parentRevisionRef = parentRevisionRef
        self.submitterPersonaID = submitterPersonaID
        self.originConversationRef = originConversationRef
        self.metadataJSON = metadataJSON
        self.bibliographyPayload = bibliographyPayload
        self.similarityHint = similarityHint
        self.bundleManifestJSON = bundleManifestJSON
    }

    /// Convenience: true when `sourcePayload` references a bundle archive
    /// (rather than inline source or a single-blob ref). The convention is
    /// that bundle refs end with `.tar.zst`.
    public var isBundle: Bool {
        sourcePayload.hasSuffix(".tar.zst")
    }

    enum CodingKeys: String, CodingKey {
        case submissionKind = "submission_kind"
        case title
        case sourceFormat = "source_format"
        case sourcePayload = "source_payload"
        case parentManuscriptRef = "parent_manuscript_ref"
        case parentRevisionRef = "parent_revision_ref"
        case submitterPersonaID = "submitter_persona_id"
        case originConversationRef = "origin_conversation_ref"
        case metadataJSON = "metadata_json"
        case bibliographyPayload = "bibliography_payload"
        case similarityHint = "similarity_hint"
        case bundleManifestJSON = "bundle_manifest_json"
    }
}

/// Convenience: build the canonical bundle ref string from a SHA-256 hex.
public func bundleSourcePayloadRef(sha256: String) -> String {
    return "blob:sha256:\(sha256).tar.zst"
}

/// Result of a successful submission.
public struct SubmissionResult: Codable, Sendable {
    /// Stable item ID of the stored `manuscript-submission` item. Callers
    /// query the submission's status by GET /api/tasks/{taskID} or by
    /// reading the item directly from the shared store.
    public let taskID: String

    /// Lifecycle state of the submission immediately after persistence
    /// (always `"pending"` for v1).
    public let status: String

    /// SHA-256 hex of the resolved source content (inline source or the
    /// hash extracted from a `blob:sha256:` reference).
    public let contentHash: String

    public init(taskID: String, status: String, contentHash: String) {
        self.taskID = taskID
        self.status = status
        self.contentHash = contentHash
    }

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case status
        case contentHash = "content_hash"
    }
}

// MARK: - Errors

public enum JournalSubmissionError: Error, LocalizedError {
    case invalidPayload(String)
    case storeUnavailable
    case persistenceFailed(Error)
    case encodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPayload(let msg):
            return "Invalid manuscript submission: \(msg)"
        case .storeUnavailable:
            return "Shared impress-core store is not available; submission cannot be persisted."
        case .persistenceFailed(let error):
            return "Failed to persist manuscript submission: \(error.localizedDescription)"
        case .encodingFailed(let msg):
            return "Failed to encode submission payload: \(msg)"
        }
    }
}

// MARK: - Service

/// Singleton entry point for journal submissions.
///
/// All submission paths (HTTP route, MCP tool, CLI) route through
/// `JournalSubmissionService.shared.submit(_:)`. The service opens its own
/// `SharedStore` connection on the unified impress-core SQLite database,
/// independent of `SharedTaskBridge` (they share the underlying file via
/// SQLite's WAL mode).
public actor JournalSubmissionService {

    public static let shared = JournalSubmissionService()

    private let logger = Logger(subsystem: "com.impress.impel", category: "journal-submission")

    private var isAvailable = false

    #if canImport(ImpressRustCore)
    private var store: SharedStore?
    #endif

    private init() {
        do {
            try SharedWorkspace.ensureDirectoryExists()
            #if canImport(ImpressRustCore)
            self.store = try SharedStore.open(path: SharedWorkspace.databaseURL.path)
            #endif
            self.isAvailable = true
            logger.info("JournalSubmissionService: ready at \(SharedWorkspace.databaseURL.path)")
        } catch {
            self.isAvailable = false
            logger.error("JournalSubmissionService: store unavailable — \(error.localizedDescription)")
        }
    }

    /// Internal initializer for tests: open against an explicit path.
    /// Not part of the public API.
    internal init(testStorePath: String) throws {
        #if canImport(ImpressRustCore)
        self.store = try SharedStore.open(path: testStorePath)
        #endif
        self.isAvailable = true
    }

    // MARK: - Submission

    /// Validate, hash, and persist a manuscript submission.
    ///
    /// The submission is stored as a `manuscript-submission@1.0.0` item with
    /// state `"pending"`. Scout will pick it up in a subsequent pass and
    /// move it through the dedup → propose → accept flow per ADR-0011 D7.
    ///
    /// - Throws: `JournalSubmissionError.invalidPayload` for validation
    ///   failures, `.storeUnavailable` if the shared store could not be
    ///   opened, `.persistenceFailed` for write errors,
    ///   `.encodingFailed` for JSON encoding errors.
    public func submit(_ payload: ManuscriptSubmission) async throws -> SubmissionResult {
        try validate(payload)

        let contentHash = computeContentHash(payload)
        // Lowercase to match Rust's Uuid::to_string() canonical form, which is
        // what SharedStore returns for SharedItemRow.id. Without this, a Swift
        // caller that does `result.taskID == row.id` will get a false negative.
        let id = UUID().uuidString.lowercased()

        let payloadJSON = try buildSubmissionPayload(
            from: payload,
            contentHash: contentHash
        )

        try await persist(id: id, payloadJSON: payloadJSON)

        logger.info(
            "JournalSubmissionService: submission \(id) queued — kind=\(payload.submissionKind.rawValue) title=\"\(payload.title.prefix(80))\""
        )
        return SubmissionResult(taskID: id, status: "pending", contentHash: contentHash)
    }

    /// Return all submissions currently in `pending` state, most-recent first.
    public func listPendingSubmissions(limit: Int = 100) throws -> [SubmissionRecord] {
        guard isAvailable else { return [] }
        #if canImport(ImpressRustCore)
        guard let store = store else { return [] }
        let rows = try store.queryBySchema(
            schemaRef: "manuscript-submission",
            limit: UInt32(max(0, limit)),
            offset: 0
        )
        return rows.compactMap { row -> SubmissionRecord? in
            guard let data = row.payloadJson.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            // Project to [String: String]; only keep string-valued fields.
            var fields: [String: String] = [:]
            for (k, v) in obj {
                if let s = v as? String { fields[k] = s }
            }
            guard fields["state"] == "pending" else { return nil }
            return SubmissionRecord(itemID: row.id, fields: fields)
        }
        #else
        return []
        #endif
    }

    // MARK: - Private helpers

    private func validate(_ payload: ManuscriptSubmission) throws {
        let trimmed = payload.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw JournalSubmissionError.invalidPayload("title is empty")
        }
        if payload.sourcePayload.isEmpty {
            throw JournalSubmissionError.invalidPayload("source_payload is empty")
        }

        // Bundle invariants: when source_payload is a .tar.zst ref, the
        // manifest must be present and parseable + validate against
        // `manuscript-bundle-manifest@1.0.0`.
        if payload.isBundle {
            guard let manifestJSON = payload.bundleManifestJSON, !manifestJSON.isEmpty else {
                throw JournalSubmissionError.invalidPayload(
                    "source_payload references a bundle (.tar.zst) but bundle_manifest_json is missing"
                )
            }
            do {
                _ = try ManuscriptBundleManifest.parse(manifestJSON)
            } catch {
                throw JournalSubmissionError.invalidPayload(
                    "bundle_manifest_json is invalid: \(error.localizedDescription)"
                )
            }
        } else if payload.bundleManifestJSON != nil {
            throw JournalSubmissionError.invalidPayload(
                "bundle_manifest_json provided but source_payload is not a bundle ref"
            )
        }

        switch payload.submissionKind {
        case .newManuscript:
            // No required parent refs.
            break
        case .newRevision:
            guard payload.parentManuscriptRef != nil else {
                throw JournalSubmissionError.invalidPayload(
                    "submission_kind=new-revision requires parent_manuscript_ref"
                )
            }
        case .fragment:
            guard payload.parentManuscriptRef != nil else {
                throw JournalSubmissionError.invalidPayload(
                    "submission_kind=fragment requires parent_manuscript_ref"
                )
            }
        }
    }

    /// Compute the SHA-256 hex of the source content. If `source_payload`
    /// is a `blob:sha256:` reference (inline blob OR bundle archive), extract
    /// and return the hex directly without recomputing.
    private func computeContentHash(_ payload: ManuscriptSubmission) -> String {
        let prefix = "blob:sha256:"
        if payload.sourcePayload.hasPrefix(prefix) {
            // Strip the prefix, then the trailing extension if any (e.g.
            // `.tar.zst` for bundles, no suffix for plain blobs).
            var rest = String(payload.sourcePayload.dropFirst(prefix.count))
            if let dot = rest.firstIndex(of: ".") {
                rest = String(rest[..<dot])
            }
            return rest
        }
        let data = Data(payload.sourcePayload.utf8)
        return SHA256.hash(data: data)
            .compactMap { String(format: "%02x", $0) }
            .joined()
    }

    /// Build the JSON payload string for the manuscript-submission item.
    /// Includes inherited `task` schema fields (state, title, description).
    private func buildSubmissionPayload(
        from p: ManuscriptSubmission,
        contentHash: String
    ) throws -> String {
        var dict: [String: Any] = [
            "submission_kind": p.submissionKind.rawValue,
            "title": p.title,
            "source_format": p.sourceFormat.rawValue,
            "source_payload": p.sourcePayload,
            "content_hash": contentHash,
            // Inherited task@1.0.0 fields:
            "state": "pending",
        ]
        if let v = p.parentManuscriptRef    { dict["parent_manuscript_ref"]    = v }
        if let v = p.parentRevisionRef      { dict["parent_revision_ref"]      = v }
        if let v = p.submitterPersonaID     { dict["submitter_persona_id"]     = v }
        if let v = p.originConversationRef  { dict["origin_conversation_ref"]  = v }
        if let v = p.metadataJSON           { dict["metadata_json"]            = v }
        if let v = p.bibliographyPayload    { dict["bibliography_payload"]     = v }
        if let v = p.similarityHint         { dict["similarity_hint"]          = v }
        if let v = p.bundleManifestJSON     { dict["bundle_manifest_json"]     = v }

        guard JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        else {
            throw JournalSubmissionError.encodingFailed(
                "submission payload is not a valid JSON object"
            )
        }
        guard let s = String(data: data, encoding: .utf8) else {
            throw JournalSubmissionError.encodingFailed("payload data is not valid UTF-8")
        }
        return s
    }

    private func persist(id: String, payloadJSON: String) async throws {
        guard isAvailable else { throw JournalSubmissionError.storeUnavailable }
        #if canImport(ImpressRustCore)
        guard let store = store else { throw JournalSubmissionError.storeUnavailable }
        do {
            try store.upsertItem(
                id: id,
                schemaRef: "manuscript-submission",
                payloadJson: payloadJSON
            )
        } catch {
            throw JournalSubmissionError.persistenceFailed(error)
        }
        #else
        throw JournalSubmissionError.storeUnavailable
        #endif
    }
}

// MARK: - SubmissionRecord (read-side projection)

/// A submission as projected from the shared store. Used by Scout and the
/// inbox UI to inspect pending submissions without re-decoding the
/// full DTO. Every field is stored as a String because the
/// manuscript-submission schema's payload fields are all `FieldType::String`.
public struct SubmissionRecord: Sendable {
    public let itemID: String
    private let fields: [String: String]

    public init(itemID: String, fields: [String: String]) {
        self.itemID = itemID
        self.fields = fields
    }

    public var title: String? { fields["title"] }
    public var submissionKind: String? { fields["submission_kind"] }
    public var state: String? { fields["state"] }
    public var contentHash: String? { fields["content_hash"] }
    public var parentManuscriptRef: String? { fields["parent_manuscript_ref"] }
    public var sourceFormat: String? { fields["source_format"] }
    public var sourcePayload: String? { fields["source_payload"] }
    public var bundleManifestJSON: String? { fields["bundle_manifest_json"] }

    /// True when `sourcePayload` references a bundle archive rather than
    /// inline source. Mirrors `ManuscriptSubmission.isBundle`.
    public var isBundle: Bool {
        sourcePayload?.hasSuffix(".tar.zst") ?? false
    }

    public func field(_ key: String) -> String? { fields[key] }
}
