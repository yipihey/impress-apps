//
//  ManagedObjects.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import Foundation
import CoreData

#if os(iOS)
import UIKit
#endif

// MARK: - Publication

@objc(CDPublication)
public class CDPublication: NSManagedObject {
    @NSManaged public var id: UUID
    @NSManaged public var citeKey: String
    @NSManaged public var entryType: String
    @NSManaged public var title: String?
    @NSManaged public var year: Int16
    @NSManaged public var abstract: String?
    @NSManaged public var doi: String?
    @NSManaged public var url: String?
    @NSManaged public var rawBibTeX: String?
    @NSManaged public var rawFields: String?
    @NSManaged public var fieldTimestamps: String?
    @NSManaged public var dateAdded: Date
    @NSManaged public var dateModified: Date

    // Enrichment fields (ADR-014)
    @NSManaged public var citationCount: Int32        // -1 = never enriched
    @NSManaged public var referenceCount: Int32       // -1 = never enriched
    @NSManaged public var enrichmentSource: String?   // Which source provided data
    @NSManaged public var enrichmentDate: Date?       // When last enriched

    // Online source metadata (ADR-016: Unified Paper Model)
    @NSManaged public var originalSourceID: String?   // Which API source found this ("arxiv", "crossref", etc.)
    @NSManaged public var pdfLinksJSON: String?       // Stored [PDFLink] array as JSON
    @NSManaged public var webURL: String?             // Link to source page

    // PDF download state (ADR-016)
    @NSManaged public var hasPDFDownloaded: Bool      // PDF exists in library folder
    @NSManaged public var pdfDownloadDate: Date?      // When PDF was downloaded

    // Extended identifiers for deduplication (ADR-016)
    @NSManaged public var semanticScholarID: String?
    @NSManaged public var openAlexID: String?

    // Normalized arXiv ID for O(1) indexed lookups
    // Set automatically when fields change via updateArxivIDNormalized()
    @NSManaged public var arxivIDNormalized: String?

    // Normalized bibcode for O(1) indexed lookups
    // Set automatically when fields change via updateBibcodeNormalized()
    @NSManaged public var bibcodeNormalized: String?

    // Read status (Apple Mail styling)
    @NSManaged public var isRead: Bool
    @NSManaged public var dateRead: Date?

    // Star/flag status (Inbox triage)
    @NSManaged public var isStarred: Bool

    // Inbox tracking
    @NSManaged public var dateAddedToInbox: Date?  // When paper was added to Inbox (for age filtering)

    // Relationships
    @NSManaged public var publicationAuthors: Set<CDPublicationAuthor>?
    @NSManaged public var linkedFiles: Set<CDLinkedFile>?
    @NSManaged public var tags: Set<CDTag>?
    @NSManaged public var collections: Set<CDCollection>?
    @NSManaged public var libraries: Set<CDLibrary>?     // Publications can belong to multiple libraries
    @NSManaged public var scixLibraries: Set<CDSciXLibrary>?  // SciX online libraries containing this paper
    @NSManaged public var remarkableDocuments: Set<CDRemarkableDocument>?  // reMarkable sync documents (ADR-019)
}

// MARK: - Publication Helpers

public extension CDPublication {

