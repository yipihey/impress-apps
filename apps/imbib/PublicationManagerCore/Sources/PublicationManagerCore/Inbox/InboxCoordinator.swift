//
//  InboxCoordinator.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-06.
//

import Foundation
import OSLog

// MARK: - Inbox Coordinator

/// Coordinates Inbox services: scheduling, fetching, and management.
///
/// This is the main entry point for Inbox functionality. It creates and manages:
/// - InboxManager: Inbox library and mute management
/// - PaperFetchService: Unified fetch pipeline
/// - InboxScheduler: Automatic feed refresh
///
/// ## Usage
///
/// Start on app launch:
/// ```swift
/// Task {
///     await InboxCoordinator.shared.start()
/// }
/// ```
@MainActor
public final class InboxCoordinator {

    // MARK: - Singleton

    public static let shared = InboxCoordinator()

    // MARK: - Dependencies

    /// The inbox manager (created on first access)
    public var inboxManager: InboxManager { InboxManager.shared }

    /// The paper fetch service
    public private(set) var paperFetchService: PaperFetchService?

    /// The inbox scheduler
    public private(set) var scheduler: InboxScheduler?

    // MARK: - State

    private var isStarted = false

    // MARK: - Initialization

    private init() {}

    // MARK: - Lifecycle

    /// Start Inbox services.
    ///
    /// This should be called on app launch after other services are initialized.
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
        let repository = PublicationRepository()

        // Register built-in sources if not already done
        await sourceManager.registerBuiltInSources()

        let fetchService = PaperFetchService(
            sourceManager: sourceManager,
            repository: repository
        )
        self.paperFetchService = fetchService
        Logger.inbox.debugCapture("PaperFetchService created", category: "coordinator")

        // Create and start scheduler
        let inboxScheduler = InboxScheduler(
            paperFetchService: fetchService
        )
        self.scheduler = inboxScheduler

        await inboxScheduler.start()
        Logger.inbox.infoCapture("InboxScheduler started", category: "coordinator")

        isStarted = true
        Logger.inbox.infoCapture("InboxCoordinator started successfully", category: "coordinator")
    }

    /// Stop Inbox services.
    public func stop() async {
        guard isStarted else { return }

        Logger.inbox.infoCapture("Stopping InboxCoordinator...", category: "coordinator")

        await scheduler?.stop()
        scheduler = nil
        paperFetchService = nil

        isStarted = false
        Logger.inbox.infoCapture("InboxCoordinator stopped", category: "coordinator")
    }

    // MARK: - Convenience Methods

    /// Trigger an immediate refresh of all due feeds.
    @discardableResult
    public func refreshAllFeeds() async -> Int {
        guard let scheduler = scheduler else {
            Logger.inbox.warning("InboxCoordinator: scheduler not started")
            return 0
        }
        return await scheduler.triggerImmediateCheck()
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

    /// Get scheduler statistics.
    public func schedulerStatistics() async -> InboxSchedulerStatistics? {
        await scheduler?.statistics
    }
}
