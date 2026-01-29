//
//  PublicationRowData.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-05.
//

import Foundation

/// Immutable value-type snapshot of publication data for safe list rendering.
///
/// This struct captures all data needed to display a publication row at creation time.
/// Unlike passing `CDPublication` directly (which can crash if the object is deleted
/// during SwiftUI re-render), `PublicationRowData` is immune to Core Data lifecycle issues.
///
/// ## Why This Exists
///
/// When using `@ObservedObject CDPublication` in row views:
/// 1. User deletes publications
/// 2. Core Data marks objects as deleted
/// 3. SwiftUI re-renders the List
/// 4. `@ObservedObject` setup triggers property access on deleted objects
/// 5. **CRASH** - before any guard in `body` can run
///
/// By converting to value types upfront, we eliminate this race condition entirely.
public struct PublicationRowData: Identifiable, Hashable, Sendable {

    // MARK: - Core Identity

    /// Unique identifier (matches CDPublication.id)
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

    /// Whether a PDF is downloaded locally (or available in iCloud on iOS)
    /// Shows paperclip icon in list view
    public let hasDownloadedPDF: Bool

    /// Whether there are non-PDF attachments (images, data files, etc.)
    /// Shows document icon in list view
    public let hasOtherAttachments: Bool

    /// Whether a PDF is available (local or can be downloaded from arXiv/ADS)
    /// Used for "Open PDF" context menu option
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

    // MARK: - Library Context (for grouped search results)

    /// Name of the library this publication belongs to (for grouping in search results)
    /// When nil, the publication is shown ungrouped or in the "Current" section
    public let libraryName: String?

    // MARK: - Initialization

    /// Create a snapshot from a CDPublication.
    ///
    /// - Parameters:
    ///   - publication: The Core Data publication to snapshot
    ///   - libraryName: Optional library name for grouping in search results
    /// - Returns: nil if the publication has been deleted or is invalid
    public init?(publication: CDPublication, libraryName: String? = nil) {
        // Guard against deleted Core Data objects
        guard !publication.isDeleted,
              publication.managedObjectContext != nil else {
            return nil
        }

        // OPTIMIZATION: Decode fields ONCE instead of on every access
        // publication.fields decodes JSON from rawFields each time it's called.
        // For 2000 publications with 5+ field accesses each = 10,000+ JSON decodes!
        let fields = publication.fields

        self.id = publication.id
        self.citeKey = publication.citeKey
        self.title = publication.title ?? "Untitled"
        self.authorString = Self.formatAuthorString(from: publication, fields: fields)
        self.year = publication.year > 0 ? Int(publication.year) : Self.parseYearFromFields(fields)
        self.abstract = publication.abstract
        self.isRead = publication.isRead
        self.isStarred = publication.isStarred
        let attachmentStatus = Self.checkAttachments(publication)
        self.hasDownloadedPDF = attachmentStatus.hasDownloadedPDF
        self.hasOtherAttachments = attachmentStatus.hasOtherAttachments
        self.citationCount = Int(publication.citationCount)
        self.referenceCount = Int(publication.referenceCount)
        self.doi = publication.doi
        self.arxivID = publication.arxivID
        self.bibcode = publication.bibcode
        self.venue = Self.extractVenue(from: fields)
        self.note = fields["note"]
        self.dateAdded = publication.dateAdded
        self.dateModified = publication.dateModified
        self.primaryCategory = Self.extractPrimaryCategory(from: fields)
        self.categories = Self.extractCategories(from: fields)
        self.libraryName = libraryName
    }

    // MARK: - Venue Extraction

    /// Extract venue from publication fields based on entry type.
    ///
    /// Priority: journal > booktitle > series > publisher
    /// For articles: journal
    /// For conference papers: booktitle
    /// For books: publisher or series
    private static func extractVenue(from fields: [String: String]) -> String? {
        // Try journal first (for @article)
        if let journal = fields["journal"], !journal.isEmpty {
            return cleanVenue(journal)
        }

        // Try booktitle (for @inproceedings, @incollection)
        if let booktitle = fields["booktitle"], !booktitle.isEmpty {
            return cleanVenue(booktitle)
        }

        // Try series (for book series)
        if let series = fields["series"], !series.isEmpty {
            return cleanVenue(series)
        }

        // Try publisher as fallback (for @book, @proceedings)
        if let publisher = fields["publisher"], !publisher.isEmpty {
            return cleanVenue(publisher)
        }

        return nil
    }