    /// Get all fields as dictionary (decoded from rawFields JSON)
    var fields: [String: String] {
        get {
            guard let json = rawFields,
                  let data = json.data(using: .utf8),
                  let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
                return [:]
            }
            return dict
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
               let json = String(data: data, encoding: .utf8) {
                rawFields = json
                // Update indexed fields for O(1) lookups
                updateArxivIDNormalized(from: newValue)
                updateBibcodeNormalized(from: newValue)
            }
        }
    }

    /// Update the normalized arXiv ID from field values.
    /// Called automatically when `fields` is set.
    func updateArxivIDNormalized(from fields: [String: String]? = nil) {
        let fieldsToUse = fields ?? self.fields
        if let arxivID = IdentifierExtractor.arxivID(from: fieldsToUse) {
            arxivIDNormalized = IdentifierExtractor.normalizeArXivID(arxivID)
        } else {
            arxivIDNormalized = nil
        }
    }

    /// Update the normalized bibcode from field values.
    /// Called automatically when `fields` is set.
    func updateBibcodeNormalized(from fields: [String: String]? = nil) {
        let fieldsToUse = fields ?? self.fields
        if let bibcode = IdentifierExtractor.bibcode(from: fieldsToUse) {
            bibcodeNormalized = bibcode.uppercased()
        } else {
            bibcodeNormalized = nil
        }
    }

    /// Get authors sorted by order
    var sortedAuthors: [CDAuthor] {
        (publicationAuthors ?? [])
            .sorted { $0.order < $1.order }
            .compactMap { $0.author }
    }

    /// Authors (alias for sortedAuthors)
    var authors: [CDAuthor] {
        sortedAuthors
    }

    /// Add a linked file to this publication (Core Data relationship accessor)
    func addToLinkedFiles(_ file: CDLinkedFile) {
        if linkedFiles == nil {
            linkedFiles = []
        }
        linkedFiles?.insert(file)
        file.publication = self
    }

    /// Remove a linked file from this publication
    func removeFromLinkedFiles(_ file: CDLinkedFile) {
        linkedFiles?.remove(file)
        file.publication = nil
    }

    /// Author string for display
    var authorString: String {
        // Prefer CDAuthor entities if they exist
        let fromEntities = sortedAuthors.map { $0.displayName }.joined(separator: ", ")
        if !fromEntities.isEmpty {
            return fromEntities
        }

        // Fall back to parsed author field with braces stripped
        guard let rawAuthor = fields["author"] else { return "" }

        // Parse and clean author names (same logic as BibTeXEntry.authorList)
        return rawAuthor
            .components(separatedBy: " and ")
            .map { BibTeXFieldCleaner.cleanAuthorName($0) }
            .joined(separator: ", ")
    }

    /// Convert to BibTeXEntry
    func toBibTeXEntry() -> BibTeXEntry {
        var entryFields = fields

        // Add core fields
        if let title = title { entryFields["title"] = title }
        if year > 0 { entryFields["year"] = String(year) }
        if let abstract = abstract { entryFields["abstract"] = abstract }
        if let doi = doi { entryFields["doi"] = doi }
        if let url = url { entryFields["url"] = url }

        // Add author field
        if !sortedAuthors.isEmpty {
            entryFields["author"] = sortedAuthors.map { $0.bibtexName }.joined(separator: " and ")
        }

        // Add file references
        let files = (linkedFiles ?? []).map { $0.relativePath }
        if !files.isEmpty {
            BdskFileCodec.addFiles(Array(files), to: &entryFields)
        }

        return BibTeXEntry(
            citeKey: citeKey,
            entryType: entryType,
            fields: entryFields,
            rawBibTeX: rawBibTeX
        )
    }

    /// Update from BibTeXEntry
    func update(from entry: BibTeXEntry, context: NSManagedObjectContext) {
        citeKey = entry.citeKey
        entryType = entry.entryType
        rawBibTeX = entry.rawBibTeX

        // Extract and set core fields (use cleaned properties, not raw fields)
        title = entry.title
        if let yearStr = entry.fields["year"], let yearInt = Int16(yearStr) {
            year = yearInt
        }
        abstract = entry.fields["abstract"]
        doi = entry.fields["doi"]
        url = entry.fields["url"]

        // Store all fields
        fields = entry.fields

        dateModified = Date()
    }

    // MARK: - Enrichment Helpers

    /// Whether this publication has been enriched
    var hasBeenEnriched: Bool {
        citationCount >= 0
    }

    /// Whether the enrichment data is stale (older than the threshold)
    func isEnrichmentStale(thresholdDays: Int = 7) -> Bool {
        guard let date = enrichmentDate else { return true }
        let threshold = TimeInterval(thresholdDays * 24 * 60 * 60)
        return Date().timeIntervalSince(date) > threshold
    }

    /// Whether this publication needs enrichment (not enriched or stale)
    var needsEnrichment: Bool {
        !hasBeenEnriched || isEnrichmentStale(thresholdDays: 1)
    }

    /// Staleness level for UI display
    var enrichmentStaleness: EnrichmentStaleness {
        guard hasBeenEnriched, let date = enrichmentDate else {
            return .neverEnriched
        }

        let age = Date().timeIntervalSince(date)
        if age < 86400 { return .fresh }           // <1 day
        if age < 7 * 86400 { return .recent }      // 1-7 days
        if age < 30 * 86400 { return .stale }      // 7-30 days
        return .veryStale                           // >30 days
    }

    /// Update enrichment data
    func updateEnrichment(citationCount: Int, source: String) {
        self.citationCount = Int32(citationCount)
        self.enrichmentSource = source
        self.enrichmentDate = Date()
        self.dateModified = Date()
    }

    /// Clear enrichment data (mark as needing refresh)
    func clearEnrichment() {
        self.citationCount = -1
        self.enrichmentSource = nil
        self.enrichmentDate = nil
    }

    // MARK: - Exploration Availability

    /// Represents the availability of exploration data (references/citations)
    public enum ExplorationAvailability: Equatable, Sendable {
        case notEnriched      // Can try, unknown if data exists
        case hasResults(Int)  // Enriched, has this many results
        case noResults        // Enriched, confirmed zero results
        case unavailable      // Missing required identifiers
    }

    /// Check availability of references for this publication
    func referencesAvailability() -> ExplorationAvailability {
        guard doi != nil || arxivID != nil || bibcode != nil else { return .unavailable }
        if !hasBeenEnriched { return .notEnriched }
        if referenceCount > 0 { return .hasResults(Int(referenceCount)) }
        return .noResults
    }

    /// Check availability of citations for this publication
    func citationsAvailability() -> ExplorationAvailability {
        guard doi != nil || arxivID != nil || bibcode != nil else { return .unavailable }
        if !hasBeenEnriched { return .notEnriched }
        if citationCount > 0 { return .hasResults(Int(citationCount)) }
        return .noResults
    }

    // MARK: - PDF Links (ADR-016)

    /// Get PDF links as array (decoded from pdfLinksJSON)
    var pdfLinks: [PDFLink] {
        get {
            guard let json = pdfLinksJSON,
                  let data = json.data(using: .utf8),
                  let links = try? JSONDecoder().decode([PDFLink].self, from: data) else {
                return []
            }
            return links
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
               let json = String(data: data, encoding: .utf8) {
                pdfLinksJSON = json
            } else {
                pdfLinksJSON = nil
            }
        }
    }

    /// Add or update a PDF link, replacing any existing link from the same source
    func addPDFLink(_ link: PDFLink) {
        var links = pdfLinks
        // Remove existing link from same source to avoid duplicates
        links.removeAll { $0.sourceID == link.sourceID }
        links.append(link)
        pdfLinks = links
    }

    // MARK: - Library Management

    /// Add this publication to a library
    func addToLibrary(_ library: CDLibrary) {
        var currentLibraries = libraries ?? []
        currentLibraries.insert(library)
        libraries = currentLibraries
    }

    /// Remove this publication from a library
    func removeFromLibrary(_ library: CDLibrary) {
        var currentLibraries = libraries ?? []
        currentLibraries.remove(library)
        libraries = currentLibraries
    }

    /// Check if publication belongs to a specific library
    func belongsToLibrary(_ library: CDLibrary) -> Bool {
        libraries?.contains(library) ?? false
    }

    // MARK: - Collection Management

    /// Add this publication to a collection
    ///
    /// Also adds to the collection's owning library to ensure smart collections
    /// can find papers (they query `library.publications`, not collections).
    func addToCollection(_ collection: CDCollection) {
        var currentCollections = collections ?? []
        currentCollections.insert(collection)
        collections = currentCollections

        // Also add to owning library if collection has one
        if let library = collection.library {
            addToLibrary(library)
        }
    }

    /// Remove this publication from a collection
    func removeFromCollection(_ collection: CDCollection) {
        var currentCollections = collections ?? []
        currentCollections.remove(collection)
        collections = currentCollections
    }

    /// Remove this publication from all collections (returns to "All Publications")
    func removeFromAllCollections() {
        collections = []
    }

    /// Best remote PDF URL based on priority (preprint > publisher > author > adsScan)
    var bestRemotePDFURL: URL? {
        let priority: [PDFLinkType] = [.preprint, .publisher, .author, .adsScan]
        for type in priority {
            if let link = pdfLinks.first(where: { $0.type == type }) {
                return link.url
            }
        }
        return pdfLinks.first?.url
    }

    /// Whether this publication has any PDF available (local or remote)
    var hasPDFAvailable: Bool {
        hasPDFDownloaded || !pdfLinks.isEmpty || !(linkedFiles?.isEmpty ?? true)
    }

    /// Web URL as URL object
    var webURLObject: URL? {
        guard let urlString = webURL else { return nil }
        return URL(string: urlString)
    }

    // MARK: - Identifier Access (from BibTeX fields)
    //
    // These use centralized IdentifierExtractor for consistent field extraction
    // across the codebase. The extractor checks multiple field variants:
    // - arXiv: eprint → arxivid → arxiv
    // - bibcode: bibcode (or extracted from adsurl)
    // - pmid: pmid

    /// arXiv ID from BibTeX fields (checks eprint, arxivid, arxiv)
    var arxivID: String? {
        IdentifierExtractor.arxivID(from: fields)
    }

    /// ADS bibcode from BibTeX fields (checks bibcode or extracts from adsurl)
    var bibcode: String? {
        IdentifierExtractor.bibcode(from: fields)
    }

    /// PubMed ID from pmid field
    var pmid: String? {
        IdentifierExtractor.pmid(from: fields)
    }

    /// arXiv PDF URL (computed from arxivID)
    var arxivPDFURL: URL? {
        guard let arxivID = arxivID, !arxivID.isEmpty else { return nil }

        // Clean arXiv ID - remove version suffix for consistent URL
        let baseID = arxivID.replacingOccurrences(
            of: #"v\d+$"#, with: "", options: .regularExpression
        )

        // arXiv IDs can be in two formats:
        // - New: 2301.12345
        // - Old: hep-th/9901001
        return URL(string: "https://arxiv.org/pdf/\(baseID).pdf")
    }

}

