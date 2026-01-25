//
//  InboxScheduler.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-06.
//

import Foundation
import CoreData
import OSLog
import Network
#if os(macOS)
import IOKit.ps
#endif

// MARK: - Inbox Scheduler

/// Schedules automatic refresh of Inbox feeds (smart searches with auto-refresh enabled).
///
/// The scheduler:
/// - Tracks all smart searches with `feedsToInbox && autoRefreshEnabled`
/// - Respects per-feed `refreshIntervalSeconds`
/// - Uses PaperFetchService to execute searches and route results to Inbox
/// - Tracks statistics and next refresh times
///
/// ## Usage
///
/// ```swift
/// let scheduler = InboxScheduler(
///     paperFetchService: fetchService,
///     persistenceController: .shared
/// )
///
/// await scheduler.start()
/// // ... later
/// await scheduler.stop()
/// ```
public actor InboxScheduler {

    // MARK: - Configuration

    /// Minimum check interval (1 minute) - how often we check if any feed is due
    public static let checkInterval: TimeInterval = 60

    /// Default refresh interval (24 hours) for feeds without explicit setting
    public static let defaultRefreshInterval: TimeInterval = 24 * 60 * 60

    /// Minimum allowed refresh interval (15 minutes)
    public static let minimumRefreshInterval: TimeInterval = 15 * 60

    // MARK: - Dependencies

    private let paperFetchService: PaperFetchService
    private let persistenceController: PersistenceController

    // MARK: - Network Monitoring

    private let networkMonitor: NWPathMonitor
    private var isNetworkAvailable: Bool = true

    // MARK: - Power/Network Settings

    /// Whether to skip refresh when on battery power (macOS only)
    public var skipOnBattery: Bool = false

    /// Whether to skip refresh when network is unavailable
    public var skipWhenOffline: Bool = true

    /// Whether to skip refresh on cellular network (iOS)
    public var skipOnCellular: Bool = true

    // MARK: - State

    private var isRunning = false
    private var schedulerTask: Task<Void, Never>?
    private var networkMonitorQueue: DispatchQueue?

    /// Track last refresh time per smart search ID
    private var lastRefreshTimes: [UUID: Date] = [:]

    /// Statistics
    private var totalPapersFetched: Int = 0
    private var totalRefreshCycles: Int = 0
    private var lastCheckDate: Date?
    private var skippedCyclesForPower: Int = 0
    private var skippedCyclesForNetwork: Int = 0

    // MARK: - Initialization

    public init(
        paperFetchService: PaperFetchService,
        persistenceController: PersistenceController = .shared
    ) {
        self.paperFetchService = paperFetchService
        self.persistenceController = persistenceController
        self.networkMonitor = NWPathMonitor()
    }

    // MARK: - Control

    /// Start the inbox scheduler.
    public func start() {
        guard !isRunning else {
            Logger.inbox.debug("InboxScheduler already running")
            return
        }

        isRunning = true

        // Start network monitoring
        startNetworkMonitoring()

        Logger.inbox.infoCapture(
            "InboxScheduler started (check interval: \(Int(Self.checkInterval))s, skipOnBattery: \(skipOnBattery), skipWhenOffline: \(skipWhenOffline))",
            category: "inbox"
        )

        schedulerTask = Task {
            await runSchedulerLoop()
        }
    }

    /// Stop the inbox scheduler.
    public func stop() {
        guard isRunning else { return }

        isRunning = false
        schedulerTask?.cancel()
        schedulerTask = nil

        // Stop network monitoring
        stopNetworkMonitoring()

        Logger.inbox.infoCapture(
            "InboxScheduler stopped (total papers: \(totalPapersFetched), cycles: \(totalRefreshCycles), skipped: \(skippedCyclesForPower) power, \(skippedCyclesForNetwork) network)",
            category: "inbox"
        )
    }

    /// Trigger an immediate refresh of all due feeds.
    ///
    /// - Returns: Total number of new papers fetched
    @discardableResult
    public func triggerImmediateCheck() async -> Int {
        Logger.inbox.infoCapture("Manual Inbox refresh triggered", category: "scheduler")
        return await performCheckCycle()
    }

    /// Refresh a specific feed immediately with high priority.
    ///
    /// This queues the feed with high priority, which will be processed next
    /// in the staggered refresh queue.
    ///
    /// - Returns: Number of new papers fetched (0 since actual count is async)
    @discardableResult
    public func refreshFeed(_ smartSearch: CDSmartSearch) async throws -> Int {
        Logger.inbox.infoCapture("Manual refresh of feed: \(smartSearch.name)", category: "scheduler")

        // Queue with high priority for immediate processing
        await SmartSearchRefreshService.shared.queueRefresh(smartSearch, priority: .high)
        lastRefreshTimes[smartSearch.id] = Date()

        // Return 0 since actual papers are fetched asynchronously
        // UI will update via notification when refresh completes
        return 0
    }

    // MARK: - Status

    /// Whether the scheduler is running.
    public var running: Bool { isRunning }

    /// Get scheduler statistics.
    public var statistics: InboxSchedulerStatistics {
        InboxSchedulerStatistics(
            isRunning: isRunning,
            lastCheckDate: lastCheckDate,
            totalPapersFetched: totalPapersFetched,
            totalRefreshCycles: totalRefreshCycles,
            feedCount: lastRefreshTimes.count,
            skippedCyclesForPower: skippedCyclesForPower,
            skippedCyclesForNetwork: skippedCyclesForNetwork,
            isNetworkAvailable: isNetworkAvailable
        )
    }

    /// Get next refresh time for a specific feed.
    public func nextRefreshTime(for smartSearchID: UUID) -> Date? {
        guard let lastRefresh = lastRefreshTimes[smartSearchID] else {
            return nil  // Never refreshed, due immediately
        }

        // We need to look up the interval - for now return a default
        // In practice this would query the smart search
        return lastRefresh.addingTimeInterval(Self.defaultRefreshInterval)
    }

    /// Get all feeds that are due for refresh.
    public func dueFeeds() async -> [CDSmartSearch] {
        let feeds = await fetchInboxFeeds()
        return feeds.filter { isDue($0) }
    }

    // MARK: - Private Helpers

    /// Main scheduler loop.
    private func runSchedulerLoop() async {
        // Do an initial check immediately on start
        await performCheckCycle()

        while isRunning && !Task.isCancelled {
            // Wait for next check interval
            do {
                try await Task.sleep(for: .seconds(Self.checkInterval))
            } catch {
                // Task was cancelled
                break
            }

            // Perform check cycle
            if isRunning {
                await performCheckCycle()
            }
        }
    }

    /// Perform a single check cycle - refresh all due feeds.
    @discardableResult
    private func performCheckCycle() async -> Int {
        lastCheckDate = Date()
        totalRefreshCycles += 1

        // Check network availability
        if skipWhenOffline && !isNetworkAvailable {
            skippedCyclesForNetwork += 1
            Logger.inbox.debugCapture(
                "InboxScheduler cycle \(totalRefreshCycles): skipped (offline)",
                category: "inbox"
            )
            return 0
        }

        // Check power state (macOS only)
        #if os(macOS)
        if skipOnBattery && isOnBatteryPower() {
            skippedCyclesForPower += 1
            Logger.inbox.debugCapture(
                "InboxScheduler cycle \(totalRefreshCycles): skipped (on battery)",
                category: "inbox"
            )
            return 0
        }
        #endif

        // Fetch all inbox feeds
        let feeds = await fetchInboxFeeds()

        if feeds.isEmpty {
            Logger.inbox.debug("No Inbox feeds configured")
            return 0
        }

        // Only log to system console, not to app console (runs every minute)
        let cycleNum = totalRefreshCycles
        let feedCount = feeds.count
        Logger.inbox.debug("InboxScheduler cycle \(cycleNum): checking \(feedCount) feeds")

        // Find feeds that are due
        let dueFeeds = feeds.filter { isDue($0) }

        if dueFeeds.isEmpty {
            Logger.inbox.debug("No feeds due for refresh")
            return 0
        }

        Logger.inbox.infoCapture(
            "\(dueFeeds.count) feeds due for refresh",
            category: "inbox"
        )

        // Queue all due feeds for staggered background refresh
        // This returns immediately - refreshes happen in background via SmartSearchRefreshService
        for feed in dueFeeds {
            await SmartSearchRefreshService.shared.queueRefresh(feed, priority: .low)
            lastRefreshTimes[feed.id] = Date()
        }

        Logger.inbox.infoCapture(
            "Queued \(dueFeeds.count) feeds for staggered background refresh",
            category: "inbox"
        )

        // Return count of queued feeds (actual papers will be fetched asynchronously)
        return dueFeeds.count
    }

    /// Fetch all smart searches configured to feed the Inbox.
    private func fetchInboxFeeds() async -> [CDSmartSearch] {
        await MainActor.run {
            let request = NSFetchRequest<CDSmartSearch>(entityName: "SmartSearch")
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "feedsToInbox == YES"),
                NSPredicate(format: "autoRefreshEnabled == YES")
            ])

            do {
                return try persistenceController.viewContext.fetch(request)
            } catch {
                Logger.inbox.errorCapture(
                    "Failed to fetch Inbox feeds: \(error.localizedDescription)",
                    category: "inbox"
                )
                return []
            }
        }
    }

    /// Check if a feed is due for refresh.
    private func isDue(_ smartSearch: CDSmartSearch) -> Bool {
        // Calculate effective refresh interval (treat 0 as "use default")
        var interval = TimeInterval(smartSearch.refreshIntervalSeconds)
        if interval <= 0 {
            interval = Self.defaultRefreshInterval
        }
        let effectiveInterval = max(interval, Self.minimumRefreshInterval)

        guard let lastRefresh = lastRefreshTimes[smartSearch.id] else {
            // Never refreshed - check dateLastExecuted from Core Data
            if let lastExecuted = smartSearch.dateLastExecuted {
                return Date().timeIntervalSince(lastExecuted) >= effectiveInterval
            }
            return true  // Never executed, due immediately
        }

        return Date().timeIntervalSince(lastRefresh) >= effectiveInterval
    }

    // MARK: - Network Monitoring

    /// Start monitoring network connectivity.
    private func startNetworkMonitoring() {
        let queue = DispatchQueue(label: "com.imbib.inbox.network", qos: .utility)
        networkMonitorQueue = queue

        networkMonitor.pathUpdateHandler = { [weak self] path in
            Task { [weak self] in
                await self?.handleNetworkChange(path)
            }
        }

        networkMonitor.start(queue: queue)
        Logger.inbox.debugCapture("Network monitoring started", category: "network")
    }

    /// Stop monitoring network connectivity.
    private func stopNetworkMonitoring() {
        networkMonitor.cancel()
        networkMonitorQueue = nil
        Logger.inbox.debugCapture("Network monitoring stopped", category: "network")
    }

    /// Handle network path changes.
    private func handleNetworkChange(_ path: NWPath) {
        let wasAvailable = isNetworkAvailable
        isNetworkAvailable = path.status == .satisfied

        // Check for cellular on iOS
        #if os(iOS)
        if skipOnCellular && path.usesInterfaceType(.cellular) {
            isNetworkAvailable = false
        }
        #endif

        if wasAvailable != isNetworkAvailable {
            Logger.inbox.infoCapture(
                "Network status changed: \(isNetworkAvailable ? "available" : "unavailable")",
                category: "network"
            )
        }
    }

    // MARK: - Power State (macOS)

    #if os(macOS)
    /// Check if the Mac is running on battery power.
    private nonisolated func isOnBatteryPower() -> Bool {
        // Get power source info
        guard let powerSources = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sourcesList = IOPSCopyPowerSourcesList(powerSources)?.takeRetainedValue() as? [CFTypeRef],
              !sourcesList.isEmpty else {
            // No battery (desktop Mac) - never skip
            return false
        }

        // Check the first power source (internal battery)
        guard let source = sourcesList.first,
              let description = IOPSGetPowerSourceDescription(powerSources, source)?.takeUnretainedValue() as? [String: Any] else {
            return false
        }

        // Check if running on battery
        if let powerSource = description[kIOPSPowerSourceStateKey as String] as? String {
            return powerSource == kIOPSBatteryPowerValue as String
        }

        return false
    }
    #endif
}

