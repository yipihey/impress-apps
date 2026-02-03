//
//  OpenAlexAutocompleteService.swift
//  PublicationManagerCore
//
//  Actor service for OpenAlex autocomplete functionality.
//  Provides suggestions for authors, institutions, sources, and concepts.
//

import Foundation
import OSLog

// MARK: - OpenAlex Autocomplete Service

/// Actor service for OpenAlex autocomplete API.
///
/// Provides real-time suggestions as users type, with:
/// - 5-minute TTL caching to reduce API calls
/// - Rate limiting (10 requests/second)
/// - Support for multiple entity types
///
/// ## Usage
///
/// ```swift
/// let service = OpenAlexAutocompleteService()
/// let suggestions = try await service.autocomplete(query: "Einst", entityType: .authors)
/// ```
public actor OpenAlexAutocompleteService {

    // MARK: - Types

    /// Grouped suggestions by entity type for multi-type autocomplete.
    public struct GroupedSuggestions: Sendable {
        public let authors: [OpenAlexAutocompleteSuggestion]
        public let institutions: [OpenAlexAutocompleteSuggestion]
        public let sources: [OpenAlexAutocompleteSuggestion]
        public let topics: [OpenAlexAutocompleteSuggestion]

        public var isEmpty: Bool {
            authors.isEmpty && institutions.isEmpty && sources.isEmpty && topics.isEmpty
        }

        public var totalCount: Int {
            authors.count + institutions.count + sources.count + topics.count
        }
    }

    /// Cache entry with expiration.
    private struct CacheEntry {
        let suggestions: [OpenAlexAutocompleteSuggestion]
        let timestamp: Date
        let entityType: OpenAlexEntityType

        var isExpired: Bool {
            Date().timeIntervalSince(timestamp) > cacheTTL
        }
    }

    // MARK: - Properties

    private let baseURL = "https://api.openalex.org"
    private let session: URLSession
    private let credentialManager: any CredentialProviding
    private let rateLimiter: RateLimiter

    /// Cache for autocomplete results (keyed by "entityType:query")
    private var cache: [String: CacheEntry] = [:]

    /// Cache TTL in seconds (5 minutes)
    private static let cacheTTL: TimeInterval = 300

    /// Last cleanup time
    private var lastCleanup: Date = Date()

    // MARK: - Initialization

    public init(
        session: URLSession = .shared,
        credentialManager: any CredentialProviding = CredentialManager()
    ) {
        self.session = session
        self.credentialManager = credentialManager
        self.rateLimiter = RateLimiter(
            rateLimit: RateLimit(requestsPerInterval: 10, intervalSeconds: 1)
        )
    }

    // MARK: - Public API

    /// Autocomplete for a specific entity type.
    ///
    /// - Parameters:
    ///   - query: The partial text to complete
    ///   - entityType: The type of entity to search for
    /// - Returns: Array of suggestions
    public func autocomplete(
        query: String,
        entityType: OpenAlexEntityType
    ) async throws -> [OpenAlexAutocompleteSuggestion] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespaces)
        guard trimmedQuery.count >= 2 else {
            return []
        }

        // Check cache first
        let cacheKey = "\(entityType.rawValue):\(trimmedQuery.lowercased())"
        if let cached = cache[cacheKey], !cached.isExpired {
            Logger.sources.debug("OpenAlex autocomplete: cache hit for \(cacheKey)")
            return cached.suggestions
        }

        // Clean cache periodically
        await cleanCacheIfNeeded()

        // Rate limit
        await rateLimiter.waitIfNeeded()

        // Build URL
        var components = URLComponents(string: "\(baseURL)/autocomplete/\(entityType.rawValue)")!
        components.queryItems = [
            URLQueryItem(name: "q", value: trimmedQuery)
        ]

        // Add email for polite pool
        if let email = await credentialManager.email(for: "openalex") {
            components.queryItems?.append(URLQueryItem(name: "mailto", value: email))
        }

        guard let url = components.url else {
            throw SourceError.invalidRequest("Invalid autocomplete URL")
        }

        Logger.network.httpRequest("GET", url: url)

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SourceError.networkError(URLError(.badServerResponse))
        }

        Logger.network.httpResponse(httpResponse.statusCode, url: url, bytes: data.count)

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 429 {
                throw SourceError.rateLimited(retryAfter: nil)
            }
            throw SourceError.networkError(URLError(.badServerResponse))
        }

        let decoder = JSONDecoder()
        let autocompleteResponse = try decoder.decode(OpenAlexAutocompleteResponse.self, from: data)

        // Cache the results
        cache[cacheKey] = CacheEntry(
            suggestions: autocompleteResponse.results,
            timestamp: Date(),
            entityType: entityType
        )

        Logger.sources.debug("OpenAlex autocomplete: \(autocompleteResponse.results.count) results for \(entityType.rawValue):\(trimmedQuery)")

        return autocompleteResponse.results
    }

    /// Autocomplete across multiple entity types in parallel.
    ///
    /// - Parameters:
    ///   - query: The partial text to complete
    ///   - entityTypes: The types of entities to search for
    ///   - maxPerType: Maximum suggestions per entity type
    /// - Returns: Grouped suggestions by entity type
    public func autocompleteMultiple(
        query: String,
        entityTypes: [OpenAlexEntityType] = [.authors, .institutions, .sources, .topics],
        maxPerType: Int = 5
    ) async throws -> GroupedSuggestions {
        let trimmedQuery = query.trimmingCharacters(in: .whitespaces)
        guard trimmedQuery.count >= 2 else {
            return GroupedSuggestions(authors: [], institutions: [], sources: [], topics: [])
        }

        // Fetch all types in parallel
        async let authorsTask = entityTypes.contains(.authors)
            ? autocomplete(query: trimmedQuery, entityType: .authors)
            : []
        async let institutionsTask = entityTypes.contains(.institutions)
            ? autocomplete(query: trimmedQuery, entityType: .institutions)
            : []
        async let sourcesTask = entityTypes.contains(.sources)
            ? autocomplete(query: trimmedQuery, entityType: .sources)
            : []
        async let topicsTask = entityTypes.contains(.topics)
            ? autocomplete(query: trimmedQuery, entityType: .topics)
            : []

        let (authors, institutions, sources, topics) = try await (
            authorsTask,
            institutionsTask,
            sourcesTask,
            topicsTask
        )

        return GroupedSuggestions(
            authors: Array(authors.prefix(maxPerType)),
            institutions: Array(institutions.prefix(maxPerType)),
            sources: Array(sources.prefix(maxPerType)),
            topics: Array(topics.prefix(maxPerType))
        )
    }

    /// Autocomplete authors by name.
    public func autocompleteAuthors(query: String) async throws -> [OpenAlexAutocompleteSuggestion] {
        try await autocomplete(query: query, entityType: .authors)
    }

    /// Autocomplete institutions by name.
    public func autocompleteInstitutions(query: String) async throws -> [OpenAlexAutocompleteSuggestion] {
        try await autocomplete(query: query, entityType: .institutions)
    }

    /// Autocomplete journals/sources by name.
    public func autocompleteSources(query: String) async throws -> [OpenAlexAutocompleteSuggestion] {
        try await autocomplete(query: query, entityType: .sources)
    }

    /// Autocomplete topics by name.
    public func autocompleteTopics(query: String) async throws -> [OpenAlexAutocompleteSuggestion] {
        try await autocomplete(query: query, entityType: .topics)
    }

    /// Autocomplete concepts by name (legacy, prefer topics).
    public func autocompleteConcepts(query: String) async throws -> [OpenAlexAutocompleteSuggestion] {
        try await autocomplete(query: query, entityType: .concepts)
    }

    // MARK: - Cache Management

    /// Clear the autocomplete cache.
    public func clearCache() {
        cache.removeAll()
        Logger.sources.debug("OpenAlex autocomplete: cache cleared")
    }

    /// Get current cache size.
    public var cacheSize: Int {
        cache.count
    }

    // MARK: - Private

    private func cleanCacheIfNeeded() async {
        // Clean every 5 minutes
        guard Date().timeIntervalSince(lastCleanup) > Self.cacheTTL else {
            return
        }

        let beforeCount = cache.count
        cache = cache.filter { !$0.value.isExpired }
        lastCleanup = Date()

        if beforeCount > self.cache.count {
            Logger.sources.debug("OpenAlex autocomplete: cleaned \(beforeCount - self.cache.count) expired cache entries")
        }
    }
}

// MARK: - Singleton

extension OpenAlexAutocompleteService {
    /// Shared instance for global use.
    public static let shared = OpenAlexAutocompleteService()
}
