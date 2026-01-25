//
//  MboxTypes.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-22.
//

import Foundation

// MARK: - Mbox Message

/// Represents an email message in mbox format (RFC 5322).
public struct MboxMessage: Sendable {
    /// The sender address for the "From " envelope line
    public let from: String

    /// Message subject (maps to publication title)
    public let subject: String

    /// Message date
    public let date: Date

    /// Unique message identifier
    public let messageID: String

    /// Custom headers (X-Imbib-* headers for metadata preservation)
    public let headers: [String: String]

    /// Message body (abstract text)
    public let body: String

    /// File attachments (PDFs and BibTeX)
    public let attachments: [MboxAttachment]

    public init(
        from: String,
        subject: String,
        date: Date,
        messageID: String,
        headers: [String: String] = [:],
        body: String = "",
        attachments: [MboxAttachment] = []
    ) {
        self.from = from
        self.subject = subject
        self.date = date
        self.messageID = messageID
        self.headers = headers
        self.body = body
        self.attachments = attachments
    }
}

// MARK: - Mbox Attachment

/// Represents a MIME attachment in an mbox message.
public struct MboxAttachment: Sendable {
    /// Filename for Content-Disposition
    public let filename: String

    /// MIME content type (e.g., "application/pdf")
    public let contentType: String

    /// Raw attachment data
    public let data: Data

    /// Custom headers for imbib metadata (X-Imbib-LinkedFile-*)
    public let customHeaders: [String: String]

    public init(
        filename: String,
        contentType: String,
        data: Data,
        customHeaders: [String: String] = [:]
    ) {
        self.filename = filename
        self.contentType = contentType
        self.data = data
        self.customHeaders = customHeaders
    }
}

// MARK: - Mbox Import Preview

/// Preview data for import confirmation UI.
public struct MboxImportPreview: Sendable {
    /// Library metadata from the mbox header
    public let libraryMetadata: LibraryMetadata?

    /// Publications to import
    public let publications: [PublicationPreview]

    /// Duplicate publications that need user decision
    public let duplicates: [DuplicateInfo]

    /// Parsing errors encountered
    public let parseErrors: [ParseError]

    public init(
        libraryMetadata: LibraryMetadata? = nil,
        publications: [PublicationPreview] = [],
        duplicates: [DuplicateInfo] = [],
        parseErrors: [ParseError] = []
    ) {
        self.libraryMetadata = libraryMetadata
        self.publications = publications
        self.duplicates = duplicates
        self.parseErrors = parseErrors
    }
}

// MARK: - Library Metadata

/// Library-level metadata from the mbox header message.
public struct LibraryMetadata: Sendable, Codable {
    public let libraryID: UUID?
    public let name: String
    public let bibtexPath: String?
    public let exportVersion: String
    public let exportDate: Date
    public let collections: [CollectionInfo]
    public let smartSearches: [SmartSearchInfo]

    public init(
        libraryID: UUID? = nil,
        name: String,
        bibtexPath: String? = nil,
        exportVersion: String = "1.0",
        exportDate: Date = Date(),
        collections: [CollectionInfo] = [],
        smartSearches: [SmartSearchInfo] = []
    ) {
        self.libraryID = libraryID
        self.name = name
        self.bibtexPath = bibtexPath
        self.exportVersion = exportVersion
        self.exportDate = exportDate
        self.collections = collections
        self.smartSearches = smartSearches
    }
}

// MARK: - Collection Info

/// Collection metadata for export/import.
public struct CollectionInfo: Sendable, Codable {
    public let id: UUID
    public let name: String
    public let parentID: UUID?
    public let isSmartCollection: Bool
    public let predicate: String?

    public init(
        id: UUID,
        name: String,
        parentID: UUID? = nil,
        isSmartCollection: Bool = false,
        predicate: String? = nil
    ) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.isSmartCollection = isSmartCollection
        self.predicate = predicate
    }
}

// MARK: - Smart Search Info

/// Smart search metadata for export/import.
public struct SmartSearchInfo: Sendable, Codable {
    public let id: UUID
    public let name: String
    public let query: String
    public let sourceIDs: [String]
    public let maxResults: Int

    public init(
        id: UUID,
        name: String,
        query: String,
        sourceIDs: [String] = [],
        maxResults: Int = 50
    ) {
        self.id = id
        self.name = name
        self.query = query
        self.sourceIDs = sourceIDs
        self.maxResults = maxResults
    }
}

// MARK: - Publication Preview

/// Publication data for import preview.
public struct PublicationPreview: Sendable, Identifiable {
    public let id: UUID
    public let citeKey: String
    public let title: String
    public let authors: String
    public let year: Int?
    public let entryType: String
    public let doi: String?
    public let arxivID: String?
    public let hasAbstract: Bool
    public let fileCount: Int
    public let collectionIDs: [UUID]
    public let rawBibTeX: String?

    /// Full message data for actual import
    public let message: MboxMessage

