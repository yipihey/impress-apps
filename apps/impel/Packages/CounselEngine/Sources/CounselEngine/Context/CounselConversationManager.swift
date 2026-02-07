import Foundation
import ImpelMail
import ImpressAI
import OSLog

/// Resolves email threads to conversations and loads context.
public final class CounselConversationManager: Sendable {
    private let logger = Logger(subsystem: "com.impress.impel", category: "counsel-context")
    private let database: CounselDatabase

    public init(database: CounselDatabase) {
        self.database = database
    }

    /// Resolve an incoming email to a conversation, creating one if needed.
    /// Uses In-Reply-To and References headers for thread matching.
    public func resolveConversation(for request: CounselRequest) throws -> CounselConversation {
        // Strategy 1: Check In-Reply-To header
        if let inReplyTo = request.inReplyTo,
           let existing = try database.fetchConversationByEmailMessageID(inReplyTo) {
            logger.info("Resolved conversation via In-Reply-To: \(existing.id)")
            return existing
        }

        // Strategy 2: Check References headers (walk backwards for most recent)
        for reference in request.references.reversed() {
            if let existing = try database.fetchConversationByEmailMessageID(reference) {
                logger.info("Resolved conversation via References: \(existing.id)")
                return existing
            }
        }

        // Strategy 3: Create a new conversation
        let conversation = CounselConversation(
            subject: request.subject,
            participantEmail: request.from
        )
        try database.createConversation(conversation)
        logger.info("Created new conversation: \(conversation.id) for '\(request.subject)'")
        return conversation
    }

    /// Load conversation history as AIMessages for the agentic loop.
    public func loadHistory(conversationID: String) throws -> [AIMessage] {
        let messages = try database.fetchMessages(conversationID: conversationID)
        return messages.compactMap { msg -> AIMessage? in
            switch msg.role {
            case .user:
                return AIMessage(role: .user, text: msg.content)
            case .assistant:
                return AIMessage(role: .assistant, text: msg.content)
            case .system:
                return nil // System messages are handled via systemPrompt
            case .toolUse:
                // Reconstruct tool use content from stored JSON
                if let data = msg.content.data(using: .utf8),
                   let toolUses = try? JSONDecoder().decode([StoredToolUse].self, from: data) {
                    let content = toolUses.map { tu -> AIContent in
                        .toolUse(AIToolUse(
                            id: tu.id,
                            name: tu.name,
                            input: tu.input.mapValues { AnySendable($0) }
                        ))
                    }
                    return AIMessage(role: .assistant, content: content)
                }
                return nil
            case .toolResult:
                // Reconstruct tool result content from stored JSON
                if let data = msg.content.data(using: .utf8),
                   let toolResults = try? JSONDecoder().decode([StoredToolResult].self, from: data) {
                    let content = toolResults.map { tr -> AIContent in
                        .toolResult(AIToolResult(
                            toolUseId: tr.toolUseId,
                            content: tr.content,
                            isError: tr.isError
                        ))
                    }
                    return AIMessage(role: .user, content: content)
                }
                return nil
            }
        }
    }

    /// Persist a user message from an incoming email.
    public func persistUserMessage(
        conversationID: String,
        content: String,
        emailMessageID: String,
        inReplyTo: String?,
        intent: String?
    ) throws -> CounselMessage {
        let message = CounselMessage(
            conversationID: conversationID,
            role: .user,
            content: content,
            emailMessageID: emailMessageID,
            inReplyTo: inReplyTo,
            intent: intent,
            tokenCount: estimateTokens(content)
        )
        try database.addMessage(message)
        return message
    }

    /// Persist the assistant's final response.
    public func persistAssistantMessage(
        conversationID: String,
        content: String,
        emailMessageID: String? = nil,
        inReplyTo: String? = nil
    ) throws -> CounselMessage {
        let message = CounselMessage(
            conversationID: conversationID,
            role: .assistant,
            content: content,
            emailMessageID: emailMessageID,
            inReplyTo: inReplyTo,
            tokenCount: estimateTokens(content)
        )
        try database.addMessage(message)
        return message
    }

    /// Persist tool use messages (assistant's tool calls).
    public func persistToolUseMessage(
        conversationID: String,
        toolUses: [AIToolUse]
    ) throws {
        let stored = toolUses.map { tu in
            StoredToolUse(
                id: tu.id,
                name: tu.name,
                input: tu.input.mapValues { value -> String in
                    if let s: String = value.get() { return s }
                    if let i: Int = value.get() { return String(i) }
                    if let b: Bool = value.get() { return String(b) }
                    return String(describing: value)
                }
            )
        }
        let json = (try? JSONEncoder().encode(stored)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let message = CounselMessage(
            conversationID: conversationID,
            role: .toolUse,
            content: json
        )
        try database.addMessage(message)
    }

    /// Persist tool result messages.
    public func persistToolResultMessage(
        conversationID: String,
        results: [AIToolResult]
    ) throws {
        let stored = results.map { StoredToolResult(toolUseId: $0.toolUseId, content: $0.content, isError: $0.isError) }
        let json = (try? JSONEncoder().encode(stored)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let message = CounselMessage(
            conversationID: conversationID,
            role: .toolResult,
            content: json
        )
        try database.addMessage(message)
    }

    /// Estimate token count from text (rough: ~4 chars per token).
    private func estimateTokens(_ text: String) -> Int {
        max(1, text.count / 4)
    }
}

// MARK: - Stored Types for JSON Serialization

struct StoredToolUse: Codable {
    let id: String
    let name: String
    let input: [String: String]
}

struct StoredToolResult: Codable {
    let toolUseId: String
    let content: String
    let isError: Bool
}