// MARK: - Enrichment Staleness

/// Staleness levels for enrichment data
public enum EnrichmentStaleness: Sendable {
    case neverEnriched  // Never fetched
    case fresh          // <1 day old
    case recent         // 1-7 days old
    case stale          // 7-30 days old
    case veryStale      // >30 days old
}

// MARK: - Author

@objc(CDAuthor)
public class CDAuthor: NSManagedObject {
    @NSManaged public var id: UUID
    @NSManaged public var familyName: String
    @NSManaged public var givenName: String?
    @NSManaged public var nameSuffix: String?

    // Relationships
    @NSManaged public var publicationAuthors: Set<CDPublicationAuthor>?
}

// MARK: - Author Helpers

public extension CDAuthor {

    /// Display name (e.g., "Albert Einstein")
    var displayName: String {
        if let given = givenName {
            var name = "\(given) \(familyName)"
            if let suffix = nameSuffix {
                name += ", \(suffix)"
            }
            return name
        }
        return familyName
    }

    /// Formatted name for display (alias for displayName)
    var formattedName: String {
        displayName
    }

    /// BibTeX format (e.g., "Einstein, Albert")
    var bibtexName: String {
        if let given = givenName {
            var name = "\(familyName), \(given)"
            if let suffix = nameSuffix {
                name += ", \(suffix)"
            }
            return name
        }
        return familyName
    }

    /// Parse author string from BibTeX format
    static func parse(_ string: String) -> (familyName: String, givenName: String?, suffix: String?) {
        let trimmed = string.trimmingCharacters(in: .whitespaces)

        if trimmed.contains(",") {
            // "Last, First" or "Last, First, Jr."
            let parts = trimmed.components(separatedBy: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }

            let familyName = parts[0]
            let givenName = parts.count > 1 ? parts[1] : nil
            let suffix = parts.count > 2 ? parts[2] : nil

            return (familyName, givenName, suffix)
        } else {
            // "First Last"
            let parts = trimmed.components(separatedBy: " ")
            if parts.count > 1 {
                let familyName = parts.last ?? trimmed
                let givenName = parts.dropLast().joined(separator: " ")
                return (familyName, givenName, nil)
            }
            return (trimmed, nil, nil)
        }
    }
}

// MARK: - Publication Author (Join Table)

@objc(CDPublicationAuthor)
public class CDPublicationAuthor: NSManagedObject {
    @NSManaged public var order: Int16

    // Relationships
    @NSManaged public var publication: CDPublication?
    @NSManaged public var author: CDAuthor?
}

// MARK: - Linked File

@objc(CDLinkedFile)
public class CDLinkedFile: NSManagedObject {
    @NSManaged public var id: UUID
    @NSManaged public var relativePath: String
    @NSManaged public var filename: String
    @NSManaged public var fileType: String?
    @NSManaged public var sha256: String?
    @NSManaged public var dateAdded: Date

    // General attachment support
    @NSManaged public var displayName: String?       // User-editable name (falls back to filename)
    @NSManaged public var fileSize: Int64            // Cached file size for UI display
    @NSManaged public var mimeType: String?          // MIME type for accurate type detection

    // CloudKit PDF sync: Binary file data for cross-device sync
    // When file is imported on macOS, data is stored here and synced to iOS via CloudKit
    // iOS can then write this data to disk when user requests to view the PDF
    @NSManaged public var fileData: Data?

    // Relationships
    @NSManaged public var publication: CDPublication?
    @NSManaged public var attachmentTags: Set<CDAttachmentTag>?  // Tags for file grouping
    @NSManaged public var annotations: Set<CDAnnotation>?        // PDF annotations (Phase 3)
    @NSManaged public var remarkableDocuments: Set<CDRemarkableDocument>?  // reMarkable sync documents (ADR-019)
}

// MARK: - Linked File Helpers

public extension CDLinkedFile {

    /// File extension
    var fileExtension: String {
        URL(fileURLWithPath: filename).pathExtension.lowercased()
    }

    /// Whether this is a PDF
    var isPDF: Bool {
        fileExtension == "pdf" || fileType == "pdf"
    }

    /// The name to display (user-set displayName or falls back to filename)
    var effectiveDisplayName: String {
        if let name = displayName, !name.isEmpty {
            return name
        }
        return filename
    }

    /// Formatted file size for display (e.g., "1.2 MB")
    var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    /// Whether this file has any attachment tags
    var hasTags: Bool {
        !(attachmentTags?.isEmpty ?? true)
    }

    /// Whether this file is stored as in-memory data (fileData) vs external file reference
    var isFileData: Bool {
        get { fileData != nil }
        set {
            // If setting to false and we have file data, this clears it
            // Note: Setting to true requires setting fileData separately
            if !newValue { fileData = nil }
        }
    }

    /// Sorted tags by order
    var sortedTags: [CDAttachmentTag] {
        (attachmentTags ?? []).sorted { $0.order < $1.order }
    }

    /// Add an attachment tag to this linked file (Core Data relationship accessor)
    func addToAttachmentTags(_ tag: CDAttachmentTag) {
        if attachmentTags == nil {
            attachmentTags = []
        }
        attachmentTags?.insert(tag)
    }

    /// Remove an attachment tag from this linked file
    func removeFromAttachmentTags(_ tag: CDAttachmentTag) {
        attachmentTags?.remove(tag)
    }
}

// MARK: - Tag

@objc(CDTag)
public class CDTag: NSManagedObject {
    @NSManaged public var id: UUID
    @NSManaged public var name: String
    @NSManaged public var color: String?

    // Relationships
    @NSManaged public var publications: Set<CDPublication>?
}

// MARK: - Attachment Tag

/// Tags for grouping attachments (files) within a publication.
/// Separate from CDTag which is for publications themselves.
@objc(CDAttachmentTag)
public class CDAttachmentTag: NSManagedObject, Identifiable {
    @NSManaged public var id: UUID
    @NSManaged public var name: String
    @NSManaged public var color: String?
    @NSManaged public var order: Int16

    // Relationships
    @NSManaged public var linkedFiles: Set<CDLinkedFile>?
}

// MARK: - Attachment Tag Helpers

public extension CDAttachmentTag {

    /// Number of files with this tag
    var fileCount: Int {
        linkedFiles?.count ?? 0
    }

    /// Add a file to this tag
    func addFile(_ file: CDLinkedFile) {
        var files = linkedFiles ?? []
        files.insert(file)
        linkedFiles = files
    }

    /// Remove a file from this tag
    func removeFile(_ file: CDLinkedFile) {
        var files = linkedFiles ?? []
        files.remove(file)
        linkedFiles = files
    }
}

// MARK: - Collection

@objc(CDCollection)
public class CDCollection: NSManagedObject, Identifiable {
    // Use private primitive accessor to handle CloudKit sync where UUID might be nil
    @NSManaged private var primitiveId: UUID?

