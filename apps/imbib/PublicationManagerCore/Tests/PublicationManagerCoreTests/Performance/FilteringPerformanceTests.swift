//
//  FilteringPerformanceTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-08.
//

import XCTest
import CoreData
@testable import PublicationManagerCore

/// Performance tests for in-memory filtering and sorting operations.
///
/// These tests benchmark operations on PublicationRowData arrays, which
/// represent the common case of filtering/sorting already-fetched data.
@MainActor
final class FilteringPerformanceTests: XCTestCase {

    // MARK: - Properties

    private var persistenceController: PersistenceController!
    private var rowDataArray: [PublicationRowData]!

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()
        persistenceController = .preview

        // Clean up and create test data
        await MainActor.run {
            PerformanceTestFixtures.cleanup(in: persistenceController.viewContext)

            let publications = PerformanceTestFixtures.createPublications(
                count: PerformanceTestConfiguration.standardCollectionSize,
                in: persistenceController.viewContext
            )
            try? persistenceController.viewContext.save()

            // Pre-convert to row data for filtering tests
            rowDataArray = PublicationRowData.from(publications)
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            PerformanceTestFixtures.cleanup(in: persistenceController.viewContext)
            try? persistenceController.viewContext.save()
        }
        rowDataArray = nil
        try await super.tearDown()
    }

    // MARK: - Filter Tests

    /// Test filtering for unread publications.
    func testFilterUnread() {
        var filtered: [PublicationRowData] = []

        let startTime = CFAbsoluteTimeGetCurrent()

        measure {
            filtered = rowDataArray.filter { !$0.isRead }
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let avgIterationTime = elapsed / Double(PerformanceTestConfiguration.measureIterations)

        // About 70% should be unread
        XCTAssertGreaterThan(filtered.count, 0)
        XCTAssertLessThan(
            avgIterationTime,
            PerformanceThreshold.filterOperation.maxSeconds,
            PerformanceThreshold.filterOperation.failureMessage(actual: avgIterationTime)
        )
        print("Unread filter: \(String(format: "%.1f", avgIterationTime * 1000))ms, \(filtered.count) results")
    }

    /// Test filtering for publications with PDFs.
    func testFilterHasPDF() {
        var filtered: [PublicationRowData] = []

        let startTime = CFAbsoluteTimeGetCurrent()

        measure {
            filtered = rowDataArray.filter { $0.hasPDFAvailable }
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let avgIterationTime = elapsed / Double(PerformanceTestConfiguration.measureIterations)

        print("Has PDF filter: \(String(format: "%.1f", avgIterationTime * 1000))ms, \(filtered.count) results")
    }

    /// Test text search filtering (title contains).
    func testSearchFilter_title() {
        var filtered: [PublicationRowData] = []

        let startTime = CFAbsoluteTimeGetCurrent()

        measure {
            filtered = rowDataArray.filter {
                $0.title.localizedCaseInsensitiveContains("Quantum")
            }
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let avgIterationTime = elapsed / Double(PerformanceTestConfiguration.measureIterations)

        XCTAssertGreaterThan(filtered.count, 0)
        XCTAssertLessThan(
            avgIterationTime,
            PerformanceThreshold.filterOperation.maxSeconds,
            PerformanceThreshold.filterOperation.failureMessage(actual: avgIterationTime)
        )
        print("Title search filter: \(String(format: "%.1f", avgIterationTime * 1000))ms, \(filtered.count) results")
    }

    /// Test text search filtering (author contains).
    func testSearchFilter_author() {
        var filtered: [PublicationRowData] = []

        let startTime = CFAbsoluteTimeGetCurrent()

        measure {
            filtered = rowDataArray.filter {
                $0.authorString.localizedCaseInsensitiveContains("Einstein")
            }
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let avgIterationTime = elapsed / Double(PerformanceTestConfiguration.measureIterations)

        XCTAssertGreaterThan(filtered.count, 0)
        print("Author search filter: \(String(format: "%.1f", avgIterationTime * 1000))ms, \(filtered.count) results")
    }

    /// Test combined filter (title OR author).
    func testSearchFilter_combined() {
        let searchTerm = "quantum"
        var filtered: [PublicationRowData] = []

        let startTime = CFAbsoluteTimeGetCurrent()

        measure {
            filtered = rowDataArray.filter {
                $0.title.localizedCaseInsensitiveContains(searchTerm) ||
                $0.authorString.localizedCaseInsensitiveContains(searchTerm) ||
                ($0.abstract?.localizedCaseInsensitiveContains(searchTerm) ?? false)
            }
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let avgIterationTime = elapsed / Double(PerformanceTestConfiguration.measureIterations)

        XCTAssertGreaterThan(filtered.count, 0)
        print("Combined search filter: \(String(format: "%.1f", avgIterationTime * 1000))ms, \(filtered.count) results")
    }

    /// Test year range filter.
    func testFilterByYearRange() {
        var filtered: [PublicationRowData] = []

        let startTime = CFAbsoluteTimeGetCurrent()

        measure {
            filtered = rowDataArray.filter { rowData in
                guard let year = rowData.year else { return false }
                return year >= 2020 && year <= 2024
            }
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let avgIterationTime = elapsed / Double(PerformanceTestConfiguration.measureIterations)

        XCTAssertGreaterThan(filtered.count, 0)
        print("Year range filter: \(String(format: "%.1f", avgIterationTime * 1000))ms, \(filtered.count) results")
    }

    // MARK: - Sort Tests

    /// Test sorting by date added (descending).
    func testSortByDateAdded() {
        var sorted: [PublicationRowData] = []

        let startTime = CFAbsoluteTimeGetCurrent()

        measure {
            sorted = rowDataArray.sorted { $0.dateAdded > $1.dateAdded }
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let avgIterationTime = elapsed / Double(PerformanceTestConfiguration.measureIterations)

        XCTAssertEqual(sorted.count, rowDataArray.count)
        XCTAssertLessThan(
            avgIterationTime,
            PerformanceThreshold.sortOperation.maxSeconds,
            PerformanceThreshold.sortOperation.failureMessage(actual: avgIterationTime)
        )
        print("Sort by date: \(String(format: "%.1f", avgIterationTime * 1000))ms")
    }

    /// Test sorting by title (alphabetical).
    func testSortByTitle() {
        var sorted: [PublicationRowData] = []

        let startTime = CFAbsoluteTimeGetCurrent()

        measure {
            sorted = rowDataArray.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let avgIterationTime = elapsed / Double(PerformanceTestConfiguration.measureIterations)

        XCTAssertEqual(sorted.count, rowDataArray.count)
        print("Sort by title: \(String(format: "%.1f", avgIterationTime * 1000))ms")
    }

    /// Test sorting by author.
    func testSortByAuthor() {
        var sorted: [PublicationRowData] = []

        let startTime = CFAbsoluteTimeGetCurrent()

        measure {
            sorted = rowDataArray.sorted {
                $0.authorString.localizedCompare($1.authorString) == .orderedAscending
            }
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let avgIterationTime = elapsed / Double(PerformanceTestConfiguration.measureIterations)

        XCTAssertEqual(sorted.count, rowDataArray.count)
        print("Sort by author: \(String(format: "%.1f", avgIterationTime * 1000))ms")
    }

    /// Test sorting by year (descending).
    func testSortByYear() {
        var sorted: [PublicationRowData] = []

        let startTime = CFAbsoluteTimeGetCurrent()

        measure {
            sorted = rowDataArray.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let avgIterationTime = elapsed / Double(PerformanceTestConfiguration.measureIterations)

        XCTAssertEqual(sorted.count, rowDataArray.count)
        print("Sort by year: \(String(format: "%.1f", avgIterationTime * 1000))ms")
    }

    /// Test sorting by citation count (descending).
    func testSortByCitationCount() {
        var sorted: [PublicationRowData] = []

        let startTime = CFAbsoluteTimeGetCurrent()

        measure {
            sorted = rowDataArray.sorted { $0.citationCount > $1.citationCount }
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let avgIterationTime = elapsed / Double(PerformanceTestConfiguration.measureIterations)

        XCTAssertEqual(sorted.count, rowDataArray.count)
        print("Sort by citations: \(String(format: "%.1f", avgIterationTime * 1000))ms")
    }

    // MARK: - Combined Filter + Sort Tests

    /// Test filtering then sorting (common UI pattern).
    func testFilterThenSort() {
        var result: [PublicationRowData] = []

        let startTime = CFAbsoluteTimeGetCurrent()

        measure {
            result = rowDataArray
                .filter { !$0.isRead }
                .sorted { $0.dateAdded > $1.dateAdded }
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let avgIterationTime = elapsed / Double(PerformanceTestConfiguration.measureIterations)

        XCTAssertGreaterThan(result.count, 0)
        print("Filter + Sort: \(String(format: "%.1f", avgIterationTime * 1000))ms")
    }

    /// Test search filter then sort (search bar interaction).
    func testSearchThenSort() {
        let searchTerm = "Galaxy"
        var result: [PublicationRowData] = []

        let startTime = CFAbsoluteTimeGetCurrent()

        measure {
            result = rowDataArray
                .filter {
                    $0.title.localizedCaseInsensitiveContains(searchTerm) ||
                    $0.authorString.localizedCaseInsensitiveContains(searchTerm)
                }
                .sorted { $0.dateAdded > $1.dateAdded }
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let avgIterationTime = elapsed / Double(PerformanceTestConfiguration.measureIterations)

        print("Search + Sort: \(String(format: "%.1f", avgIterationTime * 1000))ms, \(result.count) results")
    }

    // MARK: - Computed Property Simulation

    /// Test simulating the filteredRowData computed property pattern.
    ///
    /// This simulates what happens when the UI re-renders and needs to
    /// recompute the filtered list.
    func testFilteredRowDataComputedProperty() {
        let filter: LibrarySortOrder = .dateAdded
        let showUnreadOnly = true
        let searchText = ""

        var result: [PublicationRowData] = []

        let startTime = CFAbsoluteTimeGetCurrent()

        measure {
            // Simulate filteredRowData computed property
            var filtered: [PublicationRowData] = rowDataArray

            // Apply unread filter
            if showUnreadOnly {
                filtered = filtered.filter { !$0.isRead }
            }

            // Apply search filter
            if !searchText.isEmpty {
                let searchLower = searchText.lowercased()
                filtered = filtered.filter {
                    $0.title.lowercased().contains(searchLower) ||
                    $0.authorString.lowercased().contains(searchLower)
                }
            }

            // Apply sort
            switch filter {
            case .dateAdded:
                result = filtered.sorted { $0.dateAdded > $1.dateAdded }
            case .title:
                result = filtered.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
            case .author:
                result = filtered.sorted { $0.authorString.localizedCompare($1.authorString) == .orderedAscending }
            case .year:
                result = filtered.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
            case .citeKey:
                result = filtered.sorted { $0.citeKey.localizedCompare($1.citeKey) == .orderedAscending }
            }
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let avgIterationTime = elapsed / Double(PerformanceTestConfiguration.measureIterations)

        XCTAssertGreaterThan(result.count, 0)
        print("Computed property simulation: \(String(format: "%.1f", avgIterationTime * 1000))ms")
    }

    // MARK: - Scaling Tests

    /// Test filter/sort performance at different collection sizes.
    func testFilterSortScaling() {
        let sizes = [100, 500, 1000, 2000]
        var results: [(size: Int, filterMs: Double, sortMs: Double)] = []

        for size in sizes {
            // Clean and recreate
            PerformanceTestFixtures.cleanup(in: persistenceController.viewContext)

            let publications = PerformanceTestFixtures.createPublications(
                count: size,
                in: persistenceController.viewContext
            )
            try? persistenceController.viewContext.save()

            let testData = PublicationRowData.from(publications)

            // Measure filter
            var filterTime: CFAbsoluteTime = 0
            let iterations = 10
            for _ in 0..<iterations {
                let start = CFAbsoluteTimeGetCurrent()
                _ = testData.filter { !$0.isRead }
                filterTime += CFAbsoluteTimeGetCurrent() - start
            }
            let avgFilterMs = (filterTime / Double(iterations)) * 1000

            // Measure sort
            var sortTime: CFAbsoluteTime = 0
            for _ in 0..<iterations {
                let start = CFAbsoluteTimeGetCurrent()
                _ = testData.sorted { $0.dateAdded > $1.dateAdded }
                sortTime += CFAbsoluteTimeGetCurrent() - start
            }
            let avgSortMs = (sortTime / Double(iterations)) * 1000

            results.append((size: size, filterMs: avgFilterMs, sortMs: avgSortMs))
            print("Size \(size): filter \(String(format: "%.1f", avgFilterMs))ms, sort \(String(format: "%.1f", avgSortMs))ms")
        }

        // Check O(n) scaling for filter
        if let result1000 = results.first(where: { $0.size == 1000 }),
           let result2000 = results.first(where: { $0.size == 2000 }) {
            let filterScaling = result2000.filterMs / result1000.filterMs
            print("Filter scaling (2000/1000): \(String(format: "%.2f", filterScaling))x")
            XCTAssertLessThan(filterScaling, 3.0, "Filter scaling worse than O(n)")
        }

        // Check O(n log n) scaling for sort
        if let result1000 = results.first(where: { $0.size == 1000 }),
           let result2000 = results.first(where: { $0.size == 2000 }) {
            let sortScaling = result2000.sortMs / result1000.sortMs
            print("Sort scaling (2000/1000): \(String(format: "%.2f", sortScaling))x")
            // O(n log n) should be ~2.1-2.2x for 2x data
            XCTAssertLessThan(sortScaling, 4.0, "Sort scaling worse than O(n log n)")
        }
    }
}

// MARK: - LibrarySortOrder (for test compatibility)

/// Sort order enum matching the app's LibrarySortOrder.
private enum LibrarySortOrder {
    case dateAdded
    case title
    case author
    case year
    case citeKey
}
