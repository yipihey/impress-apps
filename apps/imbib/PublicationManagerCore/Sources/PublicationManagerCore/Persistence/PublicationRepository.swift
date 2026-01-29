//
//  PublicationRepository.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import Foundation
import CoreData
import OSLog

// MARK: - Publication Repository

/// Data access layer for publications.
/// Abstracts Core Data operations for the rest of the app.
public actor PublicationRepository {

    // MARK: - Properties

    private let persistenceController: PersistenceController

    // MARK: - Initialization

    public init(persistenceController: PersistenceController = .shared) {
        self.persistenceController = persistenceController
    }

    // MARK: - Fetch Operations

    /// Fetch all publications
    public func fetchAll(sortedBy sortKey: String = "dateAdded", ascending: Bool = false) async -> [CDPublication] {
        Logger.persistence.entering()
        defer { Logger.persistence.exiting() }

        let context = persistenceController.viewContext

        return await context.perform {
            let request = NSFetchRequest<CDPublication>(entityName: "Publication")
            request.sortDescriptors = [NSSortDescriptor(key: sortKey, ascending: ascending)]

            do {
                return try context.fetch(request)
            } catch {
                Logger.persistence.error("Failed to fetch publications: \(error.localizedDescription)")
                return []
            }
        }
    }

    /// Fetch publication by cite key
    public func fetch(byCiteKey citeKey: String) async -> CDPublication? {
        let context = persistenceController.viewContext

        return await context.perform {
            let request = NSFetchRequest<CDPublication>(entityName: "Publication")
            request.predicate = NSPredicate(format: "citeKey == %@", citeKey)
            request.fetchLimit = 1

            return try? context.fetch(request).first
        }
    }

    /// Fetch publication by ID
    public func fetch(byID id: UUID) async -> CDPublication? {
        let context = persistenceController.viewContext

        return await context.perform {
            let request = NSFetchRequest<CDPublication>(entityName: "Publication")
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            request.fetchLimit = 1

            return try? context.fetch(request).first
        }
    }

    /// Fetch publications by multiple IDs
    public func fetch(byIDs ids: Set<UUID>) async -> [CDPublication] {
        guard !ids.isEmpty else { return [] }
        let context = persistenceController.viewContext

        return await context.perform {
            let request = NSFetchRequest<CDPublication>(entityName: "Publication")
            request.predicate = NSPredicate(format: "id IN %@", ids as CVarArg)

            return (try? context.fetch(request)) ?? []
        }
    }

    /// Search publications by title, author, abstract, and other fields.
    ///
    /// Uses the Rust full-text search index when available for fast, relevance-ranked
    /// results across all text fields including abstracts. Falls back to basic Core Data
    /// search if the index is unavailable.
    ///
    /// - Parameter query: The search query
    /// - Returns: Publications matching the query, ordered by relevance
    public func search(query: String) async -> [CDPublication] {
        guard !query.isEmpty else { return await fetchAll() }

        // Try full-text search first
        if let results = await FullTextSearchService.shared.search(query: query) {
            // Fetch the actual CDPublication objects by ID
            let ids = Set(results.map { $0.publicationId })
            let publications = await fetch(byIDs: ids)

            // Sort by relevance score (maintain the order from search results)
            let idToScore = Dictionary(uniqueKeysWithValues: results.map { ($0.publicationId, $0.score) })
            return publications.sorted { pub1, pub2 in
                let score1 = idToScore[pub1.id] ?? 0
                let score2 = idToScore[pub2.id] ?? 0
                return score1 > score2
            }
        }

        // Fallback to basic Core Data search
        let context = persistenceController.viewContext

        return await context.perform {
            let request = NSFetchRequest<CDPublication>(entityName: "Publication")
            request.predicate = NSPredicate(
                format: "title CONTAINS[cd] %@ OR citeKey CONTAINS[cd] %@",
                query, query
            )
            request.sortDescriptors = [NSSortDescriptor(key: "dateModified", ascending: false)]

            do {
                return try context.fetch(request)
            } catch {
                Logger.persistence.error("Search failed: \(error.localizedDescription)")
                return []
            }
        }
    }

    /// Get all existing cite keys
    public func allCiteKeys() async -> Set<String> {
        let context = persistenceController.viewContext

        return await context.perform {
            let request = NSFetchRequest<CDPublication>(entityName: "Publication")
            request.propertiesToFetch = ["citeKey"]

            do {
                let pubs = try context.fetch(request)
                return Set(pubs.map { $0.citeKey })
            } catch {
                Logger.persistence.error("Failed to fetch cite keys: \(error.localizedDescription)")
                return []
            }
        }
    }

    // MARK: - Create Operations

    /// Create a new publication from BibTeX entry
    ///
    /// - Parameters:
    ///   - entry: The BibTeX entry to create from
    ///   - library: Optional library for resolving file paths
    ///   - processLinkedFiles: If true, process Bdsk-File-* fields to create linked file records
    @discardableResult
    public func create(
        from entry: BibTeXEntry,
        in library: CDLibrary? = nil,
        processLinkedFiles: Bool = true
    ) async -> CDPublication {
        // Apply import settings to the entry
        let processedEntry = await applyImportSettings(to: entry)

        Logger.persistence.info("Creating publication: \(processedEntry.citeKey)")
        let context = persistenceController.viewContext

        let publication = await context.perform {
            let publication = CDPublication(context: context)
            publication.id = UUID()
            publication.dateAdded = Date()
            publication.update(from: processedEntry, context: context)

            self.persistenceController.save()
            return publication
        }

        // Process linked files on MainActor
        if processLinkedFiles {
            await MainActor.run {
                AttachmentManager.shared.processBdskFiles(from: processedEntry, for: publication, in: library)
            }
        }

        // Index for full-text search
        await FullTextSearchService.shared.indexPublication(publication)

        return publication
    }

    /// Apply import settings to a BibTeX entry
    /// - Generates cite key if autoGenerateCiteKeys is enabled and cite key is missing/generic
    /// - Applies default entry type if entry type is missing
    private func applyImportSettings(to entry: BibTeXEntry) async -> BibTeXEntry {
        let settings = await ImportExportSettingsStore.shared.settings
        var processedEntry = entry

        // Auto-generate cite key if setting is enabled and cite key is missing/generic
        if settings.autoGenerateCiteKeys && isCiteKeyGeneric(entry.citeKey) {
            let generatedKey = generateCiteKey(from: entry)
            processedEntry.citeKey = generatedKey
            Logger.persistence.debug("Generated cite key '\(generatedKey)' for entry")
        }

        // Apply default entry type if missing or generic
        if processedEntry.entryType.isEmpty || processedEntry.entryType.lowercased() == "misc" {
            // Only override "misc" if we have better information
            let detectedType = detectEntryType(from: processedEntry)
            if detectedType != "misc" || processedEntry.entryType.isEmpty {
                processedEntry.entryType = detectedType.isEmpty ? settings.defaultEntryType : detectedType
            }
        }

        return processedEntry
    }

    /// Check if a cite key is generic/placeholder
    private func isCiteKeyGeneric(_ citeKey: String) -> Bool {
        let lowercased = citeKey.lowercased()
        return citeKey.isEmpty ||
               lowercased == "new" ||
               lowercased == "untitled" ||
               lowercased == "unknown" ||
               lowercased.hasPrefix("entry") ||
               lowercased.hasPrefix("ref") ||
               citeKey.allSatisfy { $0.isNumber }
    }

    /// Generate a cite key from entry fields: LastName + Year + TitleWord
    private func generateCiteKey(from entry: BibTeXEntry) -> String {
        // Extract last name from author field
        let lastNamePart = entry.fields["author"]?
            .components(separatedBy: " and ")
            .first?
            .components(separatedBy: ",")
            .first?
            .trimmingCharacters(in: .whitespaces)
            .components(separatedBy: " ")
            .last?
            .filter { $0.isLetter } ?? "Unknown"

        // Extract year
        let yearPart = entry.fields["year"] ?? ""

        // Extract first meaningful title word (longer than 3 characters)
        let titleWord = (entry.fields["title"] ?? "")
            .components(separatedBy: .whitespaces)
            .first { $0.count > 3 }?
            .filter { $0.isLetter }
            .capitalized ?? ""

        return "\(lastNamePart)\(yearPart)\(titleWord)"
    }

    /// Detect entry type from fields if not explicitly set
    private func detectEntryType(from entry: BibTeXEntry) -> String {
        let fields = entry.fields

        // Check for journal article indicators
        if fields["journal"] != nil {
            return "article"
        }

        // Check for conference paper indicators
        if fields["booktitle"] != nil || fields["conference"] != nil {
            return "inproceedings"
        }

        // Check for book indicators
        if fields["isbn"] != nil || (fields["publisher"] != nil && fields["editor"] != nil) {
            return "book"
        }

        // Check for thesis indicators
        if fields["school"] != nil {
            if let type = fields["type"]?.lowercased(),
               type.contains("phd") || type.contains("doctor") {
                return "phdthesis"
            }
            return "mastersthesis"
        }

        // Check for technical report
        if fields["institution"] != nil {
            return "techreport"
        }

        // Default to misc
        return "misc"
    }

    /// Import multiple entries
    ///
    /// - Parameters:
    ///   - entries: BibTeX entries to import
    ///   - library: Optional library for resolving file paths (for Bdsk-File-* fields)
    public func importEntries(_ entries: [BibTeXEntry], in library: CDLibrary? = nil) async -> Int {
        Logger.persistence.info("Importing \(entries.count) entries")

        var imported = 0
        for entry in entries {
            // Check for duplicate
            if await fetch(byCiteKey: entry.citeKey) == nil {
                await create(from: entry, in: library)
                imported += 1
            } else {
                Logger.persistence.debug("Skipping duplicate: \(entry.citeKey)")
            }
        }

        Logger.persistence.info("Imported \(imported) new entries")
        return imported
    }

    // MARK: - Update Operations

    /// Update an existing publication
    public func update(_ publication: CDPublication, with entry: BibTeXEntry) async {
        Logger.persistence.info("Updating publication: \(publication.citeKey)")
        let context = persistenceController.viewContext

        await context.perform {
            publication.update(from: entry, context: context)
            self.persistenceController.save()
        }

        // Update search index
        await FullTextSearchService.shared.indexPublication(publication)
    }

    /// Update a single field in a publication
    public func updateField(_ publication: CDPublication, field: String, value: String?) async {
        Logger.persistence.info("Updating field '\(field)' for: \(publication.citeKey)")
        let context = persistenceController.viewContext

        await context.perform {
            var currentFields = publication.fields
            if let value = value, !value.isEmpty {
                currentFields[field] = value
            } else {
                currentFields.removeValue(forKey: field)
            }
            publication.fields = currentFields
            publication.dateModified = Date()
            self.persistenceController.save()
        }

        // Re-index if a searchable field changed
        let searchableFields: Set<String> = ["abstract", "title", "author", "note"]
        if searchableFields.contains(field) {
            await FullTextSearchService.shared.indexPublication(publication)
        }
    }

    // MARK: - Enrichment Operations

    /// Save enrichment result to a publication
    ///
    /// Updates citation count, PDF URLs, abstract, and other enrichment data.
    /// Called from EnrichmentService.onEnrichmentComplete callback.
    public func saveEnrichmentResult(publicationID: UUID, result: EnrichmentResult) async {
        guard let publication = await fetch(byID: publicationID) else {
            Logger.persistence.warning("Cannot save enrichment - publication not found: \(publicationID)")
            return
        }

        let context = persistenceController.viewContext
        let data = result.data

        await context.perform {
            // Citation count
            if let count = data.citationCount {
                publication.citationCount = Int32(count)
            }

            // Reference count
            if let count = data.referenceCount {
                publication.referenceCount = Int32(count)
            }

            // PDF URLs from enrichment source (e.g., OpenAlex)
            if let pdfURLs = data.pdfURLs, !pdfURLs.isEmpty {
                for pdfURL in pdfURLs {
                    let link = PDFLink(
                        url: pdfURL,
                        type: .publisher,  // OpenAlex typically returns publisher/OA URLs
                        sourceID: data.source.sourceID
                    )
                    publication.addPDFLink(link)
                }
                Logger.persistence.info("Added \(pdfURLs.count) PDF link(s) from \(data.source.displayName)")
            }

            // Typed PDF links from enrichment (e.g., ADS scanned PDFs)
            if let pdfLinks = data.pdfLinks, !pdfLinks.isEmpty {
                for link in pdfLinks {
                    publication.addPDFLink(link)
                }
                Logger.persistence.info("Added \(pdfLinks.count) typed PDF link(s) from \(data.source.displayName)")
            }

            // Abstract (if we don't have one and enrichment provides it)
            if publication.abstract == nil || publication.abstract?.isEmpty == true,
               let abstract = data.abstract, !abstract.isEmpty {
                publication.abstract = abstract
            }

            // Resolved identifiers
            if let oaID = result.resolvedIdentifiers[.openAlex], publication.openAlexID == nil {
                publication.openAlexID = oaID
            }
            if let ssID = result.resolvedIdentifiers[.semanticScholar], publication.semanticScholarID == nil {
                publication.semanticScholarID = ssID
            }
            // Bibcode from ADS enrichment - critical for Similar/Co-read features
            if let bibcode = result.resolvedIdentifiers[.bibcode] {
                publication.bibcodeNormalized = bibcode
                // Also store in fields dict for BibTeX export
                var fields = publication.fields
                fields["bibcode"] = bibcode
                publication.fields = fields
                Logger.persistence.info("Resolved bibcode: \(bibcode) for \(publication.citeKey)")
            }

            // Update enrichment tracking fields
            publication.enrichmentSource = data.source.sourceID
            publication.enrichmentDate = Date()
            publication.dateModified = Date()

            self.persistenceController.save()
            Logger.persistence.info("Saved enrichment result for: \(publication.citeKey)")
        }

        // Re-index if abstract was added (searchable field changed)
        if result.data.abstract != nil {
            await FullTextSearchService.shared.indexPublication(publication)
        }

        // Notify views that enrichment data is available
        await MainActor.run {
            NotificationCenter.default.post(
                name: .publicationEnrichmentDidComplete,
                object: nil,
                userInfo: ["publicationID": publicationID]
            )
        }
    }

    // MARK: - Delete Operations

    /// Delete a publication
    public func delete(_ publication: CDPublication) async {
        Logger.persistence.info("Deleting publication: \(publication.citeKey)")

        // Capture ID before deletion
        let publicationId = publication.id

        let context = persistenceController.viewContext
        await context.perform {
            context.delete(publication)
            self.persistenceController.save()
        }

        // Remove from search index
        await FullTextSearchService.shared.removePublication(id: publicationId)
    }

    /// Delete multiple publications
    public func delete(_ publications: [CDPublication]) async {
        guard !publications.isEmpty else { return }
        Logger.persistence.info("Deleting \(publications.count) publications")

        // Capture IDs before deletion
        let publicationIds = publications.map { $0.id }

        let context = persistenceController.viewContext
        await context.perform {
            for publication in publications {
                context.delete(publication)
            }
            self.persistenceController.save()
        }

        // Remove from search index
        for id in publicationIds {
            await FullTextSearchService.shared.removePublication(id: id)
        }
    }

    /// Delete publications by their UUIDs
    /// This fetches fresh objects from Core Data and deletes them safely.
    public func deleteByIDs(_ ids: Set<UUID>) async {
        guard !ids.isEmpty else { return }
        Logger.persistence.info("Deleting \(ids.count) publications by ID")

        let context = persistenceController.viewContext

        await context.perform {
            let request = NSFetchRequest<CDPublication>(entityName: "Publication")
            request.predicate = NSPredicate(format: "id IN %@", ids as CVarArg)

            do {
                let publications = try context.fetch(request)
                for publication in publications {
                    context.delete(publication)
                }
                // Process pending changes to ensure isDeleted is set before UI updates
                context.processPendingChanges()
                self.persistenceController.save()
                Logger.persistence.info("Successfully deleted \(publications.count) publications")
            } catch {
                Logger.persistence.error("Failed to fetch publications for deletion: \(error)")
            }
        }

        // Remove from search index
        for id in ids {
            await FullTextSearchService.shared.removePublication(id: id)
        }
    }

    // MARK: - Read Status (Apple Mail Styling)

    /// Mark a publication as read
    public func markAsRead(_ publication: CDPublication) async {
        guard !publication.isRead else { return }
        let context = persistenceController.viewContext

        await context.perform {
            publication.isRead = true
            publication.dateRead = Date()
            self.persistenceController.save()
        }
    }

    /// Mark a publication as unread
    public func markAsUnread(_ publication: CDPublication) async {
        guard publication.isRead else { return }
        let context = persistenceController.viewContext

        await context.perform {
            publication.isRead = false
            publication.dateRead = nil
            self.persistenceController.save()
        }
    }

    /// Toggle read/unread status
    public func toggleReadStatus(_ publication: CDPublication) async {
        if publication.isRead {
            await markAsUnread(publication)
        } else {
            await markAsRead(publication)
        }
    }

    /// Mark multiple publications as read
    public func markAllAsRead(_ publications: [CDPublication]) async {
        let unread = publications.filter { !$0.isRead }
        guard !unread.isEmpty else { return }

        let context = persistenceController.viewContext
        let now = Date()

        await context.perform {
            for publication in unread {
                publication.isRead = true
                publication.dateRead = now
            }
            self.persistenceController.save()
        }
    }

    /// Fetch count of unread publications
    public func unreadCount() async -> Int {
        let context = persistenceController.viewContext

        return await context.perform {
            let request = NSFetchRequest<CDPublication>(entityName: "Publication")
            request.predicate = NSPredicate(format: "isRead == NO")

            return (try? context.count(for: request)) ?? 0
        }
    }

    /// Fetch all unread publications
    public func fetchUnread(sortedBy sortKey: String = "dateAdded", ascending: Bool = false) async -> [CDPublication] {
        let context = persistenceController.viewContext

        return await context.perform {
            let request = NSFetchRequest<CDPublication>(entityName: "Publication")
            request.predicate = NSPredicate(format: "isRead == NO")
            request.sortDescriptors = [NSSortDescriptor(key: sortKey, ascending: ascending)]

            return (try? context.fetch(request)) ?? []
        }
    }

    // MARK: - Export Operations

    /// Export all publications to BibTeX string
    public func exportAll() async -> String {
        let publications = await fetchAll(sortedBy: "citeKey", ascending: true)
        let entries = publications.map { $0.toBibTeXEntry() }

        // Use user's preference for preserving raw BibTeX
        let preserveRaw = await ImportExportSettingsStore.shared.exportPreserveRawBibTeX
        let options = BibTeXExporter.Options(preferRawBibTeX: preserveRaw)

        return BibTeXExporter(options: options).export(entries)
    }

    /// Export selected publications to BibTeX string
    public func export(_ publications: [CDPublication]) async -> String {
        let entries = publications.map { $0.toBibTeXEntry() }

        // Use user's preference for preserving raw BibTeX
        let preserveRaw = await ImportExportSettingsStore.shared.exportPreserveRawBibTeX
        let options = BibTeXExporter.Options(preferRawBibTeX: preserveRaw)

        return BibTeXExporter(options: options).export(entries)
    }

    // MARK: - Deduplication (ADR-016)

    /// Find publication by DOI (normalized to lowercase)
    public func findByDOI(_ doi: String) async -> CDPublication? {
        let normalized = doi.lowercased().trimmingCharacters(in: .whitespaces)
        let context = persistenceController.viewContext

        return await context.perform {
            let request = NSFetchRequest<CDPublication>(entityName: "Publication")
            request.predicate = NSPredicate(format: "doi ==[c] %@", normalized)
            request.fetchLimit = 1

            return try? context.fetch(request).first
        }
    }

    /// Find publication by cite key
    ///
    /// - Parameter citeKey: The BibTeX cite key to search for
    /// - Returns: The publication with the matching cite key, or nil if not found
    public func findByCiteKey(_ citeKey: String) async -> CDPublication? {
        let context = persistenceController.viewContext

        return await context.perform {
            let request = NSFetchRequest<CDPublication>(entityName: "Publication")
            request.predicate = NSPredicate(format: "citeKey == %@", citeKey)
            request.fetchLimit = 1

            return try? context.fetch(request).first
        }
    }

    /// Find publication by arXiv ID (strips version suffix like "v1", "v2")
    ///
    /// Uses indexed `arxivIDNormalized` field for O(1) lookup instead of
    /// scanning rawFields. This is much faster for large libraries.
    public func findByArXiv(_ arxivID: String) async -> CDPublication? {
        // Normalize for O(1) indexed lookup
        let normalizedID = IdentifierExtractor.normalizeArXivID(arxivID)

        let context = persistenceController.viewContext

        return await context.perform {
            let request = NSFetchRequest<CDPublication>(entityName: "Publication")
            // Use indexed arxivIDNormalized field for O(1) lookup
            request.predicate = NSPredicate(format: "arxivIDNormalized == %@", normalizedID)
            request.fetchLimit = 1

            do {
                return try context.fetch(request).first
            } catch {
                return nil
            }
        }
    }

    /// Find publication by ADS bibcode
    ///
    /// Uses indexed `bibcodeNormalized` field for O(1) lookup instead of
    /// scanning rawFields. This is much faster for large libraries.
    public func findByBibcode(_ bibcode: String) async -> CDPublication? {
        let normalized = bibcode.uppercased().trimmingCharacters(in: .whitespaces)
        let context = persistenceController.viewContext

        return await context.perform {
            let request = NSFetchRequest<CDPublication>(entityName: "Publication")
            // Use indexed bibcodeNormalized field for O(1) lookup
            request.predicate = NSPredicate(format: "bibcodeNormalized == %@", normalized)
            request.fetchLimit = 1

            do {
                return try context.fetch(request).first
            } catch {
                return nil
            }
        }
    }

    /// Find publication by Semantic Scholar ID
    public func findBySemanticScholarID(_ id: String) async -> CDPublication? {
        let context = persistenceController.viewContext

        return await context.perform {
            let request = NSFetchRequest<CDPublication>(entityName: "Publication")
            request.predicate = NSPredicate(format: "semanticScholarID == %@", id)
            request.fetchLimit = 1

            return try? context.fetch(request).first
        }
    }

    /// Find publication by OpenAlex ID
    public func findByOpenAlexID(_ id: String) async -> CDPublication? {
        let context = persistenceController.viewContext

        return await context.perform {
            let request = NSFetchRequest<CDPublication>(entityName: "Publication")
            request.predicate = NSPredicate(format: "openAlexID == %@", id)
            request.fetchLimit = 1

            return try? context.fetch(request).first
        }
    }

    /// Find publication by any identifier from a SearchResult
    /// Checks DOI, arXiv ID, and bibcode in priority order
    public func findByIdentifiers(_ result: SearchResult) async -> CDPublication? {
        // Check DOI first (most reliable)
        if let doi = result.doi {
            if let pub = await findByDOI(doi) {
                return pub
            }
        }

        // Check arXiv ID
        if let arxivID = result.arxivID {
            if let pub = await findByArXiv(arxivID) {
                return pub
            }
        }

        // Check bibcode
        if let bibcode = result.bibcode {
            if let pub = await findByBibcode(bibcode) {
                return pub
            }
        }

        // Check Semantic Scholar ID
        if let ssID = result.semanticScholarID {
            if let pub = await findBySemanticScholarID(ssID) {
                return pub
            }
        }

        // Check OpenAlex ID
        if let oaID = result.openAlexID {
            if let pub = await findByOpenAlexID(oaID) {
                return pub
            }
        }

        return nil
    }

    // MARK: - Create from Search Result (ADR-016)

    /// Create a new publication from a SearchResult with online source metadata
    ///
    /// This method creates a CDPublication directly from search result metadata,
    /// without requiring a network fetch for BibTeX. The BibTeX is generated locally.
    ///
    /// - Parameters:
    ///   - result: The search result to create from
    ///   - library: Optional library for file paths
    ///   - abstractOverride: Optional abstract to use instead of result.abstract (for merging from alternates)
    /// - Returns: The created CDPublication
    @discardableResult
    public func createFromSearchResult(_ result: SearchResult, in library: CDLibrary? = nil, abstractOverride: String? = nil) async -> CDPublication {
        Logger.persistence.info("Creating publication from search result: \(result.title)")
        let context = persistenceController.viewContext

        return await context.perform {
            let publication = CDPublication(context: context)
            publication.id = UUID()
            publication.dateAdded = Date()
            publication.dateModified = Date()

            // Generate cite key
            let existingKeys = self.fetchCiteKeysSync(context: context)
            publication.citeKey = self.generateCiteKey(for: result, existingKeys: existingKeys)

            // Set entry type (default to article)
            publication.entryType = "article"

            // Core fields
            publication.title = result.title
            if let year = result.year {
                publication.year = Int16(year)
            }
            // Use abstract override if provided (for merged abstracts from deduplication)
            publication.abstract = abstractOverride ?? result.abstract
            publication.doi = result.doi

            // Build fields dictionary
            var fields: [String: String] = [:]
            if !result.authors.isEmpty {
                fields["author"] = result.authors.joined(separator: " and ")
            }
            if let venue = result.venue {
                fields["journal"] = venue
            }
            if let doi = result.doi {
                fields["doi"] = doi
            }
            if let arxivID = result.arxivID {
                fields["eprint"] = arxivID
                fields["archiveprefix"] = "arXiv"
            }
            if let bibcode = result.bibcode {
                fields["bibcode"] = bibcode
            }
            if let pmid = result.pmid {
                fields["pmid"] = pmid
            }
            publication.fields = fields

            // ADR-016: Online source metadata
            publication.originalSourceID = result.sourceID
            publication.webURL = result.webURL?.absoluteString
            publication.semanticScholarID = result.semanticScholarID
            publication.openAlexID = result.openAlexID

            // Store PDF links as JSON
            if !result.pdfLinks.isEmpty {
                publication.pdfLinks = result.pdfLinks
            }

            // Generate and store BibTeX
            let entry = publication.toBibTeXEntry()
            publication.rawBibTeX = BibTeXExporter().export([entry])

            self.persistenceController.save()
            return publication
        }
    }

    /// Synchronous helper to fetch existing cite keys (must be called from context.perform)
    private func fetchCiteKeysSync(context: NSManagedObjectContext) -> Set<String> {
        let request = NSFetchRequest<CDPublication>(entityName: "Publication")
        request.propertiesToFetch = ["citeKey"]

        do {
            let pubs = try context.fetch(request)
            return Set(pubs.map { $0.citeKey })
        } catch {
            return []
        }
    }

    /// Generate a unique cite key for a search result
    private func generateCiteKey(for result: SearchResult, existingKeys: Set<String>) -> String {
        let lastName = result.firstAuthorLastName ?? "Unknown"
        let yearStr = result.year.map { String($0) } ?? ""

        // Get first significant word from title (>3 chars)
        let titleWord = result.title
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .first { $0.count > 3 } ?? "Paper"

        var candidate = "\(lastName)\(yearStr)\(titleWord)"
        var counter = 0

        while existingKeys.contains(candidate) {
            counter += 1
            candidate = "\(lastName)\(yearStr)\(titleWord)\(counter)"
        }

        return candidate
    }

    /// Add a publication to a collection
    public func addToCollection(_ publication: CDPublication, collection: CDCollection) async {
        let context = persistenceController.viewContext

        await context.perform {
            var pubs = collection.publications ?? []
            pubs.insert(publication)
            collection.publications = pubs

            // Also add to owning library if collection has one
            // This ensures smart collections can find these papers
            if let library = collection.library {
                publication.addToLibrary(library)
            }

            self.persistenceController.save()
        }
    }

    // MARK: - Batch Operations (Performance Optimization)

    /// Find existing publications by identifiers in a single batch query.
    ///
    /// Much more efficient than calling `findByIdentifiers()` in a loop.
    /// Returns a dictionary mapping SearchResult.id to existing CDPublication.
    ///
    /// - Parameter results: Search results to check for existing publications
    /// - Returns: Dictionary mapping result IDs to existing publications
    public func findExistingByIdentifiers(_ results: [SearchResult]) async -> [String: CDPublication] {
        guard !results.isEmpty else { return [:] }

        let context = persistenceController.viewContext

        return await context.perform {
            var existing: [String: CDPublication] = [:]

            // Collect all identifiers for batch query
            let dois = results.compactMap { $0.doi }.filter { !$0.isEmpty }
            let arxivIDs = results.compactMap { $0.arxivID }.filter { !$0.isEmpty }
            let bibcodes = results.compactMap { $0.bibcode }.filter { !$0.isEmpty }
            let ssIDs = results.compactMap { $0.semanticScholarID }.filter { !$0.isEmpty }
            let oaIDs = results.compactMap { $0.openAlexID }.filter { !$0.isEmpty }

            // Build compound predicate for all identifiers
            var predicates: [NSPredicate] = []

            if !dois.isEmpty {
                predicates.append(NSPredicate(format: "doi IN[c] %@", dois))
            }
            if !arxivIDs.isEmpty {
                // Normalize arXiv IDs for lookup
                let normalizedArxivs = arxivIDs.map { IdentifierExtractor.normalizeArXivID($0) }
                predicates.append(NSPredicate(format: "arxivIDNormalized IN %@", normalizedArxivs))
            }
            if !bibcodes.isEmpty {
                let normalizedBibcodes = bibcodes.map { $0.uppercased().trimmingCharacters(in: .whitespaces) }
                predicates.append(NSPredicate(format: "bibcodeNormalized IN %@", normalizedBibcodes))
            }
            if !ssIDs.isEmpty {
                predicates.append(NSPredicate(format: "semanticScholarID IN %@", ssIDs))
            }
            if !oaIDs.isEmpty {
                predicates.append(NSPredicate(format: "openAlexID IN %@", oaIDs))
            }

            guard !predicates.isEmpty else { return [:] }

            let request = NSFetchRequest<CDPublication>(entityName: "Publication")
            request.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: predicates)

            do {
                let found = try context.fetch(request)

                // Build lookup dictionaries from found publications for O(1) matching
                // This ensures each result maps to at most ONE publication
                var pubsByDOI: [String: CDPublication] = [:]
                var pubsByArxiv: [String: CDPublication] = [:]
                var pubsByBibcode: [String: CDPublication] = [:]
                var pubsBySS: [String: CDPublication] = [:]
                var pubsByOA: [String: CDPublication] = [:]

                for pub in found {
                    if let doi = pub.doi, !doi.isEmpty {
                        pubsByDOI[doi.lowercased()] = pub
                    }
                    if let arxiv = pub.arxivIDNormalized, !arxiv.isEmpty {
                        pubsByArxiv[arxiv] = pub
                    }
                    if let bibcode = pub.bibcodeNormalized, !bibcode.isEmpty {
                        pubsByBibcode[bibcode] = pub
                    }
                    if let ssID = pub.semanticScholarID, !ssID.isEmpty {
                        pubsBySS[ssID] = pub
                    }
                    if let oaID = pub.openAlexID, !oaID.isEmpty {
                        pubsByOA[oaID] = pub
                    }
                }

                // Track match statistics for diagnostics
                var matchesByDOI = 0
                var matchesByArxiv = 0
                var matchesByBibcode = 0
                var matchesBySS = 0
                var matchesByOA = 0

                // Match each result exactly once using dictionary lookups
                for result in results {
                    // Skip if already matched (prevents double-counting)
                    if existing[result.id] != nil { continue }

                    // Check each identifier type in priority order
                    if let doi = result.doi, !doi.isEmpty,
                       let pub = pubsByDOI[doi.lowercased()] {
                        existing[result.id] = pub
                        matchesByDOI += 1
                        continue
                    }
                    if let arxiv = result.arxivID, !arxiv.isEmpty,
                       let pub = pubsByArxiv[IdentifierExtractor.normalizeArXivID(arxiv)] {
                        existing[result.id] = pub
                        matchesByArxiv += 1
                        continue
                    }
                    if let bibcode = result.bibcode, !bibcode.isEmpty,
                       let pub = pubsByBibcode[bibcode.uppercased().trimmingCharacters(in: .whitespaces)] {
                        existing[result.id] = pub
                        matchesByBibcode += 1
                        continue
                    }
                    if let ssID = result.semanticScholarID, !ssID.isEmpty,
                       let pub = pubsBySS[ssID] {
                        existing[result.id] = pub
                        matchesBySS += 1
                        continue
                    }
                    if let oaID = result.openAlexID, !oaID.isEmpty,
                       let pub = pubsByOA[oaID] {
                        existing[result.id] = pub
                        matchesByOA += 1
                        continue
                    }
                }

                // Log unmatched results for debugging
                let unmatchedCount = results.count - existing.count
                if unmatchedCount > 0 {
                    let unmatchedSample = results.filter { existing[$0.id] == nil }.prefix(5)
                    let sampleIDs = unmatchedSample.map { $0.arxivID ?? $0.id }.joined(separator: ", ")
                    Logger.persistence.infoCapture(
                        "Batch find: \(unmatchedCount) unmatched results, sample: \(sampleIDs)",
                        category: "batch"
                    )
                }


                Logger.persistence.debugCapture(
                    "Batch find: \(results.count) results → \(found.count) DB → \(existing.count) mapped " +
                    "(DOI:\(matchesByDOI) arXiv:\(matchesByArxiv) bibcode:\(matchesByBibcode) SS:\(matchesBySS) OA:\(matchesByOA))",
                    category: "batch"
                )
            } catch {
                Logger.persistence.errorCapture("Batch find failed: \(error.localizedDescription)", category: "batch")
            }

            return existing
        }
    }

    /// Create multiple publications from search results in a single batch.
    ///
    /// Much more efficient than calling `createFromSearchResult()` in a loop.
    /// Performs a single Core Data save for all entries.
    ///
    /// - Parameters:
    ///   - results: Search results to create publications from
    ///   - collection: Optional collection to add all publications to
    /// - Returns: Array of created CDPublication entities
    @discardableResult
    public func createFromSearchResults(
        _ results: [SearchResult],
        collection: CDCollection? = nil
    ) async -> [CDPublication] {
        guard !results.isEmpty else { return [] }

        Logger.persistence.infoCapture("Batch creating \(results.count) publications", category: "batch")
        let context = persistenceController.viewContext

        return await context.perform {
            // Fetch existing cite keys once for uniqueness check
            let existingKeys = self.fetchCiteKeysSync(context: context)
            var usedKeys = existingKeys
            var created: [CDPublication] = []

            for result in results {
                let publication = CDPublication(context: context)
                publication.id = UUID()
                publication.dateAdded = Date()
                publication.dateModified = Date()

                // Generate unique cite key
                let citeKey = self.generateCiteKey(for: result, existingKeys: usedKeys)
                publication.citeKey = citeKey
                usedKeys.insert(citeKey)

                // Set entry type (default to article)
                publication.entryType = "article"

                // Core fields
                publication.title = result.title
                if let year = result.year {
                    publication.year = Int16(year)
                }
                publication.abstract = result.abstract
                publication.doi = result.doi

                // Build fields dictionary
                var fields: [String: String] = [:]
                if !result.authors.isEmpty {
                    fields["author"] = result.authors.joined(separator: " and ")
                }
                if let venue = result.venue {
                    fields["journal"] = venue
                }
                if let doi = result.doi {
                    fields["doi"] = doi
                }
                if let arxivID = result.arxivID {
                    fields["eprint"] = arxivID
                    fields["archiveprefix"] = "arXiv"
                }
                if let bibcode = result.bibcode {
                    fields["bibcode"] = bibcode
                }
                if let pmid = result.pmid {
                    fields["pmid"] = pmid
                }
                publication.fields = fields

                // ADR-016: Online source metadata
                publication.originalSourceID = result.sourceID
                publication.webURL = result.webURL?.absoluteString
                publication.semanticScholarID = result.semanticScholarID
                publication.openAlexID = result.openAlexID

                // Store PDF links as JSON
                if !result.pdfLinks.isEmpty {
                    publication.pdfLinks = result.pdfLinks
                }

                // Generate and store BibTeX
                let entry = publication.toBibTeXEntry()
                publication.rawBibTeX = BibTeXExporter().export([entry])

                // Add to collection if provided (no save yet)
                if let collection {
                    publication.addToCollection(collection)
                }

                created.append(publication)
            }

            // Single save for all entries
            self.persistenceController.save()

            Logger.persistence.infoCapture(
                "Batch created \(created.count) publications (single save)",
                category: "batch"
            )

            return created
        }
    }

    /// Add multiple publications to a collection in a single batch.
    ///
    /// Much more efficient than calling `addToCollection()` in a loop.
    /// Performs a single Core Data save for all entries.
    ///
    /// - Parameters:
    ///   - publications: Publications to add
    ///   - collection: Collection to add them to
    public func addToCollection(_ publications: [CDPublication], collection: CDCollection) async {
        guard !publications.isEmpty else { return }

        let context = persistenceController.viewContext

        await context.perform {
            // Also add to owning library if collection has one
            // This ensures smart collections can find these papers
            let library = collection.library

            for pub in publications {
                pub.addToCollection(collection)
                if let library = library {
                    pub.addToLibrary(library)
                }
            }

            // Single save for all additions
            self.persistenceController.save()

            Logger.persistence.debugCapture(
                "Batch added \(publications.count) publications to collection '\(collection.name ?? "unnamed")'",
                category: "batch"
            )
        }
    }

    // MARK: - RIS Import Operations

    /// Create a new publication from RIS entry
    ///
    /// Converts the RIS entry to BibTeX internally for storage.
    ///
    /// - Parameters:
    ///   - entry: The RIS entry to create from
    ///   - library: Optional library for resolving file paths
    @discardableResult
    public func create(from entry: RISEntry, in library: CDLibrary? = nil) async -> CDPublication {
        // Convert RIS to BibTeX for storage
        let bibtexEntry = RISBibTeXConverter.toBibTeX(entry)
        Logger.persistence.info("Creating publication from RIS: \(bibtexEntry.citeKey)")
        return await create(from: bibtexEntry, in: library, processLinkedFiles: false)
    }

    /// Import multiple RIS entries
    ///
    /// - Parameters:
    ///   - entries: RIS entries to import
    ///   - library: Optional library for resolving file paths
    public func importRISEntries(_ entries: [RISEntry], in library: CDLibrary? = nil) async -> Int {
        Logger.persistence.info("Importing \(entries.count) RIS entries")

        var imported = 0
        for entry in entries {
            // Convert to BibTeX to get cite key
            let bibtexEntry = RISBibTeXConverter.toBibTeX(entry)

            // Check for duplicate
            if await fetch(byCiteKey: bibtexEntry.citeKey) == nil {
                await create(from: entry, in: library)
                imported += 1
            } else {
                Logger.persistence.debug("Skipping duplicate: \(bibtexEntry.citeKey)")
            }
        }

        Logger.persistence.info("Imported \(imported) new RIS entries")
        return imported
    }

    /// Import RIS content from string
    ///
    /// - Parameters:
    ///   - content: RIS formatted string
    ///   - library: Optional library for resolving file paths
    /// - Returns: Number of entries imported
    public func importRIS(_ content: String, in library: CDLibrary? = nil) async throws -> Int {
        let parser = RISParserFactory.createParser()
        let entries = try parser.parse(content)
        return await importRISEntries(entries, in: library)
    }

    /// Import RIS file from URL
    ///
    /// - Parameters:
    ///   - url: URL to the .ris file
    ///   - library: Optional library for resolving file paths
    /// - Returns: Number of entries imported
    public func importRISFile(at url: URL, in library: CDLibrary? = nil) async throws -> Int {
        Logger.persistence.info("Importing RIS file: \(url.lastPathComponent)")
        let content = try String(contentsOf: url, encoding: .utf8)
        return try await importRIS(content, in: library)
    }

    // MARK: - RIS Export Operations

    /// Export all publications to RIS string
    public func exportAllToRIS() async -> String {
        let publications = await fetchAll(sortedBy: "citeKey", ascending: true)
        return exportToRIS(publications)
    }

    /// Export selected publications to RIS string
    public func exportToRIS(_ publications: [CDPublication]) -> String {
        let bibtexEntries = publications.map { $0.toBibTeXEntry() }
        let risEntries = RISBibTeXConverter.toRIS(bibtexEntries)
        return RISExporter().export(risEntries)
    }

    // MARK: - Move and Collection Operations

    /// Add publications to a static collection
    public func addPublications(_ publications: [CDPublication], to collection: CDCollection) async {
        guard !collection.isSmartCollection else { return }
        let context = persistenceController.viewContext

        await context.perform {
            var current = collection.publications ?? []
            for pub in publications {
                current.insert(pub)
            }
            collection.publications = current

            // Also add to owning library if collection has one
            // This ensures smart collections can find these papers
            if let library = collection.library {
                for pub in publications {
                    pub.addToLibrary(library)
                }
            }

            self.persistenceController.save()
        }
    }

    /// Add publications to a library (publications can belong to multiple libraries)
    ///
    /// When adding to a non-Inbox library, posts `.publicationKeptToLibrary`
    /// notification to trigger auto-removal from Inbox.
    public func addToLibrary(_ publications: [CDPublication], library: CDLibrary) async {
        let context = persistenceController.viewContext
        let isInboxLibrary = library.isInbox

        await context.perform {
            for publication in publications {
                publication.addToLibrary(library)
            }
            self.persistenceController.save()
        }

        // Post notification for Inbox auto-remove (only for non-Inbox libraries)
        if !isInboxLibrary {
            await MainActor.run {
                for publication in publications {
                    NotificationCenter.default.post(
                        name: .publicationSavedToLibrary,
                        object: publication
                    )
                }
            }
        }
    }

    /// Remove publications from a library
    public func removeFromLibrary(_ publications: [CDPublication], library: CDLibrary) async {
        let context = persistenceController.viewContext

        await context.perform {
            for publication in publications {
                publication.removeFromLibrary(library)
            }
            self.persistenceController.save()
        }
    }

    /// Remove publications from all collections (return to "All Publications")
    public func removeFromAllCollections(_ publications: [CDPublication]) async {
        let context = persistenceController.viewContext

        await context.perform {
            for publication in publications {
                publication.removeFromAllCollections()
            }
            self.persistenceController.save()
        }
    }

    // MARK: - Smart Collection Execution

    /// Execute a smart collection query and return matching publications
    ///
    /// Smart collections are scoped to their parent library if they have one.
    public func executeSmartCollection(_ collection: CDCollection) async -> [CDPublication] {
        guard collection.isSmartCollection,
              let predicateString = collection.predicate,
              !predicateString.isEmpty else {
            // For static collections or empty predicate, return the assigned publications
            Logger.persistence.debug("Smart collection '\(collection.name)' - not smart or empty predicate, returning \(collection.publications?.count ?? 0) direct publications")
            return Array(collection.publications ?? [])
        }

        Logger.persistence.info("Executing smart collection: '\(collection.name)' with predicate: \(predicateString)")
        let context = persistenceController.viewContext
        let library = collection.library

        return await context.perform {
            let request = NSFetchRequest<CDPublication>(entityName: "Publication")

            // Build compound predicate: user's rules AND library membership
            var predicates: [NSPredicate] = []

            // Add user's smart collection predicate
            predicates.append(NSPredicate(format: predicateString))

            // Scope to owning library if present
            if let library = library {
                predicates.append(NSPredicate(format: "ANY libraries == %@", library))
                Logger.persistence.debug("Scoping to library: \(library.name)")
            } else {
                Logger.persistence.debug("No library scope - searching all publications")
            }

            let compoundPredicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            request.predicate = compoundPredicate
            request.sortDescriptors = [NSSortDescriptor(key: "dateModified", ascending: false)]

            Logger.persistence.debug("Final predicate: \(compoundPredicate)")

            do {
                let results = try context.fetch(request)
                Logger.persistence.info("Smart collection '\(collection.name)' returned \(results.count) results")

                // Debug: Log year values for all publications in the library
                if let library = library {
                    let allInLibrary = NSFetchRequest<CDPublication>(entityName: "Publication")
                    allInLibrary.predicate = NSPredicate(format: "ANY libraries == %@", library)
                    if let allPubs = try? context.fetch(allInLibrary) {
                        let yearCounts = Dictionary(grouping: allPubs, by: { $0.year })
                            .mapValues { $0.count }
                            .sorted { $0.key < $1.key }
                        Logger.persistence.info("📊 Year distribution in '\(library.name)': \(yearCounts.map { "year=\($0.key): \($0.value)" }.joined(separator: ", "))")

                        // Check rawFields for year
                        let withRawFieldsYear = allPubs.filter { $0.fields["year"] != nil }.count
                        Logger.persistence.info("📊 Publications with year in rawFields: \(withRawFieldsYear)/\(allPubs.count)")
                    }
                }

                return results
            } catch {
                Logger.persistence.error("Smart collection query failed: \(error.localizedDescription)")
                return []
            }
        }
    }
}

