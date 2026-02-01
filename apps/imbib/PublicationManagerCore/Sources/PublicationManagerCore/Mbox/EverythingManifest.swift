//
//  EverythingManifest.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-29.
//

import Foundation

// MARK: - Everything Manifest

/// Global manifest for "Everything" mbox export format (v2.0).
/// Contains an index of all libraries, muted items, and dismissed papers.
public struct EverythingManifest: Sendable, Codable {
    /// Manifest format version
    public let manifestVersion: String

    /// When the export was created
    public let exportDate: Date

    /// Device name that created the export
    public let deviceName: String?

    /// Index of all libraries in the export
    public let libraries: [LibraryIndex]

    /// Muted items (authors, venues, categories, etc.)
    public let mutedItems: [MutedItemInfo]

    /// Dismissed papers (to prevent re-adding to Inbox)
    public let dismissedPapers: [DismissedPaperInfo]

    /// Total number of publications in the export (for progress display)
    public let totalPublications: Int

    public init(
        manifestVersion: String = "2.0",
        exportDate: Date = Date(),
        deviceName: String? = nil,
        libraries: [LibraryIndex] = [],
        mutedItems: [MutedItemInfo] = [],
        dismissedPapers: [DismissedPaperInfo] = [],
        totalPublications: Int = 0
    ) {
        self.manifestVersion = manifestVersion
        self.exportDate = exportDate
        self.deviceName = deviceName
        self.libraries = libraries
        self.mutedItems = mutedItems
        self.dismissedPapers = dismissedPapers
        self.totalPublications = totalPublications
    }
}

// MARK: - Library Index

/// Summary of a library in the manifest (lightweight, for index purposes).
public struct LibraryIndex: Sendable, Codable, Identifiable {
    public let id: UUID
    public let name: String
    public let type: LibraryType
    public let publicationCount: Int
    public let collectionCount: Int
    public let smartSearchCount: Int

    public init(
        id: UUID,
        name: String,
        type: LibraryType,
        publicationCount: Int = 0,
        collectionCount: Int = 0,
        smartSearchCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.publicationCount = publicationCount
        self.collectionCount = collectionCount
        self.smartSearchCount = smartSearchCount
    }
}

// MARK: - Muted Item Info

/// Information about a muted item for export/import.
public struct MutedItemInfo: Sendable, Codable, Identifiable {
    public var id: String { "\(type):\(value)" }

    /// Type of muted item: author, doi, venue, arxivCategory, bibcode
    public let type: String

    /// The muted value
    public let value: String

    /// When the item was muted
    public let dateAdded: Date?

    public init(
        type: String,
        value: String,
        dateAdded: Date? = nil
    ) {
        self.type = type
        self.value = value
        self.dateAdded = dateAdded
    }
}

// MARK: - Dismissed Paper Info

/// Information about a dismissed paper for export/import.
public struct DismissedPaperInfo: Sendable, Codable {
    /// DOI of the dismissed paper
    public let doi: String?

    /// arXiv ID of the dismissed paper
    public let arxivID: String?

    /// ADS bibcode of the dismissed paper
    public let bibcode: String?

    /// When the paper was dismissed
    public let dateDismissed: Date?

    public init(
        doi: String? = nil,
        arxivID: String? = nil,
        bibcode: String? = nil,
        dateDismissed: Date? = nil
    ) {
        self.doi = doi
        self.arxivID = arxivID
        self.bibcode = bibcode
        self.dateDismissed = dateDismissed
    }

    /// Whether this has at least one identifier
    public var hasIdentifier: Bool {
        doi != nil || arxivID != nil || bibcode != nil
    }
}

// MARK: - Everything Import Preview

/// Preview data for Everything import confirmation UI.
public struct EverythingImportPreview: Sendable {
    /// Parsed manifest
    public let manifest: EverythingManifest

    /// Library previews with detailed metadata
    public let libraries: [LibraryImportPreview]

    /// Publications to import (grouped by primary library)
    public let publications: [PublicationPreview]

    /// Duplicate publications that need user decision
    public let duplicates: [DuplicateInfo]

    /// Parsing errors encountered
    public let parseErrors: [ParseError]

