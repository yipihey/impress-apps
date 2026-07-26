//
//  JournalReviewServiceTests.swift
//  CounselEngineTests
//
//  Phase 4 tests for CounselReviewService and ArtificerRevisionService.
//  Uses a mock AIProvider so we can validate the structured-output extraction
//  + storage path without depending on a live Anthropic API key.
//

import Foundation
import ImpressAI
import Testing
@testable import CounselEngine

#if canImport(ImpressRustCore)
import ImpressRustCore
#endif

// MARK: - Mock provider

/// A scriptable mock AIProvider that returns a pre-built AICompletionResponse
/// for the next call to `complete(_:)`.
private final class MockAIProvider: AIProvider, @unchecked Sendable {

    var metadata: AIProviderMetadata {
        AIProviderMetadata(
            id: "mock",
            name: "Mock",
            models: [],
            capabilities: [.tools, .systemPrompt],
            credentialRequirement: .none,
            category: .custom
        )
    }

    private let responseProvider: @Sendable (AICompletionRequest) throws -> AICompletionResponse

    init(_ responseProvider: @escaping @Sendable (AICompletionRequest) throws -> AICompletionResponse) {
        self.responseProvider = responseProvider
    }

    func complete(_ request: AICompletionRequest) async throws -> AICompletionResponse {
        try responseProvider(request)
    }

    func validate() async throws -> AIProviderStatus { .ready }
}

private func makeToolUseResponse(
    toolName: String,
    input: [String: AnySendable]
) -> AICompletionResponse {
    AICompletionResponse(
        id: UUID().uuidString,
        content: [.toolUse(AIToolUse(id: "tu-\(UUID().uuidString)", name: toolName, input: input))],
        model: "mock",
        finishReason: .toolUse,
        usage: AIUsage(inputTokens: 10, outputTokens: 50)
    )
}

private func makeTextOnlyResponse(_ text: String) -> AICompletionResponse {
    AICompletionResponse(
        id: UUID().uuidString,
        content: [.text(text)],
        model: "mock",
        finishReason: .stop,
        usage: AIUsage(inputTokens: 10, outputTokens: 5)
    )
}

// MARK: - Setup helpers

private struct ReviewSetup {
    let counsel: CounselReviewService
    let artificer: ArtificerRevisionService
    let store: SharedStore
    let dbPath: String
    let manuscriptID: String
    let revisionID: String
}

