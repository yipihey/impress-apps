//
//  AIAssistantService.swift
//  imprint
//
//  AI writing assistant service using Claude or OpenAI APIs.
//  Provides rewriting, expansion, summarization, and chat capabilities.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.imprint.app", category: "aiAssistant")

// MARK: - AI Assistant Service

/// Service for AI-powered writing assistance.
///
/// Supports multiple providers:
/// - Claude (Anthropic)
/// - GPT (OpenAI)
///
/// Features:
/// - Rewrite text for clarity
/// - Expand outlines to prose
/// - Summarize long passages
/// - General chat for writing help
@MainActor
public final class AIAssistantService: ObservableObject {

    // MARK: - Singleton

    public static let shared = AIAssistantService()

    // MARK: - Published State

    /// Current AI provider
    @Published public var provider: AIProvider = .claude

    /// Whether a request is in progress
    @Published public private(set) var isLoading = false

    /// Last error encountered
    @Published public var lastError: AIAssistantError?

    /// Chat history for current session
    @Published public var chatHistory: [ChatMessage] = []

    // MARK: - Configuration

    /// API key storage (UserDefaults for simplicity; should use Keychain in production)
    @AppStorage("ai.claudeApiKey") private var claudeApiKey: String = ""
    @AppStorage("ai.openaiApiKey") private var openaiApiKey: String = ""
    @AppStorage("ai.provider") private var storedProvider: String = "claude"

    // API endpoints
    private let claudeEndpoint = "https://api.anthropic.com/v1/messages"
    private let openaiEndpoint = "https://api.openai.com/v1/chat/completions"

    // MARK: - Initialization

    private init() {
        provider = AIProvider(rawValue: storedProvider) ?? .claude
    }

    // MARK: - Configuration

    /// Check if API key is configured for current provider
    public var isConfigured: Bool {
        switch provider {
        case .claude:
            return !claudeApiKey.isEmpty
        case .openai:
            return !openaiApiKey.isEmpty
        }
    }

    /// Set API key for a provider
    public func setAPIKey(_ key: String, for provider: AIProvider) {
        switch provider {
        case .claude:
            claudeApiKey = key
        case .openai:
            openaiApiKey = key
        }
    }

