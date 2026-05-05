//
//  FeedScheduler.swift
//  PublicationManagerCore
//
//  Generalized feed scheduler — refreshes all auto-refresh smart search collections,
//  not just those that feed to Inbox. Replaces the Inbox-specific scheduling logic
//  while preserving the same startup delay and check interval behavior.
//

import Foundation
import ImpressStoreKit
import OSLog
import Network
#if os(macOS)
import IOKit.ps
#endif

// MARK: - Feed Scheduler

/// Schedules automatic refresh of all smart search collections with auto-refresh enabled.
///
/// This generalizes `InboxScheduler` to support per-library smart search collections.
/// All smart searches with `autoRefreshEnabled == true` are eligible, regardless of
/// whether `feedsToInbox` is set. The scheduler:
/// - Tracks all smart searches with `autoRefreshEnabled`
/// - Respects per-feed `refreshIntervalSeconds`
/// - Uses PaperFetchService to execute searches and route results
/// - Respects the 90-second startup delay to avoid render loops
public actor FeedScheduler {

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

    /// Start the feed scheduler.
    public func start() {
        guard !isRunning else {
            Logger.inbox.debug("FeedScheduler already running")
            return
        }

        isRunning = true

        // Start network monitoring
        startNetworkMonitoring()

        Logger.inbox.infoCapture(
            "FeedScheduler started (check interval: \(Int(Self.checkInterval))s, skipOnBattery: \(skipOnBattery), skipWhenOffline: \(skipWhenOffline))",
            category: "feed-scheduler"
        )

        schedulerTask = Task {
            await runSchedulerLoop()
        }
    }

    /// Stop the feed scheduler.
    public func stop() {
        guard isRunning else { return }

        isRunning = false
        schedulerTask?.cancel()
        schedulerTask = nil

        // Stop network monitoring
        stopNetworkMonitoring()

        Logger.inbox.infoCapture(
            "FeedScheduler stopped (total papers: \(totalPapersFetched), cycles: \(totalRefreshCycles), skipped: \(skippedCyclesForPower) power, \(skippedCyclesForNetwork) network)",
            category: "feed-scheduler"
        )
    }

    /// Trigger an immediate refresh of all due feeds.
    @discardableResult
    public func triggerImmediateCheck() async -> Int {
        Logger.inbox.infoCapture("Manual feed refresh triggered", category: "feed-scheduler")
        return await performCheckCycle()
    }

    /// Refresh a specific feed immediately with high priority.
    @discardableResult
    public func refreshFeed(_ smartSearchID: UUID) async throws -> Int {
        let name = await withStore { $0.getSmartSearch(id: smartSearchID)?.name ?? "unknown" }
        Logger.inbox.infoCapture("Manual refresh of feed: \(name)", category: "feed-scheduler")

        do {
            let count = try await paperFetchService.fetchForFeed(smartSearchID: smartSearchID)
            lastRefreshTimes[smartSearchID] = Date()
            return count
        } catch {
            Logger.inbox.errorCapture("Failed to refresh feed \(smartSearchID): \(error.localizedDescription)", category: "feed-scheduler")
            lastRefreshTimes[smartSearchID] = Date()
            return 0
        }
    }

    // MARK: - Status

    /// Whether the scheduler is running.
    public var running: Bool { isRunning }

    /// Get scheduler statistics.
    public var statistics: FeedSchedulerStatistics {
        FeedSchedulerStatistics(
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
        let feeds = await fetchAutoRefreshFeeds()
        return feeds.filter { isDue($0) }
    }

    // MARK: - Private Helpers

    /// Main scheduler loop.
    private func runSchedulerLoop() async {
        // CRITICAL: Delay first check cycle to avoid contending with startup data loading.
        // See CLAUDE.md "Startup Render Loop Prevention" — background services that mutate
        // data during first 90s cause perpetual SwiftUI body re-evaluation.
        do {
            try await Task.sleep(for: .seconds(90))
        } catch {
            return
        }
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
                "FeedScheduler cycle \(totalRefreshCycles): skipped (offline)",
                category: "feed-scheduler"
            )
            return 0
        }

        #if os(macOS)
        if skipOnBattery && isOnBatteryPower() {
            skippedCyclesForPower += 1
            Logger.inbox.debugCapture(
                "FeedScheduler cycle \(totalRefreshCycles): skipped (on battery)",
                category: "feed-scheduler"
            )
            return 0
        }
        #endif

        let feeds = await fetchAutoRefreshFeeds()

        if feeds.isEmpty {
            Logger.inbox.debug("No auto-refresh feeds configured")
            return 0
        }

        let cycleNum = totalRefreshCycles
        let feedCount = feeds.count
        Logger.inbox.debug("FeedScheduler cycle \(cycleNum): checking \(feedCount) feeds")

        let dueFeeds = feeds.filter { isDue($0) }

        if dueFeeds.isEmpty {
            Logger.inbox.debug("No feeds due for refresh")
            return 0
        }

        Logger.inbox.infoCapture(
            "\(dueFeeds.count) feeds due for refresh",
            category: "feed-scheduler"
        )

        var totalFetched = 0
        for feed in dueFeeds {
            do {
                // Route through BackgroundOperationQueue at .background
                // priority so scheduled refreshes are deduped against
                // any user-initiated manual refresh of the same feed,
                // enforce the 90s startup grace, and show up in the
                // operation overlay. If the queue refuses or dedupes,
                // the `AwaitResult` returns .deduped/.refusedStartupGrace
                // with no count.
                let feedID = feed.id
                let feedName = feed.name
                let fetchService = self.paperFetchService
                let result: AwaitResult<Int> = try await BackgroundOperationQueue.shared.submitAndAwait(
                    kind: .network,
                    priority: .background,
                    dedupeKey: "feed-refresh-\(feedID.uuidString)",
                    label: "ScheduledFeedRefresh[\(feedName)]"
                ) { _ in
                    try await fetchService.fetchForFeed(smartSearchID: feedID)
                }
                if case .completed(let count) = result {
                    totalFetched += count
                }
            } catch {
                Logger.inbox.errorCapture("Failed to refresh feed '\(feed.name)': \(error.localizedDescription)", category: "feed-scheduler")
            }
            lastRefreshTimes[feed.id] = Date()
        }

        Logger.inbox.infoCapture(
            "Refreshed \(dueFeeds.count) feeds, fetched \(totalFetched) papers",
            category: "feed-scheduler"
        )

        return dueFeeds.count
    }

    /// Fetch all smart searches with auto-refresh enabled.
    ///
    /// Handles both inbox feeds (`feedsToInbox == true`) and library feeds.
    /// PaperFetchService.fetchForFeed() routes papers appropriately based on
    /// each feed's configuration.
    private func fetchAutoRefreshFeeds() async -> [SmartSearch] {
        await withStore { store in
            let allSearches = store.listSmartSearches()
            return allSearches.filter { $0.autoRefreshEnabled }
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
        let queue = DispatchQueue(label: "com.imbib.feed.network", qos: .utility)
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

// MARK: - Feed Scheduler Statistics

/// Statistics about the feed scheduler.
public struct FeedSchedulerStatistics: Sendable, Equatable {
    public let isRunning: Bool
    public let lastCheckDate: Date?
    public let totalPapersFetched: Int
    public let totalRefreshCycles: Int
    public let feedCount: Int
    public let skippedCyclesForPower: Int
    public let skippedCyclesForNetwork: Int
    public let isNetworkAvailable: Bool
}
