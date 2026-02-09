//
//  AutomationService.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-16.
//
//  Actor implementing AutomationOperations protocol (ADR-018).
//  Calls RustStoreAdapter and SourceManager directly for rich data returns.
//

import Foundation
import OSLog
import ImpressFTUI
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

private let logger = Logger(subsystem: "com.imbib.app", category: "automationService")

// MARK: - Automation Service

/// Main implementation of AutomationOperations.
///
/// This actor provides the core automation functionality, calling the Rust store
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

    private var sourceManager: SourceManager
    private let settingsStore: AutomationSettingsStore

    // MARK: - Initialization

    public init(
        sourceManager: SourceManager = SourceManager(),
        settingsStore: AutomationSettingsStore = .shared
    ) {
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

    // MARK: - Rust Store Bridge

    /// Access the Rust store on the main actor.
    /// All RustStoreAdapter methods are @MainActor, so we bridge via MainActor.run.
    private func withStore<T: Sendable>(_ operation: @MainActor @Sendable (RustStoreAdapter) -> T) async -> T {
        await MainActor.run {
            operation(RustStoreAdapter.shared)
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

        let publications: [PublicationRowData]
        if query.isEmpty {
            // Fetch all from default library
            publications = await withStore { store in
                if let lib = store.getDefaultLibrary() {
                    return store.queryPublications(parentId: lib.id)
                }
                return []
            }
        } else {
            publications = await withStore { store in
                store.searchPublications(query: query)
            }
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

        return filtered.map { toPaperResult($0) }
    }

    private func applyFilters(to publications: [PublicationRowData], filters: SearchFilters) -> [PublicationRowData] {
        var result = publications

        if let yearFrom = filters.yearFrom {
            result = result.filter { ($0.year ?? 0) >= yearFrom }
        }
        if let yearTo = filters.yearTo {
            result = result.filter { ($0.year ?? Int.max) <= yearTo }
        }
        if let isRead = filters.isRead {
            result = result.filter { $0.isRead == isRead }
        }
        if let hasLocalPDF = filters.hasLocalPDF {
            result = result.filter { $0.hasDownloadedPDF == hasLocalPDF }
        }
        if let authors = filters.authors, !authors.isEmpty {
            result = result.filter { pub in
                let pubAuthors = pub.authorString.lowercased()
                return authors.contains { pubAuthors.contains($0.lowercased()) }
            }
        }
        // Note: library/collection filtering requires detail lookups; skip for now
        // since most callers filter by parentId at query time.
        if let tags = filters.tags, !tags.isEmpty {
            result = result.filter { pub in
                let pubTagPaths = Set(pub.tagDisplays.map(\.path))
                return tags.contains { pubTagPaths.contains($0) }
            }
        }
        if let flagColor = filters.flagColor {
            result = result.filter { $0.flag?.color.rawValue == flagColor }
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

        guard let publication = await findPublication(by: identifier) else {
            return nil
        }
        return toPaperResult(publication)
    }

    public func getPapers(identifiers: [PaperIdentifier]) async throws -> [PaperResult] {
        try await checkAuthorization()

        var results: [PaperResult] = []
        for id in identifiers {
            if let pub = await findPublication(by: id) {
                results.append(toPaperResult(pub))
            }
        }
        return results
    }

    private func findPublication(by identifier: PaperIdentifier) async -> PublicationRowData? {
        switch identifier {
        case .citeKey(let key):
            return await withStore { $0.findByCiteKey(citeKey: key) }
        case .doi(let doi):
            return await withStore { $0.findByDoi(doi: doi).first }
        case .arxiv(let id):
            return await withStore { $0.findByArxiv(arxivId: id).first }
        case .bibcode(let code):
            return await withStore { $0.findByBibcode(bibcode: code).first }
        case .uuid(let uuid):
            return await withStore { $0.getPublication(id: uuid) }
        case .pmid(let id):
            return await withStore { $0.findByIdentifiers(pmid: id).first }
        case .semanticScholar:
            // Semantic Scholar lookup not yet supported in Rust store
            return nil
        case .openAlex:
            // OpenAlex lookup not yet supported in Rust store
            return nil
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

        // Collect existing publication IDs that need collection assignment
        var existingToAssignIDs: [UUID] = []

        // Resolve the target library ID
        let targetLibraryID: UUID = await {
            if let lib = library { return lib }
            if let defaultLib = await withStore({ $0.getDefaultLibrary() }) {
                return defaultLib.id
            }
            // Last resort: create a default library
            if let created = await withStore({ $0.createLibrary(name: "Library") }) {
                return created.id
            }
            return UUID()
        }()

        for identifier in identifiers {
            // Check if already exists
            if let existing = await findPublication(by: identifier) {
                duplicates.append(identifier.value)
                existingToAssignIDs.append(existing.id)
                logger.debug("Duplicate found for: \(identifier.value)")
                continue
            }

            do {
                // Try to fetch from external source based on identifier type
                let searchResult = try await fetchFromExternal(identifier: identifier)

                // Get BibTeX from source (or synthesize it)
                let bibtex: String
                do {
                    let entry = try await sourceManager.fetchBibTeX(for: searchResult)
                    bibtex = entry.rawBibTeX ?? entry.synthesizeBibTeX()
                } catch {
                    // Synthesize BibTeX from search result metadata
                    bibtex = searchResult.toBibTeX()
                }

                // Import via Rust store
                let importedIDs = await withStore { store in
                    store.importBibTeX(bibtex, libraryId: targetLibraryID)
                }

                // Add to collection if specified
                if let collectionID = collection, !importedIDs.isEmpty {
                    await withStore { store in
                        store.addToCollection(publicationIds: importedIDs, collectionId: collectionID)
                    }
                }

                // Download PDF if requested
                if downloadPDFs && !searchResult.pdfLinks.isEmpty {
                    for pubID in importedIDs {
                        await MainActor.run {
                            NotificationCenter.default.post(
                                name: .downloadPDF,
                                object: nil,
                                userInfo: ["publicationID": pubID]
                            )
                        }
                    }
                }

                // Convert imported publications to PaperResult
                for pubID in importedIDs {
                    if let pub = await withStore({ $0.getPublication(id: pubID) }) {
                        added.append(toPaperResult(pub))
                    }
                }

            } catch {
                failed[identifier.value] = error.localizedDescription
                logger.error("Failed to add paper \(identifier.value): \(error.localizedDescription)")
            }
        }

        // Assign existing (duplicate) papers to target collection
        if !existingToAssignIDs.isEmpty {
            if let collectionID = collection {
                await withStore { store in
                    store.addToCollection(publicationIds: existingToAssignIDs, collectionId: collectionID)
                }
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
                await withStore { store in
                    store.movePublications(ids: [pub.id], toLibraryId: libraryID)
                }
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
                await withStore { store in
                    store.addToCollection(publicationIds: [pub.id], collectionId: collectionID)
                }
                assigned.append(identifier.value)
            } else {
                notFound.append(identifier.value)
            }
        }
        return AddToContainerResult(assigned: assigned, notFound: notFound)
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
        var idsToDelete: [UUID] = []

        for identifier in identifiers {
            if let pub = await findPublication(by: identifier) {
                idsToDelete.append(pub.id)
                deletedCount += 1
            }
        }

        if !idsToDelete.isEmpty {
            await withStore { store in
                store.deletePublications(ids: idsToDelete)
            }
        }

        return deletedCount
    }

    public func markAsRead(identifiers: [PaperIdentifier]) async throws -> Int {
        try await checkAuthorization()

        var ids: [UUID] = []
        for identifier in identifiers {
            if let pub = await findPublication(by: identifier), !pub.isRead {
                ids.append(pub.id)
            }
        }

        if !ids.isEmpty {
            await withStore { store in
                store.setRead(ids: ids, read: true)
            }
        }

        return ids.count
    }

    public func markAsUnread(identifiers: [PaperIdentifier]) async throws -> Int {
        try await checkAuthorization()

        var ids: [UUID] = []
        for identifier in identifiers {
            if let pub = await findPublication(by: identifier), pub.isRead {
                ids.append(pub.id)
            }
        }

        if !ids.isEmpty {
            await withStore { store in
                store.setRead(ids: ids, read: false)
            }
        }

        return ids.count
    }

    public func toggleReadStatus(identifiers: [PaperIdentifier]) async throws -> Int {
        try await checkAuthorization()

        var count = 0
        for identifier in identifiers {
            if let pub = await findPublication(by: identifier) {
                await withStore { store in
                    store.setRead(ids: [pub.id], read: !pub.isRead)
                }
                count += 1
            }
        }
        return count
    }

    public func toggleStar(identifiers: [PaperIdentifier]) async throws -> Int {
        try await checkAuthorization()

        var count = 0
        for identifier in identifiers {
            if let pub = await findPublication(by: identifier) {
                await withStore { store in
                    store.setStarred(ids: [pub.id], starred: !pub.isStarred)
                }
                count += 1
            }
        }
        return count
    }

    // MARK: - Collection Operations

    public func listCollections(libraryID: UUID?) async throws -> [CollectionResult] {
        try await checkAuthorization()

        if let libraryID = libraryID {
            let collections = await withStore { store in
                store.listCollections(libraryId: libraryID)
            }
            return collections.map { toCollectionResult($0, libraryID: libraryID) }
        } else {
            // List collections across all libraries
            let libraries = await withStore { $0.listLibraries() }
            var allCollections: [CollectionResult] = []
            for lib in libraries {
                let collections = await withStore { store in
                    store.listCollections(libraryId: lib.id)
                }
                allCollections.append(contentsOf: collections.map { toCollectionResult($0, libraryID: lib.id, libraryName: lib.name) })
            }
            return allCollections
        }
    }

    public func createCollection(
        name: String,
        libraryID: UUID?,
        isSmartCollection: Bool,
        predicate: String?
    ) async throws -> CollectionResult {
        try await checkAuthorization()
        logger.info("Creating collection: \(name)")

        // Resolve library ID
        let resolvedLibraryID: UUID
        if let libraryID = libraryID {
            resolvedLibraryID = libraryID
        } else if let defaultLib = await withStore({ $0.getDefaultLibrary() }) {
            resolvedLibraryID = defaultLib.id
        } else {
            throw AutomationOperationError.operationFailed("No library found to create collection in")
        }

        guard let collection = await withStore({ store in
            store.createCollection(
                name: name,
                libraryId: resolvedLibraryID,
                isSmart: isSmartCollection,
                query: predicate
            )
        }) else {
            throw AutomationOperationError.operationFailed("Failed to create collection")
        }

        return toCollectionResult(collection, libraryID: resolvedLibraryID)
    }

    public func deleteCollection(collectionID: UUID) async throws -> Bool {
        try await checkAuthorization()

        // Delete via the generic deleteItem (collections are items in the Rust store)
        await withStore { store in
            store.deleteItem(id: collectionID)
        }
        return true
    }

    public func addToCollection(papers: [PaperIdentifier], collectionID: UUID) async throws -> Int {
        try await checkAuthorization()

        var ids: [UUID] = []
        for identifier in papers {
            if let pub = await findPublication(by: identifier) {
                ids.append(pub.id)
            }
        }

        if !ids.isEmpty {
            await withStore { store in
                store.addToCollection(publicationIds: ids, collectionId: collectionID)
            }
        }

        return ids.count
    }

    public func removeFromCollection(papers: [PaperIdentifier], collectionID: UUID) async throws -> Int {
        try await checkAuthorization()

        var ids: [UUID] = []
        for identifier in papers {
            if let pub = await findPublication(by: identifier) {
                ids.append(pub.id)
            }
        }

        if !ids.isEmpty {
            await withStore { store in
                store.removeFromCollection(publicationIds: ids, collectionId: collectionID)
            }
        }

        return ids.count
    }

    // MARK: - Library Operations

    public func createLibrary(name: String) async throws -> LibraryResult {
        try await checkAuthorization()
        logger.info("Creating library: \(name)")

        guard let library = await withStore({ $0.createLibrary(name: name) }) else {
            throw AutomationOperationError.operationFailed("Failed to create library")
        }

        logger.info("Created library '\(name)' with ID: \(library.id)")
        return toLibraryResult(library)
    }

    public func listLibraries() async throws -> [LibraryResult] {
        try await checkAuthorization()

        let libraries = await withStore { $0.listLibraries() }
        return libraries.map { toLibraryResult($0) }
    }

    public func getDefaultLibrary() async throws -> LibraryResult? {
        try await checkAuthorization()

        guard let library = await withStore({ $0.getDefaultLibrary() }) else {
            return nil
        }
        return toLibraryResult(library)
    }

    public func getInboxLibrary() async throws -> LibraryResult? {
        try await checkAuthorization()

        guard let library = await withStore({ $0.getInboxLibrary() }) else {
            return nil
        }
        return toLibraryResult(library)
    }

    // MARK: - Export Operations

    public func exportBibTeX(identifiers: [PaperIdentifier]?) async throws -> ExportResult {
        try await checkAuthorization()

        if let identifiers = identifiers {
            // Export specific publications
            var ids: [UUID] = []
            for identifier in identifiers {
                if let pub = await findPublication(by: identifier) {
                    ids.append(pub.id)
                }
            }
            let content = await withStore { $0.exportBibTeX(ids: ids) }
            return ExportResult(format: "bibtex", content: content, paperCount: ids.count)
        } else {
            // Export all from default library
            guard let defaultLib = await withStore({ $0.getDefaultLibrary() }) else {
                return ExportResult(format: "bibtex", content: "", paperCount: 0)
            }
            let content = await withStore { $0.exportAllBibTeX(libraryId: defaultLib.id) }
            let count = defaultLib.publicationCount
            return ExportResult(format: "bibtex", content: content, paperCount: count)
        }
    }

    public func exportRIS(identifiers: [PaperIdentifier]?) async throws -> ExportResult {
        try await checkAuthorization()

        // RIS export not yet available in Rust store
        throw AutomationOperationError.operationFailed("RIS export not yet available with Rust store. Use BibTeX export instead.")
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

            if publication.hasDownloadedPDF {
                alreadyHad.append(publication.citeKey)
                continue
            }

            // Trigger PDF download via notification
            let pubID = publication.id
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .downloadPDF,
                    object: nil,
                    userInfo: ["publicationID": pubID]
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
                status[identifier.value] = publication.hasDownloadedPDF
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

        var ids: [UUID] = []
        for identifier in papers {
            if let pub = await findPublication(by: identifier) {
                ids.append(pub.id)
            }
        }

        if !ids.isEmpty {
            await withStore { store in
                store.addTag(ids: ids, tagPath: path)
            }
        }

        return ids.count
    }

    public func removeTag(path: String, from papers: [PaperIdentifier]) async throws -> Int {
        try await checkAuthorization()
        logger.info("Removing tag '\(path)' from \(papers.count) papers")

        var ids: [UUID] = []
        for identifier in papers {
            if let pub = await findPublication(by: identifier) {
                ids.append(pub.id)
            }
        }

        if !ids.isEmpty {
            await withStore { store in
                store.removeTag(ids: ids, tagPath: path)
            }
        }

        return ids.count
    }

    public func listTags(matching prefix: String?, limit: Int) async throws -> [TagResult] {
        try await checkAuthorization()

        let tags = await withStore { $0.listTagsWithCounts() }

        var filtered: [TagDefinition]
        if let prefix = prefix, !prefix.isEmpty {
            filtered = tags.filter { $0.path.lowercased().hasPrefix(prefix.lowercased()) }
        } else {
            filtered = tags
        }

        filtered = Array(filtered.prefix(limit))
        return filtered.map { toTagResult($0) }
    }

    public func getTagTree() async throws -> String {
        try await checkAuthorization()
        return await TagManagementService.shared.tagTree()
    }

    // MARK: - Flag Operations

    public func setFlag(color: String, style: String?, length: String?, papers: [PaperIdentifier]) async throws -> Int {
        try await checkAuthorization()
        logger.info("Setting flag '\(color)' on \(papers.count) papers")

        guard FlagColor(rawValue: color) != nil else {
            throw AutomationOperationError.operationFailed("Invalid flag color: \(color). Use: red, amber, blue, gray")
        }

        var ids: [UUID] = []
        for identifier in papers {
            if let pub = await findPublication(by: identifier) {
                ids.append(pub.id)
            }
        }

        if !ids.isEmpty {
            await withStore { store in
                store.setFlag(ids: ids, color: color, style: style, length: length)
            }
        }

        return ids.count
    }

    public func clearFlag(papers: [PaperIdentifier]) async throws -> Int {
        try await checkAuthorization()
        logger.info("Clearing flag from \(papers.count) papers")

        var ids: [UUID] = []
        for identifier in papers {
            if let pub = await findPublication(by: identifier) {
                ids.append(pub.id)
            }
        }

        if !ids.isEmpty {
            await withStore { store in
                store.setFlag(ids: ids, color: nil)
            }
        }

        return ids.count
    }

    // MARK: - Collection Papers

    public func listPapersInCollection(
        collectionID: UUID,
        limit: Int,
        offset: Int
    ) async throws -> (papers: [PaperResult], totalCount: Int) {
        try await checkAuthorization()

        let allPubs = await withStore { store in
            store.listCollectionMembers(collectionId: collectionID)
        }

        let totalCount = allPubs.count
        let paginated = Array(allPubs.dropFirst(offset).prefix(limit))
        let papers = paginated.map { toPaperResult($0) }

        return (papers: papers, totalCount: totalCount)
    }

    // MARK: - Participant Operations

    public func listParticipants(libraryID: UUID) async throws -> [ParticipantResult] {
        try await checkAuthorization()

        // TODO: CloudKit sharing not yet available with Rust store
        return []
    }

    public func setParticipantPermission(
        libraryID: UUID,
        participantID: String,
        permission: String
    ) async throws {
        try await checkAuthorization()

        // TODO: CloudKit sharing not yet available with Rust store
        throw AutomationOperationError.sharingUnavailable
    }

    // MARK: - Activity Feed Operations

    public func recentActivity(libraryID: UUID, limit: Int) async throws -> [ActivityResult] {
        try await checkAuthorization()

        let records = await withStore { store in
            store.listActivityRecords(libraryId: libraryID, limit: UInt32(limit))
        }

        return records.map { toActivityResult($0) }
    }

    // MARK: - Comment Operations

    public func listComments(publicationIdentifier: PaperIdentifier) async throws -> [CommentResult] {
        try await checkAuthorization()

        guard let publication = await findPublication(by: publicationIdentifier) else {
            throw AutomationOperationError.paperNotFound(publicationIdentifier.value)
        }

        let comments = await withStore { store in
            store.listComments(publicationId: publication.id)
        }

        return buildCommentTree(from: comments)
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

        // Get current user info
        let authorName: String
        #if os(macOS)
        authorName = Host.current().localizedName ?? "Unknown"
        #else
        authorName = UIDevice.current.name
        #endif

        guard let comment = await withStore({ store in
            store.createComment(
                publicationId: publication.id,
                text: text,
                authorIdentifier: nil,
                authorDisplayName: authorName,
                parentCommentId: parentCommentID
            )
        }) else {
            throw AutomationOperationError.operationFailed("Failed to create comment")
        }

        logger.info("Added comment to '\(publication.citeKey)'")
        return toCommentResult(comment)
    }

    public func deleteComment(commentID: UUID) async throws {
        try await checkAuthorization()

        // Delete comment via generic deleteItem
        await withStore { store in
            store.deleteItem(id: commentID)
        }

        logger.info("Deleted comment \(commentID)")
    }

    // MARK: - Assignment Operations

    public func listAssignments(libraryID: UUID) async throws -> [AssignmentResult] {
        try await checkAuthorization()

        // List all assignments (Rust store doesn't filter by library directly,
        // so we filter in Swift)
        let assignments = await withStore { store in
            store.listAssignments()
        }

        // Filter by library
        let filtered = assignments.filter { $0.libraryID == libraryID }
        return filtered.map { toAssignmentResult($0) }
    }

    public func listAssignmentsForPublication(publicationIdentifier: PaperIdentifier) async throws -> [AssignmentResult] {
        try await checkAuthorization()

        guard let publication = await findPublication(by: publicationIdentifier) else {
            throw AutomationOperationError.paperNotFound(publicationIdentifier.value)
        }

        let assignments = await withStore { store in
            store.listAssignments(publicationId: publication.id)
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

        // Get current user info for "assigned by"
        let assignedByName: String
        #if os(macOS)
        assignedByName = Host.current().localizedName ?? "Unknown"
        #else
        assignedByName = UIDevice.current.name
        #endif

        let dueDateMs: Int64? = dueDate.map { Int64($0.timeIntervalSince1970 * 1000) }

        guard let assignment = await withStore({ store in
            store.createAssignment(
                publicationId: publication.id,
                assigneeName: assigneeName,
                assignedByName: assignedByName,
                note: note,
                dueDate: dueDateMs
            )
        }) else {
            throw AutomationOperationError.operationFailed("Failed to create assignment")
        }

        logger.info("Created assignment: '\(publication.citeKey)' suggested to '\(assigneeName)'")
        return toAssignmentResult(assignment)
    }

    public func deleteAssignment(assignmentID: UUID) async throws {
        try await checkAuthorization()

        await withStore { store in
            store.deleteItem(id: assignmentID)
        }

        logger.info("Deleted assignment \(assignmentID)")
    }

    public func participantNames(libraryID: UUID) async throws -> [String] {
        try await checkAuthorization()

        // TODO: CloudKit sharing not yet available with Rust store
        // Return unique assignee names from assignments as a fallback
        let assignments = await withStore { store in
            store.listAssignments()
        }

        let names = Set(assignments.map(\.assigneeName))
        return Array(names).sorted()
    }

    // MARK: - Sharing Operations

    public func shareLibrary(libraryID: UUID) async throws -> ShareResult {
        try await checkAuthorization()

        // TODO: CloudKit sharing not yet available with Rust store
        throw AutomationOperationError.sharingUnavailable
    }

    public func unshareLibrary(libraryID: UUID) async throws {
        try await checkAuthorization()

        // TODO: CloudKit sharing not yet available with Rust store
        throw AutomationOperationError.sharingUnavailable
    }

    public func leaveShare(libraryID: UUID, keepCopy: Bool) async throws {
        try await checkAuthorization()

        // TODO: CloudKit sharing not yet available with Rust store
        throw AutomationOperationError.sharingUnavailable
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

        // Get linked files for this publication
        let linkedFiles = await withStore { store in
            store.listLinkedFiles(publicationId: publication.id)
        }

        guard let linkedFile = linkedFiles.first(where: { $0.isPDF }) else {
            throw AutomationOperationError.linkedFileNotFound(publication.citeKey)
        }

        let annotations = await withStore { store in
            store.listAnnotations(linkedFileId: linkedFile.id, pageNumber: pageNumber.map { Int32($0) })
        }

        return annotations.map { toAnnotationResult($0) }
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

        // Get linked files for this publication
        let linkedFiles = await withStore { store in
            store.listLinkedFiles(publicationId: publication.id)
        }

        guard let linkedFile = linkedFiles.first(where: { $0.isPDF }) else {
            throw AutomationOperationError.linkedFileNotFound(publication.citeKey)
        }

        // Validate annotation type
        guard let annotationType = AnnotationType(rawValue: type) else {
            throw AutomationOperationError.operationFailed("Invalid annotation type: \(type). Use: highlight, underline, strikethrough, note, freeText")
        }

        let hexColor = color ?? annotationType.defaultColor

        // Set default bounds for note annotations
        let boundsJson: String?
        if annotationType == .note || annotationType == .freeText {
            boundsJson = "{\"x\":50,\"y\":50,\"width\":200,\"height\":100}"
        } else {
            boundsJson = nil
        }

        guard let annotation = await withStore({ store in
            store.createAnnotation(
                linkedFileId: linkedFile.id,
                annotationType: type,
                pageNumber: Int64(pageNumber),
                boundsJson: boundsJson,
                color: hexColor,
                contents: contents,
                selectedText: selectedText
            )
        }) else {
            throw AutomationOperationError.operationFailed("Failed to create annotation")
        }

        logger.info("Added \(type) annotation to '\(publication.citeKey)' page \(pageNumber)")
        return toAnnotationResult(annotation)
    }

    /// Delete an annotation by ID.
    public func deleteAnnotation(annotationID: UUID) async throws {
        try await checkAuthorization()

        await withStore { store in
            store.deleteItem(id: annotationID)
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

        // PublicationRowData has `note` field
        return publication.note
    }

    /// Update the notes for a publication.
    public func updateNotes(publicationIdentifier: PaperIdentifier, notes: String?) async throws {
        try await checkAuthorization()

        guard let publication = await findPublication(by: publicationIdentifier) else {
            throw AutomationOperationError.paperNotFound(publicationIdentifier.value)
        }

        await withStore { store in
            store.updateField(id: publication.id, field: "note", value: notes)
        }

        logger.info("Updated notes for '\(publication.citeKey)'")
    }

    // MARK: - Conversion Helpers

    private func toPaperResult(_ pub: PublicationRowData) -> PaperResult {
        let tagPaths = pub.tagDisplays.map(\.path).sorted()

        let flagResult: FlagResult? = pub.flag.map {
            FlagResult(
                color: $0.color.rawValue,
                style: $0.style.rawValue,
                length: $0.length.rawValue
            )
        }

        return PaperResult(
            id: pub.id,
            citeKey: pub.citeKey,
            title: pub.title,
            authors: parseAuthors(from: pub.authorString),
            year: pub.year,
            venue: pub.venue,
            abstract: pub.abstract,
            doi: pub.doi,
            arxivID: pub.arxivID,
            bibcode: pub.bibcode,
            pmid: nil,  // Not available in PublicationRowData
            semanticScholarID: nil,  // Not available in PublicationRowData
            openAlexID: nil,  // Not available in PublicationRowData
            isRead: pub.isRead,
            isStarred: pub.isStarred,
            hasPDF: pub.hasDownloadedPDF,
            citationCount: pub.citationCount > 0 ? pub.citationCount : nil,
            dateAdded: pub.dateAdded,
            dateModified: pub.dateModified,
            bibtex: "",  // BibTeX not in row data; use exportBibTeX for full text
            webURL: nil,  // Not available in PublicationRowData
            pdfURLs: [],  // Not available in PublicationRowData
            tags: tagPaths,
            flag: flagResult,
            collectionIDs: [],  // Not available in PublicationRowData
            libraryIDs: [],  // Not available in PublicationRowData
            notes: pub.note,
            annotationCount: 0  // Not available in PublicationRowData
        )
    }

    /// Convert a full detail model to PaperResult (richer data).
    private func toPaperResultFromDetail(_ pub: PublicationModel) -> PaperResult {
        let tagPaths = pub.tags.map(\.path).sorted()

        let flagResult: FlagResult? = pub.flag.map {
            FlagResult(
                color: $0.color.rawValue,
                style: $0.style.rawValue,
                length: $0.length.rawValue
            )
        }

        return PaperResult(
            id: pub.id,
            citeKey: pub.citeKey,
            title: pub.title,
            authors: pub.authors.map(\.displayName),
            year: pub.year,
            venue: pub.journal ?? pub.booktitle,
            abstract: pub.abstract,
            doi: pub.doi,
            arxivID: pub.arxivID,
            bibcode: pub.bibcode,
            pmid: pub.pmid,
            semanticScholarID: pub.fields["semantic_scholar_id"],
            openAlexID: pub.fields["openalex_id"],
            isRead: pub.isRead,
            isStarred: pub.isStarred,
            hasPDF: pub.hasDownloadedPDF || !pub.linkedFiles.isEmpty,
            citationCount: pub.citationCount > 0 ? pub.citationCount : nil,
            dateAdded: pub.dateAdded,
            dateModified: pub.dateModified,
            bibtex: pub.rawBibTeX ?? "",
            webURL: pub.url,
            pdfURLs: [],
            tags: tagPaths,
            flag: flagResult,
            collectionIDs: pub.collectionIDs,
            libraryIDs: pub.libraryIDs,
            notes: pub.note,
            annotationCount: 0
        )
    }

    private func parseAuthors(from authorString: String) -> [String] {
        // PublicationRowData.authorString is pre-formatted as "Last1, Last2 ... LastN"
        // Split by comma for the automation result
        return authorString
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "..." }
    }

    private func toCollectionResult(_ collection: CollectionModel, libraryID: UUID? = nil, libraryName: String? = nil) -> CollectionResult {
        CollectionResult(
            id: collection.id,
            name: collection.name,
            paperCount: collection.publicationCount,
            isSmartCollection: collection.isSmart,
            libraryID: libraryID,
            libraryName: libraryName
        )
    }

    private func toLibraryResult(_ library: LibraryModel) -> LibraryResult {
        LibraryResult(
            id: library.id,
            name: library.name,
            paperCount: library.publicationCount,
            collectionCount: 0,  // Would need separate query; omit for now
            isDefault: library.isDefault,
            isInbox: library.isInbox,
            isShared: false,  // CloudKit sharing not yet available with Rust store
            isShareOwner: false,
            participantCount: 0,
            canEdit: true
        )
    }

    private func toTagResult(_ tag: TagDefinition) -> TagResult {
        // Extract parent path from the tag path
        let components = tag.path.components(separatedBy: "/")
        let parentPath = components.count > 1
            ? components.dropLast().joined(separator: "/")
            : nil

        return TagResult(
            id: UUID(),  // TagDefinition uses path as ID, generate UUID for TagResult
            name: tag.leafName,
            canonicalPath: tag.path,
            parentPath: parentPath,
            useCount: tag.publicationCount,
            publicationCount: tag.publicationCount
        )
    }

    private func toActivityResult(_ record: ActivityRecord) -> ActivityResult {
        ActivityResult(
            id: record.id,
            activityType: record.activityType,
            actorDisplayName: record.actorDisplayName,
            targetTitle: record.targetTitle,
            targetID: record.targetID.flatMap { UUID(uuidString: $0) },
            detail: record.detail,
            date: record.date
        )
    }

    private func toCommentResult(_ comment: Comment) -> CommentResult {
        CommentResult(
            id: comment.id,
            text: comment.text,
            authorDisplayName: comment.authorDisplayName,
            authorIdentifier: comment.authorIdentifier,
            dateCreated: comment.dateCreated,
            dateModified: comment.dateModified,
            parentCommentID: comment.parentCommentID,
            replies: []
        )
    }

    /// Build a threaded comment tree from a flat list of comments.
    private func buildCommentTree(from comments: [Comment]) -> [CommentResult] {
        // Find top-level comments (no parent)
        let topLevel = comments.filter { $0.parentCommentID == nil }

        return topLevel
            .sorted { $0.dateCreated < $1.dateCreated }
            .map { comment in
                let replies = comments
                    .filter { $0.parentCommentID == comment.id }
                    .sorted { $0.dateCreated < $1.dateCreated }
                    .map { reply in
                        CommentResult(
                            id: reply.id,
                            text: reply.text,
                            authorDisplayName: reply.authorDisplayName,
                            authorIdentifier: reply.authorIdentifier,
                            dateCreated: reply.dateCreated,
                            dateModified: reply.dateModified,
                            parentCommentID: reply.parentCommentID,
                            replies: []  // Only one level of nesting for now
                        )
                    }

                return CommentResult(
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
    }

    private func toAssignmentResult(_ assignment: Assignment) -> AssignmentResult {
        AssignmentResult(
            id: assignment.id,
            publicationID: assignment.publicationID,
            publicationTitle: nil,  // Would need extra lookup; omit for efficiency
            publicationCiteKey: nil,
            assigneeName: assignment.assigneeName,
            assignedByName: assignment.assignedByName,
            note: assignment.note,
            dateCreated: assignment.dateCreated,
            dueDate: assignment.dueDate,
            libraryID: assignment.libraryID
        )
    }

    private func toAnnotationResult(_ annotation: AnnotationModel) -> AnnotationResult {
        AnnotationResult(
            id: annotation.id,
            type: annotation.annotationType,
            pageNumber: annotation.pageNumber,
            contents: annotation.contents,
            selectedText: annotation.selectedText,
            color: annotation.color ?? "#FFFF00",
            author: annotation.authorName,
            dateCreated: annotation.dateCreated,
            dateModified: annotation.dateModified
        )
    }
}

// MARK: - Notification Names

public extension Notification.Name {
    static let downloadPDF = Notification.Name("com.imbib.downloadPDF")
}
