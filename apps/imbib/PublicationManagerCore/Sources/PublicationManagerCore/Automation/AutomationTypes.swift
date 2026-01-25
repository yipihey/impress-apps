//
//  AutomationTypes.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-16.
//
//  Core data types for the automation layer (ADR-018).
//  These types are used by AutomationService, MCP server, AppIntents, and REST API.
//

import Foundation

// MARK: - Paper Identifier

/// Flexible paper identifier for lookup operations.
/// Supports multiple identifier types commonly used in academic databases.
public enum PaperIdentifier: Codable, Sendable, Hashable {
    case citeKey(String)
    case doi(String)
    case arxiv(String)
    case bibcode(String)
    case uuid(UUID)
    case pmid(String)
    case semanticScholar(String)
    case openAlex(String)

    /// Create from a string, auto-detecting the identifier type.
    ///
    /// Detection rules:
    /// - UUID format → uuid
    /// - Starts with "10." → doi
    /// - Contains "arxiv" or matches arXiv pattern → arxiv
    /// - Matches bibcode pattern (19 chars) → bibcode
    /// - Otherwise → citeKey
    public static func fromString(_ string: String) -> PaperIdentifier {
        let trimmed = string.trimmingCharacters(in: .whitespaces)

        // Check for UUID
        if let uuid = UUID(uuidString: trimmed) {
            return .uuid(uuid)
        }

        // Check for DOI (starts with 10.)
        if trimmed.hasPrefix("10.") || trimmed.lowercased().hasPrefix("doi:") {
            let doi = trimmed.hasPrefix("doi:") ? String(trimmed.dropFirst(4)) : trimmed
            return .doi(doi.trimmingCharacters(in: .whitespaces))
        }

        // Check for arXiv ID patterns
        // Old format: hep-th/9901001, astro-ph/0001234
        // New format: 2301.12345, 2301.12345v2
        let arxivPatterns = [
            #"^\d{4}\.\d{4,5}(v\d+)?$"#,      // New format
            #"^[a-z-]+/\d{7}(v\d+)?$"#,        // Old format
            #"^arXiv:\d{4}\.\d{4,5}(v\d+)?$"#  // With prefix
        ]
        for pattern in arxivPatterns {
            if trimmed.range(of: pattern, options: .regularExpression) != nil {
                let id = trimmed.hasPrefix("arXiv:") ? String(trimmed.dropFirst(6)) : trimmed
                return .arxiv(id)
            }
        }

        // Check for bibcode (19 characters, starts with year)
        // Format: YYYYJJJJJVVVVMPPPPA (e.g., 2023ApJ...950L..22A)
        if trimmed.count == 19, let year = Int(trimmed.prefix(4)), year >= 1800, year <= 2100 {
            return .bibcode(trimmed)
        }

        // Check for PMID (numeric only)
        if trimmed.allSatisfy({ $0.isNumber }) && trimmed.count >= 5 && trimmed.count <= 10 {
            return .pmid(trimmed)
        }

        // Check for Semantic Scholar ID (40-char hex string)
        if trimmed.count == 40, trimmed.allSatisfy({ $0.isHexDigit }) {
            return .semanticScholar(trimmed)
        }

        // Check for OpenAlex ID (starts with W followed by digits)
        if trimmed.hasPrefix("W") && trimmed.dropFirst().allSatisfy({ $0.isNumber }) {
            return .openAlex(trimmed)
        }

        // Default to cite key
        return .citeKey(trimmed)
    }

    /// The identifier value as a string
    public var value: String {
        switch self {
        case .citeKey(let v): return v
        case .doi(let v): return v
        case .arxiv(let v): return v
        case .bibcode(let v): return v
        case .uuid(let v): return v.uuidString
        case .pmid(let v): return v
        case .semanticScholar(let v): return v
        case .openAlex(let v): return v
        }
    }

