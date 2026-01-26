//
//  RustDeduplication.swift
//  PublicationManagerCore
//
//  Deduplication algorithms backed by the Rust imbib-core library.
//  Provides fast similarity scoring and matching for publications.
//

import Foundation
import ImbibRustCore

// MARK: - Deduplication Protocol

/// Protocol for deduplication algorithms.
public protocol DeduplicationScoring: Sendable {
    /// Calculate similarity between two entries
    func calculateSimilarity(entry1: BibTeXEntry, entry2: BibTeXEntry) -> DeduplicationMatchResult

    /// Check if two titles are similar
    func titlesMatch(title1: String, title2: String, threshold: Double) -> Bool

    /// Check if author lists have overlap
    func authorsOverlap(authors1: String, authors2: String) -> Bool

    /// Normalize a title for comparison
    func normalizeTitle(_ title: String) -> String

    /// Normalize an author name for comparison
    func normalizeAuthor(_ author: String) -> String
}

/// Result of a deduplication comparison
public struct DeduplicationMatchResult: Sendable, Equatable {
    /// Overall similarity score (0.0 to 1.0)
    public let score: Double
    /// Human-readable explanation of why entries match
    public let reason: String

    public init(score: Double, reason: String) {
        self.score = score
        self.reason = reason
    }

    /// Whether this is considered a probable match
    public var isMatch: Bool { score >= 0.8 }

    /// Whether this is considered a possible match worth reviewing
    public var isPossibleMatch: Bool { score >= 0.5 }
}

// MARK: - Deduplication Factory

/// Factory for creating deduplication scorers.
public enum DeduplicationScorerFactory {

    /// Current backend selection.
    /// Defaults to Rust when available, Swift otherwise.
    public static var currentBackend: BibTeXParserFactory.Backend = .rust

    /// Create a scorer using the current backend
    public static func createScorer() -> any DeduplicationScoring {
        switch currentBackend {
        case .swift:
            return SwiftDeduplicationScorer()
        case .rust:
            return RustDeduplicationScorer()
        }
    }
}

// MARK: - Swift Deduplication Scorer

/// Swift implementation of deduplication scoring
public struct SwiftDeduplicationScorer: DeduplicationScoring, Sendable {

    public init() {}

    public func calculateSimilarity(entry1: BibTeXEntry, entry2: BibTeXEntry) -> DeduplicationMatchResult {
        var score: Double = 0.0
        var reasons: [String] = []

        // Check DOI match (strongest signal)
        if let doi1 = entry1.fields["doi"], let doi2 = entry2.fields["doi"],
           normalizeDOI(doi1) == normalizeDOI(doi2) {
            return DeduplicationMatchResult(score: 1.0, reason: "DOI match")
        }

        // Title similarity
        if let title1 = entry1.fields["title"], let title2 = entry2.fields["title"] {
            let titleScore = titleSimilarity(title1, title2)
            if titleScore > 0.9 {
                score += 0.5
                reasons.append(String(format: "Title match (%.0f%%)", titleScore * 100))
            } else if titleScore > 0.7 {
                score += 0.3
                reasons.append(String(format: "Similar title (%.0f%%)", titleScore * 100))
            }
        }

        // Author overlap
        if let authors1 = entry1.fields["author"], let authors2 = entry2.fields["author"],
           authorsOverlap(authors1: authors1, authors2: authors2) {
            score += 0.3
            reasons.append("Author overlap")
        }

        // Year match
        if let year1 = entry1.fields["year"], let year2 = entry2.fields["year"] {
            if year1 == year2 {
                score += 0.1
                reasons.append("Same year")
            } else if let y1 = Int(year1), let y2 = Int(year2), abs(y1 - y2) <= 1 {
                score += 0.05
                reasons.append("Years within 1")
            }
        }

        score = min(score, 1.0)
        let reason = reasons.isEmpty ? "No significant similarity" : reasons.joined(separator: "; ")

        return DeduplicationMatchResult(score: score, reason: reason)
    }

