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

// MARK: - Deduplication Scorer

/// Factory for creating deduplication scorers.
///
/// Stage 7 item 5: there is exactly one scorer now — the Rust one. The
/// `SwiftDeduplicationScorer` that used to sit beside it was a line-for-line
/// transcription of `imbib_core::deduplication::similarity`, selectable through
/// a `Backend` enum that production code never set and that defaulted to
/// `.rust`. Two implementations of one algorithm, one of them unreachable, both
/// needing to be kept in step: the factory is kept (call sites read better
/// through it, and it is the seam where scoring options would go) but the choice
/// is gone.
public enum DeduplicationScorerFactory {

    /// Create a scorer.
    public static func createScorer() -> any DeduplicationScoring {
        RustDeduplicationScorer()
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
