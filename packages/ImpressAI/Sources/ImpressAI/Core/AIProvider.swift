import Foundation

/// Protocol defining a pluggable AI provider implementation.
///
/// Providers must be `Sendable` for thread-safe concurrent access.
/// All methods are async and designed to work with Swift's structured concurrency.
///
/// Example implementation:
/// ```swift
/// public actor MyProvider: AIProvider {
///     public var metadata: AIProviderMetadata { ... }
///     public func complete(_ request: AICompletionRequest) async throws -> AICompletionResponse { ... }
///     public func stream(_ request: AICompletionRequest) async throws -> AsyncThrowingStream<AIStreamChunk, Error> { ... }
///     public func validate() async throws -> AIProviderStatus { ... }
/// }
/// ```
public protocol AIProvider: Sendable {
    /// Metadata describing the provider's capabilities, models, and requirements.
    var metadata: AIProviderMetadata { get }

    /// Performs a non-streaming completion request.
    ///
    /// - Parameter request: The completion request containing messages, model, and parameters.
    /// - Returns: The complete response from the AI model.
    /// - Throws: `AIError` if the request fails.
    func complete(_ request: AICompletionRequest) async throws -> AICompletionResponse

    /// Performs a streaming completion request.
    ///
    /// - Parameter request: The completion request containing messages, model, and parameters.
    /// - Returns: An async stream of response chunks.
    /// - Throws: `AIError` if the request fails to initiate.
    func stream(_ request: AICompletionRequest) async throws -> AsyncThrowingStream<AIStreamChunk, Error>

    /// Validates the provider's configuration and credentials.
    ///
    /// - Returns: The current status of the provider.
    /// - Throws: `AIError` if validation fails catastrophically.
    func validate() async throws -> AIProviderStatus
}

/// Default implementations for AIProvider.
public extension AIProvider {
    /// Default streaming implementation that wraps the non-streaming complete method.
    func stream(_ request: AICompletionRequest) async throws -> AsyncThrowingStream<AIStreamChunk, Error> {
        let response = try await complete(request)
        return AsyncThrowingStream { continuation in
            continuation.yield(AIStreamChunk(
                id: response.id,
                content: response.content,
                finishReason: response.finishReason,
                usage: response.usage
            ))
            continuation.finish()
        }
    }
}

/// Status of an AI provider.
public enum AIProviderStatus: Sendable, Equatable {
    /// Provider is ready to accept requests.
    case ready

    /// Provider requires credentials to be configured.
    case needsCredentials([String])

    /// Provider is temporarily unavailable (e.g., rate limited).
    case unavailable(reason: String)

    /// Provider encountered a configuration error.
    case error(String)

    /// Whether the provider can currently accept requests.
    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// Category of AI provider for UI grouping.
public enum AIProviderCategory: String, Sendable, CaseIterable, Codable {
    /// Cloud-hosted AI services (Claude, OpenAI, Google).
    case cloud

    /// Locally-running AI services (Ollama).
    case local

    /// AI aggregator services (OpenRouter).
    case aggregator

    /// Agent orchestration systems (Impel).
    case agent

    /// Custom user-defined endpoints.
    case custom

    /// Display name for the category.
    public var displayName: String {
        switch self {
        case .cloud: return "Cloud Services"
        case .local: return "Local Models"
        case .aggregator: return "Aggregators"
        case .agent: return "AI Agents"
        case .custom: return "Custom Endpoints"
        }
    }
}
