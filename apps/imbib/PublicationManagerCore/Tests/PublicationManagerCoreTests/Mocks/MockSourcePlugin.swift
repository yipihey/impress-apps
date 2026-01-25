//
//  MockSourcePlugin.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-04.
//

import Foundation
@testable import PublicationManagerCore

/// Configurable mock source plugin for testing.
public actor MockSourcePlugin: SourcePlugin {

    // MARK: - Metadata

    public nonisolated let metadata: SourceMetadata

    // MARK: - Configuration

    /// Results to return from search
    public var searchResults: [SearchResult] = []

    /// Error to throw from search (if set)
    public var searchError: Error?

    /// BibTeX entries to return (keyed by result ID)
    public var bibtexEntries: [String: BibTeXEntry] = [:]

    /// Error to throw from fetchBibTeX (if set)
    public var fetchBibTeXError: Error?

    /// Delay to simulate network latency (in seconds)
    public var searchDelay: TimeInterval = 0

    // MARK: - Call Tracking

    public private(set) var searchCallCount = 0
    public private(set) var lastSearchQuery: String?
    public private(set) var fetchBibTeXCallCount = 0
    public private(set) var lastFetchedResultID: String?

    // MARK: - Initialization

    public init(
        id: String = "mock",
        name: String = "Mock Source",
        credentialRequirement: CredentialRequirement = .none
    ) {
        self.metadata = SourceMetadata(
            id: id,
            name: name,
            description: "Mock source for testing",
            rateLimit: RateLimit(requestsPerInterval: 100, intervalSeconds: 1),
            credentialRequirement: credentialRequirement,
            registrationURL: nil,
            deduplicationPriority: 999,
            iconName: "questionmark.circle"
        )
    }

    // MARK: - SourcePlugin Methods

    public func search(query: String, maxResults: Int = 50) async throws -> [SearchResult] {
        searchCallCount += 1
        lastSearchQuery = query

        if searchDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(searchDelay * 1_000_000_000))
        }

        if let error = searchError {
            throw error
        }

        return Array(searchResults.prefix(maxResults))
    }

    public func fetchBibTeX(for result: SearchResult) async throws -> BibTeXEntry {
        fetchBibTeXCallCount += 1
        lastFetchedResultID = result.id

        if let error = fetchBibTeXError {
            throw error
        }

        if let entry = bibtexEntries[result.id] {
            return entry
        }

        // Generate default entry from result
        return BibTeXEntry(
            citeKey: result.id,
            entryType: "article",
            fields: [
                "title": result.title,
                "author": result.authors.joined(separator: " and "),
                "year": result.year.map(String.init) ?? ""
            ],
            rawBibTeX: nil
        )
    }

    public nonisolated func normalize(_ entry: BibTeXEntry) -> BibTeXEntry {
        // Return entry unchanged by default
        entry
    }

    // MARK: - Test Helpers

    /// Reset all tracked state
    public func reset() {
        searchResults = []
        searchError = nil
        bibtexEntries = [:]
        fetchBibTeXError = nil
        searchDelay = 0
        searchCallCount = 0
        lastSearchQuery = nil
        fetchBibTeXCallCount = 0
        lastFetchedResultID = nil
    }

    /// Configure search to return specific results
    public func setSearchResults(_ results: [SearchResult]) {
        self.searchResults = results
    }

    /// Configure search to throw an error
    public func setSearchError(_ error: Error) {
        self.searchError = error
    }

    /// Add a BibTeX entry for a result
    public func setBibTeXEntry(_ entry: BibTeXEntry, for resultID: String) {
        bibtexEntries[resultID] = entry
    }
}

// MARK: - Factory Helpers

extension MockSourcePlugin {
    /// Create a mock plugin with pre-configured results
    public static func withResults(_ results: [SearchResult], id: String = "mock") -> MockSourcePlugin {
        let plugin = MockSourcePlugin(id: id)
        Task { await plugin.setSearchResults(results) }
        return plugin
    }

    /// Create sample search results for testing
    public static func sampleSearchResults(count: Int = 3, sourceID: String = "mock") -> [SearchResult] {
        (0..<count).map { i in
            SearchResult(
                id: "\(sourceID)-result-\(i)",
                sourceID: sourceID,
                title: "Sample Paper \(i + 1): A Study of Testing",
                authors: ["Author \(i + 1), First", "Coauthor, Second"],
                year: 2020 + i,
                venue: "Journal of Mock Research",
                abstract: "This is a sample abstract for paper \(i + 1).",
                doi: "10.1234/mock.\(i)",
                arxivID: nil,
                pmid: nil,
                bibcode: nil,
                semanticScholarID: nil,
                openAlexID: nil,
                pdfURL: nil,
                webURL: URL(string: "https://example.com/paper/\(i)"),
                bibtexURL: nil
            )
        }
    }
}