private func freshSetup(
    counselProvider: AIProvider,
    artificerProvider: AIProvider
) throws -> ReviewSetup {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("JournalReviewTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    let dbPath = tempDir.appendingPathComponent("test.sqlite").path

    let store = try SharedStore.open(path: dbPath)

    // Seed a manuscript and a revision.
    let manuscriptID = UUID().uuidString.lowercased()
    let revisionID = UUID().uuidString.lowercased()
    let mPayload: [String: Any] = [
        "title": "Test Manuscript",
        "status": "submitted",
        "current_revision_ref": revisionID,
    ]
    try store.upsertItem(
        id: manuscriptID,
        schemaRef: "manuscript",
        payloadJson: String(data: try JSONSerialization.data(withJSONObject: mPayload, options: [.sortedKeys]), encoding: .utf8)!
    )
    let rPayload: [String: Any] = [
        "parent_manuscript_ref": manuscriptID,
        "revision_tag": "submitted",
        "content_hash": String(repeating: "a", count: 64),
        "pdf_artifact_ref": "00000000-0000-0000-0000-000000000001",
        "source_archive_ref": "blob:sha256:" + String(repeating: "a", count: 64),
        "abstract": "We compute X under conditions Y.",
    ]
    try store.upsertItem(
        id: revisionID,
        schemaRef: "manuscript-revision",
        payloadJson: String(data: try JSONSerialization.data(withJSONObject: rPayload, options: [.sortedKeys]), encoding: .utf8)!
    )

    let counsel = try CounselReviewService(provider: counselProvider, storePath: dbPath)
    let artificer = try ArtificerRevisionService(provider: artificerProvider, storePath: dbPath)
    return ReviewSetup(
        counsel: counsel,
        artificer: artificer,
        store: store,
        dbPath: dbPath,
        manuscriptID: manuscriptID,
        revisionID: revisionID
    )
}

private func decode(_ json: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
}

// MARK: - CounselReviewService

@Test func counselWritesReviewItemFromToolUseResponse() async throws {
    let mock = MockAIProvider { _ in
        makeToolUseResponse(toolName: "submit_journal_review", input: [
            "verdict": AnySendable("approve-with-changes"),
            "body":    AnySendable("Strong derivation but state BCs in §1."),
            "summary": AnySendable("Approve with three minor changes."),
            "confidence": AnySendable(0.85),
        ])
    }
    let dummyArtificer = MockAIProvider { _ in makeTextOnlyResponse("") }
    let setup = try freshSetup(counselProvider: mock, artificerProvider: dummyArtificer)

    let reviewID = try await setup.counsel.reviewRevision(
        manuscriptID: setup.manuscriptID,
        revisionID: setup.revisionID
    )

    let row = try #require(try setup.store.getItem(id: reviewID))
    #expect(row.schemaRef == "review")
    let payload = decode(row.payloadJson)
    #expect(payload["subject_ref"] as? String == setup.revisionID)
    #expect(payload["verdict"]     as? String == "approve-with-changes")
    #expect(payload["body"]        as? String == "Strong derivation but state BCs in §1.")
    #expect(payload["summary"]     as? String == "Approve with three minor changes.")
    #expect(payload["agent_id"]    as? String == "counsel")
    let conf = (payload["confidence"] as? Double) ?? (payload["confidence"] as? NSNumber)?.doubleValue
    #expect(conf == 0.85)
}

@Test func counselThrowsWhenModelReturnsTextOnly() async throws {
    let mock = MockAIProvider { _ in makeTextOnlyResponse("Sorry, I can't help.") }
    let dummyArtificer = MockAIProvider { _ in makeTextOnlyResponse("") }
    let setup = try freshSetup(counselProvider: mock, artificerProvider: dummyArtificer)

    do {
        _ = try await setup.counsel.reviewRevision(
            manuscriptID: setup.manuscriptID,
            revisionID: setup.revisionID
        )
        Issue.record("expected modelDidNotCallTool")
    } catch JournalReviewError.modelDidNotCallTool { /* ok */ }
    catch { Issue.record("unexpected error: \(error)") }
}

@Test func counselThrowsOnUnknownVerdict() async throws {
    let mock = MockAIProvider { _ in
        makeToolUseResponse(toolName: "submit_journal_review", input: [
            "verdict": AnySendable("destroy-it"),
            "body":    AnySendable("nope"),
        ])
    }
    let dummyArtificer = MockAIProvider { _ in makeTextOnlyResponse("") }
    let setup = try freshSetup(counselProvider: mock, artificerProvider: dummyArtificer)

    do {
        _ = try await setup.counsel.reviewRevision(
            manuscriptID: setup.manuscriptID,
            revisionID: setup.revisionID
        )
        Issue.record("expected invalidToolPayload")
    } catch JournalReviewError.invalidToolPayload { /* ok */ }
    catch { Issue.record("unexpected error: \(error)") }
}

@Test func counselThrowsOnEmptyBody() async throws {
    let mock = MockAIProvider { _ in
        makeToolUseResponse(toolName: "submit_journal_review", input: [
            "verdict": AnySendable("approve"),
            "body":    AnySendable(""),
        ])
    }
    let dummyArtificer = MockAIProvider { _ in makeTextOnlyResponse("") }
    let setup = try freshSetup(counselProvider: mock, artificerProvider: dummyArtificer)

    do {
        _ = try await setup.counsel.reviewRevision(
            manuscriptID: setup.manuscriptID,
            revisionID: setup.revisionID
        )
        Issue.record("expected invalidToolPayload")
    } catch JournalReviewError.invalidToolPayload { /* ok */ }
    catch { Issue.record("unexpected error: \(error)") }
}

@Test func counselThrowsWhenRevisionMissing() async throws {
    let mock = MockAIProvider { _ in makeTextOnlyResponse("") }
    let setup = try freshSetup(counselProvider: mock, artificerProvider: mock)

    do {
        _ = try await setup.counsel.reviewRevision(
            manuscriptID: setup.manuscriptID,
            revisionID: UUID().uuidString.lowercased()
        )
        Issue.record("expected revisionNotFound")
    } catch JournalReviewError.revisionNotFound { /* ok */ }
    catch { Issue.record("unexpected error: \(error)") }
}

@Test func counselClampsConfidenceTo01() async throws {
    let mock = MockAIProvider { _ in
        makeToolUseResponse(toolName: "submit_journal_review", input: [
            "verdict": AnySendable("approve"),
            "body":    AnySendable("OK."),
            "confidence": AnySendable(2.5),  // out of range; service must clamp
        ])
    }
    let dummyArtificer = MockAIProvider { _ in makeTextOnlyResponse("") }
    let setup = try freshSetup(counselProvider: mock, artificerProvider: dummyArtificer)
    let reviewID = try await setup.counsel.reviewRevision(
        manuscriptID: setup.manuscriptID,
        revisionID: setup.revisionID
    )
    let row = try #require(try setup.store.getItem(id: reviewID))
    let payload = decode(row.payloadJson)
    let conf = (payload["confidence"] as? Double) ?? (payload["confidence"] as? NSNumber)?.doubleValue
    #expect(conf == 1.0)
}

// MARK: - ArtificerRevisionService

@Test func artificerWritesRevisionNoteFromToolUseResponse() async throws {
    let counselMock = MockAIProvider { _ in makeTextOnlyResponse("") }
    let artificerMock = MockAIProvider { _ in
        makeToolUseResponse(toolName: "submit_journal_revision_note", input: [
            "verdict": AnySendable("propose"),
            "body":    AnySendable("Address reviewer point 2: state BCs."),
            "diff":    AnySendable("--- a/intro.tex\n+++ b/intro.tex\n@@ +3 +3 @@\n+We assume periodic BCs.\n"),
            "target_section": AnySendable("introduction"),
        ])
    }
    let setup = try freshSetup(counselProvider: counselMock, artificerProvider: artificerMock)

    let noteID = try await setup.artificer.proposeRevision(
        manuscriptID: setup.manuscriptID,
        revisionID: setup.revisionID
    )

    let row = try #require(try setup.store.getItem(id: noteID))
    #expect(row.schemaRef == "revision-note")
    let payload = decode(row.payloadJson)
    #expect(payload["subject_ref"]    as? String == setup.revisionID)
    #expect(payload["verdict"]        as? String == "propose")
    #expect(payload["body"]           as? String == "Address reviewer point 2: state BCs.")
    #expect((payload["diff"]          as? String)?.contains("periodic BCs") == true)
    #expect(payload["target_section"] as? String == "introduction")
    #expect(payload["agent_id"]       as? String == "artificer")
}

@Test func artificerLinksReviewRefWhenProvided() async throws {
    let counselMock = MockAIProvider { _ in
        makeToolUseResponse(toolName: "submit_journal_review", input: [
            "verdict": AnySendable("request-revision"),
            "body":    AnySendable("Section 3 unclear."),
        ])
    }
    let artificerMock = MockAIProvider { _ in
        makeToolUseResponse(toolName: "submit_journal_revision_note", input: [
            "verdict": AnySendable("propose"),
            "body":    AnySendable("Clarify §3."),
            "diff":    AnySendable("--- a/methods.tex\n+++ b/methods.tex\n+clarification\n"),
        ])
    }
    let setup = try freshSetup(counselProvider: counselMock, artificerProvider: artificerMock)

    let reviewID = try await setup.counsel.reviewRevision(
        manuscriptID: setup.manuscriptID,
        revisionID: setup.revisionID
    )
    let noteID = try await setup.artificer.proposeRevision(
        manuscriptID: setup.manuscriptID,
        revisionID: setup.revisionID,
        reviewID: reviewID
    )

    let noteRow = try #require(try setup.store.getItem(id: noteID))
    let payload = decode(noteRow.payloadJson)
    #expect(payload["review_ref"] as? String == reviewID)
}

@Test func artificerThrowsOnMissingDiff() async throws {
    let counselMock = MockAIProvider { _ in makeTextOnlyResponse("") }
    let artificerMock = MockAIProvider { _ in
        makeToolUseResponse(toolName: "submit_journal_revision_note", input: [
            "verdict": AnySendable("propose"),
            "body":    AnySendable("Vague suggestion."),
            // no diff field
        ])
    }
    let setup = try freshSetup(counselProvider: counselMock, artificerProvider: artificerMock)

    do {
        _ = try await setup.artificer.proposeRevision(
            manuscriptID: setup.manuscriptID,
            revisionID: setup.revisionID
        )
        Issue.record("expected invalidToolPayload")
    } catch JournalReviewError.invalidToolPayload { /* ok */ }
    catch { Issue.record("unexpected error: \(error)") }
}