    public func titlesMatch(title1: String, title2: String, threshold: Double) -> Bool {
        titleSimilarity(title1, title2) >= threshold
    }

    public func authorsOverlap(authors1: String, authors2: String) -> Bool {
        let surnames1 = extractSurnames(authors1)
        let surnames2 = extractSurnames(authors2)

        for s1 in surnames1 {
            for s2 in surnames2 {
                if s1.lowercased() == s2.lowercased() {
                    return true
                }
            }
        }
        return false
    }

    public func normalizeTitle(_ title: String) -> String {
        title.lowercased()
            .replacingOccurrences(of: "[^\\w\\s]", with: "", options: .regularExpression)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    public func normalizeAuthor(_ author: String) -> String {
        // Extract last name
        let parts = author.components(separatedBy: ",")
        if parts.count > 1 {
            return parts[0].trimmingCharacters(in: .whitespaces).lowercased()
        }
        return author.components(separatedBy: " ").last?.lowercased() ?? author.lowercased()
    }

    // MARK: - Private Helpers

    private func titleSimilarity(_ title1: String, _ title2: String) -> Double {
        let norm1 = normalizeTitle(title1)
        let norm2 = normalizeTitle(title2)

        guard !norm1.isEmpty && !norm2.isEmpty else { return 0.0 }

        let words1 = Set(norm1.components(separatedBy: " "))
        let words2 = Set(norm2.components(separatedBy: " "))

        let intersection = words1.intersection(words2).count
        let union = words1.union(words2).count

        return union > 0 ? Double(intersection) / Double(union) : 0.0
    }

    private func extractSurnames(_ authors: String) -> [String] {
        let authorList = authors.components(separatedBy: " and ")
        return authorList.map { author in
            let parts = author.components(separatedBy: ",")
            if parts.count > 1 {
                return parts[0].trimmingCharacters(in: .whitespaces)
            }
            return author.components(separatedBy: " ").last ?? author
        }
    }

    private func normalizeDOI(_ doi: String) -> String {
        doi.lowercased()
            .replacingOccurrences(of: "https://doi.org/", with: "")
            .replacingOccurrences(of: "http://doi.org/", with: "")
            .replacingOccurrences(of: "doi:", with: "")
    }
}

// MARK: - Rust Deduplication Scorer

/// Deduplication scorer using the Rust imbib-core library.
public struct RustDeduplicationScorer: DeduplicationScoring, Sendable {

    public init() {}

    public func calculateSimilarity(entry1: BibTeXEntry, entry2: BibTeXEntry) -> DeduplicationMatchResult {
        let rustEntry1 = convertToRustEntry(entry1)
        let rustEntry2 = convertToRustEntry(entry2)

        let result = ImbibRustCore.calculateSimilarity(entry1: rustEntry1, entry2: rustEntry2)

        return DeduplicationMatchResult(
            score: result.score,
            reason: result.reason
        )
    }

    public func titlesMatch(title1: String, title2: String, threshold: Double) -> Bool {
        ImbibRustCore.titlesMatch(title1: title1, title2: title2, threshold: threshold)
    }

    public func authorsOverlap(authors1: String, authors2: String) -> Bool {
        ImbibRustCore.authorsOverlap(authors1: authors1, authors2: authors2)
    }

    public func normalizeTitle(_ title: String) -> String {
        ImbibRustCore.normalizeTitleExport(title: title)
    }

    public func normalizeAuthor(_ author: String) -> String {
        ImbibRustCore.normalizeAuthorExport(author: author)
    }

    // MARK: - Private Helpers

    private func convertToRustEntry(_ entry: BibTeXEntry) -> ImbibRustCore.BibTeXEntry {
        BibTeXEntryConversions.toRust(entry)
    }
}

/// Information about Rust deduplication
public enum RustDeduplicationInfo {
    public static var isAvailable: Bool { true }
}
