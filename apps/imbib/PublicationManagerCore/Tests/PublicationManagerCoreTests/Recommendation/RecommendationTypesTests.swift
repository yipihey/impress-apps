//
//  RecommendationTypesTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-19.
//

import XCTest
@testable import PublicationManagerCore

final class RecommendationTypesTests: XCTestCase {

    // MARK: - Feature Type Tests

    func testFeatureTypeAllCases() {
        // 9 tunable + 3 mute filters = 12
        XCTAssertEqual(FeatureType.allCases.count, 12)
    }

    func testFeatureTypeTunableFeatures() {
        XCTAssertEqual(FeatureType.tunableFeatures.count, 9)
        for feature in FeatureType.tunableFeatures {
            XCTAssertFalse(feature.isMuteFilter)
        }
    }

    func testFeatureTypeDefaultWeights() {
        // Tunable features should have positive weights
        XCTAssertGreaterThan(FeatureType.authorAffinity.defaultWeight, 0)
        XCTAssertGreaterThan(FeatureType.topicMatch.defaultWeight, 0)
        XCTAssertGreaterThan(FeatureType.recency.defaultWeight, 0)

        // Mute filters should have negative weights
        XCTAssertLessThan(FeatureType.mutedAuthor.defaultWeight, 0)
        XCTAssertLessThan(FeatureType.mutedCategory.defaultWeight, 0)
        XCTAssertLessThan(FeatureType.mutedVenue.defaultWeight, 0)
    }

    func testFeatureTypeCategories() {
        XCTAssertEqual(FeatureType.authorAffinity.category, .preferences)
        XCTAssertEqual(FeatureType.citationVelocity.category, .discovery)
        XCTAssertEqual(FeatureType.mutedAuthor.category, .filters)
    }

    func testFeatureTypeDisplayNames() {
        for feature in FeatureType.allCases {
            XCTAssertFalse(feature.displayName.isEmpty, "Display name should not be empty for \(feature)")
        }
    }

    func testFeatureTypeDescriptions() {
        for feature in FeatureType.allCases {
            XCTAssertFalse(feature.featureDescription.isEmpty, "Description should not be empty for \(feature)")
        }
    }

    func testMuteFilterFlag() {
        XCTAssertTrue(FeatureType.mutedAuthor.isMuteFilter)
        XCTAssertTrue(FeatureType.mutedCategory.isMuteFilter)
        XCTAssertTrue(FeatureType.mutedVenue.isMuteFilter)
        XCTAssertFalse(FeatureType.authorAffinity.isMuteFilter)
        XCTAssertFalse(FeatureType.aiSimilarity.isMuteFilter)
    }

    // MARK: - Migration Tests

    func testMigrateOldKeys() {
        // Merged keys
        XCTAssertEqual(FeatureType.migrateWeightKey("authorStarred"), "authorAffinity")
        XCTAssertEqual(FeatureType.migrateWeightKey("saveRateAuthor"), "authorAffinity")
        XCTAssertEqual(FeatureType.migrateWeightKey("dismissRateAuthor"), "authorAffinity")
        XCTAssertEqual(FeatureType.migrateWeightKey("readingTimeTopic"), "topicMatch")
        XCTAssertEqual(FeatureType.migrateWeightKey("collectionMatch"), "topicMatch")
        XCTAssertEqual(FeatureType.migrateWeightKey("venueFrequency"), "venueAffinity")
        XCTAssertEqual(FeatureType.migrateWeightKey("saveRateVenue"), "venueAffinity")

        // Renamed keys
        XCTAssertEqual(FeatureType.migrateWeightKey("tagMatch"), "tagAffinity")
        XCTAssertEqual(FeatureType.migrateWeightKey("authorCoauthorship"), "coauthorNetwork")
        XCTAssertEqual(FeatureType.migrateWeightKey("fieldCitationVelocity"), "citationVelocity")
        XCTAssertEqual(FeatureType.migrateWeightKey("librarySimilarity"), "aiSimilarity")

        // Removed keys
        XCTAssertNil(FeatureType.migrateWeightKey("citationOverlap"))
        XCTAssertNil(FeatureType.migrateWeightKey("pdfDownloadAuthor"))

        // Already valid keys pass through
        XCTAssertEqual(FeatureType.migrateWeightKey("recency"), "recency")
        XCTAssertEqual(FeatureType.migrateWeightKey("smartSearchMatch"), "smartSearchMatch")
        XCTAssertEqual(FeatureType.migrateWeightKey("mutedAuthor"), "mutedAuthor")
    }

    // MARK: - Training Event Tests

