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
        // Convert to Rust input format
        let inputs = results.map { result in
            DeduplicationInput(
                id: result.id,
                sourceId: result.sourceID,
                title: result.title,
                firstAuthorLastName: result.firstAuthorLastName,
                year: result.year.map { Int32($0) },
                doi: result.doi,
                arxivId: result.arxivID,
                pmid: result.pmid,
                bibcode: result.bibcode
            )
        }

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

    /// Check if two search results share any identifier
    public static func sharesIdentifier(_ a: SearchResult, _ b: SearchResult) -> Bool {
        let inputA = DeduplicationInput(
            id: a.id,
            sourceId: a.sourceID,
            title: a.title,
            firstAuthorLastName: a.firstAuthorLastName,
            year: a.year.map { Int32($0) },
            doi: a.doi,
            arxivId: a.arxivID,
            pmid: a.pmid,
            bibcode: a.bibcode
        )

        let inputB = DeduplicationInput(
            id: b.id,
            sourceId: b.sourceID,
            title: b.title,
            firstAuthorLastName: b.firstAuthorLastName,
            year: b.year.map { Int32($0) },
            doi: b.doi,
            arxivId: b.arxivID,
            pmid: b.pmid,
            bibcode: b.bibcode
        )

        return ImbibRustCore.sharesIdentifier(a: inputA, b: inputB)
    }

    /// Check if two search results fuzzy match (by title/author/year)
    public static func fuzzyMatch(
        _ a: SearchResult,
        _ b: SearchResult,
        titleThreshold: Double = 0.85
    ) -> Double? {
        let inputA = DeduplicationInput(
            id: a.id,
            sourceId: a.sourceID,
            title: a.title,
            firstAuthorLastName: a.firstAuthorLastName,
            year: a.year.map { Int32($0) },
            doi: a.doi,
            arxivId: a.arxivID,
            pmid: a.pmid,
            bibcode: a.bibcode
        )

        let inputB = DeduplicationInput(
            id: b.id,
            sourceId: b.sourceID,
            title: b.title,
            firstAuthorLastName: b.firstAuthorLastName,
            year: b.year.map { Int32($0) },
            doi: b.doi,
            arxivId: b.arxivID,
            pmid: b.pmid,
            bibcode: b.bibcode
        )

        return fuzzyMatchResults(a: inputA, b: inputB, titleThreshold: titleThreshold)
    }
}

// MARK: - Configuration

/// Configuration for deduplication orchestration
public struct DeduplicationOrchestratorConfig {
    /// Minimum title similarity threshold (0.0 - 1.0)
    public var titleThreshold: Double

    /// Whether to use fuzzy matching when no identifier match
    public var useFuzzyMatching: Bool

    /// Source priority order (lower index = higher priority)
    public var sourcePriority: [String]

    public static let `default` = DeduplicationOrchestratorConfig(
        titleThreshold: 0.85,
        useFuzzyMatching: true,
        sourcePriority: ["crossref", "pubmed", "ads", "semanticscholar", "openalex", "arxiv", "dblp"]
    )

    public init(
        titleThreshold: Double = 0.85,
        useFuzzyMatching: Bool = true,
        sourcePriority: [String] = ["crossref", "pubmed", "ads", "semanticscholar", "openalex", "arxiv", "dblp"]
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
