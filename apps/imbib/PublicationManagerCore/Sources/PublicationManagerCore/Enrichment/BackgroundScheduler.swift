//
//  BackgroundScheduler.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import Foundation
import OSLog

// MARK: - Stale Publication Provider Protocol

/// Protocol for providing stale publications that need enrichment.
///
/// This abstraction allows the scheduler to work with any data source
/// (Core Data, mock data for tests, etc.)
public protocol StalePublicationProvider: Sendable {
    /// Find publications with stale or missing enrichment data.
    ///
    /// - Parameters:
    ///   - olderThan: Enrichment date threshold (nil = never enriched)
    ///   - limit: Maximum number of publications to return
    /// - Returns: Array of tuples containing publication ID and identifiers
    func findStalePublications(
        olderThan date: Date,
        limit: Int
    ) async -> [(id: UUID, identifiers: [IdentifierType: String])]

    /// Count of publications that have never been enriched.
    func countNeverEnriched() async -> Int

    /// Count of publications with stale enrichment.
    func countStale(olderThan date: Date) async -> Int
}

// MARK: - Background Scheduler

/// Schedules and manages periodic background enrichment of library publications.
///
/// The scheduler periodically checks for publications with stale or missing
/// enrichment data and queues them for background processing.
///
/// ## Features
/// - Configurable check interval (default: 1 hour)
/// - Configurable items per cycle (default: 50)
/// - Respects user's auto-sync preference
/// - Staleness based on enrichment date
///
/// ## Usage
///
/// ```swift
/// let scheduler = BackgroundScheduler(
///     enrichmentService: service,
///     publicationProvider: provider,
///     settingsProvider: settings
/// )
///
/// // Start scheduling
/// await scheduler.start()
///
/// // Check status
/// let stats = await scheduler.statistics
///
/// // Stop scheduling
/// await scheduler.stop()
/// ```
public actor BackgroundScheduler {

    // MARK: - Configuration

    /// Default check interval (1 hour)
    public static let defaultCheckInterval: TimeInterval = 3600

    /// Default maximum items per check cycle
    public static let defaultItemsPerCycle = 50

    // MARK: - Dependencies

    private let enrichmentService: EnrichmentService
    private let publicationProvider: StalePublicationProvider
    private let settingsProvider: EnrichmentSettingsProvider

    // MARK: - Configuration Properties

    private let checkInterval: TimeInterval
    private let itemsPerCycle: Int

    // MARK: - State

    private var isRunning = false
    private var schedulerTask: Task<Void, Never>?
    private var lastCheckDate: Date?
    private var totalItemsQueued: Int = 0
    private var cycleCount: Int = 0

    // MARK: - Initialization

    /// Create a background scheduler.
    ///
    /// - Parameters:
    ///   - enrichmentService: Service to queue enrichment requests
    ///   - publicationProvider: Provider for finding stale publications
    ///   - settingsProvider: User settings for enrichment preferences
    ///   - checkInterval: How often to check for stale publications (default: 1 hour)
    ///   - itemsPerCycle: Maximum items to queue per check (default: 50)
    public init(
        enrichmentService: EnrichmentService,
        publicationProvider: StalePublicationProvider,
        settingsProvider: EnrichmentSettingsProvider = DefaultEnrichmentSettingsProvider(),
        checkInterval: TimeInterval = defaultCheckInterval,
        itemsPerCycle: Int = defaultItemsPerCycle
    ) {
        self.enrichmentService = enrichmentService
        self.publicationProvider = publicationProvider
        self.settingsProvider = settingsProvider
        self.checkInterval = checkInterval
        self.itemsPerCycle = itemsPerCycle
    }

    // MARK: - Control

    /// Start the background scheduler.
    ///
    /// The scheduler will periodically check for stale publications
    /// and queue them for enrichment.
    public func start() {
        guard !isRunning else {
            Logger.enrichment.debug("Scheduler already running")
            return
        }

        isRunning = true
        let intervalMinutes = Int(checkInterval / 60)
        Logger.enrichment.infoCapture(
            "Background scheduler started (interval: \(intervalMinutes)min, batch: \(itemsPerCycle))",
            category: "enrichment"
        )

        schedulerTask = Task {
            await runSchedulerLoop()
        }
    }

    /// Stop the background scheduler.
    public func stop() {
        guard isRunning else { return }

        isRunning = false
        schedulerTask?.cancel()
        schedulerTask = nil
        Logger.enrichment.infoCapture(
            "Background scheduler stopped (total queued: \(totalItemsQueued), cycles: \(cycleCount))",
            category: "enrichment"
        )
    }

    /// Trigger an immediate check cycle (useful for testing or manual refresh).
    ///
    /// - Returns: Number of publications queued
    @discardableResult
    public func triggerImmediateCheck() async -> Int {
        Logger.enrichment.infoCapture("Manual enrichment check triggered", category: "enrichment")
        return await performCheckCycle()
    }

    // MARK: - Status

    /// Whether the scheduler is currently running.
    public var running: Bool {
        isRunning
    }

    /// Statistics about scheduler activity.
    public var statistics: SchedulerStatistics {
        SchedulerStatistics(
            isRunning: isRunning,
            lastCheckDate: lastCheckDate,
            totalItemsQueued: totalItemsQueued,
            cycleCount: cycleCount,
            checkInterval: checkInterval,
            itemsPerCycle: itemsPerCycle
        )
    }

    /// Get counts of publications needing enrichment.
    public func enrichmentNeeds() async -> EnrichmentNeeds {
        let refreshDays = await settingsProvider.refreshIntervalDays
        let staleDate = Calendar.current.date(
            byAdding: .day,
            value: -refreshDays,
            to: Date()
        ) ?? Date()

        let neverEnriched = await publicationProvider.countNeverEnriched()
        let stale = await publicationProvider.countStale(olderThan: staleDate)

        return EnrichmentNeeds(
            neverEnriched: neverEnriched,
            stale: stale,
            total: neverEnriched + stale
        )
    }

    // MARK: - Private Helpers

    /// Main scheduler loop.
    private func runSchedulerLoop() async {
        while isRunning && !Task.isCancelled {
            // Check if auto-sync is enabled
            let autoSyncEnabled = await settingsProvider.autoSyncEnabled
            if autoSyncEnabled {
                await performCheckCycle()
            } else {
                Logger.enrichment.debug("BackgroundScheduler: auto-sync disabled, skipping cycle")
            }

            // Wait for next check interval
            do {
                try await Task.sleep(for: .seconds(checkInterval))
            } catch {
                // Task was cancelled
                break
            }
        }
    }

    /// Perform a single check cycle.
    ///
    /// - Returns: Number of publications queued
    @discardableResult
    private func performCheckCycle() async -> Int {
        cycleCount += 1
        lastCheckDate = Date()

        let refreshDays = await settingsProvider.refreshIntervalDays
        let staleDate = Calendar.current.date(
            byAdding: .day,
            value: -refreshDays,
            to: Date()
        ) ?? Date()

        Logger.enrichment.infoCapture(
            "Scheduler cycle \(cycleCount): checking for stale publications (older than \(refreshDays) days)",
            category: "enrichment"
        )

        // Find stale publications
        let stalePublications = await publicationProvider.findStalePublications(
            olderThan: staleDate,
            limit: itemsPerCycle
        )

        if stalePublications.isEmpty {
            Logger.enrichment.debug("No stale publications found")
            return 0
        }

        Logger.enrichment.infoCapture(
            "Found \(stalePublications.count) stale publications",
            category: "enrichment"
        )

        // Queue each for enrichment
        for (pubID, identifiers) in stalePublications {
            await enrichmentService.queueForEnrichment(
                publicationID: pubID,
                identifiers: identifiers,
                priority: .backgroundSync
            )
        }

        totalItemsQueued += stalePublications.count
        Logger.enrichment.infoCapture(
            "Queued \(stalePublications.count) publications for background enrichment",
            category: "enrichment"
        )

        return stalePublications.count
    }
}

