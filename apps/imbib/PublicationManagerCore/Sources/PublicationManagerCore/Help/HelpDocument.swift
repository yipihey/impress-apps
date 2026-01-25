//
//  HelpDocument.swift
//  PublicationManagerCore
//
//  Data models for help documentation.
//

import Foundation

/// A help document with metadata for display and search.
public struct HelpDocument: Identifiable, Sendable, Codable, Equatable, Hashable {
    /// Unique identifier (e.g., "getting-started").
    public let id: String

    /// Display title shown in sidebar and header.
    public let title: String

    /// Category for grouping in the sidebar.
    public let category: HelpCategory

    /// Source markdown filename (e.g., "getting-started.md").
    public let filename: String

    /// Keywords for search matching.
    public let keywords: [String]

    /// Brief description for search results.
    public let summary: String

    /// Order within the category.
    public let sortOrder: Int

    /// Whether this is developer documentation (ADRs, architecture).
    public let isDeveloperDoc: Bool

    public init(
        id: String,
        title: String,
        category: HelpCategory,
        filename: String,
        keywords: [String] = [],
        summary: String = "",
        sortOrder: Int = 0,
        isDeveloperDoc: Bool = false
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.filename = filename
        self.keywords = keywords
        self.summary = summary
        self.sortOrder = sortOrder
        self.isDeveloperDoc = isDeveloperDoc
    }
}

// MARK: - Search Result

/// Match type for help search results.
public enum HelpSearchMatchType: String, Sendable, Codable {
    case title
    case keyword
    case content
    case semantic

    /// Display label for the match type badge.
    public var label: String {
        switch self {
        case .title: return "Title"
        case .keyword: return "Keyword"
        case .content: return "Content"
        case .semantic: return "Related"
        }
    }

    /// SF Symbol name for the badge icon.
    public var iconName: String {
        switch self {
        case .title: return "textformat"
        case .keyword: return "tag"
        case .content: return "doc.text"
        case .semantic: return "brain"
        }
    }
}

/// A search result from the help index.
public struct HelpSearchResult: Identifiable, Sendable {
    public let id: String
    public let documentID: String
    public let documentTitle: String
    public let category: HelpCategory
    public let snippet: String?
    public let matchType: HelpSearchMatchType
    public let score: Float

    public init(
        documentID: String,
        documentTitle: String,
        category: HelpCategory,
        snippet: String? = nil,
        matchType: HelpSearchMatchType,
        score: Float
    ) {
        self.id = "\(documentID)-\(matchType.rawValue)"
        self.documentID = documentID
        self.documentTitle = documentTitle
        self.category = category
        self.snippet = snippet
        self.matchType = matchType
        self.score = score
    }
}

// MARK: - Help Index

/// Structure for the bundled help index JSON.
public struct HelpIndex: Codable, Sendable {
    public let version: String
    public let documents: [HelpDocument]

    public init(version: String = "1.0", documents: [HelpDocument] = []) {
        self.version = version
        self.documents = documents
    }
}