// MARK: - Scheduler Statistics

/// Statistics about the Inbox scheduler.
public struct InboxSchedulerStatistics: Sendable, Equatable {
    /// Whether the scheduler is running.
    public let isRunning: Bool

    /// When the last check cycle occurred.
    public let lastCheckDate: Date?

    /// Total papers fetched since scheduler started.
    public let totalPapersFetched: Int

    /// Number of check cycles completed.
    public let totalRefreshCycles: Int

    /// Number of feeds being tracked.
    public let feedCount: Int

    /// Number of cycles skipped due to battery power.
    public let skippedCyclesForPower: Int

    /// Number of cycles skipped due to network unavailability.
    public let skippedCyclesForNetwork: Int

    /// Whether network is currently available.
    public let isNetworkAvailable: Bool
}

// MARK: - Feed Status

/// Status of a single Inbox feed.
public struct InboxFeedStatus: Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let lastRefresh: Date?
    public let nextRefresh: Date?
    public let lastFetchCount: Int
    public let refreshIntervalSeconds: Int32

    /// Whether this feed is due for refresh.
    public var isDue: Bool {
        guard let next = nextRefresh else { return true }
        return Date() >= next
    }

    /// Time until next refresh (negative if overdue).
    public var timeUntilRefresh: TimeInterval? {
        nextRefresh?.timeIntervalSinceNow
    }
}

// MARK: - Refresh Interval Presets

/// Common refresh interval presets for UI pickers.
public enum RefreshIntervalPreset: Int32, CaseIterable, Sendable {
    case oneHour = 3600             // 1 hour (minimum to avoid rate limiting)
    case threeHours = 10800         // 3 hours
    case sixHours = 21600           // 6 hours (default)
    case twelveHours = 43200        // 12 hours
    case daily = 86400              // 24 hours
    case weekly = 604800            // 7 days

    public var displayName: String {
        switch self {
        case .oneHour: return "1 hour"
        case .threeHours: return "3 hours"
        case .sixHours: return "6 hours"
        case .twelveHours: return "12 hours"
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        }
    }

    public var seconds: Int32 { rawValue }
}