// MARK: - Tag Repository

public actor TagRepository {

    private let persistenceController: PersistenceController

    public init(persistenceController: PersistenceController = .shared) {
        self.persistenceController = persistenceController
    }

    /// Fetch all tags
    public func fetchAll() async -> [CDTag] {
        let context = persistenceController.viewContext

        return await context.perform {
            let request = NSFetchRequest<CDTag>(entityName: "Tag")
            request.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]

            return (try? context.fetch(request)) ?? []
        }
    }

    /// Create or find tag by name
    public func findOrCreate(name: String) async -> CDTag {
        let context = persistenceController.viewContext

        return await context.perform {
            let request = NSFetchRequest<CDTag>(entityName: "Tag")
            request.predicate = NSPredicate(format: "name ==[cd] %@", name)
            request.fetchLimit = 1

            if let existing = try? context.fetch(request).first {
                return existing
            }

            let tag = CDTag(context: context)
            tag.id = UUID()
            tag.name = name
            self.persistenceController.save()
            return tag
        }
    }
}

// MARK: - Collection Repository

public actor CollectionRepository {

    private let persistenceController: PersistenceController

    public init(persistenceController: PersistenceController = .shared) {
        self.persistenceController = persistenceController
    }

    /// Fetch all collections
    public func fetchAll() async -> [CDCollection] {
        let context = persistenceController.viewContext

        return await context.perform {
            let request = NSFetchRequest<CDCollection>(entityName: "Collection")
            request.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]

            return (try? context.fetch(request)) ?? []
        }
    }

    /// Fetch only smart collections
    public func fetchSmartCollections() async -> [CDCollection] {
        let context = persistenceController.viewContext

        return await context.perform {
            let request = NSFetchRequest<CDCollection>(entityName: "Collection")
            request.predicate = NSPredicate(format: "isSmartCollection == YES")
            request.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]

            return (try? context.fetch(request)) ?? []
        }
    }

    /// Fetch only static collections
    public func fetchStaticCollections() async -> [CDCollection] {
        let context = persistenceController.viewContext

        return await context.perform {
            let request = NSFetchRequest<CDCollection>(entityName: "Collection")
            request.predicate = NSPredicate(format: "isSmartCollection == NO")
            request.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]

            return (try? context.fetch(request)) ?? []
        }
    }

    /// Create a new collection
    @discardableResult
    public func create(name: String, isSmartCollection: Bool = false, predicate: String? = nil) async -> CDCollection {
        Logger.persistence.info("Creating collection: \(name) (smart: \(isSmartCollection))")
        let context = persistenceController.viewContext

        return await context.perform {
            let collection = CDCollection(context: context)
            collection.id = UUID()
            collection.name = name
            collection.isSmartCollection = isSmartCollection
            collection.predicate = predicate
            self.persistenceController.save()
            return collection
        }
    }

    /// Update a collection
    public func update(_ collection: CDCollection, name: String? = nil, predicate: String? = nil) async {
        Logger.persistence.info("Updating collection: \(collection.name)")
        let context = persistenceController.viewContext

        await context.perform {
            if let name = name {
                collection.name = name
            }
            if collection.isSmartCollection {
                collection.predicate = predicate
            }
            self.persistenceController.save()
        }
    }

    /// Delete a collection
    public func delete(_ collection: CDCollection) async {
        Logger.persistence.info("Deleting collection: \(collection.name)")
        let context = persistenceController.viewContext

        await context.perform {
            context.delete(collection)
            self.persistenceController.save()
        }
    }

    /// Execute a smart collection query
    public func executeSmartCollection(_ collection: CDCollection) async -> [CDPublication] {
        guard collection.isSmartCollection,
              let predicateString = collection.predicate,
              !predicateString.isEmpty else {
            // For static collections or empty predicate, return the assigned publications
            return Array(collection.publications ?? [])
        }

        Logger.persistence.debug("Executing smart collection: \(collection.name)")
        let context = persistenceController.viewContext
        let library = collection.library

        return await context.perform {
            let request = NSFetchRequest<CDPublication>(entityName: "Publication")

            // Build compound predicate: user's rules AND library membership
            var predicates: [NSPredicate] = []

            // Add user's smart collection predicate
            predicates.append(NSPredicate(format: predicateString))

            // Scope to owning library if present
            if let library = library {
                predicates.append(NSPredicate(format: "ANY libraries == %@", library))
            }

            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            request.sortDescriptors = [NSSortDescriptor(key: "dateModified", ascending: false)]

            do {
                return try context.fetch(request)
            } catch {
                Logger.persistence.error("Smart collection query failed: \(error.localizedDescription)")
                return []
            }
        }
    }

    /// Add publications to a static collection
    public func addPublications(_ publications: [CDPublication], to collection: CDCollection) async {
        guard !collection.isSmartCollection else { return }
        let context = persistenceController.viewContext

        await context.perform {
            var current = collection.publications ?? []
            for pub in publications {
                current.insert(pub)
            }
            collection.publications = current

            // Also add to owning library if collection has one
            // This ensures smart collections can find these papers
            if let library = collection.library {
                for pub in publications {
                    pub.addToLibrary(library)
                }
            }

            self.persistenceController.save()
        }
    }

    /// Remove publications from a static collection
    public func removePublications(_ publications: [CDPublication], from collection: CDCollection) async {
        guard !collection.isSmartCollection else { return }
        let context = persistenceController.viewContext

        await context.perform {
            var current = collection.publications ?? []
            for pub in publications {
                current.remove(pub)
            }
            collection.publications = current
            self.persistenceController.save()
        }
    }
}
