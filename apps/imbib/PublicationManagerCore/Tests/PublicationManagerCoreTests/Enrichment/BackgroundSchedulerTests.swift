//
//  BackgroundSchedulerTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-04.
//

import XCTest
@testable import PublicationManagerCore

final class BackgroundSchedulerTests: XCTestCase {

    var enrichmentService: EnrichmentService!
    var publicationProvider: MockStalePublicationProvider!
    var settingsProvider: MockEnrichmentSettingsProvider!
    var scheduler: BackgroundScheduler!

    override func setUp() async throws {
        try await super.setUp()

        // Create mock enrichment service with no plugins (we just need the queue)
        enrichmentService = EnrichmentService(plugins: [])
        publicationProvider = MockStalePublicationProvider()
        settingsProvider = MockEnrichmentSettingsProvider()

        scheduler = BackgroundScheduler(
            enrichmentService: enrichmentService,
            publicationProvider: publicationProvider,
            settingsProvider: settingsProvider,
            checkInterval: 0.1,  // Fast interval for testing
            itemsPerCycle: 10
        )
    }

    override func tearDown() async throws {
        await scheduler.stop()
        try await super.tearDown()
    }

    // MARK: - Start/Stop Tests

    func testStartSetsRunningTrue() async {
        var isRunning = await scheduler.running
        XCTAssertFalse(isRunning)

        await scheduler.start()

        isRunning = await scheduler.running
        XCTAssertTrue(isRunning)
    }

    func testStopSetsRunningFalse() async {
        await scheduler.start()
        var isRunning = await scheduler.running
        XCTAssertTrue(isRunning)

        await scheduler.stop()

        isRunning = await scheduler.running
        XCTAssertFalse(isRunning)
    }

    func testDoubleStartIsNoOp() async {
        await scheduler.start()
        await scheduler.start()  // Should not throw or cause issues

        let isRunning = await scheduler.running
        XCTAssertTrue(isRunning)
    }

    func testDoubleStopIsNoOp() async {
        await scheduler.start()
        await scheduler.stop()
        await scheduler.stop()  // Should not throw

        let isRunning = await scheduler.running
        XCTAssertFalse(isRunning)
    }

    // MARK: - Immediate Check Tests

    func testTriggerImmediateCheckWithNoPublications() async {
        let count = await scheduler.triggerImmediateCheck()

        XCTAssertEqual(count, 0)
    }

    func testTriggerImmediateCheckWithStalePublications() async {
        // Add some never-enriched publications
        await publicationProvider.addPublication(
            id: UUID(),
            identifiers: [.doi: "10.1234/test1"]
        )
        await publicationProvider.addPublication(
            id: UUID(),
            identifiers: [.doi: "10.1234/test2"]
        )

        let count = await scheduler.triggerImmediateCheck()

        XCTAssertEqual(count, 2)
    }

    func testTriggerImmediateCheckRespectsItemLimit() async {
        // Add more publications than the limit
        for i in 0..<20 {
            await publicationProvider.addPublication(
                id: UUID(),
                identifiers: [.doi: "10.1234/test\(i)"]
            )
        }

        let count = await scheduler.triggerImmediateCheck()

        XCTAssertEqual(count, 10)  // itemsPerCycle = 10
    }

    func testTriggerImmediateCheckQueuesPublications() async {
        let pubID = UUID()
        await publicationProvider.addPublication(
            id: pubID,
            identifiers: [.doi: "10.1234/test"]
        )

        await scheduler.triggerImmediateCheck()

        let queueDepth = await enrichmentService.queueDepth()
        XCTAssertEqual(queueDepth, 1)
    }

    // MARK: - Staleness Tests

    func testNeverEnrichedPublicationsAreStale() async {
        await publicationProvider.addPublication(
            id: UUID(),
            identifiers: [.doi: "10.1234/never-enriched"],
            enrichmentDate: nil
        )

        let count = await scheduler.triggerImmediateCheck()

        XCTAssertEqual(count, 1)
    }

