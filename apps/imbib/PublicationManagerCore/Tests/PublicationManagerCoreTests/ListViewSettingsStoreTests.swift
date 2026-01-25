//
//  ListViewSettingsStoreTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-06.
//

import XCTest
@testable import PublicationManagerCore

final class ListViewSettingsStoreTests: XCTestCase {

    // MARK: - Setup

    var store: ListViewSettingsStore!
    var defaults: UserDefaults!

    override func setUp() async throws {
        // Use a separate UserDefaults suite for testing
        defaults = UserDefaults(suiteName: "test.listViewSettings")!
        defaults.removePersistentDomain(forName: "test.listViewSettings")
        store = ListViewSettingsStore(userDefaults: defaults)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: "test.listViewSettings")
        defaults = nil
        store = nil
    }

    // MARK: - Default Values

    func testDefaultSettings() async {
        let settings = await store.settings

        XCTAssertTrue(settings.showYear)
        XCTAssertTrue(settings.showTitle)
        XCTAssertFalse(settings.showVenue)
        XCTAssertTrue(settings.showCitationCount)
        XCTAssertTrue(settings.showUnreadIndicator)
        XCTAssertTrue(settings.showAttachmentIndicator)
        XCTAssertEqual(settings.abstractLineLimit, 2)
        XCTAssertEqual(settings.rowDensity, .default)
    }

    // MARK: - Persistence

    func testSettingsPersistence() async {
        // Modify settings
        var modified = ListViewSettings()
        modified.showYear = false
        modified.showVenue = true
        modified.abstractLineLimit = 5
        modified.rowDensity = .compact

        await store.update(modified)

        // Clear cache and reload
        await store.clearCache()
        let loaded = await store.settings

        XCTAssertFalse(loaded.showYear)
        XCTAssertTrue(loaded.showVenue)
        XCTAssertEqual(loaded.abstractLineLimit, 5)
        XCTAssertEqual(loaded.rowDensity, .compact)
    }

    func testAbstractLineLimitClamping() async {
        await store.updateAbstractLineLimit(-5)
        var settings = await store.settings
        XCTAssertEqual(settings.abstractLineLimit, 0)

        await store.updateAbstractLineLimit(15)
        settings = await store.settings
        XCTAssertEqual(settings.abstractLineLimit, 10)

        await store.updateAbstractLineLimit(7)
        settings = await store.settings
        XCTAssertEqual(settings.abstractLineLimit, 7)
    }

    func testUpdateFieldVisibility() async {
        await store.updateFieldVisibility(
            showYear: false,
            showTitle: false,
            showCitationCount: false
        )

        let settings = await store.settings
        XCTAssertFalse(settings.showYear)
        XCTAssertFalse(settings.showTitle)
        XCTAssertFalse(settings.showCitationCount)
        // Unchanged values should remain at defaults
        XCTAssertTrue(settings.showUnreadIndicator)
    }

    func testUpdateRowDensity() async {
        await store.updateRowDensity(.spacious)
        var settings = await store.settings
        XCTAssertEqual(settings.rowDensity, .spacious)

        await store.updateRowDensity(.compact)
        settings = await store.settings
        XCTAssertEqual(settings.rowDensity, .compact)
    }

    func testReset() async {
        // Modify settings
        var modified = ListViewSettings()
        modified.showYear = false
        modified.showVenue = true
        modified.abstractLineLimit = 8
        await store.update(modified)

        // Reset
        await store.reset()

        // Should be back to defaults
        let settings = await store.settings
        XCTAssertTrue(settings.showYear)
        XCTAssertFalse(settings.showVenue)
        XCTAssertEqual(settings.abstractLineLimit, 2)
    }

    // MARK: - Row Density

    func testRowDensityPadding() {
        XCTAssertEqual(RowDensity.compact.rowPadding, 4)
        XCTAssertEqual(RowDensity.default.rowPadding, 8)
        XCTAssertEqual(RowDensity.spacious.rowPadding, 12)
    }

    func testRowDensityContentSpacing() {
        XCTAssertEqual(RowDensity.compact.contentSpacing, 1)
        XCTAssertEqual(RowDensity.default.contentSpacing, 2)
        XCTAssertEqual(RowDensity.spacious.contentSpacing, 4)
    }

    func testRowDensityDisplayName() {
        XCTAssertEqual(RowDensity.compact.displayName, "Compact")
        XCTAssertEqual(RowDensity.default.displayName, "Default")
        XCTAssertEqual(RowDensity.spacious.displayName, "Spacious")
    }

    // MARK: - Equatable

    func testSettingsEquatable() {
        let settings1 = ListViewSettings()
        var settings2 = ListViewSettings()

        XCTAssertEqual(settings1, settings2)

        settings2.showYear = false
        XCTAssertNotEqual(settings1, settings2)
    }

    // MARK: - Codable

    func testSettingsCodable() throws {
        var original = ListViewSettings()
        original.showYear = false
        original.showVenue = true
        original.abstractLineLimit = 6
        original.rowDensity = .spacious

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ListViewSettings.self, from: data)

        XCTAssertEqual(original, decoded)
    }
}
