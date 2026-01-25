//
//  FeatureExtractorTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-19.
//

import XCTest
import CoreData
@testable import PublicationManagerCore

final class FeatureExtractorTests: XCTestCase {

    var context: NSManagedObjectContext!

    override func setUpWithError() throws {
        context = PersistenceController.preview.viewContext
    }

    // MARK: - Recency Score Tests

    func testRecencyScoreCurrentYear() {
        let publication = createPublication(year: Calendar.current.component(.year, from: Date()))

        let score = FeatureExtractor.recencyScore(publication)

        // Current year should have high score (close to 1.0)
        XCTAssertGreaterThan(score, 0.9)
    }

    func testRecencyScoreOldPaper() {
        let publication = createPublication(year: 2010)

        let score = FeatureExtractor.recencyScore(publication)

        // Old paper should have lower score
        XCTAssertLessThan(score, 0.1)
    }

    func testRecencyScoreUnknownYear() {
        let publication = createPublication(year: 0)

        let score = FeatureExtractor.recencyScore(publication)

        // Unknown year gets neutral score
        XCTAssertEqual(score, 0.5)
    }

    // MARK: - Citation Velocity Tests

    func testCitationVelocityHighCitations() {
        let currentYear = Calendar.current.component(.year, from: Date())
        let publication = createPublication(year: currentYear - 2, citationCount: 100)

        let score = FeatureExtractor.citationVelocityScore(publication)

        // 50 citations/year is very high
        XCTAssertGreaterThan(score, 0.5)
    }

    func testCitationVelocityZeroCitations() {
        let publication = createPublication(year: 2020, citationCount: 0)

        let score = FeatureExtractor.citationVelocityScore(publication)

        XCTAssertEqual(score, 0.0)
    }

    // MARK: - Muted Penalty Tests

    func testMutedAuthorPenaltyNoMutes() {
        let publication = createPublication(author: "Einstein")

        let penalty = FeatureExtractor.mutedAuthorPenalty(publication)

        // No mutes should result in no penalty
        XCTAssertEqual(penalty, 0.0)
    }

    func testMutedCategoryPenaltyNoMutes() {
        let publication = createPublication()
        publication.fields = ["primaryclass": "astro-ph.CO"]

        let penalty = FeatureExtractor.mutedCategoryPenalty(publication)

        // No mutes should result in no penalty
        XCTAssertEqual(penalty, 0.0)
    }

    // MARK: - Author Coauthorship Tests

    func testAuthorCoauthorshipNoLibrary() {
        let publication = createPublication(author: "Einstein")

        let score = FeatureExtractor.authorCoauthorshipScore(publication, library: nil)

        // No library means no coauthorship score
        XCTAssertEqual(score, 0.0)
    }

    // MARK: - Full Feature Extraction Tests

    func testExtractReturnsAllFeatures() {
        let publication = createPublication()

        let features = FeatureExtractor.extract(
            from: publication,
            profile: nil,
            library: nil
        )

        // Should have a value for every feature type
        for featureType in FeatureType.allCases {
            XCTAssertNotNil(features[featureType], "Missing feature: \(featureType)")
        }
    }

    func testExtractValuesInExpectedRange() {
        let publication = createPublication()

        let features = FeatureExtractor.extract(
            from: publication,
            profile: nil,
            library: nil
        )

        // Most values should be in [-1, 1] range
        for (feature, value) in features {
            XCTAssertGreaterThanOrEqual(value, -1.0, "Value for \(feature) below -1")
            XCTAssertLessThanOrEqual(value, 1.0, "Value for \(feature) above 1")
        }
    }

    // MARK: - Helpers

    private func createPublication(
        author: String = "Test Author",
        year: Int = 2020,
        citationCount: Int32 = 0
    ) -> CDPublication {
        let publication = CDPublication(context: context)
        publication.id = UUID()
        publication.citeKey = "test\(UUID().uuidString.prefix(8))"
        publication.title = "Test Paper"
        publication.year = Int16(year)
        publication.citationCount = citationCount
        publication.fields = ["author": author]
        publication.dateAdded = Date()
        return publication
    }
}
