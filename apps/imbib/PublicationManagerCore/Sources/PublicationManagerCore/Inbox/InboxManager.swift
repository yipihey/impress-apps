//
//  InboxManager.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-06.
//

import Foundation
import CoreData
import OSLog

// MARK: - Inbox Manager

/// Manages the special Inbox library for paper discovery and curation.
///
/// The Inbox is a single global library that receives papers from smart searches
/// and ad-hoc searches. Papers are automatically removed from the Inbox when
/// kept to other libraries.
///
/// Features:
/// - Single global Inbox library (created on first access)
/// - Mute list management (authors, papers, venues, categories)
/// - Unread count tracking
/// - Auto-remove on keep
@MainActor
@Observable
public final class InboxManager {

    // MARK: - Singleton

    public static let shared = InboxManager()

    // MARK: - Published State

    /// The Inbox library (lazily created on first access)
    public private(set) var inboxLibrary: CDLibrary?

    /// Number of unread papers in the Inbox
    public private(set) var unreadCount: Int = 0

    /// All muted items
    public private(set) var mutedItems: [CDMutedItem] = []

    /// Number of dismissed papers (for Settings display)
    public var dismissedPaperCount: Int {
        let request = NSFetchRequest<CDDismissedPaper>(entityName: "DismissedPaper")
        do {
            return try persistenceController.viewContext.count(for: request)
        } catch {
            Logger.inbox.errorCapture("Failed to count dismissed papers: \(error.localizedDescription)", category: "dismiss")
            return 0
        }
    }

    // MARK: - Dependencies

    private let persistenceController: PersistenceController

    // MARK: - Initialization

    public init(persistenceController: PersistenceController = .shared) {
        self.persistenceController = persistenceController
        loadInbox()
        loadMutedItems()
        setupObservers()

        // Clean up orphaned papers in feed collections (papers that were dismissed
        // before the fix that removes papers from all feed collections on dismiss)
        cleanupOrphanedFeedPapers()
    }

    // MARK: - Inbox Library

    /// Get or create the Inbox library
    @discardableResult
    public func getOrCreateInbox() -> CDLibrary {
        // Validate cached reference is still valid (not deleted/faulted)
        if let inbox = inboxLibrary, !inbox.isDeleted, inbox.managedObjectContext != nil {
            return inbox
        }

        // Clear invalid cached reference
        inboxLibrary = nil

        // Try to find existing inbox
        let request = NSFetchRequest<CDLibrary>(entityName: "Library")
        request.predicate = NSPredicate(format: "isInbox == YES")
        request.fetchLimit = 1

        do {
            if let existing = try persistenceController.viewContext.fetch(request).first {
                Logger.inbox.infoCapture("Found existing Inbox library", category: "manager")
                inboxLibrary = existing
                updateUnreadCount()
                return existing
            }
        } catch {
            Logger.inbox.errorCapture("Failed to fetch Inbox: \(error.localizedDescription)", category: "manager")
        }

        // Create new Inbox
        Logger.inbox.infoCapture("Creating Inbox library", category: "manager")

        let context = persistenceController.viewContext
        let inbox = CDLibrary(context: context)
        inbox.id = UUID()
        inbox.name = "Inbox"
        inbox.isInbox = true
        inbox.isDefault = false
        inbox.dateCreated = Date()
        inbox.sortOrder = -1  // Always at top

        persistenceController.save()
        inboxLibrary = inbox

        Logger.inbox.infoCapture("Created Inbox library with ID: \(inbox.id)", category: "manager")
        return inbox
    }

    /// Invalidate cached state after a reset.
    ///
    /// Call this after `FirstRunManager.resetToFirstRun()` to clear stale references
    /// before the app restarts or re-initializes.
    public func invalidateCaches() {
        Logger.inbox.infoCapture("Invalidating InboxManager caches", category: "manager")
        inboxLibrary = nil
        mutedItems = []
        unreadCount = 0
    }

    /// Load the Inbox library from Core Data
    private func loadInbox() {
        let request = NSFetchRequest<CDLibrary>(entityName: "Library")
        request.predicate = NSPredicate(format: "isInbox == YES")
        request.fetchLimit = 1

        do {
            inboxLibrary = try persistenceController.viewContext.fetch(request).first
            if inboxLibrary != nil {
                Logger.inbox.debugCapture("Loaded Inbox library", category: "manager")
                updateUnreadCount()
            }
        } catch {
            Logger.inbox.errorCapture("Failed to load Inbox: \(error.localizedDescription)", category: "manager")
        }
    }

