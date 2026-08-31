//
//  SidebarSnapshot.swift
//  PublicationManagerCore
//
//  Phase 3 of the responsiveness rework: an @Observable cache of the
//  data the sidebar needs to render, populated off the main thread by a
//  maintainer that subscribes to `ImbibImpressStore.events`. The sidebar
//  reads from this snapshot instead of querying the store during its
//  rebuild — guaranteeing that the sidebar tree construction never
//  touches the SQLite mutex.
//
//  ## Invariant
//
//  The sidebar view-model calls `unreadCountForFeed`, `unreadForLibrary`,
//  `flagCount(color:)` and gets whatever is currently in the snapshot —
//  possibly stale by a few tens of milliseconds. Staleness is acceptable
//  because it is *non-blocking*: the user sees the sidebar update within
//  one frame after a mutation, rather than waiting for the main thread
//  to finish a round-trip through the store.
//

import Foundation

/// @Observable cache of sidebar display data.
///
/// Lives on the main actor so SwiftUI / NSOutlineView can read it
/// directly during rebuild without any hop. Populated by
/// `SidebarSnapshotMaintainer` from off-main queries.
@MainActor
@Observable
public final class SidebarSnapshot {

    // MARK: - Singleton

    public static let shared = SidebarSnapshot()

    // MARK: - Cached counts

    /// Unread publications linked to each smart-search-scoped feed.
    public private(set) var unreadByFeedID: [UUID: Int] = [:]

    /// Unread publications in each library.
    public private(set) var unreadByLibraryID: [UUID: Int] = [:]

    /// Per-flag-color counts (keys are the color strings used by the Rust
    /// schema — "red", "orange", "yellow", "green", "blue", "purple", "grey").
    public private(set) var flagCounts: [String: Int] = [:]

    /// Monotonically bumped on every snapshot apply. Views observe this
    /// to trigger rebuilds when the snapshot refreshes.
    public private(set) var version: Int = 0

    /// When was the snapshot last refreshed (for debug / the console overlay).
    public private(set) var lastUpdated: Date = .distantPast

    /// The tree builders' data plane (sidebar plan P2): everything the
    /// `childrenOf:` builders used to fetch from the store synchronously on
    /// the main thread, gathered off-main by the maintainer in the same sweep
    /// as the counts. `nil` until the first sweep publishes — readers behind
    /// the `sidebar.snapshotTree` flag fall back to the fetch path until then,
    /// so enabling the flag can never render an empty sidebar.
    public private(set) var treeData: SidebarTreeData?

    // MARK: - Init

    public init() {}

    // MARK: - Mutation (internal)

    /// Replace the snapshot with freshly-computed values and bump the
    /// version. Should only be called by `SidebarSnapshotMaintainer`.
    ///
    /// Also posts `.sidebarSnapshotDidUpdate` so the sidebar can trigger
    /// a lightweight rebuild that reads from the now-fresh snapshot.
    internal func apply(
        unreadByFeed: [UUID: Int],
        unreadByLibrary: [UUID: Int],
        flagCounts: [String: Int],
        treeData: SidebarTreeData? = nil
    ) {
        self.unreadByFeedID = unreadByFeed
        self.unreadByLibraryID = unreadByLibrary
        self.flagCounts = flagCounts
        if let treeData { self.treeData = treeData }
        self.version &+= 1
        self.lastUpdated = Date()

        NotificationCenter.default.post(name: .sidebarSnapshotDidUpdate, object: nil)
    }

    // MARK: - Read (public, synchronous)

    public func unreadCountForFeed(_ feedID: UUID) -> Int {
        unreadByFeedID[feedID] ?? 0
    }

    public func unreadCountForLibrary(_ libraryID: UUID) -> Int {
        unreadByLibraryID[libraryID] ?? 0
    }

    public func flagCount(color: String) -> Int {
        flagCounts[color] ?? 0
    }
}

/// Immutable data the sidebar's tree builders consume — one value, produced
/// off-main, swapped atomically (sidebar plan P2).
///
/// The keys mirror the per-dataVersion fetch cache the builders use when the
/// `sidebar.snapshotTree` flag is off: collections and inbox-relevant feeds
/// per library (nil key = the unscoped "all feeds" read), starred counts per
/// library (nil = all), artifact counts per type (nil = total).
public struct SidebarTreeData: Sendable {
    public let collectionsByLibrary: [UUID: [CollectionModel]]
    public let feedsByLibrary: [UUID?: [SmartSearch]]
    public let starredByLibrary: [UUID?: Int]
    public let artifactCounts: [ArtifactType?: Int]

    public init(
        collectionsByLibrary: [UUID: [CollectionModel]],
        feedsByLibrary: [UUID?: [SmartSearch]],
        starredByLibrary: [UUID?: Int],
        artifactCounts: [ArtifactType?: Int]
    ) {
        self.collectionsByLibrary = collectionsByLibrary
        self.feedsByLibrary = feedsByLibrary
        self.starredByLibrary = starredByLibrary
        self.artifactCounts = artifactCounts
    }
}

public extension Notification.Name {
    /// Posted whenever `SidebarSnapshot.shared` is refreshed. The sidebar
    /// listens for this and calls `bumpDataVersionLight()` to rebuild.
    static let sidebarSnapshotDidUpdate = Notification.Name("sidebarSnapshotDidUpdate")
}
