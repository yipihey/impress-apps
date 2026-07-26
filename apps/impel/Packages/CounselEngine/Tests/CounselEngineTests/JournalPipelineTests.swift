//
//  JournalPipelineTests.swift
//  CounselEngineTests
//
//  Phase 3 tests for the JournalPipeline orchestrator. Drives
//  dispatchSnapshotIfWarranted directly (bypassing Darwin notifications)
//  to verify the source-resolution + auto-snapshot logic.
//

import Foundation
import Testing
@testable import CounselEngine

#if canImport(ImpressRustCore)
import ImpressRustCore
#endif

// MARK: - Helpers

private func freshSetup() throws -> (JournalPipeline, JournalSnapshotJob, SharedStore, String) {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("JournalPipelineTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    let dbPath = tempDir.appendingPathComponent("test.sqlite").path
    let job = try JournalSnapshotJob(testStorePath: dbPath)
    let pipeline = JournalPipeline(startupGraceSeconds: 0, snapshotJob: job, storePath: dbPath)
    let store = try SharedStore.open(path: dbPath)
    return (pipeline, job, store, dbPath)
}

private func writeManuscript(in store: SharedStore, title: String, status: String) throws -> String {
    let id = UUID().uuidString.lowercased()
    let payload: [String: Any] = [
        "title": title,
        "status": status,
        "current_revision_ref": "00000000-0000-0000-0000-000000000000",
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    try store.upsertItem(id: id, schemaRef: "manuscript", payloadJson: String(data: data, encoding: .utf8)!)
    return id
}

private func writeAcceptedSubmission(
    in store: SharedStore,
    parentManuscript: String,
    sourcePayload: String
) throws -> String {
    let id = UUID().uuidString.lowercased()
    let payload: [String: Any] = [
        "title": "Accepted submission",
        "submission_kind": "new-manuscript",
        "source_format": "tex",
        "source_payload": sourcePayload,
        "state": "accepted",
        "accepted_manuscript_ref": parentManuscript,
        "content_hash": String(repeating: "0", count: 64),
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    try store.upsertItem(id: id, schemaRef: "manuscript-submission", payloadJson: String(data: data, encoding: .utf8)!)
    return id
}

private func decode(_ json: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
}

// MARK: - Tests

@Test func dispatchOnSubmittedStatusCreatesRevision() async throws {
    let (pipeline, _, store, _) = try freshSetup()
    let manuscriptID = try writeManuscript(in: store, title: "P1", status: "submitted")
    _ = try writeAcceptedSubmission(in: store, parentManuscript: manuscriptID, sourcePayload: "alpha source")

    await pipeline.dispatchSnapshotIfWarranted(manuscriptID: manuscriptID)

    // Verify a revision item exists pointed-to by the manuscript.
    let row = try #require(try store.getItem(id: manuscriptID))
    let payload = decode(row.payloadJson)
    let revRef = payload["current_revision_ref"] as? String
    #expect(revRef != "00000000-0000-0000-0000-000000000000")
    let revRow = try #require(try store.getItem(id: revRef!))
    let revPayload = decode(revRow.payloadJson)
    #expect(revPayload["snapshot_reason"] as? String == "status-change")
    #expect(revPayload["revision_tag"] as? String == "submitted")
}

@Test func dispatchOnDraftStatusDoesNotSnapshot() async throws {
    let (pipeline, _, store, _) = try freshSetup()
    let manuscriptID = try writeManuscript(in: store, title: "Draft", status: "draft")
    _ = try writeAcceptedSubmission(in: store, parentManuscript: manuscriptID, sourcePayload: "anything")

    await pipeline.dispatchSnapshotIfWarranted(manuscriptID: manuscriptID)

    let row = try #require(try store.getItem(id: manuscriptID))
    let payload = decode(row.payloadJson)
    // current_revision_ref still the placeholder.
    #expect(payload["current_revision_ref"] as? String == "00000000-0000-0000-0000-000000000000")
}

@Test func dispatchWithNoAcceptedSubmissionIsNoOp() async throws {
    let (pipeline, _, store, _) = try freshSetup()
    let manuscriptID = try writeManuscript(in: store, title: "Lonely", status: "submitted")
    // Note: no accepted submission written.

    await pipeline.dispatchSnapshotIfWarranted(manuscriptID: manuscriptID)

    let row = try #require(try store.getItem(id: manuscriptID))
    let payload = decode(row.payloadJson)
    #expect(payload["current_revision_ref"] as? String == "00000000-0000-0000-0000-000000000000")
}

@Test func dispatchTwiceWithSameSourceIsIdempotent() async throws {
    let (pipeline, _, store, _) = try freshSetup()
    let manuscriptID = try writeManuscript(in: store, title: "Idempotent", status: "submitted")
    _ = try writeAcceptedSubmission(in: store, parentManuscript: manuscriptID, sourcePayload: "stable")

    await pipeline.dispatchSnapshotIfWarranted(manuscriptID: manuscriptID)
    let after1 = try #require(try store.getItem(id: manuscriptID))
    let revAfter1 = decode(after1.payloadJson)["current_revision_ref"] as? String

    await pipeline.dispatchSnapshotIfWarranted(manuscriptID: manuscriptID)
    let after2 = try #require(try store.getItem(id: manuscriptID))
    let revAfter2 = decode(after2.payloadJson)["current_revision_ref"] as? String

    #expect(revAfter1 == revAfter2, "idempotent dispatch must not create a new revision")
}

@Test func dispatchPicksMostRecentAcceptedSubmission() async throws {
    let (pipeline, _, store, _) = try freshSetup()
    let manuscriptID = try writeManuscript(in: store, title: "Latest wins", status: "submitted")

    _ = try writeAcceptedSubmission(in: store, parentManuscript: manuscriptID, sourcePayload: "older content")
    // Sleep so created_ms differs.
    try await Task.sleep(nanoseconds: 20_000_000)
    _ = try writeAcceptedSubmission(in: store, parentManuscript: manuscriptID, sourcePayload: "newer content")

    await pipeline.dispatchSnapshotIfWarranted(manuscriptID: manuscriptID)

    let row = try #require(try store.getItem(id: manuscriptID))
    let revRef = decode(row.payloadJson)["current_revision_ref"] as? String
    let revRow = try #require(try store.getItem(id: revRef!))
    let revPayload = decode(revRow.payloadJson)
    let sourceArchive = revPayload["source_archive_ref"] as? String

    // Newer content has a different SHA than older content; verify the
    // source_archive_ref's hash matches the SHA of "newer content".
    let expectedSuffix = String(
        SHA256_hex(of: "newer content")
    )
    #expect(sourceArchive == "blob:sha256:\(expectedSuffix)")
}

// Tiny helper duplicating SHA-256-hex without importing CryptoKit at the
// top (tests already depend on it transitively via @testable CounselEngine).
import CryptoKit
private func SHA256_hex(of text: String) -> String {
    SHA256.hash(data: Data(text.utf8))
        .compactMap { String(format: "%02x", $0) }
        .joined()
}