    /// Computed id that ensures a valid UUID is always returned.
    public var id: UUID {
        get {
            willAccessValue(forKey: "id")
            defer { didAccessValue(forKey: "id") }

            if let existingId = primitiveId {
                return existingId
            }

            let newId = UUID()
            primitiveId = newId
            return newId
        }
        set {
            willChangeValue(forKey: "id")
            primitiveId = newValue
            didChangeValue(forKey: "id")
        }
    }

    @NSManaged public var name: String
    @NSManaged public var isSmartCollection: Bool
    @NSManaged public var predicate: String?

    // ADR-016: Unified Paper Model
    @NSManaged public var isSmartSearchResults: Bool  // True if this is a smart search result collection
    @NSManaged public var isSystemCollection: Bool    // True for "Last Search" and other system collections

    // Relationships
    @NSManaged public var publications: Set<CDPublication>?
    @NSManaged public var smartSearch: CDSmartSearch?     // Inverse of CDSmartSearch.resultCollection
    @NSManaged public var library: CDLibrary?             // Inverse of CDLibrary.collections
    @NSManaged public var owningLibrary: CDLibrary?       // Inverse of CDLibrary.lastSearchCollection (for system collections)

    // Collection hierarchy for exploration drill-down
    @NSManaged public var parentCollection: CDCollection?     // Parent collection (for nested exploration)
    @NSManaged public var childCollections: Set<CDCollection>?  // Child collections
}

// MARK: - Collection Helpers

public extension CDCollection {

    /// Parse predicate string to NSPredicate
    var nsPredicate: NSPredicate? {
        guard isSmartCollection,
              let predicateString = predicate,
              !predicateString.isEmpty else {
            return nil
        }
        return NSPredicate(format: predicateString)
    }

    /// Get the owning library (direct or via smart search)
    var effectiveLibrary: CDLibrary? {
        library ?? smartSearch?.library
    }

    /// Count publications matching this collection's criteria.
    /// For static collections: returns count of directly assigned publications.
    /// For smart collections: evaluates predicate against owning library's publications.
    var matchingPublicationCount: Int {
        // Static collection: use direct relationship
        if !isSmartCollection {
            return publications?.filter { !$0.isDeleted }.count ?? 0
        }

        // Smart collection: evaluate predicate against library publications
        guard let predicate = nsPredicate,
              let owningLibrary = effectiveLibrary,
              let libraryPubs = owningLibrary.publications else {
            return 0
        }

        // Filter library publications by predicate
        let validPubs = libraryPubs.filter { !$0.isDeleted && $0.managedObjectContext != nil }
        return (validPubs as NSSet).filtered(using: predicate).count
    }

    // MARK: - Hierarchy Helpers

    /// Depth of this collection in the hierarchy (0 = root, 1 = first level child, etc.)
    var depth: Int {
        var d = 0
        var current = parentCollection
        while current != nil {
            d += 1
            current = current?.parentCollection
        }
        return d
    }

    /// Whether this collection has any child collections
    var hasChildren: Bool {
        !(childCollections?.isEmpty ?? true)
    }

    /// Sorted child collections by name
    var sortedChildren: [CDCollection] {
        (childCollections ?? []).sorted { ($0.name) < ($1.name) }
    }

    /// All ancestor collections from root to parent
    var ancestors: [CDCollection] {
        var result: [CDCollection] = []
        var current = parentCollection
        while let c = current {
            result.insert(c, at: 0)
            current = c.parentCollection
        }
        return result
    }
}

// MARK: - Library

@objc(CDLibrary)
public class CDLibrary: NSManagedObject, Identifiable {
    // Use private primitive accessor to handle CloudKit sync where UUID might be nil
    @NSManaged private var primitiveId: UUID?

    /// Computed id that ensures a valid UUID is always returned.
    /// If CloudKit syncs a record with nil UUID, a new one is generated.
    public var id: UUID {
        get {
            willAccessValue(forKey: "id")
            defer { didAccessValue(forKey: "id") }

            if let existingId = primitiveId {
                return existingId
            }

            // Generate and save a UUID if nil (CloudKit sync edge case)
            let newId = UUID()
            primitiveId = newId
            return newId
        }
        set {
            willChangeValue(forKey: "id")
            primitiveId = newValue
            didChangeValue(forKey: "id")
        }
    }

    @NSManaged public var name: String
    @NSManaged public var bibFilePath: String?         // Path to .bib file (may be nil for new libraries)
    @NSManaged public var papersDirectoryPath: String? // Path to Papers folder
    @NSManaged public var bookmarkData: Data?          // Security-scoped bookmark for file access
    @NSManaged public var dateCreated: Date
    @NSManaged public var dateLastOpened: Date?
    @NSManaged public var isDefault: Bool              // Is this the default library?
    @NSManaged public var sortOrder: Int16             // For sidebar ordering (drag-and-drop)
    @NSManaged public var isInbox: Bool                // Is this the special Inbox library?
    @NSManaged public var isSystemLibrary: Bool        // Is this a system library? (e.g., Exploration)
    @NSManaged public var isSaveLibrary: Bool            // Is this the Save library for Inbox triage?
    @NSManaged public var isDismissedLibrary: Bool     // Is this the Dismissed library for Inbox triage?
    @NSManaged public var isLocalOnly: Bool            // Is this local-only? (e.g., Exploration - not synced)
    @NSManaged public var deviceIdentifier: String?    // Device that created this local-only library

    // Relationships
    @NSManaged public var smartSearches: Set<CDSmartSearch>?
    @NSManaged public var publications: Set<CDPublication>?    // All publications in this library
    @NSManaged public var collections: Set<CDCollection>?      // All collections in this library
    @NSManaged public var lastSearchCollection: CDCollection?  // ADR-016: System collection for ad-hoc search results
    @NSManaged public var recommendationProfiles: Set<CDRecommendationProfile>?  // ADR-020: Learned preferences for this library
}

// MARK: - Library Helpers

public extension CDLibrary {

    /// Display name (uses .bib filename if name is empty)
    var displayName: String {
        if !name.isEmpty {
            return name
        }
        if let path = bibFilePath {
            return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        }
        return "Untitled Library"
    }

    /// Resolve the .bib file URL using the security-scoped bookmark (macOS) or path (iOS)
    func resolveURL() -> URL? {
        #if os(macOS)
        guard let bookmarkData else {
            // Fall back to path if no bookmark
            if let path = bibFilePath {
                return URL(fileURLWithPath: path)
            }
            return nil
        }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }

