//
//  InboxTriageService.swift
//  PublicationManagerCore
//
//  Centralized service for inbox triage operations (save/dismiss).
//

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.imbib.app", category: "inbox-triage")

/// Centralized service for inbox triage operations (save/dismiss).
///
/// Provides consistent behavior across iOS and macOS list views:
/// - Save: Adds paper to target library, removes from inbox, tracks dismissal
/// - Dismiss: Moves to Dismissed library (not delete), tracks dismissal
/// - Both: Automatically calculate next selection for smooth UI transitions
@MainActor
public final class InboxTriageService {

    // MARK: - Singleton

    public static let shared = InboxTriageService()

    private var store: RustStoreAdapter { RustStoreAdapter.shared }

    private init() {}

    // MARK: - Save to Library

    /// Save publications to a target library.
    ///
    /// This is the primary triage action for saving interesting papers.
    /// Papers are added to the target library and removed from their source.
    ///
    /// - Parameters:
    ///   - ids: Set of publication IDs to save
    ///   - publications: Current list of publications (for selection calculation)
    ///   - currentSelection: Currently selected publication ID
    ///   - targetLibraryID: Library ID to save papers to
    ///   - source: Where the papers are coming from (for proper cleanup)
    /// - Returns: Result containing the next selection info and count of papers saved
    public func saveToLibrary(
        ids: Set<UUID>,
        from publications: [PublicationRowData],
        currentSelectionID: UUID?,
        targetLibraryID: UUID,
        source: TriageSource
    ) -> TriageResult {
        guard !ids.isEmpty else {
            return TriageResult(nextSelectionID: nil, affectedCount: 0)
        }

        // Calculate next selection BEFORE modifying data
        let nextID = SelectionAdvancement.advanceSelection(
            removing: ids,
            from: publications,
            currentSelectionID: currentSelectionID
        )

        let inboxManager = InboxManager.shared
        var savedCount = 0

        for id in ids {
            guard publications.contains(where: { $0.id == id }) else { continue }

            switch source {
            case .inboxLibrary, .inboxFeed:
                // Inbox save: track dismissal, move to target library
                inboxManager.trackDismissal(id)
                store.movePublications(ids: [id], toLibraryId: targetLibraryID)
                savedCount += 1
                // ADR-020: Record save signal for recommendation engine
                Task { await SignalCollector.shared.recordSave(id) }

            case .regularLibrary(let sourceLibraryID):
                // Non-inbox: move to target library from source
                store.movePublications(ids: [id], toLibraryId: targetLibraryID)
                savedCount += 1
            }
        }

        let targetLib = store.getLibrary(id: targetLibraryID)
        logger.info("Saved \(savedCount) papers to '\(targetLib?.name ?? "unknown")' from \(source.logDescription)")

        return TriageResult(
            nextSelectionID: nextID,
            affectedCount: savedCount
        )
    }

    // MARK: - Dismiss from Inbox

    /// Dismiss publications from inbox.
    ///
    /// Papers are NOT deleted - they are moved to the Dismissed library
    /// and tracked to prevent reappearance in feeds.
    ///
    /// - Parameters:
    ///   - ids: Set of publication IDs to dismiss
    ///   - publications: Current list of publications (for selection calculation)
    ///   - currentSelectionID: Currently selected publication ID
    ///   - dismissedLibraryID: Library ID to move dismissed papers to
    ///   - source: Where the papers are coming from (for proper cleanup)
    /// - Returns: Result containing the next selection info and count of papers dismissed
    public func dismissFromInbox(
        ids: Set<UUID>,
        from publications: [PublicationRowData],
        currentSelectionID: UUID?,
        dismissedLibraryID: UUID,
        source: TriageSource
    ) -> TriageResult {
        guard !ids.isEmpty else {
            return TriageResult(nextSelectionID: nil, affectedCount: 0)
        }

        // Calculate next selection BEFORE modifying data
        let nextID = SelectionAdvancement.advanceSelection(
            removing: ids,
            from: publications,
            currentSelectionID: currentSelectionID
        )

        let inboxManager = InboxManager.shared
        var dismissedCount = 0

        for id in ids {
            guard publications.contains(where: { $0.id == id }) else { continue }

            // Track dismissal to prevent reappearance
            inboxManager.trackDismissal(id)

            // Move to Dismissed library
            store.movePublications(ids: [id], toLibraryId: dismissedLibraryID)
            dismissedCount += 1

            // ADR-020: Record dismiss signal for recommendation engine
            Task { await SignalCollector.shared.recordDismiss(id) }
        }

        inboxManager.updateUnreadCount()

        logger.info("Dismissed \(dismissedCount) papers from \(source.logDescription)")

        return TriageResult(
            nextSelectionID: nextID,
            affectedCount: dismissedCount
        )
    }
}

// MARK: - Supporting Types

/// The source context for triage operations.
public enum TriageSource {
    /// Viewing the main Inbox library
    case inboxLibrary

    /// Viewing an inbox feed (smart search that feeds to inbox)
    case inboxFeed(UUID)  // smart search ID

    /// Viewing a regular (non-inbox) library
    case regularLibrary(UUID)  // library ID

    var logDescription: String {
        switch self {
        case .inboxLibrary:
            return "Inbox"
        case .inboxFeed(let id):
            return "feed '\(id)'"
        case .regularLibrary(let id):
            return "library '\(id)'"
        }
    }
}

/// Result of a triage operation.
public struct TriageResult {
    /// The UUID of the next paper to select (or nil if none remain)
    public let nextSelectionID: UUID?

    /// Number of papers affected by the operation
    public let affectedCount: Int

    public init(nextSelectionID: UUID?, affectedCount: Int) {
        self.nextSelectionID = nextSelectionID
        self.affectedCount = affectedCount
    }
}
