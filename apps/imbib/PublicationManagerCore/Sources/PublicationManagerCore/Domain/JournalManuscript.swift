//
//  JournalManuscript.swift
//  PublicationManagerCore
//
//  Phase 2 of the impress journal pipeline (per docs/plan-journal-pipeline.md
//  §3.1 + ADR-0011 D1/D2/D6).
//
//  Swift-side projections of the journal pipeline schemas registered in
//  `crates/impress-core/src/schemas/`:
//    - `manuscript@1.0.0`           → JournalManuscript
//    - `manuscript-revision@1.0.0`  → JournalRevision
//    - `manuscript-submission@1.0.0`→ JournalSubmissionRecord
//
//  These are READ-side projections used by imbib's Journal sidebar and
//  ManuscriptDetailView. They mirror the Rust schema field shapes but are
//  decoded from the `payload_json` string returned by SharedStore.
//
//  Mutations go through `ManuscriptBridge` (sibling SharedStore handle).
//  Submissions are AUTHORED via the impel-side `JournalSubmissionService`
//  in CounselEngine — imbib only reads them here.
//

import Foundation

// MARK: - Status

/// Lifecycle state of a journal manuscript per ADR-0011 D1.
public enum JournalManuscriptStatus: String, Codable, CaseIterable, Sendable {
    case draft
    case internalReview = "internal-review"
    case submitted
    case inRevision = "in-revision"
    case published
    case archived

    public var displayName: String {
        switch self {
        case .draft:          return "Draft"
        case .internalReview: return "Internal Review"
        case .submitted:      return "Submitted"
        case .inRevision:     return "In Revision"
        case .published:      return "Published"
        case .archived:       return "Archived"
        }
    }

    public var systemImage: String {
        switch self {
        case .draft:          return "pencil"
        case .internalReview: return "eye"
        case .submitted:      return "paperplane"
        case .inRevision:     return "arrow.triangle.2.circlepath"
        case .published:      return "checkmark.seal"
        case .archived:       return "archivebox"
        }
    }

    public var isActive: Bool {
        switch self {
        case .draft, .internalReview, .submitted, .inRevision: return true
        case .published, .archived:                            return false
        }
    }
}

// MARK: - Manuscript

/// Read-side projection of a `manuscript@1.0.0` item. Field semantics per
/// ADR-0011 D1 and the schema in `crates/impress-core/src/schemas/manuscript.rs`.
public struct JournalManuscript: Identifiable, Equatable, Sendable {

    /// Stable item ID (UUID). Lowercase per the Rust canonical form.
    public let id: String

    public let title: String
    public let status: JournalManuscriptStatus

    /// Item ID of the most recent `manuscript-revision`. May be the all-zero
    /// placeholder UUID if no revision has been snapshotted yet (Phase 3).
    public let currentRevisionRef: String

    public let authors: [String]
    public let journalTarget: String?
    public let submissionID: String?
    public let topicTags: [String]
    public let notes: String?

    public init(
        id: String,
        title: String,
        status: JournalManuscriptStatus,
        currentRevisionRef: String,
        authors: [String] = [],
        journalTarget: String? = nil,
        submissionID: String? = nil,
        topicTags: [String] = [],
        notes: String? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.currentRevisionRef = currentRevisionRef
        self.authors = authors
        self.journalTarget = journalTarget
        self.submissionID = submissionID
        self.topicTags = topicTags
        self.notes = notes
    }

    /// Decode from a `payload_json` string returned by SharedStore. Returns
    /// nil if required fields are missing or malformed; the caller decides
    /// whether to log or silently drop the row.
    public static func decode(itemID: String, payloadJSON: String) -> JournalManuscript? {
        guard let data = payloadJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        guard let title = obj["title"] as? String,
              let statusStr = obj["status"] as? String,
              let status = JournalManuscriptStatus(rawValue: statusStr),
              let currentRev = obj["current_revision_ref"] as? String
        else { return nil }

        return JournalManuscript(
            id: itemID,
            title: title,
            status: status,
            currentRevisionRef: currentRev,
            authors: (obj["authors"] as? [String]) ?? [],
            journalTarget: obj["journal_target"] as? String,
            submissionID: obj["submission_id"] as? String,
            topicTags: (obj["topic_tags"] as? [String]) ?? [],
            notes: obj["notes"] as? String
        )
    }
}

// MARK: - Revision

/// Read-side projection of a `manuscript-revision@1.0.0` item. Per ADR-0011
/// D2 these items are immutable — modifying the payload is rejected at the
/// store boundary (see `crates/impress-core/src/sqlite_store.rs` and the
/// `revision_items_reject_payload_mutations` test).
public struct JournalRevision: Identifiable, Equatable, Sendable {

