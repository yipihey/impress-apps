//
//  PublicationListCore.swift
//  PublicationManagerCore
//
//  Stage 5d (SPLIT rule) — scope → rows, and the triggers that reload them.
//
//  ## What this is
//
//  The model half of a publication list host: it owns the paginated read, the
//  sort, the store-event subscription and the network refresh. It owns no view
//  state and no strings, so both a `List` and an `NSTableView`-adjacent host can
//  hold one.
//
//  Currently consumed by imbib-iOS's `IOSUnifiedPublicationListWrapper`. macOS's
//  `UnifiedPublicationListWrapper` keeps its own reload — see "Why macOS does
//  not hold one yet", below; it consumes the three stateless halves
//  (`PublicationScope`, `PublicationListOrder`, `PublicationListMutations`)
//  instead. That asymmetry is stated rather than hidden, because a "shared" file
//  with one caller is just a moved file.
//
//  ## What was duplicated, and what it cost
//
//  * **Sorting did nothing on iOS.** macOS sorts in SQL: `onChange(of:
//    currentSortOrder)` calls `dataSource.reload(sort: order.sortKey,
//    ascending:)`. iOS held the same `currentSortOrder` / `currentSortAscending`
//    state, handed it to `PublicationListView` (which renders the sort menu),
//    and had no `onChange` — it loaded once via `queryPublications(for:)` at the
//    store's default `created DESC` and never re-queried. `PublicationListView`
//    only sorts client-side for `.recommended`. So on iOS every entry in the
//    sort menu except Recommended was inert: it ticked, and the list did not
//    move. `applySort` is the missing edge.
//  * **Pagination did nothing on iOS.** macOS drives
//    `PaginatedDataSource.shouldLoadMore`/`loadNextPage` from
//    `onRowAppeared`, and `loadUntilFound` when a global-search hit is off-page.
//    iOS called `queryPublications(for:)` directly with no limit — fine at
//    today's `pageSize` of 10 000, a cliff at 10 001, and it meant the two
//    hosts read the store through two different paths.
//  * **The refresh vocabulary was written twice, and each copy had the half the
//    other lacked.** iOS implements smart-search refresh for real (group feeds
//    via `GroupFeedRefreshService`, everything else via
//    `SmartSearchProviderCache` + `SmartSearchProvider.refresh()`); macOS's
//    `.smartSearch` case was `// TODO: implement smart search refresh with Rust
//    store` followed by a 100 ms sleep. The SciX pull is the same code on both.
//    macOS now calls the same remote half via `pullSmartSearch` — the one part
//    of this file the gated macOS chrome consumes directly.
//
//  ## Why macOS does not hold one yet
//
//  macOS's `refreshPublicationsList` is not only a reload. Around the same
//  `dataSource.reload` it runs: store-version deduplication
//  (`lastRefreshedStoreVersion`, so an explicit call and a `.storeDidMutate`
//  for one mutation refresh once), the Apple-Mail unread snapshot (rows stay
//  visible after being marked read until you navigate away), `LocalFilter`
//  parsing plus a debounced FTS intersection, and two change-detected caches
//  (`cachedAllLibraries`, `cachedWritableScixLibraries`) that exist to stop a
//  non-`Equatable` tuple array from re-evaluating `PublicationListView` on every
//  body pass. iOS has none of those. Absorbing them is what would let macOS hold
//  a core, and every one of them is observable behaviour on the frozen pane, so
//  it belongs to the wave that is allowed to change it — not to a SPLIT.
//
//  Two things this file deliberately does NOT own:
//
//  * **The empty-state and title copy.** The two hosts ship different product
//    copy (macOS: "No new papers in your inbox."; iOS: "Add feeds to start
//    discovering papers."), and iOS's smart-search empty state guards an empty
//    query where macOS renders `No Results for ""`. Unifying strings adds or
//    changes words on the frozen macOS pane — a product decision, not a
//    refactor. Same reasoning as `InfoTab.macExplorationKinds`.
//  * **Selection.** See the note in `PublicationListMutations`: a phone's split
//    view is a stack, so writing a selection pushes the detail view over the
//    list. The hosts answer selection differently on purpose.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.imbib.app", category: "publicationlistcore")

