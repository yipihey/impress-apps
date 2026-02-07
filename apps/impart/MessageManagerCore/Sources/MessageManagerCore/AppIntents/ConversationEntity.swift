import AppIntents
import Foundation

// MARK: - Conversation Entity

@available(macOS 14.0, iOS 17.0, *)
public struct ConversationEntity: AppEntity, Sendable {
    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(
            name: LocalizedStringResource("Conversation"),
            numericFormat: LocalizedStringResource("\(placeholder: .int) conversations")
        )
    }

    public static var defaultQuery = ConversationEntityQuery()

    public let id: UUID
    public let title: String
    public let participants: String
    public let messageCount: Int
    public let lastActivity: Date
    public let isArchived: Bool

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(participants) — \(messageCount) messages",
            image: .init(systemName: isArchived ? "archivebox" : "bubble.left.and.bubble.right")
        )
    }

    public init(id: UUID, title: String, participants: String = "", messageCount: Int = 0, lastActivity: Date = Date(), isArchived: Bool = false) {
        self.id = id
        self.title = title
        self.participants = participants
        self.messageCount = messageCount
        self.lastActivity = lastActivity
        self.isArchived = isArchived
    }

    /// Create from a ResearchConversation domain model.
    public init(from conversation: ResearchConversation) {
        self.id = conversation.id
        self.title = conversation.title
        self.participants = conversation.participants.joined(separator: ", ")
        self.messageCount = conversation.messageCount
        self.lastActivity = conversation.lastActivityAt
        self.isArchived = conversation.isArchived
    }
}

// MARK: - Conversation Entity Query

@available(macOS 14.0, iOS 17.0, *)
public struct ConversationEntityQuery: EntityQuery {
    public init() {}

    public func entities(for identifiers: [UUID]) async throws -> [ConversationEntity] {
        guard let service = await ImpartIntentServiceLocator.service else { return [] }
        return try await service.conversationsForIds(identifiers)
    }

    public func suggestedEntities() async throws -> [ConversationEntity] {
        guard let service = await ImpartIntentServiceLocator.service else { return [] }
        return try await service.listConversations(limit: 10, includeArchived: false)
    }
}

@available(macOS 14.0, iOS 17.0, *)
public struct ConversationEntityStringQuery: EntityStringQuery {
    public init() {}

    public func entities(for identifiers: [UUID]) async throws -> [ConversationEntity] {
        guard let service = await ImpartIntentServiceLocator.service else { return [] }
        return try await service.conversationsForIds(identifiers)
    }

    public func entities(matching string: String) async throws -> [ConversationEntity] {
        guard let service = await ImpartIntentServiceLocator.service else { return [] }
        return try await service.searchConversationsByTitle(string)
    }

    public func suggestedEntities() async throws -> [ConversationEntity] {
        guard let service = await ImpartIntentServiceLocator.service else { return [] }
        return try await service.listConversations(limit: 10, includeArchived: false)
    }
}
