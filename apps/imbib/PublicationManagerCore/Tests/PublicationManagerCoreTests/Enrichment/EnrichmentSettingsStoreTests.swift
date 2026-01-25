//
//  EnrichmentSettingsStoreTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-04.
//

import XCTest
@testable import PublicationManagerCore

final class EnrichmentSettingsStoreTests: XCTestCase {

    var userDefaults: UserDefaults!
    var store: EnrichmentSettingsStore!

    override func setUp() async throws {
        try await super.setUp()

        // Use a unique suite for test isolation
        let suiteName = "com.imbib.test.\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: suiteName)!

        // Clear any existing data
        userDefaults.removeObject(forKey: EnrichmentSettingsStore.userDefaultsKey)

        store = EnrichmentSettingsStore(userDefaults: userDefaults)
    }

    override func tearDown() async throws {
        userDefaults.removeSuite(named: userDefaults.description)
        try await super.tearDown()
    }

    // MARK: - Default Settings Tests

    func testInitialSettingsAreDefaults() async {
        let settings = await store.settings

        XCTAssertEqual(settings, EnrichmentSettings.default)
    }

    func testPreferredSourceDefault() async {
        let source = await store.preferredSource

        XCTAssertEqual(source, .ads)
    }

    func testSourcePriorityDefault() async {
        let priority = await store.sourcePriority

        XCTAssertEqual(priority, [.ads])
    }

    func testAutoSyncEnabledDefault() async {
        let enabled = await store.autoSyncEnabled

        XCTAssertTrue(enabled)
    }

    func testRefreshIntervalDaysDefault() async {
        let days = await store.refreshIntervalDays

        XCTAssertEqual(days, 7)
    }

    // MARK: - Update Tests

    func testUpdatePreferredSource() async {
        await store.updatePreferredSource(.ads)

        let source = await store.preferredSource
        XCTAssertEqual(source, .ads)
    }

    func testUpdateSourcePriority() async {
        let newPriority: [EnrichmentSource] = [.ads]
        await store.updateSourcePriority(newPriority)

        let priority = await store.sourcePriority
        XCTAssertEqual(priority, newPriority)
    }

    func testUpdateAutoSyncEnabled() async {
        await store.updateAutoSyncEnabled(false)

        let enabled = await store.autoSyncEnabled
        XCTAssertFalse(enabled)
    }

    func testUpdateRefreshIntervalDays() async {
        await store.updateRefreshIntervalDays(14)

        let days = await store.refreshIntervalDays
        XCTAssertEqual(days, 14)
    }

    func testUpdateRefreshIntervalDaysMinimumIsOne() async {
        await store.updateRefreshIntervalDays(0)

        let days = await store.refreshIntervalDays
        XCTAssertEqual(days, 1)

        await store.updateRefreshIntervalDays(-5)

        let days2 = await store.refreshIntervalDays
        XCTAssertEqual(days2, 1)
    }

    func testUpdateSettings() async {
        let newSettings = EnrichmentSettings(
            preferredSource: .ads,
            sourcePriority: [.ads],
            autoSyncEnabled: false,
            refreshIntervalDays: 30
        )

        await store.updateSettings(newSettings)

        let settings = await store.settings
        XCTAssertEqual(settings, newSettings)
    }

    // MARK: - Persistence Tests

    func testSettingsArePersisted() async {
        // Update some settings
        await store.updateAutoSyncEnabled(false)

        // Create a new store with the same UserDefaults
        let newStore = EnrichmentSettingsStore(userDefaults: userDefaults)

        let enabled = await newStore.autoSyncEnabled

        XCTAssertFalse(enabled)
    }

    func testResetToDefaults() async {
        // Change some settings
        await store.updateAutoSyncEnabled(false)
        await store.updateRefreshIntervalDays(30)

        // Reset
        await store.resetToDefaults()

        let settings = await store.settings
        XCTAssertEqual(settings, EnrichmentSettings.default)
    }

    func testResetToDefaultsIsPersisted() async {
        await store.updateAutoSyncEnabled(false)
        await store.resetToDefaults()

        // Create a new store
        let newStore = EnrichmentSettingsStore(userDefaults: userDefaults)

        let settings = await newStore.settings
        XCTAssertEqual(settings, EnrichmentSettings.default)
    }

    // MARK: - Move Source Tests

    func testMoveSourceToBeginning() async {
        // With only one source, move is a no-op
        await store.moveSource(.ads, to: 0)

        let priority = await store.sourcePriority
        XCTAssertEqual(priority.first, .ads)
    }

    // MARK: - Convenience Methods Tests

    func testIsSourceEnabled() async {
        let isADSEnabled = await store.isSourceEnabled(.ads)
        XCTAssertTrue(isADSEnabled)
    }

    func testPriorityRank() async {
        let adsRank = await store.priorityRank(of: .ads)

        XCTAssertEqual(adsRank, 0)
    }

    func testTopPrioritySource() async {
        let top = await store.topPrioritySource

        XCTAssertEqual(top, .ads)
    }

    func testTopPrioritySourceWhenEmpty() async {
        await store.updateSourcePriority([])

        let top = await store.topPrioritySource

        XCTAssertNil(top)
    }

    // MARK: - Codable Round-Trip Tests

    func testEnrichmentSettingsCodable() throws {
        let settings = EnrichmentSettings(
            preferredSource: .ads,
            sourcePriority: [.ads],
            autoSyncEnabled: false,
            refreshIntervalDays: 14
        )

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(EnrichmentSettings.self, from: data)

        XCTAssertEqual(decoded, settings)
    }

    func testEnrichmentSettingsEquatable() {
        let settings1 = EnrichmentSettings(
            preferredSource: .ads,
            sourcePriority: [.ads],
            autoSyncEnabled: true,
            refreshIntervalDays: 7
        )
        let settings2 = EnrichmentSettings(
            preferredSource: .ads,
            sourcePriority: [.ads],
            autoSyncEnabled: true,
            refreshIntervalDays: 7
        )
        let settings3 = EnrichmentSettings(
            preferredSource: .ads,
            sourcePriority: [.ads],
            autoSyncEnabled: false,
            refreshIntervalDays: 7
        )

        XCTAssertEqual(settings1, settings2)
        XCTAssertNotEqual(settings1, settings3)
    }

    // MARK: - Corrupted Data Handling

    func testCorruptedDataFallsBackToDefaults() async {
        // Write corrupted data directly to UserDefaults
        userDefaults.set("not valid json".data(using: .utf8), forKey: EnrichmentSettingsStore.userDefaultsKey)

        // Create a new store
        let newStore = EnrichmentSettingsStore(userDefaults: userDefaults)

        let settings = await newStore.settings
        XCTAssertEqual(settings, EnrichmentSettings.default)
    }
}
