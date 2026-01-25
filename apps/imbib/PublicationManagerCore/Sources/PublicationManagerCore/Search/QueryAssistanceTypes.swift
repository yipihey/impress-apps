//
//  QueryAssistanceTypes.swift
//  PublicationManagerCore
//
//  Core types for the Query Assistance feature that provides real-time
//  validation and preview for search queries.
//

import Foundation

// MARK: - Issue Severity

/// Severity level for query validation issues.
public enum QueryIssueSeverity: String, Sendable, Comparable {
    /// Query will fail or return incorrect results
    case error
    /// Query may not work as expected
    case warning
    /// Minor suggestion for improvement
    case hint

    public static func < (lhs: QueryIssueSeverity, rhs: QueryIssueSeverity) -> Bool {
        let order: [QueryIssueSeverity] = [.hint, .warning, .error]
        guard let lhsIndex = order.firstIndex(of: lhs),
              let rhsIndex = order.firstIndex(of: rhs) else {
            return false
        }
        return lhsIndex < rhsIndex
    }
}

// MARK: - Query Suggestion

/// A suggested fix for a validation issue.
public struct QuerySuggestion: Sendable, Identifiable {
    public let id: UUID
    /// The corrected query text
    public let correctedQuery: String
    /// Human-readable description of what the fix does
    public let description: String

    public init(
        id: UUID = UUID(),
        correctedQuery: String,
        description: String
    ) {
        self.id = id
        self.correctedQuery = correctedQuery
        self.description = description
    }
}

// MARK: - Query Validation Issue

/// A validation issue found in a query.
public struct QueryValidationIssue: Sendable, Identifiable {
    public let id: UUID
    /// Unique rule identifier (e.g., "ads.author.quote")
    public let ruleID: String
    /// Severity of the issue
    public let severity: QueryIssueSeverity
    /// Human-readable message describing the issue
    public let message: String
    /// Range in the query string where the issue occurs (optional)
    public let range: Range<String.Index>?
    /// Suggested fixes for this issue
    public let suggestions: [QuerySuggestion]

    public init(
        id: UUID = UUID(),
        ruleID: String,
        severity: QueryIssueSeverity,
        message: String,
        range: Range<String.Index>? = nil,
        suggestions: [QuerySuggestion] = []
    ) {
        self.id = id
        self.ruleID = ruleID
        self.severity = severity
        self.message = message
        self.range = range
        self.suggestions = suggestions
    }

    /// Icon name for this severity level
    public var iconName: String {
        switch severity {
        case .error: return "xmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .hint: return "lightbulb.fill"
        }
    }
}

// MARK: - Query Validation Result

/// Result of validating a query.
public struct QueryValidationResult: Sendable {
    /// All issues found in the query
    public let issues: [QueryValidationIssue]
    /// The original query that was validated
    public let query: String

    public init(issues: [QueryValidationIssue], query: String) {
        self.issues = issues
        self.query = query
    }

    /// Whether the query has any errors (blocking issues)
    public var hasErrors: Bool {
        issues.contains { $0.severity == .error }
    }

    /// Whether the query has any warnings
    public var hasWarnings: Bool {
        issues.contains { $0.severity == .warning }
    }

    /// Whether the query has any hints
    public var hasHints: Bool {
        issues.contains { $0.severity == .hint }
    }

    /// Whether the query is valid (no blocking issues)
    public var isValid: Bool {
        !hasErrors
    }

    /// Errors only
    public var errors: [QueryValidationIssue] {
        issues.filter { $0.severity == .error }
    }

    /// Warnings only
    public var warnings: [QueryValidationIssue] {
        issues.filter { $0.severity == .warning }
    }

    /// Hints only
    public var hints: [QueryValidationIssue] {
        issues.filter { $0.severity == .hint }
    }

    /// Empty result (no issues)
    public static let empty = QueryValidationResult(issues: [], query: "")
}

// MARK: - Query Preview Result

/// Result of a preview query (count only).
public struct QueryPreviewResult: Sendable {
    /// Total number of results for this query
    public let totalResults: Int
    /// Time taken to fetch the preview (for diagnostics)
    public let fetchDuration: TimeInterval
    /// Whether the result was from cache
    public let fromCache: Bool
    /// Optional human-readable message
    public let message: String?

    public init(
        totalResults: Int,
        fetchDuration: TimeInterval = 0,
        fromCache: Bool = false,
        message: String? = nil
    ) {
        self.totalResults = totalResults
        self.fetchDuration = fetchDuration
        self.fromCache = fromCache
        self.message = message
    }

    /// Semantic category based on result count
    public var category: PreviewCategory {
        switch totalResults {
        case 0: return .noResults
        case 1...10_000: return .good
        default: return .tooMany
        }
    }
}

/// Category for preview result counts
public enum PreviewCategory: Sendable {
    /// No results found
    case noResults
    /// Reasonable result set (1-10,000)
    case good
    /// Too many results, consider refining
    case tooMany
}

// MARK: - Query Assistance State

/// Overall state of query assistance for a query.
public enum QueryAssistanceState: Sendable {
    /// No query entered yet
    case empty
    /// Validation in progress
    case validating
    /// Validation complete, waiting for preview
    case validated(QueryValidationResult)
    /// Preview fetch in progress
    case fetchingPreview(QueryValidationResult)
    /// Complete result with validation and preview
    case complete(QueryValidationResult, QueryPreviewResult)
    /// Error occurred during preview fetch
    case previewError(QueryValidationResult, Error)

    /// The validation result, if available
    public var validationResult: QueryValidationResult? {
        switch self {
        case .empty, .validating:
            return nil
        case .validated(let result),
             .fetchingPreview(let result),
             .complete(let result, _),
             .previewError(let result, _):
            return result
        }
    }

    /// The preview result, if available
    public var previewResult: QueryPreviewResult? {
        switch self {
        case .complete(_, let preview):
            return preview
        default:
            return nil
        }
    }

    /// Whether a preview fetch is in progress
    public var isFetchingPreview: Bool {
        if case .fetchingPreview = self {
            return true
        }
        return false
    }
}

// MARK: - Source Type

/// Supported search sources for query assistance.
public enum QueryAssistanceSource: String, Sendable, CaseIterable {
    case ads = "ads"
    case arxiv = "arxiv"
    case wos = "wos"
    case openalex = "openalex"

    public var displayName: String {
        switch self {
        case .ads: return "ADS"
        case .arxiv: return "arXiv"
        case .wos: return "Web of Science"
        case .openalex: return "OpenAlex"
        }
    }

    /// Recommended debounce delay for preview requests
    public var previewDebounceDelay: TimeInterval {
        switch self {
        case .ads: return 0.8  // 800ms
        case .arxiv: return 1.5  // 1500ms (arXiv has stricter limits)
        case .wos: return 1.0  // 1000ms
        case .openalex: return 0.8  // 800ms (generous rate limits with polite pool)
        }
    }
}
