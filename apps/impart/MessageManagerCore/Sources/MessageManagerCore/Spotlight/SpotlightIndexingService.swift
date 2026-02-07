import Foundation
import CoreSpotlight
import OSLog

/// Indexes impart conversations for system Spotlight search.
public actor SpotlightIndexingService {
    public static let shared = SpotlightIndexingService()
    public static let domainIdentifier = "com.impart.conversation"

    private let index: CSSearchableIndex
    private var isAvailable: Bool = true

    private init() {
        self.index = CSSearchableIndex.default()
        Task { await checkAvailability() }
    }

    private func checkAvailability() {
        isAvailable = true
        Logger.spotlight.info("impart Spotlight indexing service initialized")
    }

    /// Index a conversation for Spotlight search.
    public func indexConversation(id: UUID, subject: String, participants: [String], preview: String) async {
        guard isAvailable else { return }

        let attributeSet = CSSearchableItemAttributeSet(contentType: .text)
        attributeSet.title = subject
        attributeSet.displayName = subject
        attributeSet.authorNames = participants
        attributeSet.contentDescription = preview
        attributeSet.url = URL(string: "impart://open/conversation/\(id.uuidString)")

        let item = CSSearchableItem(
            uniqueIdentifier: id.uuidString,
            domainIdentifier: Self.domainIdentifier,
            attributeSet: attributeSet
        )
        item.expirationDate = Date.distantFuture

        do {
            try await index.indexSearchableItems([item])
            Logger.spotlight.debug("Indexed conversation: \(subject)")
        } catch {
            Logger.spotlight.error("Failed to index conversation \(subject): \(error.localizedDescription)")
        }
    }

    /// Remove a conversation from the Spotlight index.
    public func removeConversation(id: UUID) async {
        guard isAvailable else { return }
        do {
            try await index.deleteSearchableItems(withIdentifiers: [id.uuidString])
            Logger.spotlight.debug("Removed conversation from Spotlight: \(id.uuidString)")
        } catch {
            Logger.spotlight.error("Failed to remove conversation from Spotlight: \(error.localizedDescription)")
        }
    }

    /// Remove all impart items from the Spotlight index.
    public func removeAllItems() async {
        guard isAvailable else { return }
        do {
            try await index.deleteSearchableItems(withDomainIdentifiers: [Self.domainIdentifier])
            Logger.spotlight.info("Removed all impart items from Spotlight index")
        } catch {
            Logger.spotlight.error("Failed to remove all items from Spotlight: \(error.localizedDescription)")
        }
    }

    /// Rebuild the entire Spotlight index.
    public func rebuildIndex(conversations: [(id: UUID, subject: String, participants: [String], preview: String)]) async {
        guard isAvailable else { return }
        Logger.spotlight.info("Rebuilding Spotlight index with \(conversations.count) conversations")
        await removeAllItems()
        for conv in conversations {
            await indexConversation(id: conv.id, subject: conv.subject, participants: conv.participants, preview: conv.preview)
        }
        Logger.spotlight.info("Spotlight index rebuild complete")
    }
}

extension Logger {
    static let spotlight = Logger(subsystem: "com.imbib.impart", category: "spotlight")
}
