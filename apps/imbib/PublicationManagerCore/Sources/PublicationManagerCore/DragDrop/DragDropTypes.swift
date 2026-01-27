//
//  DragDropTypes.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-16.
//

import Foundation
import UniformTypeIdentifiers
import CoreData

// MARK: - Drop Target

/// Represents a valid drop target in the sidebar or content area.
public enum DropTarget: Sendable, Equatable {
    /// Drop on a specific publication (for attaching files)
    case publication(publicationID: UUID, libraryID: UUID?)

    /// Drop on a library (for importing papers or adding to library)
    case library(libraryID: UUID)

    /// Drop on a collection (for importing papers or adding to collection)
    case collection(collectionID: UUID, libraryID: UUID)

    /// Drop on the new library zone (for creating a library from dropped files)
    case newLibraryZone

    /// Drop on inbox
    case inbox

    public var libraryID: UUID? {
        switch self {
        case .publication(_, let libraryID):
            return libraryID
        case .library(let libraryID):
            return libraryID
        case .collection(_, let libraryID):
            return libraryID
        case .newLibraryZone, .inbox:
            return nil
        }
    }
}

// MARK: - Drop Validation

/// Result of validating a drop operation.
public struct DropValidation: Sendable {
    /// Whether the drop is valid
    public let isValid: Bool

    /// Category of files being dropped
    public let category: DroppedFileCategory

    /// Count of files in each category
    public let fileCounts: [DroppedFileCategory: Int]

    /// Badge text to display (e.g., "Import 3 PDFs")
    public let badgeText: String?

    /// Badge icon to display
    public let badgeIcon: String?

    public init(
        isValid: Bool,
        category: DroppedFileCategory = .unknown,
        fileCounts: [DroppedFileCategory: Int] = [:],
        badgeText: String? = nil,
        badgeIcon: String? = nil
    ) {
        self.isValid = isValid
        self.category = category
        self.fileCounts = fileCounts
        self.badgeText = badgeText
        self.badgeIcon = badgeIcon
    }

    public static let invalid = DropValidation(isValid: false)
}

// MARK: - Dropped File Category

/// Category of dropped file(s) to determine handling.
public enum DroppedFileCategory: Sendable, Hashable {
    /// PDF files that should create publications
    case pdf

    /// BibTeX files (.bib)
    case bibtex

    /// RIS files (.ris)
    case ris

    /// Publication ID transfers (internal drag)
    case publicationTransfer

    /// Generic attachments for existing publications
    case attachment

    /// Unknown or mixed content
    case unknown

    public var displayName: String {
        switch self {
        case .pdf: return "PDF"
        case .bibtex: return "BibTeX"
        case .ris: return "RIS"
        case .publicationTransfer: return "Publication"
        case .attachment: return "File"
        case .unknown: return "Item"
        }
    }
}

// MARK: - Drop Result

/// Result of a drop operation.
public enum DropResult: Sendable {
    /// Drop was handled successfully
    case success(message: String?)

    /// Drop requires user confirmation (shows preview)
    case needsConfirmation

    /// Drop failed
    case failure(error: Error)

    /// Drop is being processed asynchronously
    case processing

    public var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

// MARK: - PDF Import Preview

/// Preview data for a PDF import operation.
public struct PDFImportPreview: Identifiable, Sendable {
    public let id: UUID

    /// URL of the source PDF
    public let sourceURL: URL

    /// Filename of the source PDF
    public let filename: String

    /// File size in bytes
    public let fileSize: Int64

    /// Extracted metadata from the PDF
    public let extractedMetadata: PDFExtractedMetadata?

    /// Enriched metadata from online sources (DOI lookup, etc.)
    public var enrichedMetadata: EnrichedMetadata?

    /// Whether a duplicate was detected
    public let isDuplicate: Bool

    /// Existing publication if duplicate
    public let existingPublication: UUID?

    /// Status of this import item
    public var status: ImportItemStatus

    /// Selected action for this item
    public var selectedAction: ImportAction

    // MARK: - User-Edited Fields

    /// User-edited title (overrides extracted/enriched)
    public var userEditedTitle: String?

    /// User-edited authors (overrides extracted/enriched)
    public var userEditedAuthors: String?

