import Foundation

/// AI provider that bridges to the Rust-based graniet/llm library.
///
/// This provider supports additional backends not available in native Swift:
/// - Groq: Ultra-fast inference with LPU technology
/// - Phind: Code-optimized AI with fast responses
/// - Mistral: European AI with strong multilingual capabilities
/// - Cohere: Enterprise-focused AI with strong RAG capabilities
/// - DeepSeek: Affordable AI with strong reasoning capabilities
/// - xAI (Grok): Grok models with real-time knowledge
/// - HuggingFace: Access to thousands of open-source models
///
/// Note: This provider requires the ImpressLLM framework to be built.
/// When ImpressLLM is not available, the provider returns unavailable status.
public actor RustLLMProvider: AIProvider {
    /// The backend identifier (e.g., "groq", "phind")
    private let backendId: String

    /// Metadata for this provider instance
    private let _metadata: AIProviderMetadata

    /// Credential manager for API keys
    private let credentialManager: AICredentialManager

    public nonisolated var metadata: AIProviderMetadata {
        _metadata
    }

    /// Creates a provider instance for a specific Rust-backed backend.
    ///
    /// - Parameters:
    ///   - backendId: The backend identifier (e.g., "groq", "phind")
    ///   - credentialManager: The credential manager to use (defaults to shared)
    public init(backendId: String, credentialManager: AICredentialManager = .shared) {
        self.backendId = backendId
        self.credentialManager = credentialManager
        self._metadata = Self.makeMetadata(for: backendId)
    }

    public func complete(_ request: AICompletionRequest) async throws -> AICompletionResponse {
        // ImpressLLM integration is currently disabled
        // This provider will be enabled when the Rust LLM integration is complete
        throw AIError.providerNotConfigured("ImpressLLM framework not fully integrated. Use native providers instead.")
    }

    public func validate() async throws -> AIProviderStatus {
        // Check if API key is configured
        let hasKey = await credentialManager.hasCredential(for: backendId, field: "apiKey")
        if !hasKey {
            return .needsCredentials(["apiKey"])
        }

        // ImpressLLM is not currently available
        return .unavailable(reason: "ImpressLLM framework not fully integrated")
    }

    // MARK: - Static Metadata Factory

    private static func makeMetadata(for backendId: String) -> AIProviderMetadata {
        switch backendId {
        case "groq":
            return AIProviderMetadata(
                id: "groq",
                name: "Groq",
                description: "Ultra-fast inference with LPU technology",
                models: [
                    AIModel(
                        id: "llama-3.3-70b-versatile",
                        name: "Llama 3.3 70B Versatile",
                        description: "Latest Llama model, excellent all-around performance",
                        contextWindow: 128_000,
                        maxOutputTokens: 32_768,
                        isDefault: true,
                        capabilities: .chat
                    ),
                    AIModel(
                        id: "llama-3.1-8b-instant",
                        name: "Llama 3.1 8B Instant",
                        description: "Smaller, faster model for quick tasks",
                        contextWindow: 128_000,
                        maxOutputTokens: 8_192,
                        capabilities: .chat
                    ),
                    AIModel(
                        id: "mixtral-8x7b-32768",
                        name: "Mixtral 8x7B",
                        description: "Mixture of experts model, fast and efficient",
                        contextWindow: 32_768,
                        maxOutputTokens: 32_768,
                        capabilities: .chat
                    ),
                ],
                capabilities: .chat,
                credentialRequirement: .apiKey,
                category: .cloud,
                registrationURL: URL(string: "https://console.groq.com/keys"),
                rateLimit: AIRateLimit(requestsPerInterval: 30, intervalSeconds: 60),
                iconName: "bolt.fill"
            )

        case "phind":
            return AIProviderMetadata(
                id: "phind",
                name: "Phind",
                description: "Code-optimized AI with fast responses",
                models: [
                    AIModel(
                        id: "Phind-70B",
                        name: "Phind 70B",
                        description: "Code-optimized model, excellent for programming",
                        contextWindow: 32_000,
                        maxOutputTokens: 4_096,
                        isDefault: true,
                        capabilities: .chat
                    ),
                ],
                capabilities: .chat,
                credentialRequirement: .apiKey,
                category: .cloud,
                registrationURL: URL(string: "https://www.phind.com/api"),
                iconName: "chevron.left.forwardslash.chevron.right"
            )

        case "mistral":
            return AIProviderMetadata(
                id: "mistral",
                name: "Mistral AI",
                description: "European AI with strong multilingual capabilities",
                models: [
                    AIModel(
                        id: "mistral-large-latest",
                        name: "Mistral Large",
                        description: "Most capable Mistral model",
                        contextWindow: 128_000,
                        maxOutputTokens: 128_000,
                        isDefault: true,
                        capabilities: .chat
                    ),
                    AIModel(
                        id: "mistral-small-latest",
                        name: "Mistral Small",
                        description: "Fast and efficient",
                        contextWindow: 32_000,
                        maxOutputTokens: 32_000,
                        capabilities: .chat
                    ),
                    AIModel(
                        id: "codestral-latest",
                        name: "Codestral",
                        description: "Specialized for code generation",
                        contextWindow: 32_000,
                        maxOutputTokens: 32_000,
                        capabilities: .chat
                    ),
                ],
                capabilities: .chat,
                credentialRequirement: .apiKey,
                category: .cloud,
                registrationURL: URL(string: "https://console.mistral.ai/api-keys/"),
                iconName: "wind"
            )

        case "cohere":
            return AIProviderMetadata(
                id: "cohere",
                name: "Cohere",
                description: "Enterprise-focused AI with strong RAG capabilities",
                models: [
                    AIModel(
                        id: "command-r-plus",
                        name: "Command R+",
                        description: "Most capable Cohere model",
                        contextWindow: 128_000,
                        maxOutputTokens: 4_096,
                        isDefault: true,
                        capabilities: .chat
                    ),
                    AIModel(
                        id: "command-r",
                        name: "Command R",
                        description: "Balanced model for general use",
                        contextWindow: 128_000,
                        maxOutputTokens: 4_096,
                        capabilities: .chat
                    ),
                ],
                capabilities: .chat,
                credentialRequirement: .apiKey,
                category: .cloud,
                registrationURL: URL(string: "https://dashboard.cohere.com/api-keys"),
                iconName: "c.circle.fill"
            )

        case "deepseek":
            return AIProviderMetadata(
                id: "deepseek",
                name: "DeepSeek",
                description: "Affordable AI with strong reasoning capabilities",
                models: [
                    AIModel(
                        id: "deepseek-chat",
                        name: "DeepSeek Chat",
                        description: "General-purpose chat model",
                        contextWindow: 64_000,
                        maxOutputTokens: 4_096,
                        isDefault: true,
                        capabilities: .chat
                    ),
                    AIModel(
                        id: "deepseek-coder",
                        name: "DeepSeek Coder",
                        description: "Specialized for code generation",
                        contextWindow: 64_000,
                        maxOutputTokens: 4_096,
                        capabilities: .chat
                    ),
                    AIModel(
                        id: "deepseek-reasoner",
                        name: "DeepSeek Reasoner",
                        description: "Advanced reasoning capabilities (R1)",
                        contextWindow: 64_000,
                        maxOutputTokens: 8_192,
                        capabilities: [.chat, .thinking]
                    ),
                ],
                capabilities: .chat,
                credentialRequirement: .apiKey,
                category: .cloud,
                registrationURL: URL(string: "https://platform.deepseek.com/api_keys"),
                iconName: "brain"
            )

        case "xai":
            return AIProviderMetadata(
                id: "xai",
                name: "xAI (Grok)",
                description: "Grok models with real-time knowledge",
                models: [
                    AIModel(
                        id: "grok-beta",
                        name: "Grok Beta",
                        description: "xAI's flagship model",
                        contextWindow: 128_000,
                        maxOutputTokens: 4_096,
                        isDefault: true,
                        capabilities: .chat
                    ),
                    AIModel(
                        id: "grok-2-1212",
                        name: "Grok 2",
                        description: "Latest Grok model",
                        contextWindow: 128_000,
                        maxOutputTokens: 4_096,
                        capabilities: .chat
                    ),
                ],
                capabilities: .chat,
                credentialRequirement: .apiKey,
                category: .cloud,
                registrationURL: URL(string: "https://console.x.ai/"),
                iconName: "x.circle.fill"
            )

        case "huggingface":
            return AIProviderMetadata(
                id: "huggingface",
                name: "HuggingFace",
                description: "Access to thousands of open-source models",
                models: [
                    AIModel(
                        id: "meta-llama/Meta-Llama-3-8B-Instruct",
                        name: "Llama 3 8B Instruct",
                        description: "Meta's instruction-tuned Llama",
                        contextWindow: 8_192,
                        maxOutputTokens: 4_096,
                        isDefault: true,
                        capabilities: .chat
                    ),
                    AIModel(
                        id: "mistralai/Mistral-7B-Instruct-v0.3",
                        name: "Mistral 7B Instruct",
                        description: "Efficient instruction model",
                        contextWindow: 32_768,
                        maxOutputTokens: 4_096,
                        capabilities: .chat
                    ),
                ],
                capabilities: .chat,
                credentialRequirement: .apiKey,
                category: .cloud,
                registrationURL: URL(string: "https://huggingface.co/settings/tokens"),
                iconName: "face.smiling"
            )

        default:
            return AIProviderMetadata(
                id: backendId,
                name: backendId.capitalized,
                models: [],
                capabilities: .chat,
                credentialRequirement: .apiKey,
                category: .cloud
            )
        }
    }
}

// MARK: - Factory Methods

public extension RustLLMProvider {
    /// Returns all available Rust-backed providers.
    static func allProviders(credentialManager: AICredentialManager = .shared) -> [RustLLMProvider] {
        let backends = ["groq", "phind", "mistral", "cohere", "deepseek", "xai", "huggingface"]
        return backends.map { RustLLMProvider(backendId: $0, credentialManager: credentialManager) }
    }

    /// Provider IDs for all Rust-backed providers.
    static var providerIds: [String] {
        ["groq", "phind", "mistral", "cohere", "deepseek", "xai", "huggingface"]
    }

    /// Whether the ImpressLLM framework is available.
    static var isAvailable: Bool {
        // ImpressLLM integration is currently disabled
        false
    }
}
