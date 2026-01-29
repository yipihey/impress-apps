//
//  InboxTriageService.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-19.
//

import Foundation
import CoreData
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
    ///   - currentSelection: Currently selected publication
    ///   - targetLibrary: Library to save papers to
    ///   - source: Where the papers are coming from (for proper cleanup)
    /// - Returns: Result containing the next selection info and count of papers saved
    public func saveToLibrary(
        ids: Set<UUID>,
        from publications: [CDPublication],
        currentSelection: CDPublication?,
        targetLibrary: CDLibrary,
        source: TriageSource
    ) -> TriageResult {
        guard !ids.isEmpty else {
            return TriageResult(nextSelectionID: nil, nextPublication: nil, affectedCount: 0)
        }

        // Calculate next selection BEFORE modifying data
        let (nextID, nextPub) = SelectionAdvancement.advanceSelection(
            removing: ids,
            from: publications,
            currentSelection: currentSelection
        )

        let inboxManager = InboxManager.shared
        var savedCount = 0

        for id in ids {
            guard let publication = publications.first(where: { $0.id == id }) else { continue }

            switch source {
            case .inboxLibrary, .inboxFeed:
                // Inbox save: use InboxManager for proper handling
                inboxManager.saveToLibrary(publication, library: targetLibrary)
                // Remove from ALL inbox feeds' result collections (not just the current one)
                // This ensures the paper disappears from all feed views after save
                removeFromAllInboxFeeds(publication)
                savedCount += 1
                // ADR-020: Record save signal for recommendation engine
                Task { await SignalCollector.shared.recordSave(publication) }

            case .regularLibrary(let sourceLibrary):
                // Non-inbox: add to target, remove from source
                publication.addToLibrary(targetLibrary)
                publication.removeFromLibrary(sourceLibrary)
                savedCount += 1
            }
        }

        // Save changes
        PersistenceController.shared.save()

        logger.info("Saved \(savedCount) papers to '\(targetLibrary.displayName)' from \(source.logDescription)")

        return TriageResult(
            nextSelectionID: nextID,
            nextPublication: nextPub,
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
    ///   - currentSelection: Currently selected publication
    ///   - dismissedLibrary: Library to move dismissed papers to
    ///   - source: Where the papers are coming from (for proper cleanup)
    /// - Returns: Result containing the next selection info and count of papers dismissed
    public func dismissFromInbox(
        ids: Set<UUID>,
        from publications: [CDPublication],
        currentSelection: CDPublication?,
        dismissedLibrary: CDLibrary,
        source: TriageSource
    ) -> TriageResult {
        guard !ids.isEmpty else {
            return TriageResult(nextSelectionID: nil, nextPublication: nil, affectedCount: 0)
        }

        // Calculate next selection BEFORE modifying data
        let (nextID, nextPub) = SelectionAdvancement.advanceSelection(
            removing: ids,
            from: publications,
            currentSelection: currentSelection
        )

        let inboxManager = InboxManager.shared
        var dismissedCount = 0

        for id in ids {
            guard let publication = publications.first(where: { $0.id == id }) else { continue }

            // Track dismissal to prevent reappearance
            inboxManager.trackDismissal(publication)

            // Remove from source based on context
            switch source {
            case .inboxLibrary, .inboxFeed:
                // Remove from inbox library
                if let inbox = inboxManager.inboxLibrary {
                    publication.removeFromLibrary(inbox)
                }
                // Remove from ALL inbox feeds' result collections (not just the current one)
                // This ensures the paper disappears from all feed views, not just the one being dismissed from
                removeFromAllInboxFeeds(publication)

            case .regularLibrary(let library):
                // Remove from the regular library
                publication.removeFromLibrary(library)
            }

            // Add to Dismissed library (NOT delete)
            publication.addToLibrary(dismissedLibrary)
            dismissedCount += 1

            // ADR-020: Record dismiss signal for recommendation engine
            Task { await SignalCollector.shared.recordDismiss(publication) }
        }

        // Save changes
        PersistenceController.shared.save()
        inboxManager.updateUnreadCount()

        logger.info("Dismissed \(dismissedCount) papers from \(source.logDescription)")

        return TriageResult(
            nextSelectionID: nextID,
            nextPublication: nextPub,
            affectedCount: dismissedCount
        )
    }

    // MARK: - Private Helpers

    /// Remove a publication from all inbox feeds' result collections.
    /// This ensures dismissed papers don't show up in any feed view.
    private func removeFromAllInboxFeeds(_ publication: CDPublication) {
        let context = PersistenceController.shared.viewContext

        // Fetch all smart searches that feed to inbox
        let request = NSFetchRequest<CDSmartSearch>(entityName: "SmartSearch")
        request.predicate = NSPredicate(format: "feedsToInbox == YES")

        guard let inboxFeeds = try? context.fetch(request) else { return }

        for feed in inboxFeeds {
            if let collection = feed.resultCollection {
                publication.removeFromCollection(collection)
            }
        }
    }
}

// MARK: - Supporting Types

/// The source context for triage operations.
public enum TriageSource {
    /// Viewing the main Inbox library
    case inboxLibrary

    /// Viewing an inbox feed (smart search that feeds to inbox)
    case inboxFeed(CDSmartSearch)

    /// Viewing a regular (non-inbox) library
    case regularLibrary(CDLibrary)

    var logDescription: String {
        switch self {
        case .inboxLibrary:
            return "Inbox"
        case .inboxFeed(let smartSearch):
            return "feed '\(smartSearch.name)'"
        case .regularLibrary(let library):
            return "library '\(library.displayName)'"
        }
    }
}

/// Result of a triage operation.
public struct TriageResult {
    /// The UUID of the next paper to select (or nil if none remain)
    public let nextSelectionID: UUID?

    /// The actual publication to select (for binding updates)
    public let nextPublication: CDPublication?

    /// Number of papers affected by the operation
    public let affectedCount: Int

    public init(nextSelectionID: UUID?, nextPublication: CDPublication?, affectedCount: Int) {
        self.nextSelectionID = nextSelectionID
        self.nextPublication = nextPublication
        self.affectedCount = affectedCount
    }
}