// MARK: - Scheduler Statistics

/// Statistics about background scheduler activity.
public struct SchedulerStatistics: Sendable, Equatable {
    /// Whether the scheduler is currently running.
    public let isRunning: Bool

    /// When the last check cycle occurred.
    public let lastCheckDate: Date?

    /// Total number of items queued since scheduler started.
    public let totalItemsQueued: Int

    /// Number of check cycles completed.
    public let cycleCount: Int

    /// Configured check interval in seconds.
    public let checkInterval: TimeInterval

    /// Maximum items queued per cycle.
    public let itemsPerCycle: Int

    /// Time until next check (nil if not running or no previous check).
    public var timeUntilNextCheck: TimeInterval? {
        guard isRunning, let lastCheck = lastCheckDate else { return nil }
        let nextCheck = lastCheck.addingTimeInterval(checkInterval)
        return max(0, nextCheck.timeIntervalSinceNow)
    }
}

// MARK: - Enrichment Needs

/// Summary of publications needing enrichment.
public struct EnrichmentNeeds: Sendable, Equatable {
    /// Publications that have never been enriched.
    public let neverEnriched: Int

    /// Publications with stale enrichment data.
    public let stale: Int

    /// Total publications needing enrichment.
    public let total: Int
}

// MARK: - Mock Publication Provider

/// Mock implementation for testing.
public actor MockStalePublicationProvider: StalePublicationProvider {
    private var publications: [(id: UUID, identifiers: [IdentifierType: String], enrichmentDate: Date?)] = []

    public init() {}

    /// Add a publication for testing.
    public func addPublication(
        id: UUID = UUID(),
        identifiers: [IdentifierType: String] = [:],
        enrichmentDate: Date? = nil
    ) {
        publications.append((id: id, identifiers: identifiers, enrichmentDate: enrichmentDate))
    }

    /// Clear all publications.
    public func clear() {
        publications.removeAll()
    }

    public func findStalePublications(
        olderThan date: Date,
        limit: Int
    ) async -> [(id: UUID, identifiers: [IdentifierType: String])] {
        publications
            .filter { pub in
                guard let enrichmentDate = pub.enrichmentDate else {
                    return true  // Never enriched
                }
                return enrichmentDate < date  // Stale
            }
            .prefix(limit)
            .map { (id: $0.id, identifiers: $0.identifiers) }
    }

    public func countNeverEnriched() async -> Int {
        publications.filter { $0.enrichmentDate == nil }.count
    }

    public func countStale(olderThan date: Date) async -> Int {
        publications.filter { pub in
            guard let enrichmentDate = pub.enrichmentDate else { return false }
            return enrichmentDate < date
        }.count
    }
}
