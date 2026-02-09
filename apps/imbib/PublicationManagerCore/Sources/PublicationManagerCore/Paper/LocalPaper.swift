//
//  LocalPaper.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import Foundation

// MARK: - Local Paper

/// A paper from a local library (.bib file backed by the Rust store).
///
/// This is a Sendable snapshot of a publication, capturing all the
/// relevant data for display and export. Changes are written back
/// through RustStoreAdapter.
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

    // MARK: - Init from PublicationModel (Rust store)

    /// Create from a PublicationModel (domain type from Rust store).
    public init(from model: PublicationModel) {
        self.id = model.id.uuidString
        self.uuid = model.id
        self.libraryID = model.libraryIDs.first ?? UUID()

        self.citeKey = model.citeKey
        self.entryType = model.entryType
        self.title = model.title

        self.authors = model.authors.map(\.displayName)
        self.year = model.year

        self.venue = model.journal ?? model.booktitle ?? model.publisher
        self.abstract = model.abstract

        self.doi = model.doi
        self.arxivID = model.arxivID
        self.pmid = model.pmid
        self.bibcode = model.bibcode

        // Files — extract from linked files
        self.linkedFilePaths = model.linkedFiles.compactMap(\.relativePath)
        self.primaryPDFPath = model.linkedFiles.first { $0.isPDF }?.relativePath

        // Parse bdsk-url-* fields for PDF links
        var links: [PDFLink] = []
        for (key, value) in model.fields {
            if key.lowercased().hasPrefix("bdsk-url-"),
               let numStr = key.split(separator: "-").last,
               let num = Int(numStr),
               let type = PDFLinkType(bdskUrlNumber: num),
               let url = URL(string: value) {
                links.append(PDFLink(url: url, type: type))
            }
        }
        self.pdfLinks = links

        self.tagNames = model.tags.map(\.leaf)
        self.collectionNames = []
        self.notes = model.note
        self.dateAdded = model.dateAdded
        self.dateModified = model.dateModified

        self.rawBibTeX = model.rawBibTeX
        self.rawFields = model.fields
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
    /// Create LocalPaper array from PublicationModel array.
    static func from(models: [PublicationModel]) -> [LocalPaper] {
        models.map { LocalPaper(from: $0) }
    }
}
