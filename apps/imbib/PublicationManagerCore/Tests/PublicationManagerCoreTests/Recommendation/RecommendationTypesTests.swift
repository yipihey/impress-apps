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
        // Verify all cases are present
        XCTAssertEqual(FeatureType.allCases.count, 18)
    }

    func testFeatureTypeDefaultWeights() {
        // Positive features should have positive weights
        XCTAssertGreaterThan(FeatureType.authorStarred.defaultWeight, 0)
        XCTAssertGreaterThan(FeatureType.collectionMatch.defaultWeight, 0)
        XCTAssertGreaterThan(FeatureType.recency.defaultWeight, 0)

        // Negative features should have negative weights
        XCTAssertLessThan(FeatureType.mutedAuthor.defaultWeight, 0)
        XCTAssertLessThan(FeatureType.mutedCategory.defaultWeight, 0)
        XCTAssertLessThan(FeatureType.dismissRateAuthor.defaultWeight, 0)
    }

    func testFeatureTypeCategories() {
        // Verify categories are assigned correctly
        XCTAssertEqual(FeatureType.authorStarred.category, .explicit)
        XCTAssertEqual(FeatureType.saveRateAuthor.category, .implicit)
        XCTAssertEqual(FeatureType.citationOverlap.category, .content)
    }

    func testFeatureTypeDisplayNames() {
        // Verify display names are non-empty
        for feature in FeatureType.allCases {
            XCTAssertFalse(feature.displayName.isEmpty, "Display name should not be empty for \(feature)")
        }
    }

    func testFeatureTypeDescriptions() {
        // Verify descriptions are non-empty
        for feature in FeatureType.allCases {
            XCTAssertFalse(feature.featureDescription.isEmpty, "Description should not be empty for \(feature)")
        }
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
        // Positive actions should have positive multipliers
        XCTAssertGreaterThan(TrainingAction.saved.learningMultiplier, 0)
        XCTAssertGreaterThan(TrainingAction.starred.learningMultiplier, 0)
        XCTAssertGreaterThan(TrainingAction.moreLikeThis.learningMultiplier, 0)

        // Negative actions should have negative multipliers
        XCTAssertLessThan(TrainingAction.dismissed.learningMultiplier, 0)
        XCTAssertLessThan(TrainingAction.lessLikeThis.learningMultiplier, 0)

        // Star should be stronger than keep
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
            .authorStarred: 0.5,
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
            .authorStarred: 0.5,
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
        XCTAssertEqual(topContributors.first?.0, .authorStarred)
    }

    // MARK: - Score Breakdown Tests

    func testScoreBreakdownCreation() {
        let component = ScoreComponent(
            feature: .authorStarred,
            rawValue: 0.8,
            weight: 0.6
        )

        XCTAssertEqual(component.contribution, 0.48, accuracy: 0.001)
        XCTAssertTrue(component.isPositiveContribution)
    }

    // MARK: - Preset Tests

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
        let focusedAuthorWeight = focusedWeights[.authorStarred] ?? 0
        let exploratoryAuthorWeight = exploratoryWeights[.authorStarred] ?? 0
        XCTAssertGreaterThan(focusedAuthorWeight, exploratoryAuthorWeight)

        // Exploratory should weight discovery signals higher
        let focusedVelocityWeight = focusedWeights[.fieldCitationVelocity] ?? 0
        let exploratoryVelocityWeight = exploratoryWeights[.fieldCitationVelocity] ?? 0
        XCTAssertLessThan(focusedVelocityWeight, exploratoryVelocityWeight)
    }
}