        // If bookmark is stale, we should refresh it (handled elsewhere)
        return url
        #else
        // iOS: Use path directly (files are in app container)
        if let path = bibFilePath {
            return URL(fileURLWithPath: path)
        }
        return nil
        #endif
    }

    /// Folder URL where the library's files are stored (parent directory of .bib file)
    @available(*, deprecated, message: "Use papersContainerURL instead for iCloud-only storage")
    var folderURL: URL? {
        resolveURL()?.deletingLastPathComponent()
    }

    // MARK: - Container-Based Storage (iCloud-Only)

    /// App container URL for this library's data.
    ///
    /// All library files (PDFs, etc.) are stored in the app's Application Support directory
    /// under `Libraries/{libraryID}/`. This eliminates sandbox complexity and ensures
    /// files are always accessible without security-scoped bookmarks.
    ///
    /// Path: `~/Library/Application Support/imbib/Libraries/{UUID}/`
    var containerURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("imbib")
        return base.appendingPathComponent("Libraries/\(id.uuidString)")
    }

    /// Papers directory within the app container for this library.
    ///
    /// Path: `~/Library/Application Support/imbib/Libraries/{UUID}/Papers/`
    var papersContainerURL: URL {
        containerURL.appendingPathComponent("Papers")
    }
}

// MARK: - Smart Search

@objc(CDSmartSearch)
public class CDSmartSearch: NSManagedObject, Identifiable {
    // Use private primitive accessor to handle CloudKit sync where UUID might be nil
    @NSManaged private var primitiveId: UUID?

    /// Computed id that ensures a valid UUID is always returned.
    public var id: UUID {
        get {
            willAccessValue(forKey: "id")
            defer { didAccessValue(forKey: "id") }

            if let existingId = primitiveId {
                return existingId
            }

            let newId = UUID()
            primitiveId = newId
            return newId
        }
        set {
            willChangeValue(forKey: "id")
            primitiveId = newValue
            didChangeValue(forKey: "id")
        }
    }

    @NSManaged public var name: String
    @NSManaged public var query: String
    @NSManaged public var sourceIDs: String?           // JSON array of source IDs
    @NSManaged public var dateCreated: Date
    @NSManaged public var dateLastExecuted: Date?
    @NSManaged public var order: Int16                  // For sidebar ordering

    // ADR-016: Unified Paper Model
    @NSManaged public var maxResults: Int16            // Limit stored results (default: 50)

    // Inbox feature: Smart searches can feed papers to the Inbox
    @NSManaged public var feedsToInbox: Bool           // If true, results go to Inbox library
    @NSManaged public var autoRefreshEnabled: Bool     // If true, auto-refresh at interval
    @NSManaged public var refreshIntervalSeconds: Int32 // Refresh interval (0 = use default 24h)
    @NSManaged public var lastFetchCount: Int16        // Papers found in last fetch (for badge)

    // Relationships
    @NSManaged public var library: CDLibrary?
    @NSManaged public var resultCollection: CDCollection?  // Collection holding imported results
}

// MARK: - Smart Search Helpers

public extension CDSmartSearch {

    /// Get source IDs as array
    var sources: [String] {
        get {
            guard let json = sourceIDs,
                  let data = json.data(using: .utf8),
                  let array = try? JSONDecoder().decode([String].self, from: data) else {
                return []
            }
            return array
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
               let json = String(data: data, encoding: .utf8) {
                sourceIDs = json
            }
        }
    }

    /// Whether this search uses all available sources
    var usesAllSources: Bool {
        sources.isEmpty
    }

    // MARK: - Group Feed Support

    /// Whether this smart search is a group feed (monitors multiple authors)
    var isGroupFeed: Bool {
        get { query.hasPrefix("GROUP_FEED|") }
        set {
            // Setting to true doesn't change the query format
            // Setting to false could convert the query, but for now we don't support this
        }
    }

    /// Parse group feed authors from the query string
    func groupFeedAuthors() -> [String] {
        guard isGroupFeed else { return [] }

        let parts = query.dropFirst("GROUP_FEED|".count).components(separatedBy: "|")
        for part in parts {
            if part.hasPrefix("authors:") {
                let authorsString = String(part.dropFirst("authors:".count))
                return authorsString
                    .components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        }
        return []
    }

    /// Parse group feed categories from the query string
    func groupFeedCategories() -> Set<String> {
        guard isGroupFeed else { return [] }

        let parts = query.dropFirst("GROUP_FEED|".count).components(separatedBy: "|")
        for part in parts {
            if part.hasPrefix("categories:") {
                let categoriesString = String(part.dropFirst("categories:".count))
                let categories = categoriesString
                    .components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                return Set(categories)
            }
        }
        return []
    }

    /// Parse whether cross-listed papers should be included
    func groupFeedIncludesCrossListed() -> Bool {
        guard isGroupFeed else { return true }

        let parts = query.dropFirst("GROUP_FEED|".count).components(separatedBy: "|")
        for part in parts {
            if part.hasPrefix("crosslist:") {
                let value = String(part.dropFirst("crosslist:".count))
                return value == "true"
            }
        }
        return true  // Default to including cross-listed
    }
}

// MARK: - Muted Item

/// Represents a muted item that should be excluded from Inbox results.
/// Can mute specific papers, authors, venues, or arXiv categories.
@objc(CDMutedItem)
public class CDMutedItem: NSManagedObject, Identifiable {
    @NSManaged public var id: UUID
    @NSManaged public var type: String                 // "author", "doi", "bibcode", "venue", "arxivCategory"
    @NSManaged public var value: String                // The muted value (e.g., author name, DOI, etc.)
    @NSManaged public var dateAdded: Date
}

// MARK: - Muted Item Types

public extension CDMutedItem {

    /// Types of items that can be muted
    enum MuteType: String, CaseIterable {
        case author = "author"           // Mute papers by a specific author
        case doi = "doi"                 // Mute a specific paper by DOI
        case bibcode = "bibcode"         // Mute a specific paper by ADS bibcode
        case venue = "venue"             // Mute papers from a venue/journal
        case arxivCategory = "arxivCategory"  // Mute papers from an arXiv category
    }

    /// Get the mute type enum
    var muteType: MuteType? {
        MuteType(rawValue: type)
    }
}

// MARK: - Dismissed Paper

/// Represents a paper that was dismissed from the Inbox.
/// Used to prevent papers from reappearing when found again by smart search feeds.
/// Tracks by DOI, arXiv ID, and/or bibcode for deduplication.
@objc(CDDismissedPaper)
public class CDDismissedPaper: NSManagedObject, Identifiable {
    @NSManaged public var id: UUID
    @NSManaged public var doi: String?             // DOI of dismissed paper
    @NSManaged public var arxivID: String?         // arXiv ID of dismissed paper
    @NSManaged public var bibcode: String?         // ADS bibcode of dismissed paper
    @NSManaged public var dateDismissed: Date      // When the paper was dismissed
}

// MARK: - SciX Library

/// Cached remote SciX library from the Biblib API.
/// Supports read/write operations with two-way sync.
@objc(CDSciXLibrary)
public class CDSciXLibrary: NSManagedObject, Identifiable {
    // Use private primitive accessor to handle CloudKit sync where UUID might be nil
    @NSManaged private var primitiveId: UUID?