    // MARK: - Unread Count

    /// Update the unread count
    public func updateUnreadCount() {
        guard let inbox = inboxLibrary else {
            if unreadCount != 0 {
                unreadCount = 0
                postUnreadCountChanged()
            }
            return
        }

        // Count unread papers in Inbox
        let request = NSFetchRequest<CDPublication>(entityName: "Publication")
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "ANY libraries == %@", inbox),
            NSPredicate(format: "isRead == NO")
        ])

        do {
            let newCount = try persistenceController.viewContext.count(for: request)
            if newCount != unreadCount {
                unreadCount = newCount
                postUnreadCountChanged()
            }
            Logger.inbox.debugCapture("Inbox unread count: \(unreadCount)", category: "unread")
        } catch {
            Logger.inbox.errorCapture("Failed to count unread: \(error.localizedDescription)", category: "unread")
            if unreadCount != 0 {
                unreadCount = 0
                postUnreadCountChanged()
            }
        }
    }

    /// Post notification when unread count changes
    private func postUnreadCountChanged() {
        NotificationCenter.default.post(
            name: .inboxUnreadCountChanged,
            object: nil,
            userInfo: ["count": unreadCount]
        )

        // Update widget data
        let totalCount = inboxLibrary?.publications?.count ?? 0
        WidgetDataStore.shared.updateInboxStats(unread: unreadCount, total: totalCount)
    }

    /// Mark a paper as read in the Inbox
    public func markAsRead(_ publication: CDPublication) {
        publication.isRead = true
        persistenceController.save()
        updateUnreadCount()
    }

    /// Mark all papers in Inbox as read
    public func markAllAsRead() {
        guard let inbox = inboxLibrary else { return }

        Logger.inbox.infoCapture("Marking all Inbox papers as read", category: "unread")

        let request = NSFetchRequest<CDPublication>(entityName: "Publication")
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "ANY libraries == %@", inbox),
            NSPredicate(format: "isRead == NO")
        ])

        do {
            let unread = try persistenceController.viewContext.fetch(request)
            for pub in unread {
                pub.isRead = true
            }
            persistenceController.save()
            unreadCount = 0
        } catch {
            Logger.inbox.errorCapture("Failed to mark all as read: \(error.localizedDescription)", category: "unread")
        }
    }

    // MARK: - Auto-Remove on Save

    /// Set up observers for auto-remove behavior
    private func setupObservers() {
        // Listen for publications being added to libraries
        NotificationCenter.default.addObserver(
            forName: .publicationSavedToLibrary,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let publication = notification.object as? CDPublication else { return }

            Task { @MainActor in
                self.handleSave(publication)
            }
        }
    }

    /// Handle when a paper is saved to another library
    private func handleSave(_ publication: CDPublication) {
        guard let inbox = inboxLibrary else { return }

        // Check if paper is in Inbox
        guard let libraries = publication.libraries, libraries.contains(inbox) else {
            return
        }

        // Check if paper is now in any non-Inbox library
        let otherLibraries = libraries.filter { !$0.isInbox }
        if !otherLibraries.isEmpty {
            // Remove from Inbox
            Logger.inbox.infoCapture("Auto-removing paper from Inbox: \(publication.citeKey)", category: "papers")
            publication.removeFromLibrary(inbox)
            persistenceController.save()
            updateUnreadCount()
        }
    }

    // MARK: - Mute Management

    /// Load all muted items from Core Data
    private func loadMutedItems() {
        let request = NSFetchRequest<CDMutedItem>(entityName: "MutedItem")
        request.sortDescriptors = [NSSortDescriptor(key: "dateAdded", ascending: false)]

        do {
            mutedItems = try persistenceController.viewContext.fetch(request)
            Logger.inbox.debugCapture("Loaded \(mutedItems.count) muted items", category: "mute")
        } catch {
            Logger.inbox.errorCapture("Failed to load muted items: \(error.localizedDescription)", category: "mute")
            mutedItems = []
        }
    }

    /// Mute an item (author, paper, venue, category)
    @discardableResult
    public func mute(type: CDMutedItem.MuteType, value: String) -> CDMutedItem {
        Logger.inbox.infoCapture("Muting \(type.rawValue): \(value)", category: "mute")

        let context = persistenceController.viewContext

        // Check if already muted
        if let existing = mutedItems.first(where: { $0.type == type.rawValue && $0.value == value }) {
            return existing
        }

        let item = CDMutedItem(context: context)
        item.id = UUID()
        item.type = type.rawValue
        item.value = value
        item.dateAdded = Date()

        persistenceController.save()
        mutedItems.insert(item, at: 0)

        return item
    }

    /// Unmute an item
    public func unmute(_ item: CDMutedItem) {
        Logger.inbox.infoCapture("Unmuting \(item.type): \(item.value)", category: "mute")

        persistenceController.viewContext.delete(item)
        persistenceController.save()
        mutedItems.removeAll { $0.id == item.id }
    }

    /// Check if a paper should be filtered out based on mute rules
    public func shouldFilter(paper: any PaperRepresentable) -> Bool {
        shouldFilter(
            id: paper.id,
            authors: paper.authors,
            doi: paper.doi,
            venue: paper.venue,
            arxivID: paper.arxivID
        )
    }

    /// Check if a search result should be filtered out based on mute rules
    public func shouldFilter(result: SearchResult) -> Bool {
        shouldFilter(
            id: result.id,
            authors: result.authors,
            doi: result.doi,
            venue: result.venue,
            arxivID: result.arxivID
        )
    }

    /// Core mute check with explicit parameters
    public func shouldFilter(
        id: String,
        authors: [String],
        doi: String?,
        venue: String?,
        arxivID: String?
    ) -> Bool {
        for item in mutedItems {
            guard let muteType = item.muteType else { continue }

            switch muteType {
            case .author:
                // Check if any author matches
                if authors.contains(where: { $0.lowercased().contains(item.value.lowercased()) }) {
                    return true
                }

            case .doi:
                if doi?.lowercased() == item.value.lowercased() {
                    return true
                }

            case .bibcode:
                if id.lowercased() == item.value.lowercased() {
                    return true
                }

            case .venue:
                if let venue = venue?.lowercased(), venue.contains(item.value.lowercased()) {
                    return true
                }

            case .arxivCategory:
                if let arxiv = arxivID, arxiv.lowercased().hasPrefix(item.value.lowercased()) {
                    return true
                }
            }
        }

        return false
    }

    /// Get muted items by type
    public func mutedItems(ofType type: CDMutedItem.MuteType) -> [CDMutedItem] {
        mutedItems.filter { $0.type == type.rawValue }
    }

    /// Clear all muted items
    public func clearAllMutedItems() {
        Logger.inbox.warningCapture("Clearing all \(mutedItems.count) muted items", category: "mute")

        for item in mutedItems {
            persistenceController.viewContext.delete(item)
        }

        persistenceController.save()
        mutedItems = []
    }

    // MARK: - Paper Operations

    /// Add a paper to the Inbox
    public func addToInbox(_ publication: CDPublication) {
        let inbox = getOrCreateInbox()

        guard !(publication.libraries?.contains(inbox) ?? false) else {
            Logger.inbox.debugCapture("Paper already in Inbox: \(publication.citeKey)", category: "papers")
            return
        }

        Logger.inbox.infoCapture("Adding paper to Inbox: \(publication.citeKey)", category: "papers")
        publication.addToLibrary(inbox)
        publication.isRead = false  // Mark as unread in Inbox
        publication.dateAddedToInbox = Date()  // Track when added for age filtering
        persistenceController.save()
        updateUnreadCount()
    }

    /// Add multiple papers to the Inbox in a single batch (more efficient than multiple addToInbox calls)
    ///
    /// This avoids multiple Core Data saves and unread count updates.
    /// - Parameter publications: Array of publications to add
    /// - Returns: Number of papers actually added (excludes duplicates)
    @discardableResult
    public func addToInboxBatch(_ publications: [CDPublication]) -> Int {
        let inbox = getOrCreateInbox()
        var addedCount = 0

        for publication in publications {
            guard !(publication.libraries?.contains(inbox) ?? false) else {
                continue  // Skip already in inbox
            }

            publication.addToLibrary(inbox)
            publication.isRead = false
            publication.dateAddedToInbox = Date()
            addedCount += 1
        }

        if addedCount > 0 {
            persistenceController.save()
            updateUnreadCount()
            Logger.inbox.infoCapture("Added \(addedCount) papers to Inbox (batch)", category: "papers")
        }

        return addedCount
    }

    /// Remove a paper from the Inbox (dismiss)
    public func dismissFromInbox(_ publication: CDPublication) {
        guard let inbox = inboxLibrary else { return }

        Logger.inbox.infoCapture("Dismissing paper from Inbox: \(publication.citeKey)", category: "papers")

        // Track dismissal so paper won't reappear
        trackDismissal(publication)

        publication.removeFromLibrary(inbox)

        // If paper is not in any other library, delete it
        if publication.libraries?.isEmpty ?? true {
            persistenceController.viewContext.delete(publication)
        }

        persistenceController.save()
        updateUnreadCount()
    }

    /// Save a paper from Inbox to a target library
    public func saveToLibrary(_ publication: CDPublication, library: CDLibrary) {
        Logger.inbox.infoCapture("Saving paper '\(publication.citeKey)' to library '\(library.displayName)'", category: "papers")

        // Track dismissal so paper won't reappear in Inbox
        trackDismissal(publication)

        // Remove from Inbox
        if let inbox = inboxLibrary {
            publication.removeFromLibrary(inbox)
        }

        // Add to target library
        publication.addToLibrary(library)
        persistenceController.save()

        // Update unread count
        updateUnreadCount()

        // Post notification for auto-remove
        NotificationCenter.default.post(name: .publicationSavedToLibrary, object: publication)
    }

    /// Get all papers in the Inbox, filtered by age limit
    public func getInboxPapers() async -> [CDPublication] {
        guard let inbox = inboxLibrary else { return [] }

        let settings = await InboxSettingsStore.shared.settings

        let request = NSFetchRequest<CDPublication>(entityName: "Publication")

        // Build predicates
        var predicates: [NSPredicate] = [
            NSPredicate(format: "ANY libraries == %@", inbox)
        ]

        // Apply age limit if set
        if settings.ageLimit.hasLimit {
            let cutoffDate = Calendar.current.date(
                byAdding: .day,
                value: -settings.ageLimit.days,
                to: Date()
            ) ?? Date()
            predicates.append(NSPredicate(format: "dateAddedToInbox >= %@ OR dateAddedToInbox == nil", cutoffDate as NSDate))
        }

        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        request.sortDescriptors = [NSSortDescriptor(key: "dateAdded", ascending: false)]

        do {
            let papers = try persistenceController.viewContext.fetch(request)
            Logger.inbox.debugCapture("Fetched \(papers.count) Inbox papers (age limit: \(settings.ageLimit.displayName))", category: "papers")
            return papers
        } catch {
            Logger.inbox.errorCapture("Failed to fetch Inbox papers: \(error.localizedDescription)", category: "papers")
            return []
        }
    }

    /// Synchronous version for compatibility
    public func getInboxPapersSync() -> [CDPublication] {
        guard let inbox = inboxLibrary else { return [] }

        let request = NSFetchRequest<CDPublication>(entityName: "Publication")
        request.predicate = NSPredicate(format: "ANY libraries == %@", inbox)
        request.sortDescriptors = [NSSortDescriptor(key: "dateAdded", ascending: false)]

        do {
            return try persistenceController.viewContext.fetch(request)
        } catch {
            Logger.inbox.errorCapture("Failed to fetch Inbox papers: \(error.localizedDescription)", category: "papers")
            return []
        }
    }

    // MARK: - Dismissal Tracking

    /// Track a dismissed paper so it won't reappear in the Inbox
    public func trackDismissal(_ publication: CDPublication) {
        // Only track if we have at least one identifier
        let doi = publication.doi
        let arxivID = publication.arxivID
        let bibcode = publication.bibcode

        guard doi != nil || arxivID != nil || bibcode != nil else {
            Logger.inbox.debugCapture("Cannot track dismissal for paper without identifiers: \(publication.citeKey)", category: "dismiss")
            return
        }

        // Check if already tracked
        if wasDismissed(doi: doi, arxivID: arxivID, bibcode: bibcode) {
            return
        }

        let context = persistenceController.viewContext
        let dismissed = CDDismissedPaper(context: context)
        dismissed.id = UUID()
        dismissed.doi = doi
        dismissed.arxivID = arxivID
        dismissed.bibcode = bibcode
        dismissed.dateDismissed = Date()

        Logger.inbox.infoCapture("Tracked dismissal for paper: DOI=\(doi ?? "nil"), arXiv=\(arxivID ?? "nil"), bibcode=\(bibcode ?? "nil")", category: "dismiss")
    }

    /// Check if a paper was previously dismissed
    public func wasDismissed(doi: String?, arxivID: String?, bibcode: String?) -> Bool {
        // Need at least one identifier to check
        guard doi != nil || arxivID != nil || bibcode != nil else {
            return false
        }

        let request = NSFetchRequest<CDDismissedPaper>(entityName: "DismissedPaper")

        // Build OR predicate for any matching identifier
        var orPredicates: [NSPredicate] = []

        if let doi = doi {
            orPredicates.append(NSPredicate(format: "doi == %@", doi))
        }
        if let arxivID = arxivID {
            // DismissedPaper has arxivID as a Core Data attribute (unlike Publication which has arxivIDNormalized)
            orPredicates.append(NSPredicate(format: "arxivID == %@", arxivID))
        }
        if let bibcode = bibcode {
            orPredicates.append(NSPredicate(format: "bibcode == %@", bibcode))
        }

        request.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: orPredicates)
        request.fetchLimit = 1

        do {
            let count = try persistenceController.viewContext.count(for: request)
            return count > 0
        } catch {
            Logger.inbox.errorCapture("Failed to check dismissal status: \(error.localizedDescription)", category: "dismiss")
            return false
        }
    }

    /// Check if a search result was previously dismissed
    public func wasDismissed(result: SearchResult) -> Bool {
        wasDismissed(doi: result.doi, arxivID: result.arxivID, bibcode: result.bibcode)
    }

    /// Clear all dismissed paper records (for testing)
    public func clearAllDismissedPapers() {
        let request = NSFetchRequest<CDDismissedPaper>(entityName: "DismissedPaper")

        do {
            let dismissed = try persistenceController.viewContext.fetch(request)
            for item in dismissed {
                persistenceController.viewContext.delete(item)
            }
            persistenceController.save()
            Logger.inbox.warningCapture("Cleared \(dismissed.count) dismissed paper records", category: "dismiss")
        } catch {
            Logger.inbox.errorCapture("Failed to clear dismissed papers: \(error.localizedDescription)", category: "dismiss")
        }
    }

    // MARK: - Feed Collection Cleanup

    /// Synchronize inbox feed collections with the inbox library.
    ///
    /// Removes papers from feed result collections if they're not in the inbox library.
    /// This cleans up orphaned papers that were dismissed before the fix that removes
    /// papers from all feed collections on dismiss.
    public func cleanupOrphanedFeedPapers() {
        guard let inbox = inboxLibrary else { return }

        let context = persistenceController.viewContext

        // Get all inbox feeds
        let feedRequest = NSFetchRequest<CDSmartSearch>(entityName: "SmartSearch")
        feedRequest.predicate = NSPredicate(format: "feedsToInbox == YES")

        guard let inboxFeeds = try? context.fetch(feedRequest) else { return }

        // Get all paper IDs that are in the inbox library
        let inboxPaperIDs = Set((inbox.publications ?? []).map { $0.id })

        var removedCount = 0

        for feed in inboxFeeds {
            guard let collection = feed.resultCollection,
                  let feedPapers = collection.publications else {
                continue
            }

            // Find papers in this feed's collection that are NOT in the inbox library
            let orphanedPapers = feedPapers.filter { !inboxPaperIDs.contains($0.id) }

            for paper in orphanedPapers {
                paper.removeFromCollection(collection)
                removedCount += 1
            }
        }

        if removedCount > 0 {
            persistenceController.save()
            Logger.inbox.infoCapture(
                "Cleaned up \(removedCount) orphaned papers from feed collections",
                category: "cleanup"
            )
        }
    }
}

// MARK: - Notifications

public extension Notification.Name {
    /// Posted when Inbox unread count changes
    static let inboxUnreadCountChanged = Notification.Name("inboxUnreadCountChanged")
}