    /// User-edited year (overrides extracted/enriched)
    public var userEditedYear: String?

    /// User-edited DOI (for manual lookup)
    public var userEditedDOI: String?

    /// User-edited arXiv ID (for manual lookup)
    public var userEditedArXivID: String?

    /// User-edited journal
    public var userEditedJournal: String?

    // MARK: - Computed Properties

    /// Best title: user-edited → enriched → extracted
    public var effectiveTitle: String? {
        if let userTitle = userEditedTitle, !userTitle.isEmpty { return userTitle }
        if let enrichedTitle = enrichedMetadata?.title, !enrichedTitle.isEmpty { return enrichedTitle }
        return extractedMetadata?.bestTitle
    }

    /// Best authors: user-edited → enriched → extracted
    public var effectiveAuthors: [String] {
        if let userAuthors = userEditedAuthors, !userAuthors.isEmpty {
            // Parse comma-separated or "and"-separated author string
            return userAuthors
                .replacingOccurrences(of: " and ", with: ", ")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        if let enrichedAuthors = enrichedMetadata?.authors, !enrichedAuthors.isEmpty { return enrichedAuthors }
        if let heuristicAuthors = extractedMetadata?.heuristicAuthors, !heuristicAuthors.isEmpty { return heuristicAuthors }
        if let author = extractedMetadata?.author { return [author] }
        return []
    }

    /// Best year: user-edited → enriched → extracted
    public var effectiveYear: Int? {
        if let userYear = userEditedYear, let year = Int(userYear) { return year }
        if let enrichedYear = enrichedMetadata?.year { return enrichedYear }
        return extractedMetadata?.heuristicYear
    }

    /// Best DOI: user-edited → enriched → extracted
    public var effectiveDOI: String? {
        if let userDOI = userEditedDOI, !userDOI.isEmpty { return userDOI }
        if let enrichedDOI = enrichedMetadata?.doi, !enrichedDOI.isEmpty { return enrichedDOI }
        return extractedMetadata?.extractedDOI
    }

    /// Best arXiv ID: user-edited → enriched → extracted
    public var effectiveArXivID: String? {
        if let userArXiv = userEditedArXivID, !userArXiv.isEmpty { return userArXiv }
        if let enrichedArXiv = enrichedMetadata?.arxivID, !enrichedArXiv.isEmpty { return enrichedArXiv }
        return extractedMetadata?.extractedArXivID
    }

    public init(
        id: UUID = UUID(),
        sourceURL: URL,
        filename: String,
        fileSize: Int64,
        extractedMetadata: PDFExtractedMetadata? = nil,
        enrichedMetadata: EnrichedMetadata? = nil,
        isDuplicate: Bool = false,
        existingPublication: UUID? = nil,
        status: ImportItemStatus = .pending,
        selectedAction: ImportAction = .importAsNew,
        userEditedTitle: String? = nil,
        userEditedAuthors: String? = nil,
        userEditedYear: String? = nil,
        userEditedDOI: String? = nil,
        userEditedArXivID: String? = nil,
        userEditedJournal: String? = nil
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.filename = filename
        self.fileSize = fileSize
        self.extractedMetadata = extractedMetadata
        self.enrichedMetadata = enrichedMetadata
        self.isDuplicate = isDuplicate
        self.existingPublication = existingPublication
        self.status = status
        self.selectedAction = selectedAction
        self.userEditedTitle = userEditedTitle
        self.userEditedAuthors = userEditedAuthors
        self.userEditedYear = userEditedYear
        self.userEditedDOI = userEditedDOI
        self.userEditedArXivID = userEditedArXivID
        self.userEditedJournal = userEditedJournal
    }
}

// MARK: - Import Item Status

/// Status of an import item during processing.
public enum ImportItemStatus: Sendable {
    case pending
    case extractingMetadata
    case enriching
    case ready
    case importing
    case completed
    case failed(Error)
    case skipped