    /// Computed id that ensures a valid UUID is always returned.
    /// If CloudKit syncs a record with nil UUID, a new one is generated.
    public var id: UUID {
        get {
            willAccessValue(forKey: "id")
            defer { didAccessValue(forKey: "id") }

            if let existingId = primitiveId {
                return existingId
            }

            // Generate and save a UUID if nil (CloudKit sync edge case)
            let newId = UUID()
            primitiveId = newId
            return newId
        }
        set {
            willChangeValue(forKey: "id")
            primitiveId = newValue
            didChangeValue(forKey: "id")
        }
    }

    @NSManaged public var remoteID: String                  // SciX library ID from API
    @NSManaged public var name: String
    @NSManaged public var descriptionText: String?
    @NSManaged public var isPublic: Bool
    @NSManaged public var dateCreated: Date
    @NSManaged public var lastSyncDate: Date?               // When last synced with SciX
    @NSManaged public var syncState: String                 // synced, pending, error
    @NSManaged public var permissionLevel: String           // owner, admin, write, read
    @NSManaged public var ownerEmail: String?
    @NSManaged public var documentCount: Int32              // Number of papers in library
    @NSManaged public var sortOrder: Int16                  // For sidebar ordering

    // Relationships
    @NSManaged public var publications: Set<CDPublication>? // Cached papers from this library
    @NSManaged public var pendingChanges: Set<CDSciXPendingChange>?
}

// MARK: - SciX Library Helpers

public extension CDSciXLibrary {

    /// Sync state enum for type-safe access
    enum SyncState: String, CaseIterable, Sendable {
        case synced = "synced"      // In sync with remote
        case pending = "pending"    // Has pending local changes
        case error = "error"        // Last sync failed
    }

    /// Permission level enum for type-safe access
    enum PermissionLevel: String, CaseIterable, Sendable {
        case owner = "owner"        // Full control, can delete
        case admin = "admin"        // Can manage permissions
        case write = "write"        // Can add/remove papers
        case read = "read"          // Read-only access

        /// SF Symbol for permission level
        public var icon: String {
            switch self {
            case .owner: return "crown"
            case .admin: return "key"
            case .write: return "pencil"
            case .read: return "eye"
            }
        }

        /// Whether this level allows editing
        var canEdit: Bool {
            self != .read
        }

        /// Whether this level allows managing permissions
        var canManagePermissions: Bool {
            self == .owner || self == .admin
        }
    }

    /// Get sync state as enum
    var syncStateEnum: SyncState {
        SyncState(rawValue: syncState) ?? .synced
    }

    /// Get permission level as enum
    var permissionLevelEnum: PermissionLevel {
        PermissionLevel(rawValue: permissionLevel) ?? .read
    }

    /// Whether this library has pending local changes
    var hasPendingChanges: Bool {
        !(pendingChanges?.isEmpty ?? true)
    }

    /// Number of pending changes
    var pendingChangeCount: Int {
        pendingChanges?.count ?? 0
    }

    /// Whether current user can edit this library
    var canEdit: Bool {
        permissionLevelEnum.canEdit
    }

    /// Whether current user can manage permissions
    var canManagePermissions: Bool {
        permissionLevelEnum.canManagePermissions
    }

    /// Display name (falls back to "Untitled" if empty)
    var displayName: String {
        name.isEmpty ? "Untitled Library" : name
    }

    /// All bibcodes in this library
    var bibcodes: [String] {
        publications?.compactMap { $0.bibcode } ?? []
    }
}

// MARK: - SciX Pending Change

/// Queued change for sync to SciX.
/// Stored locally until confirmed and pushed to server.
@objc(CDSciXPendingChange)
public class CDSciXPendingChange: NSManagedObject, Identifiable {
    @NSManaged public var id: UUID
    @NSManaged public var action: String                    // add, remove, updateMeta
    @NSManaged public var bibcodesJSON: String?             // JSON array of bibcodes (for add/remove)
    @NSManaged public var metadataJSON: String?             // JSON object with new metadata (for updateMeta)
    @NSManaged public var dateCreated: Date

    // Relationships
    @NSManaged public var library: CDSciXLibrary?
}

// MARK: - SciX Pending Change Helpers

public extension CDSciXPendingChange {

    /// Action types for pending changes
    enum Action: String, CaseIterable, Sendable {
        case add = "add"                // Add papers to library
        case remove = "remove"          // Remove papers from library
        case updateMeta = "updateMeta"  // Update library metadata (name, description, public)
    }

    /// Get action as enum
    var actionEnum: Action {
        Action(rawValue: action) ?? .add
    }

    /// Get bibcodes as array (for add/remove actions)
    var bibcodes: [String] {
        get {
            guard let json = bibcodesJSON,
                  let data = json.data(using: .utf8),
                  let array = try? JSONDecoder().decode([String].self, from: data) else {
                return []
            }
            return array
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
               let json = String(data: data, encoding: .utf8) {
                bibcodesJSON = json
            }
        }
    }

    /// Metadata update info
    struct MetadataUpdate: Codable {
        var name: String?
        var description: String?
        var isPublic: Bool?
    }

    /// Get metadata update (for updateMeta action)
    var metadata: MetadataUpdate? {
        get {
            guard let json = metadataJSON,
                  let data = json.data(using: .utf8) else {
                return nil
            }
            return try? JSONDecoder().decode(MetadataUpdate.self, from: data)
        }
        set {
            if let value = newValue,
               let data = try? JSONEncoder().encode(value),
               let json = String(data: data, encoding: .utf8) {
                metadataJSON = json
            } else {
                metadataJSON = nil
            }
        }
    }

    /// Description of the change for display
    var changeDescription: String {
        switch actionEnum {
        case .add:
            let count = bibcodes.count
            return "Add \(count) paper\(count == 1 ? "" : "s")"
        case .remove:
            let count = bibcodes.count
            return "Remove \(count) paper\(count == 1 ? "" : "s")"
        case .updateMeta:
            if let meta = metadata {
                var changes: [String] = []
                if meta.name != nil { changes.append("name") }
                if meta.description != nil { changes.append("description") }
                if meta.isPublic != nil { changes.append("visibility") }
                return "Update \(changes.joined(separator: ", "))"
            }
            return "Update metadata"
        }
    }
}

// MARK: - Annotation (Phase 3: PDF Annotation Persistence)

/// Core Data entity for PDF annotation metadata.
/// Stores annotation data for CloudKit sync and searchable annotation index.
@objc(CDAnnotation)
public class CDAnnotation: NSManagedObject, Identifiable {
    @NSManaged public var id: UUID
    @NSManaged public var annotationType: String       // highlight, underline, strikethrough, note, freeText
    @NSManaged public var pageNumber: Int32            // 0-indexed page number
    @NSManaged public var boundsJSON: String           // JSON-encoded CGRect
    @NSManaged public var color: String?               // Hex color like "#FFFF00"
    @NSManaged public var contents: String?            // Text content for notes
    @NSManaged public var selectedText: String?        // Highlighted/underlined text
    @NSManaged public var author: String?              // Device name or user identifier
    @NSManaged public var dateCreated: Date
    @NSManaged public var dateModified: Date
    @NSManaged public var syncState: String?           // For CloudKit sync tracking

    // Relationships
    @NSManaged public var linkedFile: CDLinkedFile?    // The PDF file containing this annotation
}

// MARK: - Annotation Types

public extension CDAnnotation {