    /// Libraries that conflict with existing ones
    public let libraryConflicts: [LibraryConflict]

    public init(
        manifest: EverythingManifest,
        libraries: [LibraryImportPreview] = [],
        publications: [PublicationPreview] = [],
        duplicates: [DuplicateInfo] = [],
        parseErrors: [ParseError] = [],
        libraryConflicts: [LibraryConflict] = []
    ) {
        self.manifest = manifest
        self.libraries = libraries
        self.publications = publications
        self.duplicates = duplicates
        self.parseErrors = parseErrors
        self.libraryConflicts = libraryConflicts
    }

    /// Total number of items to import
    public var totalItemCount: Int {
        publications.count + duplicates.count
    }
}

// MARK: - Library Import Preview

/// Preview of a library to be imported.
public struct LibraryImportPreview: Sendable, Identifiable {
    public let id: UUID
    public let metadata: LibraryMetadata
    public let publicationCount: Int
    public let isNew: Bool  // True if this will create a new library

    public init(
        id: UUID,
        metadata: LibraryMetadata,
        publicationCount: Int = 0,
        isNew: Bool = true
    ) {
        self.id = id
        self.metadata = metadata
        self.publicationCount = publicationCount
        self.isNew = isNew
    }
}

// MARK: - Library Conflict

/// Conflict between an imported library and an existing one.
public struct LibraryConflict: Sendable, Identifiable {
    public let id: UUID
    public let importName: String
    public let importType: LibraryType
    public let existingID: UUID
    public let existingName: String
    public var resolution: LibraryConflictResolution

    public init(
        id: UUID = UUID(),
        importName: String,
        importType: LibraryType,
        existingID: UUID,
        existingName: String,
        resolution: LibraryConflictResolution = .merge
    ) {
        self.id = id
        self.importName = importName
        self.importType = importType
        self.existingID = existingID
        self.existingName = existingName
        self.resolution = resolution
    }
}

// MARK: - Library Conflict Resolution

/// How to resolve a library name/type conflict during import.
public enum LibraryConflictResolution: String, Sendable, CaseIterable {
    case merge = "Merge"       // Merge publications into existing library
    case replace = "Replace"   // Replace existing library with imported one
    case rename = "Rename"     // Create new library with modified name
    case skip = "Skip"         // Skip importing this library

    public var description: String {
        switch self {
        case .merge:
            return "Merge publications into existing library"
        case .replace:
            return "Replace existing library (destructive)"
        case .rename:
            return "Create new library with a different name"
        case .skip:
            return "Skip this library entirely"
        }
    }
}

// MARK: - Everything Import Result

/// Result of an Everything mbox import operation.
public struct EverythingImportResult: Sendable {
    /// Number of libraries created
    public let librariesCreated: Int

    /// Number of libraries merged
    public let librariesMerged: Int

    /// Number of collections created
    public let collectionsCreated: Int

    /// Number of smart searches created
    public let smartSearchesCreated: Int

    /// Number of publications imported
    public let publicationsImported: Int

    /// Number of publications skipped (duplicates)
    public let publicationsSkipped: Int

    /// Number of publications merged
    public let publicationsMerged: Int

    /// Number of muted items imported
    public let mutedItemsImported: Int

    /// Number of dismissed papers imported
    public let dismissedPapersImported: Int

    /// Errors encountered during import
    public let errors: [MboxImportErrorInfo]

    public init(
        librariesCreated: Int = 0,
        librariesMerged: Int = 0,
        collectionsCreated: Int = 0,
        smartSearchesCreated: Int = 0,
        publicationsImported: Int = 0,
        publicationsSkipped: Int = 0,
        publicationsMerged: Int = 0,
        mutedItemsImported: Int = 0,
        dismissedPapersImported: Int = 0,
        errors: [MboxImportErrorInfo] = []
    ) {
        self.librariesCreated = librariesCreated
        self.librariesMerged = librariesMerged
        self.collectionsCreated = collectionsCreated
        self.smartSearchesCreated = smartSearchesCreated
        self.publicationsImported = publicationsImported
        self.publicationsSkipped = publicationsSkipped
        self.publicationsMerged = publicationsMerged
        self.mutedItemsImported = mutedItemsImported
        self.dismissedPapersImported = dismissedPapersImported
        self.errors = errors
    }