    public var displayText: String {
        switch self {
        case .pending: return "Pending"
        case .extractingMetadata: return "Extracting..."
        case .enriching: return "Looking up..."
        case .ready: return "Ready"
        case .importing: return "Importing..."
        case .completed: return "Imported"
        case .failed: return "Failed"
        case .skipped: return "Skipped"
        }
    }
}

// MARK: - Import Action

/// Action to take for an import item.
public enum ImportAction: String, CaseIterable, Sendable {
    case importAsNew = "Import as new publication"
    case attachToExisting = "Attach to existing"
    case skip = "Skip"
    case replace = "Replace existing"
}

// MARK: - Enriched Metadata

/// Metadata enriched from online sources.
public struct EnrichedMetadata: Sendable {
    public let title: String?
    public let authors: [String]
    public let year: Int?
    public let journal: String?
    public let doi: String?
    public let arxivID: String?
    public let abstract: String?
    public let bibtex: String?
    public let source: String  // e.g., "Crossref", "ADS", "arXiv"

    public init(
        title: String? = nil,
        authors: [String] = [],
        year: Int? = nil,
        journal: String? = nil,
        doi: String? = nil,
        arxivID: String? = nil,
        abstract: String? = nil,
        bibtex: String? = nil,
        source: String
    ) {
        self.title = title
        self.authors = authors
        self.year = year
        self.journal = journal
        self.doi = doi
        self.arxivID = arxivID
        self.abstract = abstract
        self.bibtex = bibtex
        self.source = source
    }
}

// MARK: - BibTeX Import Preview

/// Preview data for a BibTeX/RIS file import.
public struct BibImportPreview: Identifiable, Sendable {
    public let id: UUID

    /// URL of the source file
    public let sourceURL: URL

    /// File format
    public let format: BibFileFormat

    /// Parsed entries
    public let entries: [BibImportEntry]

    /// Parse errors encountered
    public let parseErrors: [String]

    public init(
        id: UUID = UUID(),
        sourceURL: URL,
        format: BibFileFormat,
        entries: [BibImportEntry],
        parseErrors: [String] = []
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.format = format
        self.entries = entries
        self.parseErrors = parseErrors
    }
}

// MARK: - Bib File Format

/// Format of a bibliography file.
public enum BibFileFormat: String, Sendable {
    case bibtex = "BibTeX"
    case ris = "RIS"

    public var fileExtensions: [String] {
        switch self {
        case .bibtex: return ["bib", "bibtex"]
        case .ris: return ["ris"]
        }
    }
}

// MARK: - BibTeX Import Entry

/// A single entry in a BibTeX/RIS import preview.
public struct BibImportEntry: Identifiable, Sendable {
    public let id: UUID

    /// Cite key (for BibTeX) or generated key
    public let citeKey: String

    /// Entry type (article, book, etc.)
    public let entryType: String

    /// Title
    public let title: String?

    /// Authors
    public let authors: [String]

    /// Year
    public let year: Int?

    /// Whether this entry is selected for import
    public var isSelected: Bool

    /// Whether a duplicate exists
    public let isDuplicate: Bool

    /// Existing publication ID if duplicate
    public let existingPublicationID: UUID?

    /// Raw BibTeX/RIS for preview
    public let rawContent: String?

    public init(
        id: UUID = UUID(),
        citeKey: String,
        entryType: String,
        title: String? = nil,
        authors: [String] = [],
        year: Int? = nil,
        isSelected: Bool = true,
        isDuplicate: Bool = false,
        existingPublicationID: UUID? = nil,
        rawContent: String? = nil
    ) {
        self.id = id
        self.citeKey = citeKey
        self.entryType = entryType
        self.title = title
        self.authors = authors
        self.year = year
        self.isSelected = isSelected
        self.isDuplicate = isDuplicate
        self.existingPublicationID = existingPublicationID
        self.rawContent = rawContent
    }
}

// MARK: - Drop Preview Data

/// Data for displaying a drop preview sheet.
public enum DropPreviewData: Identifiable, Sendable, Equatable {
    case pdfImport([PDFImportPreview])
    case bibImport(BibImportPreview)

    public var id: String {
        switch self {
        case .pdfImport(let previews):
            return "pdf-\(previews.map { $0.id.uuidString }.joined())"
        case .bibImport(let preview):
            return "bib-\(preview.id.uuidString)"
        }
    }

    /// Equatable conformance based on ID comparison for onChange detection.
    public static func == (lhs: DropPreviewData, rhs: DropPreviewData) -> Bool {
        lhs.id == rhs.id
    }
}
