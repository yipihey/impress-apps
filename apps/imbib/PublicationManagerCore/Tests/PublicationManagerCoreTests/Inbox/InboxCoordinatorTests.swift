//
//  InboxCoordinatorTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-06.
//

import XCTest
import CoreData
@testable import PublicationManagerCore

@MainActor
final class InboxCoordinatorTests: XCTestCase {

    // MARK: - Properties

    private var coordinator: InboxCoordinator!

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()
        coordinator = InboxCoordinator.shared
    }

    override func tearDown() async throws {
        await coordinator.stop()
        try await super.tearDown()
    }

    // MARK: - Lifecycle Tests

    func testStart_initializesServices() async {
        // Given - coordinator not started
        await coordinator.stop()
        XCTAssertNil(coordinator.paperFetchService)
        XCTAssertNil(coordinator.scheduler)

        // When
        await coordinator.start()

        // Then
        XCTAssertNotNil(coordinator.paperFetchService)
        XCTAssertNotNil(coordinator.scheduler)
    }

    func testStart_startsScheduler() async {
        // When
        await coordinator.start()

        // Then
        let running = await coordinator.scheduler?.running ?? false
        XCTAssertTrue(running)
    }

    func testStart_alreadyStarted_doesNotReinitialize() async {
        // Given
        await coordinator.start()
        let firstService = coordinator.paperFetchService

        // When - start again
        await coordinator.start()

        // Then - should be same instance (not recreated)
        XCTAssertTrue(coordinator.paperFetchService === firstService)
    }

    func testStop_stopsScheduler() async {
        // Given
        await coordinator.start()
        let runningBefore = await coordinator.scheduler?.running ?? false
        XCTAssertTrue(runningBefore)

        // When
        await coordinator.stop()

        // Then
        XCTAssertNil(coordinator.scheduler)
        XCTAssertNil(coordinator.paperFetchService)
    }

    // MARK: - Service Access Tests

    func testInboxManager_returnsSharedInstance() {
        // When
        let manager = coordinator.inboxManager

        // Then
        XCTAssertNotNil(manager)
        XCTAssertTrue(manager === InboxManager.shared)
    }

    func testSchedulerStatistics_returnsStats_whenRunning() async {
        // Given
        await coordinator.start()
        // Wait a moment for initial check
        try? await Task.sleep(for: .milliseconds(100))

        // When
        let stats = await coordinator.schedulerStatistics()

        // Then
        XCTAssertNotNil(stats)
        XCTAssertTrue(stats?.isRunning ?? false)
    }

    func testSchedulerStatistics_returnsNil_whenNotStarted() async {
        // Given
        await coordinator.stop()

        // When
        let stats = await coordinator.schedulerStatistics()

        // Then
        XCTAssertNil(stats)
    }

    // MARK: - Delegation Tests

    func testRefreshAllFeeds_whenNotStarted_returnsZero() async {
        // Given
        await coordinator.stop()

        // When
        let count = await coordinator.refreshAllFeeds()

        // Then
        XCTAssertEqual(count, 0)
    }

    func testSendToInbox_whenNotStarted_returnsZero() async {
        // Given
        await coordinator.stop()
        let results = [
            SearchResult(
                id: "test-\(UUID().uuidString)",
                sourceID: "test",
                title: "Test Paper",
                authors: ["Author, A."],
                year: 2024
            )
        ]

        // When
        let count = await coordinator.sendToInbox(results: results)

        // Then
        XCTAssertEqual(count, 0)
    }

    func testSendToInbox_whenStarted_delegatesToService() async {
        // Given
        await coordinator.start()
        let uniqueID = "coord-test-\(UUID().uuidString)"
        let results = [
            SearchResult(
                id: uniqueID,
                sourceID: "test",
                title: "Test Paper",
                authors: ["CoordinatorTestAuthor, A."],
                year: 2024
            )
        ]

        // When
        let count = await coordinator.sendToInbox(results: results)

        // Then - paper should be created
        XCTAssertEqual(count, 1)
    }
}