/// Scope → rows for a publication list host, with the reload triggers.
@MainActor
@Observable
public final class PublicationListCore {

    // MARK: - Scope

    /// The scope being displayed. Immutable: `PaginatedDataSource` binds its
    /// source at init, so a scope change means a new core (which is also what
    /// the `.id(source.viewID)` rule demands of the host view).
    public let source: PublicationSource

    // MARK: - Rows

    /// Rows currently loaded, pre-sorted by SQL.
    public private(set) var rows: [PublicationRowData] = []

    /// Total row count for the scope, independent of how many pages are loaded.
    public var totalCount: Int { dataSource.totalCount }

    // MARK: - Sort

    public private(set) var sortOrder: LibrarySortOrder
    public private(set) var sortAscending: Bool

    // MARK: - Storage

    private let dataSource: PaginatedDataSource

    // MARK: - Init

    /// Loads the first page synchronously, so the host's first render shows rows
    /// instead of an empty list. Matches macOS's wrapper `init`.
    public init(
        source: PublicationSource,
        sortOrder: LibrarySortOrder = .dateAdded,
        sortAscending: Bool = false
    ) {
        self.source = source
        self.sortOrder = sortOrder
        self.sortAscending = sortAscending
        self.dataSource = PaginatedDataSource(source: source)
        dataSource.loadInitialPage(sort: sortOrder.sortKey, ascending: sortAscending)
        self.rows = dataSource.rows
    }

    // MARK: - Reload

    /// Re-read the scope from SQL at the current sort.
    public func reload() {
        dataSource.reload(sort: sortOrder.sortKey, ascending: sortAscending)
        rows = dataSource.rows
    }

    /// Change the sort and re-read.
    ///
    /// `.recommended` is scored in Swift, so it does not reload — the host
    /// re-orders with `PublicationListOrder.visualOrder`. Every other order is
    /// an `ORDER BY`, which is why this has to reach the store at all.
    public func applySort(_ order: LibrarySortOrder, ascending: Bool) {
        guard order != sortOrder || ascending != sortAscending else { return }
        sortOrder = order
        sortAscending = ascending
        guard order != .recommended else { return }
        reload()
    }

    /// Drop rows from the local snapshot before the store round-trips, so a
    /// deleted paper is never rendered.
    public func optimisticallyRemove(ids: Set<UUID>) {
        for id in ids { dataSource.removeRow(id: id) }
        rows.removeAll { ids.contains($0.id) }
    }

    /// Page in more rows when the host reports the tail coming into view.
    public func loadMoreIfNeeded(after id: UUID) {
        guard dataSource.shouldLoadMore(currentItem: id) else { return }
        dataSource.loadNextPage()
        rows = dataSource.rows
    }

    /// Page until `id` is loaded — for selections arriving from outside the list
    /// (global search, a URL open) that point at an off-page row.
    @discardableResult
    public func loadUntilFound(_ id: UUID) -> Bool {
        guard !rows.contains(where: { $0.id == id }) else { return false }
        guard dataSource.loadUntilFound(id: id) else { return false }
        rows = dataSource.rows
        return true
    }

    // MARK: - Order and selection

    /// The order the user sees. See `PublicationListOrder`.
    public func visualOrder(recommendationScores: [UUID: Double]) -> [PublicationRowData] {
        PublicationListOrder.visualOrder(
            rows,
            sortOrder: sortOrder,
            ascending: sortAscending,
            recommendationScores: recommendationScores
        )
    }

    /// Where selection goes after `ids` leave the list.
    public func nextSelection(
        removing ids: Set<UUID>,
        recommendationScores: [UUID: Double] = [:]
    ) -> UUID? {
        PublicationListOrder.nextSelection(
            removing: ids,
            from: visualOrder(recommendationScores: recommendationScores)
        )
    }

    // MARK: - Store events

