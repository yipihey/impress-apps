//
//  EnrichmentIntegrationTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-04.
//

import XCTest
@testable import PublicationManagerCore

/// Integration tests for the enrichment system.
///
/// These tests verify the full enrichment flow from request to completion,
/// testing how components work together.
final class EnrichmentIntegrationTests: XCTestCase {

    // MARK: - Test Fixtures

    var mockPlugin: MockEnrichmentPlugin!
    var settingsProvider: DefaultEnrichmentSettingsProvider!
    var service: EnrichmentService!

    override func setUp() async throws {
        try await super.setUp()

        mockPlugin = MockEnrichmentPlugin(
            id: "ads",
            name: "NASA ADS",
            capabilities: [.citationCount, .references, .pdfURL]
        )

        settingsProvider = DefaultEnrichmentSettingsProvider()

        service = EnrichmentService(
            plugins: [mockPlugin],
            settingsProvider: settingsProvider
        )
    }

    override func tearDown() async throws {
        mockPlugin = nil
        settingsProvider = nil
        service = nil
        try await super.tearDown()
    }

    // MARK: - Full Flow Tests

    func testEnrichment_fullFlow_success() async throws {
        // Configure mock to succeed
        await mockPlugin.setEnrichResult(
            EnrichmentResult(
                data: EnrichmentData(
                    citationCount: 42,
                    source: .ads,
                    fetchedAt: Date()
                )
            )
        )

        // Enrich with DOI
        let identifiers: [IdentifierType: String] = [.doi: "10.1234/test"]
        let result = try await service.enrichNow(identifiers: identifiers)

        // Verify result
        XCTAssertEqual(result.data.citationCount, 42)
        XCTAssertEqual(result.data.source, .ads)
    }

    func testEnrichment_pluginFails_throwsError() async throws {
        // Plugin fails
        await mockPlugin.setFailure(EnrichmentError.networkError("Connection failed"))

        // Enrich should fail
        let identifiers: [IdentifierType: String] = [.doi: "10.1234/test"]

        do {
            _ = try await service.enrichNow(identifiers: identifiers)
            XCTFail("Expected error to be thrown")
        } catch let error as EnrichmentError {
            if case .networkError(let message) = error {
                XCTAssertTrue(message.contains("Connection"))
            } else {
                XCTFail("Expected network error")
            }
        }
    }

    func testEnrichment_emptyIdentifiers_throwsNoIdentifier() async throws {
        let identifiers: [IdentifierType: String] = [:]

        do {
            _ = try await service.enrichNow(identifiers: identifiers)
            XCTFail("Expected error to be thrown")
        } catch EnrichmentError.noIdentifier {
            // Expected
        }
    }

    // MARK: - Queue Tests

    func testEnrichment_queueing_addsToQueue() async throws {
        let pubID = UUID()
        let identifiers: [IdentifierType: String] = [.doi: "10.1234/test"]

        await service.queueForEnrichment(
            publicationID: pubID,
            identifiers: identifiers,
            priority: .userTriggered
        )

        let depth = await service.queueDepth()
        XCTAssertEqual(depth, 1)
    }

    func testEnrichment_processNextQueued_enrichesAndRemoves() async throws {
        await mockPlugin.setEnrichResult(
            EnrichmentResult(
                data: EnrichmentData(
                    citationCount: 55,
                    source: .ads,
                    fetchedAt: Date()
                )
            )
        )

        let pubID = UUID()
        let identifiers: [IdentifierType: String] = [.doi: "10.1234/test"]

        await service.queueForEnrichment(
            publicationID: pubID,
            identifiers: identifiers,
            priority: .libraryPaper
        )

        // Process the queued item
        let result = await service.processNextQueued()

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.0, pubID)

        if case .success(let enrichResult) = result?.1 {
            XCTAssertEqual(enrichResult.data.citationCount, 55)
        } else {
            XCTFail("Expected success result")
        }

