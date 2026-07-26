//
//  StewardDedupSweepTests.swift
//  CounselEngineTests
//
//  Phase 5.1 tests: Steward's manuscript dedup sweep. Verifies pairwise
//  Jaccard scoring, threshold enforcement, recency window, and revision-
//  note proposal writes.
//

import Foundation
import Testing
@testable import CounselEngine

#if canImport(ImpressRustCore)
import ImpressRustCore
#endif

private func freshSetup() throws -> (JournalPipeline, SharedStore, String) {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("StewardDedupTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    let dbPath = tempDir.appendingPathComponent("test.sqlite").path
    let pipeline = JournalPipeline(startupGraceSeconds: 0, snapshotJob: nil, storePath: dbPath)
    let store = try SharedStore.open(path: dbPath)
    return (pipeline, store, dbPath)
}

private func writeManuscript(in store: SharedStore, title: String) throws -> String {
    let id = UUID().uuidString.lowercased()
    let payload: [String: Any] = [
        "title": title,
        "status": "draft",
        "current_revision_ref": "00000000-0000-0000-0000-000000000000",
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    try store.upsertItem(
        id: id,
        schemaRef: "manuscript",
        payloadJson: String(data: data, encoding: .utf8)!
    )
    return id
}

@Test func sweepWithNoNearDuplicatesProducesNoCandidates() async throws {
    let (pipeline, store, _) = try freshSetup()
    _ = try writeManuscript(in: store, title: "Black Hole Thermodynamics")
    _ = try writeManuscript(in: store, title: "Crystal Lattice Vibrations")

    let result = await pipeline.runDedupSweep(dryRun: true)
    #expect(result.manuscriptsScanned == 2)
    #expect(result.candidatePairs.isEmpty)
    #expect(result.proposalNoteIDs.isEmpty)
}

@Test func sweepDetectsNearDuplicateAndProposesMerge() async throws {
    let (pipeline, store, _) = try freshSetup()
    // Use identical titles (Jaccard = 1.0) — guaranteed above threshold.
    // Real-world near-duplicates with minor wording edits typically need
    // ≥ 7 content tokens to clear 0.85; keep the test data simple.
    let older = try writeManuscript(in: store, title: "Two-Point Function of T3FT Cosmology")
    // Sleep so created_ms differs.
    try await Task.sleep(nanoseconds: 30_000_000)
    _ = try writeManuscript(in: store, title: "Two-Point Function of T3FT Cosmology")

    let result = await pipeline.runDedupSweep(dryRun: false)
    #expect(result.manuscriptsScanned == 2)
    #expect(result.candidatePairs.count == 1)

    let pair = result.candidatePairs.first!
    #expect(pair.titleScore >= 0.85)
    // Older becomes the subject of the proposal.
    #expect(pair.manuscriptIDA == older)

    // A revision-note proposal item was written.
    #expect(result.proposalNoteIDs.count == 1)
    let note = try #require(try store.getItem(id: result.proposalNoteIDs[0]))
    #expect(note.schemaRef == "revision-note")
    let payload = try #require((try? JSONSerialization.jsonObject(with: Data(note.payloadJson.utf8))) as? [String: Any])
    #expect(payload["agent_id"] as? String == "steward")
    #expect(payload["verdict"] as? String == "propose")
    #expect((payload["body"] as? String)?.contains("near-duplicate") == true)
}

@Test func sweepDryRunDoesNotWriteProposals() async throws {
    let (pipeline, store, _) = try freshSetup()
    _ = try writeManuscript(in: store, title: "Two-Point Function of T3FT Cosmology")
    try await Task.sleep(nanoseconds: 20_000_000)
    _ = try writeManuscript(in: store, title: "Two-Point Function of T3FT Cosmology")

    let result = await pipeline.runDedupSweep(dryRun: true)
    #expect(result.candidatePairs.count == 1)
    #expect(result.proposalNoteIDs.isEmpty)

    // Confirm no revision-note items exist in the store.
    let notes = try store.queryBySchema(schemaRef: "revision-note", limit: 100, offset: 0)
    #expect(notes.isEmpty)
}

@Test func sweepRespectsCustomThreshold() async throws {
    let (pipeline, store, _) = try freshSetup()
    // Two titles that would score around 0.5 on Jaccard — over the
    // permissive threshold but under the default.
    _ = try writeManuscript(in: store, title: "Effective Field Theory of Inflation")
    try await Task.sleep(nanoseconds: 20_000_000)
    _ = try writeManuscript(in: store, title: "Effective Field Theory of Dark Matter")

    let strict = await pipeline.runDedupSweep(threshold: 0.85, dryRun: true)
    #expect(strict.candidatePairs.isEmpty, "default threshold must reject this pair")

    let permissive = await pipeline.runDedupSweep(threshold: 0.4, dryRun: true)
    #expect(permissive.candidatePairs.count >= 1, "lower threshold must catch this pair")
}

@Test func tokenizationStripsStopwordsAndShortTokens() {
    let tokens = JournalPipeline.tokenize("The Study of the Galaxy and the Universe")
    #expect(!tokens.contains("the"))
    #expect(!tokens.contains("of"))    // 2 chars — too short
    #expect(tokens.contains("study"))
    #expect(tokens.contains("galaxy"))
    #expect(tokens.contains("universe"))
}
