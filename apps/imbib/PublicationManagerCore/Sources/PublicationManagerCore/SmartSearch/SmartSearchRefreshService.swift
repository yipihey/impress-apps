//
//  SmartSearchRefreshService.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-08.
//

import Foundation
import CoreData
import OSLog

// MARK: - Refresh Priority

/// Priority levels for smart search refresh requests.
public enum RefreshPriority: Int, Comparable, Sendable {
    case high = 0    // Currently visible smart search
    case normal = 1  // Standard background refresh
    case low = 2     // Batch startup refresh

    public static func < (lhs: RefreshPriority, rhs: RefreshPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Refresh Request

/// A request to refresh a smart search.
private struct RefreshRequest: Sendable {
    let smartSearchID: UUID
    let priority: RefreshPriority
    let requestedAt: Date

    init(smartSearchID: UUID, priority: RefreshPriority) {
        self.smartSearchID = smartSearchID
        self.priority = priority
        self.requestedAt = Date()
    }
}

// MARK: - Smart Search Refresh Service

/// Actor-based service for managing staggered background refresh of smart searches.
///
/// This service ensures:
/// - Maximum 1 concurrent refresh (to avoid overwhelming ADS/network)
/// - 1 second delay between refreshes
/// - Priority queue (visible smart search gets priority)
/// - Non-blocking: cached results shown immediately, refresh happens in background
///
/// ## Usage
///
/// ```swift
/// // Queue a refresh (high priority for visible, low for startup batch)
/// await SmartSearchRefreshService.shared.queueRefresh(smartSearch, priority: .high)
///
/// // Check if a smart search is being refreshed (for UI indicator)
/// let isRefreshing = await SmartSearchRefreshService.shared.isRefreshing(smartSearch.id)
/// ```
public actor SmartSearchRefreshService {

    // MARK: - Singleton

    public static let shared = SmartSearchRefreshService()

    // MARK: - Configuration

    /// Maximum number of concurrent refreshes (1 to avoid overwhelming the network)
    private let maxConcurrentRefreshes = 1

    /// Delay between starting each refresh (seconds)
    private let delayBetweenRefreshes: TimeInterval = 1.0

    /// Maximum queue size (drop oldest low-priority items if exceeded)
    private let maxQueueSize = 20

    // MARK: - Dependencies

    private var sourceManager: SourceManager?
    private var repository: PublicationRepository?

    // MARK: - State

    /// Queue of pending refresh requests (sorted by priority)
    private var refreshQueue: [RefreshRequest] = []

    /// Set of smart search IDs currently being refreshed
    private var activeRefreshes: Set<UUID> = []

    /// Whether the processing loop is running
    private var isProcessing = false

    /// Completion handlers waiting for a specific refresh to complete
    private var completionHandlers: [UUID: [(Error?) -> Void]] = [:]

    // MARK: - Initialization

    public init() {}

    // MARK: - Configuration

    /// Configure the service with dependencies.
    ///
    /// Call this once at app startup before using the service.
    public func configure(sourceManager: SourceManager, repository: PublicationRepository) {
        self.sourceManager = sourceManager
        self.repository = repository
        Logger.smartSearch.infoCapture("SmartSearchRefreshService configured", category: "refresh")
    }

    // MARK: - Public Interface

    /// Queue a smart search for background refresh.
    ///
    /// - Parameters:
    ///   - smartSearch: The smart search to refresh
    ///   - priority: Refresh priority (high for visible, low for batch startup)
    public func queueRefresh(_ smartSearch: CDSmartSearch, priority: RefreshPriority = .normal) {
        let id = smartSearch.id
        let name = smartSearch.name

        // Don't queue if already in queue or actively refreshing
        if activeRefreshes.contains(id) {
            Logger.smartSearch.debugCapture("Smart search '\(name)' already refreshing, skipping queue", category: "refresh")
            return
        }

        if refreshQueue.contains(where: { $0.smartSearchID == id }) {
            // Update priority if higher
            if let index = refreshQueue.firstIndex(where: { $0.smartSearchID == id }),
               priority < refreshQueue[index].priority {
                refreshQueue[index] = RefreshRequest(smartSearchID: id, priority: priority)
                sortQueue()
                Logger.smartSearch.debugCapture("Smart search '\(name)' priority upgraded to \(priority)", category: "refresh")
            }
            return
        }

        // Add to queue
        let request = RefreshRequest(smartSearchID: id, priority: priority)
        refreshQueue.append(request)
        sortQueue()

        // Trim queue if too large (remove oldest low-priority items)
        while refreshQueue.count > maxQueueSize {
            if let lowPriorityIndex = refreshQueue.lastIndex(where: { $0.priority == .low }) {
                refreshQueue.remove(at: lowPriorityIndex)
                Logger.smartSearch.debugCapture("Queue overflow: dropped low-priority item", category: "refresh")
            } else {
                break
            }
        }

        Logger.smartSearch.debugCapture("Queued smart search '\(name)' with priority \(priority) (queue size: \(refreshQueue.count))", category: "refresh")

        // Start processing if not already running
        if !isProcessing {
            startProcessing()
        }
    }

    /// Queue a refresh and wait for it to complete.
    ///
    /// - Parameters:
    ///   - smartSearch: The smart search to refresh
    ///   - priority: Refresh priority
    /// - Throws: Any error from the refresh operation
    public func queueRefreshAndWait(_ smartSearch: CDSmartSearch, priority: RefreshPriority = .normal) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let id = smartSearch.id

            // Add completion handler
            if completionHandlers[id] == nil {
                completionHandlers[id] = []
            }
            completionHandlers[id]?.append { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }

            // Queue the refresh
            Task {
                await self.queueRefresh(smartSearch, priority: priority)
            }
        }
    }

