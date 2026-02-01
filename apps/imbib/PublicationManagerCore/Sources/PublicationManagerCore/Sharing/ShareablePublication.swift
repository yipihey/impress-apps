//
//  ShareablePublication.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-29.
//

import Foundation
import CoreData

// MARK: - Shareable Publication

/// Sendable snapshot of publication data for sharing via AirDrop, Messages, etc.
///
/// This is a lightweight, Codable struct that captures all data needed for
/// sharing a publication. It can be initialized from a CDPublication or
/// any PaperRepresentable, and supports multiple export formats via Transferable.
public struct ShareablePublication: Codable, Sendable, Identifiable {

    // MARK: - Identity

    public let id: UUID
    public let citeKey: String

    // MARK: - Bibliographic Data

    public let title: String
    public let authors: [String]
    public let year: Int?
    public let venue: String?
    public let abstract: String?
    public let entryType: String

    // MARK: - Identifiers

    public let doi: String?
    public let arxivID: String?
    public let bibcode: String?
    public let pmid: String?

    // MARK: - BibTeX

    public let rawBibTeX: String?
    public let fields: [String: String]

    // MARK: - PDF Data

    /// Optional embedded PDF data for sharing
    public let pdfData: Data?

    /// Original PDF filename (if available)
    public let pdfFilename: String?

    // MARK: - Initialization

    /// Create from a CDPublication.
    ///
    /// - Parameters:
    ///   - publication: The Core Data publication to snapshot
    ///   - includePDF: Whether to include embedded PDF data (increases size significantly)
    ///   - pdfData: Optional pre-loaded PDF data (avoids re-reading from disk)
    @MainActor
    public init(from publication: CDPublication, includePDF: Bool = false, pdfData: Data? = nil) {
        self.id = publication.id
        self.citeKey = publication.citeKey

        self.title = publication.title ?? "Untitled"
        self.authors = publication.sortedAuthors.map { $0.displayName }
        self.year = publication.year > 0 ? Int(publication.year) : nil

        let fields = publication.fields
        self.venue = fields["journal"] ?? fields["booktitle"] ?? fields["publisher"]
        self.abstract = publication.abstract
        self.entryType = publication.entryType

        self.doi = publication.doi
        self.arxivID = publication.arxivID
        self.bibcode = publication.bibcode
        self.pmid = publication.pmid

        self.rawBibTeX = publication.rawBibTeX
        self.fields = fields

        // PDF handling
        if includePDF {
            self.pdfData = pdfData
            self.pdfFilename = publication.linkedFiles?.first { $0.isPDF }?.filename
        } else {
            self.pdfData = nil
            self.pdfFilename = nil
        }
    }

    /// Create from any PaperRepresentable.
    public init(from paper: any PaperRepresentable) {
        self.id = UUID()

        // Generate cite key
        let lastNamePart = paper.authors.first?
            .components(separatedBy: ",").first?
            .components(separatedBy: " ").last?
            .filter { $0.isLetter } ?? "Unknown"
        let yearPart = paper.year.map { String($0) } ?? ""
        let titleWord = paper.title
            .components(separatedBy: .whitespaces)
            .first { $0.count > 3 }?
            .filter { $0.isLetter }
            .capitalized ?? ""
        self.citeKey = "\(lastNamePart)\(yearPart)\(titleWord)"

        self.title = paper.title
        self.authors = paper.authors
        self.year = paper.year
        self.venue = paper.venue
        self.abstract = paper.abstract
        self.entryType = "article"

        self.doi = paper.doi
        self.arxivID = paper.arxivID
        self.bibcode = paper.bibcode
        self.pmid = paper.pmid

        self.rawBibTeX = nil

        // Build fields dictionary
        var fields: [String: String] = [:]
        fields["title"] = paper.title
        if !paper.authors.isEmpty {
            fields["author"] = paper.authors.joined(separator: " and ")
        }
        if let year = paper.year {
            fields["year"] = String(year)
        }
        if let venue = paper.venue {
            fields["journal"] = venue
        }
        if let abstract = paper.abstract {
            fields["abstract"] = abstract
        }
        if let doi = paper.doi {
            fields["doi"] = doi
        }
        if let arxivID = paper.arxivID {
            fields["eprint"] = arxivID
            fields["archiveprefix"] = "arXiv"
        }
        self.fields = fields

        self.pdfData = nil
        self.pdfFilename = nil
    }

    /// Create directly with all values.
    public init(
        id: UUID = UUID(),
        citeKey: String,
        title: String,
        authors: [String],
        year: Int?,
        venue: String? = nil,
        abstract: String? = nil,
        entryType: String = "article",
        doi: String? = nil,
        arxivID: String? = nil,
        bibcode: String? = nil,
        pmid: String? = nil,
        rawBibTeX: String? = nil,
        fields: [String: String] = [:],
        pdfData: Data? = nil,
        pdfFilename: String? = nil
    ) {
        self.id = id
        self.citeKey = citeKey
        self.title = title
        self.authors = authors
        self.year = year
        self.venue = venue
        self.abstract = abstract
        self.entryType = entryType
        self.doi = doi
        self.arxivID = arxivID
        self.bibcode = bibcode
        self.pmid = pmid
        self.rawBibTeX = rawBibTeX
        self.fields = fields
        self.pdfData = pdfData
        self.pdfFilename = pdfFilename
    }

    // MARK: - Computed Properties