    public init(
        id: UUID,
        citeKey: String,
        title: String,
        authors: String,
        year: Int? = nil,
        entryType: String = "article",
        doi: String? = nil,
        arxivID: String? = nil,
        hasAbstract: Bool = false,
        fileCount: Int = 0,
        collectionIDs: [UUID] = [],
        rawBibTeX: String? = nil,
        message: MboxMessage
    ) {
        self.id = id
        self.citeKey = citeKey
        self.title = title
        self.authors = authors
        self.year = year
        self.entryType = entryType
        self.doi = doi
        self.arxivID = arxivID
        self.hasAbstract = hasAbstract
        self.fileCount = fileCount
        self.collectionIDs = collectionIDs
        self.rawBibTeX = rawBibTeX
        self.message = message
    }
}

// MARK: - Duplicate Info

/// Information about a duplicate publication.
public struct DuplicateInfo: Sendable, Identifiable {
    public let id: UUID
    public let importPublication: PublicationPreview
    public let existingCiteKey: String
    public let existingTitle: String
    public let matchType: MatchType

    public enum MatchType: String, Sendable {
        case uuid = "UUID"
        case citeKey = "Cite Key"
        case doi = "DOI"
        case arxivID = "arXiv ID"
    }

    public init(
        id: UUID = UUID(),
        importPublication: PublicationPreview,
        existingCiteKey: String,
        existingTitle: String,
        matchType: MatchType
    ) {
        self.id = id
        self.importPublication = importPublication
        self.existingCiteKey = existingCiteKey
        self.existingTitle = existingTitle
        self.matchType = matchType
    }
}

// MARK: - Parse Error

/// Error encountered during mbox parsing.
public struct ParseError: Sendable, Identifiable {
    public let id: UUID
    public let messageIndex: Int
    public let description: String

    public init(
        id: UUID = UUID(),
        messageIndex: Int,
        description: String
    ) {
        self.id = id
        self.messageIndex = messageIndex
        self.description = description
    }
}

// MARK: - Import Result

/// Result of an mbox import operation.
public struct MboxImportResult: Sendable {
    public let importedCount: Int
    public let skippedCount: Int
    public let mergedCount: Int
    public let errors: [MboxImportErrorInfo]

    public init(
        importedCount: Int = 0,
        skippedCount: Int = 0,
        mergedCount: Int = 0,
        errors: [MboxImportErrorInfo] = []
    ) {
        self.importedCount = importedCount
        self.skippedCount = skippedCount
        self.mergedCount = mergedCount
        self.errors = errors
    }
}

// MARK: - Import Error

/// Error during import execution.
public struct MboxImportErrorInfo: Sendable, Identifiable {
    public let id: UUID
    public let citeKey: String?
    public let description: String

    public init(
        id: UUID = UUID(),
        citeKey: String? = nil,
        description: String
    ) {
        self.id = id
        self.citeKey = citeKey
        self.description = description
    }
}

// MARK: - Mbox Custom Headers

/// Constants for custom X-Imbib headers.
public enum MboxHeader {
    public static let imbibID = "X-Imbib-ID"
    public static let imbibCiteKey = "X-Imbib-CiteKey"
    public static let imbibEntryType = "X-Imbib-EntryType"
    public static let imbibDOI = "X-Imbib-DOI"
    public static let imbibArXiv = "X-Imbib-ArXiv"
    public static let imbibJournal = "X-Imbib-Journal"
    public static let imbibCollections = "X-Imbib-Collections"
    public static let imbibBibcode = "X-Imbib-Bibcode"

    // Library headers
    public static let libraryID = "X-Imbib-Library-ID"
    public static let libraryName = "X-Imbib-Library-Name"
    public static let libraryBibtexPath = "X-Imbib-Library-BibtexPath"
    public static let exportVersion = "X-Imbib-Export-Version"
    public static let exportDate = "X-Imbib-Export-Date"

    // Linked file headers (for attachments)
    public static let linkedFilePath = "X-Imbib-LinkedFile-Path"
    public static let linkedFileIsMain = "X-Imbib-LinkedFile-IsMain"
}

// MARK: - Export Options

/// Options for mbox export.
public struct MboxExportOptions: Sendable {
    /// Whether to include file attachments
    public let includeFiles: Bool

    /// Whether to include BibTeX attachment
    public let includeBibTeX: Bool

    /// Maximum file size to include (nil = no limit)
    public let maxFileSize: Int?

    public init(
        includeFiles: Bool = true,
        includeBibTeX: Bool = true,
        maxFileSize: Int? = nil
    ) {
        self.includeFiles = includeFiles
        self.includeBibTeX = includeBibTeX
        self.maxFileSize = maxFileSize
    }

    public static let `default` = MboxExportOptions()
}

// MARK: - Import Options

/// Options for mbox import.
public struct MboxImportOptions: Sendable {
    /// How to handle duplicates
    public let duplicateHandling: DuplicateHandling

    /// Whether to import files
    public let importFiles: Bool

    /// Whether to preserve original UUIDs
    public let preserveUUIDs: Bool

    public enum DuplicateHandling: String, Sendable, CaseIterable {
        case skip = "Skip"
        case replace = "Replace"
        case merge = "Merge"
        case askEach = "Ask for Each"
    }

    public init(
        duplicateHandling: DuplicateHandling = .skip,
        importFiles: Bool = true,
        preserveUUIDs: Bool = true
    ) {
        self.duplicateHandling = duplicateHandling
        self.importFiles = importFiles
        self.preserveUUIDs = preserveUUIDs
    }

    public static let `default` = MboxImportOptions()
}
