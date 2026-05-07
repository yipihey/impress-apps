//
//  JournalReviewService.swift
//  CounselEngine
//
//  Phase 4 of the impress journal pipeline (per docs/plan-journal-pipeline.md
//  §3.4 + ADR-0011 D7 + ADR-0012 D2/D3).
//
//  Counsel persona's structured-review entry point and Artificer persona's
//  structured-revision-note entry point. Both services share an extraction
//  pattern: send a single completion request to AnthropicProvider with one
//  forced tool call; parse the resulting AIToolUse content into a typed
//  payload; write the corresponding knowledge-object item to SharedStore.
//
//  Why a single-shot tool call instead of NativeAgentLoop:
//  NativeAgentLoop is the right primitive for multi-turn agents that
//  iteratively call tools to research a question. For "extract one
//  structured value from the model" a single-shot AICompletionRequest with
//  `tools: [submit_*]` and a strong system prompt is simpler, has clearer
//  failure modes (single retry on parse error vs. nondeterministic loop
//  behaviour), and is fully mockable via the AIProvider protocol.
//
//  Per the Implementation Plan §8 Risk #1 mitigation: this service uses
//  Anthropic SDK with a JSON-schema-constrained tool. Apple Intelligence
//  `@Generable` remains a fallback if Anthropic response quality is
//  insufficient (Phase 5 polish).
//

import Foundation
import ImpressAI
import ImpressKit
import OSLog

#if canImport(ImpressRustCore)
import ImpressRustCore
#endif

// MARK: - Errors

public enum JournalReviewError: Error, LocalizedError {
    case storeUnavailable
    case revisionNotFound(String)
    case manuscriptNotFound(String)
    case modelDidNotCallTool
    case invalidToolPayload(String)
    case writeFailed(Error)
    case modelError(Error)

    public var errorDescription: String? {
        switch self {
        case .storeUnavailable:
            return "Shared impress-core store is not available"
        case .revisionNotFound(let id):
            return "Manuscript revision not found: \(id)"
        case .manuscriptNotFound(let id):
            return "Manuscript not found: \(id)"
        case .modelDidNotCallTool:
            return "Model returned text instead of calling the structured-output tool"
        case .invalidToolPayload(let msg):
            return "Tool payload missing required field or wrong shape: \(msg)"
        case .writeFailed(let err):
            return "Failed to persist review/revision-note: \(err.localizedDescription)"
        case .modelError(let err):
            return "Model call failed: \(err.localizedDescription)"
        }
    }
}

// MARK: - Verdict enums (mirror the schema vocabularies)

public enum ReviewVerdict: String, Codable, Sendable {
    case approve
    case approveWithChanges = "approve-with-changes"
    case requestRevision = "request-revision"
    case reject
}

public enum RevisionNoteVerdict: String, Codable, Sendable {
    case propose
    case accept
    case reject
    case defer_ = "defer"
}

// MARK: - CounselReviewService

