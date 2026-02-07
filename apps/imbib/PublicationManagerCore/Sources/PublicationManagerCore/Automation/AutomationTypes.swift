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

// MARK: - Flag Result

/// Serializable representation of a paper's flag.
public struct FlagResult: Codable, Sendable, Hashable {
    public let color: String    // "red"|"amber"|"blue"|"gray"
    public let style: String    // "solid"|"dashed"|"dotted"
    public let length: String   // "full"|"half"|"quarter"

    public init(color: String, style: String = "solid", length: String = "full") {
        self.color = color
        self.style = style
        self.length = length
    }
}

// MARK: - Tag Result

/// Serializable representation of a tag.
public struct TagResult: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let name: String           // leaf segment
    public let canonicalPath: String  // full path e.g. "methods/sims"
    public let parentPath: String?
    public let useCount: Int
    public let publicationCount: Int

    public init(
        id: UUID,
        name: String,
        canonicalPath: String,
        parentPath: String? = nil,
        useCount: Int = 0,
        publicationCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.canonicalPath = canonicalPath
        self.parentPath = parentPath
        self.useCount = useCount
        self.publicationCount = publicationCount
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
    public var tags: [String]?
    public var flagColor: String?
    public var addedAfter: Date?
    public var addedBefore: Date?

    public init(
        yearFrom: Int? = nil,
        yearTo: Int? = nil,
        authors: [String]? = nil,
        isRead: Bool? = nil,
        hasLocalPDF: Bool? = nil,
        collections: [UUID]? = nil,
        libraries: [UUID]? = nil,
        limit: Int? = nil,
        offset: Int? = nil,
        tags: [String]? = nil,
        flagColor: String? = nil,
        addedAfter: Date? = nil,
        addedBefore: Date? = nil
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
        self.tags = tags
        self.flagColor = flagColor
        self.addedAfter = addedAfter
        self.addedBefore = addedBefore
    }
}

// MARK: - External Search Result

/// Result from searching external sources (ADS, arXiv, Crossref, etc.).
/// Contains identifiers that can be passed to `addPapers()`.
public struct ExternalSearchResult: Codable, Sendable {
    public let title: String
    public let authors: [String]
    public let year: Int?
    public let venue: String
    public let abstract: String
    public let sourceID: String
    public let doi: String?
    public let arxivID: String?
    public let bibcode: String?

    /// The best identifier to use with `addPapers()`.
    public var bestIdentifier: String {
        if let doi = doi, !doi.isEmpty { return doi }
        if let arxiv = arxivID, !arxiv.isEmpty { return arxiv }
        if let bib = bibcode, !bib.isEmpty { return bib }
        return title
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
    public let tags: [String]
    public let flag: FlagResult?
    public let collectionIDs: [UUID]
    public let libraryIDs: [UUID]
    public let notes: String?
    public let annotationCount: Int

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
        pdfURLs: [String] = [],
        tags: [String] = [],
        flag: FlagResult? = nil,
        collectionIDs: [UUID] = [],
        libraryIDs: [UUID] = [],
        notes: String? = nil,
        annotationCount: Int = 0
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
        self.tags = tags
        self.flag = flag
        self.collectionIDs = collectionIDs
        self.libraryIDs = libraryIDs
        self.notes = notes
        self.annotationCount = annotationCount
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
    public let isShared: Bool
    public let isShareOwner: Bool
    public let participantCount: Int
    public let canEdit: Bool

    public init(
        id: UUID,
        name: String,
        paperCount: Int,
        collectionCount: Int,
        isDefault: Bool = false,
        isInbox: Bool = false,
        isShared: Bool = false,
        isShareOwner: Bool = false,
        participantCount: Int = 0,
        canEdit: Bool = true
    ) {
        self.id = id
        self.name = name
        self.paperCount = paperCount
        self.collectionCount = collectionCount
        self.isDefault = isDefault
        self.isInbox = isInbox
        self.isShared = isShared
        self.isShareOwner = isShareOwner
        self.participantCount = participantCount
        self.canEdit = canEdit
    }
}

// MARK: - Operation Results

/// Result of adding papers to the library.
public struct AddToContainerResult: Codable, Sendable {
    public let assigned: [String]  // Identifiers that were assigned
    public let notFound: [String]  // Identifiers not found in library
}

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

// MARK: - Collaboration Types

/// Serializable representation of a share participant.
public struct ParticipantResult: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let displayName: String?
    public let email: String?
    public let permission: String  // "readOnly" | "readWrite"
    public let isOwner: Bool
    public let status: String  // "accepted" | "pending" | "removed"

    public init(
        id: String,
        displayName: String? = nil,
        email: String? = nil,
        permission: String = "readOnly",
        isOwner: Bool = false,
        status: String = "accepted"
    ) {
        self.id = id
        self.displayName = displayName
        self.email = email
        self.permission = permission
        self.isOwner = isOwner
        self.status = status
    }
}

