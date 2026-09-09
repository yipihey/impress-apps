//
//  AgentProvenanceDisplayTests.swift
//  PublicationManagerCoreTests
//
//  The Agents detail pane could show every field it had about a task and
//  still not say what the task was doing. A suspended task reads `running`,
//  its run summary describes work that already finished, and the question it
//  is actually waiting on lives on a SEPARATE item the task does not
//  reference — so "Running" for five days looked like a stuck daemon rather
//  than a queue waiting on a person.
//

import XCTest
import ImpressRustCore
@testable import PublicationManagerCore

final class SpawnRuleDescriptionTests: XCTestCase {

    /// "impel/enrichment-spawn" is accurate and nearly opaque. What a reader
    /// wants from "Launched By" is the EVENT that caused the task to exist.
    func testKnownRulesReadAsEvents() {
        XCTAssertEqual(
            AgentStoreReader.spawnRuleDescription("impel/enrichment-spawn"),
            "Enrichment pipeline — a paper entered the library"
        )
        XCTAssertEqual(
            AgentStoreReader.spawnRuleDescription("impel/throughline-source-spawn"),
            "Throughline sync — the narrative itself was edited"
        )
    }

    /// The two throughline rules fire on opposite sides of the same sync and
    /// must not read identically — that is the whole question a reader has.
    func testTheTwoThroughlineRulesAreDistinguishable() {
        XCTAssertNotEqual(
            AgentStoreReader.spawnRuleDescription("impel/throughline-spawn"),
            AgentStoreReader.spawnRuleDescription("impel/throughline-source-spawn")
        )
    }

    /// An unrecognised rule names itself rather than vanishing. A future rule
    /// this table has not learned yet must still say something true.
    func testUnknownRulesPassThroughUnchanged() {
        XCTAssertEqual(
            AgentStoreReader.spawnRuleDescription("impel/some-rule-added-later"),
            "impel/some-rule-added-later"
        )
        XCTAssertEqual(AgentStoreReader.spawnRuleDescription(""), "")
    }
}

final class PendingReviewParsingTests: XCTestCase {

    /// The review carries BOTH halves of what the task cannot say: which
    /// paper, and what is being proposed about it. The pane reads them from
    /// here, so the payload keys are a contract with impel's `open_review`.
    func testReviewCarriesTheQuestionAndTheProposedTags() throws {
        let row = SharedItemRow(
            id: "11111111-1111-4111-8111-111111111111",
            schemaRef: "review-request@1.0.0",
            payloadJson: """
            {"question":"Apply 2 proposed tag(s) to \\"The VariableTNG project\\"? Confidence below 0.50.",
             "context_proposed_tags":["ai/topic/galaxies","ai/methods/simulation"]}
            """,
            createdMs: 1_757_000_000_000,
            modifiedMs: 1_757_000_000_000,
            parentId: nil,
            isRead: false,
            isStarred: false,
            tags: [],
            flagColor: nil
        )
        let review = try XCTUnwrap(PendingReview(row: row))
        XCTAssertTrue(review.question.contains("VariableTNG"), "the paper is named in the question")
        XCTAssertEqual(review.proposedTags, ["ai/topic/galaxies", "ai/methods/simulation"])
        XCTAssertFalse(review.isResolved, "no resolution means it is still blocking")
    }

    /// A resolved review must not be reported as blocking, or an answered
    /// checkpoint would keep claiming the task is waiting.
    func testAResolvedReviewIsNotBlocking() throws {
        let row = SharedItemRow(
            id: "22222222-2222-4222-8222-222222222222",
            schemaRef: "review-request@1.0.0",
            payloadJson: #"{"question":"q","resolution":"approved"}"#,
            createdMs: 1_757_000_000_000,
            modifiedMs: 1_757_000_000_000,
            parentId: nil,
            isRead: false,
            isStarred: false,
            tags: [],
            flagColor: nil
        )
        let review = try XCTUnwrap(PendingReview(row: row))
        XCTAssertTrue(review.isResolved)
    }
}

// MARK: - "Which model did the tagging?"

/// A row labelled "Model" showing `heuristic-v1 (deterministic)` invites the
/// reader to assume `heuristic-v1` is one. It is a keyword table, and the
/// honest answer to "which model was used" is "none" — which the pane has to
/// say, not imply through a parenthetical.
final class ModelAttributionTests: XCTestCase {

    private func run(model: String, executorKind: String?) -> AgentRunRowData {
        let kindJSON = executorKind.map { ",\"executor_kind\":\"\($0)\"" } ?? ""
        let row = SharedItemRow(
            id: "33333333-3333-4333-8333-333333333333",
            schemaRef: "agent-run@1.0.0",
            payloadJson: "{\"agent_id\":\"impel/keyword-tag\",\"model\":\"\(model)\"\(kindJSON)}",
            createdMs: 1_757_000_000_000,
            modifiedMs: 1_757_000_000_000,
            parentId: nil,
            isRead: false,
            isStarred: false,
            tags: [],
            flagColor: nil
        )
        return AgentRunRowData(from: row)!
    }

    func testDeterministicRunSaysNoModelWasUsed() {
        let r = run(model: "heuristic-v1", executorKind: "deterministic")
        XCTAssertEqual(r.modelRowLabel, "Method", "a keyword table is not a model")
        XCTAssertTrue(
            r.modelDisplay.contains("no model"),
            "the absence of a model must be stated: \(r.modelDisplay)"
        )
    }

    /// When something DID infer, the row names it plainly — that is the case
    /// the question was really about.
    func testAModelRunNamesTheModelAndNothingElse() {
        let r = run(model: "anthropic/claude-opus-4-8", executorKind: "model")
        XCTAssertEqual(r.modelRowLabel, "Model")
        XCTAssertEqual(
            r.modelDisplay, "anthropic/claude-opus-4-8",
            "no qualifier to read past — the model id is the answer"
        )
    }

    /// Rows written before `executor_kind` existed genuinely do not say which
    /// it was, so the pane must not claim either way.
    func testRunsPredatingExecutorKindAreNotGuessed() {
        let r = run(model: "heuristic-v1", executorKind: nil)
        XCTAssertEqual(r.modelDisplay, "heuristic-v1")
        XCTAssertFalse(r.modelDisplay.contains("no model"))
    }
}
