import Foundation

/// Central registry and coordinator for AI providers.
///
/// The AIProviderManager handles:
/// - Provider registration and discovery
/// - Request routing to appropriate providers
/// - Credential status tracking
/// - Default provider selection
///
/// Example usage:
/// ```swift
/// let manager = AIProviderManager.shared
/// await manager.registerBuiltInProviders()
///
/// let request = AICompletionRequest(
///     messages: [AIMessage(role: .user, text: "Hello!")]
/// )
/// let response = try await manager.complete(request)
/// ```
public actor AIProviderManager {
    /// Shared singleton instance.
    public static let shared = AIProviderManager()

    private var providers: [String: any AIProvider] = [:]
    private let credentialManager: AICredentialManager

    /// User-selected default provider ID.
    public private(set) var defaultProviderId: String?

    /// User-selected default model ID.
    public private(set) var defaultModelId: String?

    /// Sets the default provider ID.
    /// - Parameter providerId: The provider ID to set as default.
    public func setDefaultProviderId(_ providerId: String?) {
        defaultProviderId = providerId
    }

    /// Sets the default model ID.
    /// - Parameter modelId: The model ID to set as default.
    public func setDefaultModelId(_ modelId: String?) {
        defaultModelId = modelId
    }

    /// Creates a new provider manager.
    ///
    /// - Parameter credentialManager: The credential manager to use.
    public init(credentialManager: AICredentialManager = .shared) {
        self.credentialManager = credentialManager
    }

    // MARK: - Provider Registration

    /// Registers an AI provider.
    ///
    /// - Parameter provider: The provider to register.
    public func register(_ provider: some AIProvider) {
        providers[provider.metadata.id] = provider
    }

    /// Unregisters an AI provider.
    ///
    /// - Parameter providerId: The ID of the provider to unregister.
    public func unregister(_ providerId: String) {
        providers.removeValue(forKey: providerId)
    }

    /// Returns a registered provider by ID.
    ///
    /// - Parameter providerId: The provider ID.
    /// - Returns: The provider, or nil if not found.
    public func provider(for providerId: String) -> (any AIProvider)? {
        providers[providerId]
    }

    /// Returns all registered providers.
    public var allProviders: [any AIProvider] {
        Array(providers.values)
    }

    /// Returns metadata for all registered providers.
    public var allProviderMetadata: [AIProviderMetadata] {
        providers.values.map { $0.metadata }
    }

    /// Registers all built-in providers.
    ///
    /// This includes native Swift providers for common services.
    /// Call `registerExtendedProviders()` to add Rust-backed providers.
    public func registerBuiltInProviders() {
        register(AnthropicProvider(credentialManager: credentialManager))
        register(OpenAIProvider(credentialManager: credentialManager))
        register(GoogleProvider(credentialManager: credentialManager))
        register(OllamaProvider())
        register(OpenRouterProvider(credentialManager: credentialManager))
    }

    /// Registers extended providers backed by the Rust LLM library.
    ///
    /// These providers offer additional backends not available in native Swift:
    /// - Groq: Ultra-fast inference with LPU technology
    /// - Phind: Code-optimized AI with fast responses
    /// - Mistral: European AI with strong multilingual capabilities
    /// - Cohere: Enterprise-focused AI with strong RAG capabilities
    /// - DeepSeek: Affordable AI with strong reasoning capabilities
    /// - xAI (Grok): Grok models with real-time knowledge
    /// - HuggingFace: Access to thousands of open-source models
    ///
    /// Note: Requires the ImpressLLM XCFramework to be built.
    /// Run `crates/impress-llm/build-xcframework.sh` first.
    public func registerExtendedProviders() {
        #if canImport(ImpressLLM)
        for provider in RustLLMProvider.allProviders(credentialManager: credentialManager) {
            register(provider)
        }
        #endif
    }

    /// Registers all available providers (built-in + extended).
    public func registerAllProviders() {
        registerBuiltInProviders()
        registerExtendedProviders()
    }

    /// Whether extended Rust-backed providers are available.
    public nonisolated var hasExtendedProviders: Bool {
        RustLLMProvider.isAvailable
    }

    /// Returns metadata for extended Rust-backed providers.
    ///
    /// This returns the available provider metadata even if ImpressLLM is not
    /// imported, allowing UI to show these providers with "Not Available" status.
    public nonisolated var extendedProviderMetadata: [AIProviderMetadata] {
        RustLLMProvider.providerIds.map { backendId in
            RustLLMProvider(backendId: backendId).metadata
        }
    }

    // MARK: - Completion Requests

    /// Performs a non-streaming completion request.
    ///
    /// Routes the request to the appropriate provider based on:
    /// 1. Explicit `providerId` in the request
    /// 2. The configured default provider
    /// 3. The first configured provider
    ///
    /// - Parameter request: The completion request.
    /// - Returns: The completion response.
    /// - Throws: `AIError` if the request fails.
    public func complete(_ request: AICompletionRequest) async throws -> AICompletionResponse {
        let provider = try await resolveProvider(for: request)
        return try await provider.complete(request)
    }

    /// Performs a streaming completion request.
    ///
    /// - Parameter request: The completion request.
    /// - Returns: An async stream of response chunks.
    /// - Throws: `AIError` if the request fails to initiate.
    public func stream(_ request: AICompletionRequest) async throws -> AsyncThrowingStream<AIStreamChunk, Error> {
        let provider = try await resolveProvider(for: request)
        return try await provider.stream(request)
    }

    // MARK: - Provider Discovery

    /// Returns providers grouped by category.
    public var providersByCategory: [AIProviderCategory: [AIProviderMetadata]] {
        var result: [AIProviderCategory: [AIProviderMetadata]] = [:]

        for provider in providers.values {
            let category = provider.metadata.category
            result[category, default: []].append(provider.metadata)
        }

        return result
    }

    /// Returns the effective default provider.
    public func effectiveDefaultProvider() async -> (any AIProvider)? {
        // First try the user-selected default
        if let defaultId = defaultProviderId,
           let provider = providers[defaultId] {
            let status = try? await provider.validate()
            if status?.isReady == true {
                return provider
            }
        }

        // Fall back to first configured provider
        for provider in providers.values {
            let status = try? await provider.validate()
            if status?.isReady == true {
                return provider
            }
        }

        return nil
    }

    /// Returns the effective default model for a provider.
    ///
    /// - Parameter providerId: The provider ID. If nil, uses the default provider.
    /// - Returns: The default model, or nil if no provider/model is available.
    public func effectiveDefaultModel(for providerId: String? = nil) async -> AIModel? {
        let targetProviderId = providerId ?? defaultProviderId
        let provider: (any AIProvider)?

        if let targetProviderId = targetProviderId {
            provider = providers[targetProviderId]
        } else {
            provider = await effectiveDefaultProvider()
        }

        guard let provider = provider else { return nil }

        // Check for user-selected default model
        if let defaultModelId = defaultModelId,
           provider.metadata.models.contains(where: { $0.id == defaultModelId }) {
            return provider.metadata.models.first { $0.id == defaultModelId }
        }

        return provider.metadata.defaultModel
    }

    // MARK: - Credential Status

    /// Returns credential status for all registered providers.
    public func credentialStatus() async -> [AIProviderCredentialInfo] {
        var result: [AIProviderCredentialInfo] = []

        for provider in providers.values {
            let metadata = provider.metadata
            var fieldStatus: [String: AICredentialFieldStatus] = [:]

            for field in metadata.credentialRequirement.fields {
                if await credentialManager.hasCredential(for: metadata.id, field: field.id) {
                    fieldStatus[field.id] = .valid
                } else if field.isOptional {
                    fieldStatus[field.id] = .notRequired
                } else {
                    fieldStatus[field.id] = .missing
                }
            }

            if metadata.credentialRequirement.fields.isEmpty {
                // Provider requires no credentials
                fieldStatus["_none"] = .notRequired
            }

            result.append(AIProviderCredentialInfo(
                providerId: metadata.id,
                providerName: metadata.name,
                fieldStatus: fieldStatus
            ))
        }

        return result
    }

    /// Checks if a provider has valid credentials configured.
    ///
    /// - Parameter providerId: The provider ID.
    /// - Returns: True if all required credentials are present.
    public func hasValidCredentials(for providerId: String) async -> Bool {
        guard let provider = providers[providerId] else {
            return false
        }

        let requirement = provider.metadata.credentialRequirement

        switch requirement {
        case .none:
            return true
        case .apiKey:
            return await credentialManager.hasCredential(for: providerId, field: "apiKey")
        case .custom(let fields):
            for field in fields where !field.isOptional {
                if !(await credentialManager.hasCredential(for: providerId, field: field.id)) {
                    return false
                }
            }
            return true
        }
    }

    // MARK: - Private Methods

    private func resolveProvider(for request: AICompletionRequest) async throws -> any AIProvider {
        // Try explicit provider ID
        if let providerId = request.providerId {
            guard let provider = providers[providerId] else {
                throw AIError.providerNotFound(providerId)
            }
            return provider
        }

        // Try default provider
        if let provider = await effectiveDefaultProvider() {
            return provider
        }

        // No provider available
        throw AIError.providerNotConfigured("No AI provider configured. Add an API key in Settings.")
    }
}
