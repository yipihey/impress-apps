//
//  SessionCacheTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-04.
//

import XCTest
@testable import PublicationManagerCore

final class SessionCacheTests: XCTestCase {

    // MARK: - Search Results Caching

    func testCacheSearchResults_storesResults() async {
        let cache = SessionCache.shared
        let results = [
            createMockSearchResult(id: "1", title: "Test Paper 1"),
            createMockSearchResult(id: "2", title: "Test Paper 2")
        ]

        // Cache results
        await cache.cacheSearchResults(results, for: "test query", sourceIDs: ["arxiv"])

        // Retrieve cached results
        let cached = await cache.getCachedResults(for: "test query", sourceIDs: ["arxiv"])

        XCTAssertNotNil(cached)
        XCTAssertEqual(cached?.count, 2)
    }

    func testCacheSearchResults_returnsNilForDifferentQuery() async {
        let cache = SessionCache.shared
        let results = [createMockSearchResult(id: "1", title: "Test")]

        await cache.cacheSearchResults(results, for: "query A", sourceIDs: ["arxiv"])

        // Different query should not return cached results
        let cached = await cache.getCachedResults(for: "query B", sourceIDs: ["arxiv"])

        XCTAssertNil(cached)
    }

    func testCacheSearchResults_caseInsensitiveQuery() async {
        let cache = SessionCache.shared
        let results = [createMockSearchResult(id: "1", title: "Test")]

        await cache.cacheSearchResults(results, for: "Machine Learning", sourceIDs: ["arxiv"])

        // Same query with different case should match
        let cached = await cache.getCachedResults(for: "machine learning", sourceIDs: ["arxiv"])

        XCTAssertNotNil(cached)
    }

    func testCacheSearchResults_differentSourceIDsAreSeparate() async {
        let cache = SessionCache.shared

        let arxivResults = [createMockSearchResult(id: "arxiv1", title: "ArXiv Paper")]
        let adsResults = [createMockSearchResult(id: "ads1", title: "ADS Paper")]

        await cache.cacheSearchResults(arxivResults, for: "quantum", sourceIDs: ["arxiv"])
        await cache.cacheSearchResults(adsResults, for: "quantum", sourceIDs: ["ads"])

        let arxivCached = await cache.getCachedResults(for: "quantum", sourceIDs: ["arxiv"])
        let adsCached = await cache.getCachedResults(for: "quantum", sourceIDs: ["ads"])

        XCTAssertEqual(arxivCached?.count, 1)
        XCTAssertEqual(adsCached?.count, 1)
        XCTAssertEqual(arxivCached?.first?.id, "arxiv1")
        XCTAssertEqual(adsCached?.first?.id, "ads1")
    }

    // MARK: - Cache Configuration Tests

    func testCacheConfiguration_constants() {
        XCTAssertEqual(SessionCache.maxSearchResults, 50)
        XCTAssertEqual(SessionCache.maxResultAge, 3600) // 1 hour
    }

    // MARK: - Clear All Tests

    func testClearAll_removesSearchResults() async {
        let cache = SessionCache.shared
        let results = [createMockSearchResult(id: "1", title: "Test")]

        await cache.cacheSearchResults(results, for: "clear test", sourceIDs: ["arxiv"])

        // Verify it's cached
        let beforeClear = await cache.getCachedResults(for: "clear test", sourceIDs: ["arxiv"])
        XCTAssertNotNil(beforeClear)

        // Clear all
        await cache.clearAll()

        // Should be gone
        let afterClear = await cache.getCachedResults(for: "clear test", sourceIDs: ["arxiv"])
        XCTAssertNil(afterClear)
    }

    // MARK: - Helper Methods

    private func createMockSearchResult(id: String, title: String) -> SearchResult {
        SearchResult(
            id: id,
            sourceID: "mock",
            title: title,
            authors: ["Test Author"],
            year: 2020,
            venue: "Test Journal",
            abstract: "Test abstract"
        )
    }
}