        // Queue should be empty now
        let depth = await service.queueDepth()
        XCTAssertEqual(depth, 0)
    }

    // MARK: - Retry Integration Tests

    func testEnrichWithRetry_succeedsOnFirstAttempt() async throws {
        await mockPlugin.setEnrichResult(
            EnrichmentResult(
                data: EnrichmentData(
                    citationCount: 77,
                    source: .ads,
                    fetchedAt: Date()
                )
            )
        )

        let identifiers: [IdentifierType: String] = [.doi: "10.1234/test"]
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01, jitterFactor: 0)

        let result = try await service.enrichWithRetry(
            identifiers: identifiers,
            policy: policy
        )

        XCTAssertEqual(result.data.citationCount, 77)
    }

    func testEnrichWithRetry_exhaustsRetries_throwsError() async throws {
        // Always fails
        await mockPlugin.setFailure(EnrichmentError.networkError("Persistent failure"))

        let identifiers: [IdentifierType: String] = [.doi: "10.1234/test"]
        let policy = RetryPolicy(maxAttempts: 2, baseDelay: 0.01, jitterFactor: 0)

        do {
            _ = try await service.enrichWithRetry(
                identifiers: identifiers,
                policy: policy
            )
            XCTFail("Expected error")
        } catch {
            // Expected
        }
    }

    // MARK: - Background Scheduler Integration Tests

    func testBackgroundScheduler_queuesStalePublications() async throws {
        let publicationProvider = MockStalePublicationProvider()

        // Add some stale publications
        let staleDate = Date(timeIntervalSinceNow: -86400 * 10) // 10 days old
        await publicationProvider.addPublication(
            id: UUID(),
            identifiers: [.doi: "10.1234/old1"],
            enrichmentDate: staleDate
        )
        await publicationProvider.addPublication(
            id: UUID(),
            identifiers: [.doi: "10.1234/old2"],
            enrichmentDate: staleDate
        )

        let scheduler = BackgroundScheduler(
            enrichmentService: service,
            publicationProvider: publicationProvider,
            settingsProvider: settingsProvider,
            checkInterval: 0.1,  // Fast for testing
            itemsPerCycle: 10
        )

        let queued = await scheduler.triggerImmediateCheck()

        XCTAssertEqual(queued, 2)

        let queueDepth = await service.queueDepth()
        XCTAssertEqual(queueDepth, 2)
    }

    func testBackgroundScheduler_neverEnrichedPublications_areQueued() async throws {
        let publicationProvider = MockStalePublicationProvider()

        // Add publications that have never been enriched (nil enrichmentDate)
        await publicationProvider.addPublication(
            id: UUID(),
            identifiers: [.doi: "10.1234/new1"],
            enrichmentDate: nil
        )

        let scheduler = BackgroundScheduler(
            enrichmentService: service,
            publicationProvider: publicationProvider,
            settingsProvider: settingsProvider,
            checkInterval: 0.1,
            itemsPerCycle: 10
        )

        let queued = await scheduler.triggerImmediateCheck()

        XCTAssertEqual(queued, 1)
    }

    // MARK: - Failed Request Tracker Integration Tests

    func testFailedRequestTracker_tracksAndClearsFailures() async {
        let tracker = FailedRequestTracker()
        let pubID1 = UUID()
        let pubID2 = UUID()

        // Record failures
        await tracker.recordFailure(
            publicationID: pubID1,
            identifiers: [.doi: "10.1234/test1"],
            error: EnrichmentError.networkError("Failed")
        )
        await tracker.recordFailure(
            publicationID: pubID2,
            identifiers: [.doi: "10.1234/test2"],
            error: EnrichmentError.rateLimited(retryAfter: 60)
        )

        var count = await tracker.failureCount
        XCTAssertEqual(count, 2)

        // Clear one
        await tracker.clearFailure(for: pubID1)
        count = await tracker.failureCount
        XCTAssertEqual(count, 1)

        // Get requests for retry
        let requests = await tracker.requestsForRetry()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.publicationID, pubID2)

        // Clear all
        await tracker.clearAll()
        count = await tracker.failureCount
        XCTAssertEqual(count, 0)
    }

    func testFailedRequestTracker_incrementsRetryCount() async {
        let tracker = FailedRequestTracker()
        let pubID = UUID()

        // Record same failure multiple times
        for _ in 0..<3 {
            await tracker.recordFailure(
                publicationID: pubID,
                identifiers: [.doi: "10.1234/test"],
                error: EnrichmentError.networkError("Failed")
            )
        }

        let requests = await tracker.requestsForRetry()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.retryCount, 2) // 0, 1, 2 = 3 attempts
    }

    // MARK: - Settings Integration Tests

    func testEnrichmentSettings_persistAndReload() async {
        let store = EnrichmentSettingsStore.shared

        // Save original settings to restore later
        let originalSettings = await store.settings

        // Update settings
        await store.updateAutoSyncEnabled(false)
        await store.updateRefreshIntervalDays(14)

        // Read back
        let settings = await store.settings
        XCTAssertFalse(settings.autoSyncEnabled)
        XCTAssertEqual(settings.refreshIntervalDays, 14)

        // Reset to defaults
        await store.resetToDefaults()
        let defaultSettings = await store.settings
        XCTAssertEqual(defaultSettings.preferredSource, .ads)
        XCTAssertTrue(defaultSettings.autoSyncEnabled)

        // Restore original settings
        await store.updatePreferredSource(originalSettings.preferredSource)
        await store.updateAutoSyncEnabled(originalSettings.autoSyncEnabled)
        await store.updateRefreshIntervalDays(originalSettings.refreshIntervalDays)
    }

    // MARK: - EnrichmentProgressState Tests

    func testEnrichmentProgressState_enrichingState() {
        let state = EnrichmentProgressState.enriching(
            completed: 5,
            total: 10,
            current: "Testing paper"
        )

        XCTAssertEqual(state.status, .enriching)
        XCTAssertEqual(state.completedCount, 5)
        XCTAssertEqual(state.totalCount, 10)
        XCTAssertEqual(state.progress, 0.5)
        XCTAssertTrue(state.isActive)
        XCTAssertEqual(state.currentOperation, "Testing paper")
    }

    func testEnrichmentProgressState_completedState() {
        let state = EnrichmentProgressState.completed(count: 20)

        XCTAssertEqual(state.status, .completed)
        XCTAssertEqual(state.completedCount, 20)
        XCTAssertEqual(state.totalCount, 20)
        XCTAssertEqual(state.progress, 1.0)
        XCTAssertFalse(state.isActive)
    }

    func testEnrichmentProgressState_errorState() {
        let state = EnrichmentProgressState.error("Network timeout")

        XCTAssertEqual(state.status, .error)
        XCTAssertEqual(state.lastError, "Network timeout")
        XCTAssertFalse(state.isActive)
    }

    func testEnrichmentProgressState_statusMessage() {
        XCTAssertEqual(EnrichmentProgressState.idle.statusMessage, "Ready")

        let enriching = EnrichmentProgressState(
            status: .enriching,
            completedCount: 3,
            totalCount: 10
        )
        XCTAssertEqual(enriching.statusMessage, "Enriching 3/10")

        let paused = EnrichmentProgressState(status: .paused)
        XCTAssertEqual(paused.statusMessage, "Paused")
    }

    // MARK: - EnrichmentStatistics Tests

    func testEnrichmentStatistics_creation() {
        let stats = EnrichmentStatistics(
            totalEnriched: 100,
            staleCount: 15,
            neverEnrichedCount: 5
        )

        XCTAssertEqual(stats.totalEnriched, 100)
        XCTAssertEqual(stats.staleCount, 15)
        XCTAssertEqual(stats.neverEnrichedCount, 5)
    }
}