/// Produces a `review/v1` knowledge object for a manuscript-revision via
/// Counsel (per ADR-0013).
public actor CounselReviewService {

    public static let shared = CounselReviewService()

    private let logger = Logger(subsystem: "com.impress.impel", category: "counsel-review")
    private let provider: AIProvider
    private var isAvailable = false

    #if canImport(ImpressRustCore)
    private var store: SharedStore?
    #endif

    /// Default init uses Anthropic + the shared workspace store.
    public init() {
        self.provider = AnthropicProvider()
        do {
            try SharedWorkspace.ensureDirectoryExists()
            #if canImport(ImpressRustCore)
            self.store = try SharedStore.open(path: SharedWorkspace.databaseURL.path)
            #endif
            self.isAvailable = true
        } catch {
            self.isAvailable = false
        }
    }

    /// Test/DI initializer.
    public init(provider: AIProvider, storePath: String) throws {
        self.provider = provider
        #if canImport(ImpressRustCore)
        self.store = try SharedStore.open(path: storePath)
        #endif
        self.isAvailable = true
    }

    // MARK: - Tool definition

    /// The single tool the model is expected to call. Schema matches the
    /// `review/v1` payload requirements in ADR-0012 D3.
    private static func reviewSubmitTool() -> AITool {
        AITool(
            name: "submit_journal_review",
            description: "Submit a structured review of the manuscript revision. Required: verdict, body. Optional: summary, sections, confidence, evidence_refs. Always call this tool exactly once with your review.",
            inputSchema: [
                "type": AnySendable("object"),
                "properties": AnySendable([
                    "verdict": AnySendable([
                        "type": AnySendable("string"),
                        "enum": AnySendable([
                            AnySendable("approve"),
                            AnySendable("approve-with-changes"),
                            AnySendable("request-revision"),
                            AnySendable("reject"),
                        ]),
                        "description": AnySendable("Overall verdict on the manuscript revision."),
                    ] as [String: AnySendable]),
                    "body": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Markdown body with the full critique. Use sections like ## Strengths, ## Concerns, ## Recommendation."),
                    ] as [String: AnySendable]),
                    "summary": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("One-paragraph summary of verdict and key concerns. Used by episodic-memory consumers."),
                    ] as [String: AnySendable]),
                    "confidence": AnySendable([
                        "type": AnySendable("number"),
                        "description": AnySendable("Reviewer confidence 0.0–1.0."),
                    ] as [String: AnySendable]),
                ] as [String: AnySendable]),
                "required": AnySendable([AnySendable("verdict"), AnySendable("body")]),
            ]
        )
    }

    // MARK: - Public API

    /// Request a structured review of the named manuscript-revision.
    ///
    /// Returns the ID of the newly-created `review/v1` item.
    @discardableResult
    public func reviewRevision(
        manuscriptID: String,
        revisionID: String,
        modelOverride: String? = nil
    ) async throws -> String {
        guard isAvailable else { throw JournalReviewError.storeUnavailable }
        #if canImport(ImpressRustCore)
        guard let store = store else { throw JournalReviewError.storeUnavailable }

        // 1. Load the revision to extract source / abstract for the prompt.
        guard let revRow = try? store.getItem(id: revisionID) else {
            throw JournalReviewError.revisionNotFound(revisionID)
        }
        guard let revPayload = try? Self.parsePayload(revRow.payloadJson) else {
            throw JournalReviewError.invalidToolPayload("revision payload not JSON")
        }

        let revisionTag = (revPayload["revision_tag"] as? String) ?? "unknown"
        let abstractText = (revPayload["abstract"] as? String) ?? ""
        let contentHash  = (revPayload["content_hash"] as? String) ?? ""

        // 2. Build the system prompt + user message.
        let systemPrompt = """
        You are Counsel, the impress journal pipeline's structured reviewer.
        Given a manuscript revision, produce a structured review by calling
        the `submit_journal_review` tool exactly once. The tool's input is
        a JSON object matching the review/v1 schema. Be concise but specific.
        Cite section numbers where possible.

        - Verdict semantics:
          - approve: ready as-is.
          - approve-with-changes: minor edits required; list them in body.
          - request-revision: substantive issues; explain in body.
          - reject: fundamental problems; explain in body.
        """

        let userText = """
        Please review manuscript-revision \(revisionTag) (content_hash: \(contentHash.prefix(12))…).

        Abstract / available content:
        \(abstractText.isEmpty ? "(no abstract recorded)" : abstractText)

        Call submit_journal_review now with your structured verdict and critique.
        """

        let request = AICompletionRequest(
            modelId: modelOverride,
            messages: [AIMessage(role: .user, text: userText)],
            systemPrompt: systemPrompt,
            maxTokens: 4096,
            tools: [Self.reviewSubmitTool()]
        )

        // 3. Call the model and extract the tool input.
        let response: AICompletionResponse
        do {
            response = try await provider.complete(request)
        } catch {
            throw JournalReviewError.modelError(error)
        }

        guard let toolUse = response.content.compactMap({ content -> AIToolUse? in
            if case .toolUse(let t) = content, t.name == "submit_journal_review" { return t }
            return nil
        }).first else {
            throw JournalReviewError.modelDidNotCallTool
        }

        // 4. Validate + project to a typed payload.
        guard let verdictStr: String = toolUse.input["verdict"]?.get(),
              ReviewVerdict(rawValue: verdictStr) != nil
        else {
            throw JournalReviewError.invalidToolPayload("verdict missing or not a known value")
        }
        guard let body: String = toolUse.input["body"]?.get(), !body.isEmpty else {
            throw JournalReviewError.invalidToolPayload("body missing or empty")
        }
        let summary: String? = toolUse.input["summary"]?.get()
        let confidence: Double? = (toolUse.input["confidence"]?.get() as Double?)
            ?? (toolUse.input["confidence"]?.get() as Int?).map(Double.init)

        // 5. Build the review/v1 payload.
        let reviewID = UUID().uuidString.lowercased()
        var reviewPayload: [String: Any] = [
            "subject_ref": revisionID,
            "verdict":     verdictStr,
            "body":        body,
            "agent_id":    "counsel",
        ]
        if let summary, !summary.isEmpty { reviewPayload["summary"] = summary }
        if let confidence { reviewPayload["confidence"] = max(0.0, min(1.0, confidence)) }

        try Self.writeItem(
            store: store,
            id: reviewID,
            schema: "review",
            payload: reviewPayload
        )

        // 6. Post the cross-app event so subscribers (imbib detail view) refresh.
        ImpressNotification.post(
            ImpressNotification.manuscriptReviewCompleted,
            from: .impel,
            resourceIDs: [manuscriptID, revisionID, reviewID]
        )
        logger.info(
            "CounselReviewService: review \(reviewID) for revision \(revisionID) verdict=\(verdictStr)"
        )
        return reviewID
        #else
        throw JournalReviewError.storeUnavailable
        #endif
    }

    // MARK: - Helpers

    nonisolated static func parsePayload(_ json: String) throws -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw JournalReviewError.invalidToolPayload("payload is not a JSON object") }
        return obj
    }

    #if canImport(ImpressRustCore)
    nonisolated static func writeItem(
        store: SharedStore,
        id: String,
        schema: String,
        payload: [String: Any]
    ) throws {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let s = String(data: data, encoding: .utf8) else {
            throw JournalReviewError.invalidToolPayload("payload data is not UTF-8")
        }
        do {
            try store.upsertItem(id: id, schemaRef: schema, payloadJson: s)
        } catch {
            throw JournalReviewError.writeFailed(error)
        }
    }
    #endif
}

