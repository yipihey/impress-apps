//
//  RustDeduplicationOrchestrator.swift
//  PublicationManagerCore
//
//  Deduplication orchestration backed by the Rust imbib-core library.
//  Groups search results by shared identifiers and fuzzy matching.
//

import Foundation
import ImbibRustCore

// MARK: - Rust Deduplication Orchestrator

/// Deduplication orchestrator using the Rust imbib-core library.
public enum RustDeduplicationOrchestrator {

    /// Deduplicate search results from multiple sources
    /// - Parameters:
    ///   - results: Array of search results to deduplicate
    ///   - config: Optional deduplication configuration
    /// - Returns: Array of deduplicated groups
    public static func deduplicate(
        _ results: [SearchResult],
        config: DeduplicationOrchestratorConfig = .default
    ) -> [DeduplicatedSearchGroup] {
        let inputs = results.map(input(from:))

        // Convert config
        let rustConfig = ImbibRustCore.DeduplicationConfig(
            titleThreshold: config.titleThreshold,
            useFuzzyMatching: config.useFuzzyMatching,
            sourcePriority: config.sourcePriority
        )

        // Call Rust
        let groups = deduplicateSearchResults(results: inputs, config: rustConfig)

        // Convert back to Swift types
        return groups.map { group in
            let primaryIndex = Int(group.primaryIndex)
            let alternateIndices = group.alternateIndices.map { Int($0) }

            // Convert identifiers
            var identifiers: [IdentifierType: String] = [:]
            for (key, value) in group.identifiers {
                if let idType = IdentifierType(rawValue: key) {
                    identifiers[idType] = value
                }
            }

            return DeduplicatedSearchGroup(
                primary: results[primaryIndex],
                alternates: alternateIndices.map { results[$0] },
                identifiers: identifiers,
                confidence: group.confidence
            )
        }
    }

    /// Check if two search results share any identifier.
    public static func sharesIdentifier(_ a: SearchResult, _ b: SearchResult) -> Bool {
        ImbibRustCore.sharesIdentifier(a: input(from: a), b: input(from: b))
    }

    /// Fuzzy-match two search results by title + first author + year, returning
    /// the title similarity when they match.
    ///
    /// Not used by `deduplicate` unless the config opts in — see
    /// `DeduplicationOrchestratorConfig.useFuzzyMatching`.
    public static func fuzzyMatch(
        _ a: SearchResult,
        _ b: SearchResult,
        titleThreshold: Double = 0.85
    ) -> Double? {
        fuzzyMatchResults(a: input(from: a), b: input(from: b), titleThreshold: titleThreshold)
    }

    /// Project a `SearchResult` onto the fields dedup actually reads.
    ///
    /// `semanticScholarID` / `openAlexID` are carried but never matched on: no
    /// two sources report the same one, so they cannot group anything — they are
    /// here so the group's identifier map is complete for a later enrichment
    /// pass, which is what the Swift service collected via `allIdentifiers`.
    private static func input(from result: SearchResult) -> DeduplicationInput {
        DeduplicationInput(
            id: result.id,
            sourceId: result.sourceID,
            title: result.title,
            firstAuthorLastName: result.firstAuthorLastName,
            year: result.year.map { Int32($0) },
            doi: result.doi,
            arxivId: result.arxivID,
            pmid: result.pmid,
            bibcode: result.bibcode,
            semanticScholarId: result.semanticScholarID,
            openAlexId: result.openAlexID
        )
    }
}

// MARK: - Configuration

/// Configuration for deduplication orchestration.
public struct DeduplicationOrchestratorConfig: Sendable {
    /// Minimum title similarity threshold (0.0 - 1.0), used only when
    /// `useFuzzyMatching` is on.
    public var titleThreshold: Double

    /// Whether to additionally merge groups that share NO identifier but match
    /// on title + first author + year.
    ///
    /// Off by default, and that is the shipped behaviour, not a conservative
    /// guess: the Swift `DeduplicationService.fuzzyMatch` was written and never
    /// called, so no released build has ever merged on fuzzy evidence. Turning
    /// it on means accepting that two papers with a 0.85-similar title, the same
    /// first author and years within one become one row — which is right for
    /// preprint/published pairs and wrong for a paper series.
    public var useFuzzyMatching: Bool

    /// Explicit source priority order, highest priority first. Empty (the
    /// default) uses the Rust `SOURCE_PRIORITY` table, so the app does not carry
    /// a second copy of the ranking.
    public var sourcePriority: [String]

    public static let `default` = DeduplicationOrchestratorConfig()

    public init(
        titleThreshold: Double = 0.85,
        useFuzzyMatching: Bool = false,
        sourcePriority: [String] = []
    ) {
        self.titleThreshold = titleThreshold
        self.useFuzzyMatching = useFuzzyMatching
        self.sourcePriority = sourcePriority
    }
}

// MARK: - Result Types

/// A group of deduplicated search results
public struct DeduplicatedSearchGroup {
    /// The primary result (from highest priority source)
    public let primary: SearchResult

    /// Alternate results from other sources (same paper)
    public let alternates: [SearchResult]

    /// Combined identifiers from all results
    public let identifiers: [IdentifierType: String]

    /// Confidence score for the grouping (1.0 = exact identifier match)
    public let confidence: Double

    public init(
        primary: SearchResult,
        alternates: [SearchResult],
        identifiers: [IdentifierType: String],
        confidence: Double
    ) {
        self.primary = primary
        self.alternates = alternates
        self.identifiers = identifiers
        self.confidence = confidence
    }
}

/// Information about Rust deduplication
public enum RustDeduplicationOrchestratorInfo {
    public static var isAvailable: Bool { true }
}
