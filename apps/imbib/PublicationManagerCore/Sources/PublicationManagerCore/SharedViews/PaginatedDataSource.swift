//
//  PaginatedDataSource.swift
//  PublicationManagerCore
//
//  Manages paginated publication data for a single publication list.
//  Loads pages from the Rust store on demand, with sorting handled by SQL.
//

import Foundation
import OSLog

/// Paginated data source that sits between RustStoreAdapter and publication list views.
///
/// Loads pages of publications from the Rust store on demand. Sorting is always
/// handled by SQL (via the Rust layer), never in Swift. Use `loadInitialPage()`
/// on first display, then `loadNextPage()` as the user scrolls.
@MainActor
@Observable
public final class PaginatedDataSource {

    // MARK: - Configuration

    /// Number of items per page.
    public let pageSize: Int

    /// The data source (library, collection, tag, etc.).
    public let source: PublicationSource

    // MARK: - State

    /// All currently loaded rows, in sort order from SQL.
    public private(set) var rows: [PublicationRowData] = []

    /// Total count of items matching the source (from COUNT(*) query).
    public private(set) var totalCount: Int = 0

    /// Whether more pages are available to load.
    public var hasMore: Bool { rows.count < totalCount }

    /// Whether a page load is in progress.
    public private(set) var isLoading: Bool = false

    /// Current sort field (passed through to SQL ORDER BY via Rust).
    public private(set) var sortField: String = "created"

    /// Current sort direction.
    public private(set) var ascending: Bool = false

    // MARK: - Private

    private let store: RustStoreAdapter
    private var currentOffset: Int = 0

    // MARK: - Init

    public init(
        source: PublicationSource,
        pageSize: Int = 10_000,
        store: RustStoreAdapter = .shared
    ) {
        self.source = source
        self.pageSize = pageSize
        self.store = store
    }

    // MARK: - Loading

    /// Load the first page and total count. Call on initial display.
    public func loadInitialPage(sort: String = "created", ascending: Bool = false) {
        self.sortField = sort
        self.ascending = ascending
        self.currentOffset = 0

        self.totalCount = store.countPublications(for: source)
        self.rows = store.queryPublications(
            for: source,
            sort: sort,
            ascending: ascending,
            limit: UInt32(pageSize),
            offset: 0
        )
        self.currentOffset = rows.count

        Logger.performance.info(
            "PaginatedDataSource: loaded \(self.rows.count)/\(self.totalCount) for \(String(describing: self.source))"
        )
    }

    /// Load the next page and append to existing rows.
    public func loadNextPage() {
        guard hasMore, !isLoading else { return }
        isLoading = true

        let nextRows = store.queryPublications(
            for: source,
            sort: sortField,
            ascending: ascending,
            limit: UInt32(pageSize),
            offset: UInt32(currentOffset)
        )
        rows.append(contentsOf: nextRows)
        currentOffset += nextRows.count
        isLoading = false

        Logger.performance.info(
            "PaginatedDataSource: page loaded, now \(self.rows.count)/\(self.totalCount)"
        )
    }

    /// Reload from scratch (e.g. after sort change or structural mutation).
    public func reload(sort: String? = nil, ascending: Bool? = nil) {
        loadInitialPage(
            sort: sort ?? self.sortField,
            ascending: ascending ?? self.ascending
        )
    }

    /// Update a single row in place (for field mutations like flag/read/star/tag).
    /// Re-fetches the row from the store to get the latest state.
    public func updateRow(id: UUID) {
        guard let index = rows.firstIndex(where: { $0.id == id }),
              let updated = store.getPublication(id: id) else { return }
        rows[index] = updated
    }

    /// Update multiple rows in place.
    public func updateRows(ids: [UUID]) {
        for id in ids {
            updateRow(id: id)
        }
    }

    /// Remove a row (for deletes without full reload).
    public func removeRow(id: UUID) {
        rows.removeAll { $0.id == id }
        totalCount = max(totalCount - 1, 0)
    }

    /// Load pages until the given publication ID is in `rows`.
    /// Returns `true` if found, `false` if all pages exhausted without finding it.
    /// Used by global search navigation to ensure the target paper is loaded
    /// before attempting to scroll to it.
    @discardableResult
    public func loadUntilFound(id targetID: UUID) -> Bool {
        // Already loaded?
        if rows.contains(where: { $0.id == targetID }) { return true }

        // Load pages until found or exhausted
        while hasMore {
            let nextRows = store.queryPublications(
                for: source,
                sort: sortField,
                ascending: ascending,
                limit: UInt32(pageSize),
                offset: UInt32(currentOffset)
            )
            rows.append(contentsOf: nextRows)
            currentOffset += nextRows.count

            if nextRows.contains(where: { $0.id == targetID }) {
                Logger.performance.info(
                    "PaginatedDataSource: found target after loading to \(self.rows.count)/\(self.totalCount)"
                )
                return true
            }

            // Empty page means no more data
            if nextRows.isEmpty { break }
        }

        Logger.performance.info(
            "PaginatedDataSource: target not found after loading all \(self.rows.count) rows"
        )
        return false
    }

    /// Check if a row is near the end of loaded data (for prefetch trigger).
    /// Returns true when within 50 rows of the end and more pages are available.
    public func shouldLoadMore(currentItem: UUID) -> Bool {
        guard hasMore else { return false }
        guard let index = rows.firstIndex(where: { $0.id == currentItem }) else { return false }
        return index >= rows.count - 50
    }
}
