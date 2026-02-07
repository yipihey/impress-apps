import Foundation
import GRDB

/// Record of a single tool call execution.
public struct CounselToolExecution: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    public static let databaseTableName = "counselToolExecution"

    public let id: String
    public var messageID: String?
    public let conversationID: String
    public let toolName: String
    public let toolInput: String
    public var toolOutput: String
    public var isError: Bool
    public var durationMs: Int
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        messageID: String? = nil,
        conversationID: String,
        toolName: String,
        toolInput: String,
        toolOutput: String = "",
        isError: Bool = false,
        durationMs: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.messageID = messageID
        self.conversationID = conversationID
        self.toolName = toolName
        self.toolInput = toolInput
        self.toolOutput = toolOutput
        self.isError = isError
        self.durationMs = durationMs
        self.createdAt = createdAt
    }
}
