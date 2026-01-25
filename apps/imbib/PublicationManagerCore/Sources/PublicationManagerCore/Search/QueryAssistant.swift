//
//  QueryAssistant.swift
//  PublicationManagerCore
//
//  Protocol defining the interface for source-specific query assistants.
//

import Foundation

// MARK: - Query Assistant Protocol

/// Protocol for source-specific query validation and preview.
///
/// Each search source (ADS, arXiv, etc.) implements this protocol to provide:
/// - Synchronous validation (no network, instant feedback)
/// - Asynchronous preview (fetches result count from API)
///
/// Implementations must be actors for thread safety.
public protocol QueryAssistant: Sendable {
    /// The source this assistant handles
    nonisolated var source: QueryAssistanceSource { get }

    /// Validate a query synchronously (no network calls).
    ///
    /// This should be called immediately as the user types to provide
    /// instant feedback on syntax errors and warnings.
    ///
    /// - Parameter query: The query string to validate
    /// - Returns: Validation result with any issues found
    nonisolated func validate(_ query: String) -> QueryValidationResult

    /// Fetch a preview of the result count for a query.
    ///
    /// This performs a minimal API request to get the total result count
    /// without fetching actual results. Should respect rate limits.
    ///
    /// - Parameter query: The query string to preview
    /// - Returns: Preview result with total count
    /// - Throws: Network or API errors
    func fetchPreview(_ query: String) async throws -> QueryPreviewResult

    /// Known field prefixes for this source
    nonisolated var knownFields: Set<String> { get }
}

// MARK: - Default Implementation

public extension QueryAssistant {
    /// Check if a field prefix is known for this source
    func isKnownField(_ field: String) -> Bool {
        knownFields.contains(field.lowercased())
    }
}

// MARK: - Query Assistant Errors

/// Errors that can occur during query assistance
public enum QueryAssistantError: Error, LocalizedError, Sendable {
    /// Rate limit exceeded
    case rateLimitExceeded
    /// API key required but not configured
    case apiKeyRequired
    /// Network error
    case networkError(underlying: Error)
    /// Invalid API response
    case invalidResponse
    /// Query is empty
    case emptyQuery

    public var errorDescription: String? {
        switch self {
        case .rateLimitExceeded:
            return "Rate limit exceeded. Please wait before trying again."
        case .apiKeyRequired:
            return "API key required for this feature."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .invalidResponse:
            return "Invalid response from server."
        case .emptyQuery:
            return "Query is empty."
        }
    }
}
