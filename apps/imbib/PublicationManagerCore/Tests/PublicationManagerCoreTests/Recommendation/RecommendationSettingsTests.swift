//
//  RecommendationSettingsTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-19.
//

import XCTest
@testable import PublicationManagerCore

final class RecommendationSettingsTests: XCTestCase {

    // MARK: - Settings Structure Tests

    func testDefaultSettingsValues() {
        let settings = RecommendationSettingsStore.Settings()

        XCTAssertTrue(settings.isEnabled)
        XCTAssertEqual(settings.serendipitySlotFrequency, 10)
        XCTAssertEqual(settings.reRankThrottleMinutes, 5)
        XCTAssertEqual(settings.negativePrefDecayDays, 90)
    }

    func testDefaultWeightsAreInitialized() {
        let settings = RecommendationSettingsStore.Settings()

        // Should have weights for all feature types
        for feature in FeatureType.allCases {
            let weight = settings.weight(for: feature)
            XCTAssertNotEqual(weight, 0, "Weight for \(feature) should be non-zero default")
        }
    }

    func testWeightForFeature() {
        var settings = RecommendationSettingsStore.Settings()

        let originalWeight = settings.weight(for: .authorStarred)
        settings.setWeight(1.5, for: .authorStarred)

        XCTAssertEqual(settings.weight(for: .authorStarred), 1.5)
        XCTAssertNotEqual(originalWeight, 1.5)
    }

    func testResetToDefaults() {
        var settings = RecommendationSettingsStore.Settings()

        // Modify some weights
        settings.setWeight(999.0, for: .authorStarred)
        settings.setWeight(-999.0, for: .mutedAuthor)

        // Reset
        settings.resetToDefaults()

        // Verify reset to default values
        XCTAssertEqual(settings.weight(for: .authorStarred), FeatureType.authorStarred.defaultWeight)
        XCTAssertEqual(settings.weight(for: .mutedAuthor), FeatureType.mutedAuthor.defaultWeight)
    }

    func testApplyPreset() {
        var settings = RecommendationSettingsStore.Settings()

        settings.apply(preset: .focused)

        // Focused preset should have high author weight
        let focusedAuthorWeight = RecommendationPreset.focused.weights[.authorStarred] ?? 0
        XCTAssertEqual(settings.weight(for: .authorStarred), focusedAuthorWeight)
    }

    func testSettingsEquality() {
        let settings1 = RecommendationSettingsStore.Settings()
        let settings2 = RecommendationSettingsStore.Settings()

        XCTAssertEqual(settings1, settings2)

        var settings3 = RecommendationSettingsStore.Settings()
        settings3.setWeight(999.0, for: .authorStarred)

        XCTAssertNotEqual(settings1, settings3)
    }

    func testSettingsCodable() throws {
        var original = RecommendationSettingsStore.Settings()
        original.setWeight(1.234, for: .authorStarred)
        original.serendipitySlotFrequency = 15
        original.isEnabled = false

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(RecommendationSettingsStore.Settings.self, from: data)

        XCTAssertEqual(decoded.weight(for: .authorStarred), 1.234)
        XCTAssertEqual(decoded.serendipitySlotFrequency, 15)
        XCTAssertFalse(decoded.isEnabled)
    }

    // MARK: - Serendipity Frequency Tests

    func testSerendipityFrequencyBounds() {
        var settings = RecommendationSettingsStore.Settings()

        settings.serendipitySlotFrequency = 1
        XCTAssertEqual(settings.serendipitySlotFrequency, 1)

        settings.serendipitySlotFrequency = 100
        XCTAssertEqual(settings.serendipitySlotFrequency, 100)
    }

    // MARK: - Decay Days Tests

    func testDecayDaysBounds() {
        var settings = RecommendationSettingsStore.Settings()

        settings.negativePrefDecayDays = 7
        XCTAssertEqual(settings.negativePrefDecayDays, 7)

        settings.negativePrefDecayDays = 365
        XCTAssertEqual(settings.negativePrefDecayDays, 365)
    }
}