// MARK: - ArtificerRevisionService

/// Produces a `revision-note/v1` knowledge object for a manuscript-revision
/// via Artificer (per ADR-0013). Typically invoked after a Counsel review
/// returns `request-revision` or `approve-with-changes`.
public actor ArtificerRevisionService {

    public static let shared = ArtificerRevisionService()

    private let logger = Logger(subsystem: "com.impress.impel", category: "artificer-revision")
    private let provider: AIProvider
    private var isAvailable = false

    #if canImport(ImpressRustCore)
    private var store: SharedStore?
    #endif

    public init() {
        self.provider = AnthropicProvider()
        do {
            try SharedWorkspace.ensureDirectoryExists()
            #if canImport(ImpressRustCore)
            self.store = try SharedStore.open(path: SharedWorkspace.databaseURL.path)
            #endif
            self.isAvailable = true
        } catch {
            self.isAvailable = false
        }
    }

    /// Test/DI initializer.
    public init(provider: AIProvider, storePath: String) throws {
        self.provider = provider
        #if canImport(ImpressRustCore)
        self.store = try SharedStore.open(path: storePath)
        #endif
        self.isAvailable = true
    }

    private static func revisionNoteSubmitTool() -> AITool {
        AITool(
            name: "submit_journal_revision_note",
            description: "Propose a manuscript revision in response to a review. Required: verdict (always 'propose' for new proposals), body, diff. Optional: target_section, evidence_refs. Always call this tool exactly once.",
            inputSchema: [
                "type": AnySendable("object"),
                "properties": AnySendable([
                    "verdict": AnySendable([
                        "type": AnySendable("string"),
                        "enum": AnySendable([
                            AnySendable("propose"),
                            AnySendable("accept"),
                            AnySendable("reject"),
                            AnySendable("defer"),
                        ]),
                        "description": AnySendable("Stance on the proposed revision. Use 'propose' for new agent-authored proposals."),
                    ] as [String: AnySendable]),
                    "body": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Prose explanation of the revision rationale (markdown)."),
                    ] as [String: AnySendable]),
                    "diff": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Unified diff text against the current revision's source. May span multiple files."),
                    ] as [String: AnySendable]),
                    "target_section": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("section_type value (e.g. 'methods') if the note is scoped to one section."),
                    ] as [String: AnySendable]),
                ] as [String: AnySendable]),
                "required": AnySendable([AnySendable("verdict"), AnySendable("body"), AnySendable("diff")]),
            ]
        )
    }

    /// Ask Artificer to produce a `revision-note/v1` for a revision, optionally
    /// in response to a specific review item.
    @discardableResult
    public func proposeRevision(
        manuscriptID: String,
        revisionID: String,
        reviewID: String? = nil,
        modelOverride: String? = nil
    ) async throws -> String {
        guard isAvailable else { throw JournalReviewError.storeUnavailable }
        #if canImport(ImpressRustCore)
        guard let store = store else { throw JournalReviewError.storeUnavailable }

        // 1. Load the revision context.
        guard let revRow = try? store.getItem(id: revisionID) else {
            throw JournalReviewError.revisionNotFound(revisionID)
        }
        let revPayload = (try? CounselReviewService.parsePayload(revRow.payloadJson)) ?? [:]
        let revisionTag = (revPayload["revision_tag"] as? String) ?? "unknown"

        // 2. Optionally load the motivating review.
        var reviewBlock = ""
        if let reviewID,
           let reviewRow = try? store.getItem(id: reviewID),
           let reviewPayload = try? CounselReviewService.parsePayload(reviewRow.payloadJson)
        {
            let v = (reviewPayload["verdict"] as? String) ?? "?"
            let body = (reviewPayload["body"] as? String) ?? ""
            reviewBlock = """

            Motivating review (verdict=\(v)):
            \(body)
            """
        }

        // 3. Compose prompt.
        let systemPrompt = """
        You are Artificer, the impress journal pipeline's revision drafter.
        Given a manuscript revision and (optionally) a review, propose
        precise, surgical changes by calling the `submit_journal_revision_note`
        tool exactly once. Your diff must be valid unified-diff format.
        Be conservative: only propose changes you are confident the human
        author would accept. Use verdict='propose' for new agent-authored
        proposals.
        """

        let userText = """
        Manuscript revision: \(revisionTag)
        \(reviewBlock)

        Call submit_journal_revision_note now with your proposed changes.
        """

        let request = AICompletionRequest(
            modelId: modelOverride,
            messages: [AIMessage(role: .user, text: userText)],
            systemPrompt: systemPrompt,
            maxTokens: 4096,
            tools: [Self.revisionNoteSubmitTool()]
        )

        let response: AICompletionResponse
        do {
            response = try await provider.complete(request)
        } catch {
            throw JournalReviewError.modelError(error)
        }

        guard let toolUse = response.content.compactMap({ content -> AIToolUse? in
            if case .toolUse(let t) = content, t.name == "submit_journal_revision_note" { return t }
            return nil
        }).first else {
            throw JournalReviewError.modelDidNotCallTool
        }

        guard let verdictStr: String = toolUse.input["verdict"]?.get(),
              RevisionNoteVerdict(rawValue: verdictStr) != nil
        else {
            throw JournalReviewError.invalidToolPayload("verdict missing or invalid")
        }
        guard let body: String = toolUse.input["body"]?.get(), !body.isEmpty else {
            throw JournalReviewError.invalidToolPayload("body missing or empty")
        }
        guard let diff: String = toolUse.input["diff"]?.get(), !diff.isEmpty else {
            throw JournalReviewError.invalidToolPayload("diff missing or empty")
        }
        let targetSection: String? = toolUse.input["target_section"]?.get()

        let noteID = UUID().uuidString.lowercased()
        var notePayload: [String: Any] = [
            "subject_ref": revisionID,
            "verdict":     verdictStr,
            "body":        body,
            "diff":        diff,
            "agent_id":    "artificer",
        ]
        if let targetSection, !targetSection.isEmpty {
            notePayload["target_section"] = targetSection
        }
        if let reviewID { notePayload["review_ref"] = reviewID }

        try CounselReviewService.writeItem(
            store: store,
            id: noteID,
            schema: "revision-note",
            payload: notePayload
        )

        ImpressNotification.post(
            ImpressNotification.manuscriptReviewCompleted,
            from: .impel,
            resourceIDs: [manuscriptID, revisionID, noteID]
        )
        logger.info(
            "ArtificerRevisionService: revision-note \(noteID) for revision \(revisionID) verdict=\(verdictStr)"
        )
        return noteID
        #else
        throw JournalReviewError.storeUnavailable
        #endif
    }
}