    public let id: String
    public let parentManuscriptRef: String
    public let revisionTag: String        // e.g. "v1", "submitted", "referee-response-1"
    public let contentHash: String        // SHA-256 hex of the source archive
    public let pdfArtifactRef: String     // ItemID of the artifact carrying the PDF
    public let sourceArchiveRef: String   // ItemID of the artifact carrying .tar.zst
    public let predecessorRevisionRef: String?
    public let compileLogRef: String?
    public let snapshotReason: String?    // status-change | user-tag | stable-churn | manual
    public let abstractText: String?
    public let wordCount: Int?
    /// Phase 8: present when the source is a directory bundle. Carries
    /// the JSON-encoded `manuscript-bundle-manifest@1.0.0` mirroring the
    /// archive's `manifest.json`. Use `bundleEntries()` to parse.
    public let bundleManifestJSON: String?

    public init(
        id: String,
        parentManuscriptRef: String,
        revisionTag: String,
        contentHash: String,
        pdfArtifactRef: String,
        sourceArchiveRef: String,
        predecessorRevisionRef: String? = nil,
        compileLogRef: String? = nil,
        snapshotReason: String? = nil,
        abstractText: String? = nil,
        wordCount: Int? = nil,
        bundleManifestJSON: String? = nil
    ) {
        self.id = id
        self.parentManuscriptRef = parentManuscriptRef
        self.revisionTag = revisionTag
        self.contentHash = contentHash
        self.pdfArtifactRef = pdfArtifactRef
        self.sourceArchiveRef = sourceArchiveRef
        self.predecessorRevisionRef = predecessorRevisionRef
        self.compileLogRef = compileLogRef
        self.snapshotReason = snapshotReason
        self.abstractText = abstractText
        self.wordCount = wordCount
        self.bundleManifestJSON = bundleManifestJSON
    }

    public static func decode(itemID: String, payloadJSON: String) -> JournalRevision? {
        guard let data = payloadJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        guard let parent = obj["parent_manuscript_ref"] as? String,
              let tag = obj["revision_tag"] as? String,
              let hash = obj["content_hash"] as? String,
              let pdfRef = obj["pdf_artifact_ref"] as? String,
              let archiveRef = obj["source_archive_ref"] as? String
        else { return nil }

        return JournalRevision(
            id: itemID,
            parentManuscriptRef: parent,
            revisionTag: tag,
            contentHash: hash,
            pdfArtifactRef: pdfRef,
            sourceArchiveRef: archiveRef,
            predecessorRevisionRef: obj["predecessor_revision_ref"] as? String,
            compileLogRef: obj["compile_log_ref"] as? String,
            snapshotReason: obj["snapshot_reason"] as? String,
            abstractText: obj["abstract"] as? String,
            wordCount: (obj["word_count"] as? Int)
                ?? (obj["word_count"] as? NSNumber).map { $0.intValue },
            bundleManifestJSON: obj["bundle_manifest_json"] as? String
        )
    }

    /// True when this revision's source is a directory bundle (Phase 8).
    public var isBundle: Bool { bundleManifestJSON != nil }

    /// Parsed bundle entries (path + role) from the manifest, or nil if
    /// this isn't a bundle revision or the manifest is malformed.
    public func bundleEntries() -> [JournalBundleEntry]? {
        guard let json = bundleManifestJSON,
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = obj["entries"] as? [[String: Any]]
        else { return nil }
        return entries.compactMap { e in
            guard let path = e["path"] as? String, let role = e["role"] as? String else { return nil }
            return JournalBundleEntry(path: path, role: role)
        }
    }

    /// Main source path (relative) from the manifest. Nil for inline-text revisions.
    public var bundleMainSource: String? {
        guard let json = bundleManifestJSON,
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj["main_source"] as? String
    }

    /// Source format from the manifest (e.g. "tex", "typst", "markdown", "html").
    public var bundleSourceFormat: String? {
        guard let json = bundleManifestJSON,
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj["source_format"] as? String
    }
}

/// One entry in a bundle's manifest, projected for UI/exporter use.
/// Mirrors the Rust `BundleEntry` and Swift CounselEngine `BundleEntry`.
public struct JournalBundleEntry: Identifiable, Equatable, Sendable, Hashable {
    public let path: String
    public let role: String  // "main" | "bibliography" | "figure" | "supplement" | "chapter" | "aux"

    public var id: String { path }

    public init(path: String, role: String) {
        self.path = path
        self.role = role
    }

    /// SF Symbol name appropriate for the role.
    public var systemImage: String {
        switch role {
        case "main": return "doc.text.fill"
        case "bibliography": return "books.vertical.fill"
        case "figure": return "photo.fill"
        case "supplement": return "doc.text"
        case "chapter": return "list.bullet.rectangle"
        case "aux": return "doc.zipper"
        default: return "doc"
        }
    }

