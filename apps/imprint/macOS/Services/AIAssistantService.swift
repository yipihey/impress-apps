//
//  AIAssistantService.swift
//  imprint
//
//  AI writing assistant service that delegates to ImpressAI providers.
//  Provides rewriting, expansion, summarization, and chat capabilities.
//

import Foundation
import OSLog
import ImpressAI

private let logger = Logger(subsystem: "com.imprint.app", category: "aiAssistant")

// MARK: - AI Assistant Service

/// Service for AI-powered writing assistance.
///
/// Supports multiple providers via ImpressAI:
/// - Claude (Anthropic)
/// - GPT (OpenAI)
///
/// Features:
/// - Rewrite text for clarity
/// - Expand outlines to prose
/// - Summarize long passages
/// - General chat for writing help
@MainActor @Observable
public final class AIAssistantService {

    // MARK: - Singleton

    public static let shared = AIAssistantService()

    // MARK: - Dependencies

    private let completionService = AITextCompletionService.shared

    // MARK: - Published State

    /// Current AI provider
    public var provider: AIProvider {
        get { AIProvider(fromTextProvider: completionService.selectedProvider) }
        set { completionService.selectedProvider = newValue.toTextProvider }
    }

    /// Whether a request is in progress
    public var isLoading: Bool { completionService.isLoading }

    /// Last error encountered
    public var lastError: AIAssistantError?

    /// Chat history for current session
    public var chatHistory: [ChatMessage] = []

    // MARK: - Initialization

    private init() {}

    // MARK: - Configuration

    /// Check if API key is configured for current provider
    public var isConfigured: Bool {
        get async {
            await completionService.isConfigured
        }
    }

    /// Synchronous check for UI (uses cached state)
    public var isConfiguredSync: Bool {
        switch provider {
        case .claude:
            return UserDefaults.standard.bool(forKey: "ai.anthropic.hasKey")
        case .openai:
            return UserDefaults.standard.bool(forKey: "ai.openai.hasKey")
        }
    }

    /// Set API key for a provider (uses ImpressAI credential manager)
    public func setAPIKey(_ key: String, for provider: AIProvider) async throws {
        try await completionService.setAPIKey(key, for: provider.toTextProvider)

        // Update cached state for sync checks
        UserDefaults.standard.set(!key.isEmpty, forKey: "ai.\(provider.toTextProvider.rawValue).hasKey")
    }

    /// Get API key for a provider (masked for display)
    public func maskedAPIKey(for provider: AIProvider) async -> String {
        await completionService.maskedAPIKey(for: provider.toTextProvider)
    }

    // MARK: - Writing Actions

    /// Rewrite selected text for clarity and academic tone.
    public func rewrite(_ text: String, style: RewriteStyle = .clearer) async throws -> String {
        let systemPrompt = """
        You are a writing assistant for academic papers. Rewrite the given text to be \(style.description).
        Preserve the meaning and any technical terms. Return only the rewritten text, no explanations.
        """

        return try await sendRequest(
            systemPrompt: systemPrompt,
            userMessage: text,
            maxTokens: max(text.count * 2, 500)
        )
    }

    /// Expand an outline or brief text into full prose.
    public func expand(_ text: String, targetLength: ExpansionLength = .medium) async throws -> String {
        let systemPrompt = """
        You are a writing assistant for academic papers. Expand the given outline or brief text into \(targetLength.description) academic prose.
        Maintain a scholarly tone, add appropriate transitions, and develop the ideas fully.
        Return only the expanded text, no explanations or meta-commentary.
        """

        return try await sendRequest(
            systemPrompt: systemPrompt,
            userMessage: text,
            maxTokens: targetLength.maxTokens
        )
    }

    /// Summarize a long passage.
    public func summarize(_ text: String, length: SummaryLength = .brief) async throws -> String {
        let systemPrompt = """
        You are a writing assistant for academic papers. Summarize the given text in \(length.description).
        Preserve key findings, methods, or arguments. Return only the summary, no explanations.
        """

        return try await sendRequest(
            systemPrompt: systemPrompt,
            userMessage: text,
            maxTokens: length.maxTokens
        )
    }

    /// Suggest citations that would support a claim.
    public func suggestCitations(for text: String) async throws -> String {
        let systemPrompt = """
        You are a research assistant. Given the following text from an academic paper, suggest 3-5 types of citations that would strengthen this claim or provide evidence.
        For each suggestion, describe:
        1. What kind of source would be helpful (e.g., "foundational paper on X", "recent meta-analysis of Y")
        2. What search terms to use in a citation database

        Format as a bulleted list. Be specific to the domain of the text.
        """

        return try await sendRequest(
            systemPrompt: systemPrompt,
            userMessage: text,
            maxTokens: 800
        )
    }

    /// Generate a response in the chat conversation.
    public func chat(_ message: String, context: String? = nil) async throws -> String {
        // Add user message to history
        let userMessage = ChatMessage(role: .user, content: message)
        chatHistory.append(userMessage)

        let systemPrompt = """
        You are an AI writing assistant for academic papers. Help the researcher with their writing, including:
        - Improving clarity and flow
        - Suggesting better phrasing
        - Explaining concepts
        - Brainstorming ideas
        - Structuring arguments

        Be concise and practical. When suggesting edits, provide the actual text to use.
        \(context != nil ? "\n\nThe user is currently working on this text:\n\(context!)" : "")
        """

        let response = try await sendRequest(
            systemPrompt: systemPrompt,
            userMessage: buildChatMessages(),
            maxTokens: 1500
        )

        // Add assistant response to history
        let assistantMessage = ChatMessage(role: .assistant, content: response)
        chatHistory.append(assistantMessage)

        return response
    }

