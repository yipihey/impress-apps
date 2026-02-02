//
//  GlobalSearchTypes.swift
//  PublicationManagerCore
//
//  Types for global search combining fulltext and semantic search.
//

import Foundation

// MARK: - Match Type

/// The type of match that produced a search result.
public enum GlobalSearchMatchType: String, Sendable, Codable {
    /// Matched via Tantivy keyword/fulltext search
    case fulltext
    /// Matched via embedding similarity (semantic search)
    case semantic
    /// Matched by both fulltext and semantic search
    case both
}

// MARK: - Global Search Result

/// A combined search result from fulltext and semantic search.
public struct GlobalSearchResult: Identifiable, Sendable {
    public let id: UUID
    public let citeKey: String
    public let title: String
    public let authors: String
    public let year: String?
    /// Snippet showing where the query matched (from fulltext search)
    public let snippet: String?
    /// How this result was found
    public let matchType: GlobalSearchMatchType
    /// Combined relevance score (higher = more relevant)
    public let score: Float
    /// Library or collection name(s) this publication belongs to
    public let libraryNames: [String]
    /// Date the publication was added to the library
    public let dateAdded: Date?
    /// Date the publication was last modified
    public let dateModified: Date?
    /// Citation count (if available)
    public let citationCount: Int
    /// Whether the publication is starred
    public let isStarred: Bool

    public init(
        id: UUID,
        citeKey: String,
        title: String,
        authors: String,
        year: String?,
        snippet: String?,
        matchType: GlobalSearchMatchType,
        score: Float,
        libraryNames: [String] = [],
        dateAdded: Date? = nil,
        dateModified: Date? = nil,
        citationCount: Int = 0,
        isStarred: Bool = false
    ) {
        self.id = id
        self.citeKey = citeKey
        self.title = title
        self.authors = authors
        self.year = year
        self.snippet = snippet
        self.matchType = matchType
        self.score = score
        self.libraryNames = libraryNames
        self.dateAdded = dateAdded
        self.dateModified = dateModified
        self.citationCount = citationCount
        self.isStarred = isStarred
    }
}

// MARK: - Global Search Sort Order

/// Sort order options for global search results.
/// Includes all library sort options plus relevance (default for search).
public enum GlobalSearchSortOrder: String, CaseIterable, Identifiable, Sendable {
    case relevance      // Default for search - by combined score
    case dateAdded
    case dateModified
    case title
    case year
    case citeKey
    case citationCount
    case starred

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .relevance: return "Relevance"
        case .dateAdded: return "Date Added"
        case .dateModified: return "Date Modified"
        case .title: return "Title"
        case .year: return "Year"
        case .citeKey: return "Cite Key"
        case .citationCount: return "Citation Count"
        case .starred: return "Starred First"
        }
    }

    /// Default sort direction for this field.
    public var defaultAscending: Bool {
        switch self {
        case .relevance, .dateAdded, .dateModified, .year, .citationCount, .starred:
            return false  // Descending (highest relevance/newest/highest first)
        case .title, .citeKey:
            return true   // Ascending (A-Z)
        }
    }

    /// SF Symbol for the sort order
    public var iconName: String {
        switch self {
        case .relevance: return "sparkle.magnifyingglass"
        case .dateAdded: return "calendar.badge.plus"
        case .dateModified: return "calendar.badge.clock"
        case .title: return "textformat"
        case .year: return "calendar"
        case .citeKey: return "key"
        case .citationCount: return "quote.bubble"
        case .starred: return "star"
        }
    }
}

extension GlobalSearchMatchType {
    /// Display label for the match type
    public var label: String {
        switch self {
        case .fulltext:
            return "Text"
        case .semantic:
            return "Similar"
        case .both:
            return "Both"
        }
    }

    /// SF Symbol name for the match type
    public var iconName: String {
        switch self {
        case .fulltext:
            return "doc.text.magnifyingglass"
        case .semantic:
            return "brain.head.profile"
        case .both:
            return "star.fill"
        }
    }
}
