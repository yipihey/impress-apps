//
//  SmartSearchProvider.swift
//  PublicationManagerCore
//
//  A paper provider backed by a saved search query.
//

import Foundation
import OSLog

// MARK: - Smart Search Provider

/// A paper provider backed by a saved search query.
///
/// Smart searches execute on demand and auto-import results to their associated
/// collection. Papers are immediately persisted via RustStoreAdapter.
public actor SmartSearchProvider {

    // MARK: - Properties

    public nonisolated let id: UUID
    public nonisolated let name: String

    private let query: String
    private let sourceIDs: [String]
    private let maxResults: Int
    private let sourceManager: SourceManager
    private let feedsToInbox: Bool

    private var lastFetched: Date?
    private var _isLoading = false
    private let refreshIntervalSeconds: Int

    // MARK: - Store Access

    private func withStore<T: Sendable>(_ operation: @MainActor @Sendable (RustStoreAdapter) -> T) async -> T {
        await MainActor.run { operation(RustStoreAdapter.shared) }
    }

    // MARK: - Initialization

    public init(
        id: UUID,
        name: String,
        query: String,
        sourceIDs: [String],
        maxResults: Int = 50,
        sourceManager: SourceManager,
        feedsToInbox: Bool = false,
        refreshIntervalSeconds: Int = 86400,
        lastExecuted: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.query = query
        self.sourceIDs = sourceIDs
        self.maxResults = maxResults
        self.sourceManager = sourceManager
        self.feedsToInbox = feedsToInbox
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.lastFetched = lastExecuted
    }

    /// Create from a SmartSearch domain model
    public init(from model: SmartSearch, sourceManager: SourceManager) {
        self.id = model.id
        self.name = model.name
        self.query = model.query
        self.sourceIDs = model.sourceIDs
        self.maxResults = model.maxResults
        self.sourceManager = sourceManager
        self.feedsToInbox = model.feedsToInbox
        self.refreshIntervalSeconds = model.refreshIntervalSeconds
        self.lastFetched = model.lastExecuted
    }

    // MARK: - State

    public var isLoading: Bool {
        _isLoading
    }

    /// Get the result collection's publications count
    public var count: Int {
        get async {
            // Smart search publications are in its result collection
            // We'd need to query the store for this
            0
        }
    }

    // MARK: - Refresh (Auto-Import)

    /// Execute the search and auto-import results.
    public func refresh() async throws {
        if query.hasPrefix("GROUP_FEED|") {
            Logger.smartSearch.errorCapture(
                "Group feed '\(name)' incorrectly routed to SmartSearchProvider. " +
                "This should use GroupFeedRefreshService instead.",
                category: "smartsearch"
            )
            throw SmartSearchError.groupFeedMisrouted(name: name)
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        Logger.smartSearch.infoCapture("Executing smart search '\(name)': \(query)", category: "smartsearch")
        _isLoading = true
        defer { _isLoading = false }

        let options = SearchOptions(
            maxResults: maxResults,
            sourceIDs: sourceIDs.isEmpty ? nil : sourceIDs
        )

        let sourcesInfo = sourceIDs.isEmpty ? "all sources" : sourceIDs.joined(separator: ", ")
        Logger.smartSearch.debugCapture("Smart search using: \(sourcesInfo)", category: "smartsearch")

        do {
            let searchStart = CFAbsoluteTimeGetCurrent()
            let results = try await sourceManager.search(
                query: query,
                options: options
            )
            let searchTime = (CFAbsoluteTimeGetCurrent() - searchStart) * 1000

            let limitedResults = Array(results.prefix(maxResults))

            let arxivIDs = results.compactMap { $0.arxivID }.sorted()
            let firstID = arxivIDs.first ?? "none"
            let lastID = arxivIDs.last ?? "none"
            Logger.smartSearch.infoCapture(
                "Smart search '\(name)' returned \(results.count) results in \(String(format: "%.0f", searchTime))ms " +
                "(arXiv range: \(firstID) to \(lastID))",
                category: "smartsearch"
            )

            // Find existing publications via RustStoreAdapter
            let findStart = CFAbsoluteTimeGetCurrent()
            let existingMap: [String: PublicationRowData] = await MainActor.run {
                let store = RustStoreAdapter.shared
                var map: [String: PublicationRowData] = [:]
                for result in limitedResults {
                    let matches = store.findByIdentifiers(
                        doi: result.doi,
                        arxivId: result.arxivID,
                        bibcode: result.bibcode
                    )
                    if let first = matches.first {
                        map[result.id] = first
                    }
                }
                return map
            }
            let findTime = (CFAbsoluteTimeGetCurrent() - findStart) * 1000

            let existingPubs = limitedResults.compactMap { existingMap[$0.id] }
            let newResults = limitedResults.filter { existingMap[$0.id] == nil }

            // Create new publications via BibTeX import
            let createStart = CFAbsoluteTimeGetCurrent()
            var newPublicationIDs: [UUID] = []
            var importTargetIsInbox = false
            if !newResults.isEmpty {
                newPublicationIDs = await MainActor.run {
                    let store = RustStoreAdapter.shared
                    guard let smartSearch = store.getSmartSearch(id: id) else { return [UUID]() }

                    // Resolve library ID — fall back to inbox for feeds-to-inbox searches
                    // whose parent was orphaned (parent set to NULL by cascade delete).
                    let libraryID: UUID
                    if let ssLibID = smartSearch.libraryID {
                        libraryID = ssLibID
                    } else if feedsToInbox, let inbox = store.getInboxLibrary() {
                        libraryID = inbox.id
                        // Re-parent the orphaned smart search to current inbox
                        store.reparentItem(id: id, newParentId: inbox.id)
                        Logger.smartSearch.infoCapture(
                            "Re-parented orphaned smart search '\(name)' to inbox library",
                            category: "smartsearch"
                        )
                    } else {
                        Logger.smartSearch.errorCapture(
                            "Smart search '\(name)' has no library ID and no inbox available",
                            category: "smartsearch"
                        )
                        return [UUID]()
                    }

                    // Track if we're importing directly into inbox
                    if let inbox = store.getInboxLibrary(), libraryID == inbox.id {
                        importTargetIsInbox = true
                    }

                    var createdIDs: [UUID] = []
                    for result in newResults {
                        let bibtex = result.toBibTeX()
                        if !bibtex.isEmpty {
                            let ids = store.importBibTeX(bibtex, libraryId: libraryID)
                            createdIDs.append(contentsOf: ids)
                        }
                    }
                    return createdIDs
                }
            }
            let createTime = (CFAbsoluteTimeGetCurrent() - createStart) * 1000

            // Link all found publications (new + existing) to this smart search via Contains references.
            // This allows the feed view to query "papers from this feed" via ReferencedBy.
            let allFoundIDs = newPublicationIDs + existingPubs.map(\.id)
            if !allFoundIDs.isEmpty {
                await MainActor.run {
                    RustStoreAdapter.shared.addToCollection(publicationIds: allFoundIDs, collectionId: id)
                }
            }

            // If this feed goes to inbox, add publications to the inbox library
            if feedsToInbox {
                let inboxStart = CFAbsoluteTimeGetCurrent()

                // Filter existing pubs: exclude dismissed and already in inbox
                let existingPubIDsForInbox: [UUID] = await MainActor.run {
                    let store = RustStoreAdapter.shared
                    return existingPubs.compactMap { pub -> UUID? in
                        let pubID = pub.id
                        // Check if dismissed
                        if store.isPaperDismissed(doi: pub.doi, arxivId: pub.arxivID, bibcode: pub.bibcode) {
                            return nil
                        }
                        // Check if already in inbox
                        if let inboxLib = store.getInboxLibrary() {
                            let inboxPubs = store.queryPublications(parentId: inboxLib.id)
                            if inboxPubs.contains(where: { $0.id == pubID }) {
                                return nil
                            }
                        }
                        return pubID
                    }
                }

                // When papers were imported directly into inbox (because the smart search
                // is parented to inbox), they're already there — only add existing pubs
                // that aren't yet in inbox. Count newly-imported papers as "added" too.
                let pubIDsToAdd: [UUID]
                if importTargetIsInbox {
                    pubIDsToAdd = existingPubIDsForInbox  // new ones already in inbox
                } else {
                    pubIDsToAdd = existingPubIDsForInbox + newPublicationIDs
                }

                let addedFromBatch = await MainActor.run {
                    InboxManager.shared.addToInboxBatch(pubIDsToAdd)
                }

                // Total added = batch additions + newly-imported papers (if they went to inbox directly)
                let totalAdded = importTargetIsInbox ? (addedFromBatch + newPublicationIDs.count) : addedFromBatch

                let inboxTime = (CFAbsoluteTimeGetCurrent() - inboxStart) * 1000
                Logger.smartSearch.infoCapture(
                    "Added \(totalAdded) papers to inbox library in \(String(format: "%.0f", inboxTime))ms" +
                    " (\(newPublicationIDs.count) new, \(addedFromBatch) existing moved)",
                    category: "smartsearch"
                )
            }

            lastFetched = Date()
            let totalTime = (CFAbsoluteTimeGetCurrent() - startTime) * 1000

            Logger.smartSearch.infoCapture(
                "Smart search '\(name)' complete: \(newResults.count) new, \(existingPubs.count) existing " +
                "in \(String(format: "%.0f", totalTime))ms " +
                "(search=\(String(format: "%.0f", searchTime))ms, find=\(String(format: "%.0f", findTime))ms, " +
                "create=\(String(format: "%.0f", createTime))ms)",
                category: "performance"
            )

        } catch {
            Logger.smartSearch.errorCapture("Smart search '\(name)' failed: \(error.localizedDescription)", category: "smartsearch")
            throw error
        }
    }

    // MARK: - Cache State

    public var timeSinceLastFetch: TimeInterval? {
        guard let lastFetched else { return nil }
        return Date().timeIntervalSince(lastFetched)
    }

    private static let defaultRefreshInterval: TimeInterval = 86400
    private static let minimumRefreshInterval: TimeInterval = 900

    public var isStale: Bool {
        guard let elapsed = timeSinceLastFetch else { return true }
        var intervalSeconds = TimeInterval(refreshIntervalSeconds)
        if intervalSeconds <= 0 {
            intervalSeconds = Self.defaultRefreshInterval
        }
        intervalSeconds = max(intervalSeconds, Self.minimumRefreshInterval)
        return elapsed > intervalSeconds
    }
}

// MARK: - Smart Search Repository

/// Repository for managing smart search definitions.
@MainActor
@Observable
public final class SmartSearchRepository {

    // MARK: - Properties

    public private(set) var smartSearches: [SmartSearch] = []
    public private(set) var currentLibraryID: UUID?

    private var store: RustStoreAdapter { RustStoreAdapter.shared }

    // MARK: - Shared Instance

    public static let shared = SmartSearchRepository()

    // MARK: - Initialization

    public init() {}

    // MARK: - Load

    public func loadSmartSearches() {
        loadSmartSearches(for: currentLibraryID)
    }

    public func loadSmartSearches(for libraryID: UUID?) {
        currentLibraryID = libraryID

        let libraryName = libraryID.flatMap { store.getLibrary(id: $0)?.name } ?? "all libraries"
        Logger.smartSearch.debugCapture("Loading smart searches for: \(libraryName)", category: "smartsearch")

        smartSearches = store.listSmartSearches(libraryId: libraryID)
            .sorted { $0.sortOrder < $1.sortOrder }

        Logger.smartSearch.infoCapture("Loaded \(smartSearches.count) smart searches for \(libraryName)", category: "smartsearch")
    }

    // MARK: - CRUD

    /// Create a new smart search for the specified library
    @discardableResult
    public func create(
        name: String,
        query: String,
        sourceIDs: [String] = [],
        libraryID: UUID? = nil,
        maxResults: Int? = nil
    ) -> SmartSearch? {
        let targetLibraryID = libraryID ?? currentLibraryID
        let libraryName = targetLibraryID.flatMap { store.getLibrary(id: $0)?.name } ?? "no library"
        let effectiveMaxResults = maxResults ?? loadDefaultMaxResults()

        Logger.smartSearch.infoCapture("Creating smart search '\(name)' in \(libraryName) with maxResults=\(effectiveMaxResults)", category: "smartsearch")

        guard let targetID = targetLibraryID else {
            Logger.smartSearch.errorCapture("No library ID for smart search creation", category: "smartsearch")
            return nil
        }

        let sourceIdsJson = "[" + sourceIDs.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        let smartSearch = store.createSmartSearch(
            name: name,
            query: query,
            libraryId: targetID,
            sourceIdsJson: sourceIdsJson,
            maxResults: Int64(effectiveMaxResults),
            autoRefreshEnabled: false,
            refreshIntervalSeconds: 86400
        )

        loadSmartSearches(for: currentLibraryID)

        if let ss = smartSearch {
            Logger.smartSearch.infoCapture("Created smart search '\(name)' with ID: \(ss.id)", category: "smartsearch")
        }

        return smartSearch
    }

    /// Delete a smart search.
    public func delete(_ smartSearchID: UUID) {
        Logger.smartSearch.infoCapture("Deleting smart search: \(smartSearchID)", category: "smartsearch")
        store.deleteItem(id: smartSearchID)
        loadSmartSearches(for: currentLibraryID)
    }

    /// Mark a smart search as recently executed
    public func markExecuted(_ smartSearchID: UUID) {
        Logger.smartSearch.debugCapture("Marking smart search executed: \(smartSearchID)", category: "smartsearch")
        // The Rust store updates lastExecuted internally when needed
    }

    // MARK: - Specialized Factory Methods

    /// Create an inbox feed
    @discardableResult
    public func createInboxFeed(
        name: String,
        query: String,
        sourceIDs: [String],
        maxResults: Int? = nil,
        refreshIntervalSeconds: Int = 3600,
        isGroupFeed: Bool = false
    ) -> SmartSearch? {
        let inboxLibraryID = InboxManager.shared.getOrCreateInbox()
        let effectiveMaxResults = maxResults ?? 500

        Logger.smartSearch.infoCapture(
            "Creating inbox feed '\(name)' with maxResults=\(effectiveMaxResults), refresh=\(refreshIntervalSeconds)s",
            category: "smartsearch"
        )

        let sourceIdsJson = "[" + sourceIDs.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        let smartSearch = store.createSmartSearch(
            name: name,
            query: query,
            libraryId: inboxLibraryID.id,
            sourceIdsJson: sourceIdsJson,
            maxResults: Int64(effectiveMaxResults),
            feedsToInbox: true,
            autoRefreshEnabled: true,
            refreshIntervalSeconds: Int64(refreshIntervalSeconds)
        )

        loadSmartSearches(for: currentLibraryID)

        if let ss = smartSearch {
            Logger.smartSearch.infoCapture("Created inbox feed '\(name)' with ID: \(ss.id)", category: "smartsearch")
        }

        return smartSearch
    }

    /// Create an exploration search
    @discardableResult
    public func createExplorationSearch(
        name: String,
        query: String,
        sourceIDs: [String],
        maxResults: Int? = nil
    ) -> SmartSearch? {
        let effectiveMaxResults = maxResults ?? loadDefaultMaxResults()
        let explorationLib = LibraryManager().getOrCreateExplorationLibrary()

        // Check if a search with the same query already exists
        let existingSearches = store.listSmartSearches(libraryId: explorationLib.id)
        if let existing = existingSearches.first(where: { $0.query == query }) {
            Logger.smartSearch.infoCapture(
                "Found existing exploration search with query '\(query)', returning existing",
                category: "smartsearch"
            )
            return existing
        }

        Logger.smartSearch.infoCapture(
            "Creating exploration search '\(name)' with maxResults=\(effectiveMaxResults)",
            category: "smartsearch"
        )

        let sourceIdsJson = "[" + sourceIDs.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        let smartSearch = store.createSmartSearch(
            name: name,
            query: query,
            libraryId: explorationLib.id,
            sourceIdsJson: sourceIdsJson,
            maxResults: Int64(effectiveMaxResults),
            autoRefreshEnabled: false,
            refreshIntervalSeconds: 86400
        )

        loadSmartSearches(for: currentLibraryID)

        if let ss = smartSearch {
            Logger.smartSearch.infoCapture("Created exploration search '\(name)' with ID: \(ss.id)", category: "smartsearch")
        }

        return smartSearch
    }

    // MARK: - Lookup

    public func find(id: UUID) -> SmartSearch? {
        smartSearches.first { $0.id == id }
    }

    public func createProviders(sourceManager: SourceManager) -> [SmartSearchProvider] {
        smartSearches.map { SmartSearchProvider(from: $0, sourceManager: sourceManager) }
    }

    public func smartSearches(for libraryID: UUID) -> [SmartSearch] {
        store.listSmartSearches(libraryId: libraryID).sorted { $0.sortOrder < $1.sortOrder }
    }

    // MARK: - Settings Helpers

    private func loadDefaultMaxResults() -> Int {
        let settingsKey = "smartSearchSettings"
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(SmartSearchSettings.self, from: data) else {
            return Int(SmartSearchSettings.default.defaultMaxResults)
        }
        return Int(settings.defaultMaxResults)
    }
}

// MARK: - Smart Search Definition

/// A Sendable snapshot of a smart search definition
public struct SmartSearchDefinition: Sendable, Identifiable, Codable, Hashable {
    public let id: UUID
    public let name: String
    public let query: String
    public let sourceIDs: [String]
    public let dateCreated: Date
    public let dateLastExecuted: Date?
    public let order: Int

    public init(
        id: UUID = UUID(),
        name: String,
        query: String,
        sourceIDs: [String] = [],
        dateCreated: Date = Date(),
        dateLastExecuted: Date? = nil,
        order: Int = 0
    ) {
        self.id = id
        self.name = name
        self.query = query
        self.sourceIDs = sourceIDs
        self.dateCreated = dateCreated
        self.dateLastExecuted = dateLastExecuted
        self.order = order
    }

    public init(from model: SmartSearch) {
        self.id = model.id
        self.name = model.name
        self.query = model.query
        self.sourceIDs = model.sourceIDs
        self.dateCreated = Date()  // SmartSearch domain model doesn't have dateCreated
        self.dateLastExecuted = model.lastExecuted
        self.order = model.sortOrder
    }
}

// MARK: - Smart Search Error

public enum SmartSearchError: LocalizedError {
    case groupFeedMisrouted(name: String)

    public var errorDescription: String? {
        switch self {
        case .groupFeedMisrouted(let name):
            return "Group feed '\(name)' was incorrectly routed to SmartSearchProvider. Use GroupFeedRefreshService instead."
        }
    }
}