    /// Check if a smart search is currently being refreshed.
    ///
    /// Use this for UI indicators (subtle spinner when viewing a refreshing smart search).
    public func isRefreshing(_ id: UUID) -> Bool {
        activeRefreshes.contains(id)
    }

    /// Check if a smart search is queued for refresh.
    public func isQueued(_ id: UUID) -> Bool {
        refreshQueue.contains { $0.smartSearchID == id }
    }

    /// Get the current queue size.
    public var queueSize: Int {
        refreshQueue.count
    }

    /// Get the number of active refreshes.
    public var activeCount: Int {
        activeRefreshes.count
    }

    /// Cancel a pending refresh request (does not cancel active refresh).
    public func cancelPending(_ id: UUID) {
        refreshQueue.removeAll { $0.smartSearchID == id }
        Logger.smartSearch.debugCapture("Cancelled pending refresh for \(id)", category: "refresh")
    }

    /// Clear all pending refresh requests.
    public func clearQueue() {
        refreshQueue.removeAll()
        Logger.smartSearch.infoCapture("Cleared refresh queue", category: "refresh")
    }

    // MARK: - Processing

    /// Start the processing loop.
    private func startProcessing() {
        guard !isProcessing else { return }
        isProcessing = true

        Logger.smartSearch.debugCapture("Starting refresh processing loop", category: "refresh")

        Task.detached(priority: .utility) { [weak self] in
            await self?.processQueue()
        }
    }

    /// Main processing loop.
    private func processQueue() async {
        while await hasWork() {
            // Wait if at concurrency limit
            while await activeRefreshes.count >= maxConcurrentRefreshes {
                try? await Task.sleep(for: .milliseconds(100))
            }

            // Dequeue next request
            guard let request = await dequeue() else {
                break
            }

            // Start the refresh
            await startRefresh(request.smartSearchID)

            // Stagger delay before next refresh
            try? await Task.sleep(for: .seconds(delayBetweenRefreshes))
        }

        await markProcessingComplete()
    }

    /// Check if there's work to do.
    private func hasWork() -> Bool {
        !refreshQueue.isEmpty
    }

    /// Dequeue the next request.
    private func dequeue() -> RefreshRequest? {
        guard !refreshQueue.isEmpty else { return nil }
        return refreshQueue.removeFirst()
    }

    /// Mark processing as complete.
    private func markProcessingComplete() {
        isProcessing = false
        Logger.smartSearch.debugCapture("Refresh processing loop complete", category: "refresh")
    }

    /// Sendable metadata extracted from a CDSmartSearch for use across actor boundaries.
    private struct SmartSearchMetadata: Sendable {
        let id: UUID
        let name: String
        let isGroupFeed: Bool
        let sources: [String]
    }

