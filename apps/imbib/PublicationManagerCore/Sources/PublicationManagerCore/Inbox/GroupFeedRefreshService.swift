//
//  GroupFeedRefreshService.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-15.
//

import Foundation
import CoreData
import OSLog

// MARK: - Group Feed Refresh Service

/// Service for refreshing group feeds with staggered per-author searches.
///
/// Group feeds monitor multiple authors within selected arXiv categories.
/// To avoid rate limiting, searches for each author are staggered with a
/// configurable delay (default: 20 seconds).
///
/// ## Usage
/// ```swift
/// let count = try await GroupFeedRefreshService.shared.refreshGroupFeed(smartSearch)
/// ```
public actor GroupFeedRefreshService {

    // MARK: - Singleton

    public static let shared = GroupFeedRefreshService()

    // MARK: - Configuration

    /// Delay between author searches (in seconds)
    private let staggerDelaySeconds: TimeInterval = 2

    /// Maximum results per author search
    private let maxResultsPerAuthor: Int = 100

    // MARK: - Dependencies

    private let arxivSource: ArXivSource
    private let persistenceController: PersistenceController

    // MARK: - State

    private var _isRefreshing = false
    private var currentProgress: GroupFeedProgress?

    // MARK: - Initialization

    public init(
        arxivSource: ArXivSource = ArXivSource(),
        persistenceController: PersistenceController = .shared
    ) {
        self.arxivSource = arxivSource
        self.persistenceController = persistenceController
    }

    // MARK: - State Access

    public var isRefreshing: Bool { _isRefreshing }

    public var progress: GroupFeedProgress? { currentProgress }

    // MARK: - Internal Types

    /// Sendable data extracted from a group feed smart search.
    private struct GroupFeedData: Sendable {
        let id: UUID
        let name: String
        let authors: [String]
        let categories: Set<String>
        let includeCrossListed: Bool
    }

    // MARK: - Refresh Group Feed

    /// Refresh a group feed by ID, fetching the smart search internally.
    ///
    /// This variant is safe to call from non-main-actor contexts as it fetches the
    /// CDSmartSearch internally on the main actor.
    ///
    /// - Parameter smartSearchID: UUID of the group feed smart search
    /// - Returns: Number of new papers added to Inbox
    /// - Throws: `GroupFeedError` if the smart search is not found or not a group feed
    @discardableResult
    public func refreshGroupFeedByID(_ smartSearchID: UUID) async throws -> Int {
        // Extract all needed data on main actor
        let feedData: GroupFeedData? = await MainActor.run { () -> GroupFeedData? in
            let request = NSFetchRequest<CDSmartSearch>(entityName: "SmartSearch")
            request.predicate = NSPredicate(format: "id == %@", smartSearchID as CVarArg)
            request.fetchLimit = 1
            guard let smartSearch = try? persistenceController.viewContext.fetch(request).first,
                  smartSearch.isGroupFeed else {
                return nil
            }
            return GroupFeedData(
                id: smartSearch.id,
                name: smartSearch.name ?? "Group Feed",
                authors: smartSearch.groupFeedAuthors(),
                categories: smartSearch.groupFeedCategories(),
                includeCrossListed: smartSearch.groupFeedIncludesCrossListed()
            )
        }

        guard let feedData else {
            throw GroupFeedError.notGroupFeed
        }

        return try await refreshGroupFeedInternal(feedData, smartSearchID: smartSearchID)
    }

    /// Refresh a group feed by searching for each author with staggered timing.
    ///
    /// - Parameter smartSearch: The group feed smart search to refresh
    /// - Returns: Number of new papers added to Inbox
    /// - Throws: `GroupFeedError` if the smart search is not a group feed
    @discardableResult
    public func refreshGroupFeed(_ smartSearch: CDSmartSearch) async throws -> Int {
        guard smartSearch.isGroupFeed else {
            throw GroupFeedError.notGroupFeed
        }

        let authors = smartSearch.groupFeedAuthors()
        let categories = smartSearch.groupFeedCategories()
        let includeCrossListed = smartSearch.groupFeedIncludesCrossListed()

        guard !authors.isEmpty else {
            throw GroupFeedError.noAuthors
        }

        guard !categories.isEmpty else {
            throw GroupFeedError.noCategories
        }

        Logger.inbox.infoCapture(
            "Starting group feed refresh: '\(smartSearch.name)' with \(authors.count) authors and \(categories.count) categories",
            category: "group-feed"
        )

        _isRefreshing = true
        currentProgress = GroupFeedProgress(
            totalAuthors: authors.count,
            completedAuthors: 0,
            currentAuthor: nil,
            totalPapers: 0
        )

        defer {
            _isRefreshing = false
            currentProgress = nil
        }

        var allResults: [SearchResult] = []
        var seenIDs: Set<String> = []

        for (index, author) in authors.enumerated() {
            // Update progress
            currentProgress = GroupFeedProgress(
                totalAuthors: authors.count,
                completedAuthors: index,
                currentAuthor: author,
                totalPapers: allResults.count
            )

            // Stagger requests (skip delay for first author)
            if index > 0 {
                Logger.inbox.debugCapture(
                    "Waiting \(Int(staggerDelaySeconds))s before searching for '\(author)'",
                    category: "group-feed"
                )
                try await Task.sleep(for: .seconds(staggerDelaySeconds))
            }

            // Build query for this author
            let query = SearchFormQueryBuilder.buildArXivAuthorCategoryQuery(
                author: author,
                categories: categories,
                includeCrossListed: includeCrossListed
            )

            Logger.inbox.debugCapture(
                "Searching for author '\(author)' with query: \(query)",
                category: "group-feed"
            )

            do {
                // Use 90-day window for author searches (authors don't publish frequently)
                let results = try await arxivSource.search(query: query, maxResults: maxResultsPerAuthor, daysBack: 90)

                // Filter to exact author matches only (arXiv does fuzzy matching by default)
                let exactMatches = results.filter { result in
                    authorMatchesExactly(author, in: result.authors)
                }

                Logger.inbox.debugCapture(
                    "Found \(results.count) papers for '\(author)', \(exactMatches.count) with exact author match",
                    category: "group-feed"
                )

                // Deduplicate within this batch (by arXiv ID or DOI)
                for result in exactMatches {
                    let resultID = result.doi ?? result.arxivID ?? result.id
                    if !seenIDs.contains(resultID) {
                        seenIDs.insert(resultID)
                        allResults.append(result)
                    }
                }
            } catch {
                Logger.inbox.errorCapture(
                    "Failed to search for author '\(author)': \(error.localizedDescription)",
                    category: "group-feed"
                )
                // Continue with other authors
            }
        }

        // Final progress update
        currentProgress = GroupFeedProgress(
            totalAuthors: authors.count,
            completedAuthors: authors.count,
            currentAuthor: nil,
            totalPapers: allResults.count
        )

        Logger.inbox.infoCapture(
            "Group feed search complete: \(allResults.count) unique papers from \(authors.count) authors",
            category: "group-feed"
        )

        // Process results through Inbox pipeline
        let newCount = await processResultsForInbox(allResults, smartSearch: smartSearch)

        // Update smart search metadata
        await MainActor.run {
            smartSearch.dateLastExecuted = Date()
            smartSearch.lastFetchCount = Int16(newCount)
            persistenceController.save()
        }

        Logger.inbox.infoCapture(
            "Group feed refresh complete: \(newCount) new papers added to Inbox",
            category: "group-feed"
        )

        return newCount
    }

    /// Internal refresh implementation using Sendable data.
    private func refreshGroupFeedInternal(_ feedData: GroupFeedData, smartSearchID: UUID) async throws -> Int {
        let authors = feedData.authors
        let categories = feedData.categories
        let includeCrossListed = feedData.includeCrossListed

        guard !authors.isEmpty else {
            throw GroupFeedError.noAuthors
        }

        guard !categories.isEmpty else {
            throw GroupFeedError.noCategories
        }

        Logger.inbox.infoCapture(
            "Starting group feed refresh: '\(feedData.name)' with \(authors.count) authors and \(categories.count) categories",
            category: "group-feed"
        )

        _isRefreshing = true
        currentProgress = GroupFeedProgress(
            totalAuthors: authors.count,
            completedAuthors: 0,
            currentAuthor: nil,
            totalPapers: 0
        )

        defer {
            _isRefreshing = false
            currentProgress = nil
        }

        var allResults: [SearchResult] = []
        var seenIDs: Set<String> = []

        for (index, author) in authors.enumerated() {
            // Update progress
            currentProgress = GroupFeedProgress(
                totalAuthors: authors.count,
                completedAuthors: index,
                currentAuthor: author,
                totalPapers: allResults.count
            )

            // Stagger requests (skip delay for first author)
            if index > 0 {
                Logger.inbox.debugCapture(
                    "Waiting \(Int(staggerDelaySeconds))s before searching for '\(author)'",
                    category: "group-feed"
                )
                try await Task.sleep(for: .seconds(staggerDelaySeconds))
            }

            // Build query for this author
            let query = SearchFormQueryBuilder.buildArXivAuthorCategoryQuery(
                author: author,
                categories: categories,
                includeCrossListed: includeCrossListed
            )

            Logger.inbox.debugCapture(
                "Searching for author '\(author)' with query: \(query)",
                category: "group-feed"
            )

            do {
                // Use 90-day window for author searches (authors don't publish frequently)
                let results = try await arxivSource.search(query: query, maxResults: maxResultsPerAuthor, daysBack: 90)

                // Filter to exact author matches only (arXiv does fuzzy matching by default)
                let exactMatches = results.filter { result in
                    authorMatchesExactly(author, in: result.authors)
                }

                Logger.inbox.debugCapture(
                    "Found \(results.count) papers for '\(author)', \(exactMatches.count) with exact author match",
                    category: "group-feed"
                )

                // Deduplicate within this batch (by arXiv ID or DOI)
                for result in exactMatches {
                    let resultID = result.doi ?? result.arxivID ?? result.id
                    if !seenIDs.contains(resultID) {
                        seenIDs.insert(resultID)
                        allResults.append(result)
                    }
                }
            } catch {
                Logger.inbox.errorCapture(
                    "Failed to search for author '\(author)': \(error.localizedDescription)",
                    category: "group-feed"
                )
                // Continue with other authors
            }
        }

        // Final progress update
        currentProgress = GroupFeedProgress(
            totalAuthors: authors.count,
            completedAuthors: authors.count,
            currentAuthor: nil,
            totalPapers: allResults.count
        )

        Logger.inbox.infoCapture(
            "Group feed search complete: \(allResults.count) unique papers from \(authors.count) authors",
            category: "group-feed"
        )

        // Process results through Inbox pipeline
        let newCount = await processResultsForInboxByID(allResults, smartSearchID: smartSearchID)

        // Update smart search metadata on main actor
        await MainActor.run {
            let request = NSFetchRequest<CDSmartSearch>(entityName: "SmartSearch")
            request.predicate = NSPredicate(format: "id == %@", smartSearchID as CVarArg)
            request.fetchLimit = 1
            if let smartSearch = try? persistenceController.viewContext.fetch(request).first {
                smartSearch.dateLastExecuted = Date()
                smartSearch.lastFetchCount = Int16(newCount)
                persistenceController.save()
            }
        }

        Logger.inbox.infoCapture(
            "Group feed refresh complete: \(newCount) new papers added to Inbox",
            category: "group-feed"
        )

        return newCount
    }

    // MARK: - Pipeline

    /// Process search results through the Inbox pipeline using smart search ID.
    private func processResultsForInboxByID(_ results: [SearchResult], smartSearchID: UUID) async -> Int {
        guard !results.isEmpty else { return 0 }

        // Get InboxManager on main actor and create repository
        let inboxManager = await MainActor.run { InboxManager.shared }
        let repository = PublicationRepository()

        // Get the result collection for this smart search
        let resultCollection: CDCollection? = await MainActor.run {
            let request = NSFetchRequest<CDSmartSearch>(entityName: "SmartSearch")
            request.predicate = NSPredicate(format: "id == %@", smartSearchID as CVarArg)
            request.fetchLimit = 1
            return try? persistenceController.viewContext.fetch(request).first?.resultCollection
        }

        // Filter results
        var filteredResults: [SearchResult] = []

        for result in results {
            // Check mute filter
            let shouldFilter = await MainActor.run {
                inboxManager.shouldFilter(result: result)
            }

            if shouldFilter {
                Logger.inbox.debugCapture("Filtered out muted paper: \(result.title)", category: "group-feed")
                continue
            }

            // Check if previously dismissed
            let wasDismissed = await MainActor.run {
                inboxManager.wasDismissed(result: result)
            }

            if wasDismissed {
                Logger.inbox.debugCapture("Skipping previously dismissed paper: \(result.title)", category: "group-feed")
                continue
            }

            filteredResults.append(result)
        }

        Logger.inbox.debugCapture(
            "After filters: \(filteredResults.count) of \(results.count) papers remain",
            category: "group-feed"
        )

        // Find existing publications that match these results
        let existingMap = await repository.findExistingByIdentifiers(filteredResults)
        let existingPubs = filteredResults.compactMap { existingMap[$0.id] }
        let newResults = filteredResults.filter { existingMap[$0.id] == nil }

        Logger.inbox.debugCapture(
            "Found \(existingPubs.count) existing papers, \(newResults.count) new papers",
            category: "group-feed"
        )

        // Filter existing papers to only those still in inbox
        // This prevents dismissed papers from reappearing when the feed refreshes
        let inboxLibrary = await MainActor.run { InboxManager.shared.inboxLibrary }
        let existingPubsStillInInbox = existingPubs.filter { pub in
            guard let inboxLib = inboxLibrary else { return false }
            return pub.libraries?.contains(inboxLib) ?? false
        }

        if existingPubs.count != existingPubsStillInInbox.count {
            Logger.inbox.debugCapture(
                "Filtered \(existingPubs.count - existingPubsStillInInbox.count) dismissed papers from group feed refresh",
                category: "group-feed"
            )
        }

        // Add filtered existing publications to the result collection (so they show in the feed view)
        if !existingPubsStillInInbox.isEmpty, let collection = resultCollection {
            await repository.addToCollection(existingPubsStillInInbox, collection: collection)
        }

        // Create new publications and add to both Inbox and result collection
        var newPaperIDs: [UUID] = []
        if !newResults.isEmpty {
            // Create publications and add to result collection
            if let collection = resultCollection {
                let newPapers = await repository.createFromSearchResults(newResults, collection: collection)
                newPaperIDs = newPapers.map { $0.id }

                // Add to Inbox on main actor
                await MainActor.run {
                    for paper in newPapers {
                        inboxManager.addToInbox(paper)
                    }
                }
            } else {
                // No result collection - just create publications
                for result in newResults {
                    let pub = await repository.createFromSearchResult(result)
                    newPaperIDs.append(pub.id)

                    await MainActor.run {
                        inboxManager.addToInbox(pub)
                    }
                }
            }
        }

        Logger.inbox.debugCapture("Created \(newPaperIDs.count) new papers", category: "group-feed")

        // Immediate ADS enrichment to resolve bibcodes for Similar/Co-read features
        // Use the ID-based method for thread safety
        if !newPaperIDs.isEmpty {
            let enrichedCount = await EnrichmentCoordinator.shared.enrichBatchByIDs(newPaperIDs)
            Logger.inbox.infoCapture(
                "ADS enrichment: \(enrichedCount)/\(newPaperIDs.count) papers resolved with bibcodes",
                category: "group-feed"
            )
        }

        // Return total papers in the feed (filtered existing + new)
        return existingPubsStillInInbox.count + newPaperIDs.count
    }

    /// Process search results through the Inbox pipeline.
    private func processResultsForInbox(_ results: [SearchResult], smartSearch: CDSmartSearch) async -> Int {
        guard !results.isEmpty else { return 0 }

        // Get InboxManager on main actor and create repository
        let inboxManager = await MainActor.run { InboxManager.shared }
        let repository = PublicationRepository()

        // Get the result collection for this smart search
        let resultCollection = await MainActor.run { smartSearch.resultCollection }

        // Filter results
        var filteredResults: [SearchResult] = []

        for result in results {
            // Check mute filter
            let shouldFilter = await MainActor.run {
                inboxManager.shouldFilter(result: result)
            }

            if shouldFilter {
                Logger.inbox.debugCapture("Filtered out muted paper: \(result.title)", category: "group-feed")
                continue
            }

            // Check if previously dismissed
            let wasDismissed = await MainActor.run {
                inboxManager.wasDismissed(result: result)
            }

            if wasDismissed {
                Logger.inbox.debugCapture("Skipping previously dismissed paper: \(result.title)", category: "group-feed")
                continue
            }

            filteredResults.append(result)
        }

        Logger.inbox.debugCapture(
            "After filters: \(filteredResults.count) of \(results.count) papers remain",
            category: "group-feed"
        )

        // Find existing publications that match these results
        let existingMap = await repository.findExistingByIdentifiers(filteredResults)
        let existingPubs = filteredResults.compactMap { existingMap[$0.id] }
        let newResults = filteredResults.filter { existingMap[$0.id] == nil }

        Logger.inbox.debugCapture(
            "Found \(existingPubs.count) existing papers, \(newResults.count) new papers",
            category: "group-feed"
        )

        // Filter existing papers to only those still in inbox
        // This prevents dismissed papers from reappearing when the feed refreshes
        let inboxLibrary = await MainActor.run { InboxManager.shared.inboxLibrary }
        let existingPubsStillInInbox = existingPubs.filter { pub in
            guard let inboxLib = inboxLibrary else { return false }
            return pub.libraries?.contains(inboxLib) ?? false
        }

        if existingPubs.count != existingPubsStillInInbox.count {
            Logger.inbox.debugCapture(
                "Filtered \(existingPubs.count - existingPubsStillInInbox.count) dismissed papers from group feed refresh",
                category: "group-feed"
            )
        }

        // Add filtered existing publications to the result collection (so they show in the feed view)
        if !existingPubsStillInInbox.isEmpty, let collection = resultCollection {
            await repository.addToCollection(existingPubsStillInInbox, collection: collection)
        }

        // Create new publications and add to both Inbox and result collection
        var newPapers: [CDPublication] = []
        if !newResults.isEmpty {
            // Create publications and add to result collection
            if let collection = resultCollection {
                newPapers = await repository.createFromSearchResults(newResults, collection: collection)
            } else {
                // No result collection - just create publications
                for result in newResults {
                    let pub = await repository.createFromSearchResult(result)
                    newPapers.append(pub)
                }
            }
        }

        Logger.inbox.debugCapture("Created \(newPapers.count) new papers", category: "group-feed")

        // Add new papers to Inbox
        if !newPapers.isEmpty {
            await MainActor.run {
                for paper in newPapers {
                    inboxManager.addToInbox(paper)
                }
            }

            // Immediate ADS enrichment to resolve bibcodes for Similar/Co-read features
            // Extract IDs on main actor for thread safety, then use ID-based API
            let newPaperIDs = await MainActor.run { newPapers.map { $0.id } }
            let enrichedCount = await EnrichmentCoordinator.shared.enrichBatchByIDs(newPaperIDs)
            Logger.inbox.infoCapture(
                "ADS enrichment: \(enrichedCount)/\(newPapers.count) papers resolved with bibcodes",
                category: "group-feed"
            )
        }

        // Return total papers in the feed (filtered existing + new)
        return existingPubsStillInInbox.count + newPapers.count
    }

    // MARK: - Author Matching

    /// Check if a target author name matches any author in the paper's author list.
    ///
    /// This performs exact matching to filter out false positives from arXiv's fuzzy search.
    /// For example, searching for "Devon Powell" should not match "Samuel Powell".
    ///
    /// The matching handles:
    /// - Case-insensitive comparison
    /// - Middle initials (e.g., "John H. Wise" matches "John Wise" or "J. H. Wise")
    /// - Name order variations (e.g., "Powell, Devon" matches "Devon Powell")
    private func authorMatchesExactly(_ targetAuthor: String, in paperAuthors: [String]) -> Bool {
        let targetNormalized = normalizeAuthorName(targetAuthor)

        for paperAuthor in paperAuthors {
            let paperNormalized = normalizeAuthorName(paperAuthor)

            // Check for exact match after normalization
            if targetNormalized == paperNormalized {
                return true
            }

            // Check if all parts of target name appear in paper author
            // This handles cases like "John Wise" matching "John H. Wise"
            let targetParts = targetNormalized.split(separator: " ").map(String.init)
            let paperParts = paperNormalized.split(separator: " ").map(String.init)

            // All significant parts of target must appear in paper author
            let significantTargetParts = targetParts.filter { $0.count > 1 }  // Ignore single initials
            let allPartsMatch = significantTargetParts.allSatisfy { targetPart in
                paperParts.contains { paperPart in
                    paperPart == targetPart || paperPart.hasPrefix(targetPart) || targetPart.hasPrefix(paperPart)
                }
            }

            if allPartsMatch && !significantTargetParts.isEmpty {
                // Also verify last names match exactly
                if let targetLast = significantTargetParts.last,
                   let paperLast = paperParts.filter({ $0.count > 1 }).last,
                   targetLast.lowercased() == paperLast.lowercased() {
                    return true
                }
            }
        }

        return false
    }

    /// Normalize an author name for comparison.
    ///
    /// - Converts to lowercase
    /// - Removes punctuation (periods, commas)
    /// - Handles "Last, First" format by converting to "First Last"
    /// - Trims whitespace
    private func normalizeAuthorName(_ name: String) -> String {
        var normalized = name.lowercased()

        // Remove periods and extra whitespace
        normalized = normalized.replacingOccurrences(of: ".", with: "")
        normalized = normalized.replacingOccurrences(of: ",", with: " ")

        // Collapse multiple spaces
        while normalized.contains("  ") {
            normalized = normalized.replacingOccurrences(of: "  ", with: " ")
        }

        normalized = normalized.trimmingCharacters(in: .whitespaces)

        // If it looks like "Last First" format (single word, space, rest), leave it
        // The matching logic handles both orders

        return normalized
    }
}

// MARK: - Group Feed Progress

/// Progress information for a group feed refresh operation.
public struct GroupFeedProgress: Sendable {
    public let totalAuthors: Int
    public let completedAuthors: Int
    public let currentAuthor: String?
    public let totalPapers: Int

    public var percentComplete: Double {
        guard totalAuthors > 0 else { return 0 }
        return Double(completedAuthors) / Double(totalAuthors) * 100
    }

    public var statusMessage: String {
        if let author = currentAuthor {
            return "Searching for '\(author)' (\(completedAuthors + 1)/\(totalAuthors))"
        } else if completedAuthors == totalAuthors {
            return "Processing \(totalPapers) papers"
        } else {
            return "Starting search..."
        }
    }
}

// MARK: - Group Feed Error

/// Errors that can occur during group feed refresh.
public enum GroupFeedError: LocalizedError {
    case notGroupFeed
    case noAuthors
    case noCategories

    public var errorDescription: String? {
        switch self {
        case .notGroupFeed:
            return "The smart search is not a group feed."
        case .noAuthors:
            return "No authors specified in the group feed."
        case .noCategories:
            return "No categories specified in the group feed."
        }
    }
}
