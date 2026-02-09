//
//  InboxManager.swift
//  PublicationManagerCore
//
//  Manages the Inbox library for paper discovery and curation.
//

import Foundation
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

    /// The Inbox library (lazily loaded on first access)
    public private(set) var inboxLibrary: LibraryModel?

    /// Number of unread papers in the Inbox
    public private(set) var unreadCount: Int = 0

    /// All muted items
    public private(set) var mutedItems: [MutedItem] = []

    /// Shared feed new result counts, keyed by feed name
    public private(set) var sharedFeedCounts: [String: Int] = [:]

    /// Total count of new papers from shared feeds
    public var sharedFeedTotalCount: Int {
        sharedFeedCounts.values.reduce(0, +)
    }

    /// Number of dismissed papers (for Settings display)
    public var dismissedPaperCount: Int {
        let store = RustStoreAdapter.shared
        return store.listDismissedPapers().count
    }

    // MARK: - Properties

    private var store: RustStoreAdapter { RustStoreAdapter.shared }

    // MARK: - Initialization

    public init() {
        loadInbox()
        loadMutedItems()
        setupObservers()
    }

    // MARK: - Inbox Library

    /// Get or create the Inbox library
    @discardableResult
    public func getOrCreateInbox() -> LibraryModel {
        // Return cached reference if still valid
        if let inbox = inboxLibrary {
            // Verify it still exists in the store
            if store.getLibrary(id: inbox.id) != nil {
                return inbox
            }
        }

        // Clear invalid cached reference
        inboxLibrary = nil

        // Try to find existing inbox
        if let existing = store.getInboxLibrary() {
            Logger.inbox.infoCapture("Found existing Inbox library", category: "manager")
            inboxLibrary = existing
            updateUnreadCount()
            return existing
        }

        // Create new Inbox
        Logger.inbox.infoCapture("Creating Inbox library", category: "manager")

        guard let inbox = store.createInboxLibrary(name: "Inbox") else {
            Logger.inbox.errorCapture("Failed to create Inbox library", category: "manager")
            // Return a placeholder that will be replaced on next access
            let placeholder = LibraryModel(id: UUID(), name: "Inbox", isDefault: false, isInbox: true)
            inboxLibrary = placeholder
            return placeholder
        }

        inboxLibrary = inbox
        Logger.inbox.infoCapture("Created Inbox library with ID: \(inbox.id)", category: "manager")
        return inbox
    }

    /// Invalidate cached state after a reset.
    public func invalidateCaches() {
        Logger.inbox.infoCapture("Invalidating InboxManager caches", category: "manager")
        inboxLibrary = nil
        mutedItems = []
        unreadCount = 0
        sharedFeedCounts = [:]
    }

    /// Clear the new-results count for a specific shared feed.
    public func clearSharedFeedCount(feedName: String) {
        sharedFeedCounts.removeValue(forKey: feedName)
    }

    /// Clear all shared feed counts.
    public func clearAllSharedFeedCounts() {
        sharedFeedCounts = [:]
    }

    /// Load the Inbox library from the store
    private func loadInbox() {
        if let inbox = store.getInboxLibrary() {
            inboxLibrary = inbox
            Logger.inbox.debugCapture("Loaded Inbox library", category: "manager")
            updateUnreadCount()
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

        let newCount = store.countUnread(parentId: inbox.id)
        if newCount != unreadCount {
            unreadCount = newCount
            postUnreadCountChanged()
        }
        Logger.inbox.debugCapture("Inbox unread count: \(unreadCount)", category: "unread")
    }

    /// Post notification when unread count changes
    private func postUnreadCountChanged() {
        NotificationCenter.default.post(
            name: .inboxUnreadCountChanged,
            object: nil,
            userInfo: ["count": unreadCount]
        )

        // Update widget data
        let totalCount = inboxLibrary.map { store.queryPublications(parentId: $0.id).count } ?? 0
        WidgetDataStore.shared.updateInboxStats(unread: unreadCount, total: totalCount)
    }

    /// Mark a paper as read in the Inbox
    public func markAsRead(_ publicationID: UUID) {
        store.setRead(ids: [publicationID], read: true)
        updateUnreadCount()
    }

    /// Mark all papers in Inbox as read
    public func markAllAsRead() {
        guard let inbox = inboxLibrary else { return }

        Logger.inbox.infoCapture("Marking all Inbox papers as read", category: "unread")

        let unreadPubs = store.queryUnread(parentId: inbox.id)
        if !unreadPubs.isEmpty {
            store.setRead(ids: unreadPubs.map(\.id), read: true)
            unreadCount = 0
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
                  let pubID = notification.object as? UUID else { return }

            Task { @MainActor in
                self.handleSave(pubID)
            }
        }

        // Listen for shared feed new results
        NotificationCenter.default.addObserver(
            forName: .sharedFeedNewResults,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let userInfo = notification.userInfo,
                  let feedName = userInfo["feedName"] as? String,
                  let count = userInfo["count"] as? Int else { return }

            Task { @MainActor in
                self.sharedFeedCounts[feedName] = count
            }
        }
    }

    /// Handle when a paper is saved to another library
    private func handleSave(_ publicationID: UUID) {
        guard let inbox = inboxLibrary else { return }

        // Check if paper is in Inbox by looking at its detail
        guard let detail = store.getPublicationDetail(id: publicationID) else { return }

        let isInInbox = detail.libraryIDs.contains(inbox.id)
        guard isInInbox else { return }

        // Check if paper is now in any non-Inbox library
        let otherLibraries = detail.libraryIDs.filter { libID in
            if let lib = store.getLibrary(id: libID) {
                return !lib.isInbox
            }
            return false
        }

        if !otherLibraries.isEmpty {
            Logger.inbox.infoCapture("Auto-removing paper from Inbox: \(detail.citeKey)", category: "papers")
            store.movePublications(ids: [publicationID], toLibraryId: otherLibraries.first!)
            updateUnreadCount()
        }
    }

    // MARK: - Mute Management

    /// Load all muted items from the store
    private func loadMutedItems() {
        mutedItems = store.listMutedItems()
        Logger.inbox.debugCapture("Loaded \(mutedItems.count) muted items", category: "mute")
    }

    /// Mute an item (author, paper, venue, category)
    @discardableResult
    public func mute(type: MuteType, value: String) -> MutedItem? {
        Logger.inbox.infoCapture("Muting \(type.rawValue): \(value)", category: "mute")

        // Check if already muted
        if let existing = mutedItems.first(where: { $0.muteType == type.rawValue && $0.value == value }) {
            return existing
        }

        guard let item = store.createMutedItem(muteType: type.rawValue, value: value) else {
            Logger.inbox.errorCapture("Failed to create muted item", category: "mute")
            return nil
        }

        mutedItems.insert(item, at: 0)
        return item
    }

    /// Unmute an item
    public func unmute(_ item: MutedItem) {
        Logger.inbox.infoCapture("Unmuting \(item.muteType): \(item.value)", category: "mute")
        store.deleteItem(id: item.id)
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
            guard let muteType = MuteType(rawValue: item.muteType) else { continue }

            switch muteType {
            case .author:
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
    public func mutedItems(ofType type: MuteType) -> [MutedItem] {
        mutedItems.filter { $0.muteType == type.rawValue }
    }

    /// Clear all muted items
    public func clearAllMutedItems() {
        Logger.inbox.warningCapture("Clearing all \(mutedItems.count) muted items", category: "mute")

        for item in mutedItems {
            store.deleteItem(id: item.id)
        }

        mutedItems = []
    }

    // MARK: - Paper Operations

    /// Add a paper to the Inbox (by importing BibTeX and adding to inbox library)
    public func addToInbox(_ publicationID: UUID) {
        let inbox = getOrCreateInbox()

        // Check if already in inbox
        if let detail = store.getPublicationDetail(id: publicationID),
           detail.libraryIDs.contains(inbox.id) {
            Logger.inbox.debugCapture("Paper already in Inbox", category: "papers")
            return
        }

        Logger.inbox.infoCapture("Adding paper to Inbox", category: "papers")
        store.movePublications(ids: [publicationID], toLibraryId: inbox.id)
        store.setRead(ids: [publicationID], read: false)
        updateUnreadCount()
    }

    /// Add multiple paper IDs to the Inbox in a single batch
    @discardableResult
    public func addToInboxBatch(_ publicationIDs: [UUID]) -> Int {
        let inbox = getOrCreateInbox()
        var addedCount = 0

        for pubID in publicationIDs {
            // Check if already in inbox
            if let detail = store.getPublicationDetail(id: pubID),
               detail.libraryIDs.contains(inbox.id) {
                continue
            }

            store.duplicatePublications(ids: [pubID], toLibraryId: inbox.id)
            store.setRead(ids: [pubID], read: false)
            addedCount += 1
        }

        if addedCount > 0 {
            updateUnreadCount()
            Logger.inbox.infoCapture("Added \(addedCount) papers to Inbox (batch)", category: "papers")
        }

        return addedCount
    }

    /// Remove a paper from the Inbox (dismiss)
    public func dismissFromInbox(_ publicationID: UUID) {
        guard let inbox = inboxLibrary else { return }

        Logger.inbox.infoCapture("Dismissing paper from Inbox", category: "papers")

        // Track dismissal so paper won't reappear
        trackDismissal(publicationID)

        // Delete from inbox library
        store.deletePublications(ids: [publicationID])
        updateUnreadCount()
    }

    /// Save a paper from Inbox to a target library
    public func saveToLibrary(_ publicationID: UUID, libraryID: UUID) {
        Logger.inbox.infoCapture("Saving paper to library", category: "papers")

        // Track dismissal so paper won't reappear in Inbox
        trackDismissal(publicationID)

        // Move to target library (removes from inbox)
        store.movePublications(ids: [publicationID], toLibraryId: libraryID)

        // Update unread count
        updateUnreadCount()

        // Post notification
        NotificationCenter.default.post(name: .publicationSavedToLibrary, object: publicationID)
    }

    /// Get all papers in the Inbox
    public func getInboxPapers() -> [PublicationRowData] {
        guard let inbox = inboxLibrary else { return [] }
        return store.queryPublications(parentId: inbox.id, sort: "created", ascending: false)
    }

    // MARK: - Dismissal Tracking

    /// Track a dismissed paper so it won't reappear in the Inbox
    public func trackDismissal(_ publicationID: UUID) {
        guard let pub = store.getPublication(id: publicationID) else {
            Logger.inbox.debugCapture("Cannot track dismissal for unknown publication", category: "dismiss")
            return
        }

        let doi = pub.doi
        let arxivID = pub.arxivID
        let bibcode = pub.bibcode

        guard doi != nil || arxivID != nil || bibcode != nil else {
            Logger.inbox.debugCapture("Cannot track dismissal for paper without identifiers", category: "dismiss")
            return
        }

        // Check if already tracked
        if wasDismissed(doi: doi, arxivID: arxivID, bibcode: bibcode) {
            return
        }

        store.dismissPaper(doi: doi, arxivId: arxivID, bibcode: bibcode)
        Logger.inbox.infoCapture("Tracked dismissal for paper: DOI=\(doi ?? "nil"), arXiv=\(arxivID ?? "nil"), bibcode=\(bibcode ?? "nil")", category: "dismiss")
    }

    /// Check if a paper was previously dismissed
    public func wasDismissed(doi: String?, arxivID: String?, bibcode: String?) -> Bool {
        guard doi != nil || arxivID != nil || bibcode != nil else {
            return false
        }
        return store.isPaperDismissed(doi: doi, arxivId: arxivID, bibcode: bibcode)
    }

    /// Check if a search result was previously dismissed
    public func wasDismissed(result: SearchResult) -> Bool {
        wasDismissed(doi: result.doi, arxivID: result.arxivID, bibcode: result.bibcode)
    }

    /// Clear all dismissed paper records
    public func clearAllDismissedPapers() {
        let dismissed = store.listDismissedPapers()
        for item in dismissed {
            store.deleteItem(id: item.id)
        }
        Logger.inbox.warningCapture("Cleared \(dismissed.count) dismissed paper records", category: "dismiss")
    }
}

// MARK: - MuteType

/// Types of items that can be muted in the inbox
public enum MuteType: String, CaseIterable, Sendable {
    case author
    case doi
    case bibcode
    case venue
    case arxivCategory
}

// MARK: - Notifications

public extension Notification.Name {
    /// Posted when Inbox unread count changes
    static let inboxUnreadCountChanged = Notification.Name("inboxUnreadCountChanged")
}
