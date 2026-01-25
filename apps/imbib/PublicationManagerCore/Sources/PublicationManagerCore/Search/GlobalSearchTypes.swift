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

    public init(
        id: UUID,
        citeKey: String,
        title: String,
        authors: String,
        year: String?,
        snippet: String?,
        matchType: GlobalSearchMatchType,
        score: Float,
        libraryNames: [String] = []
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
