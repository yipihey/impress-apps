//
//  PublicationRowData.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-05.
//

import Foundation
import ImpressFTUI
import OSLog

/// Immutable value-type snapshot of publication data for safe list rendering.
///
/// This struct captures all data needed to display a publication row at creation time.
/// Created from Rust `BibliographyRow` via `RustStoreAdapter`.
public struct PublicationRowData: Identifiable, Hashable, Sendable {

    // MARK: - Core Identity

    /// Unique identifier
    public let id: UUID

    /// BibTeX cite key
    public let citeKey: String

    // MARK: - Display Data

    /// Publication title
    public let title: String

    /// Pre-formatted author string for display (e.g., "Einstein, Bohr ... Feynman")
    public let authorString: String

    /// Publication year (nil if not available)
    public let year: Int?

    /// Abstract text (nil if not available)
    public let abstract: String?

    /// Whether the publication has been read
    public let isRead: Bool

    /// Whether the publication is starred/flagged
    public let isStarred: Bool

    /// Rich flag state (color, style, length) — nil if unflagged
    public let flag: PublicationFlag?

    /// Whether a PDF is downloaded locally
    public let hasDownloadedPDF: Bool

    /// Whether there are non-PDF attachments
    public let hasOtherAttachments: Bool

    /// Whether a PDF is available (local or can be downloaded from arXiv/ADS)
    public var hasPDFAvailable: Bool {
        hasDownloadedPDF || arxivID != nil
    }

    /// Citation count from online sources
    public let citationCount: Int

    /// Reference count from online sources
    public let referenceCount: Int

    /// DOI for context menu "Copy DOI" action
    public let doi: String?

    /// arXiv ID for "Open in Browser" context menu
    public let arxivID: String?

    /// ADS bibcode for "Open in Browser" context menu
    public let bibcode: String?

    /// Venue (journal, booktitle, or publisher) for display
    public let venue: String?

    /// Notes/annotations for this publication (searchable)
    public let note: String?

    /// Date added to library (for sorting)
    public let dateAdded: Date

    /// Date last modified (for sorting)
    public let dateModified: Date

    // MARK: - arXiv Categories

    /// Primary arXiv category (e.g., "cs.LG", "astro-ph.GA")
    public let primaryCategory: String?

    /// All arXiv categories (includes cross-listed)
    public let categories: [String]

    // MARK: - Tags

    /// Tag display data for rendering in the list row
    public let tagDisplays: [TagDisplayData]

    // MARK: - Library Context (for grouped search results)

    /// Name of the library this publication belongs to (for grouping in search results)
    public let libraryName: String?

    // MARK: - Memberwise Init

    /// Direct memberwise initializer for creating PublicationRowData from any source.
    public init(
        id: UUID,
        citeKey: String = "",
        title: String = "Untitled",
        authorString: String = "Unknown Author",
        year: Int? = nil,
        abstract: String? = nil,
        isRead: Bool = false,
        isStarred: Bool = false,
        flag: PublicationFlag? = nil,
        hasDownloadedPDF: Bool = false,
        hasOtherAttachments: Bool = false,
        citationCount: Int = 0,
        referenceCount: Int = 0,
        doi: String? = nil,
        arxivID: String? = nil,
        bibcode: String? = nil,
        venue: String? = nil,
        note: String? = nil,
        dateAdded: Date = Date(),
        dateModified: Date = Date(),
        primaryCategory: String? = nil,
        categories: [String] = [],
        tagDisplays: [TagDisplayData] = [],
        libraryName: String? = nil
    ) {
        self.id = id
        self.citeKey = citeKey
        self.title = title
        self.authorString = authorString
        self.year = year
        self.abstract = abstract
        self.isRead = isRead
        self.isStarred = isStarred
        self.flag = flag
        self.hasDownloadedPDF = hasDownloadedPDF
        self.hasOtherAttachments = hasOtherAttachments
        self.citationCount = citationCount
        self.referenceCount = referenceCount
        self.doi = doi
        self.arxivID = arxivID
        self.bibcode = bibcode
        self.venue = venue
        self.note = note
        self.dateAdded = dateAdded
        self.dateModified = dateModified
        self.primaryCategory = primaryCategory
        self.categories = categories
        self.tagDisplays = tagDisplays
        self.libraryName = libraryName
    }
}
