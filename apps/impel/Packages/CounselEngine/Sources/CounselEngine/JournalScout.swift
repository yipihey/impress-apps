//
//  JournalScout.swift
//  CounselEngine
//
//  Phase 1.3 of the journal pipeline (per docs/plan-journal-pipeline.md
//  §3.6 + ADR-0011 D7).
//
//  Scout is the persona that triages incoming `manuscript-submission`
//  items: it validates them, computes deduplication against existing
//  manuscripts, and proposes one of three outcomes:
//
//    - `.newManuscript`              — no near-duplicate found
//    - `.newRevisionOf(manuscriptID)` — submission resembles an existing
//                                       manuscript at high title similarity
//    - `.fragmentOf(manuscriptID)`    — submitter explicitly flagged this
//                                       as a fragment of an existing manuscript
//
//  Phase 1 implementation: title-only Jaccard similarity in pure Swift.
//  Phase 2+ will layer in cosine similarity over content embeddings via
//  imbib's EmbeddingService.
//

import Foundation
import ImpressKit
import OSLog

#if canImport(ImpressRustCore)
import ImpressRustCore
#endif

// MARK: - Outcome

/// Scout's recommendation for how to dispose of a submission.
public enum ScoutOutcome: Equatable, Sendable {
    /// Create a new manuscript from this submission.
    case newManuscript

    /// Treat this submission as a new revision of the named manuscript.
    /// Carries the title-similarity score that triggered the match.
    case newRevisionOf(manuscriptID: String, titleScore: Double)

    /// Treat this submission as a fragment to be attached to the named
    /// manuscript (e.g., a partial section). The submitter must have
    /// indicated `submission_kind = "fragment"` for this outcome to apply.
    case fragmentOf(manuscriptID: String)
}

/// One candidate match Scout considered, with its similarity score.
/// Useful for surfacing alternatives in the Submissions inbox UI.
public struct ScoutCandidate: Sendable, Equatable {
    public let manuscriptID: String
    public let manuscriptTitle: String
    public let titleScore: Double
}

/// Full Scout report: outcome + ranked candidates considered.
public struct ScoutReport: Sendable {
    public let submissionID: String
    public let outcome: ScoutOutcome
    public let candidates: [ScoutCandidate]
}

// MARK: - Errors

public enum JournalScoutError: Error, LocalizedError {
    case submissionNotFound(String)
    case storeUnavailable
    case invalidSubmission(String)

    public var errorDescription: String? {
        switch self {
        case .submissionNotFound(let id):
            return "Manuscript submission not found: \(id)"
        case .storeUnavailable:
            return "Shared impress-core store is not available"
        case .invalidSubmission(let msg):
            return "Submission cannot be triaged: \(msg)"
        }
    }
}

// MARK: - Service

