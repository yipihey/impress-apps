//
//  AgentMessageHandler.swift
//  MessageManagerCore
//
//  Handles messages to/from AI agents.
//  Queues messages for AI processing and generates responses.
//

import Foundation
import OSLog

private let agentLogger = Logger(subsystem: "com.impart", category: "agent")

// MARK: - Agent Message Status

/// Status of an agent-processed message.
public enum AgentMessageStatus: String, Codable, Sendable {
    case pending        // Waiting to be processed
    case processing     // Currently being processed by AI
    case completed      // Processing complete, response generated
    case failed         // Processing failed
    case cancelled      // Processing cancelled by user
}

// MARK: - Agent Request

/// Request for AI agent processing.
public struct AgentRequest: Identifiable, Codable, Sendable {
    public let id: UUID
    public let messageId: UUID
    public let agentAddress: AgentAddress
    public let subject: String
    public let body: String
    public let context: AgentContext?
    public let createdAt: Date
    public var status: AgentMessageStatus

    public init(
        id: UUID = UUID(),
        messageId: UUID,
        agentAddress: AgentAddress,
        subject: String,
        body: String,
        context: AgentContext? = nil,
        createdAt: Date = Date(),
        status: AgentMessageStatus = .pending
    ) {
        self.id = id
        self.messageId = messageId
        self.agentAddress = agentAddress
        self.subject = subject
        self.body = body
        self.context = context
        self.createdAt = createdAt
        self.status = status
    }
}

// MARK: - Agent Context

/// Additional context for agent processing.
public struct AgentContext: Codable, Sendable {
    /// Previous messages in the conversation.
    public var conversationHistory: [ConversationMessage]?

    /// Referenced papers (for research agents).
    public var referencedPapers: [PaperReference]?

    /// User preferences for the response.
    public var preferences: AgentPreferences?

    public init(
        conversationHistory: [ConversationMessage]? = nil,
        referencedPapers: [PaperReference]? = nil,
        preferences: AgentPreferences? = nil
    ) {
        self.conversationHistory = conversationHistory
        self.referencedPapers = referencedPapers
        self.preferences = preferences
    }
}

/// Message in conversation history.
public struct ConversationMessage: Codable, Sendable {
    public let role: String  // "user", "assistant", "agent"
    public let content: String
    public let timestamp: Date

    public init(role: String, content: String, timestamp: Date = Date()) {
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
}

/// Reference to a paper (for imbib integration).
public struct PaperReference: Codable, Sendable {
    public let title: String
    public let authors: [String]
    public let year: Int?
    public let doi: String?
    public let arxivId: String?
    public let citeKey: String?

    public init(
        title: String,
        authors: [String],
        year: Int? = nil,
        doi: String? = nil,
        arxivId: String? = nil,
        citeKey: String? = nil
    ) {
        self.title = title
        self.authors = authors
        self.year = year
        self.doi = doi
        self.arxivId = arxivId
        self.citeKey = citeKey
    }
}

/// User preferences for agent responses.
public struct AgentPreferences: Codable, Sendable {
    public var tone: ResponseTone?
    public var length: ResponseLength?
    public var format: ResponseFormat?

    public init(
        tone: ResponseTone? = nil,
        length: ResponseLength? = nil,
        format: ResponseFormat? = nil
    ) {
        self.tone = tone
        self.length = length
        self.format = format
    }
}

public enum ResponseTone: String, Codable, Sendable {
    case formal
    case casual
    case technical
    case friendly
}

public enum ResponseLength: String, Codable, Sendable {
    case brief
    case moderate
    case detailed
}

public enum ResponseFormat: String, Codable, Sendable {
    case plainText
    case markdown
    case html
}

// MARK: - Agent Response

/// Response from AI agent.
public struct AgentResponse: Identifiable, Codable, Sendable {
    public let id: UUID
    public let requestId: UUID
    public let agentAddress: AgentAddress
    public let subject: String
    public let body: String
    public let generatedAt: Date
    public let modelUsed: String?
    public let tokenCount: Int?

