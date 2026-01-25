//
//  QueryAssistanceService.swift
//  PublicationManagerCore
//
//  Actor that orchestrates query validation and preview fetching
//  with caching and rate limiting.
//

import Foundation
import OSLog

// MARK: - Query Assistance Service

/// Actor that manages query validation and preview fetching.
///
/// Responsibilities:
/// - Dispatches to source-specific QueryAssistant implementations
/// - Manages preview result cache (60 second TTL)
/// - Handles rate limiting through the assistants
public actor QueryAssistanceService {

    // MARK: - Shared Instance

    public static let shared = QueryAssistanceService()

    // MARK: - Properties

    private var assistants: [QueryAssistanceSource: any QueryAssistant] = [:]
    private var previewCache: [CacheKey: CachedPreview] = [:]
    private let cacheTTL: TimeInterval = 60  // 60 seconds

    // MARK: - Initialization

    public init() {}

    // MARK: - Assistant Registration

    /// Register a query assistant for a source
    public func register(_ assistant: any QueryAssistant) {
        assistants[assistant.source] = assistant
    }

    /// Get the assistant for a source
    public func assistant(for source: QueryAssistanceSource) -> (any QueryAssistant)? {
        assistants[source]
    }

    // MARK: - Validation

    /// Validate a query for a specific source.
    ///
    /// This is synchronous and does not make network calls.
    /// - Parameters:
    ///   - query: The query to validate
    ///   - source: The search source
    /// - Returns: Validation result with any issues found
    public func validate(_ query: String, for source: QueryAssistanceSource) -> QueryValidationResult {
        guard let assistant = assistants[source] else {
            Logger.queryAssistance.warning("No assistant registered for \(source.rawValue)")
            return QueryValidationResult(issues: [], query: query)
        }

        let result = assistant.validate(query)
        Logger.queryAssistance.debug("Validated query for \(source.rawValue): \(result.issues.count) issues")
        return result
    }

    // MARK: - Preview

    /// Fetch a preview (result count) for a query.
    ///
    /// Results are cached for 60 seconds to avoid redundant API calls.
    /// - Parameters:
    ///   - query: The query to preview
    ///   - source: The search source
    /// - Returns: Preview result with total count
    public func fetchPreview(_ query: String, for source: QueryAssistanceSource) async throws -> QueryPreviewResult {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw QueryAssistantError.emptyQuery
        }

        guard let assistant = assistants[source] else {
            Logger.queryAssistance.warning("No assistant registered for \(source.rawValue)")
            throw QueryAssistantError.invalidResponse
        }

        // Check cache
        let cacheKey = CacheKey(query: query, source: source)
        if let cached = previewCache[cacheKey], !cached.isExpired(ttl: cacheTTL) {
            Logger.queryAssistance.debug("Preview cache hit for \(source.rawValue)")
            return QueryPreviewResult(
                totalResults: cached.result.totalResults,
                fetchDuration: 0,
                fromCache: true,
                message: cached.result.message
            )
        }

        // Fetch from API
        let startTime = Date()
        let result = try await assistant.fetchPreview(query)
        let duration = Date().timeIntervalSince(startTime)

        Logger.queryAssistance.debug("Fetched preview for \(source.rawValue): \(result.totalResults) results in \(duration, format: .fixed(precision: 2))s")

        // Cache the result
        previewCache[cacheKey] = CachedPreview(result: result, timestamp: Date())

        // Clean up old cache entries periodically
        cleanExpiredCache()

        return QueryPreviewResult(
            totalResults: result.totalResults,
            fetchDuration: duration,
            fromCache: false,
            message: result.message
        )
    }

    // MARK: - Cache Management

    /// Clear all cached previews
    public func clearCache() {
        previewCache.removeAll()
        Logger.queryAssistance.debug("Preview cache cleared")
    }

    /// Clear cached previews for a specific source
    public func clearCache(for source: QueryAssistanceSource) {
        previewCache = previewCache.filter { $0.key.source != source }
        Logger.queryAssistance.debug("Preview cache cleared for \(source.rawValue)")
    }

    /// Remove expired cache entries
    private func cleanExpiredCache() {
        let expiredKeys = previewCache.filter { $0.value.isExpired(ttl: cacheTTL) }.map(\.key)
        for key in expiredKeys {
            previewCache.removeValue(forKey: key)
        }
        if !expiredKeys.isEmpty {
            Logger.queryAssistance.debug("Cleaned \(expiredKeys.count) expired cache entries")
        }
    }
}

// MARK: - Cache Types

private struct CacheKey: Hashable {
    let query: String
    let source: QueryAssistanceSource
}

private struct CachedPreview {
    let result: QueryPreviewResult
    let timestamp: Date

    func isExpired(ttl: TimeInterval) -> Bool {
        Date().timeIntervalSince(timestamp) > ttl
    }
}

// MARK: - Logger Extension

extension Logger {
    static let queryAssistance = Logger(subsystem: "com.imbib", category: "QueryAssistance")
}
