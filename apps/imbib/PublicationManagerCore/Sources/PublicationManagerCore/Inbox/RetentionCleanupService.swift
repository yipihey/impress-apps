//
//  RetentionCleanupService.swift
//  PublicationManagerCore
//
//  Periodic cleanup of old inbox papers and exploration collections
//  based on user-configured retention settings.
//
//  WHERE it runs is the point of this file's shape (review PH-H2,
//  2026-09-25). It used to be a `.task` in the chassis sidebar's lifecycle
//  modifier, and the layout tree's `outline` pane applies that modifier — so
//  every outline MOUNT ran it: in impress, imprint, implore, impel and
//  impart, on every split, swap and preset change, on the main actor inside
//  the 90 s settling window, with each delete registering "Delete" on the
//  user's undo stack. Now the one caller is imbib's own lifecycle
//  (`InboxCoordinator.start`, which only imbib calls), once per process,
//  behind the suite's 90 s startup gate, inside
//  `UndoCoordinator.performAutomatic("retention")`, and logged to the
//  console (`?category=retention`) as a three-point trace.
//

import Foundation
import ImpressLogging
import OSLog

/// Runs retention cleanup for inbox papers and exploration collections.
///
/// `scheduleLaunchCleanup()` is imbib's once-per-launch entry point; a
/// view must never call either method (a view's lifecycle is not the app's:
/// a pane mounts again on every re-layout).
/// Respects starred/saved papers — they are never auto-deleted.
@MainActor
public final class RetentionCleanupService {
    public static let shared = RetentionCleanupService()

    private let store = RustStoreAdapter.shared

    /// How many cleanups this process has run. The counter the live proof
    /// reads: a split or a launch of any app other than imbib leaves it at
    /// 0, and imbib's own schedule moves it to 1 once the gate opens.
    public private(set) var runCount = 0

    /// The launch run, once scheduled. Non-nil means "already scheduled" —
    /// a second call is a no-op that says so.
    private var launchTask: Task<Void, Never>?

    private init() {}

    /// Schedule the launch cleanup: once per process, after `gate` opens.
    ///
    /// The cleanup DELETES papers, and every delete mutates the store, so it
    /// is a background writer under CLAUDE.md's startup rule: nothing in the
    /// first 90 s. One `Task.sleep` (inside `waitUntilOpen`), never a loop.
    @discardableResult
    public func scheduleLaunchCleanup(
        gate: EInkStartupGate = EInkStartupGate(), reason: String = "launch"
    ) -> Task<Void, Never>? {
        if let launchTask {
            Logger.library.debugCapture(
                "retention: launch cleanup already scheduled — not scheduling a second (\(reason))",
                category: "retention")
            return launchTask
        }
        Logger.library.infoCapture(
            "retention: \(reason) cleanup scheduled, runs in \(Int(gate.remaining.rounded())) s "
                + "(startup gate)",
            category: "retention")
        let task = Task { @MainActor [weak self] in
            guard await gate.waitUntilOpen() else {
                Logger.library.infoCapture(
                    "retention: \(reason) cleanup cancelled before the gate opened", category: "retention")
                return
            }
            self?.performCleanup(reason: reason)
        }
        launchTask = task
        return task
    }

    /// Run all retention cleanup tasks now, as automatic work: none of its
    /// deletes reaches the user's undo stack.
    public func performCleanup(reason: String = "on demand") {
        runCount += 1
        let run = runCount
        // 1. MUTATION — what is about to be asked of the store.
        Logger.library.infoCapture(
            "retention run \(run) (\(reason)): inbox \(InboxRetentionStore.shared.retentionDays) d, "
                + "exploration \(ExplorationRetentionStore.shared.retentionDays) d (0 = keep forever)",
            category: "retention")
        let removed = UndoCoordinator.performAutomatic("retention") {
            (inbox: cleanupInbox(), explorations: cleanupExplorations(), feeds: cleanupFeedCollections())
        }
        // 2. SAVE — what the store did. (3. DISPLAY is the lists' own
        // `pane N display` / sidebar-count lines, which these deletes drive.)
        Logger.library.infoCapture(
            "retention run \(run) (\(reason)) done: removed \(removed.inbox) inbox paper(s), "
                + "\(removed.explorations) exploration search(es), \(removed.feeds) feed paper(s)",
            category: "retention")
    }

