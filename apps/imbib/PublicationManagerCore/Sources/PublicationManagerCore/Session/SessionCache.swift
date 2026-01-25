//
//  SessionCache.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import Foundation
import OSLog

// MARK: - Session Cache

/// Session-scoped cache for search API responses.
///
/// ADR-016: Simplified cache that only stores raw API responses to avoid
/// redundant network calls. Papers are now auto-imported to Core Data,
/// so there's no need for BibTeX, RIS, PDF, or metadata caches.
public actor SessionCache {

    // MARK: - Singleton

    public static let shared = SessionCache()

    // MARK: - Configuration

    /// Maximum number of cached search results
    public static let maxSearchResults = 50

    /// Maximum age for cached results (1 hour)
    public static let maxResultAge: TimeInterval = 3600

    // MARK: - Properties

    private var searchResults: [String: CachedSearchResults] = [:]

    private let logger = Logger(subsystem: "com.imbib.core", category: "SessionCache")

    // MARK: - Initialization

    private init() {}

    // MARK: - Search Results

    /// Cache search results for a query
    public func cacheSearchResults(_ results: [SearchResult], for query: String, sourceIDs: [String]) {
        let key = cacheKey(query: query, sourceIDs: sourceIDs)
        searchResults[key] = CachedSearchResults(
            results: results,
            timestamp: Date()
        )

        // Evict old entries if over limit
        evictOldSearchResults()

        logger.debug("Cached \(results.count) results for query: \(query)")
    }

    /// Get cached search results if still valid
    public func getCachedResults(for query: String, sourceIDs: [String]) -> [SearchResult]? {
        let key = cacheKey(query: query, sourceIDs: sourceIDs)
        guard let cached = searchResults[key] else { return nil }

        // Check if expired
        if Date().timeIntervalSince(cached.timestamp) > Self.maxResultAge {
            searchResults.removeValue(forKey: key)
            return nil
        }

        logger.debug("Cache hit for query: \(query)")
        return cached.results
    }

    /// Clear cached results for a query
    public func clearResults(for query: String, sourceIDs: [String]) {
        let key = cacheKey(query: query, sourceIDs: sourceIDs)
        searchResults.removeValue(forKey: key)
    }

    // MARK: - Cleanup

    /// Clear all cached data
    public func clearAll() {
        searchResults.removeAll()
        logger.info("Cleared session cache")
    }

    // MARK: - Private Helpers

    private func cacheKey(query: String, sourceIDs: [String]) -> String {
        let sortedSources = sourceIDs.sorted().joined(separator: ",")
        return "\(query.lowercased())|\(sortedSources)"
    }

    private func evictOldSearchResults() {
        // Remove expired entries
        let now = Date()
        searchResults = searchResults.filter { _, cached in
            now.timeIntervalSince(cached.timestamp) < Self.maxResultAge
        }

        // If still over limit, remove oldest
        while searchResults.count > Self.maxSearchResults {
            if let oldest = searchResults.min(by: { $0.value.timestamp < $1.value.timestamp }) {
                searchResults.removeValue(forKey: oldest.key)
            }
        }
    }
}

// MARK: - Cached Search Results

private struct CachedSearchResults {
    let results: [SearchResult]
    let timestamp: Date
}
