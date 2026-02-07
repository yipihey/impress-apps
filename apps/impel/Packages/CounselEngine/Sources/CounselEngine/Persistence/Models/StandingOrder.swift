import Foundation
import GRDB

/// A recurring task definition.
public struct StandingOrder: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    public static let databaseTableName = "standingOrder"

    public let id: String
    public var conversationID: String?
    public var description: String
    public var schedule: String
    public var toolChain: String
    public var lastRunAt: Date?
    public var nextRunAt: Date?
    public var isActive: Bool
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        conversationID: String? = nil,
        description: String,
        schedule: String,
        toolChain: String = "[]",
        lastRunAt: Date? = nil,
        nextRunAt: Date? = nil,
        isActive: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.conversationID = conversationID
        self.description = description
        self.schedule = schedule
        self.toolChain = toolChain
        self.lastRunAt = lastRunAt
        self.nextRunAt = nextRunAt
        self.isActive = isActive
        self.createdAt = createdAt
    }
}
