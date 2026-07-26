//
//  JournalScoutTests.swift
//  CounselEngineTests
//
//  Phase 1.3 tests: Scout's title-Jaccard tokenization, similarity scoring,
//  and triage outcome decisions.
//

import Foundation
import Testing
@testable import CounselEngine

#if canImport(ImpressRustCore)
import ImpressRustCore
#endif

// MARK: - Tokenization

@Test func tokenizationLowercasesAndStripsPunctuation() {
    let tokens = JournalScout.tokenize("Two-Point Function of T3FT Cosmology!")
    // Each content word kept as a 3+ char alphanumeric token, no punctuation.
    #expect(tokens.contains("two"))
    #expect(tokens.contains("point"))
    #expect(tokens.contains("function"))
    #expect(tokens.contains("t3ft"))
    #expect(tokens.contains("cosmology"))
    // "of" is too short (2 chars) — must be filtered.
    #expect(!tokens.contains("of"))
}

@Test func tokenizationDropsStopwords() {
    let tokens = JournalScout.tokenize("The Study of the Galaxy and the Universe")
    #expect(!tokens.contains("the"))
    #expect(!tokens.contains("and"))
    #expect(tokens.contains("study"))
    #expect(tokens.contains("galaxy"))
    #expect(tokens.contains("universe"))
}

// MARK: - Title Jaccard

@Test func identicalTitlesScoreOne() {
    let s = JournalScout.titleJaccard(
        "Two-Point Function of T3FT Cosmology",
        "Two-Point Function of T3FT Cosmology"
    )
    #expect(s == 1.0)
}

@Test func unrelatedTitlesScoreZero() {
    let s = JournalScout.titleJaccard(
        "Black Hole Thermodynamics",
        "Crystal Lattice Vibrations"
    )
    #expect(s == 0.0)
}

@Test func nearDuplicateScoreAboveThreshold() {
    // Same paper, slightly tweaked title — should pass the 0.7 threshold.
    let s = JournalScout.titleJaccard(
        "Two-Point Function of T3FT Cosmology",
        "Two-Point Function of T3FT Cosmology (revised)"
    )
    #expect(s >= 0.7, "near-duplicate titles must score >= 0.7, got \(s)")
}

@Test func partialOverlapBelowThreshold() {
    // Shared topic word, otherwise different — should fall well under 0.7.
    let s = JournalScout.titleJaccard(
        "Two-Point Function of T3FT Cosmology",
        "Bispectrum Estimators in T3FT Cosmology"
    )
    #expect(s < 0.7, "partial-overlap titles should score < 0.7, got \(s)")
    #expect(s > 0.0)
}

@Test func emptyTitleYieldsZero() {
    #expect(JournalScout.titleJaccard("", "anything") == 0.0)
    #expect(JournalScout.titleJaccard("anything", "") == 0.0)
}

// MARK: - Triage outcomes (with in-memory store)

@Test func triageWithNoExistingManuscriptsReturnsNewManuscript() async throws {
    let (scout, submitter) = try testScoutAndSubmitter()
    let result = try await submitter.submit(ManuscriptSubmission(
        submissionKind: .newManuscript,
        title: "Brand New Paper on Cosmology",
        sourceFormat: .tex,
        sourcePayload: "x"
    ))
    let report = try await scout.triage(submissionID: result.taskID)
    #expect(report.outcome == .newManuscript)
    #expect(report.candidates.isEmpty)
}

@Test func triageWithUnrelatedManuscriptsStillReturnsNewManuscript() async throws {
    let (scout, submitter, dbPath) = try testScoutSubmitterPath()

    // Seed an unrelated manuscript directly via SharedStore.
    #if canImport(ImpressRustCore)
    let store = try SharedStore.open(path: dbPath)
    let id = UUID().uuidString.lowercased()
    try store.upsertItem(
        id: id,
        schemaRef: "manuscript",
        payloadJson: #"{"title": "Crystal Lattice Vibrations", "status": "draft", "current_revision_ref": "00000000-0000-0000-0000-000000000000"}"#
    )
    #endif

    let result = try await submitter.submit(ManuscriptSubmission(
        submissionKind: .newManuscript,
        title: "Black Hole Thermodynamics in de Sitter Space",
        sourceFormat: .tex,
        sourcePayload: "x"
    ))
    let report = try await scout.triage(submissionID: result.taskID)
    #expect(report.outcome == .newManuscript)
}