    /// Human-readable type name
    public var typeName: String {
        switch self {
        case .citeKey: return "citeKey"
        case .doi: return "doi"
        case .arxiv: return "arXiv"
        case .bibcode: return "bibcode"
        case .uuid: return "uuid"
        case .pmid: return "pmid"
        case .semanticScholar: return "semanticScholar"
        case .openAlex: return "openAlex"
        }
    }
}

// MARK: - Search Filters

/// Filters for library search operations.
public struct SearchFilters: Codable, Sendable {
    public var yearFrom: Int?
    public var yearTo: Int?
    public var authors: [String]?
    public var isRead: Bool?
    public var hasLocalPDF: Bool?
    public var collections: [UUID]?
    public var libraries: [UUID]?
    public var limit: Int?
    public var offset: Int?

    public init(
        yearFrom: Int? = nil,
        yearTo: Int? = nil,
        authors: [String]? = nil,
        isRead: Bool? = nil,
        hasLocalPDF: Bool? = nil,
        collections: [UUID]? = nil,
        libraries: [UUID]? = nil,
        limit: Int? = nil,
        offset: Int? = nil
    ) {
        self.yearFrom = yearFrom
        self.yearTo = yearTo
        self.authors = authors
        self.isRead = isRead
        self.hasLocalPDF = hasLocalPDF
        self.collections = collections
        self.libraries = libraries
        self.limit = limit
        self.offset = offset
    }
}

// MARK: - Paper Result

/// Complete serializable representation of a paper.
/// This is the primary data transfer object for automation operations.
public struct PaperResult: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let citeKey: String
    public let title: String
    public let authors: [String]
    public let year: Int?
    public let venue: String?
    public let abstract: String?
    public let doi: String?
    public let arxivID: String?
    public let bibcode: String?
    public let pmid: String?
    public let semanticScholarID: String?
    public let openAlexID: String?
    public let isRead: Bool
    public let isStarred: Bool
    public let hasPDF: Bool
    public let citationCount: Int?
    public let dateAdded: Date
    public let dateModified: Date
    public let bibtex: String
    public let webURL: String?
    public let pdfURLs: [String]

    public init(
        id: UUID,
        citeKey: String,
        title: String,
        authors: [String],
        year: Int? = nil,
        venue: String? = nil,
        abstract: String? = nil,
        doi: String? = nil,
        arxivID: String? = nil,
        bibcode: String? = nil,
        pmid: String? = nil,
        semanticScholarID: String? = nil,
        openAlexID: String? = nil,
        isRead: Bool = false,
        isStarred: Bool = false,
        hasPDF: Bool = false,
        citationCount: Int? = nil,
        dateAdded: Date = Date(),
        dateModified: Date = Date(),
        bibtex: String = "",
        webURL: String? = nil,
        pdfURLs: [String] = []
    ) {
        self.id = id
        self.citeKey = citeKey
        self.title = title
        self.authors = authors
        self.year = year
        self.venue = venue
        self.abstract = abstract
        self.doi = doi
        self.arxivID = arxivID
        self.bibcode = bibcode
        self.pmid = pmid
        self.semanticScholarID = semanticScholarID
        self.openAlexID = openAlexID
        self.isRead = isRead
        self.isStarred = isStarred
        self.hasPDF = hasPDF
        self.citationCount = citationCount
        self.dateAdded = dateAdded
        self.dateModified = dateModified
        self.bibtex = bibtex
        self.webURL = webURL
        self.pdfURLs = pdfURLs
    }

    /// First author's last name
    public var firstAuthorLastName: String? {
        guard let first = authors.first else { return nil }
        if first.contains(",") {
            return first.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces)
        }
        return first.components(separatedBy: " ").last
    }
}

// MARK: - Collection Result

/// Serializable representation of a collection.
public struct CollectionResult: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let name: String
    public let paperCount: Int
    public let isSmartCollection: Bool
    public let libraryID: UUID?
    public let libraryName: String?

    public init(
        id: UUID,
        name: String,
        paperCount: Int,
        isSmartCollection: Bool = false,
        libraryID: UUID? = nil,
        libraryName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.paperCount = paperCount
        self.isSmartCollection = isSmartCollection
        self.libraryID = libraryID
        self.libraryName = libraryName
    }
}

