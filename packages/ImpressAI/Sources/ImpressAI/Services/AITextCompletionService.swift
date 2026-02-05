//
//  AITextCompletionService.swift
//  ImpressAI
//
//  High-level text completion service that wraps AI providers
//  with a simpler API for common use cases.
//

import Foundation

/// High-level service for AI text completions.
///
/// Provides a simplified API for:
/// - Streaming text completions
/// - Non-streaming completions
/// - Provider selection and fallback
///
/// Usage:
/// ```swift
/// let service = AITextCompletionService.shared
/// let text = try await service.complete(
///     systemPrompt: "You are a helpful assistant.",
///     userMessage: "Explain Swift concurrency.",
///     provider: .anthropic
/// )
/// ```
@MainActor @Observable
public final class AITextCompletionService {

    // MARK: - Singleton

    public static let shared = AITextCompletionService()

    // MARK: - State

    /// Whether a request is in progress
    public private(set) var isLoading = false

    /// The currently selected provider
    public var selectedProvider: AITextProvider = .anthropic {
        didSet {
            UserDefaults.standard.set(selectedProvider.rawValue, forKey: "impressai.selectedProvider")
        }
    }

    // MARK: - Private State

    private let credentialManager = AICredentialManager.shared
    private let anthropicProvider = AnthropicProvider()
    private let openAIProvider = OpenAIProvider()

    // MARK: - Initialization

    private init() {
        let stored = UserDefaults.standard.string(forKey: "impressai.selectedProvider") ?? "anthropic"
        selectedProvider = AITextProvider(rawValue: stored) ?? .anthropic
    }

    // MARK: - Configuration

    /// Check if the current provider is configured with credentials.
    public var isConfigured: Bool {
        get async {
            await credentialManager.hasCredential(for: selectedProvider.providerId, field: "apiKey")
        }
    }

    /// Check if a specific provider is configured.
    public func isConfigured(provider: AITextProvider) async -> Bool {
        await credentialManager.hasCredential(for: provider.providerId, field: "apiKey")
    }

    /// Set API key for a provider.
    public func setAPIKey(_ key: String, for provider: AITextProvider) async throws {
        try await credentialManager.store(key, for: provider.providerId, field: "apiKey")
    }

    /// Get masked API key for display.
    public func maskedAPIKey(for provider: AITextProvider) async -> String {
        guard let key = await credentialManager.retrieve(for: provider.providerId, field: "apiKey") else {
            return ""
        }
        if key.isEmpty { return "" }
        if key.count <= 8 { return String(repeating: "•", count: key.count) }
        return key.prefix(4) + String(repeating: "•", count: key.count - 8) + key.suffix(4)
    }

    // MARK: - Completion API

    /// Perform a non-streaming text completion.
    ///
    /// - Parameters:
    ///   - systemPrompt: System instructions for the model
    ///   - userMessage: The user's message
    ///   - maxTokens: Maximum tokens to generate
    ///   - provider: Optional provider override (uses selectedProvider if nil)
    /// - Returns: The generated text
    public func complete(
        systemPrompt: String,
        userMessage: String,
        maxTokens: Int = 2000,
        provider: AITextProvider? = nil
    ) async throws -> String {
        let targetProvider = provider ?? selectedProvider

        guard await isConfigured(provider: targetProvider) else {
            throw AITextCompletionError.notConfigured
        }

        isLoading = true
        defer { isLoading = false }

        let request = AICompletionRequest(
            providerId: targetProvider.providerId,
            messages: [AIMessage(role: .user, text: userMessage)],
            systemPrompt: systemPrompt,
            maxTokens: maxTokens
        )

        let response = try await getProvider(for: targetProvider).complete(request)
        return response.text
    }

    /// Perform a streaming text completion.
    ///
    /// - Parameters:
    ///   - systemPrompt: System instructions for the model
    ///   - userMessage: The user's message
    ///   - maxTokens: Maximum tokens to generate
    ///   - provider: Optional provider override (uses selectedProvider if nil)
    /// - Returns: An async stream of text chunks
    public func stream(
        systemPrompt: String,
        userMessage: String,
        maxTokens: Int = 2000,
        provider: AITextProvider? = nil
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let targetProvider = provider ?? self.selectedProvider

                    guard await self.isConfigured(provider: targetProvider) else {
                        throw AITextCompletionError.notConfigured
                    }

                    await MainActor.run {
                        self.isLoading = true
                    }

                    let request = AICompletionRequest(
                        providerId: targetProvider.providerId,
                        messages: [AIMessage(role: .user, text: userMessage)],
                        systemPrompt: systemPrompt,
                        maxTokens: maxTokens,
                        stream: true
                    )

                    let stream = try await self.getProvider(for: targetProvider).stream(request)

                    for try await chunk in stream {
                        if !chunk.text.isEmpty {
                            continuation.yield(chunk.text)
                        }
                        if chunk.finishReason != nil {
                            break
                        }
                    }

                    await MainActor.run {
                        self.isLoading = false
                    }

                    continuation.finish()

                } catch {
                    await MainActor.run {
                        self.isLoading = false
                    }
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Private Methods

    private func getProvider(for provider: AITextProvider) -> any AIProvider {
        switch provider {
        case .anthropic:
            return anthropicProvider
        case .openai:
            return openAIProvider
        }
    }
}

// MARK: - Supporting Types

/// Available text completion providers.
public enum AITextProvider: String, CaseIterable, Identifiable, Sendable {
    case anthropic
    case openai

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .anthropic: return "Claude (Anthropic)"
        case .openai: return "GPT (OpenAI)"
        }
    }

    var providerId: String {
        switch self {
        case .anthropic: return "anthropic"
        case .openai: return "openai"
        }
    }
}

/// Errors from text completion operations.
public enum AITextCompletionError: LocalizedError {
    case notConfigured
    case requestFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "AI provider is not configured. Please add your API key in Settings."
        case .requestFailed(let message):
            return "Request failed: \(message)"
        }
    }
}
