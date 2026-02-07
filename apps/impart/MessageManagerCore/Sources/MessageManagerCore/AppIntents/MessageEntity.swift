import AppIntents
import Foundation

// MARK: - Message Entity

@available(macOS 14.0, iOS 17.0, *)
public struct MessageEntity: AppEntity, Sendable {
    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(
            name: LocalizedStringResource("Message"),
            numericFormat: LocalizedStringResource("\(placeholder: .int) messages")
        )
    }

    public static var defaultQuery = MessageEntityQuery()

    public let id: UUID
    public let subject: String
    public let sender: String
    public let date: Date
    public let snippet: String
    public let isRead: Bool
    public let hasAttachments: Bool

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(subject)",
            subtitle: "\(sender)",
            image: .init(systemName: isRead ? "envelope.open" : "envelope.fill")
        )
    }

    public init(id: UUID, subject: String, sender: String, date: Date = Date(), snippet: String = "", isRead: Bool = false, hasAttachments: Bool = false) {
        self.id = id
        self.subject = subject
        self.sender = sender
        self.date = date
        self.snippet = snippet
        self.isRead = isRead
        self.hasAttachments = hasAttachments
    }

    /// Create from a Message domain model.
    public init(from message: Message) {
        self.id = message.id
        self.subject = message.subject
        self.sender = message.from.first?.displayString ?? "Unknown"
        self.date = message.date
        self.snippet = message.snippet
        self.isRead = message.isRead
        self.hasAttachments = message.hasAttachments
    }
}

// MARK: - Message Entity Query

@available(macOS 14.0, iOS 17.0, *)
public struct MessageEntityQuery: EntityQuery {
    public init() {}

    public func entities(for identifiers: [UUID]) async throws -> [MessageEntity] {
        guard let service = await ImpartIntentServiceLocator.service else { return [] }
        return try await service.messagesForIds(identifiers)
    }

    public func suggestedEntities() async throws -> [MessageEntity] {
        guard let service = await ImpartIntentServiceLocator.service else { return [] }
        return try await service.searchMessages(query: "", maxResults: 10)
    }
}

@available(macOS 14.0, iOS 17.0, *)
public struct MessageEntityStringQuery: EntityStringQuery {
    public init() {}

    public func entities(for identifiers: [UUID]) async throws -> [MessageEntity] {
        guard let service = await ImpartIntentServiceLocator.service else { return [] }
        return try await service.messagesForIds(identifiers)
    }

    public func entities(matching string: String) async throws -> [MessageEntity] {
        guard let service = await ImpartIntentServiceLocator.service else { return [] }
        return try await service.searchMessagesBySubject(string)
    }

    public func suggestedEntities() async throws -> [MessageEntity] {
        guard let service = await ImpartIntentServiceLocator.service else { return [] }
        return try await service.searchMessages(query: "", maxResults: 10)
    }
}