    /// Get API key for a provider (masked for display)
    public func maskedAPIKey(for provider: AIProvider) -> String {
        let key: String
        switch provider {
        case .claude:
            key = claudeApiKey
        case .openai:
            key = openaiApiKey
        }

        if key.isEmpty { return "" }
        if key.count <= 8 { return String(repeating: "•", count: key.count) }
        return key.prefix(4) + String(repeating: "•", count: key.count - 8) + key.suffix(4)
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
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard isConfigured else {
                        throw AIAssistantError.notConfigured
                    }

                    await MainActor.run {
                        isLoading = true
                        lastError = nil
                    }

                    switch provider {
                    case .claude:
                        try await streamClaudeRequest(
                            system: systemPrompt,
                            user: userMessage,
                            maxTokens: maxTokens,
                            continuation: continuation
                        )
                    case .openai:
                        try await streamOpenAIRequest(
                            system: systemPrompt,
                            user: userMessage,
                            maxTokens: maxTokens,
                            continuation: continuation
                        )
                    }

                    await MainActor.run {
                        isLoading = false
                    }

                    continuation.finish()

                } catch {
                    await MainActor.run {
                        isLoading = false
                        lastError = error as? AIAssistantError ?? .requestFailed(error.localizedDescription)
                    }
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func streamClaudeRequest(
        system: String,
        user: String,
        maxTokens: Int,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        guard let url = URL(string: claudeEndpoint) else {
            throw AIAssistantError.invalidConfiguration
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(claudeApiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": "claude-sonnet-4-20250514",
            "max_tokens": maxTokens,
            "stream": true,
            "system": system,
            "messages": [
                ["role": "user", "content": user]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        logger.info("Starting Claude streaming request...")

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIAssistantError.requestFailed("Invalid response")
        }

        if httpResponse.statusCode != 200 {
            // Read error body
            var errorData = Data()
            for try await byte in bytes {
                errorData.append(byte)
            }
            if let errorJson = try? JSONSerialization.jsonObject(with: errorData) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw AIAssistantError.apiError(httpResponse.statusCode, message)
            }
            throw AIAssistantError.apiError(httpResponse.statusCode, "Unknown error")
        }

        // Parse SSE stream
        var buffer = ""
        for try await byte in bytes {
            buffer.append(Character(UnicodeScalar(byte)))

            // Check for complete SSE event (ends with double newline)
            while let eventEnd = buffer.range(of: "\n\n") {
                let eventString = String(buffer[..<eventEnd.lowerBound])
                buffer.removeSubrange(..<eventEnd.upperBound)

                // Parse SSE event
                for line in eventString.components(separatedBy: "\n") {
                    if line.hasPrefix("data: ") {
                        let jsonString = String(line.dropFirst(6))
                        if jsonString == "[DONE]" {
                            continue
                        }

                        if let data = jsonString.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

                            // Extract text from content_block_delta event
                            if let eventType = json["type"] as? String,
                               eventType == "content_block_delta",
                               let delta = json["delta"] as? [String: Any],
                               let text = delta["text"] as? String {
                                continuation.yield(text)
                            }
                        }
                    }
                }
            }
        }

        logger.info("Claude streaming complete")
    }

    private func streamOpenAIRequest(
        system: String,
        user: String,
        maxTokens: Int,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        guard let url = URL(string: openaiEndpoint) else {
            throw AIAssistantError.invalidConfiguration
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(openaiApiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": "gpt-4o",
            "max_tokens": maxTokens,
            "stream": true,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        logger.info("Starting OpenAI streaming request...")

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIAssistantError.requestFailed("Invalid response")
        }

        if httpResponse.statusCode != 200 {
            var errorData = Data()
            for try await byte in bytes {
                errorData.append(byte)
            }
            if let errorJson = try? JSONSerialization.jsonObject(with: errorData) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw AIAssistantError.apiError(httpResponse.statusCode, message)
            }
            throw AIAssistantError.apiError(httpResponse.statusCode, "Unknown error")
        }

        // Parse SSE stream
        var buffer = ""
        for try await byte in bytes {
            buffer.append(Character(UnicodeScalar(byte)))

            while let eventEnd = buffer.range(of: "\n\n") {
                let eventString = String(buffer[..<eventEnd.lowerBound])
                buffer.removeSubrange(..<eventEnd.upperBound)

                for line in eventString.components(separatedBy: "\n") {
                    if line.hasPrefix("data: ") {
                        let jsonString = String(line.dropFirst(6))
                        if jsonString == "[DONE]" {
                            continue
                        }

                        if let data = jsonString.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let choices = json["choices"] as? [[String: Any]],
                           let firstChoice = choices.first,
                           let delta = firstChoice["delta"] as? [String: Any],
                           let content = delta["content"] as? String {
                            continuation.yield(content)
                        }
                    }
                }
            }
        }

        logger.info("OpenAI streaming complete")
    }

    // MARK: - API Communication

    private func sendRequest(systemPrompt: String, userMessage: String, maxTokens: Int) async throws -> String {
        guard isConfigured else {
            throw AIAssistantError.notConfigured
        }

        isLoading = true
        lastError = nil

        defer { isLoading = false }

        do {
            let response: String
            switch provider {
            case .claude:
                response = try await sendClaudeRequest(system: systemPrompt, user: userMessage, maxTokens: maxTokens)
            case .openai:
                response = try await sendOpenAIRequest(system: systemPrompt, user: userMessage, maxTokens: maxTokens)
            }
            return response
        } catch {
            let aiError = error as? AIAssistantError ?? .requestFailed(error.localizedDescription)
            lastError = aiError
            throw aiError
        }
    }

    private func sendClaudeRequest(system: String, user: String, maxTokens: Int) async throws -> String {
        guard let url = URL(string: claudeEndpoint) else {
            throw AIAssistantError.invalidConfiguration
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(claudeApiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": "claude-sonnet-4-20250514",
            "max_tokens": maxTokens,
            "system": system,
            "messages": [
                ["role": "user", "content": user]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        logger.info("Sending Claude request...")
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIAssistantError.requestFailed("Invalid response")
        }

        if httpResponse.statusCode != 200 {
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw AIAssistantError.apiError(httpResponse.statusCode, message)
            }
            throw AIAssistantError.apiError(httpResponse.statusCode, "Unknown error")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let firstContent = content.first,
              let text = firstContent["text"] as? String else {
            throw AIAssistantError.parseError
        }

        logger.info("Claude response received: \(text.prefix(100))...")
        return text
    }

    private func sendOpenAIRequest(system: String, user: String, maxTokens: Int) async throws -> String {
        guard let url = URL(string: openaiEndpoint) else {
            throw AIAssistantError.invalidConfiguration
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(openaiApiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": "gpt-4o",
            "max_tokens": maxTokens,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        logger.info("Sending OpenAI request...")
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIAssistantError.requestFailed("Invalid response")
        }

        if httpResponse.statusCode != 200 {
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw AIAssistantError.apiError(httpResponse.statusCode, message)
            }
            throw AIAssistantError.apiError(httpResponse.statusCode, "Unknown error")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AIAssistantError.parseError
        }

        logger.info("OpenAI response received: \(content.prefix(100))...")
        return content
    }

    private func buildChatMessages() -> String {
        // For simplicity, concatenate recent history
        // In production, would send as proper message array
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
}

// MARK: - AppStorage Extension

import SwiftUI

extension AppStorage where Value == String {
    init(wrappedValue: String, _ key: String) {
        self.init(wrappedValue: wrappedValue, key, store: .standard)
    }
}
