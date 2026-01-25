//
//  SourcePlugin.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import Foundation

// MARK: - Source Plugin Protocol

/// Protocol for publication source plugins.
/// All implementations must be actors for thread safety.
public protocol SourcePlugin: Sendable {

    /// Metadata describing this source
    var metadata: SourceMetadata { get }

    /// Search for publications matching the query
    /// - Parameters:
    ///   - query: Search query string
    ///   - maxResults: Maximum number of results to return (default: 50)
    /// - Returns: Array of search results
    func search(query: String, maxResults: Int) async throws -> [SearchResult]

    /// Fetch BibTeX entry for a specific search result
    /// - Parameter result: The search result to fetch BibTeX for
    /// - Returns: Parsed BibTeX entry
    func fetchBibTeX(for result: SearchResult) async throws -> BibTeXEntry

    /// Fetch RIS entry for a specific search result
    /// Not all sources support RIS; default implementation throws unsupportedFormat
    /// - Parameter result: The search result to fetch RIS for
    /// - Returns: Parsed RIS entry
    func fetchRIS(for result: SearchResult) async throws -> RISEntry

    /// Whether this source supports RIS export
    var supportsRIS: Bool { get }

    /// Normalize a BibTeX entry (add source-specific fields, fix formatting)
    /// Default implementation returns entry unchanged
    func normalize(_ entry: BibTeXEntry) -> BibTeXEntry
}

// MARK: - Default Implementation

public extension SourcePlugin {
    func normalize(_ entry: BibTeXEntry) -> BibTeXEntry {
        entry
    }

    var supportsRIS: Bool {
        false
    }

    func fetchRIS(for result: SearchResult) async throws -> RISEntry {
        throw SourceError.unsupportedFormat("RIS")
    }
}

// MARK: - Source Metadata

/// Metadata describing a source plugin
public struct SourceMetadata: Sendable, Identifiable, Equatable {

    /// Unique identifier for this source (e.g., "arxiv", "crossref")
    public let id: String

    /// Human-readable name (e.g., "arXiv", "Crossref")
    public let name: String

    /// Brief description of the source
    public let description: String

    /// Rate limiting configuration
    public let rateLimit: RateLimit

    /// What credentials this source requires
    public let credentialRequirement: CredentialRequirement

    /// URL where users can register for API access (if applicable)
    public let registrationURL: URL?

    /// Priority for deduplication (lower = higher priority)
    public let deduplicationPriority: Int

    /// SF Symbol name for the source icon
    public let iconName: String

    public init(
        id: String,
        name: String,
        description: String = "",
        rateLimit: RateLimit = .none,
        credentialRequirement: CredentialRequirement = .none,
        registrationURL: URL? = nil,
        deduplicationPriority: Int = 100,
        iconName: String = "doc.text.magnifyingglass"
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.rateLimit = rateLimit
        self.credentialRequirement = credentialRequirement
        self.registrationURL = registrationURL
        self.deduplicationPriority = deduplicationPriority
        self.iconName = iconName
    }
}

// MARK: - Rate Limit

/// Rate limiting configuration for a source
public struct RateLimit: Sendable, Equatable {

    /// Maximum requests per interval
    public let requestsPerInterval: Int

    /// Time interval in seconds
    public let intervalSeconds: TimeInterval

    public init(requestsPerInterval: Int, intervalSeconds: TimeInterval) {
        self.requestsPerInterval = requestsPerInterval
        self.intervalSeconds = intervalSeconds
    }

    /// No rate limiting
    public static let none = RateLimit(requestsPerInterval: Int.max, intervalSeconds: 1)

    /// Minimum delay between requests
    public var minDelay: TimeInterval {
        guard requestsPerInterval > 0 else { return 0 }
        return intervalSeconds / Double(requestsPerInterval)
    }
}

// MARK: - Credential Requirement

/// What credentials a source requires
public enum CredentialRequirement: Sendable, Equatable {
    /// No credentials required
    case none

    /// API key required
    case apiKey

    /// Email required (for polite pool access)
    case email

    /// Both API key and email required
    case apiKeyAndEmail

    /// API key optional but recommended
    case apiKeyOptional

    /// Email optional but recommended
    case emailOptional

    public var requiresCredentials: Bool {
        switch self {
        case .none, .apiKeyOptional, .emailOptional:
            return false
        case .apiKey, .email, .apiKeyAndEmail:
            return true
        }
    }

    public var displayDescription: String {
        switch self {
        case .none:
            return "No credentials required"
        case .apiKey:
            return "API key required"
        case .email:
            return "Email required"
        case .apiKeyAndEmail:
            return "API key and email required"
        case .apiKeyOptional:
            return "API key optional (recommended)"
        case .emailOptional:
            return "Email optional (recommended)"
        }
    }
}

// MARK: - Search Sort Order

/// Sort order for search results
public enum SearchSortOrder: String, Sendable, CaseIterable {
    case relevance
    case dateDescending
    case dateAscending
    case citationCount

    public var displayName: String {
        switch self {
        case .relevance: return "Relevance"
        case .dateDescending: return "Newest First"
        case .dateAscending: return "Oldest First"
        case .citationCount: return "Citation Count"
        }
    }
}

// MARK: - Search Options

/// Options for customizing search behavior
public struct SearchOptions: Sendable {

    /// Maximum number of results to return
    public let maxResults: Int

    /// Sort order for results
    public let sortOrder: SearchSortOrder

    /// Specific sources to search (nil = all available)
    public let sourceIDs: [String]?

    public init(
        maxResults: Int = 300,
        sortOrder: SearchSortOrder = .relevance,
        sourceIDs: [String]? = nil
    ) {
        self.maxResults = maxResults
        self.sortOrder = sortOrder
        self.sourceIDs = sourceIDs
    }

    public static let `default` = SearchOptions()
}
