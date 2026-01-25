//
//  LocalPaper.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import Foundation
import CoreData

// MARK: - Local Paper

/// A paper from a local library (.bib file backed by Core Data).
///
/// This is a Sendable snapshot of a CDPublication, capturing all the
/// relevant data for display and export. Changes are written back
/// through the repository.
public struct LocalPaper: PaperRepresentable, Hashable {

    // MARK: - Identity

    public let id: String
    public let uuid: UUID
    public let libraryID: UUID

    // MARK: - Bibliographic Data

    public let citeKey: String
    public let entryType: String
    public let title: String
    public let authors: [String]
    public let year: Int?
    public let venue: String?
    public let abstract: String?

    // MARK: - Identifiers

    public let doi: String?
    public let arxivID: String?
    public let pmid: String?
    public let bibcode: String?

    // MARK: - Files

    public let linkedFilePaths: [String]
    public let primaryPDFPath: String?

    /// PDF links stored in bdsk-url-* fields (BibDesk compatible)
    public let pdfLinks: [PDFLink]

    // MARK: - Metadata

    public let tagNames: [String]
    public let collectionNames: [String]
    public let notes: String?
    public let dateAdded: Date
    public let dateModified: Date

    // MARK: - Raw Data

    public let rawBibTeX: String?
    public let rawFields: [String: String]

    // MARK: - Source Type

    public var sourceType: PaperSourceType {
        .local(libraryID: libraryID)
    }

    // MARK: - Initialization

    /// Create from a CDPublication snapshot
    ///
    /// Call this on the managed object context's queue to safely
    /// extract all data from the Core Data object.
    /// Returns nil if the publication has been deleted.
    public init?(publication: CDPublication, libraryID: UUID) {
        // Guard against deleted Core Data objects
        guard !publication.isDeleted && publication.managedObjectContext != nil else {
            return nil
        }

        self.id = publication.id.uuidString
        self.uuid = publication.id
        self.libraryID = libraryID

        self.citeKey = publication.citeKey
        self.entryType = publication.entryType
        self.title = publication.title ?? "Untitled"

        // Extract authors
        let sortedAuthors = publication.sortedAuthors
        if !sortedAuthors.isEmpty {
            self.authors = sortedAuthors.map { $0.displayName }
        } else if let authorField = publication.fields["author"] {
            // Parse from raw field
            self.authors = authorField
                .components(separatedBy: " and ")
                .map { BibTeXFieldCleaner.cleanAuthorName($0) }
        } else {
            self.authors = []
        }

        self.year = publication.year > 0 ? Int(publication.year) : nil

        // Extract venue (journal, booktitle, etc.)
        let fields = publication.fields
        self.venue = fields["journal"] ?? fields["booktitle"] ?? fields["publisher"]

        self.abstract = publication.abstract

        // Identifiers (using centralized IdentifierExtractor)
        self.doi = publication.doi ?? IdentifierExtractor.doi(from: fields)
        self.arxivID = IdentifierExtractor.arxivID(from: fields)
        self.pmid = IdentifierExtractor.pmid(from: fields)
        self.bibcode = IdentifierExtractor.bibcode(from: fields)

        // Files
        let files = publication.linkedFiles ?? []
        self.linkedFilePaths = files.map { $0.relativePath }
        self.primaryPDFPath = files.first { $0.isPDF }?.relativePath

        // Parse bdsk-url-* fields for PDF links
        var links: [PDFLink] = []
        for (key, value) in fields {
            if key.lowercased().hasPrefix("bdsk-url-"),
               let numStr = key.split(separator: "-").last,
               let num = Int(numStr),
               let type = PDFLinkType(bdskUrlNumber: num),
               let url = URL(string: value) {
                links.append(PDFLink(url: url, type: type))
            }
        }
        self.pdfLinks = links

        // Metadata
        self.tagNames = (publication.tags ?? []).map { $0.name }
        self.collectionNames = (publication.collections ?? []).map { $0.name }
        self.notes = fields["annote"] ?? fields["note"]
        self.dateAdded = publication.dateAdded
        self.dateModified = publication.dateModified

        // Raw data
        self.rawBibTeX = publication.rawBibTeX
        self.rawFields = fields
    }

    // MARK: - PaperRepresentable

    public var hasPDF: Bool {
        primaryPDFPath != nil || !pdfLinks.isEmpty
    }

    public func pdfURL() async -> URL? {
        guard let pdfPath = primaryPDFPath else { return nil }
        // TODO: Resolve relative path against library base URL
        // For now, return nil - this will be implemented with LibraryManager
        return nil
    }

    public func bibtex() async throws -> String {
        if let raw = rawBibTeX {
            return raw
        }
        // Generate from fields
        let entry = BibTeXEntry(
            citeKey: citeKey,
            entryType: entryType,
            fields: rawFields
        )
        let exporter = BibTeXExporter()
        return exporter.export(entry)
    }

    // MARK: - Hashable

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: LocalPaper, rhs: LocalPaper) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Batch Creation

public extension LocalPaper {
    /// Create LocalPaper array from CDPublication array on the main context
    /// Filters out any deleted publications that return nil
    @MainActor
    static func from(publications: [CDPublication], libraryID: UUID) -> [LocalPaper] {
        publications.compactMap { LocalPaper(publication: $0, libraryID: libraryID) }
    }
}