    // MARK: - Inbox Cleanup

    private func cleanupInbox() -> Int {
        let retentionDays = InboxRetentionStore.shared.retentionDays
        guard retentionDays > 0 else { return 0 } // 0 = keep forever

        let autoRemoveRead = InboxRetentionStore.shared.autoRemoveRead
        guard let inboxLib = InboxManager.shared.inboxLibrary else { return 0 }

        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? Date()
        let publications = store.queryPublications(
            parentId: inboxLib.id,
            sort: "created",
            ascending: true,
            limit: nil,
            offset: nil
        )

        var removedCount = 0
        for pub in publications {
            // Never remove starred papers
            if pub.isStarred { continue }

            let created = pub.dateAdded
            let isOld = created < cutoff
            let shouldRemoveAsRead = autoRemoveRead && pub.isRead

            if isOld || shouldRemoveAsRead {
                InboxManager.shared.trackDismissal(pub.id)
                store.deleteItem(id: pub.id)
                removedCount += 1
            }
        }

        if removedCount > 0 {
            Logger.library.infoCapture(
                "Inbox retention: removed \(removedCount) papers (cutoff: \(retentionDays) days)",
                category: "retention")
        }
        return removedCount
    }

    // MARK: - Feed Collection Cleanup

    /// Clean up papers in smart search collections that have per-collection retention settings.
    private func cleanupFeedCollections() -> Int {
        let allSearches = store.listSmartSearches()
        var total = 0

        for search in allSearches {
            // Only process feeds with per-collection retention configured
            guard let retentionDays = search.retentionDays, retentionDays > 0 else { continue }

            let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? Date()
            guard let libraryID = search.libraryID else { continue }

            let publications = store.queryPublications(
                parentId: libraryID,
                sort: "created",
                ascending: true,
                limit: nil,
                offset: nil
            )

            var removedCount = 0
            for pub in publications {
                // Never remove starred papers
                if pub.isStarred { continue }

                let created = pub.dateAdded
                let isOld = created < cutoff
                let shouldRemoveAsRead = search.autoRemoveRead && pub.isRead

                if isOld || shouldRemoveAsRead {
                    InboxManager.shared.trackDismissal(pub.id)
                    store.deleteItem(id: pub.id)
                    removedCount += 1
                }
            }

            if removedCount > 0 {
                Logger.library.infoCapture(
                    "Feed '\(search.name)' retention: removed \(removedCount) papers (cutoff: \(retentionDays) days)",
                    category: "retention")
            }
            total += removedCount
        }
        return total
    }

    // MARK: - Exploration Cleanup

    private func cleanupExplorations() -> Int {
        let retentionDays = ExplorationRetentionStore.shared.retentionDays
        guard retentionDays > 0 else { return 0 } // 0 = keep forever

        // Read exploration library ID from UserDefaults (matches LibraryManager's storage)
        guard let explorationIDString = UserDefaults.standard.string(forKey: "explorationLibraryID"),
              let explorationLibID = UUID(uuidString: explorationIDString) else { return 0 }
        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? Date()

        var removedCount = 0

        // Clean up exploration smart searches that have been executed and are past retention.
        // Skip searches with no lastExecuted — they were created manually and haven't
        // been refreshed yet, so we can't determine their age from this field.
        let searches = store.listSmartSearches(libraryId: explorationLibID)
        for search in searches {
            guard let executed = search.lastExecuted else { continue }
            if executed < cutoff {
                store.deleteItem(id: search.id)
                removedCount += 1
            }
        }

        if removedCount > 0 {
            Logger.library.infoCapture(
                "Exploration retention: removed \(removedCount) items (cutoff: \(retentionDays) days)",
                category: "retention")
        }
        return removedCount
    }
}
