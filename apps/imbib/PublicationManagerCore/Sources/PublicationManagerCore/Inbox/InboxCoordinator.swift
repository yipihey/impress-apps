//
//  InboxCoordinator.swift
//  PublicationManagerCore
//
//  Coordinates Inbox services: scheduling, fetching, and management.
//

import Foundation
import OSLog

// MARK: - Inbox Coordinator

/// Coordinates Inbox and feed services: scheduling, fetching, and management.
///
/// This is the main entry point for feed functionality. It creates and manages:
/// - InboxManager: Inbox library and mute management
/// - MuteService: Global mute filtering (extracted from InboxManager)
/// - PaperFetchService: Unified fetch pipeline
/// - FeedScheduler: Unified feed refresh (all autoRefreshEnabled feeds, inbox and library)
@MainActor
public final class InboxCoordinator {

    // MARK: - Singleton

    public static let shared = InboxCoordinator()

    // MARK: - Dependencies

    /// The inbox manager (created on first access)
    public var inboxManager: InboxManager { InboxManager.shared }

    /// The global mute service
    public var muteService: MuteService { MuteService.shared }

    /// The paper fetch service
    public private(set) var paperFetchService: PaperFetchService?

    /// The legacy inbox scheduler — deprecated, kept for API compatibility.
    /// FeedScheduler now handles all feeds including inbox feeds.
    @available(*, deprecated, message: "Use feedScheduler instead. FeedScheduler handles all auto-refresh feeds.")
    public private(set) var scheduler: InboxScheduler?

    /// The unified feed scheduler (all autoRefreshEnabled feeds)
    public private(set) var feedScheduler: FeedScheduler?

    // MARK: - State

    private var isStarted = false

    // MARK: - Initialization

    private init() {}

    // MARK: - Lifecycle

    /// Start Inbox services.
    public func start() async {
        guard !isStarted else {
            Logger.inbox.debug("InboxCoordinator already started")
            return
        }

        Logger.inbox.infoCapture("Starting InboxCoordinator...", category: "coordinator")

        // Initialize Inbox library if needed
        _ = inboxManager.getOrCreateInbox()
        Logger.inbox.debugCapture("Inbox library initialized", category: "coordinator")

        // Create fetch service with shared dependencies
        let sourceManager = SourceManager(credentialManager: CredentialManager.shared)

        // Register built-in sources if not already done
        await sourceManager.registerBuiltInSources()

        let fetchService = PaperFetchService(
            sourceManager: sourceManager
        )
        self.paperFetchService = fetchService
        Logger.inbox.debugCapture("PaperFetchService created", category: "coordinator")

        // Create and start unified feed scheduler (all autoRefreshEnabled feeds)
        let unifiedScheduler = FeedScheduler(
            paperFetchService: fetchService
        )
        self.feedScheduler = unifiedScheduler

        await unifiedScheduler.start()
        Logger.inbox.infoCapture("FeedScheduler started (unified: handles all auto-refresh feeds)", category: "coordinator")

        isStarted = true
        Logger.inbox.infoCapture("InboxCoordinator started successfully", category: "coordinator")
    }

    /// Stop Inbox and feed services.
    public func stop() async {
        guard isStarted else { return }

        Logger.inbox.infoCapture("Stopping InboxCoordinator...", category: "coordinator")

        await feedScheduler?.stop()
        feedScheduler = nil
        paperFetchService = nil

        isStarted = false
        Logger.inbox.infoCapture("InboxCoordinator stopped", category: "coordinator")
    }

    // MARK: - Convenience Methods

    /// Trigger an immediate refresh of all due feeds.
    @discardableResult
    public func refreshAllFeeds() async -> Int {
        guard let feedScheduler = feedScheduler else {
            Logger.inbox.warning("InboxCoordinator: no scheduler running")
            return 0
        }
        return await feedScheduler.triggerImmediateCheck()
    }

    /// Send search results to the Inbox.
    @discardableResult
    public func sendToInbox(results: [SearchResult]) async -> Int {
        guard let fetchService = paperFetchService else {
            Logger.inbox.warning("InboxCoordinator: fetch service not started")
            return 0
        }
        return await fetchService.sendToInbox(results: results)
    }

    /// Get feed scheduler statistics.
    public func feedSchedulerStatistics() async -> FeedSchedulerStatistics? {
        await feedScheduler?.statistics
    }

    /// Get inbox scheduler statistics (deprecated — use feedSchedulerStatistics).
    @available(*, deprecated, message: "Use feedSchedulerStatistics instead")
    public func schedulerStatistics() async -> InboxSchedulerStatistics? {
        nil
    }
}
