import Foundation
import GRDB

/// An individual message in a conversation.
public struct CounselMessage: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    public static let databaseTableName = "counselMessage"

    public let id: String
    public let conversationID: String
    public let role: MessageRole
    public let content: String
    public var emailMessageID: String?
    public var inReplyTo: String?
    public var intent: String?
    public let createdAt: Date
    public var tokenCount: Int

    public init(
        id: String = UUID().uuidString,
        conversationID: String,
        role: MessageRole,
        content: String,
        emailMessageID: String? = nil,
        inReplyTo: String? = nil,
        intent: String? = nil,
        createdAt: Date = Date(),
        tokenCount: Int = 0
    ) {
        self.id = id
        self.conversationID = conversationID
        self.role = role
        self.content = content
        self.emailMessageID = emailMessageID
        self.inReplyTo = inReplyTo
        self.intent = intent
        self.createdAt = createdAt
        self.tokenCount = tokenCount
    }
}

public enum MessageRole: String, Codable, Sendable {
    case user
    case assistant
    case system
    case toolUse = "tool_use"
    case toolResult = "tool_result"
}