    public init(
        id: UUID = UUID(),
        requestId: UUID,
        agentAddress: AgentAddress,
        subject: String,
        body: String,
        generatedAt: Date = Date(),
        modelUsed: String? = nil,
        tokenCount: Int? = nil
    ) {
        self.id = id
        self.requestId = requestId
        self.agentAddress = agentAddress
        self.subject = subject
        self.body = body
        self.generatedAt = generatedAt
        self.modelUsed = modelUsed
        self.tokenCount = tokenCount
    }
}

// MARK: - Agent Message Handler

/// Actor-based handler for AI agent messages.
public actor AgentMessageHandler {

    // MARK: - Properties

    /// Pending requests queue.
    private var pendingRequests: [AgentRequest] = []

    /// Completed responses.
    private var responses: [UUID: AgentResponse] = [:]

    /// Whether the handler is processing.
    private var isProcessing = false

    // MARK: - Initialization

    public init() {}

    // MARK: - Queue Management

    /// Queue a message for agent processing.
    public func queueMessage(
        messageId: UUID,
        agentAddress: AgentAddress,
        subject: String,
        body: String,
        context: AgentContext? = nil
    ) -> AgentRequest {
        let request = AgentRequest(
            messageId: messageId,
            agentAddress: agentAddress,
            subject: subject,
            body: body,
            context: context
        )

        pendingRequests.append(request)
        agentLogger.info("Queued message for \(agentAddress.displayName): \(subject)")

        return request
    }

    /// Get pending requests.
    public func getPendingRequests() -> [AgentRequest] {
        pendingRequests.filter { $0.status == .pending }
    }

    /// Get request by ID.
    public func getRequest(_ id: UUID) -> AgentRequest? {
        pendingRequests.first { $0.id == id }
    }

    /// Cancel a pending request.
    public func cancelRequest(_ id: UUID) {
        if let index = pendingRequests.firstIndex(where: { $0.id == id }) {
            pendingRequests[index].status = .cancelled
            agentLogger.info("Cancelled request \(id)")
        }
    }

    /// Get response for a request.
    public func getResponse(for requestId: UUID) -> AgentResponse? {
        responses[requestId]
    }

    // MARK: - Processing

    /// Process the next pending request.
    /// This is a placeholder - actual AI integration will be implemented via ImpressAI.
    public func processNextRequest() async -> AgentResponse? {
        guard !isProcessing else { return nil }
        guard let index = pendingRequests.firstIndex(where: { $0.status == .pending }) else {
            return nil
        }

        isProcessing = true
        pendingRequests[index].status = .processing
        let request = pendingRequests[index]

        agentLogger.info("Processing request for \(request.agentAddress.displayName)")

        // TODO: Integrate with ImpressAI for actual processing
        // For now, generate a placeholder response

        let response = AgentResponse(
            requestId: request.id,
            agentAddress: request.agentAddress,
            subject: "Re: \(request.subject)",
            body: "[AI response would be generated here via ImpressAI]",
            modelUsed: request.agentAddress.modelName
        )

        pendingRequests[index].status = .completed
        responses[request.id] = response
        isProcessing = false

        agentLogger.info("Completed request \(request.id)")

        return response
    }

    /// Process all pending requests.
    public func processAllPendingRequests() async -> [AgentResponse] {
        var allResponses: [AgentResponse] = []

        while let response = await processNextRequest() {
            allResponses.append(response)
        }

        return allResponses
    }

    // MARK: - Message Detection

    /// Check if a message should be handled by an agent.
    public func shouldHandleMessage(
        toAddresses: [EmailAddress],
        ccAddresses: [EmailAddress]
    ) -> AgentAddress? {
        // Check to addresses first
        if let agent = AgentAddress.findAgents(in: toAddresses).first {
            return agent
        }
        // Then check CC
        if let agent = AgentAddress.findAgents(in: ccAddresses).first {
            return agent
        }
        return nil
    }

    /// Create a draft message to an agent.
    public func createAgentDraft(
        type: AgentType,
        model: String,
        accountId: UUID,
        subject: String = "",
        body: String = ""
    ) -> DraftMessage {
        let agentEmail = AgentAddress.create(type: type, model: model)
        let agentAddress = EmailAddress(name: "\(type.displayName) Agent", email: agentEmail)

        return DraftMessage(
            accountId: accountId,
            to: [agentAddress],
            subject: subject,
            body: body
        )
    }
}

// MARK: - Agent Conversation

/// A conversation with an AI agent.
public struct AgentConversation: Identifiable, Codable, Sendable {
    public let id: UUID
    public let agentAddress: AgentAddress
    public let startedAt: Date
    public var messages: [AgentConversationMessage]

    public init(
        id: UUID = UUID(),
        agentAddress: AgentAddress,
        startedAt: Date = Date(),
        messages: [AgentConversationMessage] = []
    ) {
        self.id = id
        self.agentAddress = agentAddress
        self.startedAt = startedAt
        self.messages = messages
    }

    public var latestMessage: AgentConversationMessage? {
        messages.max { $0.timestamp < $1.timestamp }
    }

    public var messageCount: Int {
        messages.count
    }
}

/// Message in an agent conversation.
public struct AgentConversationMessage: Identifiable, Codable, Sendable {
    public let id: UUID
    public let isFromAgent: Bool
    public let content: String
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        isFromAgent: Bool,
        content: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.isFromAgent = isFromAgent
        self.content = content
        self.timestamp = timestamp
    }
}