/// Triages incoming `manuscript-submission` items.
///
/// Phase 1 invocation is on-demand: callers (the Submissions inbox UI,
/// a CLI command, or a future scheduled job) call
/// `JournalScout.shared.triage(submissionID:)`. Auto-triage on submission
/// receipt is Phase 2 work.
public actor JournalScout {

    public static let shared = JournalScout()

    /// Title Jaccard threshold above which a submission is considered a
    /// near-duplicate of an existing manuscript. Configurable per ADR-0011 D6.
    /// Default 0.7 — high enough to avoid false positives on unrelated
    /// papers sharing common words ("a study of"), low enough to catch
    /// minor wording changes between revisions.
    public static let defaultTitleJaccardThreshold: Double = 0.7

    private let logger = Logger(subsystem: "com.impress.impel", category: "journal-scout")

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
        } catch {
            self.isAvailable = false
            logger.error("JournalScout: store unavailable — \(error.localizedDescription)")
        }
    }

    /// Internal initializer for tests.
    internal init(testStorePath: String) throws {
        #if canImport(ImpressRustCore)
        self.store = try SharedStore.open(path: testStorePath)
        #endif
        self.isAvailable = true
    }

    // MARK: - Triage

    /// Triage a single pending submission and return Scout's recommendation.
    ///
    /// Reads the submission from the store, lists candidate manuscripts,
    /// scores them via title Jaccard, and returns a `ScoutReport`.
    /// Does NOT mutate the store — Scout is read-only in Phase 1. The
    /// caller (UI / CLI) decides whether to act on the recommendation.
    public func triage(submissionID: String) async throws -> ScoutReport {
        guard isAvailable else { throw JournalScoutError.storeUnavailable }
        #if canImport(ImpressRustCore)
        guard let store = store else { throw JournalScoutError.storeUnavailable }

        // Load the submission.
        guard let row = try store.getItem(id: submissionID) else {
            throw JournalScoutError.submissionNotFound(submissionID)
        }
        let payload = try JournalScout.parsePayload(row.payloadJson)
        guard let submissionTitle = payload["title"] as? String,
              let kind = payload["submission_kind"] as? String
        else {
            throw JournalScoutError.invalidSubmission(
                "submission \(submissionID) missing title or submission_kind"
            )
        }

        // Fragment outcome is decided by the submitter, not Scout — Scout
        // simply confirms the parent reference exists.
        if kind == "fragment", let parent = payload["parent_manuscript_ref"] as? String {
            let title = (try? JournalScout.getManuscriptTitle(store: store, id: parent)) ?? "<unknown>"
            return ScoutReport(
                submissionID: submissionID,
                outcome: .fragmentOf(manuscriptID: parent),
                candidates: [ScoutCandidate(
                    manuscriptID: parent,
                    manuscriptTitle: title,
                    titleScore: 1.0
                )]
            )
        }

        // Score against all existing manuscripts.
        let manuscripts = try store.queryBySchema(
            schemaRef: "manuscript",
            limit: 5000,
            offset: 0
        )

        var candidates: [ScoutCandidate] = []
        for m in manuscripts {
            let mTitle = (try? JournalScout.parsePayload(m.payloadJson)["title"] as? String)
                ?? ""
            let score = JournalScout.titleJaccard(submissionTitle, mTitle)
            if score > 0.0 {
                candidates.append(ScoutCandidate(
                    manuscriptID: m.id,
                    manuscriptTitle: mTitle,
                    titleScore: score
                ))
            }
        }
        candidates.sort { $0.titleScore > $1.titleScore }

        // Decide outcome.
        let outcome: ScoutOutcome
        if let best = candidates.first,
           best.titleScore >= Self.defaultTitleJaccardThreshold {
            outcome = .newRevisionOf(
                manuscriptID: best.manuscriptID,
                titleScore: best.titleScore
            )
        } else {
            outcome = .newManuscript
        }

        let topN = Array(candidates.prefix(5))
        let outcomeLabel = String(describing: outcome)
        let topScore = topN.first?.titleScore ?? 0.0
        logger.info(
            "JournalScout: \(submissionID) → \(outcomeLabel) (\(candidates.count) candidates, top score=\(topScore))"
        )
        return ScoutReport(submissionID: submissionID, outcome: outcome, candidates: topN)
        #else
        throw JournalScoutError.storeUnavailable
        #endif
    }

    // MARK: - Title Jaccard

    /// Compute Jaccard similarity over the bag-of-words of two titles.
    ///
    /// Words are normalized: lowercased, punctuation stripped, stopwords
    /// removed, very short tokens (< 3 chars) dropped. Returns 0.0 if
    /// either title yields no usable tokens.
    nonisolated public static func titleJaccard(_ a: String, _ b: String) -> Double {
        let setA = tokenize(a)
        let setB = tokenize(b)
        if setA.isEmpty || setB.isEmpty { return 0.0 }
        let intersection = setA.intersection(setB).count
        let union = setA.union(setB).count
        return union == 0 ? 0.0 : Double(intersection) / Double(union)
    }

    /// Tokenize a title into a normalized bag of words.
    nonisolated public static func tokenize(_ title: String) -> Set<String> {
        let lower = title.lowercased()
        let cleaned = lower.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == " " {
                return Character(scalar)
            }
            return " "
        }
        let normalized = String(cleaned)
        let tokens = normalized.split(separator: " ").map(String.init)
        return Set(tokens.filter { $0.count >= 3 && !stopwords.contains($0) })
    }

    /// Common English title stopwords. Small, hand-picked list — we want
    /// to filter "the", "and", "a/an", common prepositions, but not
    /// content-bearing terms.
    nonisolated private static let stopwords: Set<String> = [
        "the", "and", "for", "with", "from", "into", "onto", "over",
        "under", "this", "that", "these", "those", "are", "was", "were",
        "been", "have", "has", "had", "but", "not", "any", "all", "its",
        "their", "them", "they", "than", "via", "per",
    ]

    // MARK: - Helpers

    nonisolated private static func parsePayload(_ json: String) throws -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw JournalScoutError.invalidSubmission("payload is not a JSON object")
        }
        return obj
    }

    #if canImport(ImpressRustCore)
    nonisolated private static func getManuscriptTitle(
        store: SharedStore,
        id: String
    ) throws -> String? {
        guard let row = try store.getItem(id: id) else { return nil }
        let payload = try parsePayload(row.payloadJson)
        return payload["title"] as? String
    }
    #endif
}

