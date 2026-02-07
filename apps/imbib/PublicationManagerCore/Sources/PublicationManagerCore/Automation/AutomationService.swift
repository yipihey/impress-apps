//
//  AutomationService.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-16.
//
//  Actor implementing AutomationOperations protocol (ADR-018).
//  Calls PublicationRepository and SourceManager directly for rich data returns.
//

import Foundation
import OSLog
import CoreData
import ImpressFTUI
#if canImport(CloudKit)
import CloudKit
#endif
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

private let logger = Logger(subsystem: "com.imbib.app", category: "automationService")

// MARK: - Automation Service

/// Main implementation of AutomationOperations.
///
/// This actor provides the core automation functionality, calling repositories
/// and source managers directly to return rich data types.
///
/// Unlike URLSchemeHandler (which posts notifications for UI updates),
/// AutomationService returns actual data for programmatic consumption by:
/// - MCP server (Claude Desktop, Cursor)
/// - Enhanced AppIntents
/// - REST API
/// - CLI tools
public actor AutomationService: AutomationOperations {

    // MARK: - Singleton

    public static let shared = AutomationService()

    // MARK: - Dependencies

    private let repository: PublicationRepository
    private let collectionRepository: CollectionRepository
    private var sourceManager: SourceManager
    private let settingsStore: AutomationSettingsStore

    // MARK: - Initialization

    public init(
        repository: PublicationRepository = PublicationRepository(),
        collectionRepository: CollectionRepository = CollectionRepository(),
        sourceManager: SourceManager = SourceManager(),
        settingsStore: AutomationSettingsStore = .shared
    ) {
        self.repository = repository
        self.collectionRepository = collectionRepository
        self.sourceManager = sourceManager
        self.settingsStore = settingsStore
    }

    /// Configure with the app's shared SourceManager (which has plugins registered).
    public func configure(sourceManager: SourceManager) {
        self.sourceManager = sourceManager
    }

    // MARK: - Authorization Check

    private func checkAuthorization() async throws {
        let isEnabled = await settingsStore.isEnabled
        guard isEnabled else {
            throw AutomationOperationError.unauthorized
        }
    }

    // MARK: - External Source Search

    /// Search external sources (ADS, arXiv, Crossref, etc.) by topic or keywords.
    /// Returns search results with identifiers that can be passed to `addPapers()`.
    public func searchExternal(query: String, source: String?, maxResults: Int) async throws -> [ExternalSearchResult] {
        try await checkAuthorization()
        logger.info("Searching external sources for: \(query) (source: \(source ?? "all"))")

        let results: [SearchResult]
        if let sourceID = source {
            results = try await sourceManager.search(query: query, sourceID: sourceID, maxResults: maxResults)
        } else {
            // Search all available sources in parallel
            let options = SearchOptions(maxResults: maxResults)
            results = try await sourceManager.search(query: query, options: options)
        }

        return results.map { result in
            ExternalSearchResult(
                title: result.title,
                authors: result.authors,
                year: result.year,
                venue: result.venue ?? "",
                abstract: result.abstract ?? "",
                sourceID: result.sourceID,
                doi: result.doi,
                arxivID: result.arxivID,
                bibcode: result.bibcode
            )
        }
    }

    // MARK: - Library Search

    public func searchLibrary(query: String, filters: SearchFilters?) async throws -> [PaperResult] {
        try await checkAuthorization()
        logger.info("Searching library for: \(query)")

        let publications: [CDPublication]
        if query.isEmpty {
            publications = await repository.fetchAll()
        } else {
            publications = await repository.search(query: query)
        }

        // Apply filters
        var filtered = publications
        if let filters = filters {
            filtered = applyFilters(to: filtered, filters: filters)
        }

        // Apply limit/offset
        if let offset = filters?.offset, offset > 0 {
            filtered = Array(filtered.dropFirst(offset))
        }
        if let limit = filters?.limit {
            filtered = Array(filtered.prefix(limit))
        }

        return filtered.compactMap { toPaperResult($0) }
    }

    private func applyFilters(to publications: [CDPublication], filters: SearchFilters) -> [CDPublication] {
        var result = publications

        if let yearFrom = filters.yearFrom {
            result = result.filter { $0.year >= Int16(yearFrom) }
        }
        if let yearTo = filters.yearTo {
            result = result.filter { $0.year <= Int16(yearTo) }
        }
        if let isRead = filters.isRead {
            result = result.filter { $0.isRead == isRead }
        }
        if let hasLocalPDF = filters.hasLocalPDF {
            result = result.filter { $0.hasPDFDownloaded == hasLocalPDF }
        }
        if let authors = filters.authors, !authors.isEmpty {
            result = result.filter { pub in
                let pubAuthors = pub.authorString.lowercased()
                return authors.contains { pubAuthors.contains($0.lowercased()) }
            }
        }
        if let libraries = filters.libraries, !libraries.isEmpty {
            result = result.filter { pub in
                guard let pubLibraries = pub.libraries else { return false }
                return pubLibraries.contains { libraries.contains($0.id) }
            }
        }
        if let collections = filters.collections, !collections.isEmpty {
            result = result.filter { pub in
                guard let pubCollections = pub.collections else { return false }
                return pubCollections.contains { collections.contains($0.id) }
            }
        }
        if let tags = filters.tags, !tags.isEmpty {
            result = result.filter { pub in
                guard let pubTags = pub.tags else { return false }
                let pubTagPaths = Set(pubTags.compactMap { $0.canonicalPath })
                return tags.contains { pubTagPaths.contains($0) }
            }
        }
        if let flagColor = filters.flagColor {
            result = result.filter { $0.flagColor == flagColor }
        }
        if let addedAfter = filters.addedAfter {
            result = result.filter { $0.dateAdded > addedAfter }
        }
        if let addedBefore = filters.addedBefore {
            result = result.filter { $0.dateAdded < addedBefore }
        }

        return result
    }

    // MARK: - External Search

    public func searchExternal(sources: [String]?, query: String, maxResults: Int?) async throws -> SearchOperationResult {
        try await checkAuthorization()
        logger.info("External search: \(query) from sources: \(sources?.joined(separator: ", ") ?? "all")")

        let options = SearchOptions(
            maxResults: maxResults ?? 50,
            sourceIDs: sources
        )

        let results = try await sourceManager.search(query: query, options: options)

        // Get actual source IDs used
        let actualSources: [String]
        if let sources = sources {
            actualSources = sources
        } else {
            actualSources = await sourceManager.availableSources.map { $0.id }
        }

        // Convert SearchResult to PaperResult
        let papers = results.map { searchResultToPaperResult($0) }

        return SearchOperationResult(
            papers: papers,
            totalCount: papers.count,
            hasMore: papers.count >= (maxResults ?? 50),
            sources: actualSources
        )
    }

    private func searchResultToPaperResult(_ result: SearchResult) -> PaperResult {
        PaperResult(
            id: UUID(),  // Generate new UUID for external results
            citeKey: generateCiteKey(for: result),
            title: result.title,
            authors: result.authors,
            year: result.year,
            venue: result.venue,
            abstract: result.abstract,
            doi: result.doi,
            arxivID: result.arxivID,
            bibcode: result.bibcode,
            pmid: result.pmid,
            semanticScholarID: result.semanticScholarID,
            openAlexID: result.openAlexID,
            isRead: false,
            isStarred: false,
            hasPDF: !result.pdfLinks.isEmpty,
            citationCount: nil,
            dateAdded: Date(),
            dateModified: Date(),
            bibtex: "",  // Not generated for search results
            webURL: result.webURL?.absoluteString,
            pdfURLs: result.pdfLinks.map { $0.url.absoluteString }
        )
    }

    private func generateCiteKey(for result: SearchResult) -> String {
        let lastName = result.firstAuthorLastName ?? "Unknown"
        let yearStr = result.year.map { String($0) } ?? ""
        let titleWord = result.title
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .first { $0.count > 3 } ?? "Paper"
        return "\(lastName)\(yearStr)\(titleWord)"
    }

    // MARK: - Paper Operations

    public func getPaper(identifier: PaperIdentifier) async throws -> PaperResult? {
        try await checkAuthorization()

        let publication = await findPublication(by: identifier)
        return publication.flatMap { toPaperResult($0) }
    }

    public func getPapers(identifiers: [PaperIdentifier]) async throws -> [PaperResult] {
        try await checkAuthorization()

        var results: [PaperResult] = []
        for id in identifiers {
            if let pub = await findPublication(by: id),
               let result = toPaperResult(pub) {
                results.append(result)
            }
        }
        return results
    }

    private func findPublication(by identifier: PaperIdentifier) async -> CDPublication? {
        switch identifier {
        case .citeKey(let key):
            return await repository.fetch(byCiteKey: key)
        case .doi(let doi):
            return await repository.findByDOI(doi)
        case .arxiv(let id):
            return await repository.findByArXiv(id)
        case .bibcode(let code):
            return await repository.findByBibcode(code)
        case .uuid(let uuid):
            return await repository.fetch(byID: uuid)
        case .pmid:
            // PMID lookup not yet implemented in repository
            return nil
        case .semanticScholar(let id):
            return await repository.findBySemanticScholarID(id)
        case .openAlex(let id):
            return await repository.findByOpenAlexID(id)
        }
    }

    public func addPapers(
        identifiers: [PaperIdentifier],
        collection: UUID?,
        library: UUID?,
        downloadPDFs: Bool
    ) async throws -> AddPapersResult {
        try await checkAuthorization()
        logger.info("Adding \(identifiers.count) papers")

        var added: [PaperResult] = []
        var duplicates: [String] = []
        var failed: [String: String] = [:]

        // Collect existing publications that need library/collection assignment
        var existingToAssign: [CDPublication] = []

        for identifier in identifiers {
            // Check if already exists
            if let existing = await findPublication(by: identifier) {
                duplicates.append(identifier.value)
                existingToAssign.append(existing)
                logger.debug("Duplicate found for: \(identifier.value)")
                continue
            }

            do {
                // Try to fetch from external source based on identifier type
                let searchResult = try await fetchFromExternal(identifier: identifier)

                // Create publication from search result
                let publication = await repository.createFromSearchResult(searchResult)

                // Add to library if specified
                if let libraryID = library {
                    await assignToLibrary([publication], libraryID: libraryID)
                }

                // Add to collection if specified
                if let collectionID = collection {
                    await assignToCollection([publication], collectionID: collectionID)
                }

                // Download PDF if requested
                if downloadPDFs && !searchResult.pdfLinks.isEmpty {
                    // Queue PDF download (actual download handled by PDFManager)
                    await MainActor.run {
                        NotificationCenter.default.post(
                            name: .downloadPDF,
                            object: nil,
                            userInfo: ["publicationID": publication.id]
                        )
                    }
                }

                if let result = toPaperResult(publication) {
                    added.append(result)
                }

            } catch {
                failed[identifier.value] = error.localizedDescription
                logger.error("Failed to add paper \(identifier.value): \(error.localizedDescription)")
            }
        }

        // Assign existing (duplicate) papers to target library/collection
        if !existingToAssign.isEmpty {
            if let libraryID = library {
                await assignToLibrary(existingToAssign, libraryID: libraryID)
            }
            if let collectionID = collection {
                await assignToCollection(existingToAssign, collectionID: collectionID)
            }
        }

        return AddPapersResult(added: added, duplicates: duplicates, failed: failed)
    }

    // MARK: - Add to Library / Collection

    /// Add existing papers to a library by identifier.
    public func addPapersToLibrary(
        identifiers: [PaperIdentifier],
        libraryID: UUID
    ) async throws -> AddToContainerResult {
        try await checkAuthorization()
        var assigned: [String] = []
        var notFound: [String] = []

        for identifier in identifiers {
            if let pub = await findPublication(by: identifier) {
                await assignToLibrary([pub], libraryID: libraryID)
                assigned.append(identifier.value)
            } else {
                notFound.append(identifier.value)
            }
        }
        return AddToContainerResult(assigned: assigned, notFound: notFound)
    }

    /// Add existing papers to a collection by identifier.
    public func addPapersToCollection(
        identifiers: [PaperIdentifier],
        collectionID: UUID
    ) async throws -> AddToContainerResult {
        try await checkAuthorization()
        var assigned: [String] = []
        var notFound: [String] = []

        for identifier in identifiers {
            if let pub = await findPublication(by: identifier) {
                await assignToCollection([pub], collectionID: collectionID)
                assigned.append(identifier.value)
            } else {
                notFound.append(identifier.value)
            }
        }
        return AddToContainerResult(assigned: assigned, notFound: notFound)
    }

    /// Assign publications to a library by UUID.
    /// Uses the repository's addToLibrary which handles mutableSetValue
    /// and posts .publicationSavedToLibrary for UI refresh.
    private func assignToLibrary(_ publications: [CDPublication], libraryID: UUID) async {
        let context = PersistenceController.shared.viewContext
        let library: CDLibrary? = await context.perform {
            let request = NSFetchRequest<CDLibrary>(entityName: "Library")
            request.predicate = NSPredicate(format: "id == %@", libraryID as CVarArg)
            request.fetchLimit = 1
            return try? context.fetch(request).first
        }
        guard let library else { return }
        await repository.addToLibrary(publications, library: library)
    }

    /// Assign publications to a collection by UUID.
    /// Uses the repository's addPublications(to:) which handles
    /// mutableSetValue and proper Core Data change tracking.
    private func assignToCollection(_ publications: [CDPublication], collectionID: UUID) async {
        let context = PersistenceController.shared.viewContext
        let collection: CDCollection? = await context.perform {
            let request = NSFetchRequest<CDCollection>(entityName: "Collection")
            request.predicate = NSPredicate(format: "id == %@", collectionID as CVarArg)
            request.fetchLimit = 1
            return try? context.fetch(request).first
        }
        guard let collection else { return }
        await repository.addPublications(publications, to: collection)
    }

    private func fetchFromExternal(identifier: PaperIdentifier) async throws -> SearchResult {
        // Build source-specific queries using each source's native identifier syntax.
        // ADS uses field-qualified queries (bibcode:X, doi:"X", identifier:X).
        // arXiv uses id: prefix. Crossref handles DOIs natively.
        struct SourceQuery {
            let sourceID: String
            let query: String
        }

        let queries: [SourceQuery]

        switch identifier {
        case .doi(let doi):
            queries = [
                SourceQuery(sourceID: "crossref", query: doi),
                SourceQuery(sourceID: "ads", query: "doi:\"\(doi)\""),
            ]
        case .arxiv(let id):
            queries = [
                SourceQuery(sourceID: "arxiv", query: "id:\(id)"),
                SourceQuery(sourceID: "ads", query: "identifier:\(id)"),
            ]
        case .bibcode(let code):
            queries = [
                SourceQuery(sourceID: "ads", query: "bibcode:\(code)"),
            ]
        case .pmid(let id):
            queries = [
                SourceQuery(sourceID: "pubmed", query: id),
            ]
        default:
            throw AutomationOperationError.invalidIdentifier("Cannot fetch \(identifier.typeName) from external sources")
        }

        // Try each source in order until one returns a result
        for sq in queries {
            do {
                let results = try await sourceManager.search(
                    query: sq.query,
                    sourceID: sq.sourceID,
                    maxResults: 5
                )
                if let result = results.first {
                    return result
                }
            } catch {
                logger.debug("Source \(sq.sourceID) failed for \(identifier.value): \(error.localizedDescription)")
            }
        }

        throw AutomationOperationError.paperNotFound(identifier.value)
    }

    public func deletePapers(identifiers: [PaperIdentifier]) async throws -> Int {
        try await checkAuthorization()
        logger.info("Deleting \(identifiers.count) papers")

        var deletedCount = 0
        for identifier in identifiers {
            if let publication = await findPublication(by: identifier) {
                await repository.delete(publication)
                deletedCount += 1
            }
        }

        return deletedCount
    }

    public func markAsRead(identifiers: [PaperIdentifier]) async throws -> Int {
        try await checkAuthorization()

        var count = 0
        for identifier in identifiers {
            if let publication = await findPublication(by: identifier), !publication.isRead {
                await repository.markAsRead(publication)
                count += 1
            }
        }
        return count
    }

    public func markAsUnread(identifiers: [PaperIdentifier]) async throws -> Int {
        try await checkAuthorization()

        var count = 0
        for identifier in identifiers {
            if let publication = await findPublication(by: identifier), publication.isRead {
                await repository.markAsUnread(publication)
                count += 1
            }
        }
        return count
    }

    public func toggleReadStatus(identifiers: [PaperIdentifier]) async throws -> Int {
        try await checkAuthorization()

        var count = 0
        for identifier in identifiers {
            if let publication = await findPublication(by: identifier) {
                await repository.toggleReadStatus(publication)
                count += 1
            }
        }
        return count
    }

    public func toggleStar(identifiers: [PaperIdentifier]) async throws -> Int {
        try await checkAuthorization()

        var count = 0
        for identifier in identifiers {
            if let publication = await findPublication(by: identifier) {
                // Toggle star status (would need to add method to repository)
                let context = publication.managedObjectContext
                context?.performAndWait {
                    publication.isStarred = !publication.isStarred
                    try? context?.save()
                }
                count += 1
            }
        }
        return count
    }

    // MARK: - Collection Operations

    public func listCollections(libraryID: UUID?) async throws -> [CollectionResult] {
        try await checkAuthorization()

        let collections = await collectionRepository.fetchAll()

        return collections
            .filter { collection in
                if let libraryID = libraryID {
                    return collection.library?.id == libraryID
                }
                return true
            }
            .map { toCollectionResult($0) }
    }

    public func createCollection(
        name: String,
        libraryID: UUID?,
        isSmartCollection: Bool,
        predicate: String?
    ) async throws -> CollectionResult {
        try await checkAuthorization()
        logger.info("Creating collection: \(name)")

        let collection = await collectionRepository.create(
            name: name,
            isSmartCollection: isSmartCollection,
            predicate: predicate
        )

        return toCollectionResult(collection)
    }

    public func deleteCollection(collectionID: UUID) async throws -> Bool {
        try await checkAuthorization()

        let collections = await collectionRepository.fetchAll()
        guard let collection = collections.first(where: { $0.id == collectionID }) else {
            return false
        }

        await collectionRepository.delete(collection)
        return true
    }

    public func addToCollection(papers: [PaperIdentifier], collectionID: UUID) async throws -> Int {
        try await checkAuthorization()

        let collections = await collectionRepository.fetchAll()
        guard let collection = collections.first(where: { $0.id == collectionID }) else {
            throw AutomationOperationError.collectionNotFound(collectionID)
        }

        var count = 0
        for identifier in papers {
            if let publication = await findPublication(by: identifier) {
                await repository.addToCollection(publication, collection: collection)
                count += 1
            }
        }

        return count
    }

    public func removeFromCollection(papers: [PaperIdentifier], collectionID: UUID) async throws -> Int {
        try await checkAuthorization()

        let collections = await collectionRepository.fetchAll()
        guard let collection = collections.first(where: { $0.id == collectionID }) else {
            throw AutomationOperationError.collectionNotFound(collectionID)
        }

        var count = 0
        var pubs: [CDPublication] = []
        for identifier in papers {
            if let publication = await findPublication(by: identifier) {
                pubs.append(publication)
                count += 1
            }
        }

        if !pubs.isEmpty {
            await collectionRepository.removePublications(pubs, from: collection)
        }

        return count
    }

    // MARK: - Library Operations

    public func createLibrary(name: String) async throws -> LibraryResult {
        try await checkAuthorization()
        logger.info("Creating library: \(name)")

        let context = PersistenceController.shared.viewContext
        let library: CDLibrary = await context.perform {
            let lib = CDLibrary(context: context)
            lib.id = UUID()
            lib.name = name
            lib.dateCreated = Date()
            lib.isDefault = false
            return lib
        }

        // Create Papers directory
        let papersURL = library.papersContainerURL
        try? FileManager.default.createDirectory(at: papersURL, withIntermediateDirectories: true)

        PersistenceController.shared.save()
        logger.info("Created library '\(name)' with ID: \(library.id)")

        return toLibraryResult(library)
    }

    public func listLibraries() async throws -> [LibraryResult] {
        try await checkAuthorization()

        // Fetch libraries from persistence
        let libraries = await fetchLibraries()
        return libraries.map { toLibraryResult($0) }
    }

    public func getDefaultLibrary() async throws -> LibraryResult? {
        try await checkAuthorization()

        let libraries = await fetchLibraries()
        return libraries.first(where: { $0.isDefault }).map { toLibraryResult($0) }
    }

    public func getInboxLibrary() async throws -> LibraryResult? {
        try await checkAuthorization()

        let libraries = await fetchLibraries()
        return libraries.first(where: { $0.isInbox }).map { toLibraryResult($0) }
    }

    private func fetchLibraries() async -> [CDLibrary] {
        let context = PersistenceController.shared.viewContext
        return await context.perform {
            let request = NSFetchRequest<CDLibrary>(entityName: "Library")
            request.sortDescriptors = [NSSortDescriptor(key: "sortOrder", ascending: true)]
            return (try? context.fetch(request)) ?? []
        }
    }

    // MARK: - Export Operations

    public func exportBibTeX(identifiers: [PaperIdentifier]?) async throws -> ExportResult {
        try await checkAuthorization()

        let publications: [CDPublication]
        if let identifiers = identifiers {
            publications = await getPaperEntities(identifiers: identifiers)
        } else {
            publications = await repository.fetchAll()
        }

        let content = await repository.export(publications)

        return ExportResult(
            format: "bibtex",
            content: content,
            paperCount: publications.count
        )
    }

    public func exportRIS(identifiers: [PaperIdentifier]?) async throws -> ExportResult {
        try await checkAuthorization()

        let publications: [CDPublication]
        if let identifiers = identifiers {
            publications = await getPaperEntities(identifiers: identifiers)
        } else {
            publications = await repository.fetchAll()
        }

        let content = await repository.exportToRIS(publications)

        return ExportResult(
            format: "ris",
            content: content,
            paperCount: publications.count
        )
    }

    private func getPaperEntities(identifiers: [PaperIdentifier]) async -> [CDPublication] {
        var publications: [CDPublication] = []
        for identifier in identifiers {
            if let pub = await findPublication(by: identifier) {
                publications.append(pub)
            }
        }
        return publications
    }

    // MARK: - PDF Operations

    public func downloadPDFs(identifiers: [PaperIdentifier]) async throws -> DownloadResult {
        try await checkAuthorization()
        logger.info("Downloading PDFs for \(identifiers.count) papers")

        var downloaded: [String] = []
        var alreadyHad: [String] = []
        var failed: [String: String] = [:]

        for identifier in identifiers {
            guard let publication = await findPublication(by: identifier) else {
                failed[identifier.value] = "Paper not found"
                continue
            }

            if publication.hasPDFDownloaded {
                alreadyHad.append(publication.citeKey)
                continue
            }

            // Trigger PDF download via notification
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .downloadPDF,
                    object: nil,
                    userInfo: ["publicationID": publication.id]
                )
            }

            // Note: Actual download is async, we just queue it here
            downloaded.append(publication.citeKey)
        }

        return DownloadResult(
            downloaded: downloaded,
            alreadyHad: alreadyHad,
            failed: failed
        )
    }

    public func checkPDFStatus(identifiers: [PaperIdentifier]) async throws -> [String: Bool] {
        try await checkAuthorization()

        var status: [String: Bool] = [:]
        for identifier in identifiers {
            if let publication = await findPublication(by: identifier) {
                status[identifier.value] = publication.hasPDFDownloaded
            } else {
                status[identifier.value] = false
            }
        }
        return status
    }

    // MARK: - Source Operations

    public func listSources() async throws -> [(id: String, name: String, hasCredentials: Bool)] {
        try await checkAuthorization()

        let sources = await sourceManager.availableSources
        var results: [(id: String, name: String, hasCredentials: Bool)] = []

        for source in sources {
            let hasCredentials = await sourceManager.hasValidCredentials(for: source.id)
            results.append((id: source.id, name: source.name, hasCredentials: hasCredentials))
        }

        return results
    }

    // MARK: - Tag Operations

    public func addTag(path: String, to papers: [PaperIdentifier]) async throws -> Int {
        try await checkAuthorization()
        logger.info("Adding tag '\(path)' to \(papers.count) papers")

        let tag = await repository.findOrCreateTagByPath(path)
        var count = 0
        for identifier in papers {
            if let publication = await findPublication(by: identifier) {
                await repository.addTag(tag, to: publication)
                count += 1
            }
        }
        return count
    }

    public func removeTag(path: String, from papers: [PaperIdentifier]) async throws -> Int {
        try await checkAuthorization()
        logger.info("Removing tag '\(path)' from \(papers.count) papers")

        let allTags = await repository.fetchAllTags()
        guard let tag = allTags.first(where: { $0.canonicalPath == path }) else {
            throw AutomationOperationError.operationFailed("Tag not found: \(path)")
        }

        var count = 0
        for identifier in papers {
            if let publication = await findPublication(by: identifier) {
                await repository.removeTag(tag.id, from: publication)
                count += 1
            }
        }
        return count
    }

    public func listTags(matching prefix: String?, limit: Int) async throws -> [TagResult] {
        try await checkAuthorization()

        let tags: [CDTag]
        if let prefix = prefix, !prefix.isEmpty {
            tags = await repository.allTags(matching: prefix, limit: limit)
        } else {
            let allTags = await repository.fetchAllTags()
            tags = Array(allTags.prefix(limit))
        }

        return tags.map { toTagResult($0) }
    }

    public func getTagTree() async throws -> String {
        try await checkAuthorization()
        return await TagManagementService.shared.tagTree()
    }

    // MARK: - Flag Operations

    public func setFlag(color: String, style: String?, length: String?, papers: [PaperIdentifier]) async throws -> Int {
        try await checkAuthorization()
        logger.info("Setting flag '\(color)' on \(papers.count) papers")

        guard let flagColor = FlagColor(rawValue: color) else {
            throw AutomationOperationError.operationFailed("Invalid flag color: \(color). Use: red, amber, blue, gray")
        }
        let flagStyle = style.flatMap { FlagStyle(rawValue: $0) } ?? .solid
        let flagLength = length.flatMap { FlagLength(rawValue: $0) } ?? .full
        let flag = PublicationFlag(color: flagColor, style: flagStyle, length: flagLength)

        var count = 0
        for identifier in papers {
            if let publication = await findPublication(by: identifier) {
                await repository.setFlag(publication, flag: flag)
                count += 1
            }
        }
        return count
    }

    public func clearFlag(papers: [PaperIdentifier]) async throws -> Int {
        try await checkAuthorization()
        logger.info("Clearing flag from \(papers.count) papers")

        var count = 0
        for identifier in papers {
            if let publication = await findPublication(by: identifier) {
                await repository.setFlag(publication, flag: nil)
                count += 1
            }
        }
        return count
    }

    // MARK: - Collection Papers

    public func listPapersInCollection(
        collectionID: UUID,
        limit: Int,
        offset: Int
    ) async throws -> (papers: [PaperResult], totalCount: Int) {
        try await checkAuthorization()

        let collections = await collectionRepository.fetchAll()
        guard let collection = collections.first(where: { $0.id == collectionID }) else {
            throw AutomationOperationError.collectionNotFound(collectionID)
        }

        let allPubs = Array(collection.publications ?? [])
        let totalCount = allPubs.count
        let paginated = Array(allPubs.dropFirst(offset).prefix(limit))
        let papers = paginated.compactMap { toPaperResult($0) }

        return (papers: papers, totalCount: totalCount)
    }

    // MARK: - Participant Operations

    public func listParticipants(libraryID: UUID) async throws -> [ParticipantResult] {
        try await checkAuthorization()

        let libraries = await fetchLibraries()
        guard let library = libraries.first(where: { $0.id == libraryID }) else {
            throw AutomationOperationError.libraryNotFound(libraryID)
        }

        guard library.isSharedLibrary else {
            return []  // Not shared, no participants
        }

        #if canImport(CloudKit)
        guard let share = PersistenceController.shared.share(for: library) else {
            return []
        }

        return share.participants.map { participant in
            let formatter = PersonNameComponentsFormatter()
            formatter.style = .default
            let displayName = participant.userIdentity.nameComponents.map { formatter.string(from: $0) }
            let email = participant.userIdentity.lookupInfo?.emailAddress

            let permission: String
            switch participant.permission {
            case .readOnly:
                permission = "readOnly"
            case .readWrite:
                permission = "readWrite"
            default:
                permission = "unknown"
            }

            let status: String
            switch participant.acceptanceStatus {
            case .accepted:
                status = "accepted"
            case .pending:
                status = "pending"
            case .removed:
                status = "removed"
            default:
                status = "unknown"
            }

            return ParticipantResult(
                id: participant.participantID,
                displayName: displayName,
                email: email,
                permission: permission,
                isOwner: participant == share.owner,
                status: status
            )
        }
        #else
        return []
        #endif
    }

    public func setParticipantPermission(
        libraryID: UUID,
        participantID: String,
        permission: String
    ) async throws {
        try await checkAuthorization()

        let libraries = await fetchLibraries()
        guard let library = libraries.first(where: { $0.id == libraryID }) else {
            throw AutomationOperationError.libraryNotFound(libraryID)
        }

        guard library.isSharedLibrary else {
            throw AutomationOperationError.notShared
        }

        guard library.isShareOwner else {
            throw AutomationOperationError.notShareOwner
        }

        #if canImport(CloudKit)
        guard let share = PersistenceController.shared.share(for: library) else {
            throw AutomationOperationError.notShared
        }

        guard let participant = share.participants.first(where: { $0.participantID == participantID }) else {
            throw AutomationOperationError.participantNotFound(participantID)
        }

        let ckPermission: CKShare.ParticipantPermission
        switch permission {
        case "readOnly":
            ckPermission = .readOnly
        case "readWrite":
            ckPermission = .readWrite
        default:
            throw AutomationOperationError.operationFailed("Invalid permission: \(permission). Use 'readOnly' or 'readWrite'")
        }

        try await CloudKitSharingService.shared.setPermission(ckPermission, for: participant, in: library)
        logger.info("Set permission '\(permission)' for participant in library '\(library.displayName)'")
        #else
        throw AutomationOperationError.sharingUnavailable
        #endif
    }

    // MARK: - Activity Feed Operations

    public func recentActivity(libraryID: UUID, limit: Int) async throws -> [ActivityResult] {
        try await checkAuthorization()

        let libraries = await fetchLibraries()
        guard let library = libraries.first(where: { $0.id == libraryID }) else {
            throw AutomationOperationError.libraryNotFound(libraryID)
        }

        let records = await MainActor.run {
            ActivityFeedService.shared.recentActivity(in: library, limit: limit)
        }

        return records.map { toActivityResult($0) }
    }

    // MARK: - Comment Operations

    public func listComments(publicationIdentifier: PaperIdentifier) async throws -> [CommentResult] {
        try await checkAuthorization()

        guard let publication = await findPublication(by: publicationIdentifier) else {
            throw AutomationOperationError.paperNotFound(publicationIdentifier.value)
        }

        let comments = await MainActor.run {
            CommentService.shared.comments(for: publication)
        }

        return comments.map { toCommentResult($0, allComments: publication.comments ?? []) }
    }

    public func addComment(
        text: String,
        publicationIdentifier: PaperIdentifier,
        parentCommentID: UUID?
    ) async throws -> CommentResult {
        try await checkAuthorization()

        guard let publication = await findPublication(by: publicationIdentifier) else {
            throw AutomationOperationError.paperNotFound(publicationIdentifier.value)
        }

        let comment = try await MainActor.run {
            try CommentService.shared.addComment(
                text: text,
                to: publication,
                parentCommentID: parentCommentID
            )
        }

        logger.info("Added comment to '\(publication.citeKey)'")
        return toCommentResult(comment, allComments: [])
    }

    public func deleteComment(commentID: UUID) async throws {
        try await checkAuthorization()

        let context = PersistenceController.shared.viewContext
        let comment: CDComment? = await context.perform {
            let request = NSFetchRequest<CDComment>(entityName: "Comment")
            request.predicate = NSPredicate(format: "id == %@", commentID as CVarArg)
            request.fetchLimit = 1
            return try? context.fetch(request).first
        }

        guard let comment = comment else {
            throw AutomationOperationError.commentNotFound(commentID)
        }

        try await MainActor.run {
            try CommentService.shared.deleteComment(comment)
        }

        logger.info("Deleted comment \(commentID)")
    }

    // MARK: - Assignment Operations

    public func listAssignments(libraryID: UUID) async throws -> [AssignmentResult] {
        try await checkAuthorization()

        let libraries = await fetchLibraries()
        guard let library = libraries.first(where: { $0.id == libraryID }) else {
            throw AutomationOperationError.libraryNotFound(libraryID)
        }

        let assignments = await MainActor.run {
            AssignmentService.shared.assignments(in: library)
        }

        return assignments.map { toAssignmentResult($0) }
    }

    public func listAssignmentsForPublication(publicationIdentifier: PaperIdentifier) async throws -> [AssignmentResult] {
        try await checkAuthorization()

        guard let publication = await findPublication(by: publicationIdentifier) else {
            throw AutomationOperationError.paperNotFound(publicationIdentifier.value)
        }

        let assignments = await MainActor.run {
            AssignmentService.shared.assignments(for: publication)
        }

        return assignments.map { toAssignmentResult($0) }
    }

    public func createAssignment(
        publicationIdentifier: PaperIdentifier,
        assigneeName: String,
        libraryID: UUID,
        note: String?,
        dueDate: Date?
    ) async throws -> AssignmentResult {
        try await checkAuthorization()

        guard let publication = await findPublication(by: publicationIdentifier) else {
            throw AutomationOperationError.paperNotFound(publicationIdentifier.value)
        }

        let libraries = await fetchLibraries()
        guard let library = libraries.first(where: { $0.id == libraryID }) else {
            throw AutomationOperationError.libraryNotFound(libraryID)
        }

        let assignment = try await MainActor.run {
            try AssignmentService.shared.suggest(
                publication: publication,
                to: assigneeName,
                in: library,
                note: note,
                dueDate: dueDate
            )
        }

        logger.info("Created assignment: '\(publication.citeKey)' suggested to '\(assigneeName)'")
        return toAssignmentResult(assignment)
    }

    public func deleteAssignment(assignmentID: UUID) async throws {
        try await checkAuthorization()

        let context = PersistenceController.shared.viewContext
        let assignment: CDAssignment? = await context.perform {
            let request = NSFetchRequest<CDAssignment>(entityName: "Assignment")
            request.predicate = NSPredicate(format: "id == %@", assignmentID as CVarArg)
            request.fetchLimit = 1
            return try? context.fetch(request).first
        }

        guard let assignment = assignment else {
            throw AutomationOperationError.assignmentNotFound(assignmentID)
        }

        try await MainActor.run {
            try AssignmentService.shared.remove(assignment)
        }

        logger.info("Deleted assignment \(assignmentID)")
    }

    public func participantNames(libraryID: UUID) async throws -> [String] {
        try await checkAuthorization()

        let libraries = await fetchLibraries()
        guard let library = libraries.first(where: { $0.id == libraryID }) else {
            throw AutomationOperationError.libraryNotFound(libraryID)
        }

        return await MainActor.run {
            AssignmentService.shared.participantNames(in: library)
        }
    }

    // MARK: - Sharing Operations

    public func shareLibrary(libraryID: UUID) async throws -> ShareResult {
        try await checkAuthorization()

        #if canImport(CloudKit)
        let libraries = await fetchLibraries()
        guard let library = libraries.first(where: { $0.id == libraryID }) else {
            throw AutomationOperationError.libraryNotFound(libraryID)
        }

        // If already shared, return existing share info
        if library.isSharedLibrary {
            if let share = PersistenceController.shared.share(for: library) {
                return ShareResult(
                    libraryID: library.id,
                    shareURL: share.url?.absoluteString,
                    isShared: true
                )
            }
        }

        let (sharedLibrary, share) = try await CloudKitSharingService.shared.shareLibrary(library)
        logger.info("Shared library '\(library.displayName)'")

        return ShareResult(
            libraryID: sharedLibrary.id,
            shareURL: share.url?.absoluteString,
            isShared: true
        )
        #else
        throw AutomationOperationError.sharingUnavailable
        #endif
    }

    public func unshareLibrary(libraryID: UUID) async throws {
        try await checkAuthorization()

        #if canImport(CloudKit)
        let libraries = await fetchLibraries()
        guard let library = libraries.first(where: { $0.id == libraryID }) else {
            throw AutomationOperationError.libraryNotFound(libraryID)
        }

        guard library.isSharedLibrary else {
            throw AutomationOperationError.notShared
        }

        guard library.isShareOwner else {
            throw AutomationOperationError.notShareOwner
        }

        try await CloudKitSharingService.shared.unshare(library)
        logger.info("Unshared library '\(library.displayName)'")
        #else
        throw AutomationOperationError.sharingUnavailable
        #endif
    }

    public func leaveShare(libraryID: UUID, keepCopy: Bool) async throws {
        try await checkAuthorization()

        #if canImport(CloudKit)
        let libraries = await fetchLibraries()
        guard let library = libraries.first(where: { $0.id == libraryID }) else {
            throw AutomationOperationError.libraryNotFound(libraryID)
        }

        guard library.isSharedLibrary else {
            throw AutomationOperationError.notShared
        }

        try await CloudKitSharingService.shared.leaveShare(library, keepCopy: keepCopy)
        logger.info("Left shared library '\(library.displayName)' (keepCopy: \(keepCopy))")
        #else
        throw AutomationOperationError.sharingUnavailable
        #endif
    }

    // MARK: - Annotation Operations

    /// List annotations for a publication's PDF.
    public func listAnnotations(
        publicationIdentifier: PaperIdentifier,
        pageNumber: Int?
    ) async throws -> [AnnotationResult] {
        try await checkAuthorization()

        guard let publication = await findPublication(by: publicationIdentifier) else {
            throw AutomationOperationError.paperNotFound(publicationIdentifier.value)
        }

        guard let linkedFile = publication.linkedFiles?.first else {
            throw AutomationOperationError.linkedFileNotFound(publication.citeKey)
        }

        let annotations = await MainActor.run {
            AnnotationPersistence.shared.loadAnnotations(for: linkedFile)
        }

        var filtered = annotations
        if let pageNumber = pageNumber {
            filtered = filtered.filter { $0.pageNumber == Int32(pageNumber) }
        }

        return filtered.map { toAnnotationResult($0) }
    }

    /// Add an annotation to a publication's PDF.
    public func addAnnotation(
        publicationIdentifier: PaperIdentifier,
        type: String,
        pageNumber: Int,
        contents: String?,
        selectedText: String?,
        color: String?
    ) async throws -> AnnotationResult {
        try await checkAuthorization()

        guard let publication = await findPublication(by: publicationIdentifier) else {
            throw AutomationOperationError.paperNotFound(publicationIdentifier.value)
        }

        guard let linkedFile = publication.linkedFiles?.first else {
            throw AutomationOperationError.linkedFileNotFound(publication.citeKey)
        }

        // Validate annotation type
        guard let annotationType = AnnotationType(rawValue: type) else {
            throw AutomationOperationError.operationFailed("Invalid annotation type: \(type). Use: highlight, underline, strikethrough, note, freeText")
        }

        let hexColor = color ?? annotationType.defaultColor

        // Create annotation in Core Data directly (without PDFKit)
        let annotation = try await MainActor.run {
            let context = PersistenceController.shared.viewContext
            let cdAnnotation = CDAnnotation(context: context)
            cdAnnotation.id = UUID()
            cdAnnotation.pageNumber = Int32(pageNumber)
            cdAnnotation.annotationType = annotationType.rawValue
            cdAnnotation.color = hexColor
            cdAnnotation.contents = contents
            cdAnnotation.selectedText = selectedText
            cdAnnotation.linkedFile = linkedFile
            cdAnnotation.dateCreated = Date()
            cdAnnotation.dateModified = Date()

            // Set author from current user
            #if os(macOS)
            cdAnnotation.author = Host.current().localizedName ?? "Unknown"
            #else
            cdAnnotation.author = UIDevice.current.name
            #endif

            // Set default bounds for note annotations
            if annotationType == .note || annotationType == .freeText {
                cdAnnotation.boundsJSON = "{\"x\":50,\"y\":50,\"width\":200,\"height\":100}"
            }

            try context.save()
            return cdAnnotation
        }

        logger.info("Added \(type) annotation to '\(publication.citeKey)' page \(pageNumber)")
        return toAnnotationResult(annotation)
    }

    /// Delete an annotation by ID.
    public func deleteAnnotation(annotationID: UUID) async throws {
        try await checkAuthorization()

        let context = PersistenceController.shared.viewContext
        let annotation: CDAnnotation? = await context.perform {
            let request = NSFetchRequest<CDAnnotation>(entityName: "Annotation")
            request.predicate = NSPredicate(format: "id == %@", annotationID as CVarArg)
            request.fetchLimit = 1
            return try? context.fetch(request).first
        }

        guard let annotation = annotation else {
            throw AutomationOperationError.annotationNotFound(annotationID)
        }

        try await MainActor.run {
            try AnnotationPersistence.shared.delete(annotation)
        }

        logger.info("Deleted annotation \(annotationID)")
    }

    // MARK: - Notes Operations

    /// Get the notes for a publication.
    public func getNotes(publicationIdentifier: PaperIdentifier) async throws -> String? {
        try await checkAuthorization()

        guard let publication = await findPublication(by: publicationIdentifier) else {
            throw AutomationOperationError.paperNotFound(publicationIdentifier.value)
        }

        return publication.fields["note"]
    }

    /// Update the notes for a publication.
    public func updateNotes(publicationIdentifier: PaperIdentifier, notes: String?) async throws {
        try await checkAuthorization()

        guard let publication = await findPublication(by: publicationIdentifier) else {
            throw AutomationOperationError.paperNotFound(publicationIdentifier.value)
        }

        await MainActor.run {
            let context = publication.managedObjectContext
            context?.performAndWait {
                var fields = publication.fields
                if let notes = notes, !notes.isEmpty {
                    fields["note"] = notes
                } else {
                    fields.removeValue(forKey: "note")
                }
                publication.fields = fields
                publication.dateModified = Date()
                try? context?.save()
            }
        }

        logger.info("Updated notes for '\(publication.citeKey)'")
    }

    // MARK: - Conversion Helpers

    private func toPaperResult(_ publication: CDPublication) -> PaperResult? {
        // Guard against deleted objects
        guard let context = publication.managedObjectContext, !publication.isDeleted else {
            return nil
        }

        // Access all Core Data properties on the context's queue to avoid threading crashes.
        // This actor may be called from the HTTP server thread (not main).
        var result: PaperResult?
        context.performAndWait {
            guard !publication.isDeleted else { return }

            let fields = publication.fields

            let tagPaths: [String] = (publication.tags ?? [])
                .compactMap { $0.canonicalPath }
                .sorted()

            let flagResult: FlagResult? = publication.flag.map {
                FlagResult(
                    color: $0.color.rawValue,
                    style: $0.style.rawValue,
                    length: $0.length.rawValue
                )
            }

            let collIDs: [UUID] = (publication.collections ?? []).map { $0.id }
            let libIDs: [UUID] = (publication.libraries ?? []).map { $0.id }
            let notes = fields["note"]
            let annotationCount = (publication.linkedFiles ?? [])
                .reduce(0) { $0 + ($1.annotations?.count ?? 0) }

            result = PaperResult(
                id: publication.id,
                citeKey: publication.citeKey,
                title: publication.title ?? "",
                authors: parseAuthors(from: fields["author"]),
                year: publication.year > 0 ? Int(publication.year) : nil,
                venue: fields["journal"] ?? fields["booktitle"],
                abstract: publication.abstract,
                doi: publication.doi,
                arxivID: publication.arxivID,
                bibcode: publication.bibcode,
                pmid: publication.pmid,
                semanticScholarID: publication.semanticScholarID,
                openAlexID: publication.openAlexID,
                isRead: publication.isRead,
                isStarred: publication.isStarred,
                hasPDF: publication.hasPDFDownloaded || !(publication.linkedFiles?.isEmpty ?? true),
                citationCount: publication.citationCount >= 0 ? Int(publication.citationCount) : nil,
                dateAdded: publication.dateAdded,
                dateModified: publication.dateModified,
                bibtex: publication.rawBibTeX ?? "",
                webURL: publication.webURL,
                pdfURLs: publication.pdfLinks.map { $0.url.absoluteString },
                tags: tagPaths,
                flag: flagResult,
                collectionIDs: collIDs,
                libraryIDs: libIDs,
                notes: notes,
                annotationCount: annotationCount
            )
        }
        return result
    }

    private func parseAuthors(from authorField: String?) -> [String] {
        guard let authorField = authorField else { return [] }
        return authorField
            .components(separatedBy: " and ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func toCollectionResult(_ collection: CDCollection) -> CollectionResult {
        guard let context = collection.managedObjectContext else {
            return CollectionResult(id: collection.id, name: collection.name, paperCount: 0,
                                    isSmartCollection: false, libraryID: nil, libraryName: nil)
        }
        var result: CollectionResult!
        context.performAndWait {
            result = CollectionResult(
                id: collection.id,
                name: collection.name,
                paperCount: collection.publications?.count ?? 0,
                isSmartCollection: collection.isSmartCollection,
                libraryID: collection.library?.id,
                libraryName: collection.library?.name
            )
        }
        return result
    }

    private func toLibraryResult(_ library: CDLibrary) -> LibraryResult {
        guard let context = library.managedObjectContext else {
            return LibraryResult(id: library.id, name: library.displayName, paperCount: 0,
                                 collectionCount: 0, isDefault: false, isInbox: false,
                                 isShared: false, isShareOwner: false, participantCount: 0, canEdit: false)
        }
        var result: LibraryResult!
        context.performAndWait {
            result = LibraryResult(
                id: library.id,
                name: library.displayName,
                paperCount: library.publications?.count ?? 0,
                collectionCount: library.collections?.count ?? 0,
                isDefault: library.isDefault,
                isInbox: library.isInbox,
                isShared: library.isSharedLibrary,
                isShareOwner: library.isShareOwner,
                participantCount: library.shareParticipantCount,
                canEdit: library.canEdit
            )
        }
        return result
    }

    private func toTagResult(_ tag: CDTag) -> TagResult {
        guard let context = tag.managedObjectContext else {
            return TagResult(id: tag.id, name: tag.leaf, canonicalPath: tag.name,
                             parentPath: nil, useCount: 0, publicationCount: 0)
        }
        var result: TagResult!
        context.performAndWait {
            result = TagResult(
                id: tag.id,
                name: tag.leaf,
                canonicalPath: tag.canonicalPath ?? tag.name,
                parentPath: tag.parentTag?.canonicalPath,
                useCount: Int(tag.useCount),
                publicationCount: tag.publicationCount
            )
        }
        return result
    }

    private func toActivityResult(_ record: CDActivityRecord) -> ActivityResult {
        ActivityResult(
            id: record.id,
            activityType: record.activityType,
            actorDisplayName: record.actorDisplayName,
            targetTitle: record.targetTitle,
            targetID: record.targetID,
            detail: record.detail,
            date: record.date
        )
    }

    private func toCommentResult(_ comment: CDComment, allComments: Set<CDComment>) -> CommentResult {
        guard let context = comment.managedObjectContext else {
            return CommentResult(id: comment.id, text: comment.text,
                                 authorDisplayName: comment.authorDisplayName,
                                 authorIdentifier: comment.authorIdentifier,
                                 dateCreated: comment.dateCreated, dateModified: comment.dateModified,
                                 parentCommentID: comment.parentCommentID, replies: [])
        }
        var result: CommentResult!
        context.performAndWait {
            let replies = allComments
                .filter { $0.parentCommentID == comment.id }
                .sorted { $0.dateCreated < $1.dateCreated }
                .map { toCommentResult($0, allComments: allComments) }

            result = CommentResult(
                id: comment.id,
                text: comment.text,
                authorDisplayName: comment.authorDisplayName,
                authorIdentifier: comment.authorIdentifier,
                dateCreated: comment.dateCreated,
                dateModified: comment.dateModified,
                parentCommentID: comment.parentCommentID,
                replies: replies
            )
        }
        return result
    }

    private func toAssignmentResult(_ assignment: CDAssignment) -> AssignmentResult {
        guard let context = assignment.managedObjectContext else {
            return AssignmentResult(id: assignment.id, publicationID: UUID(),
                                    publicationTitle: nil, publicationCiteKey: nil,
                                    assigneeName: assignment.assigneeName,
                                    assignedByName: assignment.assignedByName,
                                    note: assignment.note, dateCreated: assignment.dateCreated,
                                    dueDate: assignment.dueDate, libraryID: nil)
        }
        var result: AssignmentResult!
        context.performAndWait {
            result = AssignmentResult(
                id: assignment.id,
                publicationID: assignment.publication?.id ?? UUID(),
                publicationTitle: assignment.publication?.title,
                publicationCiteKey: assignment.publication?.citeKey,
                assigneeName: assignment.assigneeName,
                assignedByName: assignment.assignedByName,
                note: assignment.note,
                dateCreated: assignment.dateCreated,
                dueDate: assignment.dueDate,
                libraryID: assignment.library?.id
            )
        }
        return result
    }

    private func toAnnotationResult(_ annotation: CDAnnotation) -> AnnotationResult {
        AnnotationResult(
            id: annotation.id,
            type: annotation.annotationType,
            pageNumber: Int(annotation.pageNumber),
            contents: annotation.contents,
            selectedText: annotation.selectedText,
            color: annotation.color ?? "#FFFF00",
            author: annotation.author,
            dateCreated: annotation.dateCreated,
            dateModified: annotation.dateModified
        )
    }
}

// MARK: - Notification Names

public extension Notification.Name {
    static let downloadPDF = Notification.Name("com.imbib.downloadPDF")
}
