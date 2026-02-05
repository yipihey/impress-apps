//
//  SmartSearchProvider.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import Foundation
import CoreData
import OSLog

// MARK: - Smart Search Provider

/// A paper provider backed by a saved search query.
///
/// Smart searches execute on demand and auto-import results to their associated
/// CDCollection (ADR-016: Unified Paper Model). Papers are immediately persisted
/// as CDPublication entities with full library capabilities.
public actor SmartSearchProvider {

    // MARK: - Properties

    public nonisolated let id: UUID
    public nonisolated let name: String

    private let query: String
    private let sourceIDs: [String]
    private let maxResults: Int16
    private let sourceManager: SourceManager
    private let repository: PublicationRepository
    private weak var resultCollection: CDCollection?
    private weak var smartSearchEntity: CDSmartSearch?

    private var lastFetched: Date?
    private var _isLoading = false
    /// Refresh interval in seconds (from smart search config)
    private let refreshIntervalSeconds: Int32

    // MARK: - Initialization

    public init(
        id: UUID,
        name: String,
        query: String,
        sourceIDs: [String],
        maxResults: Int16 = 50,
        sourceManager: SourceManager,
        repository: PublicationRepository,
        resultCollection: CDCollection?,
        refreshIntervalSeconds: Int32 = 86400,  // Default: daily
        lastExecuted: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.query = query
        self.sourceIDs = sourceIDs
        self.maxResults = maxResults
        self.sourceManager = sourceManager
        self.repository = repository
        self.resultCollection = resultCollection
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.lastFetched = lastExecuted  // Initialize from persisted value
        self.smartSearchEntity = nil
    }

    /// Create from a Core Data smart search entity
    public init(from entity: CDSmartSearch, sourceManager: SourceManager, repository: PublicationRepository) {
        self.id = entity.id
        self.name = entity.name
        self.query = entity.query
        self.sourceIDs = entity.sources
        self.maxResults = entity.maxResults
        self.sourceManager = sourceManager
        self.repository = repository
        self.resultCollection = entity.resultCollection
        self.smartSearchEntity = entity
        self.refreshIntervalSeconds = entity.refreshIntervalSeconds
        // CRITICAL: Initialize lastFetched from persisted dateLastExecuted
        // This prevents unnecessary refresh on app restart
        self.lastFetched = entity.dateLastExecuted
    }

    // MARK: - Helpers

    /// Fetch the result collection, re-fetching from Core Data if the weak reference was lost.
    ///
    /// Core Data may fault out objects when views rebuild (e.g., after loadLibraries()),
    /// causing weak references to become nil. This method re-fetches from the database
    /// to ensure we always have the collection when needed.
    private func getResultCollection() async -> CDCollection? {
        // Try cached weak reference first
        if let cached = resultCollection {
            return cached
        }

        // Re-fetch from Core Data using the smart search ID
        let collection: CDCollection? = await MainActor.run {
            let request = NSFetchRequest<CDSmartSearch>(entityName: "SmartSearch")
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            request.fetchLimit = 1

            guard let smartSearch = try? PersistenceController.shared.viewContext.fetch(request).first else {
                return nil
            }
            return smartSearch.resultCollection
        }

        // Update cached reference for future calls
        if let collection {
            self.resultCollection = collection
        }

        return collection
    }

    // MARK: - State

    public var isLoading: Bool {
        _isLoading
    }

    /// Get the result collection's publications (fetched from Core Data)
    public var publications: [CDPublication] {
        guard let collection = resultCollection else { return [] }
        return Array(collection.publications ?? [])
            .sorted { ($0.dateAdded) > ($1.dateAdded) }
    }

    public var count: Int {
        resultCollection?.publications?.count ?? 0
    }

    // MARK: - Refresh (Auto-Import)

    /// Execute the search and auto-import results to the result collection.
    ///
    /// This method:
    /// 1. Executes the search query against configured sources
    /// 2. Deduplicates results against existing library publications (batch query)
    /// 3. Creates new CDPublication entities for new results (batch create)
    /// 4. Adds all results (new and existing) to the result collection (batch add)
    ///
    /// Uses batch Core Data operations for performance: 2-3 saves instead of 100+.
    public func refresh() async throws {
        // Safety check: Group feeds must be routed to GroupFeedRefreshService
        // If this query slipped through, something went wrong in the routing logic
        if query.hasPrefix("GROUP_FEED|") {
            Logger.smartSearch.errorCapture(
                "⚠️ Group feed '\(name)' incorrectly routed to SmartSearchProvider. " +
                "This should use GroupFeedRefreshService instead.",
                category: "smartsearch"
            )
            throw SmartSearchError.groupFeedMisrouted(name: name)
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        Logger.smartSearch.infoCapture("Executing smart search '\(name)': \(query)", category: "smartsearch")
        _isLoading = true
        defer { _isLoading = false }

        // Fetch result collection, re-fetching from Core Data if weak reference was lost
        guard let collection = await getResultCollection() else {
            Logger.smartSearch.errorCapture("Smart search '\(name)' has no result collection", category: "smartsearch")
            return
        }

        // Build search options using the stored maxResults for this smart search
        let options = SearchOptions(
            maxResults: Int(self.maxResults),
            sourceIDs: sourceIDs.isEmpty ? nil : sourceIDs
        )

        let sourcesInfo = sourceIDs.isEmpty ? "all sources" : sourceIDs.joined(separator: ", ")
        Logger.smartSearch.debugCapture("Smart search using: \(sourcesInfo)", category: "smartsearch")

        // Execute the search
        do {
            let searchStart = CFAbsoluteTimeGetCurrent()
            let results = try await sourceManager.search(
                query: query,
                options: options
            )
            let searchTime = (CFAbsoluteTimeGetCurrent() - searchStart) * 1000

            // Limit results (SourceManager already limits, but ensure consistency)
            let limitedResults = Array(results.prefix(Int(self.maxResults)))

            // Log arXiv ID range to verify we're getting recent papers
            let arxivIDs = results.compactMap { $0.arxivID }.sorted()
            let firstID = arxivIDs.first ?? "none"
            let lastID = arxivIDs.last ?? "none"
            Logger.smartSearch.infoCapture(
                "Smart search '\(name)' returned \(results.count) results in \(String(format: "%.0f", searchTime))ms " +
                "(arXiv range: \(firstID) to \(lastID))",
                category: "smartsearch"
            )

            // BATCH OPTIMIZATION: Find existing publications in single query
            let findStart = CFAbsoluteTimeGetCurrent()
            let existingMap = await repository.findExistingByIdentifiers(limitedResults)
            let findTime = (CFAbsoluteTimeGetCurrent() - findStart) * 1000

            // Separate new vs existing results
            let existingPubs = limitedResults.compactMap { existingMap[$0.id] }
            let newResults = limitedResults.filter { existingMap[$0.id] == nil }

            // For inbox feeds: filter out dismissed papers from collection, and papers already in inbox from re-adding
            // Papers that exist in DB but aren't in inbox might have been added via other paths (PDF import, etc.)
            // Need to run filtering on MainActor since wasDismissed is MainActor-isolated
            let existingPubsForCollection: [CDPublication]  // Papers to add to feed collection (excludes dismissed only)
            let existingPubsForInbox: [CDPublication]       // Papers to add to inbox (excludes dismissed AND already in inbox)

            if smartSearchEntity?.feedsToInbox == true {
                let (forCollection, forInbox) = await MainActor.run {
                    let inboxLibrary = InboxManager.shared.inboxLibrary
                    let inboxManager = InboxManager.shared

                    // Filter for collection: only exclude dismissed papers
                    let collectionPubs = existingPubs.filter { pub in
                        !inboxManager.wasDismissed(doi: pub.doi, arxivID: pub.arxivID, bibcode: pub.bibcode)
                    }

                    // Filter for inbox: exclude dismissed AND already in inbox
                    let inboxPubs = collectionPubs.filter { pub in
                        if let inboxLib = inboxLibrary, pub.libraries?.contains(inboxLib) == true {
                            return false  // Already in inbox, don't re-add
                        }
                        return true
                    }

                    return (collectionPubs, inboxPubs)
                }
                existingPubsForCollection = forCollection
                existingPubsForInbox = forInbox

                let dismissedCount = existingPubs.count - existingPubsForCollection.count
                let alreadyInInboxCount = existingPubsForCollection.count - existingPubsForInbox.count
                if dismissedCount > 0 || alreadyInInboxCount > 0 {
                    Logger.smartSearch.debugCapture(
                        "Filtered \(dismissedCount) dismissed papers, \(alreadyInInboxCount) already in inbox",
                        category: "smartsearch"
                    )
                }
            } else {
                existingPubsForCollection = existingPubs
                existingPubsForInbox = []  // Non-inbox feeds don't add to inbox
            }

            // BATCH: Add existing publications to collection (single save)
            // This adds ALL non-dismissed papers to the feed collection, even if already in inbox
            let addStart = CFAbsoluteTimeGetCurrent()
            if !existingPubsForCollection.isEmpty {
                await repository.addToCollection(existingPubsForCollection, collection: collection)
            }
            let addTime = (CFAbsoluteTimeGetCurrent() - addStart) * 1000

            // BATCH: Create new publications and add to collection (single save)
            let createStart = CFAbsoluteTimeGetCurrent()
            var newPublications: [CDPublication] = []
            if !newResults.isEmpty {
                newPublications = await repository.createFromSearchResults(newResults, collection: collection)
            }
            let createTime = (CFAbsoluteTimeGetCurrent() - createStart) * 1000

            // If this feed goes to inbox, also add publications to the inbox library
            if smartSearchEntity?.feedsToInbox == true {
                let inboxStart = CFAbsoluteTimeGetCurrent()

                // Add only papers not already in inbox + new publications
                // Note: existingPubsForInbox excludes dismissed papers and those already in inbox
                let allPublications = existingPubsForInbox + newPublications
                let addedCount = await MainActor.run {
                    InboxManager.shared.addToInboxBatch(allPublications)
                }

                let inboxTime = (CFAbsoluteTimeGetCurrent() - inboxStart) * 1000
                Logger.smartSearch.debugCapture(
                    "Added \(addedCount) papers to inbox library in \(String(format: "%.0f", inboxTime))ms",
                    category: "smartsearch"
                )
            }

            lastFetched = Date()
            let totalTime = (CFAbsoluteTimeGetCurrent() - startTime) * 1000

            Logger.smartSearch.infoCapture(
                "⏱ Smart search '\(name)' complete: \(newResults.count) new, \(existingPubsForCollection.count) existing " +
                "in \(String(format: "%.0f", totalTime))ms " +
                "(search=\(String(format: "%.0f", searchTime))ms, find=\(String(format: "%.0f", findTime))ms, " +
                "add=\(String(format: "%.0f", addTime))ms, create=\(String(format: "%.0f", createTime))ms)",
                category: "performance"
            )

        } catch {
            Logger.smartSearch.errorCapture("Smart search '\(name)' failed: \(error.localizedDescription)", category: "smartsearch")
            throw error
        }
    }

    // MARK: - Settings

    /// Load current max results from settings (always uses current value, not stored)
    private func loadCurrentMaxResults() async -> Int16 {
        await SmartSearchSettingsStore.shared.settings.defaultMaxResults
    }

    // MARK: - Cache State

    /// Time since last fetch, or nil if never fetched
    public var timeSinceLastFetch: TimeInterval? {
        guard let lastFetched else { return nil }
        return Date().timeIntervalSince(lastFetched)
    }

    /// Default refresh interval: 24 hours
    private static let defaultRefreshInterval: TimeInterval = 86400

    /// Minimum refresh interval: 15 minutes (to prevent excessive API calls)
    private static let minimumRefreshInterval: TimeInterval = 900

    /// Whether cached results are stale (exceeds configured refresh interval)
    public var isStale: Bool {
        guard let elapsed = timeSinceLastFetch else { return true }
        // Use configured interval, or default if 0 (unset), with minimum floor
        var intervalSeconds = TimeInterval(refreshIntervalSeconds)
        if intervalSeconds <= 0 {
            intervalSeconds = Self.defaultRefreshInterval
        }
        intervalSeconds = max(intervalSeconds, Self.minimumRefreshInterval)
        return elapsed > intervalSeconds
    }

    /// Clear the result collection (removes publications only in this collection)
    public func clearResults() async {
        Logger.smartSearch.debugCapture("Clearing results for smart search '\(name)'", category: "smartsearch")
        guard let collection = resultCollection else { return }

        // Get publications only in this collection
        let publications = collection.publications ?? []
        for pub in publications {
            // Only remove from collection, don't delete (might be in other collections)
            var collections = pub.collections ?? []
            collections.remove(collection)
            pub.collections = collections
        }

        // Clear the collection's publications
        collection.publications = []
        lastFetched = nil
    }
}

// MARK: - Smart Search Repository

/// Repository for managing smart search definitions in Core Data.
///
/// Smart searches are library-specific - each library has its own set of smart searches.
@MainActor
@Observable
public final class SmartSearchRepository {

    // MARK: - Properties

    public private(set) var smartSearches: [CDSmartSearch] = []

    /// Current library being filtered (nil = show all)
    public private(set) var currentLibrary: CDLibrary?

    private let persistenceController: PersistenceController

    // MARK: - Shared Instance

    public static let shared = SmartSearchRepository()

    // MARK: - Initialization

    public init(persistenceController: PersistenceController = .shared) {
        self.persistenceController = persistenceController
    }

    // MARK: - Load

    /// Load all smart searches (unfiltered)
    public func loadSmartSearches() {
        loadSmartSearches(for: currentLibrary)
    }

    /// Load smart searches for a specific library
    public func loadSmartSearches(for library: CDLibrary?) {
        currentLibrary = library

        let libraryName = library?.displayName ?? "all libraries"
        Logger.smartSearch.debugCapture("Loading smart searches for: \(libraryName)", category: "smartsearch")

        let request = NSFetchRequest<CDSmartSearch>(entityName: "SmartSearch")
        request.sortDescriptors = [
            NSSortDescriptor(key: "order", ascending: true),
            NSSortDescriptor(key: "name", ascending: true)
        ]

        // Filter by library if provided
        if let library {
            request.predicate = NSPredicate(format: "library == %@", library)
        }

        do {
            smartSearches = try persistenceController.viewContext.fetch(request)
            Logger.smartSearch.infoCapture("Loaded \(smartSearches.count) smart searches for \(libraryName)", category: "smartsearch")

            // Repair any smart searches missing result collections
            repairMissingResultCollections()
        } catch {
            Logger.smartSearch.errorCapture("Failed to load smart searches: \(error.localizedDescription)", category: "smartsearch")
            smartSearches = []
        }
    }

    /// Repair smart searches that are missing result collections (migration from older versions)
    private func repairMissingResultCollections() {
        let context = persistenceController.viewContext
        var repairedCount = 0

        for smartSearch in smartSearches where smartSearch.resultCollection == nil {
            Logger.smartSearch.warningCapture(
                "Smart search '\(smartSearch.name)' missing result collection, creating one",
                category: "smartsearch"
            )

            // Create the missing result collection
            let collection = CDCollection(context: context)
            collection.id = UUID()
            collection.name = smartSearch.name
            collection.isSmartSearchResults = true
            collection.isSmartCollection = false
            collection.smartSearch = smartSearch
            collection.library = smartSearch.library
            smartSearch.resultCollection = collection

            repairedCount += 1
        }

        if repairedCount > 0 {
            persistenceController.save()
            Logger.smartSearch.infoCapture(
                "Repaired \(repairedCount) smart searches with missing result collections",
                category: "smartsearch"
            )
        }
    }

    // MARK: - CRUD

    /// Create a new smart search for the specified library
    ///
    /// This also creates an associated CDCollection to hold imported results (ADR-016).
    /// If `maxResults` is nil, uses the user's configured default from settings.
    @discardableResult
    public func create(
        name: String,
        query: String,
        sourceIDs: [String] = [],
        library: CDLibrary? = nil,
        maxResults: Int16? = nil
    ) -> CDSmartSearch {
        let context = persistenceController.viewContext
        let targetLibrary = library ?? currentLibrary
        let libraryName = targetLibrary?.displayName ?? "no library"

        // Use provided maxResults or read default from settings
        let effectiveMaxResults = maxResults ?? loadDefaultMaxResults()

        Logger.smartSearch.infoCapture("Creating smart search '\(name)' in \(libraryName) with maxResults=\(effectiveMaxResults)", category: "smartsearch")

        let smartSearch = CDSmartSearch(context: context)
        smartSearch.id = UUID()
        smartSearch.name = name
        smartSearch.query = query
        smartSearch.sources = sourceIDs
        smartSearch.dateCreated = Date()
        smartSearch.dateLastExecuted = Date()  // Prevent immediate refresh on startup
        smartSearch.library = targetLibrary
        smartSearch.maxResults = effectiveMaxResults
        smartSearch.refreshIntervalSeconds = 86400  // Default: 24 hours

        // Set order based on existing searches in this library
        let existingCount = targetLibrary?.smartSearches?.count ?? smartSearches.count
        smartSearch.order = Int16(existingCount)

        // ADR-016: Create associated collection for imported results
        let collection = CDCollection(context: context)
        collection.id = UUID()
        collection.name = name  // Same name as smart search
        collection.isSmartSearchResults = true
        collection.isSmartCollection = false  // Not a predicate-based collection
        collection.smartSearch = smartSearch
        collection.library = targetLibrary  // Link to owning library for smart collection queries
        smartSearch.resultCollection = collection

        Logger.smartSearch.debugCapture("Created result collection for smart search '\(name)'", category: "smartsearch")

        persistenceController.save()
        loadSmartSearches(for: currentLibrary)

        Logger.smartSearch.infoCapture("Created smart search '\(name)' with ID: \(smartSearch.id)", category: "smartsearch")
        return smartSearch
    }

    /// Update an existing smart search.
    ///
    /// For smart searches in shared libraries, only read-write participants can update.
    public func update(
        _ smartSearch: CDSmartSearch,
        name: String? = nil,
        query: String? = nil,
        sourceIDs: [String]? = nil
    ) {
        // Permission check for shared libraries
        if let library = smartSearch.library, library.isSharedLibrary, !library.canEditLibrary {
            Logger.smartSearch.warningCapture("Cannot update smart search in shared library: read-only participant", category: "smartsearch")
            return
        }

        Logger.smartSearch.infoCapture("Updating smart search: \(smartSearch.name)", category: "smartsearch")

        if let name { smartSearch.name = name }
        if let query { smartSearch.query = query }
        if let sourceIDs { smartSearch.sources = sourceIDs }

        persistenceController.save()
        loadSmartSearches(for: currentLibrary)
    }

    /// Delete a smart search.
    ///
    /// Publications in the smart search's result collection are only deleted if they
    /// are not members of any other collection. This preserves publications that have
    /// been dragged to user-created collections.
    ///
    /// For smart searches in shared libraries, only read-write participants can delete.
    public func delete(_ smartSearch: CDSmartSearch) {
        // Permission check for shared libraries
        if let library = smartSearch.library, library.isSharedLibrary, !library.canEditLibrary {
            Logger.smartSearch.warningCapture("Cannot delete smart search in shared library: read-only participant", category: "smartsearch")
            return
        }

        Logger.smartSearch.infoCapture("Deleting smart search: \(smartSearch.name)", category: "smartsearch")

        let context = persistenceController.viewContext

        // Check if this smart search has a result collection with publications
        if let resultCollection = smartSearch.resultCollection,
           let resultPubs = resultCollection.publications as? Set<CDPublication>, !resultPubs.isEmpty {

            var deletedCount = 0
            var preservedCount = 0

            for pub in resultPubs {
                // Check if this publication is in ANY other collection (excluding result collection)
                let otherCollections = (pub.collections ?? []).filter { $0.id != resultCollection.id }

                if otherCollections.isEmpty {
                    // Publication is ONLY in this smart search's result collection - safe to delete
                    context.delete(pub)
                    deletedCount += 1
                } else {
                    // Publication is in other collections - preserve it, just remove from result collection
                    var updatedCollections = pub.collections ?? []
                    updatedCollections.remove(resultCollection)
                    pub.collections = updatedCollections
                    preservedCount += 1
                }
            }

            Logger.smartSearch.infoCapture(
                "Smart search cleanup: deleted \(deletedCount) publications, preserved \(preservedCount) in other collections",
                category: "smartsearch"
            )

            // Delete the result collection
            context.delete(resultCollection)
        }

        // Delete the smart search itself
        context.delete(smartSearch)
        persistenceController.save()
        loadSmartSearches(for: currentLibrary)
    }

    /// Reorder smart searches.
    ///
    /// For shared libraries, only read-write participants can reorder.
    public func reorder(_ searches: [CDSmartSearch]) {
        // Permission check: if any search is in a shared library, check permissions
        if let library = searches.first?.library, library.isSharedLibrary, !library.canEditLibrary {
            Logger.smartSearch.warningCapture("Cannot reorder smart searches in shared library: read-only participant", category: "smartsearch")
            return
        }

        Logger.smartSearch.debugCapture("Reordering \(searches.count) smart searches", category: "smartsearch")

        for (index, search) in searches.enumerated() {
            search.order = Int16(index)
        }
        persistenceController.save()
        loadSmartSearches(for: currentLibrary)
    }

    /// Mark a smart search as recently executed
    public func markExecuted(_ smartSearch: CDSmartSearch) {
        Logger.smartSearch.debugCapture("Marking smart search executed: \(smartSearch.name)", category: "smartsearch")
        smartSearch.dateLastExecuted = Date()
        persistenceController.save()
    }

    /// Move a smart search to a different library.
    ///
    /// Requires write permission on both source and destination libraries.
    public func move(_ smartSearch: CDSmartSearch, to library: CDLibrary) {
        // Permission check on source library
        if let sourceLibrary = smartSearch.library, sourceLibrary.isSharedLibrary, !sourceLibrary.canEditLibrary {
            Logger.smartSearch.warningCapture("Cannot move smart search from shared library: read-only participant", category: "smartsearch")
            return
        }
        // Permission check on destination library
        if library.isSharedLibrary, !library.canEditLibrary {
            Logger.smartSearch.warningCapture("Cannot move smart search to shared library: read-only participant", category: "smartsearch")
            return
        }

        Logger.smartSearch.infoCapture("Moving smart search '\(smartSearch.name)' to library '\(library.displayName)'", category: "smartsearch")

        smartSearch.library = library
        persistenceController.save()
        loadSmartSearches(for: currentLibrary)
    }

    // MARK: - Specialized Factory Methods

    /// Create a library smart search (from + button in library).
    ///
    /// Library smart searches:
    /// - Stored in the specified library
    /// - Do NOT feed to inbox
    /// - Do NOT auto-refresh (manual execution only)
    ///
    /// For shared libraries, only read-write participants can create smart searches.
    /// Returns nil if the current user lacks permission.
    @discardableResult
    public func createLibrarySmartSearch(
        name: String,
        query: String,
        sourceIDs: [String],
        library: CDLibrary,
        maxResults: Int16? = nil
    ) -> CDSmartSearch? {
        // Permission check for shared libraries
        if library.isSharedLibrary, !library.canEditLibrary {
            Logger.smartSearch.warningCapture("Cannot create smart search in shared library: read-only participant", category: "smartsearch")
            return nil
        }

        let context = persistenceController.viewContext
        let effectiveMaxResults = maxResults ?? loadDefaultMaxResults()

        Logger.smartSearch.infoCapture(
            "Creating library smart search '\(name)' in '\(library.displayName)' with maxResults=\(effectiveMaxResults)",
            category: "smartsearch"
        )

        let smartSearch = CDSmartSearch(context: context)
        smartSearch.id = UUID()
        smartSearch.name = name
        smartSearch.query = query
        smartSearch.sources = sourceIDs
        smartSearch.dateCreated = Date()
        smartSearch.dateLastExecuted = Date()
        smartSearch.library = library
        smartSearch.maxResults = effectiveMaxResults
        smartSearch.refreshIntervalSeconds = 86400
        // Library smart searches do NOT feed to inbox or auto-refresh
        smartSearch.feedsToInbox = false
        smartSearch.autoRefreshEnabled = false

        let existingCount = library.smartSearches?.count ?? 0
        smartSearch.order = Int16(existingCount)

        // Create associated collection
        let collection = CDCollection(context: context)
        collection.id = UUID()
        collection.name = name
        collection.isSmartSearchResults = true
        collection.isSmartCollection = false
        collection.smartSearch = smartSearch
        collection.library = library
        smartSearch.resultCollection = collection

        persistenceController.save()
        loadSmartSearches(for: currentLibrary)

        Logger.smartSearch.infoCapture("Created library smart search '\(name)' with ID: \(smartSearch.id)", category: "smartsearch")
        return smartSearch
    }

    /// Create an inbox feed (from + button in Inbox section).
    ///
    /// Inbox feeds:
    /// - Stored in the Inbox library
    /// - Feed to inbox (feedsToInbox = true)
    /// - Auto-refresh on schedule (autoRefreshEnabled = true)
    @discardableResult
    public func createInboxFeed(
        name: String,
        query: String,
        sourceIDs: [String],
        maxResults: Int16? = nil,
        refreshIntervalSeconds: Int32 = 3600,
        isGroupFeed: Bool = false
    ) -> CDSmartSearch {
        let context = persistenceController.viewContext
        let effectiveMaxResults = maxResults ?? 500  // Feeds default to higher max results
        let inboxLibrary = InboxManager.shared.getOrCreateInbox()

        Logger.smartSearch.infoCapture(
            "Creating inbox feed '\(name)' with maxResults=\(effectiveMaxResults), refresh=\(refreshIntervalSeconds)s",
            category: "smartsearch"
        )

        let smartSearch = CDSmartSearch(context: context)
        smartSearch.id = UUID()
        smartSearch.name = name
        smartSearch.query = query
        smartSearch.sources = sourceIDs
        smartSearch.dateCreated = Date()
        smartSearch.dateLastExecuted = nil  // Will be set after first fetch
        smartSearch.library = inboxLibrary
        smartSearch.maxResults = effectiveMaxResults
        smartSearch.refreshIntervalSeconds = refreshIntervalSeconds
        // Inbox feeds DO feed to inbox and auto-refresh
        smartSearch.feedsToInbox = true
        smartSearch.autoRefreshEnabled = true
        smartSearch.isGroupFeed = isGroupFeed

        let existingCount = inboxLibrary.smartSearches?.count ?? 0
        smartSearch.order = Int16(existingCount)

        // Create associated collection
        let collection = CDCollection(context: context)
        collection.id = UUID()
        collection.name = name
        collection.isSmartSearchResults = true
        collection.isSmartCollection = false
        collection.smartSearch = smartSearch
        collection.library = inboxLibrary
        smartSearch.resultCollection = collection

        persistenceController.save()
        loadSmartSearches(for: currentLibrary)

        Logger.smartSearch.infoCapture("Created inbox feed '\(name)' with ID: \(smartSearch.id)", category: "smartsearch")
        return smartSearch
    }

    /// Create an exploration search (from Search section).
    ///
    /// Exploration searches:
    /// - Stored in the Exploration library
    /// - Do NOT feed to inbox
    /// - Do NOT auto-refresh (one-off searches)
    ///
    /// If a search with the same query already exists in the exploration library,
    /// that search is returned instead of creating a duplicate.
    @discardableResult
    public func createExplorationSearch(
        name: String,
        query: String,
        sourceIDs: [String],
        maxResults: Int16? = nil
    ) -> CDSmartSearch {
        let context = persistenceController.viewContext
        let effectiveMaxResults = maxResults ?? loadDefaultMaxResults()
        let explorationLibrary = LibraryManager(persistenceController: persistenceController).getOrCreateExplorationLibrary()

        // Check for existing search with same query to prevent duplicates
        if let existingSearches = explorationLibrary.smartSearches,
           let existing = existingSearches.first(where: { $0.query == query }) {
            Logger.smartSearch.infoCapture(
                "Found existing exploration search with query '\(query)', returning existing",
                category: "smartsearch"
            )
            // Update name if different (user may have renamed)
            if existing.name != name {
                existing.name = name
                persistenceController.save()
            }
            return existing
        }

        Logger.smartSearch.infoCapture(
            "Creating exploration search '\(name)' with maxResults=\(effectiveMaxResults)",
            category: "smartsearch"
        )

        let smartSearch = CDSmartSearch(context: context)
        smartSearch.id = UUID()
        smartSearch.name = name
        smartSearch.query = query
        smartSearch.sources = sourceIDs
        smartSearch.dateCreated = Date()
        smartSearch.dateLastExecuted = Date()
        smartSearch.library = explorationLibrary
        smartSearch.maxResults = effectiveMaxResults
        smartSearch.refreshIntervalSeconds = 86400
        // Exploration searches do NOT feed to inbox or auto-refresh
        smartSearch.feedsToInbox = false
        smartSearch.autoRefreshEnabled = false

        let existingCount = explorationLibrary.smartSearches?.count ?? 0
        smartSearch.order = Int16(existingCount)

        // Create associated collection
        let collection = CDCollection(context: context)
        collection.id = UUID()
        collection.name = name
        collection.isSmartSearchResults = true
        collection.isSmartCollection = false
        collection.smartSearch = smartSearch
        collection.library = explorationLibrary
        smartSearch.resultCollection = collection

        persistenceController.save()
        loadSmartSearches(for: currentLibrary)

        Logger.smartSearch.infoCapture("Created exploration search '\(name)' with ID: \(smartSearch.id)", category: "smartsearch")
        return smartSearch
    }

    // MARK: - Lookup

    /// Find a smart search by ID
    public func find(id: UUID) -> CDSmartSearch? {
        smartSearches.first { $0.id == id }
    }

    /// Create providers for all smart searches in current library
    public func createProviders(sourceManager: SourceManager, repository: PublicationRepository) -> [SmartSearchProvider] {
        smartSearches.map { SmartSearchProvider(from: $0, sourceManager: sourceManager, repository: repository) }
    }

    /// Get all smart searches for a specific library
    public func smartSearches(for library: CDLibrary) -> [CDSmartSearch] {
        Array(library.smartSearches ?? []).sorted { $0.order < $1.order }
    }

    // MARK: - Settings Helpers

    /// Load default max results from UserDefaults (synchronous read)
    ///
    /// This reads directly from UserDefaults to avoid async actor access in synchronous create().
    private func loadDefaultMaxResults() -> Int16 {
        let settingsKey = "smartSearchSettings"
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(SmartSearchSettings.self, from: data) else {
            return SmartSearchSettings.default.defaultMaxResults
        }
        return settings.defaultMaxResults
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

    public init(from entity: CDSmartSearch) {
        self.id = entity.id
        self.name = entity.name
        self.query = entity.query
        self.sourceIDs = entity.sources
        self.dateCreated = entity.dateCreated
        self.dateLastExecuted = entity.dateLastExecuted
        self.order = Int(entity.order)
    }
}

// MARK: - Smart Search Error

/// Errors that can occur during smart search operations.
public enum SmartSearchError: LocalizedError {
    case groupFeedMisrouted(name: String)

    public var errorDescription: String? {
        switch self {
        case .groupFeedMisrouted(let name):
            return "Group feed '\(name)' was incorrectly routed to SmartSearchProvider. Use GroupFeedRefreshService instead."
        }
    }
}