    /// Formatted citation string for plain text sharing.
    ///
    /// Format: "Author1, Author2 (Year). Title. DOI: doi"
    public var formattedCitation: String {
        var parts: [String] = []

        // Authors
        if !authors.isEmpty {
            if authors.count == 1 {
                parts.append(authors[0])
            } else if authors.count == 2 {
                parts.append("\(authors[0]) and \(authors[1])")
            } else {
                parts.append("\(authors[0]) et al.")
            }
        }

        // Year
        if let year = year {
            parts.append("(\(year))")
        }

        // Title
        parts.append(title + ".")

        // Venue
        if let venue = venue {
            parts.append(venue + ".")
        }

        // Identifier
        if let doi = doi {
            parts.append("https://doi.org/\(doi)")
        } else if let arxivID = arxivID {
            parts.append("https://arxiv.org/abs/\(arxivID)")
        }

        return parts.joined(separator: " ")
    }

    /// Primary URL for this publication (DOI or arXiv link).
    public var primaryURL: URL? {
        if let doi = doi {
            return URL(string: "https://doi.org/\(doi)")
        }
        if let arxivID = arxivID {
            return URL(string: "https://arxiv.org/abs/\(arxivID)")
        }
        if let bibcode = bibcode {
            return URL(string: "https://ui.adsabs.harvard.edu/abs/\(bibcode)")
        }
        return nil
    }

    /// Generate BibTeX string for this publication.
    public var bibtex: String {
        if let raw = rawBibTeX {
            return raw
        }

        // Generate from fields
        let entry = BibTeXEntry(
            citeKey: citeKey,
            entryType: entryType,
            fields: fields
        )
        let exporter = BibTeXExporter()
        return exporter.export(entry)
    }

    /// Suggested filename for BibTeX export.
    public var suggestedBibFilename: String {
        "\(citeKey).bib"
    }

    /// Suggested filename for PDF export.
    public var suggestedPDFFilename: String {
        if let filename = pdfFilename {
            return filename
        }

        // Generate from metadata: Author_Year_Title.pdf
        var parts: [String] = []

        if let firstAuthor = authors.first {
            let lastName = firstAuthor
                .components(separatedBy: ",").first?
                .components(separatedBy: " ").last ?? firstAuthor
            parts.append(lastName.filter { $0.isLetter })
        }

        if let year = year {
            parts.append(String(year))
        }

        let titlePart = title
            .components(separatedBy: .whitespaces)
            .prefix(3)
            .joined(separator: "_")
            .filter { $0.isLetter || $0 == "_" }
        if !titlePart.isEmpty {
            parts.append(titlePart)
        }

        let name = parts.isEmpty ? citeKey : parts.joined(separator: "_")
        return "\(name).pdf"
    }
}

// MARK: - Shareable Publications Container

/// Container for multiple publications, used for library sharing.
public struct ShareablePublications: Codable, Sendable {

    /// The publications to share
    public let publications: [ShareablePublication]

    /// Optional library name (for context)
    public let libraryName: String?

    /// When the export was created
    public let exportDate: Date

    /// Export format version
    public let version: String

    // MARK: - Initialization

    public init(
        publications: [ShareablePublication],
        libraryName: String? = nil,
        exportDate: Date = Date(),
        version: String = "1.0"
    ) {
        self.publications = publications
        self.libraryName = libraryName
        self.exportDate = exportDate
        self.version = version
    }

    /// Create from a library.
    @MainActor
    public init(
        from library: CDLibrary,
        includePDFs: Bool = false,
        pdfDataProvider: ((CDPublication) async -> Data?)? = nil
    ) async {
        let pubs = library.publications ?? []
        var shareablePubs: [ShareablePublication] = []

        for pub in pubs where !pub.isDeleted {
            let pdfData: Data?
            if includePDFs, let provider = pdfDataProvider {
                pdfData = await provider(pub)
            } else {
                pdfData = nil
            }
            shareablePubs.append(ShareablePublication(from: pub, includePDF: includePDFs, pdfData: pdfData))
        }

        self.publications = shareablePubs
        self.libraryName = library.displayName
        self.exportDate = Date()
        self.version = "1.0"
    }

    // MARK: - Computed Properties

    /// Combined BibTeX for all publications.
    public var combinedBibTeX: String {
        publications.map { $0.bibtex }.joined(separator: "\n\n")
    }

    /// Total count of publications.
    public var count: Int {
        publications.count
    }

    /// Whether any publication has PDF data.
    public var hasPDFData: Bool {
        publications.contains { $0.pdfData != nil }
    }

    /// Suggested filename for combined BibTeX export.
    public var suggestedBibFilename: String {
        if let name = libraryName {
            let cleaned = name.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
            return "\(cleaned).bib"
        }
        return "Papers.bib"
    }
}

// MARK: - Equatable

extension ShareablePublication: Equatable {
    public static func == (lhs: ShareablePublication, rhs: ShareablePublication) -> Bool {
        lhs.id == rhs.id
    }
}

extension ShareablePublications: Equatable {
    public static func == (lhs: ShareablePublications, rhs: ShareablePublications) -> Bool {
        lhs.publications.map { $0.id } == rhs.publications.map { $0.id } &&
        lhs.libraryName == rhs.libraryName
    }
}

// MARK: - Hashable

extension ShareablePublication: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

extension ShareablePublications: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(publications.map { $0.id })
        hasher.combine(libraryName)
    }
}
