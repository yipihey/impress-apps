import AppIntents
import Foundation

// MARK: - Thread Entity

@available(macOS 14.0, *)
public struct ThreadEntity: AppEntity, Sendable {
    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(
            name: LocalizedStringResource("Thread"),
            numericFormat: LocalizedStringResource("\(placeholder: .int) threads")
        )
    }

    public static var defaultQuery = ThreadEntityQuery()

    public let id: UUID
    public let title: String
    public let persona: String
    public let status: String
    public let messageCount: Int
    public let createdAt: Date
    public let lastActivity: Date

    public var displayRepresentation: DisplayRepresentation {
        let statusIcon: String
        switch status {
        case "active": statusIcon = "circle.fill"
        case "blocked": statusIcon = "exclamationmark.circle"
        case "completed": statusIcon = "checkmark.circle"
        default: statusIcon = "circle"
        }
        return DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(persona) — \(status)",
            image: .init(systemName: statusIcon)
        )
    }

    public init(id: UUID, title: String, persona: String = "", status: String = "active", messageCount: Int = 0, createdAt: Date = Date(), lastActivity: Date = Date()) {
        self.id = id
        self.title = title
        self.persona = persona
        self.status = status
        self.messageCount = messageCount
        self.createdAt = createdAt
        self.lastActivity = lastActivity
    }
}

// MARK: - Thread Entity Query

@available(macOS 14.0, *)
public struct ThreadEntityQuery: EntityQuery {
    public init() {}

    public func entities(for identifiers: [UUID]) async throws -> [ThreadEntity] {
        // TODO: Connect to thread persistence
        return []
    }

    public func suggestedEntities() async throws -> [ThreadEntity] {
        // TODO: Return active threads
        return []
    }
}

// MARK: - Escalation Entity

@available(macOS 14.0, *)
public struct EscalationEntity: AppEntity, Sendable {
    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(
            name: LocalizedStringResource("Escalation"),
            numericFormat: LocalizedStringResource("\(placeholder: .int) escalations")
        )
    }

    public static var defaultQuery = EscalationEntityQuery()

    public let id: UUID
    public let threadID: UUID
    public let summary: String
    public let priority: String
    public let createdAt: Date

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(summary)",
            subtitle: "\(priority) priority",
            image: .init(systemName: "exclamationmark.triangle")
        )
    }

    public init(id: UUID, threadID: UUID, summary: String, priority: String = "normal", createdAt: Date = Date()) {
        self.id = id
        self.threadID = threadID
        self.summary = summary
        self.priority = priority
        self.createdAt = createdAt
    }
}

@available(macOS 14.0, *)
public struct EscalationEntityQuery: EntityQuery {
    public init() {}

    public func entities(for identifiers: [UUID]) async throws -> [EscalationEntity] {
        return []
    }

    public func suggestedEntities() async throws -> [EscalationEntity] {
        return []
    }
}