// MARK: - Library Result

/// Serializable representation of a library.
public struct LibraryResult: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let name: String
    public let paperCount: Int
    public let collectionCount: Int
    public let isDefault: Bool
    public let isInbox: Bool

    public init(
        id: UUID,
        name: String,
        paperCount: Int,
        collectionCount: Int,
        isDefault: Bool = false,
        isInbox: Bool = false
    ) {
        self.id = id
        self.name = name
        self.paperCount = paperCount
        self.collectionCount = collectionCount
        self.isDefault = isDefault
        self.isInbox = isInbox
    }
}

// MARK: - Operation Results

/// Result of adding papers to the library.
public struct AddPapersResult: Codable, Sendable {
    public let added: [PaperResult]
    public let duplicates: [String]  // Identifiers that matched existing papers
    public let failed: [String: String]  // Identifier → error message

    public init(
        added: [PaperResult] = [],
        duplicates: [String] = [],
        failed: [String: String] = [:]
    ) {
        self.added = added
        self.duplicates = duplicates
        self.failed = failed
    }

    /// Total number of papers processed
    public var totalProcessed: Int {
        added.count + duplicates.count + failed.count
    }

    /// Whether all operations succeeded (no failures)
    public var allSucceeded: Bool {
        failed.isEmpty
    }
}

/// Result of an export operation.
public struct ExportResult: Codable, Sendable {
    public let format: String  // "bibtex", "ris", etc.
    public let content: String
    public let paperCount: Int

    public init(format: String, content: String, paperCount: Int) {
        self.format = format
        self.content = content
        self.paperCount = paperCount
    }
}

/// Result of PDF download operations.
public struct DownloadResult: Codable, Sendable {
    public let downloaded: [String]  // Cite keys of newly downloaded PDFs
    public let alreadyHad: [String]  // Cite keys that already had PDFs
    public let failed: [String: String]  // Cite key → error message

    public init(
        downloaded: [String] = [],
        alreadyHad: [String] = [],
        failed: [String: String] = [:]
    ) {
        self.downloaded = downloaded
        self.alreadyHad = alreadyHad
        self.failed = failed
    }

    /// Total number of papers processed
    public var totalProcessed: Int {
        downloaded.count + alreadyHad.count + failed.count
    }
}

/// Result of a search operation.
public struct SearchOperationResult: Codable, Sendable {
    public let papers: [PaperResult]
    public let totalCount: Int
    public let hasMore: Bool
    public let sources: [String]

    public init(
        papers: [PaperResult],
        totalCount: Int? = nil,
        hasMore: Bool = false,
        sources: [String] = []
    ) {
        self.papers = papers
        self.totalCount = totalCount ?? papers.count
        self.hasMore = hasMore
        self.sources = sources
    }
}

// MARK: - Automation Errors

/// Errors that can occur during automation operations.
public enum AutomationOperationError: Error, LocalizedError, Sendable {
    case paperNotFound(String)
    case collectionNotFound(UUID)
    case libraryNotFound(UUID)
    case invalidIdentifier(String)
    case exportFailed(String)
    case downloadFailed(String)
    case searchFailed(String)
    case operationFailed(String)
    case unauthorized
    case rateLimited

    public var errorDescription: String? {
        switch self {
        case .paperNotFound(let id):
            return "Paper not found: \(id)"
        case .collectionNotFound(let id):
            return "Collection not found: \(id)"
        case .libraryNotFound(let id):
            return "Library not found: \(id)"
        case .invalidIdentifier(let id):
            return "Invalid identifier: \(id)"
        case .exportFailed(let reason):
            return "Export failed: \(reason)"
        case .downloadFailed(let reason):
            return "Download failed: \(reason)"
        case .searchFailed(let reason):
            return "Search failed: \(reason)"
        case .operationFailed(let reason):
            return "Operation failed: \(reason)"
        case .unauthorized:
            return "Unauthorized: automation API is disabled"
        case .rateLimited:
            return "Rate limited: too many requests"
        }
    }
}