    /// Clear chat history
    public func clearChat() {
        chatHistory.removeAll()
    }

    // MARK: - Streaming API

    /// Stream a message response for real-time output.
    ///
    /// - Parameters:
    ///   - systemPrompt: The system prompt to use
    ///   - userMessage: The user's message
    ///   - maxTokens: Maximum tokens for the response
    /// - Returns: An async stream of text chunks
    public func streamMessage(
        systemPrompt: String,
        userMessage: String,
        maxTokens: Int = 2000
    ) -> AsyncThrowingStream<String, Error> {
        completionService.stream(
            systemPrompt: systemPrompt,
            userMessage: userMessage,
            maxTokens: maxTokens
        )
    }

    // MARK: - API Communication

    private func sendRequest(systemPrompt: String, userMessage: String, maxTokens: Int) async throws -> String {
        lastError = nil

        do {
            let response = try await completionService.complete(
                systemPrompt: systemPrompt,
                userMessage: userMessage,
                maxTokens: maxTokens
            )
            logger.info("AI response received: \(response.prefix(100))...")
            return response
        } catch {
            let aiError: AIAssistantError
            if let textError = error as? AITextCompletionError {
                switch textError {
                case .notConfigured:
                    aiError = .notConfigured
                case .requestFailed(let msg):
                    aiError = .requestFailed(msg)
                }
            } else if let impressError = error as? AIError {
                aiError = AIAssistantError.from(impressError)
            } else {
                aiError = .requestFailed(error.localizedDescription)
            }
            lastError = aiError
            throw aiError
        }
    }

    private func buildChatMessages() -> String {
        // For simplicity, concatenate recent history
        let recentHistory = chatHistory.suffix(10)
        return recentHistory.map { "\($0.role.rawValue): \($0.content)" }.joined(separator: "\n\n")
    }
}

// MARK: - Supporting Types

/// AI provider options
public enum AIProvider: String, CaseIterable, Identifiable {
    case claude
    case openai

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: return "Claude (Anthropic)"
        case .openai: return "GPT (OpenAI)"
        }
    }

    init(fromTextProvider provider: AITextProvider) {
        switch provider {
        case .anthropic: self = .claude
        case .openai: self = .openai
        }
    }

    var toTextProvider: AITextProvider {
        switch self {
        case .claude: return .anthropic
        case .openai: return .openai
        }
    }
}

/// Chat message for conversation history
public struct ChatMessage: Identifiable, Equatable {
    public let id = UUID()
    public let role: ChatRole
    public let content: String
    public let timestamp = Date()
}

public enum ChatRole: String {
    case user
    case assistant
}

/// Rewriting style options
public enum RewriteStyle: String, CaseIterable, Identifiable {
    case clearer = "clearer"
    case concise = "concise"
    case formal = "formal"
    case simpler = "simpler"

    public var id: String { rawValue }

    var description: String {
        switch self {
        case .clearer: return "clearer and more readable"
        case .concise: return "more concise while preserving meaning"
        case .formal: return "more formal and academic"
        case .simpler: return "simpler and easier to understand"
        }
    }
}

/// Expansion length options
public enum ExpansionLength: String, CaseIterable, Identifiable {
    case short = "short"
    case medium = "medium"
    case long = "long"

    public var id: String { rawValue }

    var description: String {
        switch self {
        case .short: return "a short paragraph (2-3 sentences)"
        case .medium: return "a medium-length paragraph (4-6 sentences)"
        case .long: return "multiple paragraphs with full development"
        }
    }

    var maxTokens: Int {
        switch self {
        case .short: return 300
        case .medium: return 600
        case .long: return 1200
        }
    }
}

/// Summary length options
public enum SummaryLength: String, CaseIterable, Identifiable {
    case brief = "brief"
    case moderate = "moderate"
    case detailed = "detailed"

    public var id: String { rawValue }

    var description: String {
        switch self {
        case .brief: return "one or two sentences"
        case .moderate: return "a short paragraph"
        case .detailed: return "a detailed summary preserving key points"
        }
    }

    var maxTokens: Int {
        switch self {
        case .brief: return 100
        case .moderate: return 250
        case .detailed: return 500
        }
    }
}

/// Errors from AI assistant operations
public enum AIAssistantError: LocalizedError {
    case notConfigured
    case invalidConfiguration
    case requestFailed(String)
    case apiError(Int, String)
    case parseError
    case rateLimited

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "AI assistant is not configured. Please add your API key in Settings."
        case .invalidConfiguration:
            return "Invalid API configuration."
        case .requestFailed(let message):
            return "Request failed: \(message)"
        case .apiError(let code, let message):
            return "API error (\(code)): \(message)"
        case .parseError:
            return "Failed to parse API response."
        case .rateLimited:
            return "Rate limited. Please wait a moment and try again."
        }
    }

    static func from(_ error: AIError) -> AIAssistantError {
        switch error {
        case .unauthorized:
            return .notConfigured
        case .rateLimited:
            return .rateLimited
        case .apiError(let code, let message):
            return .apiError(code, message)
        case .parseError:
            return .parseError
        case .networkError(let underlying):
            return .requestFailed(underlying.localizedDescription)
        default:
            return .requestFailed(error.localizedDescription)
        }
    }
}
