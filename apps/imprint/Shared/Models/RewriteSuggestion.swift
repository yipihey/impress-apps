//
//  RewriteSuggestion.swift
//  imprint
//
//  Model for AI-generated text suggestions with diff display support.
//

import Foundation

// MARK: - Rewrite Suggestion

/// Represents an AI-generated suggestion for rewriting selected text.
public struct RewriteSuggestion: Identifiable {
    /// Unique identifier for this suggestion.
    public let id: UUID

    /// The original text that was selected.
    public let originalText: String

    /// The AI-suggested replacement text.
    public var suggestedText: String

    /// The action that generated this suggestion.
    public let action: AIAction

    /// The range in the source document where the original text is located.
    public let range: NSRange

    /// Timestamp when the suggestion was created.
    public let timestamp: Date

    /// Whether the suggestion is still being streamed.
    public var isStreaming: Bool

    public init(
        id: UUID = UUID(),
        originalText: String,
        suggestedText: String,
        action: AIAction,
        range: NSRange,
        timestamp: Date = Date(),
        isStreaming: Bool = false
    ) {
        self.id = id
        self.originalText = originalText
        self.suggestedText = suggestedText
        self.action = action
        self.range = range
        self.timestamp = timestamp
        self.isStreaming = isStreaming
    }

    /// Whether the suggestion differs from the original.
    public var hasChanges: Bool {
        originalText != suggestedText
    }
}

// MARK: - Suggestion State

/// State for managing the current suggestion in the UI.
public enum SuggestionState: Equatable {
    /// No suggestion is active.
    case idle

    /// A suggestion is being generated.
    case loading(AIAction)

    /// A suggestion is ready to be reviewed.
    case ready(RewriteSuggestion)

    /// An error occurred while generating the suggestion.
    case error(String)

    public static func == (lhs: SuggestionState, rhs: SuggestionState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle):
            return true
        case (.loading(let a), .loading(let b)):
            return a.id == b.id
        case (.ready(let a), .ready(let b)):
            return a.id == b.id
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}

// MARK: - Diff Segment

/// A segment of text for diff display, indicating whether it was added, removed, or unchanged.
public struct DiffSegment: Identifiable {
    public let id = UUID()

    /// The text content of this segment.
    public let text: String

    /// The type of change this segment represents.
    public let type: DiffType

    public init(text: String, type: DiffType) {
        self.text = text
        self.type = type
    }
}

/// Type of change in a diff segment.
public enum DiffType {
    /// Text that was removed (shown in red/strikethrough).
    case removed

    /// Text that was added (shown in green/highlighted).
    case added

    /// Text that is unchanged.
    case unchanged
}

// MARK: - Simple Diff Calculator

/// Utility for computing simple word-level diffs between two strings.
public enum DiffCalculator {

    /// Compute diff segments between original and suggested text.
    /// Uses a simple word-based diff algorithm for readable results.
    public static func computeDiff(original: String, suggested: String) -> [DiffSegment] {
        let originalWords = original.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let suggestedWords = suggested.split(separator: " ", omittingEmptySubsequences: false).map(String.init)

        // Use LCS (Longest Common Subsequence) for diff
        let lcs = longestCommonSubsequence(originalWords, suggestedWords)
        var segments: [DiffSegment] = []

        var origIndex = 0
        var suggIndex = 0
        var lcsIndex = 0

        while origIndex < originalWords.count || suggIndex < suggestedWords.count {
            if lcsIndex < lcs.count {
                // Handle removed words (in original but not in LCS at this position)
                while origIndex < originalWords.count && originalWords[origIndex] != lcs[lcsIndex] {
                    appendSegment(&segments, text: originalWords[origIndex], type: .removed)
                    origIndex += 1
                }

                // Handle added words (in suggested but not in LCS at this position)
                while suggIndex < suggestedWords.count && suggestedWords[suggIndex] != lcs[lcsIndex] {
                    appendSegment(&segments, text: suggestedWords[suggIndex], type: .added)
                    suggIndex += 1
                }

                // Handle common word
                if origIndex < originalWords.count && suggIndex < suggestedWords.count {
                    appendSegment(&segments, text: originalWords[origIndex], type: .unchanged)
                    origIndex += 1
                    suggIndex += 1
                    lcsIndex += 1
                }
            } else {
                // Handle remaining removed words
                while origIndex < originalWords.count {
                    appendSegment(&segments, text: originalWords[origIndex], type: .removed)
                    origIndex += 1
                }

                // Handle remaining added words
                while suggIndex < suggestedWords.count {
                    appendSegment(&segments, text: suggestedWords[suggIndex], type: .added)
                    suggIndex += 1
                }
            }
        }

        return consolidateSegments(segments)
    }

    private static func appendSegment(_ segments: inout [DiffSegment], text: String, type: DiffType) {
        // Add space before word if not the first segment
        let textWithSpace = segments.isEmpty ? text : " " + text
        segments.append(DiffSegment(text: textWithSpace, type: type))
    }

    private static func consolidateSegments(_ segments: [DiffSegment]) -> [DiffSegment] {
        // Merge consecutive segments of the same type
        var result: [DiffSegment] = []

        for segment in segments {
            if let last = result.last, last.type == segment.type {
                result[result.count - 1] = DiffSegment(text: last.text + segment.text, type: segment.type)
            } else {
                result.append(segment)
            }
        }

        return result
    }

    /// Compute the longest common subsequence of two arrays.
    private static func longestCommonSubsequence(_ a: [String], _ b: [String]) -> [String] {
        let m = a.count
        let n = b.count

        // Build LCS table
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)

        for i in 1...m {
            for j in 1...n {
                if a[i - 1] == b[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }

        // Backtrack to find LCS
        var lcs: [String] = []
        var i = m
        var j = n

        while i > 0 && j > 0 {
            if a[i - 1] == b[j - 1] {
                lcs.insert(a[i - 1], at: 0)
                i -= 1
                j -= 1
            } else if dp[i - 1][j] > dp[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }

        return lcs
    }
}