    /// Start a single refresh operation.
    private func startRefresh(_ smartSearchID: UUID) async {
        guard let sourceManager, let repository else {
            Logger.smartSearch.errorCapture("SmartSearchRefreshService not configured - call configure() first", category: "refresh")
            return
        }

        activeRefreshes.insert(smartSearchID)

        // Fetch smart search metadata on main actor - extract Sendable data only
        let metadata: SmartSearchMetadata? = await MainActor.run {
            let request = NSFetchRequest<CDSmartSearch>(entityName: "SmartSearch")
            request.predicate = NSPredicate(format: "id == %@", smartSearchID as CVarArg)
            request.fetchLimit = 1
            guard let smartSearch = try? PersistenceController.shared.viewContext.fetch(request).first else {
                return nil
            }
            return SmartSearchMetadata(
                id: smartSearch.id,
                name: smartSearch.name ?? "Unnamed",
                isGroupFeed: smartSearch.isGroupFeed,
                sources: smartSearch.sources
            )
        }

        guard let metadata else {
            Logger.smartSearch.warningCapture("Smart search \(smartSearchID) not found - may have been deleted", category: "refresh")
            refreshComplete(smartSearchID, error: nil)
            return
        }

        Logger.smartSearch.infoCapture("Starting background refresh of '\(metadata.name)'", category: "refresh")

        // Route group feeds to GroupFeedRefreshService (staggered per-author searches)
        if metadata.isGroupFeed {
            do {
                // Use ID-based method to avoid Core Data threading issues
                _ = try await GroupFeedRefreshService.shared.refreshGroupFeedByID(smartSearchID)

                Logger.smartSearch.infoCapture("Group feed refresh completed for '\(metadata.name)'", category: "refresh")
                refreshComplete(smartSearchID, error: nil)

                // Post notification for UI updates
                await MainActor.run {
                    NotificationCenter.default.post(name: .smartSearchRefreshCompleted, object: smartSearchID)
                }
            } catch {
                Logger.smartSearch.errorCapture("Group feed refresh failed for '\(metadata.name)': \(error.localizedDescription)", category: "refresh")
                refreshComplete(smartSearchID, error: error)
            }
            return
        }

        // Get or create provider for regular smart searches
        let provider = await SmartSearchProviderCache.shared.getOrCreateByID(
            smartSearchID: smartSearchID,
            sourceManager: sourceManager,
            repository: repository
        )

        guard let provider else {
            Logger.smartSearch.warningCapture("Could not create provider for '\(metadata.name)'", category: "refresh")
            refreshComplete(smartSearchID, error: nil)
            return
        }

        // Perform the refresh
        do {
            try await provider.refresh()

            // Mark as executed and get unenriched papers on main actor
            let unenrichedPaperIDs: [UUID] = await MainActor.run {
                let request = NSFetchRequest<CDSmartSearch>(entityName: "SmartSearch")
                request.predicate = NSPredicate(format: "id == %@", smartSearchID as CVarArg)
                request.fetchLimit = 1
                guard let smartSearch = try? PersistenceController.shared.viewContext.fetch(request).first else {
                    return []
                }

                SmartSearchRepository.shared.markExecuted(smartSearch)

                // Check for arXiv papers needing enrichment
                guard metadata.sources.contains("arxiv"),
                      let collection = smartSearch.resultCollection,
                      let publications = collection.publications else {
                    return []
                }

                return publications
                    .filter { $0.bibcodeNormalized == nil && $0.fields["eprint"] != nil }
                    .map { $0.id }
            }

            // Immediate ADS enrichment for arXiv feeds (pass IDs, not managed objects)
            if !unenrichedPaperIDs.isEmpty {
                let enrichedCount = await EnrichmentCoordinator.shared.enrichBatchByIDs(unenrichedPaperIDs)
                Logger.smartSearch.infoCapture(
                    "ADS enrichment: \(enrichedCount)/\(unenrichedPaperIDs.count) papers resolved with bibcodes",
                    category: "refresh"
                )
            }

            Logger.smartSearch.infoCapture("Background refresh completed for '\(metadata.name)'", category: "refresh")
            refreshComplete(smartSearchID, error: nil)

            // Post notification for UI updates
            await MainActor.run {
                NotificationCenter.default.post(name: .smartSearchRefreshCompleted, object: smartSearchID)
            }

        } catch {
            Logger.smartSearch.errorCapture("Background refresh failed for '\(metadata.name)': \(error.localizedDescription)", category: "refresh")
            refreshComplete(smartSearchID, error: error)
        }
    }

    /// Mark a refresh as complete.
    private func refreshComplete(_ id: UUID, error: Error?) {
        activeRefreshes.remove(id)

        // Call completion handlers
        if let handlers = completionHandlers.removeValue(forKey: id) {
            for handler in handlers {
                handler(error)
            }
        }
    }

    /// Sort queue by priority (high priority first).
    private func sortQueue() {
        refreshQueue.sort { $0.priority < $1.priority }
    }
}

// MARK: - Notifications

public extension Notification.Name {
    /// Posted when a smart search background refresh completes.
    /// The object is the smart search UUID.
    static let smartSearchRefreshCompleted = Notification.Name("smartSearchRefreshCompleted")
}