    /// Types of PDF annotations
    enum AnnotationType: String, CaseIterable, Sendable {
        case highlight = "highlight"
        case underline = "underline"
        case strikethrough = "strikethrough"
        case note = "note"              // Sticky note (text annotation)
        case freeText = "freeText"      // Free text annotation
        case ink = "ink"                // Drawing/signature

        /// SF Symbol for this annotation type
        public var icon: String {
            switch self {
            case .highlight: return "highlighter"
            case .underline: return "underline"
            case .strikethrough: return "strikethrough"
            case .note: return "note.text"
            case .freeText: return "textformat"
            case .ink: return "pencil.tip"
            }
        }

        /// Display name for UI
        public var displayName: String {
            switch self {
            case .highlight: return "Highlight"
            case .underline: return "Underline"
            case .strikethrough: return "Strikethrough"
            case .note: return "Note"
            case .freeText: return "Free Text"
            case .ink: return "Ink"
            }
        }
    }

    /// Get annotation type as enum
    var typeEnum: AnnotationType? {
        AnnotationType(rawValue: annotationType)
    }
}

// MARK: - Annotation Bounds

public extension CDAnnotation {

    /// Encodable bounds struct for JSON storage
    struct Bounds: Codable, Sendable {
        public var x: CGFloat
        public var y: CGFloat
        public var width: CGFloat
        public var height: CGFloat

        public init(rect: CGRect) {
            self.x = rect.origin.x
            self.y = rect.origin.y
            self.width = rect.size.width
            self.height = rect.size.height
        }

        public var cgRect: CGRect {
            CGRect(x: x, y: y, width: width, height: height)
        }
    }

    /// Get bounds as CGRect
    var bounds: CGRect {
        get {
            guard let data = boundsJSON.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(Bounds.self, from: data) else {
                return .zero
            }
            return decoded.cgRect
        }
        set {
            let bounds = Bounds(rect: newValue)
            if let data = try? JSONEncoder().encode(bounds),
               let json = String(data: data, encoding: .utf8) {
                boundsJSON = json
            }
        }
    }
}

// MARK: - Recommendation Profile (ADR-020)

/// Stores learned user preferences for inbox/exploration ranking.
///
/// The recommendation engine uses a transparent linear weighted sum model.
/// All weights are user-adjustable and the score breakdown is visible for every paper.
@objc(CDRecommendationProfile)
public class CDRecommendationProfile: NSManagedObject, Identifiable {
    @NSManaged private var primitiveId: UUID?

    /// Computed id that ensures a valid UUID is always returned.
    public var id: UUID {
        get {
            willAccessValue(forKey: "id")
            defer { didAccessValue(forKey: "id") }

            if let existingId = primitiveId {
                return existingId
            }

            let newId = UUID()
            primitiveId = newId
            return newId
        }
        set {
            willChangeValue(forKey: "id")
            primitiveId = newValue
            didChangeValue(forKey: "id")
        }
    }

    @NSManaged public var topicAffinitiesData: Data?        // [String: Double] JSON
    @NSManaged public var authorAffinitiesData: Data?       // [String: Double] JSON
    @NSManaged public var venueAffinitiesData: Data?        // [String: Double] JSON
    @NSManaged public var lastUpdated: Date
    @NSManaged public var trainingEventsData: Data?         // [TrainingEvent] JSON

    // Relationships
    @NSManaged public var library: CDLibrary?               // Optional: per-library profile
}

// MARK: - Recommendation Profile Helpers

public extension CDRecommendationProfile {

    /// Get topic affinities as dictionary
    var topicAffinities: [String: Double] {
        get {
            guard let data = topicAffinitiesData,
                  let dict = try? JSONDecoder().decode([String: Double].self, from: data) else {
                return [:]
            }
            return dict
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                topicAffinitiesData = data
            }
        }
    }

    /// Get author affinities as dictionary
    var authorAffinities: [String: Double] {
        get {
            guard let data = authorAffinitiesData,
                  let dict = try? JSONDecoder().decode([String: Double].self, from: data) else {
                return [:]
            }
            return dict
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                authorAffinitiesData = data
            }
        }
    }

    /// Get venue affinities as dictionary
    var venueAffinities: [String: Double] {
        get {
            guard let data = venueAffinitiesData,
                  let dict = try? JSONDecoder().decode([String: Double].self, from: data) else {
                return [:]
            }
            return dict
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                venueAffinitiesData = data
            }
        }
    }

    /// Get affinity for a specific author (normalized name)
    func authorAffinity(for authorName: String) -> Double {
        authorAffinities[authorName.lowercased()] ?? 0.0
    }

    /// Get affinity for a specific topic keyword
    func topicAffinity(for topic: String) -> Double {
        topicAffinities[topic.lowercased()] ?? 0.0
    }

    /// Get affinity for a specific venue/journal
    func venueAffinity(for venue: String) -> Double {
        venueAffinities[venue.lowercased()] ?? 0.0
    }

    /// Update affinity for an author
    func updateAuthorAffinity(_ authorName: String, delta: Double) {
        var affinities = authorAffinities
        let key = authorName.lowercased()
        affinities[key] = (affinities[key] ?? 0.0) + delta
        authorAffinities = affinities
        lastUpdated = Date()
    }

    /// Update affinity for a topic
    func updateTopicAffinity(_ topic: String, delta: Double) {
        var affinities = topicAffinities
        let key = topic.lowercased()
        affinities[key] = (affinities[key] ?? 0.0) + delta
        topicAffinities = affinities
        lastUpdated = Date()
    }

    /// Update affinity for a venue
    func updateVenueAffinity(_ venue: String, delta: Double) {
        var affinities = venueAffinities
        let key = venue.lowercased()
        affinities[key] = (affinities[key] ?? 0.0) + delta
        venueAffinities = affinities
        lastUpdated = Date()
    }

    /// Check if this is a cold start (no training data)
    var isColdStart: Bool {
        authorAffinities.isEmpty && topicAffinities.isEmpty && venueAffinities.isEmpty
    }

    /// Total number of learned preferences
    var preferenceCount: Int {
        authorAffinities.count + topicAffinities.count + venueAffinities.count
    }
}

// MARK: - Annotation Helpers

public extension CDAnnotation {

    /// Create an annotation from PDFAnnotation data
    static func create(
        from pdfAnnotation: Any,  // PDFAnnotation - using Any to avoid PDFKit import in this file
        pageNumber: Int,
        selectedText: String? = nil,
        in context: NSManagedObjectContext
    ) -> CDAnnotation {
        let annotation = CDAnnotation(context: context)
        annotation.id = UUID()
        annotation.pageNumber = Int32(pageNumber)
        annotation.selectedText = selectedText
        annotation.dateCreated = Date()
        annotation.dateModified = Date()

        #if os(macOS)
        annotation.author = Host.current().localizedName ?? "Unknown"
        #else
        annotation.author = UIDevice.current.name
        #endif

        return annotation
    }

