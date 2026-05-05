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
        isRefreshing = true
        Task.detached(priority: .utility) { [weak self] in
            await self?.performRefresh()
        }
    }

    private func performRefresh() async {
        defer {
            // Schedule follow-up refresh if events arrived during this one.
            Task { await self.finishRefresh() }
        }

        // All of these run on the gateway actor's nonisolated accessors,
        // which internally dispatch to the Rust reader pool.
        let gateway = ImbibImpressStore.shared

        // Feeds — only the smart searches that feed the inbox currently
        // show unread counts in the sidebar.
        let allSearches = gateway.listSmartSearches()
        var unreadByFeed: [UUID: Int] = [:]
        for feed in allSearches where feed.feedsToInbox {
            unreadByFeed[feed.id] = gateway.countUnreadInCollection(collectionId: feed.id)
        }

        // Libraries.
        let libraries = gateway.listLibraries()
        var unreadByLibrary: [UUID: Int] = [:]
        for lib in libraries {
            unreadByLibrary[lib.id] = gateway.countUnread(parentId: lib.id)
        }

        // Flag counts for the sidebar "Flagged" section.
        let flagColors = ["red", "orange", "yellow", "green", "blue", "purple", "grey"]
        var flagCounts: [String: Int] = [:]
        for color in flagColors {
            flagCounts[color] = gateway.countFlagged(color: color)
        }

        // Publish atomically on the main actor.
        await MainActor.run {
            SidebarSnapshot.shared.apply(
                unreadByFeed: unreadByFeed,
                unreadByLibrary: unreadByLibrary,
                flagCounts: flagCounts
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