    /// Display label for the role.
    public var displayRole: String {
        switch role {
        case "main": return "Main"
        case "bibliography": return "Bibliography"
        case "figure": return "Figure"
        case "supplement": return "Supplement"
        case "chapter": return "Chapter"
        case "aux": return "Auxiliary"
        default: return role.capitalized
        }
    }
}

// MARK: - Submission record (read projection)

/// Submission kind echoing the impel-side `SubmissionKind` enum in CounselEngine.
/// Re-declared here so PublicationManagerCore doesn't need to depend on
/// CounselEngine just to read submissions.
public enum JournalSubmissionKind: String, Codable, CaseIterable, Sendable {
    case newManuscript = "new-manuscript"
    case newRevision   = "new-revision"
    case fragment

    public var displayName: String {
        switch self {
        case .newManuscript: return "New Manuscript"
        case .newRevision:   return "New Revision"
        case .fragment:      return "Fragment"
        }
    }

    public var systemImage: String {
        switch self {
        case .newManuscript: return "doc.badge.plus"
        case .newRevision:   return "doc.badge.arrow.up"
        case .fragment:      return "doc.text.below.ecg"
        }
    }
}

/// Submission lifecycle state echoing the inherited `task` schema's `state` field.
public enum JournalSubmissionState: String, Codable, CaseIterable, Sendable {
    case pending
    case running
    case accepted
    case completed
    case failed
    case cancelled
}

/// Read-side projection of a `manuscript-submission@1.0.0` item.
public struct JournalSubmissionRecord: Identifiable, Equatable, Sendable {

    public let id: String
    public let title: String
    public let submissionKind: JournalSubmissionKind
    public let state: JournalSubmissionState
    public let sourceFormat: String?            // "tex" | "typst"
    public let sourcePayload: String?           // inline source or "blob:sha256:..."
    public let contentHash: String?
    public let parentManuscriptRef: String?
    public let parentRevisionRef: String?
    public let submitterPersonaID: String?
    public let originConversationRef: String?
    public let similarityHint: String?

    public init(
        id: String,
        title: String,
        submissionKind: JournalSubmissionKind,
        state: JournalSubmissionState,
        sourceFormat: String? = nil,
        sourcePayload: String? = nil,
        contentHash: String? = nil,
        parentManuscriptRef: String? = nil,
        parentRevisionRef: String? = nil,
        submitterPersonaID: String? = nil,
        originConversationRef: String? = nil,
        similarityHint: String? = nil
    ) {
        self.id = id
        self.title = title
        self.submissionKind = submissionKind
        self.state = state
        self.sourceFormat = sourceFormat
        self.sourcePayload = sourcePayload
        self.contentHash = contentHash
        self.parentManuscriptRef = parentManuscriptRef
        self.parentRevisionRef = parentRevisionRef
        self.submitterPersonaID = submitterPersonaID
        self.originConversationRef = originConversationRef
        self.similarityHint = similarityHint
    }

    public static func decode(itemID: String, payloadJSON: String) -> JournalSubmissionRecord? {
        guard let data = payloadJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        guard let title = obj["title"] as? String,
              let kindStr = obj["submission_kind"] as? String,
              let kind = JournalSubmissionKind(rawValue: kindStr),
              let stateStr = obj["state"] as? String,
              let state = JournalSubmissionState(rawValue: stateStr)
        else { return nil }

        return JournalSubmissionRecord(
            id: itemID,
            title: title,
            submissionKind: kind,
            state: state,
            sourceFormat: obj["source_format"] as? String,
            sourcePayload: obj["source_payload"] as? String,
            contentHash: obj["content_hash"] as? String,
            parentManuscriptRef: obj["parent_manuscript_ref"] as? String,
            parentRevisionRef: obj["parent_revision_ref"] as? String,
            submitterPersonaID: obj["submitter_persona_id"] as? String,
            originConversationRef: obj["origin_conversation_ref"] as? String,
            similarityHint: obj["similarity_hint"] as? String
        )
    }

    /// First N lines of the inline source content (or a placeholder for
    /// blob references). Used by the Submissions inbox row preview.
    public func sourcePreview(maxLines: Int = 10) -> String {
        guard let payload = sourcePayload, !payload.isEmpty else { return "" }
        if payload.hasPrefix("blob:sha256:") {
            return "(content stored as blob)"
        }
        let lines = payload.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.prefix(maxLines).joined(separator: "\n")
    }
}

// MARK: - Knowledge objects (Phase 4)

/// Verdict vocabulary for `review/v1` per ADR-0012 D3.
public enum JournalReviewVerdict: String, Codable, CaseIterable, Sendable {
    case approve
    case approveWithChanges = "approve-with-changes"
    case requestRevision = "request-revision"
    case reject

