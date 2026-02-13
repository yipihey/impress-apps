//
//  RetentionCleanupService.swift
//  PublicationManagerCore
//
//  Periodic cleanup of old inbox papers and exploration collections
//  based on user-configured retention settings.
//

import Foundation
import OSLog

/// Runs retention cleanup for inbox papers and exploration collections.
///
/// Call `performCleanup()` on app launch and periodically.
/// Respects starred/saved papers — they are never auto-deleted.
@MainActor
public final class RetentionCleanupService {
    public static let shared = RetentionCleanupService()

    private let store = RustStoreAdapter.shared
    private let logger = Logger(subsystem: "com.imbib.app", category: "retention")

    private init() {}

    /// Run all retention cleanup tasks.
    public func performCleanup() {
        cleanupInbox()
        cleanupExplorations()
    }

    // MARK: - Inbox Cleanup

    private func cleanupInbox() {
        let retentionDays = InboxRetentionStore.shared.retentionDays
        guard retentionDays > 0 else { return } // 0 = keep forever

        let autoRemoveRead = InboxRetentionStore.shared.autoRemoveRead
        guard let inboxLib = InboxManager.shared.inboxLibrary else { return }

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
                store.deleteItem(id: pub.id)
                removedCount += 1
            }
        }

        if removedCount > 0 {
            logger.info("Inbox retention: removed \(removedCount) papers (cutoff: \(retentionDays) days)")
        }
    }

    // MARK: - Exploration Cleanup

    private func cleanupExplorations() {
        let retentionDays = ExplorationRetentionStore.shared.retentionDays
        guard retentionDays > 0 else { return } // 0 = keep forever

        // Read exploration library ID from UserDefaults (matches LibraryManager's storage)
        guard let explorationIDString = UserDefaults.standard.string(forKey: "explorationLibraryID"),
              let explorationLibID = UUID(uuidString: explorationIDString) else { return }
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
            logger.info("Exploration retention: removed \(removedCount) items (cutoff: \(retentionDays) days)")
        }
    }
}
