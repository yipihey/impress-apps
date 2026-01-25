//
//  HelpSearchViewModel.swift
//  PublicationManagerCore
//
//  View model for help search functionality.
//

import Foundation
import SwiftUI
import OSLog
import Combine

private let logger = Logger(subsystem: "com.imbib.help", category: "search")

/// View model for help search with debouncing and keyboard navigation.
@MainActor
@Observable
public final class HelpSearchViewModel {

    // MARK: - Published State

    /// The current search query.
    public var query: String = "" {
        didSet {
            scheduleSearch()
        }
    }

    /// Search results.
    public private(set) var results: [HelpSearchResult] = []

    /// Whether a search is in progress.
    public private(set) var isSearching = false

    /// Currently selected result index for keyboard navigation.
    public var selectedIndex: Int = 0

    // MARK: - Private

    private var searchTask: Task<Void, Never>?
    private let debounceInterval: TimeInterval = 0.15 // 150ms debounce

    // MARK: - Initialization

    public init() {}

    // MARK: - Search

    /// Schedule a search with debouncing.
    private func scheduleSearch() {
        searchTask?.cancel()

        let query = self.query
        searchTask = Task { [weak self] in
            // Debounce delay
            try? await Task.sleep(nanoseconds: UInt64(150_000_000)) // 150ms

            guard !Task.isCancelled else { return }

            await self?.performSearch(query: query)
        }
    }

    /// Perform the actual search.
    private func performSearch(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            results = []
            selectedIndex = 0
            return
        }

        isSearching = true
        defer { isSearching = false }

        results = await HelpIndexService.shared.search(query: trimmed)
        selectedIndex = results.isEmpty ? 0 : 0

        logger.info("Help search for '\(trimmed)' returned \(self.results.count) results")
    }

    /// Clear the search query and results.
    public func clear() {
        searchTask?.cancel()
        query = ""
        results = []
        selectedIndex = 0
        isSearching = false
    }

    // MARK: - Keyboard Navigation

    /// Select the next result.
    public func selectNext() {
        guard !results.isEmpty else { return }
        selectedIndex = min(selectedIndex + 1, results.count - 1)
    }

    /// Select the previous result.
    public func selectPrevious() {
        guard !results.isEmpty else { return }
        selectedIndex = max(selectedIndex - 1, 0)
    }

    /// Get the currently selected result.
    public var selectedResult: HelpSearchResult? {
        guard !results.isEmpty, results.indices.contains(selectedIndex) else {
            return nil
        }
        return results[selectedIndex]
    }

    /// Select a result by index.
    public func select(at index: Int) {
        guard results.indices.contains(index) else { return }
        selectedIndex = index
    }
}