    func testRecentlyEnrichedPublicationsAreNotStale() async {
        await publicationProvider.addPublication(
            id: UUID(),
            identifiers: [.doi: "10.1234/recent"],
            enrichmentDate: Date()  // Just now
        )

        let count = await scheduler.triggerImmediateCheck()

        XCTAssertEqual(count, 0)
    }

    func testOldEnrichedPublicationsAreStale() async {
        let oldDate = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        await publicationProvider.addPublication(
            id: UUID(),
            identifiers: [.doi: "10.1234/old"],
            enrichmentDate: oldDate
        )

        let count = await scheduler.triggerImmediateCheck()

        XCTAssertEqual(count, 1)
    }

    // MARK: - Settings Tests

    func testAutoSyncDisabledSkipsCycle() async {
        await settingsProvider.setAutoSyncEnabled(false)
        await publicationProvider.addPublication(
            id: UUID(),
            identifiers: [.doi: "10.1234/test"]
        )

        // Start scheduler and let it run briefly
        await scheduler.start()
        try? await Task.sleep(for: .milliseconds(150))
        await scheduler.stop()

        // Queue should be empty because auto-sync is disabled
        let queueDepth = await enrichmentService.queueDepth()
        XCTAssertEqual(queueDepth, 0)
    }

    func testCustomRefreshIntervalIsUsed() async {
        await settingsProvider.setRefreshIntervalDays(1)  // 1 day

        // Add publication enriched 2 days ago (should be stale)
        let twoDaysAgo = Calendar.current.date(byAdding: .day, value: -2, to: Date())!
        await publicationProvider.addPublication(
            id: UUID(),
            identifiers: [.doi: "10.1234/test"],
            enrichmentDate: twoDaysAgo
        )

        let count = await scheduler.triggerImmediateCheck()

        XCTAssertEqual(count, 1)
    }

    // MARK: - Statistics Tests

    func testInitialStatistics() async {
        let stats = await scheduler.statistics

        XCTAssertFalse(stats.isRunning)
        XCTAssertNil(stats.lastCheckDate)
        XCTAssertEqual(stats.totalItemsQueued, 0)
        XCTAssertEqual(stats.cycleCount, 0)
    }

    func testStatisticsAfterCheck() async {
        await publicationProvider.addPublication(
            id: UUID(),
            identifiers: [.doi: "10.1234/test"]
        )

        await scheduler.triggerImmediateCheck()

        let stats = await scheduler.statistics
        XCTAssertNotNil(stats.lastCheckDate)
        XCTAssertEqual(stats.totalItemsQueued, 1)
        XCTAssertEqual(stats.cycleCount, 1)
    }

    func testStatisticsAccumulate() async {
        await publicationProvider.addPublication(
            id: UUID(),
            identifiers: [.doi: "10.1234/test1"]
        )

        await scheduler.triggerImmediateCheck()

        // Clear first publication and add a new one
        // (simulates the first one being enriched and no longer stale)
        await publicationProvider.clear()
        await publicationProvider.addPublication(
            id: UUID(),
            identifiers: [.doi: "10.1234/test2"]
        )

        await scheduler.triggerImmediateCheck()

        let stats = await scheduler.statistics
        XCTAssertEqual(stats.totalItemsQueued, 2)
        XCTAssertEqual(stats.cycleCount, 2)
    }

    func testStatisticsShowsRunningState() async {
        await scheduler.start()

        let stats = await scheduler.statistics
        XCTAssertTrue(stats.isRunning)
    }

    // MARK: - Enrichment Needs Tests