/// Serializable representation of an activity record.
public struct ActivityResult: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let activityType: String  // "added" | "removed" | "annotated" | "commented" | "organized"
    public let actorDisplayName: String?
    public let targetTitle: String?
    public let targetID: UUID?
    public let detail: String?
    public let date: Date

    public init(
        id: UUID,
        activityType: String,
        actorDisplayName: String? = nil,
        targetTitle: String? = nil,
        targetID: UUID? = nil,
        detail: String? = nil,
        date: Date = Date()
    ) {
        self.id = id
        self.activityType = activityType
        self.actorDisplayName = actorDisplayName
        self.targetTitle = targetTitle
        self.targetID = targetID
        self.detail = detail
        self.date = date
    }
}

/// Serializable representation of a comment.
public struct CommentResult: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let text: String
    public let authorDisplayName: String?
    public let authorIdentifier: String?
    public let dateCreated: Date
    public let dateModified: Date
    public let parentCommentID: UUID?
    public let replies: [CommentResult]

    public init(
        id: UUID,
        text: String,
        authorDisplayName: String? = nil,
        authorIdentifier: String? = nil,
        dateCreated: Date = Date(),
        dateModified: Date = Date(),
        parentCommentID: UUID? = nil,
        replies: [CommentResult] = []
    ) {
        self.id = id
        self.text = text
        self.authorDisplayName = authorDisplayName
        self.authorIdentifier = authorIdentifier
        self.dateCreated = dateCreated
        self.dateModified = dateModified
        self.parentCommentID = parentCommentID
        self.replies = replies
    }
}

/// Serializable representation of a reading assignment/suggestion.
public struct AssignmentResult: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let publicationID: UUID
    public let publicationTitle: String?
    public let publicationCiteKey: String?
    public let assigneeName: String?
    public let assignedByName: String?
    public let note: String?
    public let dateCreated: Date
    public let dueDate: Date?
    public let libraryID: UUID?

    public init(
        id: UUID,
        publicationID: UUID,
        publicationTitle: String? = nil,
        publicationCiteKey: String? = nil,
        assigneeName: String? = nil,
        assignedByName: String? = nil,
        note: String? = nil,
        dateCreated: Date = Date(),
        dueDate: Date? = nil,
        libraryID: UUID? = nil
    ) {
        self.id = id
        self.publicationID = publicationID
        self.publicationTitle = publicationTitle
        self.publicationCiteKey = publicationCiteKey
        self.assigneeName = assigneeName
        self.assignedByName = assignedByName
        self.note = note
        self.dateCreated = dateCreated
        self.dueDate = dueDate
        self.libraryID = libraryID
    }
}

/// Result of a share operation.
public struct ShareResult: Codable, Sendable {
    public let libraryID: UUID
    public let shareURL: String?
    public let isShared: Bool

    public init(libraryID: UUID, shareURL: String? = nil, isShared: Bool = false) {
        self.libraryID = libraryID
        self.shareURL = shareURL
        self.isShared = isShared
    }
}

// MARK: - Annotation Types

/// Serializable representation of a PDF annotation.
public struct AnnotationResult: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let type: String  // "highlight" | "underline" | "strikethrough" | "note" | "freeText" | "ink"
    public let pageNumber: Int
    public let contents: String?  // Text content for note/freeText annotations
    public let selectedText: String?  // Selected text for markup annotations
    public let color: String  // Hex color string e.g. "#FFFF00"
    public let author: String?
    public let dateCreated: Date
    public let dateModified: Date

    public init(
        id: UUID,
        type: String,
        pageNumber: Int,
        contents: String? = nil,
        selectedText: String? = nil,
        color: String = "#FFFF00",
        author: String? = nil,
        dateCreated: Date = Date(),
        dateModified: Date = Date()
    ) {
        self.id = id
        self.type = type
        self.pageNumber = pageNumber
        self.contents = contents
        self.selectedText = selectedText
        self.color = color
        self.author = author
        self.dateCreated = dateCreated
        self.dateModified = dateModified
    }
}

/// Available annotation types for creation.
public enum AnnotationType: String, Codable, Sendable, CaseIterable {
    case highlight
    case underline
    case strikethrough
    case note
    case freeText

    /// Default color for this annotation type
    public var defaultColor: String {
        switch self {
        case .highlight: return "#FFFF00"  // Yellow
        case .underline: return "#FF0000"  // Red
        case .strikethrough: return "#FF0000"  // Red
        case .note: return "#FFFF00"  // Yellow
        case .freeText: return "#000000"  // Black
        }
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
    case commentNotFound(UUID)
    case assignmentNotFound(UUID)
    case participantNotFound(String)
    case sharingUnavailable
    case notShared
    case notShareOwner
    case annotationNotFound(UUID)
    case linkedFileNotFound(String)  // Publication has no PDF

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
        case .commentNotFound(let id):
            return "Comment not found: \(id)"
        case .assignmentNotFound(let id):
            return "Assignment not found: \(id)"
        case .participantNotFound(let id):
            return "Participant not found: \(id)"
        case .sharingUnavailable:
            return "CloudKit sharing is not available"
        case .notShared:
            return "Library is not shared"
        case .notShareOwner:
            return "Only the share owner can perform this operation"
        case .annotationNotFound(let id):
            return "Annotation not found: \(id)"
        case .linkedFileNotFound(let citeKey):
            return "No PDF attached to paper: \(citeKey)"
        }
    }
}
