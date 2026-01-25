//
//  DeduplicationService.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import Foundation
import OSLog

// MARK: - Deduplication Service

/// Deduplicates search results from multiple sources.
/// Uses identifier matching and fuzzy title matching.
public actor DeduplicationService {

    // MARK: - Initialization

    public init() {}

    // MARK: - Source Priority

    /// Priority order for selecting primary result (lower = higher priority)
    private static let sourcePriority: [String: Int] = [
        "crossref": 10,      // Publisher source, most authoritative
        "pubmed": 20,        // Curated
        "ads": 30,           // Curated
        "semanticscholar": 40,
        "openalex": 50,
        "arxiv": 60,
        "dblp": 70,
    ]

    // MARK: - Public API

    /// Deduplicate search results from multiple sources
    public func deduplicate(_ results: [SearchResult]) -> [DeduplicatedResult] {
        Logger.deduplication.entering()
        defer { Logger.deduplication.exiting() }

        guard !results.isEmpty else { return [] }

        // Group results by shared identifiers
        var groups: [[SearchResult]] = []
        var processed = Set<String>()

        for result in results {
            if processed.contains(result.id) { continue }

            // Find all results that share an identifier with this one
            var group: [SearchResult] = [result]
            processed.insert(result.id)

            for other in results {
                if processed.contains(other.id) { continue }

                if sharesIdentifier(result, other) || fuzzyMatch(result, other) {
                    group.append(other)
                    processed.insert(other.id)
                }
            }

            groups.append(group)
        }

        // Convert groups to DeduplicatedResult
        let deduplicated = groups.map { group -> DeduplicatedResult in
            let sorted = group.sorted { priority(for: $0) < priority(for: $1) }
            let primary = sorted[0]
            let alternates = Array(sorted.dropFirst())

            // Collect all identifiers
            var identifiers: [IdentifierType: String] = [:]
            for result in group {
                for (type, value) in result.allIdentifiers {
                    identifiers[type] = value
                }
            }

            return DeduplicatedResult(
                primary: primary,
                alternates: alternates,
                identifiers: identifiers
            )
        }

        Logger.deduplication.info("Deduplicated \(results.count) results to \(deduplicated.count)")
        return deduplicated
    }

    // MARK: - Identifier Matching

    private func sharesIdentifier(_ a: SearchResult, _ b: SearchResult) -> Bool {
        // Check DOI
        if let doiA = a.doi, let doiB = b.doi, normalizeDOI(doiA) == normalizeDOI(doiB) {
            return true
        }

        // Check arXiv ID
        if let arxivA = a.arxivID, let arxivB = b.arxivID, normalizeArXiv(arxivA) == normalizeArXiv(arxivB) {
            return true
        }

        // Check PMID
        if let pmidA = a.pmid, let pmidB = b.pmid, pmidA == pmidB {
            return true
        }

        // Check bibcode
        if let bibcodeA = a.bibcode, let bibcodeB = b.bibcode, bibcodeA == bibcodeB {
            return true
        }

        return false
    }

    private func normalizeDOI(_ doi: String) -> String {
        doi.lowercased()
            .replacingOccurrences(of: "https://doi.org/", with: "")
            .replacingOccurrences(of: "http://doi.org/", with: "")
            .replacingOccurrences(of: "doi:", with: "")
    }

    private func normalizeArXiv(_ arxivID: String) -> String {
        // Remove version suffix
        arxivID.replacingOccurrences(of: #"v\d+$"#, with: "", options: .regularExpression)
    }

    // MARK: - Fuzzy Matching

    private func fuzzyMatch(_ a: SearchResult, _ b: SearchResult) -> Bool {
        // Match on normalized title + first author + year
        let titleA = normalizeTitle(a.title)
        let titleB = normalizeTitle(b.title)

        guard titleSimilarity(titleA, titleB) > 0.85 else { return false }

        // Check year if available
        if let yearA = a.year, let yearB = b.year {
            guard abs(yearA - yearB) <= 1 else { return false }
        }

        // Check first author if available
        if let authorA = a.authors.first, let authorB = b.authors.first {
            let lastNameA = extractLastName(authorA)
            let lastNameB = extractLastName(authorB)
            guard lastNameA.lowercased() == lastNameB.lowercased() else { return false }
        }

        return true
    }

    private func normalizeTitle(_ title: String) -> String {
        title.lowercased()
            .replacingOccurrences(of: #"[^\w\s]"#, with: "", options: .regularExpression)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func titleSimilarity(_ a: String, _ b: String) -> Double {
        // Simple Jaccard similarity on words
        let wordsA = Set(a.components(separatedBy: " "))
        let wordsB = Set(b.components(separatedBy: " "))

        let intersection = wordsA.intersection(wordsB).count
        let union = wordsA.union(wordsB).count

        guard union > 0 else { return 0 }
        return Double(intersection) / Double(union)
    }

    private func extractLastName(_ author: String) -> String {
        // Handle "Last, First" format
        if author.contains(",") {
            return author.components(separatedBy: ",")[0].trimmingCharacters(in: .whitespaces)
        }
        // Handle "First Last" format
        return author.components(separatedBy: " ").last ?? author
    }

    // MARK: - Priority

    private func priority(for result: SearchResult) -> Int {
        Self.sourcePriority[result.sourceID] ?? 100
    }
}
