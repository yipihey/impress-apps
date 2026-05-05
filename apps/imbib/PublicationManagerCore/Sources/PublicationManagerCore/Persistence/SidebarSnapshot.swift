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
        flagCounts: [String: Int]
    ) {
        self.unreadByFeedID = unreadByFeed
        self.unreadByLibraryID = unreadByLibrary
        self.flagCounts = flagCounts
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

public extension Notification.Name {
    /// Posted whenever `SidebarSnapshot.shared` is refreshed. The sidebar
    /// listens for this and calls `bumpDataVersionLight()` to rebuild.
    static let sidebarSnapshotDidUpdate = Notification.Name("sidebarSnapshotDidUpdate")
}