    /// Whether the import had any errors
    public var hasErrors: Bool {
        !errors.isEmpty
    }

    /// Summary description of the import result
    public var summary: String {
        var parts: [String] = []

        if librariesCreated > 0 {
            parts.append("\(librariesCreated) librar\(librariesCreated == 1 ? "y" : "ies") created")
        }
        if librariesMerged > 0 {
            parts.append("\(librariesMerged) librar\(librariesMerged == 1 ? "y" : "ies") merged")
        }
        if publicationsImported > 0 {
            parts.append("\(publicationsImported) publication\(publicationsImported == 1 ? "" : "s") imported")
        }
        if publicationsMerged > 0 {
            parts.append("\(publicationsMerged) merged")
        }
        if publicationsSkipped > 0 {
            parts.append("\(publicationsSkipped) skipped")
        }
        if errors.count > 0 {
            parts.append("\(errors.count) error\(errors.count == 1 ? "" : "s")")
        }

        return parts.joined(separator: ", ")
    }
}

// MARK: - Everything Export Options

/// Options for Everything mbox export.
public struct EverythingExportOptions: Sendable {
    /// Whether to include file attachments (PDFs)
    public let includeFiles: Bool

    /// Whether to include BibTeX attachment for each publication
    public let includeBibTeX: Bool

    /// Maximum file size to include (nil = no limit)
    public let maxFileSize: Int?

    /// Whether to include the Exploration library (device-specific, usually skipped)
    public let includeExploration: Bool

    /// Whether to include triage history (read/starred status, dismissed papers)
    public let includeTriageHistory: Bool

    /// Whether to include muted items
    public let includeMutedItems: Bool

    public init(
        includeFiles: Bool = true,
        includeBibTeX: Bool = true,
        maxFileSize: Int? = nil,
        includeExploration: Bool = false,
        includeTriageHistory: Bool = true,
        includeMutedItems: Bool = true
    ) {
        self.includeFiles = includeFiles
        self.includeBibTeX = includeBibTeX
        self.maxFileSize = maxFileSize
        self.includeExploration = includeExploration
        self.includeTriageHistory = includeTriageHistory
        self.includeMutedItems = includeMutedItems
    }

    public static let `default` = EverythingExportOptions()
}

// MARK: - Everything Import Options

/// Options for Everything mbox import.
public struct EverythingImportOptions: Sendable {
    /// How to handle duplicate publications
    public let duplicateHandling: MboxImportOptions.DuplicateHandling

    /// Whether to import files
    public let importFiles: Bool

    /// Whether to preserve original UUIDs
    public let preserveUUIDs: Bool

    /// Whether to import triage state (read, starred)
    public let importTriageState: Bool

    /// Whether to import muted items
    public let importMutedItems: Bool

    /// Whether to import dismissed papers
    public let importDismissedPapers: Bool

    /// How to resolve library conflicts by ID
    public let libraryConflictResolutions: [UUID: LibraryConflictResolution]

    public init(
        duplicateHandling: MboxImportOptions.DuplicateHandling = .skip,
        importFiles: Bool = true,
        preserveUUIDs: Bool = true,
        importTriageState: Bool = true,
        importMutedItems: Bool = true,
        importDismissedPapers: Bool = true,
        libraryConflictResolutions: [UUID: LibraryConflictResolution] = [:]
    ) {
        self.duplicateHandling = duplicateHandling
        self.importFiles = importFiles
        self.preserveUUIDs = preserveUUIDs
        self.importTriageState = importTriageState
        self.importMutedItems = importMutedItems
        self.importDismissedPapers = importDismissedPapers
        self.libraryConflictResolutions = libraryConflictResolutions
    }

    public static let `default` = EverythingImportOptions()
}

// MARK: - Export Version

/// Version of the mbox export format.
public enum ExportVersion: String, Sendable {
    case singleLibrary = "1.0"   // Original single-library format
    case everything = "2.0"       // Everything export format
    case unknown = "unknown"
}
