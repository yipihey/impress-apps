//
//  InboxSchedulerTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-06.
//

import XCTest
import CoreData
@testable import PublicationManagerCore

final class InboxSchedulerTests: XCTestCase {

    // MARK: - Properties

    private var persistenceController: PersistenceController!
    private var sourceManager: SourceManager!
    private var repository: PublicationRepository!
    private var fetchService: PaperFetchService!
    private var scheduler: InboxScheduler!

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()
        persistenceController = .preview

        // Create real services (no network calls will happen without enabled feeds)
        sourceManager = SourceManager(credentialManager: CredentialManager.shared)
        repository = PublicationRepository()
        fetchService = PaperFetchService(
            sourceManager: sourceManager,
            repository: repository,
            persistenceController: persistenceController
        )
        scheduler = InboxScheduler(
            paperFetchService: fetchService,
            persistenceController: persistenceController
        )
    }

    override func tearDown() async throws {
        await scheduler.stop()

        // Clean up entities
        await MainActor.run {
            let context = persistenceController.viewContext

            let ssRequest = NSFetchRequest<CDSmartSearch>(entityName: "SmartSearch")
            let sses = try? context.fetch(ssRequest)
            sses?.forEach { context.delete($0) }

            let libRequest = NSFetchRequest<CDLibrary>(entityName: "Library")
            let libs = try? context.fetch(libRequest)
            libs?.forEach { context.delete($0) }

            try? context.save()
        }

        scheduler = nil
        fetchService = nil
        repository = nil
        sourceManager = nil
        try await super.tearDown()
    }

    // MARK: - Lifecycle Tests

    func testStart_setsRunningToTrue() async {
        // Given
        let running = await scheduler.running
        XCTAssertFalse(running)

        // When
        await scheduler.start()

        // Then
        let runningAfter = await scheduler.running
        XCTAssertTrue(runningAfter)
    }

    func testStart_alreadyRunning_doesNotRestartLoop() async {
        // Given
        await scheduler.start()

        // When - start again (should be no-op)
        await scheduler.start()

        // Then - should still be running
        let running = await scheduler.running
        XCTAssertTrue(running)
    }

    func testStop_setsRunningToFalse() async {
        // Given
        await scheduler.start()
        let runningBefore = await scheduler.running
        XCTAssertTrue(runningBefore)

        // When
        await scheduler.stop()

        // Then
        let runningAfter = await scheduler.running
        XCTAssertFalse(runningAfter)
    }

    func testStop_whenNotRunning_doesNothing() async {
        // Given
        let running = await scheduler.running
        XCTAssertFalse(running)

        // When
        await scheduler.stop()

        // Then - still not running, no crash
        let runningAfter = await scheduler.running
        XCTAssertFalse(runningAfter)
    }

    // MARK: - Statistics Tests

    func testStatistics_initialValues() async {
        // When
        let stats = await scheduler.statistics

        // Then
        XCTAssertFalse(stats.isRunning)
        XCTAssertNil(stats.lastCheckDate)
        XCTAssertEqual(stats.totalPapersFetched, 0)
        XCTAssertEqual(stats.totalRefreshCycles, 0)
        XCTAssertEqual(stats.skippedCyclesForPower, 0)
        XCTAssertEqual(stats.skippedCyclesForNetwork, 0)
    }

    func testStatistics_afterStart_showsRunning() async {
        // When
        await scheduler.start()
        // Give it a moment to complete initial cycle
        try? await Task.sleep(for: .milliseconds(100))

        let stats = await scheduler.statistics

        // Then
        XCTAssertTrue(stats.isRunning)
        XCTAssertNotNil(stats.lastCheckDate)
        XCTAssertGreaterThanOrEqual(stats.totalRefreshCycles, 1)
    }

    func testStatistics_equatable() async {
        // Given
        let stats1 = InboxSchedulerStatistics(
            isRunning: true,
            lastCheckDate: Date(),
            totalPapersFetched: 10,
            totalRefreshCycles: 5,
            feedCount: 3,
            skippedCyclesForPower: 1,
            skippedCyclesForNetwork: 2,
            isNetworkAvailable: true
        )

        let stats2 = InboxSchedulerStatistics(
            isRunning: true,
            lastCheckDate: stats1.lastCheckDate,
            totalPapersFetched: 10,
            totalRefreshCycles: 5,
            feedCount: 3,
            skippedCyclesForPower: 1,
            skippedCyclesForNetwork: 2,
            isNetworkAvailable: true
        )

        // Then
        XCTAssertEqual(stats1, stats2)
    }

    // MARK: - Due Checking Tests

    func testNextRefreshTime_neverRefreshed_returnsNil() async {
        // Given
        let randomID = UUID()

        // When
        let nextTime = await scheduler.nextRefreshTime(for: randomID)

        // Then - nil means due immediately
        XCTAssertNil(nextTime)
    }

    func testDueFeeds_noFeeds_returnsEmpty() async {
        // When
        let due = await scheduler.dueFeeds()

        // Then
        XCTAssertTrue(due.isEmpty)
    }

    func testDueFeeds_withDueFeed_returnsFeed() async {
        // Given
        await MainActor.run {
            let lib = createTestLibrary(name: "Test Library")
            let ss = createTestSmartSearch(
                name: "Due Feed",
                query: "test",
                library: lib,
                feedsToInbox: true,
                autoRefresh: true
            )
            ss.dateLastExecuted = Date.distantPast  // Way overdue
            persistenceController.save()
        }

        // When
        let due = await scheduler.dueFeeds()

        // Then
        XCTAssertEqual(due.count, 1)
        XCTAssertEqual(due.first?.name, "Due Feed")
    }

    func testDueFeeds_recentlyRefreshed_notIncluded() async {
        // Given
        await MainActor.run {
            let lib = createTestLibrary(name: "Test Library")
            let ss = createTestSmartSearch(
                name: "Recent Feed",
                query: "test",
                library: lib,
                feedsToInbox: true,
                autoRefresh: true
            )
            ss.dateLastExecuted = Date()  // Just now
            ss.refreshIntervalSeconds = 3600  // 1 hour
            persistenceController.save()
        }

        // When
        let due = await scheduler.dueFeeds()

        // Then - recently executed, not due yet
        XCTAssertTrue(due.isEmpty)
    }

    func testDueFeeds_feedsToInboxDisabled_notIncluded() async {
        // Given
        await MainActor.run {
            let lib = createTestLibrary(name: "Test Library")
            _ = createTestSmartSearch(
                name: "Non-Inbox Feed",
                query: "test",
                library: lib,
                feedsToInbox: false,  // Does not feed to inbox
                autoRefresh: true
            )
            persistenceController.save()
        }

        // When
        let due = await scheduler.dueFeeds()

        // Then - not feeding to inbox, not included
        XCTAssertTrue(due.isEmpty)
    }

    func testDueFeeds_autoRefreshDisabled_notIncluded() async {
        // Given
        await MainActor.run {
            let lib = createTestLibrary(name: "Test Library")
            _ = createTestSmartSearch(
                name: "Manual Feed",
                query: "test",
                library: lib,
                feedsToInbox: true,
                autoRefresh: false  // No auto-refresh
            )
            persistenceController.save()
        }

        // When
        let due = await scheduler.dueFeeds()

        // Then - auto-refresh disabled, not included
        XCTAssertTrue(due.isEmpty)
    }

    // MARK: - Manual Trigger Tests

    func testTriggerImmediateCheck_performsCheckCycle() async {
        // Given
        let statsBefore = await scheduler.statistics
        XCTAssertEqual(statsBefore.totalRefreshCycles, 0)

        // When
        let _ = await scheduler.triggerImmediateCheck()

        // Then
        let statsAfter = await scheduler.statistics
        XCTAssertEqual(statsAfter.totalRefreshCycles, 1)
    }

    func testTriggerImmediateCheck_multipleCallsIncrementCycles() async {
        // Given
        _ = await scheduler.triggerImmediateCheck()
        let stats1 = await scheduler.statistics
        XCTAssertEqual(stats1.totalRefreshCycles, 1)

        // When
        _ = await scheduler.triggerImmediateCheck()

        // Then
        let stats2 = await scheduler.statistics
        XCTAssertEqual(stats2.totalRefreshCycles, 2)
    }

    // MARK: - Refresh Interval Presets Tests

    func testRefreshIntervalPreset_values() {
        XCTAssertEqual(RefreshIntervalPreset.oneHour.seconds, 3600)
        XCTAssertEqual(RefreshIntervalPreset.threeHours.seconds, 10800)
        XCTAssertEqual(RefreshIntervalPreset.sixHours.seconds, 21600)
        XCTAssertEqual(RefreshIntervalPreset.twelveHours.seconds, 43200)
        XCTAssertEqual(RefreshIntervalPreset.daily.seconds, 86400)
        XCTAssertEqual(RefreshIntervalPreset.weekly.seconds, 604800)
    }

    func testRefreshIntervalPreset_displayNames() {
        XCTAssertEqual(RefreshIntervalPreset.oneHour.displayName, "1 hour")
        XCTAssertEqual(RefreshIntervalPreset.threeHours.displayName, "3 hours")
        XCTAssertEqual(RefreshIntervalPreset.sixHours.displayName, "6 hours")
        XCTAssertEqual(RefreshIntervalPreset.twelveHours.displayName, "12 hours")
        XCTAssertEqual(RefreshIntervalPreset.daily.displayName, "Daily")
        XCTAssertEqual(RefreshIntervalPreset.weekly.displayName, "Weekly")
    }

    func testRefreshIntervalPreset_allCases() {
        // Verify all cases are defined
        XCTAssertEqual(RefreshIntervalPreset.allCases.count, 6)
    }

    // MARK: - InboxFeedStatus Tests

    func testInboxFeedStatus_isDue_whenNoNextRefresh() {
        let status = InboxFeedStatus(
            id: UUID(),
            name: "Test",
            lastRefresh: nil,
            nextRefresh: nil,
            lastFetchCount: 0,
            refreshIntervalSeconds: 3600
        )

        XCTAssertTrue(status.isDue)
    }

    func testInboxFeedStatus_isDue_whenPastNextRefresh() {
        let status = InboxFeedStatus(
            id: UUID(),
            name: "Test",
            lastRefresh: Date.distantPast,
            nextRefresh: Date.distantPast,
            lastFetchCount: 0,
            refreshIntervalSeconds: 3600
        )

        XCTAssertTrue(status.isDue)
    }

    func testInboxFeedStatus_notDue_whenFutureNextRefresh() {
        let status = InboxFeedStatus(
            id: UUID(),
            name: "Test",
            lastRefresh: Date(),
            nextRefresh: Date.distantFuture,
            lastFetchCount: 0,
            refreshIntervalSeconds: 3600
        )

        XCTAssertFalse(status.isDue)
    }

    func testInboxFeedStatus_timeUntilRefresh() {
        let futureDate = Date().addingTimeInterval(3600)
        let status = InboxFeedStatus(
            id: UUID(),
            name: "Test",
            lastRefresh: Date(),
            nextRefresh: futureDate,
            lastFetchCount: 0,
            refreshIntervalSeconds: 3600
        )

        XCTAssertNotNil(status.timeUntilRefresh)
        XCTAssertGreaterThan(status.timeUntilRefresh!, 0)
    }

    // MARK: - Configuration Tests

    func testSchedulerConfiguration_checkInterval() {
        XCTAssertEqual(InboxScheduler.checkInterval, 60)  // 1 minute
    }

    func testSchedulerConfiguration_defaultRefreshInterval() {
        XCTAssertEqual(InboxScheduler.defaultRefreshInterval, 24 * 60 * 60)  // Daily
    }

    func testSchedulerConfiguration_minimumRefreshInterval() {
        XCTAssertEqual(InboxScheduler.minimumRefreshInterval, 15 * 60)  // 15 minutes
    }

    // MARK: - Helpers

    @MainActor
    private func createTestLibrary(name: String) -> CDLibrary {
        let context = persistenceController.viewContext
        let lib = CDLibrary(context: context)
        lib.id = UUID()
        lib.name = name
        lib.isInbox = false
        lib.isDefault = false
        lib.dateCreated = Date()
        lib.sortOrder = 0
        return lib
    }

    @MainActor
    private func createTestSmartSearch(
        name: String,
        query: String,
        library: CDLibrary,
        feedsToInbox: Bool,
        autoRefresh: Bool
    ) -> CDSmartSearch {
        let context = persistenceController.viewContext
        let ss = CDSmartSearch(context: context)
        ss.id = UUID()
        ss.name = name
        ss.query = query
        ss.library = library
        ss.feedsToInbox = feedsToInbox
        ss.autoRefreshEnabled = autoRefresh
        ss.refreshIntervalSeconds = Int32(InboxScheduler.defaultRefreshInterval)
        ss.maxResults = 50
        ss.order = 0
        ss.dateCreated = Date()
        return ss
    }
}