    /// Clean venue string (remove braces, trim whitespace)
    private static func cleanVenue(_ venue: String) -> String {
        venue
            .replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Author Formatting

    /// Format author list for Mail-style display.
    ///
    /// - 1 author: "LastName"
    /// - 2 authors: "LastName1, LastName2"
    /// - 3 authors: "LastName1, LastName2, LastName3"
    /// - 4+ authors: "LastName1, LastName2 ... LastNameN"
    ///
    /// Performance: Checks raw BibTeX author field FIRST to avoid expensive
    /// Core Data relationship fetches. For 2000 publications, CDAuthor lookups
    /// would trigger thousands of relationship faults.
    private static func formatAuthorString(from publication: CDPublication, fields: [String: String]) -> String {
        // OPTIMIZATION: Check raw author field FIRST - this is O(1) dictionary lookup
        // Avoids expensive Core Data relationship fetches (sortedAuthors triggers N+1 queries)
        if let rawAuthor = fields["author"], !rawAuthor.isEmpty {
            let authors = rawAuthor.components(separatedBy: " and ")
                .map { BibTeXFieldCleaner.cleanAuthorName($0) }
                .filter { !$0.isEmpty }

            if !authors.isEmpty {
                return formatAuthorList(authors)
            }
        }

        // Fall back to CDAuthor entities only if raw field is missing
        // This path is rarely taken for imported BibTeX entries
        let sortedAuthors = publication.sortedAuthors
        if !sortedAuthors.isEmpty {
            let names = sortedAuthors.map { BibTeXFieldCleaner.cleanAuthorName($0.displayName) }
            return formatAuthorList(names)
        }

        return "Unknown Author"
    }

    private static func formatAuthorList(_ authors: [String]) -> String {
        guard !authors.isEmpty else {
            return "Unknown Author"
        }

        let lastNames = authors.map { extractLastName(from: $0) }

        switch lastNames.count {
        case 1:
            return lastNames[0]
        case 2:
            return "\(lastNames[0]), \(lastNames[1])"
        case 3:
            return "\(lastNames[0]), \(lastNames[1]), \(lastNames[2])"
        default:
            // 4+ authors: first two ... last
            return "\(lastNames[0]), \(lastNames[1]) ... \(lastNames[lastNames.count - 1])"
        }
    }

    private static func extractLastName(from author: String) -> String {
        let trimmed = author.trimmingCharacters(in: .whitespaces)

        if trimmed.contains(",") {
            // "Last, First" format
            return trimmed.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? trimmed
        } else {
            // "First Last" format - get the last word
            let parts = trimmed.components(separatedBy: " ").filter { !$0.isEmpty }
            return parts.last ?? trimmed
        }
    }

    // MARK: - Year Parsing

    private static func parseYearFromFields(_ fields: [String: String]) -> Int? {
        guard let yearStr = fields["year"], let parsed = Int(yearStr) else {
            return nil
        }
        return parsed > 0 ? parsed : nil
    }

    // MARK: - Attachment Check

    /// Check for downloaded PDFs and other attachments.
    ///
    /// Returns:
    /// - `hasDownloadedPDF`: True if there's a locally downloaded PDF file,
    ///   or if the PDF data is available via CloudKit sync (fileData exists).
    /// - `hasOtherAttachments`: True if there are non-PDF attachments.
    ///
    /// Note: Remote PDF links (arXiv, ADS, etc.) are NOT counted - only actual files.
    private static func checkAttachments(_ publication: CDPublication) -> (hasDownloadedPDF: Bool, hasOtherAttachments: Bool) {
        guard let linkedFiles = publication.linkedFiles, !linkedFiles.isEmpty else {
            return (false, false)
        }

        var hasDownloadedPDF = false
        var hasOtherAttachments = false

        for file in linkedFiles {
            if file.isPDF {
                // Check if this PDF is actually downloaded (or synced via CloudKit)
                // fileData means it's available from CloudKit even if local file is missing
                // linkedFile record without fileData means PDF exists locally
                if file.fileData != nil {
                    hasDownloadedPDF = true
                } else {
                    // Trust that linkedFile record means PDF exists locally
                    hasDownloadedPDF = true
                }
            } else {
                hasOtherAttachments = true
            }
        }

        return (hasDownloadedPDF, hasOtherAttachments)
    }

    // MARK: - Category Extraction

    /// Extract primary arXiv category from BibTeX fields.
    ///
    /// Looks for `primaryclass` field (standard arXiv BibTeX convention).
    private static func extractPrimaryCategory(from fields: [String: String]) -> String? {
        fields["primaryclass"]
    }

    /// Extract all arXiv categories from BibTeX fields.
    ///
    /// Returns the primary category plus any cross-listed categories from `categories` field.
    private static func extractCategories(from fields: [String: String]) -> [String] {
        var result: [String] = []

        // Add primary category first
        if let primary = fields["primaryclass"], !primary.isEmpty {
            result.append(primary)
        }

        // Add additional categories from categories field (comma-separated)
        if let categoriesField = fields["categories"] {
            let additional = categoriesField
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !result.contains($0) }
            result.append(contentsOf: additional)
        }

        return result
    }
}

// MARK: - Batch Conversion

extension PublicationRowData {

    /// Convert an array of CDPublications to row data, filtering out deleted objects.
    ///
    /// - Parameters:
    ///   - publications: The publications to convert
    ///   - libraryName: Optional library name to assign to all converted publications
    /// - Returns: Array of valid row data (deleted publications are excluded)
    public static func from(_ publications: [CDPublication], libraryName: String? = nil) -> [PublicationRowData] {
        publications.compactMap { PublicationRowData(publication: $0, libraryName: libraryName) }
    }
}
