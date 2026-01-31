//
//  CounselSession.swift
//  MessageManagerCore
//
//  Actor for managing research conversations with AI counsels.
//  Integrates with ImpressAI for LLM execution.
//

import Foundation
import ImpressAI
import OSLog

private let counselLogger = Logger(subsystem: "com.impart", category: "counsel")

// MARK: - Counsel Errors

/// Errors that can occur during counsel sessions.
public enum CounselError: LocalizedError {
    case noProviderConfigured
    case noResponse
    case executionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noProviderConfigured:
            return "No AI provider configured. Go to Settings → AI to add your API key."
        case .noResponse:
            return "AI did not return a response. Please try again."
        case .executionFailed(let reason):
            return "AI execution failed: \(reason)"
        }
    }
}

// MARK: - Counsel Configuration

/// Configuration for a counsel session.
public struct CounselConfiguration: Sendable {
    /// The AI model to use (e.g., "opus4.5", "sonnet4").
    public let model: String

    /// Maximum tokens for response.
    public let maxTokens: Int

    /// Temperature for generation (0.0-1.0).
    public let temperature: Double

    /// System prompt additions.
    public let systemPromptAdditions: String?

    public init(
        model: String = "opus4.5",
        maxTokens: Int = 4096,
        temperature: Double = 0.7,
        systemPromptAdditions: String? = nil
    ) {
        self.model = model
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.systemPromptAdditions = systemPromptAdditions
    }

    /// Default configuration for research conversations.
    public static var research: CounselConfiguration {
        CounselConfiguration(
            model: "opus4.5",
            maxTokens: 4096,
            temperature: 0.7,
            systemPromptAdditions: """
            Focus on academic rigor, cite sources when possible, and be explicit about uncertainty.
            """
        )
    }

    /// Configuration for quick responses.
    public static var quick: CounselConfiguration {
        CounselConfiguration(
            model: "sonnet4",
            maxTokens: 1024,
            temperature: 0.5
        )
    }
}

// MARK: - Counsel Response

/// Response from a counsel interaction.
public struct CounselResponse: Sendable {
    /// The generated response content.
    public let content: String

    /// Model used for generation.
    public let modelUsed: String

    /// Token count for the response.
    public let tokenCount: Int

    /// Processing duration in milliseconds.
    public let processingDurationMs: Int

    /// Artifacts mentioned in the response.
    public let mentionedArtifacts: [String]

    /// Correlation ID for provenance tracking.
    public let correlationId: String

    public init(
        content: String,
        modelUsed: String,
        tokenCount: Int,
        processingDurationMs: Int,
        mentionedArtifacts: [String] = [],
        correlationId: String
    ) {
        self.content = content
        self.modelUsed = modelUsed
        self.tokenCount = tokenCount
        self.processingDurationMs = processingDurationMs
        self.mentionedArtifacts = mentionedArtifacts
        self.correlationId = correlationId
    }
}

// MARK: - Counsel Session

