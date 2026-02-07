import Foundation
import GRDB

/// A conversation groups related emails into a thread.
public struct CounselConversation: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    public static let databaseTableName = "counselConversation"

    public let id: String
    public var subject: String
    public var participantEmail: String
    public var createdAt: Date
    public var updatedAt: Date
    public var status: ConversationStatus
    public var summary: String?
    public var totalTokensUsed: Int
    public var messageCount: Int

    public init(
        id: String = UUID().uuidString,
        subject: String,
        participantEmail: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        status: ConversationStatus = .active,
        summary: String? = nil,
        totalTokensUsed: Int = 0,
        messageCount: Int = 0
    ) {
        self.id = id
        self.subject = subject
        self.participantEmail = participantEmail
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.status = status
        self.summary = summary
        self.totalTokensUsed = totalTokensUsed
        self.messageCount = messageCount
    }
}

public enum ConversationStatus: String, Codable, Sendable {
    case active
    case archived
    case failed
}
