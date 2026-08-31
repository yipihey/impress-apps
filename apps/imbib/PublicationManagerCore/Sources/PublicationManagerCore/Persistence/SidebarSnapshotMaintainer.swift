//
//  SidebarSnapshotMaintainer.swift
//  PublicationManagerCore
//
//  Actor that owns the background refresh loop for `SidebarSnapshot`.
//  Subscribes to `ImbibImpressStore.events` and re-computes the cached
//  counts after every mutation. The compute itself runs on the actor's
//  background executor, so the main thread is never blocked on a
//  sidebar refresh — only a short hop to publish the results.
//
//  ## Lifecycle
//
//  `start()` is called once from `imbibApp.applicationDidFinishLaunching`.
//  It kicks off the event subscription loop and does an initial refresh.
//  After that, every mutation on `ImbibImpressStore` (fanned out via
//  `postMutation`) triggers a debounced refresh.
//
//  ## Debouncing
//
//  Rapid successive mutations (tagging 50 papers in one batch, a feed
//  fetch importing 200 papers) collapse into a single refresh. The
//  maintainer tracks an `isRefreshing` flag and a `pending` bit: if a
//  new event arrives while a refresh is in progress, `pending` is set
//  and one more refresh runs after the current one completes.
//

import Foundation
import ImpressLogging
import ImpressStoreKit