    /// Keep the VISIBLE list in sync with async ingest (feed and inbox refresh,
    /// share-in, enrichment, batch import). Runs until cancelled; drive it from
    /// a `.task`.
    ///
    /// The policy is iOS's, which is the broader of the two: it also reloads on
    /// `.collectionMembershipChanged` and on an `.itemsMutated` that intersects
    /// the visible set. macOS reloads on `.structural` only, because
    /// `PublicationListView` has its own subscription that patches a single row
    /// in O(1) for field-level mutations — which is enough for macOS, where a
    /// field change cannot alter membership of the scopes it shows. It is NOT
    /// enough for the membership-defined scopes iOS lands on directly (a
    /// collection, a flag colour), where a flag change adds or removes a ROW.
    public func observeStoreEvents() async {
        for await event in ImbibImpressStore.shared.events.subscribe() {
            switch event {
            case .structural, .collectionMembershipChanged:
                reload()
            case .itemsMutated(_, let ids):
                // Only re-query when a visible row actually changed.
                let visible = Set(rows.map(\.id))
                if !visible.isDisjoint(with: ids) {
                    reload()
                }
            }
        }
    }

    // MARK: - Network refresh

    /// Pull fresh papers for scopes that have a remote side, then reload.
    ///
    /// - Returns: a user-presentable error message, or nil on success. Returning
    ///   the message instead of storing it keeps the error's PRESENTATION with
    ///   the host (macOS renders a retry `ContentUnavailableView`, iOS an alert).
    @discardableResult
    public func refreshFromSource(sourceManager: SourceManager) async -> String? {
        switch source {
        case .smartSearch(let id):
            return await refreshSmartSearch(id, sourceManager: sourceManager)
        case .scixLibrary(let id):
            return await refreshSciXLibrary(id)
        case .library, .inbox, .collection, .flagged, .unread, .starred, .tag, .dismissed,
             .citedInManuscripts, .recent, .combined:
            // No remote side — a refresh is a re-read.
            reload()
            return nil
        }
    }

    private func refreshSmartSearch(
        _ smartSearchID: UUID,
        sourceManager: SourceManager
    ) async -> String? {
        let failure = await Self.pullSmartSearch(smartSearchID, sourceManager: sourceManager)
        // Reload from the store after refresh, whether or not it errored — a
        // partial refresh still landed rows.
        reload()
        return failure?.localizedDescription
    }

    /// The REMOTE half of a smart-search refresh, without the reload.
    ///
    /// Exposed as a static because macOS's `UnifiedPublicationListWrapper` does
    /// not hold a core (see "Why macOS does not hold one yet") but does need
    /// this exact sequence: its `.smartSearch` case used to be
    /// `// TODO: implement smart search refresh with Rust store` plus a 100 ms
    /// `Task.sleep`, so pressing Refresh on a smart search re-read the store and
    /// fetched nothing. Both hosts call this; each then reloads its own way and
    /// PRESENTS the error its own way (macOS stores an `Error` for a retry
    /// `ContentUnavailableView`, iOS shows an alert), which is why the failure is
    /// returned rather than stored.
    ///
    /// - Returns: the failure, or nil on success (including when the smart search
    ///   no longer exists — there is nothing to pull, and that is not an error).
    public static func pullSmartSearch(
        _ smartSearchID: UUID,
        sourceManager: SourceManager
    ) async -> Error? {
        guard let smartSearch = RustStoreAdapter.shared.getSmartSearch(id: smartSearchID) else {
            return nil
        }

        // Route group feeds to GroupFeedRefreshService
        if smartSearch.isGroupFeed {
            do {
                _ = try await GroupFeedRefreshService.shared.refreshGroupFeedByID(smartSearchID)
            } catch {
                logger.error("Group feed error: \(error.localizedDescription)")
                return error
            }
        } else if let provider = await SmartSearchProviderCache.shared.getOrCreateByID(
            smartSearchID: smartSearchID,
            sourceManager: sourceManager
        ) {
            do {
                try await provider.refresh()
            } catch {
                logger.error("Smart search error: \(error.localizedDescription)")
                return error
            }
        }
        return nil
    }

    private func refreshSciXLibrary(_ scixLibraryID: UUID) async -> String? {
        guard let library = RustStoreAdapter.shared.getScixLibrary(id: scixLibraryID) else {
            reload()
            return nil
        }
        do {
            try await SciXSyncManager.shared.pullLibraryPapers(libraryID: library.remoteID)
            reload()
            return nil
        } catch {
            logger.error("SciX library refresh failed: \(error.localizedDescription)")
            return error.localizedDescription
        }
    }
}