    public var displayName: String {
        switch self {
        case .approve:            return "Approve"
        case .approveWithChanges: return "Approve with Changes"
        case .requestRevision:    return "Request Revision"
        case .reject:             return "Reject"
        }
    }

    public var systemImage: String {
        switch self {
        case .approve:            return "checkmark.seal"
        case .approveWithChanges: return "checkmark.circle"
        case .requestRevision:    return "arrow.triangle.2.circlepath"
        case .reject:             return "xmark.octagon"
        }
    }
}

/// Read-side projection of a `review/v1` knowledge object.
public struct JournalReview: Identifiable, Equatable, Sendable {
    public let id: String
    public let subjectRef: String                    // ItemId of the manuscript-revision
    public let verdict: JournalReviewVerdict
    public let body: String
    public let summary: String?
    public let confidence: Double?
    public let agentID: String?                      // "counsel" if agent-authored
    public let agentRunRef: String?

    public init(
        id: String,
        subjectRef: String,
        verdict: JournalReviewVerdict,
        body: String,
        summary: String? = nil,
        confidence: Double? = nil,
        agentID: String? = nil,
        agentRunRef: String? = nil
    ) {
        self.id = id
        self.subjectRef = subjectRef
        self.verdict = verdict
        self.body = body
        self.summary = summary
        self.confidence = confidence
        self.agentID = agentID
        self.agentRunRef = agentRunRef
    }

    public static func decode(itemID: String, payloadJSON: String) -> JournalReview? {
        guard let data = payloadJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        guard let subj = obj["subject_ref"] as? String,
              let verdictStr = obj["verdict"] as? String,
              let verdict = JournalReviewVerdict(rawValue: verdictStr),
              let body = obj["body"] as? String
        else { return nil }
        let confidence = (obj["confidence"] as? Double)
            ?? (obj["confidence"] as? NSNumber)?.doubleValue
        return JournalReview(
            id: itemID,
            subjectRef: subj,
            verdict: verdict,
            body: body,
            summary: obj["summary"] as? String,
            confidence: confidence,
            agentID: obj["agent_id"] as? String,
            agentRunRef: obj["agent_run_ref"] as? String
        )
    }
}

/// Verdict vocabulary for `revision-note/v1` per ADR-0012 D4.
public enum JournalRevisionNoteVerdict: String, Codable, CaseIterable, Sendable {
    case propose
    case accept
    case reject
    case `defer`

    public var displayName: String {
        switch self {
        case .propose: return "Proposed"
        case .accept:  return "Accepted"
        case .reject:  return "Rejected"
        case .defer:   return "Deferred"
        }
    }

    public var systemImage: String {
        switch self {
        case .propose: return "lightbulb"
        case .accept:  return "checkmark.circle"
        case .reject:  return "xmark.circle"
        case .defer:   return "clock"
        }
    }
}

/// Read-side projection of a `revision-note/v1` knowledge object.
public struct JournalRevisionNote: Identifiable, Equatable, Sendable {
    public let id: String
    public let subjectRef: String                    // ItemId of the manuscript-revision
    public let verdict: JournalRevisionNoteVerdict
    public let body: String
    public let diff: String?
    public let targetSection: String?
    public let reviewRef: String?                    // ItemId of the motivating review (if any)
    public let agentID: String?                      // "artificer" if agent-authored

    public init(
        id: String,
        subjectRef: String,
        verdict: JournalRevisionNoteVerdict,
        body: String,
        diff: String? = nil,
        targetSection: String? = nil,
        reviewRef: String? = nil,
        agentID: String? = nil
    ) {
        self.id = id
        self.subjectRef = subjectRef
        self.verdict = verdict
        self.body = body
        self.diff = diff
        self.targetSection = targetSection
        self.reviewRef = reviewRef
        self.agentID = agentID
    }

    public static func decode(itemID: String, payloadJSON: String) -> JournalRevisionNote? {
        guard let data = payloadJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        guard let subj = obj["subject_ref"] as? String,
              let verdictStr = obj["verdict"] as? String,
              let verdict = JournalRevisionNoteVerdict(rawValue: verdictStr),
              let body = obj["body"] as? String
        else { return nil }
        return JournalRevisionNote(
            id: itemID,
            subjectRef: subj,
            verdict: verdict,
            body: body,
            diff: obj["diff"] as? String,
            targetSection: obj["target_section"] as? String,
            reviewRef: obj["review_ref"] as? String,
            agentID: obj["agent_id"] as? String
        )
    }

    /// First N lines of the diff for compact preview.
    public func diffPreview(maxLines: Int = 12) -> String {
        guard let diff, !diff.isEmpty else { return "" }
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.prefix(maxLines).joined(separator: "\n")
    }
}
