//
//  CoreDataFetchPerformanceTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-08.
//

import XCTest
import CoreData
@testable import PublicationManagerCore

/// Performance tests for Core Data fetch operations.
///
/// These tests benchmark fetching publications from Core Data with various
/// sort descriptors and predicates. Fetch performance affects initial load
/// time when switching to a collection or library.
@MainActor
final class CoreDataFetchPerformanceTests: XCTestCase {

    // MARK: - Properties

    private var persistenceController: PersistenceController!

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()
        persistenceController = .preview

        // Clean up and create test data
        await MainActor.run {
            PerformanceTestFixtures.cleanup(in: persistenceController.viewContext)

            // Create standard collection size
            _ = PerformanceTestFixtures.createPublications(
                count: PerformanceTestConfiguration.standardCollectionSize,
                in: persistenceController.viewContext
            )
            try? persistenceController.viewContext.save()
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            PerformanceTestFixtures.cleanup(in: persistenceController.viewContext)
            try? persistenceController.viewContext.save()
        }
        try await super.tearDown()
    }

    // MARK: - Basic Fetch Tests

    /// Test fetching all publications (no sorting).
    func testFetchAll_unsorted() {
        let context = persistenceController.viewContext
        let request = NSFetchRequest<CDPublication>(entityName: "Publication")
        var results: [CDPublication] = []

        let startTime = CFAbsoluteTimeGetCurrent()

        measure {
            results = (try? context.fetch(request)) ?? []
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let avgIterationTime = elapsed / Double(PerformanceTestConfiguration.measureIterations)

        XCTAssertEqual(results.count, PerformanceTestConfiguration.standardCollectionSize)
        print("Unsorted fetch: \(String(format: "%.1f", avgIterationTime * 1000))ms")
    }

    /// Test fetching all publications sorted by date added.
    func testFetchAll_sortedByDateAdded() {
        let context = persistenceController.viewContext
        let request = NSFetchRequest<CDPublication>(entityName: "Publication")
        request.sortDescriptors = [NSSortDescriptor(key: "dateAdded", ascending: false)]
        var results: [CDPublication] = []

        let startTime = CFAbsoluteTimeGetCurrent()

        measure {
            results = (try? context.fetch(request)) ?? []
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let avgIterationTime = elapsed / Double(PerformanceTestConfiguration.measureIterations)

        XCTAssertEqual(results.count, PerformanceTestConfiguration.standardCollectionSize)
        XCTAssertLessThan(
            avgIterationTime,
            PerformanceThreshold.coreDataFetch.maxSeconds,
            PerformanceThreshold.coreDataFetch.failureMessage(actual: avgIterationTime)
        )
        print("Date-sorted fetch: \(String(format: "%.1f", avgIterationTime * 1000))ms")
    }

    /// Test fetching sorted by title (string sort is typically slower).
    func testFetchAll_sortedByTitle() {
        let context = persistenceController.viewContext
        let request = NSFetchRequest<CDPublication>(entityName: "Publication")
        request.sortDescriptors = [NSSortDescriptor(key: "title", ascending: true)]
        var results: [CDPublication] = []

        let startTime = CFAbsoluteTimeGetCurrent()

        measure {
            results = (try? context.fetch(request)) ?? []
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let avgIterationTime = elapsed / Double(PerformanceTestConfiguration.measureIterations)

        XCTAssertEqual(results.count, PerformanceTestConfiguration.standardCollectionSize)
        print("Title-sorted fetch: \(String(format: "%.1f", avgIterationTime * 1000))ms")
    }

    /// Test fetching sorted by cite key.
    func testFetchAll_sortedByCiteKey() {
        let context = persistenceController.viewContext
        let request = NSFetchRequest<CDPublication>(entityName: "Publication")
        request.sortDescriptors = [NSSortDescriptor(key: "citeKey", ascending: true)]
        var results: [CDPublication] = []

        let startTime = CFAbsoluteTimeGetCurrent()

        measure {
            results = (try? context.fetch(request)) ?? []
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let avgIterationTime = elapsed / Double(PerformanceTestConfiguration.measureIterations)

        XCTAssertEqual(results.count, PerformanceTestConfiguration.standardCollectionSize)
        print("Cite key-sorted fetch: \(String(format: "%.1f", avgIterationTime * 1000))ms")
    }

    // MARK: - Predicate Fetch Tests

    /// Test fetching with unread filter.
    func testFetch_unreadOnly() {
        let context = persistenceController.viewContext
        let request = NSFetchRequest<CDPublication>(entityName: "Publication")
        request.predicate = NSPredicate(format: "isRead == NO")
        request.sortDescriptors = [NSSortDescriptor(key: "dateAdded", ascending: false)]
        var results: [CDPublication] = []

        let startTime = CFAbsoluteTimeGetCurrent()

        measure {
            results = (try? context.fetch(request)) ?? []
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let avgIterationTime = elapsed / Double(PerformanceTestConfiguration.measureIterations)

        // Should have ~70% unread based on fixture generation
        XCTAssertGreaterThan(results.count, 0)
        print("Unread filter fetch: \(String(format: "%.1f", avgIterationTime * 1000))ms, \(results.count) results")
    }

    /// Test fetching with year range predicate.
    func testFetch_yearRange() {
        let context = persistenceController.viewContext
        let request = NSFetchRequest<CDPublication>(entityName: "Publication")
        request.predicate = NSPredicate(format: "year >= %d AND year <= %d", 2020, 2024)
        request.sortDescriptors = [NSSortDescriptor(key: "year", ascending: false)]
        var results: [CDPublication] = []

        let startTime = CFAbsoluteTimeGetCurrent()

        measure {
            results = (try? context.fetch(request)) ?? []
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let avgIterationTime = elapsed / Double(PerformanceTestConfiguration.measureIterations)

        XCTAssertGreaterThan(results.count, 0)
        print("Year range fetch: \(String(format: "%.1f", avgIterationTime * 1000))ms, \(results.count) results")
    }

    /// Test fetching with title search (CONTAINS predicate).
    func testFetch_titleSearch() {
        let context = persistenceController.viewContext
        let request = NSFetchRequest<CDPublication>(entityName: "Publication")
        request.predicate = NSPredicate(format: "title CONTAINS[cd] %@", "Quantum")
        request.sortDescriptors = [NSSortDescriptor(key: "dateAdded", ascending: false)]
        var results: [CDPublication] = []

        let startTime = CFAbsoluteTimeGetCurrent()

        measure {
            results = (try? context.fetch(request)) ?? []
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let avgIterationTime = elapsed / Double(PerformanceTestConfiguration.measureIterations)

        XCTAssertGreaterThan(results.count, 0)
        print("Title search fetch: \(String(format: "%.1f", avgIterationTime * 1000))ms, \(results.count) results")
    }

    // MARK: - Count Fetch Tests

    /// Test counting publications (faster than fetching all).
    func testFetchCount() {
        let context = persistenceController.viewContext
        let request = NSFetchRequest<CDPublication>(entityName: "Publication")
        var count = 0

        let startTime = CFAbsoluteTimeGetCurrent()

        measure {
            count = (try? context.count(for: request)) ?? 0
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let avgIterationTime = elapsed / Double(PerformanceTestConfiguration.measureIterations)

        XCTAssertEqual(count, PerformanceTestConfiguration.standardCollectionSize)
        print("Count fetch: \(String(format: "%.3f", avgIterationTime * 1000))ms")
    }

    // MARK: - Batch Size Tests

    /// Test fetch with batch size hint.
    func testFetch_withBatchSize() {
        let context = persistenceController.viewContext
        let request = NSFetchRequest<CDPublication>(entityName: "Publication")
        request.sortDescriptors = [NSSortDescriptor(key: "dateAdded", ascending: false)]
        request.fetchBatchSize = 50  // Common page size
        var results: [CDPublication] = []

        let startTime = CFAbsoluteTimeGetCurrent()

        measure {
            results = (try? context.fetch(request)) ?? []
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let avgIterationTime = elapsed / Double(PerformanceTestConfiguration.measureIterations)

        XCTAssertEqual(results.count, PerformanceTestConfiguration.standardCollectionSize)
        print("Batch fetch (50): \(String(format: "%.1f", avgIterationTime * 1000))ms")
    }

    // MARK: - Scaling Tests

    /// Test fetch performance at different collection sizes.
    func testFetchScaling() {
        let sizes = [100, 500, 1000, 2000]
        var results: [(size: Int, avgMs: Double)] = []

        for size in sizes {
            // Clean and recreate
            PerformanceTestFixtures.cleanup(in: persistenceController.viewContext)
            _ = PerformanceTestFixtures.createPublications(
                count: size,
                in: persistenceController.viewContext
            )
            try? persistenceController.viewContext.save()

            let request = NSFetchRequest<CDPublication>(entityName: "Publication")
            request.sortDescriptors = [NSSortDescriptor(key: "dateAdded", ascending: false)]

            var totalTime: CFAbsoluteTime = 0
            let iterations = 10

            for _ in 0..<iterations {
                let start = CFAbsoluteTimeGetCurrent()
                _ = try? persistenceController.viewContext.fetch(request)
                totalTime += CFAbsoluteTimeGetCurrent() - start
            }

            let avgMs = (totalTime / Double(iterations)) * 1000
            results.append((size: size, avgMs: avgMs))
            print("Size \(size): \(String(format: "%.1f", avgMs))ms")
        }

        // Core Data fetch should scale sub-linearly due to indexing
        if let result1000 = results.first(where: { $0.size == 1000 }),
           let result2000 = results.first(where: { $0.size == 2000 }) {
            let scalingFactor = result2000.avgMs / result1000.avgMs
            print("Scaling factor (2000/1000): \(String(format: "%.2f", scalingFactor))x")
        }
    }

    // MARK: - Sort Comparison

    /// Compare different sort descriptor performance.
    func testSortComparison() {
        let context = persistenceController.viewContext
        let sortConfigs: [(name: String, descriptor: NSSortDescriptor)] = [
            ("dateAdded", NSSortDescriptor(key: "dateAdded", ascending: false)),
            ("title", NSSortDescriptor(key: "title", ascending: true)),
            ("citeKey", NSSortDescriptor(key: "citeKey", ascending: true)),
            ("year", NSSortDescriptor(key: "year", ascending: false))
        ]

        for config in sortConfigs {
            let request = NSFetchRequest<CDPublication>(entityName: "Publication")
            request.sortDescriptors = [config.descriptor]

            var totalTime: CFAbsoluteTime = 0
            let iterations = 10

            for _ in 0..<iterations {
                let start = CFAbsoluteTimeGetCurrent()
                _ = try? context.fetch(request)
                totalTime += CFAbsoluteTimeGetCurrent() - start
            }

            let avgMs = (totalTime / Double(iterations)) * 1000
            print("Sort by \(config.name): \(String(format: "%.1f", avgMs))ms")
        }
    }
}
