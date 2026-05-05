//
//  GroupFeedRefreshService.swift
//  PublicationManagerCore
//
//  Service for refreshing group feeds with staggered per-author searches.
//

import Foundation
import ImpressStoreKit
import OSLog

// MARK: - Group Feed Refresh Service

/// Service for refreshing group feeds with staggered per-author searches.
///
/// Group feeds monitor multiple authors within selected arXiv categories.
/// To avoid rate limiting, searches for each author are staggered with a
/// configurable delay (default: 2 seconds).
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

    // MARK: - Store Access

    private func withStore<T: Sendable>(_ operation: @MainActor @Sendable (RustStoreAdapter) -> T) async -> T {
        await MainActor.run { operation(RustStoreAdapter.shared) }
    }

    // MARK: - State

    private var _isRefreshing = false
    private var currentProgress: GroupFeedProgress?

    /// Set of feed IDs currently being refreshed. Used to prevent concurrent
    /// refreshes of the same feed (which can happen when the user triggers a
    /// manual refresh while a scheduled refresh is in flight, or when the
    /// actor's isolation is released during `Task.sleep` inside the per-author
    /// stagger loop).
    private var activelyRefreshing: Set<UUID> = []

    // MARK: - Initialization

    public init(
        arxivSource: ArXivSource = ArXivSource()
    ) {
        self.arxivSource = arxivSource
    }

    // MARK: - State Access

    public var isRefreshing: Bool { _isRefreshing }

    public var progress: GroupFeedProgress? { currentProgress }

    // MARK: - Internal Types

    /// Sendable data extracted from a group feed smart search.
    private struct GroupFeedData: Sendable {
        let id: UUID
        let name: String
        let query: String
        let authors: [String]
        let categories: Set<String>
        let includeCrossListed: Bool
    }

    // MARK: - Refresh Group Feed

    /// Refresh a group feed by ID. Routes through the shared
    /// `BackgroundOperationQueue` so concurrent refresh requests for the
    /// same feed (or any work competing for the store) are globally
    /// deduped and visible in the operation overlay.
    ///
    /// Priority is `.userInitiated` — manual refreshes should bypass
    /// the startup grace period so the user always sees fresh data when
    /// they explicitly ask for it. Scheduled refreshes from
    /// `FeedScheduler` submit at `.background` priority (see
    /// `refreshGroupFeedByIDScheduled`).
    @discardableResult
    public func refreshGroupFeedByID(_ smartSearchID: UUID) async throws -> Int {
        try await refreshGroupFeedByID(smartSearchID, priority: .userInitiated)
    }

    /// Internal priority-controlled variant — user-initiated manual
    /// refreshes use `.userInitiated`; scheduled refreshes use
    /// `.background` so the startup grace applies.
    @discardableResult
    public func refreshGroupFeedByID(
        _ smartSearchID: UUID,
        priority: OperationPriority
    ) async throws -> Int {
        let dedupeKey = "group-feed-refresh-\(smartSearchID.uuidString)"

        let result: AwaitResult<Int> = try await BackgroundOperationQueue.shared.submitAndAwait(
            kind: .network,
            priority: priority,
            dedupeKey: dedupeKey,
            label: "GroupFeedRefresh[\(smartSearchID)]"
        ) { _ in
            try await self.runRefreshLocked(smartSearchID)
        }

        switch result {
        case .completed(let count):
            return count
        case .deduped:
            Logger.inbox.infoCapture(
                "Group feed \(smartSearchID) already refreshing — operation queue deduped",
                category: "group-feed"
            )
            return 0
        case .refusedStartupGrace:
            Logger.inbox.debugCapture(
                "Group feed \(smartSearchID) refresh refused: startup grace",
                category: "group-feed"
            )
            return 0
        }
    }

    /// Runs the actual refresh. Called only from inside the operation
    /// queue's work closure, so the queue's dedupe key guarantees only
    /// one invocation per feed ID at a time.
    private func runRefreshLocked(_ smartSearchID: UUID) async throws -> Int {
        // Keep the legacy activelyRefreshing set as belt-and-suspenders
        // for anything that still calls refreshGroupFeedInternal directly.
        if activelyRefreshing.contains(smartSearchID) {
            return 0
        }
        activelyRefreshing.insert(smartSearchID)
        defer { activelyRefreshing.remove(smartSearchID) }

        // Extract all needed data on main actor
        let feedData: GroupFeedData? = await withStore { store -> GroupFeedData? in
            guard let ss = store.getSmartSearch(id: smartSearchID) else { return nil }

            // Parse group feed metadata from query
            let query = ss.query
            guard query.hasPrefix("GROUP_FEED|") else { return nil }

            let authors = Self.parseGroupFeedAuthors(query)
            let categories = Self.parseGroupFeedCategories(query)
            let includeCrossListed = Self.parseGroupFeedIncludesCrossListed(query)

            return GroupFeedData(
                id: ss.id,
                name: ss.name,
                query: query,
                authors: authors,
                categories: categories,
                includeCrossListed: includeCrossListed
            )
        }

        guard let feedData else {
            throw GroupFeedError.notGroupFeed
        }

        return try await refreshGroupFeedInternal(feedData)
    }

    /// Internal refresh implementation using Sendable data.
    private func refreshGroupFeedInternal(_ feedData: GroupFeedData) async throws -> Int {
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
            currentProgress = GroupFeedProgress(
                totalAuthors: authors.count,
                completedAuthors: index,
                currentAuthor: author,
                totalPapers: allResults.count
            )

            if index > 0 {
                Logger.inbox.debugCapture(
                    "Waiting \(Int(staggerDelaySeconds))s before searching for '\(author)'",
                    category: "group-feed"
                )
                try await Task.sleep(for: .seconds(staggerDelaySeconds))
            }

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
                let results = try await arxivSource.search(query: query, maxResults: maxResultsPerAuthor, daysBack: 90)

                let exactMatches = results.filter { result in
                    authorMatchesExactly(author, in: result.authors)
                }

                Logger.inbox.debugCapture(
                    "Found \(results.count) papers for '\(author)', \(exactMatches.count) with exact author match",
                    category: "group-feed"
                )

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
            }
        }

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
        let newCount = await processResultsForInbox(allResults, smartSearchID: feedData.id)

        Logger.inbox.infoCapture(
            "Group feed refresh complete: \(newCount) new papers added to Inbox",
            category: "group-feed"
        )

        return newCount
    }

    // MARK: - Pipeline

    /// Process search results through the Inbox pipeline.
    private func processResultsForInbox(_ results: [SearchResult], smartSearchID: UUID) async -> Int {
        guard !results.isEmpty else { return 0 }

        let inboxManager = await MainActor.run { InboxManager.shared }

        // Filter results
        var filteredResults: [SearchResult] = []

        for result in results {
            let shouldFilter = await MainActor.run {
                inboxManager.shouldFilter(result: result)
            }

            if shouldFilter {
                Logger.inbox.debugCapture("Filtered out muted paper: \(result.title)", category: "group-feed")
                continue
            }

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

        // Deduplicate: find existing publications by identifiers
        var existingPubIDs: [UUID] = []
        var newResults: [SearchResult] = []

        for result in filteredResults {
            let existing = await withStore { store -> PublicationRowData? in
                if let doi = result.doi, !doi.isEmpty,
                   let pub = store.findByDoi(doi: doi).first {
                    return pub
                }
                if let arxiv = result.arxivID, !arxiv.isEmpty,
                   let pub = store.findByArxiv(arxivId: arxiv).first {
                    return pub
                }
                return nil
            }
            if let existing {
                existingPubIDs.append(existing.id)
            } else {
                newResults.append(result)
            }
        }

        Logger.inbox.debugCapture(
            "Found \(existingPubIDs.count) existing papers, \(newResults.count) new papers",
            category: "group-feed"
        )

        // Filter existing papers: skip those already in inbox or dismissed
        let existingPubIDsToAdd: [UUID] = await MainActor.run {
            let store = RustStoreAdapter.shared
            let inboxLib = inboxManager.inboxLibrary
            return existingPubIDs.filter { pubID in
                guard let detail = store.getPublicationDetail(id: pubID) else { return false }
                if let inboxLib, detail.libraryIDs.contains(inboxLib.id) {
                    return false
                }
                if inboxManager.wasDismissed(doi: detail.doi, arxivID: detail.arxivID, bibcode: detail.bibcode) {
                    return false
                }
                return true
            }
        }

        // Add filtered existing publications to inbox and link to feed
        if !existingPubIDsToAdd.isEmpty {
            await MainActor.run {
                _ = inboxManager.addToInboxBatch(existingPubIDsToAdd)
                RustStoreAdapter.shared.addToCollection(publicationIds: existingPubIDsToAdd, collectionId: smartSearchID)
            }
        }

        // Create new publications and add to Inbox
        var newPaperIDs: [UUID] = []
        if !newResults.isEmpty {
            // Get default library for import
            let defaultLibraryId = await withStore { store -> UUID? in
                store.getDefaultLibrary()?.id ?? store.listLibraries().first?.id
            }
            guard let libraryId = defaultLibraryId else {
                Logger.inbox.errorCapture("No library available for import", category: "group-feed")
                return existingPubIDsToAdd.count
            }

            for result in newResults {
                let bibtex = result.toBibTeX()
                let importedIDs = await withStore { $0.importBibTeX(bibtex, libraryId: libraryId) }
                newPaperIDs.append(contentsOf: importedIDs)
            }

            let capturedNewIDs = newPaperIDs
            await MainActor.run {
                _ = inboxManager.addToInboxBatch(capturedNewIDs)
                RustStoreAdapter.shared.addToCollection(publicationIds: capturedNewIDs, collectionId: smartSearchID)
            }
        }

        let totalLinked = existingPubIDsToAdd.count + newPaperIDs.count
        Logger.inbox.debugCapture("Created \(newPaperIDs.count) new papers, linked \(totalLinked) to feed", category: "group-feed")

        // Immediate ADS enrichment
        if !newPaperIDs.isEmpty {
            let enrichedCount = await EnrichmentCoordinator.shared.enrichBatchByIDs(newPaperIDs)
            Logger.inbox.infoCapture(
                "ADS enrichment: \(enrichedCount)/\(newPaperIDs.count) papers resolved with bibcodes",
                category: "group-feed"
            )
        }

        return existingPubIDsToAdd.count + newPaperIDs.count
    }

    // MARK: - Group Feed Query Parsing

    /// Parse authors from a GROUP_FEED query string.
    static func parseGroupFeedAuthors(_ query: String) -> [String] {
        // Supported formats:
        //   authors:Name1,Name2,Name3                           (current, `,` between authors)
        //   au:Lastname, First;Lastname, First;Lastname, First  (legacy `;` between authors)
        //   au:Lastname, First,Lastname, First                  (legacy mixed — `,` inside name, bare `,` between)
        //
        // Disambiguation: ", " (comma + whitespace) is treated as INTRA-name
        // (joining "Lastname" and "Firstname"). A bare "," not followed by
        // whitespace or a ";" is treated as BETWEEN authors.
        let parts = query.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        for part in parts {
            if let raw = stripPrefix(part, prefixes: ["authors:", "au:"]) {
                return splitAuthorList(raw)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .map(lastNameOnly)
            }
        }
        return []
    }

    /// Split an author list string, treating "," as separator ONLY when not
    /// followed by whitespace. A bare "," between "Risa" and "Blandford"
    /// separates authors; ", " between "Lastname" and "Firstname" joins them.
    /// ";" always separates authors.
    private static func splitAuthorList(_ s: String) -> [String] {
        var result: [String] = []
        var current = ""
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == ";" {
                result.append(current)
                current = ""
                i += 1
                continue
            }
            if c == "," {
                // Peek next character
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                if let n = next, n.isWhitespace {
                    // Intra-name separator (e.g., "Lastname, Firstname")
                    current.append(c)
                    i += 1
                } else {
                    // Inter-name separator
                    result.append(current)
                    current = ""
                    i += 1
                }
                continue
            }
            current.append(c)
            i += 1
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Extract the surname from a "Lastname, Firstname" or "Firstname Lastname"
    /// string. arXiv's author search works best on surnames, so we strip
    /// first names before building queries.
    private static func lastNameOnly(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let commaIdx = trimmed.firstIndex(of: ",") {
            // "Lastname, Firstname" → "Lastname"
            return String(trimmed[..<commaIdx]).trimmingCharacters(in: .whitespaces)
        }
        // "Firstname Lastname" → "Lastname" (take last token)
        let tokens = trimmed.split(separator: " ")
        if tokens.count > 1, let last = tokens.last {
            return String(last)
        }
        return trimmed
    }

    /// Parse categories from a GROUP_FEED query string.
    static func parseGroupFeedCategories(_ query: String) -> Set<String> {
        let parts = query.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        for part in parts {
            if let raw = stripPrefix(part, prefixes: ["categories:", "cat:"]) {
                return Set(
                    raw.components(separatedBy: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                )
            }
        }
        return []
    }

    /// Parse cross-listed flag from a GROUP_FEED query string.
    static func parseGroupFeedIncludesCrossListed(_ query: String) -> Bool {
        let parts = query.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        for part in parts {
            if let raw = stripPrefix(part, prefixes: ["crosslist:", "crosslisted:"]) {
                return raw.trimmingCharacters(in: .whitespaces).lowercased() == "true"
            }
        }
        return true
    }

    private static func stripPrefix(_ s: String, prefixes: [String]) -> String? {
        for p in prefixes where s.hasPrefix(p) {
            return String(s.dropFirst(p.count))
        }
        return nil
    }

    // MARK: - Author Matching

    /// Check if a target author name matches any author in the paper's author list.
    private func authorMatchesExactly(_ targetAuthor: String, in paperAuthors: [String]) -> Bool {
        let targetNormalized = normalizeAuthorName(targetAuthor)

        for paperAuthor in paperAuthors {
            let paperNormalized = normalizeAuthorName(paperAuthor)

            if targetNormalized == paperNormalized {
                return true
            }

            let targetParts = targetNormalized.split(separator: " ").map(String.init)
            let paperParts = paperNormalized.split(separator: " ").map(String.init)

            let significantTargetParts = targetParts.filter { $0.count > 1 }
            let allPartsMatch = significantTargetParts.allSatisfy { targetPart in
                paperParts.contains { paperPart in
                    paperPart == targetPart || paperPart.hasPrefix(targetPart) || targetPart.hasPrefix(paperPart)
                }
            }

            if allPartsMatch && !significantTargetParts.isEmpty {
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
    private func normalizeAuthorName(_ name: String) -> String {
        var normalized = name.lowercased()
        normalized = normalized.replacingOccurrences(of: ".", with: "")
        normalized = normalized.replacingOccurrences(of: ",", with: " ")

        while normalized.contains("  ") {
            normalized = normalized.replacingOccurrences(of: "  ", with: " ")
        }

        normalized = normalized.trimmingCharacters(in: .whitespaces)
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