    func testEnrichmentNeedsWithNeverEnriched() async {
        await publicationProvider.addPublication(
            id: UUID(),
            identifiers: [.doi: "10.1234/never1"],
            enrichmentDate: nil
        )
        await publicationProvider.addPublication(
            id: UUID(),
            identifiers: [.doi: "10.1234/never2"],
            enrichmentDate: nil
        )

        let needs = await scheduler.enrichmentNeeds()

        XCTAssertEqual(needs.neverEnriched, 2)
        XCTAssertEqual(needs.stale, 0)
        XCTAssertEqual(needs.total, 2)
    }

    func testEnrichmentNeedsWithStale() async {
        let oldDate = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        await publicationProvider.addPublication(
            id: UUID(),
            identifiers: [.doi: "10.1234/stale"],
            enrichmentDate: oldDate
        )

        let needs = await scheduler.enrichmentNeeds()

        XCTAssertEqual(needs.neverEnriched, 0)
        XCTAssertEqual(needs.stale, 1)
        XCTAssertEqual(needs.total, 1)
    }

    func testEnrichmentNeedsMixed() async {
        let oldDate = Calendar.current.date(byAdding: .day, value: -30, to: Date())!

        await publicationProvider.addPublication(
            id: UUID(),
            identifiers: [.doi: "10.1234/never"],
            enrichmentDate: nil
        )
        await publicationProvider.addPublication(
            id: UUID(),
            identifiers: [.doi: "10.1234/stale"],
            enrichmentDate: oldDate
        )
        await publicationProvider.addPublication(
            id: UUID(),
            identifiers: [.doi: "10.1234/fresh"],
            enrichmentDate: Date()
        )

        let needs = await scheduler.enrichmentNeeds()

        XCTAssertEqual(needs.neverEnriched, 1)
        XCTAssertEqual(needs.stale, 1)
        XCTAssertEqual(needs.total, 2)
    }

    // MARK: - Scheduler Loop Tests

    func testSchedulerRunsMultipleCycles() async {
        await publicationProvider.addPublication(
            id: UUID(),
            identifiers: [.doi: "10.1234/test"]
        )

        await scheduler.start()

        // Wait for multiple cycles (interval is 0.1s)
        try? await Task.sleep(for: .milliseconds(350))

        await scheduler.stop()

        let stats = await scheduler.statistics
        XCTAssertGreaterThanOrEqual(stats.cycleCount, 2)
    }

    // MARK: - Time Until Next Check Tests

    func testTimeUntilNextCheckWhenNotRunning() async {
        let stats = await scheduler.statistics

        XCTAssertNil(stats.timeUntilNextCheck)
    }

    func testTimeUntilNextCheckAfterCheck() async {
        await scheduler.triggerImmediateCheck()
        await scheduler.start()

        let stats = await scheduler.statistics

        XCTAssertNotNil(stats.timeUntilNextCheck)
        // Should be close to checkInterval (0.1s in our test setup)
        XCTAssertLessThanOrEqual(stats.timeUntilNextCheck ?? 0, 0.1)
    }
}

// MARK: - Mock Settings Provider

actor MockEnrichmentSettingsProvider: EnrichmentSettingsProvider {
    private var _preferredSource: EnrichmentSource = .ads
    private var _sourcePriority: [EnrichmentSource] = [.ads]
    private var _autoSyncEnabled: Bool = true
    private var _refreshIntervalDays: Int = 7

    var preferredSource: EnrichmentSource {
        _preferredSource
    }

    var sourcePriority: [EnrichmentSource] {
        _sourcePriority
    }

    var autoSyncEnabled: Bool {
        _autoSyncEnabled
    }

    var refreshIntervalDays: Int {
        _refreshIntervalDays
    }

    func setPreferredSource(_ source: EnrichmentSource) {
        _preferredSource = source
    }

    func setSourcePriority(_ priority: [EnrichmentSource]) {
        _sourcePriority = priority
    }

    func setAutoSyncEnabled(_ enabled: Bool) {
        _autoSyncEnabled = enabled
    }

    func setRefreshIntervalDays(_ days: Int) {
        _refreshIntervalDays = days
    }
}
