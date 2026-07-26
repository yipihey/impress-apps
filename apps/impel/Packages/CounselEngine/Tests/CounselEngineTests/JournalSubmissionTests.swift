//
//  JournalSubmissionTests.swift
//  CounselEngineTests
//
//  Unit tests for the journal submission entry point (Phase 1.1 of the
//  journal pipeline). Verifies validation, content hashing, payload
//  encoding, and round-trip storage in an in-memory SharedStore.
//

import CryptoKit
import Foundation
import Testing
@testable import CounselEngine

#if canImport(ImpressRustCore)
import ImpressRustCore
#endif

// MARK: - Validation

@Test func submissionRequiresNonEmptyTitle() async throws {
    let payload = ManuscriptSubmission(
        submissionKind: .newManuscript,
        title: "   ",  // whitespace only
        sourceFormat: .tex,
        sourcePayload: "\\documentclass{article}\\begin{document}hi\\end{document}"
    )
    let service = try testService()
    do {
        _ = try await service.submit(payload)
        Issue.record("expected invalid-payload error")
    } catch let JournalSubmissionError.invalidPayload(msg) {
        #expect(msg.contains("title"))
    }
}

@Test func submissionRequiresNonEmptySource() async throws {
    let payload = ManuscriptSubmission(
        submissionKind: .newManuscript,
        title: "ok",
        sourceFormat: .tex,
        sourcePayload: ""
    )
    let service = try testService()
    do {
        _ = try await service.submit(payload)
        Issue.record("expected invalid-payload error")
    } catch let JournalSubmissionError.invalidPayload(msg) {
        #expect(msg.contains("source_payload"))
    }
}

@Test func newRevisionRequiresParentManuscript() async throws {
    let payload = ManuscriptSubmission(
        submissionKind: .newRevision,
        title: "Revision",
        sourceFormat: .tex,
        sourcePayload: "x"
    )
    let service = try testService()
    do {
        _ = try await service.submit(payload)
        Issue.record("expected invalid-payload error")
    } catch let JournalSubmissionError.invalidPayload(msg) {
        #expect(msg.contains("parent_manuscript_ref"))
    }
}

@Test func fragmentRequiresParentManuscript() async throws {
    let payload = ManuscriptSubmission(
        submissionKind: .fragment,
        title: "Fragment",
        sourceFormat: .tex,
        sourcePayload: "x"
    )
    let service = try testService()
    do {
        _ = try await service.submit(payload)
        Issue.record("expected invalid-payload error")
    } catch let JournalSubmissionError.invalidPayload(msg) {
        #expect(msg.contains("parent_manuscript_ref"))
    }
}

// MARK: - Content hash

@Test func contentHashOfInlineSourceMatchesSHA256() async throws {
    let source = "\\section{Test}\nHello journal.\n"
    let payload = ManuscriptSubmission(
        submissionKind: .newManuscript,
        title: "Hash Test",
        sourceFormat: .tex,
        sourcePayload: source
    )
    let service = try testService()
    let result = try await service.submit(payload)

    let expected = SHA256.hash(data: Data(source.utf8))
        .compactMap { String(format: "%02x", $0) }
        .joined()
    #expect(result.contentHash == expected)
    #expect(result.contentHash.count == 64)
}

@Test func contentHashOfBlobReferenceExtractsHexDirectly() async throws {
    let knownHash = String(repeating: "a", count: 64)
    let payload = ManuscriptSubmission(
        submissionKind: .newManuscript,
        title: "Blob Ref",
        sourceFormat: .typst,
        sourcePayload: "blob:sha256:\(knownHash)"
    )
    let service = try testService()
    let result = try await service.submit(payload)
    #expect(result.contentHash == knownHash)
}

// MARK: - Round trip

@Test func submitThenListReturnsThePendingItem() async throws {
    let service = try testService()
    let payload = ManuscriptSubmission(
        submissionKind: .newManuscript,
        title: "Round Trip Paper",
        sourceFormat: .tex,
        sourcePayload: "\\documentclass{article}\\begin{document}rt\\end{document}",
        submitterPersonaID: "scout"
    )
    let result = try await service.submit(payload)
    #expect(result.status == "pending")

    let pending = try await service.listPendingSubmissions()
    let match = pending.first(where: { $0.itemID == result.taskID })
    #expect(match != nil)
    #expect(match?.title == "Round Trip Paper")
    #expect(match?.submissionKind == "new-manuscript")
    #expect(match?.state == "pending")
    #expect(match?.contentHash == result.contentHash)
}

@Test func taskIDIsLowercaseUUID() async throws {
    let service = try testService()
    let payload = ManuscriptSubmission(
        submissionKind: .newManuscript,
        title: "Case Test",
        sourceFormat: .tex,
        sourcePayload: "x"
    )
    let result = try await service.submit(payload)
    // The returned taskID must be lowercase to match Rust's Uuid::to_string()
    // canonical form — otherwise downstream FFI lookups by ID fail silently.
    #expect(result.taskID == result.taskID.lowercased())
    #expect(UUID(uuidString: result.taskID) != nil)
}

@Test func twoSubmissionsHaveDistinctTaskIDs() async throws {
    let service = try testService()
    let p1 = ManuscriptSubmission(
        submissionKind: .newManuscript,
        title: "A",
        sourceFormat: .tex,
        sourcePayload: "alpha"
    )
    let p2 = ManuscriptSubmission(
        submissionKind: .newManuscript,
        title: "B",
        sourceFormat: .tex,
        sourcePayload: "beta"
    )
    let r1 = try await service.submit(p1)
    let r2 = try await service.submit(p2)
    #expect(r1.taskID != r2.taskID)
    #expect(r1.contentHash != r2.contentHash)
}

// MARK: - JSON shape compatibility (DTO codable)

@Test func submissionDecodesFromOnTheWireJSON() throws {
    let json = """
    {
      "submission_kind": "new-manuscript",
      "title": "From the Wire",
      "source_format": "tex",
      "source_payload": "\\\\documentclass{article}",
      "submitter_persona_id": "scout",
      "metadata_json": "{\\"intended_journal\\":\\"PRD\\"}"
    }
    """.data(using: .utf8)!
    let payload = try JSONDecoder().decode(ManuscriptSubmission.self, from: json)
    #expect(payload.submissionKind == .newManuscript)
    #expect(payload.title == "From the Wire")
    #expect(payload.sourceFormat == .tex)
    #expect(payload.submitterPersonaID == "scout")
    #expect(payload.metadataJSON?.contains("PRD") == true)
}

@Test func resultEncodesToOnTheWireJSON() throws {
    let r = SubmissionResult(taskID: "abc", status: "pending", contentHash: "deadbeef")
    let data = try JSONEncoder().encode(r)
    let s = String(data: data, encoding: .utf8) ?? ""
    #expect(s.contains("\"task_id\""))
    #expect(s.contains("\"content_hash\""))
}

// MARK: - Helpers

/// Build an isolated JournalSubmissionService backed by a fresh on-disk
/// SQLite store under a temp directory. Each test gets its own store.
private func testService() throws -> JournalSubmissionService {
    try testServiceWithPath().0
}

private func testServiceWithPath() throws -> (JournalSubmissionService, String) {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("JournalSubmissionTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    let dbPath = tempDir.appendingPathComponent("test.sqlite").path
    let svc = try JournalSubmissionService(testStorePath: dbPath)
    return (svc, dbPath)
}
