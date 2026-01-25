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
    private let sourceManager: SourceManager
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

    // MARK: - Authorization Check

    private func checkAuthorization() async throws {
        let isEnabled = await settingsStore.isEnabled
        guard isEnabled else {
            throw AutomationOperationError.unauthorized
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

        for identifier in identifiers {
            // Check if already exists
            if let existing = await findPublication(by: identifier) {
                duplicates.append(identifier.value)
                logger.debug("Duplicate found for: \(identifier.value)")
                continue
            }

            do {
                // Try to fetch from external source based on identifier type
                let searchResult = try await fetchFromExternal(identifier: identifier)

                // Create publication from search result
                let publication = await repository.createFromSearchResult(searchResult)

                // Add to collection if specified
                if let collectionID = collection {
                    let collections = await collectionRepository.fetchAll()
                    if let targetCollection = collections.first(where: { $0.id == collectionID }) {
                        await repository.addToCollection(publication, collection: targetCollection)
                    }
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

        return AddPapersResult(added: added, duplicates: duplicates, failed: failed)
    }

    private func fetchFromExternal(identifier: PaperIdentifier) async throws -> SearchResult {
        // Search external sources based on identifier type
        let query: String
        let sources: [String]?

        switch identifier {
        case .doi(let doi):
            query = doi
            sources = ["crossref", "ads"]
        case .arxiv(let id):
            query = id
            sources = ["arxiv"]
        case .bibcode(let code):
            query = code
            sources = ["ads"]
        case .pmid(let id):
            query = id
            sources = ["pubmed"]
        default:
            throw AutomationOperationError.invalidIdentifier("Cannot fetch \(identifier.typeName) from external sources")
        }

        let results = try await sourceManager.search(
            query: query,
            options: SearchOptions(maxResults: 5, sourceIDs: sources)
        )

        guard let result = results.first else {
            throw AutomationOperationError.paperNotFound(identifier.value)
        }

        return result
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

    // MARK: - Conversion Helpers

    private func toPaperResult(_ publication: CDPublication) -> PaperResult? {
        // Guard against deleted objects
        guard publication.managedObjectContext != nil, !publication.isDeleted else {
            return nil
        }

        let fields = publication.fields
        return PaperResult(
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
            pdfURLs: publication.pdfLinks.map { $0.url.absoluteString }
        )
    }

    private func parseAuthors(from authorField: String?) -> [String] {
        guard let authorField = authorField else { return [] }
        return authorField
            .components(separatedBy: " and ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func toCollectionResult(_ collection: CDCollection) -> CollectionResult {
        CollectionResult(
            id: collection.id,
            name: collection.name,
            paperCount: collection.publications?.count ?? 0,
            isSmartCollection: collection.isSmartCollection,
            libraryID: collection.library?.id,
            libraryName: collection.library?.name
        )
    }

    private func toLibraryResult(_ library: CDLibrary) -> LibraryResult {
        LibraryResult(
            id: library.id,
            name: library.displayName,
            paperCount: library.publications?.count ?? 0,
            collectionCount: library.collections?.count ?? 0,
            isDefault: library.isDefault,
            isInbox: library.isInbox
        )
    }
}

// MARK: - Notification Names

public extension Notification.Name {
    static let downloadPDF = Notification.Name("com.imbib.downloadPDF")
}