    /// Preview text for display (contents or selected text truncated)
    var previewText: String {
        if let contents = contents, !contents.isEmpty {
            return String(contents.prefix(100))
        }
        if let selected = selectedText, !selected.isEmpty {
            return String(selected.prefix(100))
        }
        return typeEnum?.displayName ?? "Annotation"
    }

    /// Whether this annotation has text content
    var hasContent: Bool {
        (contents != nil && !contents!.isEmpty) || (selectedText != nil && !selectedText!.isEmpty)
    }
}

// MARK: - CDLinkedFile Annotation Helpers

public extension CDLinkedFile {

    /// Sorted annotations by page number, then position
    var sortedAnnotations: [CDAnnotation] {
        (annotations ?? []).sorted { a, b in
            if a.pageNumber != b.pageNumber {
                return a.pageNumber < b.pageNumber
            }
            // Same page: sort by y position (top to bottom)
            return a.bounds.origin.y > b.bounds.origin.y
        }
    }

    /// Annotations on a specific page
    func annotations(onPage page: Int) -> [CDAnnotation] {
        sortedAnnotations.filter { $0.pageNumber == Int32(page) }
    }

    /// Count of annotations
    var annotationCount: Int {
        annotations?.count ?? 0
    }

    /// Whether this file has any annotations
    var hasAnnotations: Bool {
        annotationCount > 0
    }
}

// MARK: - reMarkable Document (ADR-019)

/// Core Data entity for tracking publications synced to reMarkable.
///
/// Stores the mapping between a publication and its reMarkable document ID,
/// along with sync state and annotation tracking.
@objc(CDRemarkableDocument)
public class CDRemarkableDocument: NSManagedObject, Identifiable {
    @NSManaged public var id: UUID
    @NSManaged public var remarkableDocumentID: String      // ID on reMarkable device
    @NSManaged public var remarkableFolderID: String?       // Parent folder on reMarkable
    @NSManaged public var remarkableVersion: Int32          // Document version for sync
    @NSManaged public var localFileHash: String?            // SHA256 of local PDF for change detection
    @NSManaged public var dateUploaded: Date                // When first uploaded
    @NSManaged public var lastSyncDate: Date?               // Last successful sync
    @NSManaged public var syncState: String                 // pending, synced, conflict, error
    @NSManaged public var syncError: String?                // Error message if syncState == error
    @NSManaged public var annotationCount: Int32            // Number of imported annotations

    // Relationships
    @NSManaged public var publication: CDPublication?       // The source publication
    @NSManaged public var linkedFile: CDLinkedFile?         // The PDF that was uploaded
    @NSManaged public var remarkableAnnotations: Set<CDRemarkableAnnotation>?  // Imported annotations
}

// MARK: - reMarkable Document Helpers

public extension CDRemarkableDocument {

    /// Sync state as enum
    enum SyncState: String, CaseIterable, Sendable {
        case pending = "pending"
        case synced = "synced"
        case conflict = "conflict"
        case error = "error"

        public var icon: String {
            switch self {
            case .pending: return "arrow.triangle.2.circlepath"
            case .synced: return "checkmark.circle.fill"
            case .conflict: return "exclamationmark.triangle.fill"
            case .error: return "xmark.circle.fill"
            }
        }
    }

    /// Get sync state as enum
    var syncStateEnum: SyncState {
        SyncState(rawValue: syncState) ?? .pending
    }

    /// Whether this document needs to be synced
    var needsSync: Bool {
        syncStateEnum == .pending || syncStateEnum == .conflict
    }

    /// Whether this document has annotations from reMarkable
    var hasRemarkableAnnotations: Bool {
        annotationCount > 0
    }

    /// Sorted annotations by page number
    var sortedAnnotations: [CDRemarkableAnnotation] {
        (remarkableAnnotations ?? []).sorted { $0.pageNumber < $1.pageNumber }
    }
}

// MARK: - reMarkable Annotation (ADR-019)

/// Core Data entity for annotations imported from reMarkable.
///
/// Stores both raw stroke data (for rendering) and converted annotation data
/// (for PDF embedding). Separate from CDAnnotation to preserve the original
/// reMarkable data format.
@objc(CDRemarkableAnnotation)
public class CDRemarkableAnnotation: NSManagedObject, Identifiable {
    @NSManaged public var id: UUID
    @NSManaged public var pageNumber: Int32                 // 0-indexed page number
    @NSManaged public var annotationType: String            // highlight, ink, text
    @NSManaged public var layerName: String?                // reMarkable layer name
    @NSManaged public var boundsJSON: String                // JSON-encoded CGRect
    @NSManaged public var strokeDataCompressed: Data?       // Compressed raw stroke data
    @NSManaged public var color: String?                    // Hex color (e.g., "#FFFF00")
    @NSManaged public var ocrText: String?                  // OCR result for handwritten notes
    @NSManaged public var ocrConfidence: Double             // OCR confidence score (0-1)
    @NSManaged public var dateImported: Date                // When imported from reMarkable
    @NSManaged public var remarkableVersion: Int32          // Version when imported

    // Relationships
    @NSManaged public var remarkableDocument: CDRemarkableDocument?  // Parent document
}

// MARK: - reMarkable Annotation Helpers

public extension CDRemarkableAnnotation {

    /// Annotation type as enum
    enum AnnotationType: String, CaseIterable, Sendable {
        case highlight = "highlight"
        case ink = "ink"
        case text = "text"

        public var icon: String {
            switch self {
            case .highlight: return "highlighter"
            case .ink: return "pencil.tip"
            case .text: return "text.cursor"
            }
        }

        public var displayName: String {
            switch self {
            case .highlight: return "Highlight"
            case .ink: return "Handwritten"
            case .text: return "Text"
            }
        }
    }

    /// Get annotation type as enum
    var typeEnum: AnnotationType {
        AnnotationType(rawValue: annotationType) ?? .ink
    }

    /// Bounds as CGRect (decoded from JSON)
    var bounds: CGRect {
        get {
            guard let data = boundsJSON.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(BoundsData.self, from: data)
            else { return .zero }
            return decoded.cgRect
        }
        set {
            let bounds = BoundsData(rect: newValue)
            if let data = try? JSONEncoder().encode(bounds),
               let json = String(data: data, encoding: .utf8) {
                boundsJSON = json
            }
        }
    }

    /// Helper struct for JSON encoding bounds
    private struct BoundsData: Codable {
        var x: CGFloat
        var y: CGFloat
        var width: CGFloat
        var height: CGFloat

        init(rect: CGRect) {
            self.x = rect.origin.x
            self.y = rect.origin.y
            self.width = rect.size.width
            self.height = rect.size.height
        }

        var cgRect: CGRect {
            CGRect(x: x, y: y, width: width, height: height)
        }
    }

    /// Whether this annotation has OCR text
    var hasOCRText: Bool {
        ocrText != nil && !ocrText!.isEmpty
    }

    /// Preview text (OCR text or type name)
    var previewText: String {
        if let text = ocrText, !text.isEmpty {
            return String(text.prefix(100))
        }
        return typeEnum.displayName
    }
}
