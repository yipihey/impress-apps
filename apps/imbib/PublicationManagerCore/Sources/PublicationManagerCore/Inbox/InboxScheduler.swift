//
//  InboxScheduler.swift
//  PublicationManagerCore
//
//  Schedules automatic refresh of Inbox feeds.
//

import Foundation
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

    // MARK: - Store Access

    private func withStore<T: Sendable>(_ operation: @MainActor @Sendable (RustStoreAdapter) -> T) async -> T {
        await MainActor.run { operation(RustStoreAdapter.shared) }
    }

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
        paperFetchService: PaperFetchService
    ) {
        self.paperFetchService = paperFetchService
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
    @discardableResult
    public func triggerImmediateCheck() async -> Int {
        Logger.inbox.infoCapture("Manual Inbox refresh triggered", category: "scheduler")
        return await performCheckCycle()
    }

    /// Refresh a specific feed immediately with high priority.
    @discardableResult
    public func refreshFeed(_ smartSearchID: UUID) async throws -> Int {
        let name = await withStore { $0.getSmartSearch(id: smartSearchID)?.name ?? "unknown" }
        Logger.inbox.infoCapture("Manual refresh of feed: \(name)", category: "scheduler")

        await SmartSearchRefreshService.shared.queueRefreshByID(smartSearchID, priority: .high)
        lastRefreshTimes[smartSearchID] = Date()

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
            return nil
        }
        return lastRefresh.addingTimeInterval(Self.defaultRefreshInterval)
    }

    /// Get all feeds that are due for refresh.
    public func dueFeeds() async -> [SmartSearch] {
        let feeds = await fetchInboxFeeds()
        return feeds.filter { isDue($0) }
    }

    // MARK: - Private Helpers

    /// Main scheduler loop.
    private func runSchedulerLoop() async {
        await performCheckCycle()

        while isRunning && !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(Self.checkInterval))
            } catch {
                break
            }

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

        if skipWhenOffline && !isNetworkAvailable {
            skippedCyclesForNetwork += 1
            Logger.inbox.debugCapture(
                "InboxScheduler cycle \(totalRefreshCycles): skipped (offline)",
                category: "inbox"
            )
            return 0
        }

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

        let feeds = await fetchInboxFeeds()

        if feeds.isEmpty {
            Logger.inbox.debug("No Inbox feeds configured")
            return 0
        }

        let cycleNum = totalRefreshCycles
        let feedCount = feeds.count
        Logger.inbox.debug("InboxScheduler cycle \(cycleNum): checking \(feedCount) feeds")

        let dueFeeds = feeds.filter { isDue($0) }

        if dueFeeds.isEmpty {
            Logger.inbox.debug("No feeds due for refresh")
            return 0
        }

        Logger.inbox.infoCapture(
            "\(dueFeeds.count) feeds due for refresh",
            category: "inbox"
        )

        for feed in dueFeeds {
            await SmartSearchRefreshService.shared.queueRefreshByID(feed.id, priority: .low)
            lastRefreshTimes[feed.id] = Date()
        }

        Logger.inbox.infoCapture(
            "Queued \(dueFeeds.count) feeds for staggered background refresh",
            category: "inbox"
        )

        return dueFeeds.count
    }

    /// Fetch all smart searches configured to feed the Inbox.
    private func fetchInboxFeeds() async -> [SmartSearch] {
        await withStore { store in
            let allSearches = store.listSmartSearches()
            return allSearches.filter { $0.feedsToInbox && $0.autoRefreshEnabled }
        }
    }

    /// Check if a feed is due for refresh.
    private func isDue(_ smartSearch: SmartSearch) -> Bool {
        var interval = TimeInterval(smartSearch.refreshIntervalSeconds)
        if interval <= 0 {
            interval = Self.defaultRefreshInterval
        }
        let effectiveInterval = max(interval, Self.minimumRefreshInterval)

        guard let lastRefresh = lastRefreshTimes[smartSearch.id] else {
            if let lastExecuted = smartSearch.lastExecuted {
                return Date().timeIntervalSince(lastExecuted) >= effectiveInterval
            }
            return true
        }

        return Date().timeIntervalSince(lastRefresh) >= effectiveInterval
    }

    // MARK: - Network Monitoring

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

    private func stopNetworkMonitoring() {
        networkMonitor.cancel()
        networkMonitorQueue = nil
        Logger.inbox.debugCapture("Network monitoring stopped", category: "network")
    }

    private func handleNetworkChange(_ path: NWPath) {
        let wasAvailable = isNetworkAvailable
        isNetworkAvailable = path.status == .satisfied

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
    private nonisolated func isOnBatteryPower() -> Bool {
        guard let powerSources = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sourcesList = IOPSCopyPowerSourcesList(powerSources)?.takeRetainedValue() as? [CFTypeRef],
              !sourcesList.isEmpty else {
            return false
        }

        guard let source = sourcesList.first,
              let description = IOPSGetPowerSourceDescription(powerSources, source)?.takeUnretainedValue() as? [String: Any] else {
            return false
        }

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
    public let isRunning: Bool
    public let lastCheckDate: Date?
    public let totalPapersFetched: Int
    public let totalRefreshCycles: Int
    public let feedCount: Int
    public let skippedCyclesForPower: Int
    public let skippedCyclesForNetwork: Int
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
    public let refreshIntervalSeconds: Int

    public var isDue: Bool {
        guard let next = nextRefresh else { return true }
        return Date() >= next
    }

    public var timeUntilRefresh: TimeInterval? {
        nextRefresh?.timeIntervalSinceNow
    }
}

// MARK: - Refresh Interval Presets

/// Common refresh interval presets for UI pickers.
public enum RefreshIntervalPreset: Int32, CaseIterable, Sendable {
    case oneHour = 3600
    case threeHours = 10800
    case sixHours = 21600
    case twelveHours = 43200
    case daily = 86400
    case weekly = 604800

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
