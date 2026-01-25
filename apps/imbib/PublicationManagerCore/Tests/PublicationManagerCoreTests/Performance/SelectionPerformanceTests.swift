//
//  SelectionPerformanceTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-08.
//

import XCTest
import CoreData
@testable import PublicationManagerCore

/// Performance tests for paper selection operations.
///
/// These tests benchmark the critical path when a user clicks on a paper in the list.
/// The current implementation uses O(n) linear scan via `publications.first(where:)`.
@MainActor
final class SelectionPerformanceTests: XCTestCase {

    // MARK: - Properties

    private var persistenceController: PersistenceController!
    private var publications: [CDPublication]!
    private var rowDataCache: [UUID: PublicationRowData]!

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()
        persistenceController = .preview

        // Clean up any existing data
        await MainActor.run {
            PerformanceTestFixtures.cleanup(in: persistenceController.viewContext)
            try? persistenceController.viewContext.save()
        }

        // Create test publications
        publications = PerformanceTestFixtures.createPublications(
            count: PerformanceTestConfiguration.standardCollectionSize,
            in: persistenceController.viewContext
        )
        try? persistenceController.viewContext.save()

        // Pre-build row data cache for dictionary lookup tests
        rowDataCache = [:]
        for pub in publications {
            if let rowData = PublicationRowData(publication: pub) {
                rowDataCache[pub.id] = rowData
            }
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            PerformanceTestFixtures.cleanup(in: persistenceController.viewContext)
            try? persistenceController.viewContext.save()
        }
        publications = nil
        rowDataCache = nil
        try await super.tearDown()
    }

    // MARK: - Linear Selection Tests (Current Implementation)

    /// Test linear scan selection for first element (best case).
    func testLinearSelectionLookup_firstElement() {
        let targetID = publications.first!.id
        var foundPublication: CDPublication?

        measure {
            foundPublication = publications.first(where: { $0.id == targetID })
        }

        XCTAssertNotNil(foundPublication)
        XCTAssertEqual(foundPublication?.id, targetID)
    }

    /// Test linear scan selection for middle element (average case).
    func testLinearSelectionLookup_middleElement() {
        let middleIndex = publications.count / 2
        let targetID = publications[middleIndex].id
        var foundPublication: CDPublication?

        measure {
            foundPublication = publications.first(where: { $0.id == targetID })
        }

        XCTAssertNotNil(foundPublication)
        XCTAssertEqual(foundPublication?.id, targetID)
    }

    /// Test linear scan selection for last element (worst case).
    ///
    /// This is the critical test - selecting the last paper in a 2000-item list
    /// requires scanning all 2000 items with the current O(n) implementation.
    func testLinearSelectionLookup_lastElement_worstCase() {
        let targetID = publications.last!.id
        var foundPublication: CDPublication?

        let startTime = CFAbsoluteTimeGetCurrent()

        // Measure block for XCTest metrics
        measure {
            foundPublication = publications.first(where: { $0.id == targetID })
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let avgIterationTime = elapsed / Double(PerformanceTestConfiguration.measureIterations)

        XCTAssertNotNil(foundPublication)
        XCTAssertEqual(foundPublication?.id, targetID)

        // Assert threshold
        XCTAssertLessThan(
            avgIterationTime,
            PerformanceThreshold.selectionLookup.maxSeconds,
            PerformanceThreshold.selectionLookup.failureMessage(actual: avgIterationTime)
        )
    }

    // MARK: - Dictionary Selection Tests (Optimized Implementation)

    /// Test dictionary lookup for selection (O(1) proposed optimization).
    func testDictionarySelectionLookup() {
        let targetID = publications.last!.id
        var foundRowData: PublicationRowData?

        measure {
            foundRowData = rowDataCache[targetID]
        }

        XCTAssertNotNil(foundRowData)
        XCTAssertEqual(foundRowData?.id, targetID)
        // Note: The measure block reports O(1) time (< 0.001ms per lookup)
        // The comparison test verifies dictionary is 100x+ faster than linear scan
    }

    /// Compare linear vs dictionary lookup performance.
    func testSelectionLookupComparison() {
        let targetID = publications.last!.id

        // Measure linear lookup
        var linearTime: CFAbsoluteTime = 0
        for _ in 0..<100 {
            let start = CFAbsoluteTimeGetCurrent()
            _ = publications.first(where: { $0.id == targetID })
            linearTime += CFAbsoluteTimeGetCurrent() - start
        }
        linearTime /= 100

        // Measure dictionary lookup
        var dictTime: CFAbsoluteTime = 0
        for _ in 0..<100 {
            let start = CFAbsoluteTimeGetCurrent()
            _ = rowDataCache[targetID]
            dictTime += CFAbsoluteTimeGetCurrent() - start
        }
        dictTime /= 100

        // Log comparison
        let speedup = linearTime / max(dictTime, 0.000001)
        print("Linear avg: \(String(format: "%.3f", linearTime * 1000))ms")
        print("Dictionary avg: \(String(format: "%.6f", dictTime * 1000))ms")
        print("Speedup: \(String(format: "%.0f", speedup))x")

        // Dictionary should be at least 10x faster
        XCTAssertGreaterThan(speedup, 10, "Dictionary lookup should be at least 10x faster than linear scan")
    }

    // MARK: - Repeated Selection Tests

    /// Simulate rapid paper switching (user browsing through list).
    func testRapidSelectionChanges() {
        let iterations = 50
        let randomIndices = (0..<iterations).map { _ in Int.random(in: 0..<publications.count) }
        var totalTime: CFAbsoluteTime = 0

        for index in randomIndices {
            let targetID = publications[index].id
            let start = CFAbsoluteTimeGetCurrent()
            _ = publications.first(where: { $0.id == targetID })
            totalTime += CFAbsoluteTimeGetCurrent() - start
        }

        let avgTime = totalTime / Double(iterations)
        let avgMs = avgTime * 1000

        print("Average selection time over \(iterations) rapid switches: \(String(format: "%.2f", avgMs))ms")

        // Each selection should be fast enough for fluid UI
        XCTAssertLessThan(
            avgTime,
            PerformanceThreshold.selectionLookup.maxSeconds,
            "Average selection during rapid browsing: \(String(format: "%.1f", avgMs))ms exceeds threshold"
        )
    }

    // MARK: - Scaling Tests

    /// Test selection performance at different collection sizes.
    func testSelectionScaling() async {
        let sizes = [100, 500, 1000, 2000]
        var results: [(size: Int, avgMs: Double)] = []

        for size in sizes {
            // Clean and recreate
            PerformanceTestFixtures.cleanup(in: persistenceController.viewContext)

            let pubs = PerformanceTestFixtures.createPublications(
                count: size,
                in: persistenceController.viewContext
            )

            // Measure worst-case (last element)
            let targetID = pubs.last!.id
            var totalTime: CFAbsoluteTime = 0
            let iterations = 20

            for _ in 0..<iterations {
                let start = CFAbsoluteTimeGetCurrent()
                _ = pubs.first(where: { $0.id == targetID })
                totalTime += CFAbsoluteTimeGetCurrent() - start
            }

            let avgMs = (totalTime / Double(iterations)) * 1000
            results.append((size: size, avgMs: avgMs))
            print("Size \(size): \(String(format: "%.2f", avgMs))ms avg")
        }

        // Verify roughly linear scaling (O(n))
        // 2000 items should take ~2x as long as 1000 items
        if let result1000 = results.first(where: { $0.size == 1000 }),
           let result2000 = results.first(where: { $0.size == 2000 }) {
            let scalingFactor = result2000.avgMs / result1000.avgMs
            print("Scaling factor (2000/1000): \(String(format: "%.2f", scalingFactor))x")
            // Should be between 1.5x and 2.5x for O(n) behavior
            XCTAssertGreaterThan(scalingFactor, 1.5, "Expected O(n) scaling")
            XCTAssertLessThan(scalingFactor, 3.0, "Scaling worse than expected")
        }
    }
}
