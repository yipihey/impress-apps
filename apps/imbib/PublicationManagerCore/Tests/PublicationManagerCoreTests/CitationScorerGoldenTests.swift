//
//  CitationScorerGoldenTests.swift
//  PublicationManagerCoreTests
//
//  Behaviour PIN for AutomationService.scoreCandidate and the ADS
//  auto-accept rules of resolveStructuredCitation (work package S2a of the
//  source convention, recorded before the Rust port). Scores in
//  Fixtures/citation-scorer-goldens.json came from running the Swift scorer,
//  not from the formula. They pin behaviour, NOT correctness: see
//  Fixtures/NOTES.md for the recorded decisions that look wrong.
//
//  Re-record (after an intentional scorer change only):
//    CITATION_GOLDEN_RECORD_IN=<cases.json> CITATION_GOLDEN_RECORD_OUT=<out.json> \
//      swift test --filter CitationScorerGolden
//

import XCTest
import ImbibRustCore
@testable import PublicationManagerCore

final class CitationScorerGoldenTests: XCTestCase {

    struct Candidate: Codable {
        var title: String
        var authors: [String]
        var year: Int?
        var venue: String?
        var doi: String?
        var arxiv: String?
        var bibcode: String?

        var external: ExternalSearchResult {
            ExternalSearchResult(
                title: title, authors: authors, year: year, venue: venue ?? "",
                abstract: "", sourceID: "golden", doi: doi, arxivID: arxiv, bibcode: bibcode
            )
        }
    }

    struct Case: Codable {
        var name: String
        var citation: CitationInput
        var candidates: [Candidate]
        var scores: [Double]?
        var accepted: Int?
        var rule: String?
        var kept: [Int]?
    }

    struct Outcome {
        var scores: [Double]
        var accepted: Int?
        var rule: String?
        var kept: [Int]
    }

    // MARK: - The cascade, as resolveStructuredCitation runs it

    /// Decode LaTeX exactly as resolveStructuredCitation does, then score.
    private func scores(_ c: Case) async -> [Double] {
        let service = AutomationService()
        let input = c.citation
        let authors = input.authors.map { ImbibRustCore.decodeLatex(input: $0) }
        let title = input.title.map { ImbibRustCore.decodeLatex(input: $0) }
        let journal = input.journal.map { ImbibRustCore.decodeLatex(input: $0) }
        var out: [Double] = []
        for cand in c.candidates {
            out.append(await service.scoreCandidateForTesting(
                cand.external, against: input,
                decodedAuthors: authors, decodedTitle: title, decodedJournal: journal))
        }
        return out
    }

    /// Copy of the `shouldAutoAccept` closure and the >= 0.30 filter in
    /// resolveStructuredCitation (step 3). Candidates are ranked by score
    /// descending (ties keep input order here; the Swift sort is unspecified).
    private func decide(_ scores: [Double]) -> (accepted: Int?, rule: String?, kept: [Int]) {
        let ranked = scores.enumerated().sorted {
            $0.element != $1.element ? $0.element > $1.element : $0.offset < $1.offset
        }
        let kept = ranked.filter { $0.element >= 0.30 }.map { $0.offset }
        guard let top = ranked.first else { return (nil, nil, kept) }
        let runnerUp = ranked.dropFirst().first?.element ?? 0
        if top.element >= 0.85 && (top.element - runnerUp) >= 0.15 { return (top.offset, "high-confidence", kept) }
        if ranked.count == 1 && top.element >= 0.50 { return (top.offset, "single-hit", kept) }
        if top.element >= 0.70 && (top.element - runnerUp) >= 0.25 { return (top.offset, "margin", kept) }
        return (nil, nil, kept)
    }

    private func outcome(_ c: Case) async -> Outcome {
        let s = await scores(c)
        let d = decide(s)
        return Outcome(scores: s, accepted: d.accepted, rule: d.rule, kept: d.kept)
    }

    // MARK: - Tests

    func testGoldens() async throws {
        let env = ProcessInfo.processInfo.environment
        if let inPath = env["CITATION_GOLDEN_RECORD_IN"], let outPath = env["CITATION_GOLDEN_RECORD_OUT"] {
            try await record(inPath: inPath, outPath: outPath)
            return
        }
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "citation-scorer-goldens", withExtension: "json", subdirectory: "Fixtures"))
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
        XCTAssertGreaterThan(cases.count, 40)
        for c in cases {
            let got = await outcome(c)
            let want = try XCTUnwrap(c.scores, c.name)
            XCTAssertEqual(got.scores.count, want.count, c.name)
            for (i, (g, w)) in zip(got.scores, want).enumerated() {
                XCTAssertEqual(g, w, accuracy: 1e-9, "\(c.name) candidate \(i)")
            }
            XCTAssertEqual(got.accepted, c.accepted, "\(c.name) accepted")
            XCTAssertEqual(got.rule, c.rule, "\(c.name) rule")
            XCTAssertEqual(got.kept, c.kept ?? [], "\(c.name) kept")
        }
    }

    private func record(inPath: String, outPath: String) async throws {
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: URL(fileURLWithPath: inPath)))
        var rows: [[String: Any]] = []
        for c in cases {
            let o = await outcome(c)
            rows.append([
                "name": c.name,
                "scores": o.scores,
                "accepted": o.accepted.map { $0 as Any } ?? NSNull(),
                "rule": o.rule.map { $0 as Any } ?? NSNull(),
                "kept": o.kept,
            ])
        }
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted])
        try data.write(to: URL(fileURLWithPath: outPath))
    }
}