/// Background refresh orchestrator for `SidebarSnapshot`.
public actor SidebarSnapshotMaintainer {

    // MARK: - Singleton

    public static let shared = SidebarSnapshotMaintainer()

    // MARK: - State

    private var isRunning = false
    private var isRefreshing = false
    private var pendingRefresh = false
    private var eventTask: Task<Void, Never>?
    private var lastSweepStart: ContinuousClock.Instant?
    private var delayedTriggerScheduled = false

    /// Minimum spacing between full count sweeps. Each sweep is ~15 store
    /// round-trips (the `snapshot` PerfMetrics bucket), and launch emits a
    /// burst of structural events that used to run three back-to-back
    /// sweeps. One delayed trigger coalesces a burst; a lone steady-state
    /// event still refreshes within this interval. Sidebar counts are
    /// advisory badges — a ≤2s lag is invisible, three redundant sweeps
    /// during launch are not.
    private let minSweepInterval: Duration = .seconds(2)

    public init() {}

    // MARK: - Lifecycle

    /// Start the maintainer. Safe to call more than once (idempotent).
    public func start() {
        guard !isRunning else { return }
        isRunning = true

        // Subscribe to the event stream. We drop events into a trigger
        // function rather than attempting to react to each one
        // specifically — every event invalidates the snapshot equally
        // at this layer. Future refinement: handle `itemsMutated`
        // narrowly for O(k) updates.
        let stream = ImbibImpressStore.shared.events.subscribe()
        eventTask = Task.detached(priority: .utility) { [weak self] in
            for await _ in stream {
                await self?.triggerRefresh()
            }
        }

        // Kick off the initial refresh so the sidebar has data even
        // before any mutation happens.
        Task { await self.triggerRefresh() }
    }

    // MARK: - Refresh orchestration

    private func triggerRefresh() {
        if isRefreshing {
            pendingRefresh = true
            return
        }
        if let last = lastSweepStart, ContinuousClock.now - last < minSweepInterval {
            guard !delayedTriggerScheduled else { return }
            delayedTriggerScheduled = true
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                await self?.runDelayedTrigger()
            }
            return
        }
        lastSweepStart = ContinuousClock.now
        isRefreshing = true
        Task.detached(priority: .utility) { [weak self] in
            await self?.performRefresh()
        }
    }

    private func runDelayedTrigger() {
        delayedTriggerScheduled = false
        triggerRefresh()
    }

    private func performRefresh() async {
        defer {
            // Schedule follow-up refresh if events arrived during this one.
            Task { await self.finishRefresh() }
        }

        // All of these run on the gateway actor's nonisolated accessors,
        // which internally dispatch to the Rust reader pool.
        let perfToken = PerfMetrics.shared.begin(PerfBucket.snapshot, detail: "sidebar-counts")
        defer { perfToken.end() }
        let gateway = ImbibImpressStore.shared

        // Sidebar plan P3: the whole sweep — counts AND tree data — in ONE
        // FFI crossing. `sidebar_snapshot()` composes the same Rust verbs the
        // per-shape reads below use (kernel-first collections included), so
        // the data cannot differ; only the crossing count does (~2+3×L → 1).
        // The per-shape path below is the FALLBACK, kept verbatim for a store
        // error — never a second implementation of the shapes.
        let oneCall = StoreTimings.shared.measure("ImbibImpressStore.sidebarSnapshot") {
            try? RustStoreAdapter.shared.imbibStore.sidebarSnapshot()
        }
        if let snapshot = oneCall {
            await publish(snapshot: snapshot)
            return
        }

        let allSearches = gateway.listSmartSearches()
        let libraries = gateway.listLibraries()
        let flagColors = ["red", "orange", "yellow", "green", "blue", "purple", "grey"]
        var unreadByFeed: [UUID: Int] = [:]
        var unreadByLibrary: [UUID: Int] = [:]
        var flagCounts: [String: Int] = [:]

        if let batched = gateway.sidebarCounts() {
            // One FFI round-trip for the whole sweep (was ~15 point
            // queries — the `snapshot` budget breach). Feeds and libraries
            // read the same container map; imbib-core's UNION dedup keeps
            // the counts equal to the point queries (parity-tested there).
            let byContainer: [UUID: Int] = Dictionary(
                batched.unreadByContainer.compactMap { entry in
                    UUID(uuidString: entry.id).map { ($0, Int(entry.count)) }
                },
                uniquingKeysWith: { a, _ in a }
            )
            for feed in allSearches where feed.feedsToInbox {
                unreadByFeed[feed.id] = byContainer[feed.id] ?? 0
            }
            for lib in libraries {
                unreadByLibrary[lib.id] = byContainer[lib.id] ?? 0
            }
            let byColor = Dictionary(
                batched.flagCounts.map { ($0.id, Int($0.count)) },
                uniquingKeysWith: { a, _ in a }
            )
            for color in flagColors {
                flagCounts[color] = byColor[color] ?? 0
            }
        } else {
            // Store error on the batched path — fall back to the point
            // queries rather than publishing zeros.
            for feed in allSearches where feed.feedsToInbox {
                unreadByFeed[feed.id] = gateway.countUnreadInCollection(collectionId: feed.id)
            }
            for lib in libraries {
                unreadByLibrary[lib.id] = gateway.countUnread(parentId: lib.id)
            }
            for color in flagColors {
                flagCounts[color] = gateway.countFlagged(color: color)
            }
        }

        // Tree data (sidebar plan P2): the same shapes the builders' fetch
        // cache reads, gathered here — off-main — in the sweep that already
        // walks libraries. Collections go through the adapter's kernel-first
        // door (`listCollectionsResolved`, the one ADR-0022 F2 left standing),
        // never a raw export. Gathered unconditionally: ~a dozen quick reads
        // per sweep, and flipping `sidebar.snapshotTree` then needs no
        // restart — the data is always current.
        let adapter = RustStoreAdapter.shared
        var collectionsByLibrary: [UUID: [CollectionModel]] = [:]
        var feedsByLibrary: [UUID?: [SmartSearch]] = [:]
        var starredByLibrary: [UUID?: Int] = [:]
        for lib in libraries {
            collectionsByLibrary[lib.id] = adapter.listCollectionsResolved(libraryId: lib.id)
            feedsByLibrary[lib.id] = gateway.listSmartSearches(libraryId: lib.id)
            starredByLibrary[lib.id] = adapter.countStarredResolved(parentId: lib.id)
        }
        feedsByLibrary[nil] = allSearches
        starredByLibrary[nil] = adapter.countStarredResolved(parentId: nil)
        var artifactCounts: [ArtifactType?: Int] = [
            nil: adapter.countArtifactsResolved(type: nil)
        ]
        for type in ArtifactType.allCases {
            artifactCounts[type] = adapter.countArtifactsResolved(type: type)
        }
        let treeData = SidebarTreeData(
            collectionsByLibrary: collectionsByLibrary,
            feedsByLibrary: feedsByLibrary,
            starredByLibrary: starredByLibrary,
            artifactCounts: artifactCounts
        )

        // Publish atomically on the main actor.
        await MainActor.run {
            SidebarSnapshot.shared.apply(
                unreadByFeed: unreadByFeed,
                unreadByLibrary: unreadByLibrary,
                flagCounts: flagCounts,
                treeData: treeData
            )
        }
    }

    /// Map the one-call Rust snapshot into the published Swift values.
    private func publish(snapshot: SidebarSnapshotData) async {
        let feedRows = snapshot.allFeeds.map { SmartSearch(from: $0) }
        let unreadByContainer: [UUID: Int] = Dictionary(
            snapshot.counts.unreadByContainer.compactMap { entry in
                UUID(uuidString: entry.id).map { ($0, Int(entry.count)) }
            },
            uniquingKeysWith: { a, _ in a }
        )
        var unreadByFeed: [UUID: Int] = [:]
        for feed in feedRows where feed.feedsToInbox {
            unreadByFeed[feed.id] = unreadByContainer[feed.id] ?? 0
        }
        var unreadByLibrary: [UUID: Int] = [:]
        for lib in snapshot.libraries {
            guard let id = UUID(uuidString: lib.id) else { continue }
            unreadByLibrary[id] = unreadByContainer[id] ?? 0
        }
        var flagCounts: [String: Int] = [:]
        for entry in snapshot.counts.flagCounts {
            flagCounts[entry.id] = Int(entry.count)
        }

        var collectionsByLibrary: [UUID: [CollectionModel]] = [:]
        var feedsByLibrary: [UUID?: [SmartSearch]] = [:]
        var starredByLibrary: [UUID?: Int] = [:]
        for per in snapshot.perLibrary {
            guard let id = UUID(uuidString: per.libraryId) else { continue }
            collectionsByLibrary[id] = per.collections.map { CollectionModel(from: $0) }
            feedsByLibrary[id] = per.feeds.map { SmartSearch(from: $0) }
            starredByLibrary[id] = Int(per.starred)
        }
        feedsByLibrary[nil] = feedRows
        starredByLibrary[nil] = Int(snapshot.starredTotal)
        var artifactCounts: [ArtifactType?: Int] = [:]
        for entry in snapshot.artifactCounts {
            let type = entry.schemaRef.flatMap { ArtifactType(rawValue: $0) }
            if entry.schemaRef != nil && type == nil { continue }
            artifactCounts[type] = Int(entry.count)
        }
        let treeData = SidebarTreeData(
            collectionsByLibrary: collectionsByLibrary,
            feedsByLibrary: feedsByLibrary,
            starredByLibrary: starredByLibrary,
            artifactCounts: artifactCounts
        )
        await MainActor.run {
            SidebarSnapshot.shared.apply(
                unreadByFeed: unreadByFeed,
                unreadByLibrary: unreadByLibrary,
                flagCounts: flagCounts,
                treeData: treeData
            )
        }
    }

    private func finishRefresh() async {
        isRefreshing = false
        if pendingRefresh {
            pendingRefresh = false
            triggerRefresh()
        }
    }
}
