import Foundation
import GRDB

/// Status of a counsel task through its lifecycle.
public enum CounselTaskStatus: String, Codable, Sendable {
    case queued
    case running
    case completed
    case failed
    case cancelled
}

/// A structured task submitted to the counsel agent engine.
///
/// Tasks are the programmatic entry point for agent orchestration. Any app
/// can submit a task via HTTP and poll or stream for results. The email
/// gateway is rebuilt as a thin adapter on top of this.
public struct CounselTask: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    public static let databaseTableName = "counselTask"

    public let id: String
    public var intent: String
    public var query: String
    public var sourceApp: String
    public var conversationID: String?
    public var callbackURL: String?
    public var status: CounselTaskStatus
    public var responseText: String?
    public var toolExecutionCount: Int
    public var roundsUsed: Int
    public var totalInputTokens: Int
    public var totalOutputTokens: Int
    public var finishReason: String?
    public var errorMessage: String?
    public let createdAt: Date
    public var startedAt: Date?
    public var completedAt: Date?

    public init(
        id: String = UUID().uuidString,
        intent: String,
        query: String,
        sourceApp: String = "api",
        conversationID: String? = nil,
        callbackURL: String? = nil,
        status: CounselTaskStatus = .queued,
        responseText: String? = nil,
        toolExecutionCount: Int = 0,
        roundsUsed: Int = 0,
        totalInputTokens: Int = 0,
        totalOutputTokens: Int = 0,
        finishReason: String? = nil,
        errorMessage: String? = nil,
        createdAt: Date = Date(),
        startedAt: Date? = nil,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.intent = intent
        self.query = query
        self.sourceApp = sourceApp
        self.conversationID = conversationID
        self.callbackURL = callbackURL
        self.status = status
        self.responseText = responseText
        self.toolExecutionCount = toolExecutionCount
        self.roundsUsed = roundsUsed
        self.totalInputTokens = totalInputTokens
        self.totalOutputTokens = totalOutputTokens
        self.finishReason = finishReason
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    /// Total tokens used (input + output).
    public var totalTokensUsed: Int { totalInputTokens + totalOutputTokens }
}
