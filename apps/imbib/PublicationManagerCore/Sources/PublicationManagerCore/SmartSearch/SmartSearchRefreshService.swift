//
//  SmartSearchRefreshService.swift
//  PublicationManagerCore
//
//  Actor-based service for managing staggered background refresh of smart searches.
//

import Foundation
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
public actor SmartSearchRefreshService {

    // MARK: - Singleton

    public static let shared = SmartSearchRefreshService()

    // MARK: - Configuration

    private let maxConcurrentRefreshes = 1
    private let delayBetweenRefreshes: TimeInterval = 3.0
    private let startupGracePeriod: TimeInterval = 5.0
    private let maxQueueSize = 20

    // MARK: - Dependencies

    private var sourceManager: SourceManager?

    // MARK: - Store Access

    private func withStore<T: Sendable>(_ operation: @MainActor @Sendable (RustStoreAdapter) -> T) async -> T {
        await MainActor.run { operation(RustStoreAdapter.shared) }
    }

    // MARK: - State

    private var refreshQueue: [RefreshRequest] = []
    private var activeRefreshes: Set<UUID> = []
    private var isProcessing = false
    private var startupGraceElapsed = false
    private var completionHandlers: [UUID: [(Error?) -> Void]] = [:]

    // MARK: - Initialization

    public init() {}

    // MARK: - Configuration

    public func configure(sourceManager: SourceManager) {
        self.sourceManager = sourceManager
        Logger.smartSearch.infoCapture("SmartSearchRefreshService configured", category: "refresh")
    }

    // MARK: - Public Interface

    /// Queue a smart search for background refresh by ID.
    public func queueRefreshByID(_ smartSearchID: UUID, priority: RefreshPriority = .normal) {
        // Don't queue if already in queue or actively refreshing
        if activeRefreshes.contains(smartSearchID) {
            return
        }

        if refreshQueue.contains(where: { $0.smartSearchID == smartSearchID }) {
            if let index = refreshQueue.firstIndex(where: { $0.smartSearchID == smartSearchID }),
               priority < refreshQueue[index].priority {
                refreshQueue[index] = RefreshRequest(smartSearchID: smartSearchID, priority: priority)
                sortQueue()
            }
            return
        }

        let request = RefreshRequest(smartSearchID: smartSearchID, priority: priority)
        refreshQueue.append(request)
        sortQueue()

        while refreshQueue.count > maxQueueSize {
            if let lowPriorityIndex = refreshQueue.lastIndex(where: { $0.priority == .low }) {
                refreshQueue.remove(at: lowPriorityIndex)
            } else {
                break
            }
        }

        Logger.smartSearch.debugCapture("Queued smart search \(smartSearchID) with priority \(priority) (queue size: \(refreshQueue.count))", category: "refresh")

        if !isProcessing {
            if priority == .high {
                startupGraceElapsed = true
            }
            startProcessing()
        }
    }

    /// Queue a refresh and wait for it to complete.
    public func queueRefreshAndWaitByID(_ smartSearchID: UUID, priority: RefreshPriority = .normal) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if completionHandlers[smartSearchID] == nil {
                completionHandlers[smartSearchID] = []
            }
            completionHandlers[smartSearchID]?.append { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }

            Task {
                await self.queueRefreshByID(smartSearchID, priority: priority)
            }
        }
    }

    public func isRefreshing(_ id: UUID) -> Bool {
        activeRefreshes.contains(id)
    }

    public func isQueued(_ id: UUID) -> Bool {
        refreshQueue.contains { $0.smartSearchID == id }
    }

    public var queueSize: Int {
        refreshQueue.count
    }

    public var activeCount: Int {
        activeRefreshes.count
    }

    public func cancelPending(_ id: UUID) {
        refreshQueue.removeAll { $0.smartSearchID == id }
    }

    public func clearQueue() {
        refreshQueue.removeAll()
        Logger.smartSearch.infoCapture("Cleared refresh queue", category: "refresh")
    }

    // MARK: - Processing

    private func startProcessing() {
        guard !isProcessing else { return }
        isProcessing = true

        Logger.smartSearch.debugCapture("Starting refresh processing loop", category: "refresh")

        Task.detached(priority: .utility) { [weak self] in
            await self?.processQueue()
        }
    }

    private func processQueue() async {
        if !startupGraceElapsed {
            Logger.smartSearch.infoCapture("Waiting \(Int(startupGracePeriod))s startup grace period before processing refresh queue", category: "refresh")
            try? await Task.sleep(for: .seconds(startupGracePeriod))
            await setStartupGraceElapsed()
        }

        while await hasWork() {
            while await activeRefreshes.count >= maxConcurrentRefreshes {
                try? await Task.sleep(for: .milliseconds(100))
            }

            guard let request = await dequeue() else {
                break
            }

            await startRefresh(request.smartSearchID)
            try? await Task.sleep(for: .seconds(delayBetweenRefreshes))
        }

        await markProcessingComplete()
    }

    private func setStartupGraceElapsed() {
        startupGraceElapsed = true
    }

    private func hasWork() -> Bool {
        !refreshQueue.isEmpty
    }

    private func dequeue() -> RefreshRequest? {
        guard !refreshQueue.isEmpty else { return nil }
        return refreshQueue.removeFirst()
    }

    private func markProcessingComplete() {
        isProcessing = false
        Logger.smartSearch.debugCapture("Refresh processing loop complete", category: "refresh")
    }

    /// Sendable metadata extracted from a SmartSearch for use across actor boundaries.
    private struct SmartSearchMetadata: Sendable {
        let id: UUID
        let name: String
        let isGroupFeed: Bool
        let sources: [String]
        let sharedLibraryName: String?
    }

    private func startRefresh(_ smartSearchID: UUID) async {
        guard let sourceManager else {
            Logger.smartSearch.errorCapture("SmartSearchRefreshService not configured - call configure() first", category: "refresh")
            return
        }

        activeRefreshes.insert(smartSearchID)

        let metadata: SmartSearchMetadata? = await withStore { store -> SmartSearchMetadata? in
            guard let ss = store.getSmartSearch(id: smartSearchID) else { return nil }
            let sharedLibName: String? = {
                guard let libID = ss.libraryID,
                      let lib = store.getLibrary(id: libID) else { return nil }
                // Check if library is shared (heuristic: name contains "Shared")
                return nil  // Shared library detection is not needed for basic refresh
            }()
            return SmartSearchMetadata(
                id: ss.id,
                name: ss.name,
                isGroupFeed: ss.query.hasPrefix("GROUP_FEED|"),
                sources: ss.sourceIDs,
                sharedLibraryName: sharedLibName
            )
        }

        guard let metadata else {
            Logger.smartSearch.warningCapture("Smart search \(smartSearchID) not found - may have been deleted", category: "refresh")
            refreshComplete(smartSearchID, error: nil)
            return
        }

        Logger.smartSearch.infoCapture("Starting background refresh of '\(metadata.name)'", category: "refresh")

        // Route group feeds to GroupFeedRefreshService
        if metadata.isGroupFeed {
            do {
                _ = try await GroupFeedRefreshService.shared.refreshGroupFeedByID(smartSearchID)
                Logger.smartSearch.infoCapture("Group feed refresh completed for '\(metadata.name)'", category: "refresh")
                refreshComplete(smartSearchID, error: nil)

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
            sourceManager: sourceManager
        )

        guard let provider else {
            Logger.smartSearch.warningCapture("Could not create provider for '\(metadata.name)'", category: "refresh")
            refreshComplete(smartSearchID, error: nil)
            return
        }

        do {
            try await provider.refresh()

            // Mark as executed
            await MainActor.run {
                SmartSearchRepository.shared.markExecuted(smartSearchID)
            }

            Logger.smartSearch.infoCapture("Background refresh completed for '\(metadata.name)'", category: "refresh")
            refreshComplete(smartSearchID, error: nil)

            await MainActor.run {
                NotificationCenter.default.post(name: .smartSearchRefreshCompleted, object: smartSearchID)
            }

        } catch {
            Logger.smartSearch.errorCapture("Background refresh failed for '\(metadata.name)': \(error.localizedDescription)", category: "refresh")
            refreshComplete(smartSearchID, error: error)
        }
    }

    private func refreshComplete(_ id: UUID, error: Error?) {
        activeRefreshes.remove(id)

        if let handlers = completionHandlers.removeValue(forKey: id) {
            for handler in handlers {
                handler(error)
            }
        }
    }

    private func sortQueue() {
        refreshQueue.sort { $0.priority < $1.priority }
    }
}

// MARK: - Notifications

public extension Notification.Name {
    /// Posted when a smart search background refresh completes.
    static let smartSearchRefreshCompleted = Notification.Name("smartSearchRefreshCompleted")
}
