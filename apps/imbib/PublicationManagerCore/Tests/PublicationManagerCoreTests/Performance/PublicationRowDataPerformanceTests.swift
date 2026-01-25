//
//  PublicationRowDataPerformanceTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-08.
//

import XCTest
import CoreData
@testable import PublicationManagerCore

/// Performance tests for PublicationRowData conversion.
///
/// PublicationRowData is created from CDPublication to provide a safe, immutable
/// snapshot for SwiftUI list rendering. This conversion extracts 15+ fields
/// including author string formatting, which can be slow for large collections.
@MainActor
final class PublicationRowDataPerformanceTests: XCTestCase {

    // MARK: - Properties

    private var persistenceController: PersistenceController!
    private var publications: [CDPublication]!

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()
        persistenceController = .preview

        // Clean up any existing data
        await MainActor.run {
            PerformanceTestFixtures.cleanup(in: persistenceController.viewContext)
            try? persistenceController.viewContext.save()
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            PerformanceTestFixtures.cleanup(in: persistenceController.viewContext)
            try? persistenceController.viewContext.save()
        }
        publications = nil
        try await super.tearDown()
    }

    // MARK: - Batch Conversion Tests

    /// Test converting 2000 publications to row data.
    func testRowDataConversion_2000Publications() {
        // Given
        publications = PerformanceTestFixtures.createPublications(
            count: PerformanceTestConfiguration.standardCollectionSize,
            in: persistenceController.viewContext
        )
        try? persistenceController.viewContext.save()

        var rowDataArray: [PublicationRowData] = []
        let startTime = CFAbsoluteTimeGetCurrent()

        // When
        measure {
            rowDataArray = []
            for pub in publications {
                if let rowData = PublicationRowData(publication: pub) {
                    rowDataArray.append(rowData)
                }
            }
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let avgIterationTime = elapsed / Double(PerformanceTestConfiguration.measureIterations)

        // Then
        XCTAssertEqual(rowDataArray.count, PerformanceTestConfiguration.standardCollectionSize)
        XCTAssertLessThan(
            avgIterationTime,
            PerformanceThreshold.rowDataConversion.maxSeconds,
            PerformanceThreshold.rowDataConversion.failureMessage(actual: avgIterationTime)
        )

        let perItemMicroseconds = (avgIterationTime * 1_000_000) / Double(publications.count)
        print("Per-item conversion: \(String(format: "%.1f", perItemMicroseconds))µs")
    }

    /// Test conversion using the static `from` method (preferred API).
    func testRowDataConversion_staticMethod() {
        // Given
        publications = PerformanceTestFixtures.createPublications(
            count: PerformanceTestConfiguration.standardCollectionSize,
            in: persistenceController.viewContext
        )
        try? persistenceController.viewContext.save()

        var rowDataArray: [PublicationRowData] = []
        let startTime = CFAbsoluteTimeGetCurrent()

        // When
        measure {
            rowDataArray = PublicationRowData.from(publications)
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let avgIterationTime = elapsed / Double(PerformanceTestConfiguration.measureIterations)

        // Then
        XCTAssertEqual(rowDataArray.count, PerformanceTestConfiguration.standardCollectionSize)
        print("Batch conversion: \(String(format: "%.1f", avgIterationTime * 1000))ms")
    }

    /// Test building a dictionary cache (for O(1) selection lookup).
    func testRowDataCacheBuilding() {
        // Given
        publications = PerformanceTestFixtures.createPublications(
            count: PerformanceTestConfiguration.standardCollectionSize,
            in: persistenceController.viewContext
        )
        try? persistenceController.viewContext.save()

        var cache: [UUID: PublicationRowData] = [:]
        let startTime = CFAbsoluteTimeGetCurrent()

        // When
        measure {
            cache = [:]
            cache.reserveCapacity(publications.count)
            for pub in publications {
                if let rowData = PublicationRowData(publication: pub) {
                    cache[pub.id] = rowData
                }
            }
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let avgIterationTime = elapsed / Double(PerformanceTestConfiguration.measureIterations)

        // Then
        XCTAssertEqual(cache.count, PerformanceTestConfiguration.standardCollectionSize)

        // Cache building should be similar to array conversion
        XCTAssertLessThan(
            avgIterationTime,
            PerformanceThreshold.rowDataConversion.maxSeconds * 1.5, // Allow 50% overhead for dictionary
            "Cache building took \(String(format: "%.1f", avgIterationTime * 1000))ms"
        )
    }

    // MARK: - Many Authors Tests (Stress Test)

    /// Test conversion with many authors per paper (stress author formatting).
    func testRowDataConversion_manyAuthors() {
        // Given - papers with 20 authors each
        publications = PerformanceTestFixtures.createPublicationsWithManyAuthors(
            count: PerformanceTestConfiguration.standardCollectionSize,
            authorsPerPub: 20,
            in: persistenceController.viewContext
        )
        try? persistenceController.viewContext.save()

        var rowDataArray: [PublicationRowData] = []
        let startTime = CFAbsoluteTimeGetCurrent()

        // When
        measure {
            rowDataArray = PublicationRowData.from(publications)
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let avgIterationTime = elapsed / Double(PerformanceTestConfiguration.measureIterations)

        // Then
        XCTAssertEqual(rowDataArray.count, PerformanceTestConfiguration.standardCollectionSize)

        // With many authors, allow 2x the normal time
        XCTAssertLessThan(
            avgIterationTime,
            PerformanceThreshold.rowDataConversion.maxSeconds * 2,
            "Many-author conversion took \(String(format: "%.1f", avgIterationTime * 1000))ms"
        )

        print("Many authors (20/paper): \(String(format: "%.1f", avgIterationTime * 1000))ms")
    }

    // MARK: - Scaling Tests

    /// Test conversion performance at different collection sizes.
    func testRowDataConversionScaling() {
        let sizes = [100, 500, 1000, 2000, 5000]
        var results: [(size: Int, avgMs: Double)] = []

        for size in sizes {
            // Clean and recreate
            PerformanceTestFixtures.cleanup(in: persistenceController.viewContext)

            let pubs = PerformanceTestFixtures.createPublications(
                count: size,
                in: persistenceController.viewContext
            )

            // Measure conversion
            var totalTime: CFAbsoluteTime = 0
            let iterations = 5

            for _ in 0..<iterations {
                let start = CFAbsoluteTimeGetCurrent()
                _ = PublicationRowData.from(pubs)
                totalTime += CFAbsoluteTimeGetCurrent() - start
            }

            let avgMs = (totalTime / Double(iterations)) * 1000
            results.append((size: size, avgMs: avgMs))
            print("Size \(size): \(String(format: "%.1f", avgMs))ms")
        }

        // Verify roughly linear scaling (O(n))
        if let result1000 = results.first(where: { $0.size == 1000 }),
           let result2000 = results.first(where: { $0.size == 2000 }) {
            let scalingFactor = result2000.avgMs / result1000.avgMs
            print("Scaling factor (2000/1000): \(String(format: "%.2f", scalingFactor))x")
            // Should be approximately 2x for O(n) behavior
            XCTAssertGreaterThan(scalingFactor, 1.5, "Expected O(n) scaling")
            XCTAssertLessThan(scalingFactor, 3.0, "Scaling worse than O(n)")
        }
    }

    // MARK: - Incremental Update Tests

    /// Test updating a single row data item (incremental vs full rebuild).
    func testSingleRowDataUpdate() {
        // Given
        publications = PerformanceTestFixtures.createPublications(
            count: PerformanceTestConfiguration.standardCollectionSize,
            in: persistenceController.viewContext
        )
        try? persistenceController.viewContext.save()

        // Pre-build cache
        var cache: [UUID: PublicationRowData] = [:]
        for pub in publications {
            if let rowData = PublicationRowData(publication: pub) {
                cache[pub.id] = rowData
            }
        }

        // Pick random publication to "update"
        let targetPub = publications[publications.count / 2]
        var totalTime: CFAbsoluteTime = 0
        let iterations = 100

        // When - measure single item update
        for _ in 0..<iterations {
            let start = CFAbsoluteTimeGetCurrent()
            if let rowData = PublicationRowData(publication: targetPub) {
                cache[targetPub.id] = rowData
            }
            totalTime += CFAbsoluteTimeGetCurrent() - start
        }

        let avgMicroseconds = (totalTime / Double(iterations)) * 1_000_000

        // Then - single update should be < 1ms
        XCTAssertLessThan(avgMicroseconds, 1000, "Single row data update: \(String(format: "%.1f", avgMicroseconds))µs")
        print("Single update: \(String(format: "%.1f", avgMicroseconds))µs")
    }

    // MARK: - Memory Efficiency Tests

    /// Test that row data conversion doesn't hold Core Data references.
    func testRowDataIndependenceFromCoreData() {
        // Given
        publications = PerformanceTestFixtures.createPublications(
            count: 100,
            in: persistenceController.viewContext
        )
        try? persistenceController.viewContext.save()

        // Convert to row data
        let rowDataArray = PublicationRowData.from(publications)
        let firstRowData = rowDataArray[0]
        let targetID = firstRowData.id

        // Delete all Core Data objects
        for pub in publications {
            persistenceController.viewContext.delete(pub)
        }
        try? persistenceController.viewContext.save()
        publications = nil

        // Then - row data should still be accessible and valid
        XCTAssertEqual(firstRowData.id, targetID)
        XCTAssertFalse(firstRowData.title.isEmpty)
        XCTAssertFalse(firstRowData.authorString.isEmpty)

        // Can still iterate over all row data
        for rowData in rowDataArray {
            XCTAssertFalse(rowData.citeKey.isEmpty)
        }
    }
}