@Test func triageWithNearDuplicateProposesNewRevision() async throws {
    let (scout, submitter, dbPath) = try testScoutSubmitterPath()

    #if canImport(ImpressRustCore)
    let store = try SharedStore.open(path: dbPath)
    let parentID = UUID().uuidString.lowercased()
    try store.upsertItem(
        id: parentID,
        schemaRef: "manuscript",
        payloadJson: #"{"title": "Two-Point Function of T3FT Cosmology", "status": "draft", "current_revision_ref": "00000000-0000-0000-0000-000000000000"}"#
    )
    #endif

    let result = try await submitter.submit(ManuscriptSubmission(
        submissionKind: .newManuscript,  // Submitter said new, but Scout should detect duplicate.
        title: "Two-Point Function of T3FT Cosmology (revised)",
        sourceFormat: .tex,
        sourcePayload: "x"
    ))
    let report = try await scout.triage(submissionID: result.taskID)

    #if canImport(ImpressRustCore)
    if case .newRevisionOf(let mid, let score) = report.outcome {
        #expect(mid == parentID)
        #expect(score >= 0.7)
    } else {
        Issue.record("expected .newRevisionOf, got \(report.outcome)")
    }
    #expect(report.candidates.first?.manuscriptID == parentID)
    #endif
}

@Test func triageOfFragmentReturnsFragmentOf() async throws {
    let (scout, submitter, dbPath) = try testScoutSubmitterPath()

    #if canImport(ImpressRustCore)
    let store = try SharedStore.open(path: dbPath)
    let parentID = UUID().uuidString.lowercased()
    try store.upsertItem(
        id: parentID,
        schemaRef: "manuscript",
        payloadJson: #"{"title": "Parent Paper", "status": "draft", "current_revision_ref": "00000000-0000-0000-0000-000000000000"}"#
    )
    #endif

    let result = try await submitter.submit(ManuscriptSubmission(
        submissionKind: .fragment,
        title: "Methods Section Excerpt",
        sourceFormat: .tex,
        sourcePayload: "x",
        parentManuscriptRef: {
            #if canImport(ImpressRustCore)
            return UUID().uuidString.lowercased()  // overridden below
            #else
            return nil
            #endif
        }()
    ))
    // Note: above placeholder isn't ideal — we want the real parentID.
    // Resubmit with the real parent.
    let realResult = try await submitter.submit(ManuscriptSubmission(
        submissionKind: .fragment,
        title: "Methods Section Excerpt",
        sourceFormat: .tex,
        sourcePayload: "y",
        parentManuscriptRef: {
            #if canImport(ImpressRustCore)
            // Use the seeded parent we created above.
            // (For test simplicity, the parentID is captured outside the closure.)
            return ""
            #else
            return nil
            #endif
        }()
    ))
    _ = result; _ = realResult  // silence unused warnings; the real assertion is below

    #if canImport(ImpressRustCore)
    // Build a submission that explicitly references the real parent.
    let fragSubmission = ManuscriptSubmission(
        submissionKind: .fragment,
        title: "Methods Section Excerpt",
        sourceFormat: .tex,
        sourcePayload: "z",
        parentManuscriptRef: parentID
    )
    let r = try await submitter.submit(fragSubmission)
    let report = try await scout.triage(submissionID: r.taskID)
    if case .fragmentOf(let mid) = report.outcome {
        #expect(mid == parentID)
    } else {
        Issue.record("expected .fragmentOf, got \(report.outcome)")
    }
    #endif
}

// MARK: - Helpers

private func testScoutAndSubmitter() throws -> (JournalScout, JournalSubmissionService) {
    let (s, sub, _) = try testScoutSubmitterPath()
    return (s, sub)
}

private func testScoutSubmitterPath() throws -> (JournalScout, JournalSubmissionService, String) {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("JournalScoutTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    let dbPath = tempDir.appendingPathComponent("test.sqlite").path
    let scout = try JournalScout(testStorePath: dbPath)
    let submitter = try JournalSubmissionService(testStorePath: dbPath)
    return (scout, submitter, dbPath)
}
