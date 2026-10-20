//
//  AutomationService.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-16.
//
//  Actor implementing AutomationOperations protocol (ADR-018).
//  Calls RustStoreAdapter and the SourceClient (the Rust source verbs) directly for rich data returns.
//

import Foundation
import ImbibRustCore
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

    private var sourceClient: SourceClient
    private let settingsStore: AutomationSettingsStore

    // MARK: - Initialization

    public init(
        sourceClient: SourceClient = SourceClient(),
        settingsStore: AutomationSettingsStore = .shared
    ) {
        self.sourceClient = sourceClient
        self.settingsStore = settingsStore
    }

    /// Configure with the app's shared SourceClient.
    public func configure(sourceClient: SourceClient) {
        self.sourceClient = sourceClient
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
            results = try await sourceClient.search(query: query, sourceID: sourceID, maxResults: maxResults)
        } else {
            // Search all available sources in parallel
            let options = SearchOptions(maxResults: maxResults)
            results = try await sourceClient.search(query: query, options: options)
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
            // An explicit container filter selects that container. Without
            // one, preserve the existing empty-query default-library scope.
            publications = await withStore { store in
                if let libraryID = filters?.libraries?.first {
                    return store.queryPublications(
                        parentId: libraryID,
                        sort: "created",
                        ascending: false,
                        limit: nil,
                        offset: nil
                    )
                }
                if let collectionID = filters?.collections?.first {
                    return store.listCollectionMembers(
                        collectionId: collectionID,
                        sort: "created",
                        ascending: false,
                        limit: nil,
                        offset: nil
                    )
                }
                if let lib = store.getDefaultLibrary() {
                    return store.queryPublications(
                        parentId: lib.id,
                        sort: "created",
                        ascending: false,
                        limit: nil,
                        offset: nil
                    )
                }
                return []
            }
        } else {
            publications = await withStore { store in
                store.searchPublications(query: query, parentId: filters?.libraries?.first)
            }
        }

        // Apply filters
        var filtered = publications
        if let filters = filters {
            filtered = applyFilters(to: filtered, filters: filters)
        }

        // Library scope is pushed into the store query above because detail
        // rows expose only the home library, not secondary Contains members.
        // Collection identity is absent from row data, so resolve it from
        // exact detail membership before pagination.
        let needsMembershipFilter = !(filters?.collections?.isEmpty ?? true)
        var membershipDetails: [UUID: PublicationModel] = [:]
        if let filters, needsMembershipFilter {
            let membershipCandidates = filtered
            let resolved = await withStore { store in
                membershipCandidates.compactMap { publication -> (PublicationRowData, PublicationModel)? in
                    guard let detail = store.getPublicationDetail(id: publication.id) else { return nil }
                    if let collections = filters.collections, !collections.isEmpty,
                       !collections.contains(where: detail.collectionIDs.contains) {
                        return nil
                    }
                    return (publication, detail)
                }
            }
            filtered = resolved.map(\.0)
            membershipDetails = Dictionary(uniqueKeysWithValues: resolved.map { ($0.0.id, $0.1) })
        }

        // Apply limit/offset
        if let offset = filters?.offset, offset > 0 {
            filtered = Array(filtered.dropFirst(offset))
        }
        if let limit = filters?.limit {
            filtered = Array(filtered.prefix(limit))
        }

        return await paperResults(for: filtered, detailOverrides: membershipDetails)
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
        // Library scope is applied in the query; collection membership is
        // resolved from detail rows before pagination in searchLibrary.
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

        let results = try await sourceClient.search(query: query, options: options)

        // Get actual source IDs used
        let actualSources: [String]
        if let sources = sources {
            actualSources = sources
        } else {
            actualSources = await sourceClient.availableSources.map { $0.id }
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
        return await paperResults(for: [publication]).first
    }

    public func getPapers(identifiers: [PaperIdentifier]) async throws -> [PaperResult] {
        try await checkAuthorization()

        var publications: [PublicationRowData] = []
        for id in identifiers {
            if let pub = await findPublication(by: id) {
                publications.append(pub)
            }
        }
        return await paperResults(for: publications)
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

                // File the record with its provenance (S-D5) through
                // `imbib-library-service_import-work`: the source's own
                // BibTeX as `raw_bibtex`, `source_id`, `ids_json`.
                let outcome = try await sourceClient.importWork(
                    searchResult,
                    library: targetLibraryID,
                    collection: collection,
                    fetchBibTeX: true
                )
                if let existing = outcome.existingID {
                    duplicates.append(identifier.value)
                    existingToAssignIDs.append(existing)
                    logger.debug("Duplicate found by the store for: \(identifier.value)")
                    continue
                }
                if outcome.dismissed {
                    failed[identifier.value] = "dismissed earlier; not re-imported"
                    continue
                }
                let importedIDs = outcome.importedID.map { [$0] } ?? []

                // Download PDFs if requested — in the background, so the
                // add returns as soon as the papers exist. (This used to post
                // a `.downloadPDF` notification nothing observed.)
                if downloadPDFs && !searchResult.pdfLinks.isEmpty {
                    for pubID in importedIDs {
                        Task.detached(priority: .utility) {
                            _ = try? await PDFAcquisitionService.shared.acquire(publicationID: pubID, policy: .background)
                        }
                    }
                }

                // Convert imported publications to PaperResult
                var importedRows: [PublicationRowData] = []
                for pubID in importedIDs {
                    if let pub = await withStore({ $0.getPublication(id: pubID) }) {
                        importedRows.append(pub)
                    }
                }
                added.append(contentsOf: await paperResults(for: importedRows))

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

        // Recent activity: adding papers here is always user- or agent-directed
        // (smart-search "Add Selected", the automation/MCP add endpoint, App
        // Intents). Automated ingest does NOT come through this path — feeds go
        // via batchImportSearchResults — so recording here is safe.
        let addedIDs = added.map { $0.id }
        if !addedIDs.isEmpty {
            await MainActor.run {
                RustStoreAdapter.shared.recordRecentAdd(ids: addedIDs)
            }
        }

        return AddPapersResult(
            added: added,
            duplicates: duplicates,
            duplicateIDs: existingToAssignIDs,
            failed: failed
        )
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
        try await requireCollection(collectionID)
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
                let results = try await sourceClient.search(
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

    // MARK: - reMarkable USB mirror (ADR-025)

    /// Mark or unmark papers for the tablet. Resolves identifiers first so
    /// the store call is one batch and the outcome names every row.
    public func setEInkMirrored(identifiers: [PaperIdentifier], mirrored: Bool) async throws -> EInkMirrorUpdateResult {
        try await checkAuthorization()

        var ids: [UUID] = []
        var notFound: [String] = []
        for identifier in identifiers {
            if let pub = await findPublication(by: identifier) {
                ids.append(pub.id)
            } else {
                notFound.append(identifier.value)
            }
        }

        guard !ids.isEmpty else {
            return EInkMirrorUpdateResult(deviceId: nil, changed: [], unchanged: [], awaitingSource: [], notFound: notFound)
        }

        let outcome = await withStore { store in
            mirrored ? store.einkMark(ids: ids) : store.einkUnmark(ids: ids)
        }
        guard let outcome else {
            throw AutomationOperationError.operationFailed(
                "The e-ink mirror could not \(mirrored ? "mark" : "unmark") the papers — is a reMarkable configured?")
        }
        logger.info("eink \(mirrored ? "mark" : "unmark") via automation: changed=\(outcome.changed.count) unchanged=\(outcome.unchanged.count) awaitingSource=\(outcome.awaitingSource.count) notFound=\(notFound.count)")
        return EInkMirrorUpdateResult(
            deviceId: outcome.deviceId,
            changed: outcome.changed,
            unchanged: outcome.unchanged,
            awaitingSource: outcome.awaitingSource,
            notFound: notFound)
    }

    /// The mirror subsystem's status (`GET /api/eink/status`).
    public func eInkStatus() async throws -> EInkStatusSnapshot? {
        try await checkAuthorization()
        return await RustStoreAdapter.shared.einkStatusBackground()
    }

    /// The mirror row for one paper, if any (`GET /api/papers/{citeKey}` → `eink`).
    public func eInkMirror(for identifier: PaperIdentifier) async throws -> EInkMirrorRecord? {
        try await checkAuthorization()
        guard let pub = await findPublication(by: identifier) else { return nil }
        return await withStore { store in store.einkMirrorRecord(publicationId: pub.id) }
    }

    /// Run one sync pass against the tablet now (`POST /api/eink/sync`).
    /// Goes through `EInkSyncCoordinator` so an agent's run is serialised
    /// with the app's own (falls back to the adapter when the services were
    /// never started). Blocking network work runs off the main thread.
    public func eInkSync(importAnnotations: Bool) async throws -> EInkSyncReport {
        try await checkAuthorization()
        return try await runEInk(reason: .manual, importOverride: importAnnotations)
    }

    /// Import what came back from the tablet now (`POST /api/eink/import`):
    /// a coordinator run under `.importOnly`, which forces the import half on.
    public func eInkImport() async throws -> EInkSyncReport {
        try await checkAuthorization()
        return try await runEInk(reason: .importOnly, importOverride: true)
    }

    /// The folders the tablet lacks, parents first (`POST /api/eink/folders/check`).
    public func eInkFolderChecklist(deviceId: String? = nil) async throws -> (deviceId: String?, folders: [EInkFolderNeed]) {
        try await checkAuthorization()
        return await withStore { store in
            let resolved = deviceId ?? store.einkStatus()?.defaultDeviceId
            return (resolved, store.einkFolderChecklist(deviceId: deviceId))
        }
    }

    private func runEInk(reason: EInkSyncReason, importOverride: Bool?) async throws -> EInkSyncReport {
        if let coordinator = await MainActor.run(body: { EInkServices.shared.coordinator }) {
            let reports = try await coordinator.runNow(reason: reason, importOverride: importOverride)
            guard let report = reports.first else {
                throw AutomationOperationError.operationFailed("No enabled reMarkable is configured")
            }
            return report
        }
        return try await RustStoreAdapter.shared.einkSync(import: importOverride ?? true)
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

        guard await MainActor.run(body: { RustStoreAdapter.shared.getLibrary(id: id) != nil }) else {
            throw AutomationOperationError.operationFailed("Library \(id.uuidString) was not found")
        }

        if deleteFiles {
            try await removeLibraryFileContainers(ids: [id])
        }

        let removed = await withStore { store in
            store.deleteLibrary(id: id)
            return store.getLibrary(id: id) == nil
        }
        guard removed else {
            throw AutomationOperationError.operationFailed(
                "Library deletion failed; requested file cleanup may already have completed")
        }
        return true
    }

    /// Delete multiple libraries in one consolidated batch. Wraps the per-id
    /// deletes in `beginBatchMutation` / `endBatchMutation` so observers fire
    /// once. Matches the on-device `LibraryManager.deleteLibraries(ids:)` semantics.
    public func deleteLibraries(ids: [UUID], deleteFiles: Bool = false) async throws -> Int {
        try await checkAuthorization()
        var seen = Set<UUID>()
        let ids = ids.filter { seen.insert($0).inserted }
        guard !ids.isEmpty else { return 0 }

        // Validate every row before touching any file container or library.
        let missingID = await MainActor.run {
            ids.first { RustStoreAdapter.shared.getLibrary(id: $0) == nil }
        }
        if let missingID {
            throw AutomationOperationError.operationFailed(
                "Library \(missingID.uuidString) was not found; batch was not changed"
            )
        }

        if deleteFiles {
            try await removeLibraryFileContainers(ids: ids)
        }

        let removed = await withStore { store in
            store.beginBatchMutation()
            defer { store.endBatchMutation() }
            var removed = 0
            for id in ids {
                store.deleteLibrary(id: id)
                guard store.getLibrary(id: id) == nil else { break }
                removed += 1
            }
            return removed
        }
        guard removed == ids.count else {
            throw AutomationOperationError.operationFailed(
                "Deleted \(removed) libraries before a store failure; requested file cleanup may already have completed")
        }
        return removed
    }

    private func removeLibraryFileContainers(ids: [UUID]) async throws {
        let urls = await MainActor.run { ids.flatMap(LibraryManager.allContainerURLs(for:)) }
        var removedAny = false
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
                removedAny = true
            } catch {
                let partial = removedAny
                    ? " Some earlier library containers were already removed."
                    : ""
                throw AutomationOperationError.operationFailed(
                    "Could not remove a library file container; no library rows were deleted.\(partial)"
                )
            }
        }
    }

    public func addToCollection(papers: [PaperIdentifier], collectionID: UUID) async throws -> Int {
        try await checkAuthorization()
        try await requireCollection(collectionID)

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
        try await requireCollection(collectionID)

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

    /// Validate a collection before any membership changes. The retained HTTP
    /// routes previously let the store adapter log a missing target and still
    /// returned success; checking the same local collection inventory here
    /// makes those routes report their declared `collectionNotFound` error.
    private func requireCollection(_ collectionID: UUID) async throws {
        let libraries = await withStore { $0.listLibraries() }
        for library in libraries {
            if await withStore({ store in
                store.listCollections(libraryId: library.id).contains { $0.id == collectionID }
            }) {
                return
            }
        }
        throw AutomationOperationError.collectionNotFound(collectionID)
    }

    // MARK: - Library Operations

    public func createLibrary(name: String) async throws -> LibraryResult {
        try await checkAuthorization()
        logger.info("Creating library: \(name)")

        guard let library = await withStore({ $0.createLibrary(name: name) }) else {
            throw AutomationOperationError.operationFailed("Failed to create library")
        }

        logger.info("Created library '\(name)' with ID: \(library.id)")
        return await toLibraryResult(library)
    }

    public func listLibraries() async throws -> [LibraryResult] {
        try await checkAuthorization()

        let libraries = await withStore { store in
            store.listLibraries().map { library in
                (library, store.listCollections(libraryId: library.id).count)
            }
        }
        return libraries.map { toLibraryResult($0.0, collectionCount: $0.1) }
    }

    public func getDefaultLibrary() async throws -> LibraryResult? {
        try await checkAuthorization()

        guard let library = await withStore({ $0.getDefaultLibrary() }) else {
            return nil
        }
        return await toLibraryResult(library)
    }

    public func getInboxLibrary() async throws -> LibraryResult? {
        try await checkAuthorization()

        guard let library = await withStore({ $0.getInboxLibrary() }) else {
            return nil
        }
        return await toLibraryResult(library)
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

        if let identifiers {
            var ids: [UUID] = []
            for identifier in identifiers {
                if let publication = await findPublication(by: identifier) {
                    ids.append(publication.id)
                }
            }
            let bibtex = await withStore { $0.exportBibTeX(ids: ids) }
            return ExportResult(format: "ris", content: formatRIS(bibtex), paperCount: ids.count)
        }

        guard let defaultLibrary = await withStore({ $0.getDefaultLibrary() }) else {
            return ExportResult(format: "ris", content: "", paperCount: 0)
        }
        let bibtex = await withStore { $0.exportAllBibTeX(libraryId: defaultLibrary.id) }
        return ExportResult(
            format: "ris",
            content: formatRIS(bibtex),
            paperCount: defaultLibrary.publicationCount
        )
    }

    /// Keep the legacy HTTP path on the same parser, converter and formatter
    /// used by the in-app RIS export action while the generated Rust verb is
    /// introduced alongside it.
    private func formatRIS(_ bibtex: String) -> String {
        let parser = BibTeXParserFactory.createParser()
        let items = (try? parser.parse(bibtex)) ?? []
        let entries = items.compactMap { item -> BibTeXEntry? in
            if case .entry(let entry) = item { return entry }
            return nil
        }
        return RISExporter().export(RISBibTeXConverter.toRIS(entries))
    }

    // MARK: - PDF Operations

    /// Download PDFs for papers — awaited, through `PDFAcquisitionService`
    /// (policy `.background`: no browser, deduped against the PDF tab). Used
    /// to post a `.downloadPDF` notification nothing observed and report
    /// every paper as "downloaded". Up to three papers fetch at once.
    public func downloadPDFs(identifiers: [PaperIdentifier]) async throws -> DownloadResult {
        try await checkAuthorization()
        logger.info("Downloading PDFs for \(identifiers.count) papers")

        var alreadyHad: [String] = []
        var failed: [String: String] = [:]
        var targets: [(id: UUID, citeKey: String)] = []

        for identifier in identifiers {
            guard let publication = await findPublication(by: identifier) else {
                failed[identifier.value] = "Paper not found"
                continue
            }
            if publication.hasDownloadedPDF {
                alreadyHad.append(publication.citeKey)
                continue
            }
            targets.append((publication.id, publication.citeKey))
        }

        enum Outcome: Sendable { case downloaded, noSource, failed(String) }
        var outcomes: [String: Outcome] = [:]
        await withTaskGroup(of: (String, Outcome).self) { group in
            var iterator = targets.makeIterator()
            var running = 0
            func launch(_ target: (id: UUID, citeKey: String)) {
                group.addTask {
                    do {
                        let url = try await PDFAcquisitionService.shared.acquire(publicationID: target.id, policy: .background)
                        return (target.citeKey, url == nil ? .noSource : .downloaded)
                    } catch {
                        return (target.citeKey, .failed(error.localizedDescription))
                    }
                }
            }
            while running < 3, let target = iterator.next() {
                launch(target)
                running += 1
            }
            for await (citeKey, outcome) in group {
                outcomes[citeKey] = outcome
                if let next = iterator.next() { launch(next) }
            }
        }

        var downloaded: [String] = []
        for target in targets {
            switch outcomes[target.citeKey] {
            case .downloaded?:
                downloaded.append(target.citeKey)
            case .noSource?:
                failed[target.citeKey] = "No PDF source available"
            case .failed(let message)?:
                failed[target.citeKey] = message
            case nil:
                failed[target.citeKey] = "Not attempted"
            }
        }
        logger.info("PDF download via automation: downloaded=\(downloaded.count) alreadyHad=\(alreadyHad.count) failed=\(failed.count)")

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

        let sources = await sourceClient.availableSources
        var results: [(id: String, name: String, hasCredentials: Bool)] = []

        for source in sources {
            let hasCredentials = await sourceClient.hasValidCredentials(for: source.id)
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
        let papers = await paperResults(for: paginated)

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

        // Rust refuses anything that is not a comment, and an id that names
        // nothing (#62: this used to be the store's generic delete, which
        // removed any record kind and answered `deleted: true` for a missing
        // id too).
        let outcome: CommentDeletion = await withStore { store in
            do {
                try store.deleteComment(commentID)
                return .deleted
            } catch StoreApiError.NotFound {
                return .notFound
            } catch StoreApiError.InvalidInput(let why) {
                return .notAComment(why)
            } catch {
                return .failed(String(describing: error))
            }
        }
        switch outcome {
        case .deleted:
            logger.info("Deleted comment \(commentID)")
        case .notFound:
            logger.warning("Delete comment \(commentID): not found")
            throw AutomationOperationError.commentNotFound(commentID)
        case .notAComment(let why):
            logger.warning("Delete comment \(commentID) refused: \(why)")
            throw AutomationOperationError.notAComment(commentID, why)
        case .failed(let why):
            throw AutomationOperationError.operationFailed(why)
        }
    }

    private enum CommentDeletion: Sendable {
        case deleted, notFound, notAComment(String), failed(String)
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
        color: String?,
        authorName: String? = nil
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
                selectedText: selectedText,
                authorName: authorName
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

    /// Every `PaperResult` for a library paper is built here. The list row
    /// carries no membership — which is why `libraryIDs` and `collectionIDs`
    /// came back `[]` for every paper — so each row is paired with its detail,
    /// the read that knows the paper's store parent (its library) and the
    /// collections that contain it. One main-actor hop for the whole page.
    private func paperResults(
        for rows: [PublicationRowData],
        detailOverrides: [UUID: PublicationModel] = [:]
    ) async -> [PaperResult] {
        guard !rows.isEmpty else { return [] }
        let ids = rows.map(\.id)
        let missingIDs = ids.filter { detailOverrides[$0] == nil }
        let fetchedDetails = await withStore { store in
            Dictionary(uniqueKeysWithValues: missingIDs.compactMap { id in
                store.getPublicationDetail(id: id).map { (id, $0) }
            })
        }
        return rows.map { row in
            Self.toPaperResult(row, detail: detailOverrides[row.id] ?? fetchedDetails[row.id])
        }
    }

    /// `detail` is `nil` only when the paper vanished between the two reads;
    /// the result then reports no membership rather than guessing one.
    static func toPaperResult(_ pub: PublicationRowData, detail: PublicationModel?) -> PaperResult {
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
            // Rust's parse of the paper's authors (`authors_json`, else
            // `author_text`), one "Family, Given" per author.
            authors: detail?.authors.map(\.displayName) ?? authorNames(fromAuthorText: pub.authorString),
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
            collectionIDs: detail?.collectionIDs ?? [],
            libraryIDs: detail?.libraryIDs ?? [],
            notes: pub.note,
            annotationCount: 0  // Not available in PublicationRowData
        )
    }

    /// One name per author from the store's `author_text`, which imbib-core
    /// writes as "Family, Given; Family, Given" (`format_author_text`). The
    /// boundary is the semicolon; the comma is inside each name. This used to
    /// split on the comma, so four authors came back as five fragments
    /// ("Amin", "Mustafa A.; Jain", …).
    static func authorNames(fromAuthorText text: String) -> [String] {
        text.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
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

    private func toLibraryResult(_ library: LibraryModel) async -> LibraryResult {
        let collectionCount = await withStore { $0.listCollections(libraryId: library.id).count }
        return toLibraryResult(library, collectionCount: collectionCount)
    }

    private func toLibraryResult(_ library: LibraryModel, collectionCount: Int) -> LibraryResult {
        LibraryResult(
            id: library.id,
            name: library.name,
            paperCount: library.publicationCount,
            collectionCount: collectionCount,
            isDefault: library.isDefault,
            isInbox: library.isInbox,
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
            id: tag.path,
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

    // Structured citation resolution and its scorer moved to Rust (koine
    // `koine-sources::{score, cascade}` behind `imbib-app-service_resolve-
    // citation`, source convention S6). The Swift goldens recorded from the
    // scorer (S2a) are now `crates/imbib-service/tests/citation_scorer_goldens.rs`.
}

// MARK: - reMarkable mirror result (ADR-025)

/// What `AutomationOperations.setEInkMirrored` did, per paper.
public struct EInkMirrorUpdateResult: Sendable, Equatable {
    /// The device the marks were written for; nil when nothing resolved.
    public let deviceId: String?
    /// Papers whose mirror row changed.
    public let changed: [UUID]
    /// Papers already in the requested state.
    public let unchanged: [UUID]
    /// Marked papers with no local PDF/ePUB yet (`awaiting_source`).
    public let awaitingSource: [UUID]
    /// Identifiers that matched no paper.
    public let notFound: [String]

    public init(deviceId: String?, changed: [UUID], unchanged: [UUID], awaitingSource: [UUID], notFound: [String]) {
        self.deviceId = deviceId
        self.changed = changed
        self.unchanged = unchanged
        self.awaitingSource = awaitingSource
        self.notFound = notFound
    }

    public var updated: Int { changed.count }
}
