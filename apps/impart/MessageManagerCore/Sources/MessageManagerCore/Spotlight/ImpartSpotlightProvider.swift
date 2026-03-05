import CoreData
import CoreSpotlight
import Foundation
import ImpressSpotlight
import UniformTypeIdentifiers

/// Adapts impart's conversations for Spotlight indexing.
///
/// Indexes CDThread (email threads) and CDResearchConversation entries
/// so researchers can find conversations via system Spotlight.
public struct ImpartSpotlightProvider: SpotlightItemProvider {
    public let domain = SpotlightDomain.conversation
    public let legacyDomains = ["com.impart.conversation"]

    public init() {}

    @MainActor
    public func allItemIDs() async -> Set<UUID> {
        let context = PersistenceController.shared.viewContext

        var allIDs = Set<UUID>()

        // Fetch thread IDs
        let threadRequest = NSFetchRequest<CDThread>(entityName: "Thread")
        if let threads = try? context.fetch(threadRequest) {
            for thread in threads {
                allIDs.insert(thread.id)
            }
        }

        // Fetch research conversation IDs
        let rcRequest = NSFetchRequest<CDResearchConversation>(entityName: "ResearchConversation")
        if let conversations = try? context.fetch(rcRequest) {
            for conv in conversations {
                allIDs.insert(conv.id)
            }
        }

        return allIDs
    }

    @MainActor
    public func spotlightItems(for ids: [UUID]) async -> [any SpotlightItem] {
        let context = PersistenceController.shared.viewContext
        var items: [any SpotlightItem] = []

        // Fetch threads
        let threadRequest = NSFetchRequest<CDThread>(entityName: "Thread")
        if let threads = try? context.fetch(threadRequest) {
            let threadsByID = Dictionary(
                threads.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            for id in ids {
                if let thread = threadsByID[id] {
                    items.append(ConversationSpotlightItem(
                        id: id,
                        subject: thread.subject,
                        participants: thread.participantsDisplayString,
                        preview: thread.latestSnippet
                    ))
                }
            }
        }

        // Fetch research conversations
        let rcRequest = NSFetchRequest<CDResearchConversation>(entityName: "ResearchConversation")
        if let conversations = try? context.fetch(rcRequest) {
            let convsByID = Dictionary(
                conversations.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            for id in ids {
                if let conv = convsByID[id] {
                    items.append(ConversationSpotlightItem(
                        id: id,
                        subject: conv.title,
                        participants: nil,
                        preview: conv.latestSnippet
                    ))
                }
            }
        }

        return items
    }
}

// MARK: - Conversation → SpotlightItem

struct ConversationSpotlightItem: SpotlightItem {
    let spotlightID: UUID
    let spotlightDomain: String
    let spotlightAttributeSet: CSSearchableItemAttributeSet

    init(id: UUID, subject: String, participants: String?, preview: String?) {
        self.spotlightID = id
        self.spotlightDomain = SpotlightDomain.conversation

        let attrs = CSSearchableItemAttributeSet(contentType: .text)
        attrs.title = subject
        attrs.displayName = subject

        if let participants, !participants.isEmpty {
            attrs.authorNames = participants.components(separatedBy: ", ")
        }

        attrs.contentDescription = preview
        attrs.url = URL(string: "impart://open/conversation/\(id.uuidString)")

        self.spotlightAttributeSet = attrs
    }
}
