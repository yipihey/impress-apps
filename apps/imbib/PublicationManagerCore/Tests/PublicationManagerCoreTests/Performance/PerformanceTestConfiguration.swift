//
//  PerformanceTestConfiguration.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-08.
//

import Foundation

/// Configuration for performance test thresholds and settings.
public enum PerformanceTestConfiguration {

    // MARK: - Collection Sizes

    /// Standard collection size for most tests (matches reported issue)
    public static let standardCollectionSize = 2000

    /// Large collection size for stress testing
    public static let largeCollectionSize = 5000

    /// Small collection for baseline comparison
    public static let smallCollectionSize = 100

    // MARK: - Time Thresholds (in seconds)

    /// Maximum acceptable time for single paper selection lookup.
    /// This is the critical path for UI responsiveness when clicking papers.
    /// Target: < 100ms for imperceptible delay
    public static let selectionLookupMaxSeconds = 0.1

    /// Maximum acceptable time to convert all CDPublications to PublicationRowData.
    /// This happens when switching to a collection or after data changes.
    /// Target: < 500ms for 2000 items (0.25ms per item)
    public static let rowDataConversionMaxSeconds = 0.5

    /// Maximum acceptable time for Core Data fetch with sorting.
    /// Target: < 300ms for 2000 items
    public static let coreDataFetchMaxSeconds = 0.3

    /// Maximum acceptable time for filtering operations (unread, search).
    /// Target: < 200ms for 2000 items
    public static let filterOperationMaxSeconds = 0.2

    /// Maximum acceptable time for sort operations.
    /// Target: < 300ms for 2000 items
    public static let sortOperationMaxSeconds = 0.3

    // MARK: - Derived Thresholds

    /// Per-item thresholds (for scaling tests)
    public enum PerItem {
        /// Max time per publication for row data conversion
        public static let rowDataConversionMicroseconds: Double = 250  // 0.25ms

        /// Max time per publication for selection scan
        public static let selectionLookupMicroseconds: Double = 50  // 0.05ms
    }

    // MARK: - Test Parameters

    /// Number of iterations for measure blocks (XCTest default is 10)
    public static let measureIterations = 10

    /// Number of warm-up iterations before measurement
    public static let warmUpIterations = 2
}

// MARK: - Threshold Helper

/// Helper for asserting performance thresholds in tests.
public struct PerformanceThreshold {
    /// Maximum absolute time in seconds
    public let maxSeconds: Double

    /// Description for failure messages
    public let description: String

    /// Collection size this threshold applies to
    public let collectionSize: Int

    public init(maxSeconds: Double, description: String, collectionSize: Int = PerformanceTestConfiguration.standardCollectionSize) {
        self.maxSeconds = maxSeconds
        self.description = description
        self.collectionSize = collectionSize
    }

    /// Format failure message with actual vs expected
    public func failureMessage(actual: Double) -> String {
        let actualMs = actual * 1000
        let maxMs = maxSeconds * 1000
        return "\(description) took \(String(format: "%.1f", actualMs))ms, exceeds threshold of \(String(format: "%.1f", maxMs))ms for \(collectionSize) items"
    }
}

// MARK: - Standard Thresholds

extension PerformanceThreshold {
    /// Selection lookup threshold (100ms)
    public static let selectionLookup = PerformanceThreshold(
        maxSeconds: PerformanceTestConfiguration.selectionLookupMaxSeconds,
        description: "Selection lookup"
    )

    /// Row data conversion threshold (500ms)
    public static let rowDataConversion = PerformanceThreshold(
        maxSeconds: PerformanceTestConfiguration.rowDataConversionMaxSeconds,
        description: "Row data conversion"
    )

    /// Core Data fetch threshold (300ms)
    public static let coreDataFetch = PerformanceThreshold(
        maxSeconds: PerformanceTestConfiguration.coreDataFetchMaxSeconds,
        description: "Core Data fetch"
    )

    /// Filter operation threshold (200ms)
    public static let filterOperation = PerformanceThreshold(
        maxSeconds: PerformanceTestConfiguration.filterOperationMaxSeconds,
        description: "Filter operation"
    )

    /// Sort operation threshold (300ms)
    public static let sortOperation = PerformanceThreshold(
        maxSeconds: PerformanceTestConfiguration.sortOperationMaxSeconds,
        description: "Sort operation"
    )
}
