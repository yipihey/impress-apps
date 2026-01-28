//
//  AIAssistantServiceCompat.swift
//  imprint
//
//  Compatibility wrapper bridging AIAssistantService to ImpressAI.
//  Provides the same API as the original AIAssistantService but uses
//  ImpressAI providers under the hood.
//

import Foundation
import ImpressAI
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "com.imprint.app", category: "aiAssistantCompat")

// MARK: - AI Assistant Service (ImpressAI-backed)

/// Compatibility layer that wraps ImpressAI for use in imprint.
///
/// This service provides the same API as the original AIAssistantService
/// but delegates to AIProviderManager for actual AI requests.
///
/// Features:
/// - Drop-in replacement for AIAssistantService
/// - Uses ImpressAI providers (Claude, OpenAI, Google, Ollama, OpenRouter)
/// - Maintains chat history
/// - Provides writing assistance actions
@MainActor
public final class AIAssistantServiceCompat: ObservableObject {

    // MARK: - Singleton

    public static let shared = AIAssistantServiceCompat()

    // MARK: - Published State

    /// Whether a request is in progress
    @Published public private(set) var isLoading = false

    /// Last error encountered
    @Published public var lastError: AIAssistantError?

    /// Chat history for current session
    @Published public var chatHistory: [ChatMessageCompat] = []

    // MARK: - ImpressAI Integration

    private let providerManager: AIProviderManager
    private let settings: AISettings

    /// The current provider metadata
    public var currentProvider: AIProviderMetadata? {
        settings.selectedProviderMetadata
    }

    /// The current model
    public var currentModel: AIModel? {
        guard let modelId = settings.selectedModelId else { return nil }
        return settings.availableModels.first { $0.id == modelId }
    }

    /// Whether API key is configured for current provider
    public var isConfigured: Bool {
        settings.isProviderReady
    }

    // MARK: - Initialization

    private init(
        providerManager: AIProviderManager = .shared,
        settings: AISettings = .shared
    ) {
        self.providerManager = providerManager
        self.settings = settings

        Task {
            await providerManager.registerBuiltInProviders()
            await settings.load()
        }
    }

    // MARK: - Writing Actions

    /// Rewrite selected text for clarity and academic tone.
    public func rewrite(_ text: String, style: RewriteStyleCompat = .clearer) async throws -> String {
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
    public func expand(_ text: String, targetLength: ExpansionLengthCompat = .medium) async throws -> String {
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
    public func summarize(_ text: String, length: SummaryLengthCompat = .brief) async throws -> String {
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
        let userMessage = ChatMessageCompat(role: .user, content: message)
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
        let assistantMessage = ChatMessageCompat(role: .assistant, content: response)
        chatHistory.append(assistantMessage)

        return response
    }

    /// Clear chat history
    public func clearChat() {
        chatHistory.removeAll()
    }

    // MARK: - ImpressAI Integration Methods

    private func sendRequest(systemPrompt: String, userMessage: String, maxTokens: Int) async throws -> String {
        guard isConfigured else {
            throw AIAssistantError.notConfigured
        }

        isLoading = true
        lastError = nil

        defer { isLoading = false }

        do {
            let request = AICompletionRequest(
                providerId: settings.selectedProviderId,
                modelId: settings.selectedModelId,
                messages: [AIMessage(role: .user, text: userMessage)],
                systemPrompt: systemPrompt,
                maxTokens: maxTokens
            )

            let response = try await providerManager.complete(request)
            logger.info("AI response received: \(response.text.prefix(100))...")
            return response.text
        } catch let error as AIError {
            let aiError = mapError(error)
            lastError = aiError
            throw aiError
        } catch {
            let aiError = AIAssistantError.requestFailed(error.localizedDescription)
            lastError = aiError
            throw aiError
        }
    }

    private func mapError(_ error: AIError) -> AIAssistantError {
        switch error {
        case .unauthorized:
            return .notConfigured
        case .providerNotConfigured:
            return .notConfigured
        case .rateLimited:
            return .rateLimited
        case .apiError(let code, let message):
            return .apiError(code, message)
        case .parseError(let message):
            return .requestFailed(message)
        case .networkError(let underlying):
            return .requestFailed(underlying.localizedDescription)
        default:
            return .requestFailed(error.localizedDescription)
        }
    }

    private func buildChatMessages() -> String {
        let recentHistory = chatHistory.suffix(10)
        return recentHistory.map { "\($0.role.rawValue): \($0.content)" }.joined(separator: "\n\n")
    }
}

// MARK: - Compat Types

/// Chat message for compatibility layer
public struct ChatMessageCompat: Identifiable, Equatable {
    public let id = UUID()
    public let role: ChatRoleCompat
    public let content: String
    public let timestamp = Date()
}

public enum ChatRoleCompat: String {
    case user
    case assistant
}

/// Rewriting style options
public enum RewriteStyleCompat: String, CaseIterable, Identifiable {
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
public enum ExpansionLengthCompat: String, CaseIterable, Identifiable {
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
public enum SummaryLengthCompat: String, CaseIterable, Identifiable {
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

// MARK: - Settings View Integration

/// View that displays ImpressAI settings for imprint
public struct ImprintAISettingsView: View {
    public init() {}

    public var body: some View {
        AISettingsView()
    }
}
