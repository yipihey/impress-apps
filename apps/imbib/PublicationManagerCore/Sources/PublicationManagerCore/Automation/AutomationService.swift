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

    /// Delete a single library. Optionally removes its file container too.
    /// Mirrors `LibraryManager.deleteLibrary(id:deleteFiles:)` for the HTTP /
    /// AppIntents / MCP path that has no view-model in scope. Papers are
    /// **unlinked**, not cascade-deleted; restorable via Edit → Undo.
    public func deleteLibrary(id: UUID, deleteFiles: Bool = false) async throws -> Bool {
        try await checkAuthorization()

        if deleteFiles {
            let containerURL = await MainActor.run { LibraryManager.containerURL(for: id) }
            if FileManager.default.fileExists(atPath: containerURL.path) {
                try? FileManager.default.removeItem(at: containerURL)
            }
        }

        await withStore { store in
            store.deleteLibrary(id: id)
        }
        return true
    }

    /// Delete multiple libraries in one consolidated batch. Wraps the per-id
    /// deletes in `beginBatchMutation` / `endBatchMutation` so observers fire
    /// once. Matches the on-device `LibraryManager.deleteLibraries(ids:)` semantics.
    public func deleteLibraries(ids: [UUID], deleteFiles: Bool = false) async throws -> Int {
        try await checkAuthorization()
        guard !ids.isEmpty else { return 0 }

        if deleteFiles {
            let urls = await MainActor.run { ids.map(LibraryManager.containerURL(for:)) }
            for url in urls where FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
        }

        await withStore { store in
            store.beginBatchMutation()
            for id in ids { store.deleteLibrary(id: id) }
            store.endBatchMutation()
        }
        return ids.count
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

    // MARK: - Structured Citation Resolution

    /// Resolve a structured citation into a single imbib paper or a ranked
    /// list of external candidates.
    ///
    /// Cascade, in order (short-circuits at first success):
    ///   1. Try to extract a DOI / arXiv id / bibcode / PMID from the
    ///      provided identifier fields or `rawBibtex`. If any is found:
    ///      • look it up locally → return `via: "local-identifier"`
    ///      • otherwise `addPapers(...)` → return `via: "imported-identifier"`
    ///   2. Search the local library by title text. Single hit →
    ///      `via: "local-text"`.
    ///   3. Build a structured ADS query via `SearchFormQueryBuilder` from
    ///      (authors, title, year). Search ADS only. Score each hit against
    ///      the `CitationInput`. If the top score ≥ 0.85 AND there is no
    ///      other candidate within 0.15 of it → auto-accept, add the paper,
    ///      return `via: "ads-high-confidence"`. Otherwise return ranked
    ///      candidates, `via: "ads-candidates"`.
    ///   4. If ADS returned zero hits, fan out to all sources with the
    ///      `freeText` query (or a synthesized "FirstAuthor Year Title"),
    ///      dedup, score, return `via: "all-sources-fallback"`.
    ///   5. Nothing anywhere → `via: "not-found"`.
    public func resolveStructuredCitation(
        _ input: CitationInput,
        library: UUID?,
        downloadPDFs: Bool = false,
        importIfMissing: Bool = true
    ) async throws -> StructuredResolveResult {
        try await checkAuthorization()
        Logger.sources.infoCapture(
            "resolveStructured: authors=\(input.authors.count) year=\(input.year.map(String.init) ?? "?") journal=\(input.journal ?? "?") hasID=\(input.hasIdentifier) hasTitle=\(input.title?.isEmpty == false) import=\(importIfMissing)",
            category: "citations"
        )

        // Decode LaTeX everywhere — authors/title/journal/raw bibtex may
        // arrive with `\'e`, `\&`, `\textit{...}`, etc.
        let decodedAuthors = input.authors.map { LaTeXDecoder.decode($0) }
        let decodedTitle = input.title.map { LaTeXDecoder.decode($0) }
        let decodedJournal = input.journal.map { LaTeXDecoder.decode($0) }
        let decodedBibtex = input.rawBibtex.map { LaTeXDecoder.decode($0) } ?? ""

        // Step 1: identifier path.
        let identifier: PaperIdentifier? = {
            if let doi = input.doi, !doi.isEmpty { return .doi(doi) }
            if let arxiv = input.arxiv, !arxiv.isEmpty { return .arxiv(arxiv) }
            if let bib = input.bibcode, !bib.isEmpty { return .bibcode(bib) }
            return Self.extractIdentifierFromBibTeX(decodedBibtex)
        }()

        if let id = identifier {
            Logger.sources.infoCapture("resolveStructured: identifier \(id.typeName)=\(id.value)", category: "citations")
            if let paper = try await getPaper(identifier: id) {
                return StructuredResolveResult(via: "local-identifier", paper: paper)
            }
            if importIfMissing {
                // Not local — import via the appropriate source, return the
                // imported paper. This is the HTTP/MCP `/api/papers/resolve`
                // contract: callers expect the paper to exist after the call.
                let addResult = try await addPapers(
                    identifiers: [id],
                    collection: nil,
                    library: library,
                    downloadPDFs: downloadPDFs
                )
                if let added = addResult.added.first {
                    return StructuredResolveResult(via: "imported-identifier", paper: added)
                }
                if !addResult.duplicates.isEmpty {
                    // Rare: duplicate detection caught it after our miss.
                    if let paper = try await getPaper(identifier: id) {
                        return StructuredResolveResult(via: "duplicate", paper: paper)
                    }
                }
                // Fall through to structured search — the identifier may have
                // been malformed or the source might not have responded.
            } else {
                // Preview mode (Smart Search). Don't write to the library —
                // fetch metadata only and return as a single ranked candidate
                // so the user can confirm via Add Selected.
                if let preview = try? await previewByIdentifier(id) {
                    return StructuredResolveResult(
                        via: "external-identifier-preview",
                        candidates: [preview]
                    )
                }
                // Fall through to structured search if the source had nothing.
            }
        }

        // Step 2: local text search by title OR by raw bibtex fragment.
        // Many manuscripts have no explicit title in their `\bibitem` block,
        // so we also try the full reference line as a query — imbib's SQL
        // search matches on title and author fields.
        let localSearchQuery: String? = {
            if let title = decodedTitle, title.count >= 10 { return title }
            if !decodedBibtex.isEmpty { return String(decodedBibtex.prefix(120)) }
            return nil
        }()
        if let lq = localSearchQuery {
            let filters = SearchFilters(limit: 5)
            let hits = try await searchLibrary(query: lq, filters: filters)
            // Score each local hit with the same heuristic we use for external
            // candidates. A strong match wins even when the DB has many
            // superficial title hits.
            let scored = hits.map { hit -> (PaperResult, Double) in
                let ext = ExternalSearchResult(
                    title: hit.title,
                    authors: hit.authors,
                    year: hit.year,
                    venue: hit.venue ?? "",
                    abstract: hit.abstract ?? "",
                    sourceID: "local",
                    doi: hit.doi,
                    arxivID: hit.arxivID,
                    bibcode: hit.bibcode
                )
                let score = scoreCandidate(
                    ext,
                    against: input,
                    decodedAuthors: decodedAuthors,
                    decodedTitle: decodedTitle,
                    decodedJournal: decodedJournal
                )
                return (hit, score)
            }.sorted { $0.1 > $1.1 }
            if let (top, topScore) = scored.first, topScore >= 0.55 {
                Logger.sources.infoCapture(
                    "resolveStructured: local-text hit '\(top.title)' score=\(String(format: "%.2f", topScore))",
                    category: "citations"
                )
                return StructuredResolveResult(via: "local-text", paper: top)
            }
        }

        // Step 3: structured ADS search.
        let adsQuery = buildADSQuery(
            authors: decodedAuthors,
            title: decodedTitle,
            year: input.year,
            database: input.preferredDatabase
        )
        var adsCandidates: [RankedCandidate] = []
        var adsUnavailableReason: String?
        if !adsQuery.isEmpty {
            Logger.sources.infoCapture("resolveStructured: ADS query = '\(adsQuery)'", category: "citations")
            // Try ADS up to twice — a single 429 at startup (from SciX
            // sync hammering the shared rate limit) shouldn't kill the
            // whole ADS pass. Sleep 1.2s between attempts.
            var attempt = 0
            let maxAttempts = 2
            while attempt < maxAttempts {
                attempt += 1
                do {
                    let adsResults = try await sourceManager.search(
                        query: adsQuery,
                        sourceID: "ads",
                        maxResults: 10
                    )
                    Logger.sources.infoCapture(
                        "resolveStructured: ADS (attempt \(attempt)) returned \(adsResults.count) result(s)",
                        category: "citations"
                    )
                    adsCandidates = adsResults
                        .map { result in
                            let ext = Self.toExternalSearchResult(result)
                            let score = scoreCandidate(
                                ext,
                                against: input,
                                decodedAuthors: decodedAuthors,
                                decodedTitle: decodedTitle,
                                decodedJournal: decodedJournal
                            )
                            return RankedCandidate(result: ext, confidence: score)
                        }
                        .sorted { $0.confidence > $1.confidence }
                    adsUnavailableReason = nil
                    break
                } catch let error as SourceError {
                    switch error {
                    case .authenticationRequired:
                        adsUnavailableReason = "ADS API key not configured (imbib Settings → Sources → ADS)"
                        attempt = maxAttempts   // no point retrying
                    case .rateLimited(let retryAfter):
                        adsUnavailableReason = "ADS rate-limited (retry after \(retryAfter.map(String.init(describing:)) ?? "unknown")s); using secondary sources"
                        if attempt < maxAttempts {
                            Logger.sources.warningCapture(
                                "resolveStructured: ADS rate-limited on attempt \(attempt), retrying in 1.2s",
                                category: "citations"
                            )
                            try? await Task.sleep(for: .milliseconds(1200))
                            continue
                        }
                    default:
                        adsUnavailableReason = "ADS error: \(error.localizedDescription)"
                        attempt = maxAttempts
                    }
                    Logger.sources.warningCapture(
                        "resolveStructured: ADS unavailable after \(attempt) attempt(s) — \(adsUnavailableReason ?? "")",
                        category: "citations"
                    )
                } catch {
                    adsUnavailableReason = "ADS error: \(error.localizedDescription)"
                    Logger.sources.warningCapture(
                        "resolveStructured: ADS search failed — \(error.localizedDescription)",
                        category: "citations"
                    )
                    attempt = maxAttempts
                }
            }
        }

        // Auto-accept from ADS — three paths:
        //   (a) High-confidence top with clear margin over runner-up.
        //   (b) ADS returned exactly ONE candidate with confidence ≥ 0.50.
        //       The structured query (`author:"X" year:Y bibstem:Z
        //       volume:V page:P`) is precise enough that a single hit means
        //       "this is the paper."
        //   (c) Two candidates where the top is ≥ 0.70 and the margin
        //       over second is ≥ 0.25 — ADS sometimes duplicates
        //       preprint + published; prefer top.
        let shouldAutoAccept: Bool = {
            guard let top = adsCandidates.first else { return false }
            let runnerUp = adsCandidates.dropFirst().first?.confidence ?? 0
            if top.confidence >= 0.85 && (top.confidence - runnerUp) >= 0.15 {
                return true
            }
            if adsCandidates.count == 1 && top.confidence >= 0.50 {
                return true
            }
            if top.confidence >= 0.70 && (top.confidence - runnerUp) >= 0.25 {
                return true
            }
            return false
        }()
        if shouldAutoAccept, let top = adsCandidates.first {
            if importIfMissing {
                let bestID = Self.bestIdentifier(from: top.result)
                if let id = bestID {
                    Logger.sources.infoCapture(
                        "resolveStructured: auto-accepting top ADS hit (confidence=\(String(format: "%.2f", top.confidence))): \(top.result.title)",
                        category: "citations"
                    )
                    let addResult = try await addPapers(
                        identifiers: [id],
                        collection: nil,
                        library: library,
                        downloadPDFs: downloadPDFs
                    )
                    if let added = addResult.added.first {
                        return StructuredResolveResult(via: "ads-high-confidence", paper: added)
                    }
                    if let duplicate = addResult.duplicates.first,
                       let paper = try await getPaper(identifier: PaperIdentifier.fromString(duplicate)) {
                        return StructuredResolveResult(via: "duplicate", paper: paper)
                    }
                }
                // Fell through — still return as a top candidate.
            } else {
                Logger.sources.infoCapture(
                    "resolveStructured: high-confidence ADS hit returned as preview (confidence=\(String(format: "%.2f", top.confidence))): \(top.result.title)",
                    category: "citations"
                )
                return StructuredResolveResult(
                    via: "ads-high-confidence-preview",
                    candidates: [top]
                )
            }
        }

        if !adsCandidates.isEmpty {
            // Filter out low-confidence junk — a 0.15 candidate from ADS is
            // still garbage; without at least an author+year match there's
            // no reason to surface it.
            let keep = adsCandidates.filter { $0.confidence >= 0.30 }
            if !keep.isEmpty {
                return StructuredResolveResult(
                    via: "ads-candidates",
                    candidates: Array(keep.prefix(10))
                )
            }
        }

        // Step 4: all-sources fallback. Build a richer query than bare
        // "FirstAuthor Year" — add the journal name when we have it so
        // openalex/crossref can narrow down by venue.
        let fallbackQuery = Self.richFallbackQuery(
            authors: decodedAuthors,
            year: input.year,
            title: decodedTitle,
            journal: decodedJournal,
            providedFreeText: input.freeText
        )
        if !fallbackQuery.isEmpty {
            Logger.sources.infoCapture("resolveStructured: all-sources fallback = '\(fallbackQuery)'", category: "citations")
            do {
                let allResults = try await sourceManager.search(
                    query: fallbackQuery,
                    options: SearchOptions(maxResults: 20)
                )
                Logger.sources.infoCapture(
                    "resolveStructured: all-sources returned \(allResults.count) raw result(s)",
                    category: "citations"
                )
                let dedup = Self.dedupByIdentifier(allResults)
                let candidates = dedup
                    .map { result -> RankedCandidate in
                        let ext = Self.toExternalSearchResult(result)
                        let score = scoreCandidate(
                            ext,
                            against: input,
                            decodedAuthors: decodedAuthors,
                            decodedTitle: decodedTitle,
                            decodedJournal: decodedJournal
                        )
                        return RankedCandidate(result: ext, confidence: score)
                    }
                    .sorted { $0.confidence > $1.confidence }

                // Same filter as ADS — don't surface garbage. Without any
                // match on author surname or year this is noise.
                let kept = candidates.filter { $0.confidence >= 0.30 }
                Logger.sources.infoCapture(
                    "resolveStructured: all-sources kept \(kept.count)/\(candidates.count) after confidence filter (top=\(String(format: "%.2f", candidates.first?.confidence ?? 0)))",
                    category: "citations"
                )
                if !kept.isEmpty {
                    return StructuredResolveResult(
                        via: "all-sources-fallback",
                        candidates: Array(kept.prefix(10))
                    )
                }
            } catch {
                Logger.sources.warningCapture(
                    "resolveStructured: fallback search failed for '\(fallbackQuery)': \(error.localizedDescription)",
                    category: "citations"
                )
            }
        }

        let reason: String = {
            if let adsReason = adsUnavailableReason {
                return "No relevant matches. \(adsReason). Consider configuring ADS to improve results for astronomy papers."
            }
            return "No external source returned a confident match for this citation"
        }()
        return StructuredResolveResult(via: "not-found", reason: reason)
    }

    // MARK: - Structured resolution helpers

    /// Build an ADS Lucene query string via `SearchFormQueryBuilder` from
    /// decoded structured inputs. Returns "" when there's nothing to search.
    private func buildADSQuery(
        authors: [String],
        title: String?,
        year: Int?,
        database: String?
    ) -> String {
        // Only include author lines that look like real surnames. Strip
        // trailing ranks/numbers and "et al.".
        let authorLines = authors
            .map { $0.replacingOccurrences(of: #"(?i)\s*et\s*al\.?\s*"#, with: "", options: .regularExpression) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        // Filter title words: ≥4 chars, not a stopword. Hand ADS only
        // terms that actually narrow the search; otherwise `title:(The AND
        // ...)` matches nothing because `The` is filtered by ADS's own
        // stopword list and the AND short-circuits.
        let titleWords = Self.titleSearchWords(from: title ?? "").joined(separator: " ")
        let db: ADSDatabase = {
            switch database?.lowercased() {
            case "astronomy": return .astronomy
            case "physics": return .physics
            case "arxiv": return .arxiv
            case "all", "", nil: return .all
            default: return .all
            }
        }()
        return SearchFormQueryBuilder.buildClassicQuery(
            authors: authorLines,
            objects: "",
            titleWords: titleWords,
            titleLogic: .and,
            abstractWords: "",
            abstractLogic: .and,
            yearFrom: year,
            yearTo: year,
            database: db,
            refereedOnly: false,
            articlesOnly: false
        )
    }

    /// Score a candidate against structured input. Heuristic only — used to
    /// rank and to decide whether to auto-accept.
    ///
    /// Points (out of 1.0):
    ///   • first-author last-name match → 0.25
    ///   • year exact match             → 0.20
    ///   • journal (bibstem) match      → 0.20
    ///   • title contains 3+ query words → up to 0.20
    ///   • has a usable identifier      → 0.15
    private func scoreCandidate(
        _ c: ExternalSearchResult,
        against input: CitationInput,
        decodedAuthors: [String],
        decodedTitle: String?,
        decodedJournal: String?
    ) -> Double {
        var score = 0.0

        // Author match — use first author's last name.
        if let queryAuthor = decodedAuthors.first,
           let candidateAuthor = c.authors.first {
            let qLast = Self.lastName(from: queryAuthor).lowercased()
            let cLast = Self.lastName(from: candidateAuthor).lowercased()
            if !qLast.isEmpty && qLast == cLast {
                score += 0.25
            } else if !qLast.isEmpty && cLast.contains(qLast) {
                score += 0.15
            }
        }

        // Year match.
        if let y = input.year, c.year == y {
            score += 0.20
        } else if let y = input.year, let cy = c.year, abs(cy - y) <= 1 {
            score += 0.08
        }

        // Journal / venue match. Users typically send a short bibstem
        // ("JCAP", "ApJ", "MNRAS"), while ADS / OpenAlex / Crossref
        // return the full journal name. Normalize both sides to a
        // bibstem-ish form before comparing.
        if let j = decodedJournal,
           !j.isEmpty,
           !c.venue.isEmpty {
            let jLow = j.lowercased()
            let vLow = c.venue.lowercased()
            if vLow.contains(jLow) || jLow.contains(vLow) {
                score += 0.20
            } else if Self.venueMatchesBibstem(venue: c.venue, bibstem: j) {
                score += 0.20
            }
        }

        // Title overlap.
        if let t = decodedTitle, !t.isEmpty, !c.title.isEmpty {
            let queryWords = Set(
                t.lowercased()
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { $0.count >= 4 }
            )
            let titleWords = Set(
                c.title.lowercased()
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { $0.count >= 4 }
            )
            let overlap = queryWords.intersection(titleWords).count
            if overlap >= 5 {
                score += 0.20
            } else if overlap >= 3 {
                score += 0.12
            } else if overlap >= 1 {
                score += 0.05
            }
        }

        // Has a usable identifier (so we can actually import it) — but only
        // reward this if there's already *some* real match above zero. A
        // completely unrelated paper that happens to have a DOI shouldn't
        // edge past the filter on ID alone.
        if score > 0,
           (c.doi?.isEmpty == false) || (c.arxivID?.isEmpty == false) || (c.bibcode?.isEmpty == false) {
            score += 0.15
        }

        return min(1.0, score)
    }

    /// Cross-check: does `venue` (e.g. "Journal of Cosmology and
    /// Astroparticle Physics") correspond to the short-form `bibstem`
    /// (e.g. "JCAP") the caller provided? ADS/OpenAlex/Crossref return
    /// full venue strings; callers send bibstems. This dictionary covers
    /// the most common astronomy/physics journals.
    ///
    /// Matching is case-insensitive and tolerant of extra whitespace
    /// and punctuation in the venue.
    private static func venueMatchesBibstem(venue: String, bibstem: String) -> Bool {
        let bib = bibstem
            .replacingOccurrences(of: ".", with: "")
            .trimmingCharacters(in: .whitespaces)
            .uppercased()
        let v = venue.lowercased()
        let expansions: [String: [String]] = [
            "APJ": ["astrophysical journal"],
            "APJL": ["astrophysical journal letters"],
            "APJS": ["astrophysical journal supplement"],
            "MNRAS": ["monthly notices", "mon not r astron soc"],
            "JCAP": ["journal of cosmology and astroparticle", "cosmology and astroparticle physics"],
            "JHEP": ["journal of high energy physics"],
            "PHRVD": ["physical review d", "phys rev d", "phys. rev. d"],
            "PHRVL": ["physical review letters", "phys rev lett", "phys. rev. lett"],
            "PHRV": ["physical review"],
            "NUPHB": ["nuclear physics b"],
            "NUPHA": ["nuclear physics a"],
            "NATUR": ["nature"],
            "NATAS": ["nature astronomy"],
            "SCI": ["science"],
            "A&A": ["astronomy and astrophysics", "astronomy & astrophysics"],
            "PHLB": ["physics letters b"],
            "PHLA": ["physics letters a"],
            "PRD": ["physical review d"],
            "PRL": ["physical review letters"]
        ]
        if let needles = expansions[bib] {
            for n in needles where v.contains(n) {
                return true
            }
        }
        return false
    }

    /// Title words worth feeding an ADS `title:(... AND ...)` clause.
    /// Drops stopwords and tokens shorter than 4 characters.
    private static func titleSearchWords(from title: String) -> [String] {
        let stop: Set<String> = [
            "the", "and", "for", "with", "from", "that", "this", "these",
            "those", "their", "about", "into", "onto", "over", "under",
            "upon", "after", "before", "between", "within", "without",
            "new", "novel", "paper", "study", "analysis", "investigation"
        ]
        return title
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 && !stop.contains($0.lowercased()) }
    }

    private static func lastName(from author: String) -> String {
        // "Bardeen, J.M." → "Bardeen"
        // "J.M. Bardeen" → "Bardeen"
        // "Bardeen" → "Bardeen"
        let trimmed = author.trimmingCharacters(in: .whitespaces)
        if let comma = trimmed.firstIndex(of: ",") {
            return String(trimmed[..<comma]).trimmingCharacters(in: .whitespaces)
        }
        let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        return parts.last ?? trimmed
    }

    /// Dedup search results by DOI/arXiv/bibcode identity. Keeps the first
    /// occurrence (preserves source ordering).
    /// Fetch metadata for a known identifier without writing to the library.
    /// Used by Smart Search's preview path so the user can confirm the match
    /// via "Add Selected" instead of being shown a paper that's already been
    /// imported. Reuses `fetchFromExternal`'s source-fallback ladder.
    private func previewByIdentifier(_ id: PaperIdentifier) async throws -> RankedCandidate {
        let result = try await fetchFromExternal(identifier: id)
        let ext = Self.toExternalSearchResult(result)
        Logger.sources.infoCapture(
            "resolveStructured: identifier preview \(id.typeName)=\(id.value) → \(result.sourceID): \(result.title)",
            category: "citations"
        )
        return RankedCandidate(result: ext, confidence: 1.0)
    }

    private static func dedupByIdentifier(_ results: [SearchResult]) -> [SearchResult] {
        var seen = Set<String>()
        var out: [SearchResult] = []
        for r in results {
            let key = [r.doi, r.arxivID, r.bibcode]
                .compactMap { $0 }
                .first { !$0.isEmpty } ?? "\(r.sourceID):\(r.title)"
            if seen.insert(key.lowercased()).inserted {
                out.append(r)
            }
        }
        return out
    }

    private static func toExternalSearchResult(_ r: SearchResult) -> ExternalSearchResult {
        ExternalSearchResult(
            title: r.title,
            authors: r.authors,
            year: r.year,
            venue: r.venue ?? "",
            abstract: r.abstract ?? "",
            sourceID: r.sourceID,
            doi: r.doi,
            arxivID: r.arxivID,
            bibcode: r.bibcode
        )
    }

    private static func bestIdentifier(from result: ExternalSearchResult) -> PaperIdentifier? {
        if let doi = result.doi, !doi.isEmpty { return .doi(doi) }
        if let arxiv = result.arxivID, !arxiv.isEmpty { return .arxiv(arxiv) }
        if let bib = result.bibcode, !bib.isEmpty { return .bibcode(bib) }
        return nil
    }

    private static func freeTextFallback(authors: [String], year: Int?, title: String?) -> String {
        var parts: [String] = []
        if let first = authors.first {
            parts.append(Self.lastName(from: first))
        }
        if let y = year { parts.append(String(y)) }
        if let t = title, !t.isEmpty {
            parts.append(String(t.prefix(80)))
        }
        return parts.joined(separator: " ")
    }

    /// Build the best all-sources free-text query we can. Order of preference:
    /// 1. Caller-provided `freeText` if non-empty (imprint already packs
    ///    the bibitem reference line here).
    /// 2. Synthesize "LastName Year Journal Volume Title..." from the fields.
    /// 3. Fall back to `freeTextFallback` (author+year+title).
    ///
    /// The rich synthesis matters because openalex / crossref / arxiv
    /// relevance scoring rewards longer, more specific queries — a short
    /// "Bardeen 1986" matches almost anything. Adding "ApJ 304 15 Gaussian"
    /// narrows the top-10 to the real paper.
    private static func richFallbackQuery(
        authors: [String],
        year: Int?,
        title: String?,
        journal: String?,
        providedFreeText: String?
    ) -> String {
        if let t = providedFreeText, !t.isEmpty {
            return String(t.prefix(220))
        }
        var parts: [String] = []
        if let first = authors.first {
            parts.append(Self.lastName(from: first))
        }
        if let y = year { parts.append(String(y)) }
        if let j = journal, !j.isEmpty { parts.append(j) }
        if let t = title, !t.isEmpty { parts.append(String(t.prefix(120))) }
        let joined = parts.joined(separator: " ")
        if joined.isEmpty {
            return Self.freeTextFallback(authors: authors, year: year, title: title)
        }
        return joined
    }

    /// Identifier extraction from a LaTeX-decoded BibTeX fragment. Mirrors
    /// the router's private helper so the cascade can be driven from here
    /// without a string round-trip.
    private static func extractIdentifierFromBibTeX(_ bibtex: String) -> PaperIdentifier? {
        guard !bibtex.isEmpty else { return nil }
        func match(_ pattern: String) -> String? {
            guard let rx = try? NSRegularExpression(pattern: pattern) else { return nil }
            let r = NSRange(bibtex.startIndex..., in: bibtex)
            guard let m = rx.firstMatch(in: bibtex, range: r),
                  m.numberOfRanges > 1,
                  let g = Range(m.range(at: 1), in: bibtex) else {
                return nil
            }
            return String(bibtex[g])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "{}\""))
        }
        if let doi = match(#"(?i)\bdoi\s*=\s*[{"]?\s*(?:https?://(?:dx\.)?doi\.org/)?(10\.[^\s",}]+)"#) {
            return .doi(doi)
        }
        if let doi = match(#"(?i)https?://(?:dx\.)?doi\.org/(10\.[^\s",}]+)"#) {
            return .doi(doi)
        }
        let archiveIsArxiv = bibtex.range(of: #"(?i)archivePrefix\s*=\s*[{"]?\s*arxiv"#, options: .regularExpression) != nil
        if let eprint = match(#"(?i)\beprint\s*=\s*[{"]?\s*([^\s",}]+)"#) {
            let looksLikeArxiv = eprint.range(of: #"^(\d{4}\.\d{4,5}|[a-z\-]+/\d{7})$"#, options: .regularExpression) != nil
            if archiveIsArxiv || looksLikeArxiv {
                return .arxiv(eprint)
            }
        }
        if let arxiv = match(#"(?i)https?://arxiv\.org/abs/([^\s",}]+)"#) {
            return .arxiv(arxiv)
        }
        if let bibcode = match(#"(?i)\bbibcode\s*=\s*[{"]?\s*([0-9]{4}[A-Za-z0-9.&]{14,19})"#) {
            return .bibcode(bibcode)
        }
        if let pmid = match(#"(?i)\bpmid\s*=\s*[{"]?\s*(\d+)"#) {
            return .pmid(pmid)
        }
        return nil
    }
}

// MARK: - Notification Names

public extension Notification.Name {
    static let downloadPDF = Notification.Name("com.imbib.downloadPDF")
}
