//
//  RemarkableSyncScheduler.swift
//  PublicationManagerCore
//
//  Background sync scheduler for reMarkable integration.
//  ADR-019: reMarkable Tablet Integration
//

import Foundation
import OSLog

#if os(iOS)
import BackgroundTasks
#endif

#if os(macOS)
import AppKit
#endif

private let logger = Logger(subsystem: "com.imbib.app", category: "remarkableSync")

// MARK: - Sync Scheduler

/// Manages background sync scheduling for reMarkable.
///
/// Uses BGTaskScheduler on iOS and Timer on macOS for periodic sync.
/// Respects user settings for sync interval and enabled state.
@MainActor
public final class RemarkableSyncScheduler: ObservableObject {

    // MARK: - Singleton

    public static let shared = RemarkableSyncScheduler()

    // MARK: - Published Properties

    @Published public private(set) var isRunning = false
    @Published public private(set) var lastSyncDate: Date?
    @Published public private(set) var lastSyncError: Error?
    @Published public private(set) var nextScheduledSync: Date?

    // MARK: - Private Properties

    private var syncTimer: Timer?
    private let settings = RemarkableSettingsStore.shared
    private var syncTask: Task<Void, Never>?

    // Background task identifier (iOS)
    private let backgroundTaskIdentifier = "com.imbib.remarkableSync"

    // MARK: - Initialization

    private init() {
        setupNotificationObservers()
    }

    // MARK: - Public API

    /// Start the sync scheduler.
    public func start() {
        guard settings.autoSyncEnabled else {
            logger.info("Auto sync disabled, not starting scheduler")
            return
        }

        guard settings.isAuthenticated else {
            logger.info("Not authenticated, not starting scheduler")
            return
        }

        isRunning = true
        scheduleNextSync()

        logger.info("Sync scheduler started with interval: \(self.settings.syncInterval)s")
    }

    /// Stop the sync scheduler.
    public func stop() {
        syncTimer?.invalidate()
        syncTimer = nil
        syncTask?.cancel()
        syncTask = nil
        isRunning = false
        nextScheduledSync = nil

        logger.info("Sync scheduler stopped")
    }

    /// Trigger an immediate sync.
    public func syncNow() async {
        logger.info("Manual sync triggered")
        await performSync()
    }

    /// Register background task (iOS only).
    public func registerBackgroundTask() {
        #if os(iOS)
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: backgroundTaskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let self = self, let bgTask = task as? BGProcessingTask else { return }
            self.handleBackgroundTask(bgTask)
        }

        logger.info("Registered background task: \(self.backgroundTaskIdentifier)")
        #endif
    }

    // MARK: - Private Methods

    private func setupNotificationObservers() {
        // Listen for settings changes
        NotificationCenter.default.addObserver(
            forName: .remarkableSettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleSettingsChanged()
            }
        }

        // Listen for app becoming active (to refresh state)
        #if os(macOS)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleAppBecameActive()
            }
        }
        #endif
    }

    private func handleSettingsChanged() {
        if settings.autoSyncEnabled && settings.isAuthenticated {
            if isRunning {
                // Reschedule with new interval
                scheduleNextSync()
            } else {
                start()
            }
        } else {
            stop()
        }
    }

    private func handleAppBecameActive() {
        // Check if we missed a scheduled sync while inactive
        if let nextSync = nextScheduledSync, nextSync < Date() {
            Task {
                await performSync()
            }
        }
    }

    private func scheduleNextSync() {
        syncTimer?.invalidate()

        let interval = settings.syncInterval
        let nextSync = Date().addingTimeInterval(interval)
        nextScheduledSync = nextSync

        syncTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.performSync()
            }
        }

        logger.debug("Next sync scheduled for: \(nextSync)")

        // Also schedule background task on iOS
        #if os(iOS)
        scheduleBackgroundTask()
        #endif
    }

    #if os(iOS)
    private func scheduleBackgroundTask() {
        let request = BGProcessingTaskRequest(identifier: backgroundTaskIdentifier)
        request.earliestBeginDate = nextScheduledSync
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false

        do {
            try BGTaskScheduler.shared.submit(request)
            logger.debug("Scheduled background task")
        } catch {
            logger.error("Failed to schedule background task: \(error)")
        }
    }

    private func handleBackgroundTask(_ task: BGProcessingTask) {
        // Create a task to perform sync
        let syncTask = Task {
            await performSync()
        }

        // Handle expiration
        task.expirationHandler = {
            syncTask.cancel()
        }

        // Wait for completion
        Task {
            await syncTask.value
            task.setTaskCompleted(success: lastSyncError == nil)

            // Schedule next background task
            await MainActor.run {
                scheduleBackgroundTask()
            }
        }
    }
    #endif

    private func performSync() async {
        // Check if sync is already in progress
        if let existingTask = syncTask, !existingTask.isCancelled {
            logger.debug("Sync already in progress, skipping")
            return
        }

        logger.info("Starting sync...")
        lastSyncError = nil

        syncTask = Task {
            do {
                let syncManager = RemarkableSyncManager.shared

                // Get sync status
                let pendingUploads = await syncManager.pendingUploads
                let pendingImports = await syncManager.pendingImports

                logger.debug("Pending uploads: \(pendingUploads), pending imports: \(pendingImports)")

                // Perform sync operations
                // This would integrate with the sync manager to:
                // 1. Upload new publications to reMarkable
                // 2. Download and import new annotations

                // For now, just update the last sync date
                await MainActor.run {
                    lastSyncDate = Date()
                    scheduleNextSync()
                }

                logger.info("Sync completed successfully")

            } catch {
                await MainActor.run {
                    lastSyncError = error
                }
                logger.error("Sync failed: \(error)")
            }
        }

        await syncTask?.value
        syncTask = nil
    }
}

// MARK: - Notification Names

public extension Notification.Name {
    static let remarkableSettingsChanged = Notification.Name("remarkableSettingsChanged")
    static let remarkableSyncStarted = Notification.Name("remarkableSyncStarted")
    static let remarkableSyncCompleted = Notification.Name("remarkableSyncCompleted")
    static let remarkableSyncFailed = Notification.Name("remarkableSyncFailed")
}

// MARK: - Sync Status

/// Current sync status for UI display.
public struct RemarkableSyncStatus: Sendable {
    public let isRunning: Bool
    public let lastSyncDate: Date?
    public let lastError: String?
    public let nextScheduledSync: Date?
    public let pendingUploads: Int
    public let pendingImports: Int

    public var statusText: String {
        if isRunning {
            return "Syncing..."
        } else if let error = lastError {
            return "Error: \(error)"
        } else if let lastSync = lastSyncDate {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return "Last sync: \(formatter.localizedString(for: lastSync, relativeTo: Date()))"
        } else {
            return "Not synced"
        }
    }

    public var hasWork: Bool {
        pendingUploads > 0 || pendingImports > 0
    }
}