/// Actor for managing a research conversation session with an AI counsel.
public actor CounselSession {

    // MARK: - Properties

    /// The conversation ID.
    public let conversationId: UUID

    /// Configuration for this session.
    private let configuration: CounselConfiguration

    /// Persistence controller for saving messages.
    private let persistenceController: PersistenceController

    /// Provenance service for tracking.
    private let provenanceService: ProvenanceService

    /// Artifact service for managing references.
    private let artifactService: ArtifactService

    /// Conversation history for context.
    private var history: [ConversationTurn] = []

    /// Currently attached artifacts.
    private var attachedArtifacts: [ArtifactReference] = []

    /// The user identifier.
    private let userId: String

    // MARK: - Initialization

    /// Initialize a new counsel session.
    public init(
        conversationId: UUID,
        configuration: CounselConfiguration = .research,
        persistenceController: PersistenceController,
        provenanceService: ProvenanceService,
        artifactService: ArtifactService,
        userId: String
    ) {
        self.conversationId = conversationId
        self.configuration = configuration
        self.persistenceController = persistenceController
        self.provenanceService = provenanceService
        self.artifactService = artifactService
        self.userId = userId
    }

    // MARK: - Messaging

    /// Send a message with streaming response.
    /// - Parameters:
    ///   - message: The user's message.
    ///   - artifacts: Artifacts to include in context.
    ///   - onChunk: Callback invoked with accumulated text as it streams.
    /// - Returns: The final counsel response.
    public func sendStreaming(
        message: String,
        artifacts: [ArtifactReference] = [],
        onChunk: @escaping @Sendable (String) -> Void
    ) async throws -> CounselResponse {
        let startTime = Date()
        let correlationId = UUID().uuidString

        counselLogger.info("Sending streaming message in conversation \(self.conversationId)")

        // Record the human message
        let humanMessageEvent = await provenanceService.recordMessageSent(
            conversationId: conversationId.uuidString,
            messageId: UUID().uuidString,
            role: "human",
            modelUsed: nil,
            contentHash: computeContentHash(message),
            actorId: userId
        )

        // Add to history
        history.append(ConversationTurn(role: .user, content: message))

        // Update attached artifacts
        for artifact in artifacts {
            if !attachedArtifacts.contains(where: { $0.uriString == artifact.uriString }) {
                attachedArtifacts.append(artifact)

                await provenanceService.recordArtifactIntroduced(
                    conversationId: conversationId.uuidString,
                    artifactUri: artifact.uriString,
                    artifactType: artifact.type.rawValue,
                    version: artifact.version,
                    displayName: artifact.displayName,
                    actorId: userId
                )
            }
        }

        // Build prompts and messages
        let systemPrompt = buildSystemPrompt()
        let messages = buildMessages()

        // Map model ID
        let modelId = mapModelId(configuration.model)

        // Build streaming request
        let request = AICompletionRequest(
            modelId: modelId,
            messages: messages,
            systemPrompt: systemPrompt,
            maxTokens: configuration.maxTokens,
            temperature: configuration.temperature,
            stream: true
        )

        let executor = AIMultiModelExecutor.shared

        // Get the stream
        let stream = try await executor.executeStreaming(request, for: "research")

        var fullText = ""
        var tokenCount = 0

        // Process stream chunks
        for try await progress in stream {
            fullText = progress.partialText
            onChunk(fullText)

            if progress.isComplete {
                break
            }
        }

        // Estimate token count (rough heuristic: ~4 chars per token)
        tokenCount = fullText.count / 4

        // Process response for artifact mentions
        let mentions = try await artifactService.processMessageContent(
            content: fullText,
            messageId: UUID(),
            conversationId: conversationId,
            mentionedBy: "counsel-\(configuration.model)@impart.local"
        )

        // Record the counsel response
        let processingDuration = Int(Date().timeIntervalSince(startTime) * 1000)
        await provenanceService.recordMessageSent(
            conversationId: conversationId.uuidString,
            messageId: UUID().uuidString,
            role: "counsel",
            modelUsed: configuration.model,
            contentHash: computeContentHash(fullText),
            actorId: "counsel-\(configuration.model)@impart.local",
            causedBy: humanMessageEvent.id
        )

        // Add to history
        history.append(ConversationTurn(role: .assistant, content: fullText))

        counselLogger.info("Streaming counsel response complete (\(tokenCount) estimated tokens, \(processingDuration)ms)")

        return CounselResponse(
            content: fullText,
            modelUsed: configuration.model,
            tokenCount: tokenCount,
            processingDurationMs: processingDuration,
            mentionedArtifacts: mentions.map(\.artifactURI),
            correlationId: correlationId
        )
    }

    /// Send a message and get a counsel response (non-streaming).
    public func send(
        message: String,
        artifacts: [ArtifactReference] = []
    ) async throws -> CounselResponse {
        let startTime = Date()
        let correlationId = UUID().uuidString

        counselLogger.info("Sending message in conversation \(self.conversationId)")

        // Record the human message
        let humanMessageEvent = await provenanceService.recordMessageSent(
            conversationId: conversationId.uuidString,
            messageId: UUID().uuidString,
            role: "human",
            modelUsed: nil,
            contentHash: computeContentHash(message),
            actorId: userId
        )

        // Add to history
        history.append(ConversationTurn(role: .user, content: message))

        // Update attached artifacts
        for artifact in artifacts {
            if !attachedArtifacts.contains(where: { $0.uriString == artifact.uriString }) {
                attachedArtifacts.append(artifact)

                // Record artifact introduction
                await provenanceService.recordArtifactIntroduced(
                    conversationId: conversationId.uuidString,
                    artifactUri: artifact.uriString,
                    artifactType: artifact.type.rawValue,
                    version: artifact.version,
                    displayName: artifact.displayName,
                    actorId: userId
                )
            }
        }

        // Build the system prompt
        let systemPrompt = buildSystemPrompt()

        // Build messages for the AI
        let messages = buildMessages()

        // Execute AI request
        let response = try await executeAIRequest(
            systemPrompt: systemPrompt,
            messages: messages,
            correlationId: correlationId
        )

        // Process response for artifact mentions
        let mentions = try await artifactService.processMessageContent(
            content: response.content,
            messageId: UUID(), // Would be the actual message ID
            conversationId: conversationId,
            mentionedBy: "counsel-\(configuration.model)@impart.local"
        )

        // Record the counsel response
        let processingDuration = Int(Date().timeIntervalSince(startTime) * 1000)
        await provenanceService.recordMessageSent(
            conversationId: conversationId.uuidString,
            messageId: UUID().uuidString,
            role: "counsel",
            modelUsed: configuration.model,
            contentHash: computeContentHash(response.content),
            actorId: "counsel-\(configuration.model)@impart.local",
            causedBy: humanMessageEvent.id
        )

        // Add to history
        history.append(ConversationTurn(role: .assistant, content: response.content))

        counselLogger.info("Received counsel response (\(response.tokenCount) tokens, \(processingDuration)ms)")

        return CounselResponse(
            content: response.content,
            modelUsed: configuration.model,
            tokenCount: response.tokenCount,
            processingDurationMs: processingDuration,
            mentionedArtifacts: mentions.map(\.artifactURI),
            correlationId: correlationId
        )
    }

    /// Attach artifacts to the conversation context.
    public func attach(artifacts: [ArtifactReference]) {
        for artifact in artifacts {
            if !attachedArtifacts.contains(where: { $0.uriString == artifact.uriString }) {
                attachedArtifacts.append(artifact)
            }
        }
    }

    /// Detach an artifact from the conversation context.
    public func detach(artifactURI: String) {
        attachedArtifacts.removeAll { $0.uriString == artifactURI }
    }

    /// Get the conversation history.
    public func getHistory() -> [ConversationTurn] {
        history
    }

    /// Get attached artifacts.
    public func getAttachedArtifacts() -> [ArtifactReference] {
        attachedArtifacts
    }

    /// Clear the conversation history (but keep artifacts).
    public func clearHistory() {
        history.removeAll()
    }

    /// Restore a message from persistence into the history.
    /// Used when loading a saved conversation.
    public func restoreHistoryMessage(_ message: ResearchMessage) {
        let role: ConversationTurn.Role = message.senderRole == .human ? .user : .assistant
        history.append(ConversationTurn(
            role: role,
            content: message.contentMarkdown,
            timestamp: message.sentAt
        ))
    }

    // MARK: - Private Helpers

    /// Build the system prompt with artifact context.
    private func buildSystemPrompt() -> String {
        var prompt = """
        You are a research counsel. Your role is to assist with research discussions, \
        analyze papers, help develop ideas, and provide rigorous academic input.

        When referencing resources, use impress:// URIs:
        - Papers: impress://imbib/papers/{citeKey}
        - Documents: impress://imprint/documents/{id}
        - Repositories: impress://repos/{host}/{owner}/{repo}@{commit}

        Always cite sources and be explicit about uncertainty. Focus on helping the \
        researcher develop and refine their ideas.
        """

        if let additions = configuration.systemPromptAdditions {
            prompt += "\n\n" + additions
        }

        // Add attached artifact context
        if !attachedArtifacts.isEmpty {
            prompt += "\n\n## Referenced Artifacts\n\n"
            for artifact in attachedArtifacts {
                prompt += "- **\(artifact.displayName)** (\(artifact.type.displayName)): `\(artifact.uriString)`"
                if let metadata = artifact.metadata {
                    if let authors = metadata.authors, !authors.isEmpty {
                        prompt += " by \(authors.joined(separator: ", "))"
                    }
                    if let abstract = metadata.abstract {
                        prompt += "\n  > \(String(abstract.prefix(200)))..."
                    }
                }
                prompt += "\n"
            }
        }

        return prompt
    }

    /// Build messages array for AI request using ImpressAI.AIMessage.
    private func buildMessages() -> [ImpressAI.AIMessage] {
        history.map { turn in
            ImpressAI.AIMessage(
                role: turn.role == .user ? .user : .assistant,
                text: turn.content
            )
        }
    }

    /// Execute the AI request via ImpressAI.
    private func executeAIRequest(
        systemPrompt: String,
        messages: [ImpressAI.AIMessage],
        correlationId: String
    ) async throws -> InternalAIResponse {
        let executor = AIMultiModelExecutor.shared

        // Map the counsel model name to actual model ID
        let modelId = mapModelId(configuration.model)

        // Build ImpressAI completion request
        let request = AICompletionRequest(
            modelId: modelId,
            messages: messages,
            systemPrompt: systemPrompt,
            maxTokens: configuration.maxTokens,
            temperature: configuration.temperature
        )

        // Execute via primary model for "research" category
        guard let result = try await executor.executePrimary(request, categoryId: "research") else {
            throw CounselError.noProviderConfigured
        }

        // Check if execution succeeded
        guard result.isSuccess, let response = result.response else {
            if let error = result.error {
                throw CounselError.executionFailed(error.localizedDescription)
            }
            throw CounselError.noResponse
        }

        counselLogger.debug("AI execution completed: model=\(response.model), tokens=\(response.usage?.outputTokens ?? 0)")

        return InternalAIResponse(
            content: response.text,
            tokenCount: response.usage?.outputTokens ?? 0,
            finishReason: mapFinishReason(response.finishReason)
        )
    }

    /// Map counsel model names to ImpressAI model IDs.
    private func mapModelId(_ counselModel: String) -> String {
        switch counselModel {
        case "opus4.5":
            return "claude-opus-4-20250514"
        case "sonnet4":
            return "claude-sonnet-4-20250514"
        case "haiku3.5":
            return "claude-3-5-haiku-20241022"
        default:
            // Pass through if already a full model ID
            return counselModel
        }
    }

    /// Map ImpressAI finish reason to internal type.
    private func mapFinishReason(_ reason: AIFinishReason?) -> InternalAIResponse.FinishReason {
        switch reason {
        case .stop, nil:
            return .complete
        case .length:
            return .maxTokens
        case .contentFilter:
            return .contentFilter
        case .toolUse, .error:
            return .error
        }
    }
}

// MARK: - Supporting Types

/// A turn in the conversation.
public struct ConversationTurn: Codable, Sendable {
    public enum Role: String, Codable, Sendable {
        case user
        case assistant
        case system
    }

    public let role: Role
    public let content: String
    public let timestamp: Date

    public init(role: Role, content: String, timestamp: Date = Date()) {
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
}

/// Internal message type for history building.
/// We use ImpressAI.AIMessage directly for API requests.
private typealias InternalAIRole = ConversationTurn.Role

/// Internal AI response type.
private struct InternalAIResponse: Sendable {
    enum FinishReason: String, Sendable {
        case complete
        case maxTokens
        case contentFilter
        case error
    }

    let content: String
    let tokenCount: Int
    let finishReason: FinishReason
}