    func testTrainingEventCreation() {
        let event = TrainingEvent(
            action: .saved,
            publicationID: UUID(),
            publicationTitle: "Test Paper",
            publicationAuthors: "Test Author",
            weightDeltas: ["author:test": 1.0]
        )

        XCTAssertEqual(event.action, .saved)
        XCTAssertEqual(event.publicationTitle, "Test Paper")
        XCTAssertFalse(event.weightDeltas.isEmpty)
    }

    func testTrainingActionLearningMultipliers() {
        XCTAssertGreaterThan(TrainingAction.saved.learningMultiplier, 0)
        XCTAssertGreaterThan(TrainingAction.starred.learningMultiplier, 0)
        XCTAssertGreaterThan(TrainingAction.moreLikeThis.learningMultiplier, 0)

        XCTAssertLessThan(TrainingAction.dismissed.learningMultiplier, 0)
        XCTAssertLessThan(TrainingAction.lessLikeThis.learningMultiplier, 0)

        XCTAssertGreaterThan(TrainingAction.starred.learningMultiplier, TrainingAction.saved.learningMultiplier)
    }

    func testTrainingActionIsPositive() {
        XCTAssertTrue(TrainingAction.saved.isPositive)
        XCTAssertTrue(TrainingAction.starred.isPositive)
        XCTAssertFalse(TrainingAction.dismissed.isPositive)
        XCTAssertFalse(TrainingAction.lessLikeThis.isPositive)
    }

    // MARK: - Recommendation Score Tests

    func testRecommendationScoreCreation() {
        let breakdown: [FeatureType: Double] = [
            .authorAffinity: 0.5,
            .recency: 0.3,
            .mutedAuthor: -0.2
        ]

        let score = RecommendationScore(
            total: 0.6,
            breakdown: breakdown,
            explanation: "Author, Recency"
        )

        XCTAssertEqual(score.total, 0.6)
        XCTAssertEqual(score.breakdown.count, 3)
        XCTAssertFalse(score.isSerendipitySlot)
    }

    func testRecommendationScoreTopContributors() {
        let breakdown: [FeatureType: Double] = [
            .authorAffinity: 0.5,
            .recency: 0.3,
            .mutedAuthor: -0.2
        ]

        let score = RecommendationScore(
            total: 0.6,
            breakdown: breakdown,
            explanation: "Test"
        )

        let topContributors = score.topContributors
        XCTAssertEqual(topContributors.count, 2)
        XCTAssertEqual(topContributors.first?.0, .authorAffinity)
    }

    // MARK: - Score Breakdown Tests

    func testScoreBreakdownCreation() {
        let component = ScoreComponent(
            feature: .authorAffinity,
            rawValue: 0.8,
            weight: 0.6
        )

        XCTAssertEqual(component.contribution, 0.48, accuracy: 0.001)
        XCTAssertTrue(component.isPositiveContribution)
        XCTAssertNil(component.detail)
    }

    func testScoreComponentWithDetail() {
        let component = ScoreComponent(
            feature: .authorAffinity,
            rawValue: 0.8,
            weight: 0.6,
            detail: "Smith, Jones"
        )

        XCTAssertEqual(component.detail, "Smith, Jones")
    }

    // MARK: - Preset Tests

    func testRecommendationPresetsCount() {
        XCTAssertEqual(RecommendationPreset.allCases.count, 3)
    }

    func testRecommendationPresets() {
        for preset in RecommendationPreset.allCases {
            let weights = preset.weights
            XCTAssertFalse(weights.isEmpty, "Preset \(preset) should have weights")
        }
    }

    func testPresetWeightsAreReasonable() {
        let focusedWeights = RecommendationPreset.focused.weights
        let exploratoryWeights = RecommendationPreset.exploratory.weights

        // Focused should weight familiar authors higher
        let focusedAuthorWeight = focusedWeights[.authorAffinity] ?? 0
        let exploratoryAuthorWeight = exploratoryWeights[.authorAffinity] ?? 0
        XCTAssertGreaterThan(focusedAuthorWeight, exploratoryAuthorWeight)

        // Exploratory should weight citation velocity higher
        let focusedVelocityWeight = focusedWeights[.citationVelocity] ?? 0
        let exploratoryVelocityWeight = exploratoryWeights[.citationVelocity] ?? 0
        XCTAssertLessThan(focusedVelocityWeight, exploratoryVelocityWeight)

        // Exploratory should weight AI similarity higher
        let focusedAIWeight = focusedWeights[.aiSimilarity] ?? 0
        let exploratoryAIWeight = exploratoryWeights[.aiSimilarity] ?? 0
        XCTAssertLessThan(focusedAIWeight, exploratoryAIWeight)
    }
}
