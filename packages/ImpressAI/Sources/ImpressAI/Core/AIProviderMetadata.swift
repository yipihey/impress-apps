import Foundation

/// Metadata describing an AI provider's capabilities, available models, and requirements.
public struct AIProviderMetadata: Sendable, Identifiable, Equatable {
    /// Unique identifier for the provider (e.g., "anthropic", "openai", "impel").
    public let id: String

    /// Human-readable name (e.g., "Claude (Anthropic)").
    public let name: String

    /// Optional description of the provider.
    public let description: String?

    /// Available models from this provider.
    public let models: [AIModel]

    /// Capabilities supported by this provider.
    public let capabilities: AICapabilities

    /// Credential requirements for this provider.
    public let credentialRequirement: AICredentialRequirement

    /// Category for UI grouping.
    public let category: AIProviderCategory

    /// Optional URL where users can obtain API keys.
    public let registrationURL: URL?

    /// Optional rate limit configuration.
    public let rateLimit: AIRateLimit?

    /// SF Symbol name for the provider icon.
    public let iconName: String?

    public init(
        id: String,
        name: String,
        description: String? = nil,
        models: [AIModel],
        capabilities: AICapabilities,
        credentialRequirement: AICredentialRequirement,
        category: AIProviderCategory,
        registrationURL: URL? = nil,
        rateLimit: AIRateLimit? = nil,
        iconName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.models = models
        self.capabilities = capabilities
        self.credentialRequirement = credentialRequirement
        self.category = category
        self.registrationURL = registrationURL
        self.rateLimit = rateLimit
        self.iconName = iconName
    }

    /// Returns the default model for this provider, if any.
    public var defaultModel: AIModel? {
        models.first { $0.isDefault } ?? models.first
    }
}

/// Represents an AI model available from a provider.
public struct AIModel: Sendable, Identifiable, Equatable, Codable {
    /// Unique identifier for the model (e.g., "claude-sonnet-4-20250514").
    public let id: String

    /// Human-readable name (e.g., "Claude Sonnet 4").
    public let name: String

    /// Optional description of the model's characteristics.
    public let description: String?

    /// Maximum context window size in tokens.
    public let contextWindow: Int?

    /// Maximum output tokens supported.
    public let maxOutputTokens: Int?

    /// Whether this is the default model for the provider.
    public let isDefault: Bool

    /// Model-specific capabilities (may differ from provider capabilities).
    public let capabilities: AICapabilities?

    public init(
        id: String,
        name: String,
        description: String? = nil,
        contextWindow: Int? = nil,
        maxOutputTokens: Int? = nil,
        isDefault: Bool = false,
        capabilities: AICapabilities? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.isDefault = isDefault
        self.capabilities = capabilities
    }
}

/// Capabilities supported by a provider or model.
public struct AICapabilities: OptionSet, Sendable, Equatable, Codable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Supports streaming responses.
    public static let streaming = AICapabilities(rawValue: 1 << 0)

    /// Supports vision/image inputs.
    public static let vision = AICapabilities(rawValue: 1 << 1)

    /// Supports tool/function calling.
    public static let tools = AICapabilities(rawValue: 1 << 2)

    /// Supports system prompts.
    public static let systemPrompt = AICapabilities(rawValue: 1 << 3)

    /// Supports JSON mode output.
    public static let jsonMode = AICapabilities(rawValue: 1 << 4)

    /// Supports embedding generation.
    public static let embeddings = AICapabilities(rawValue: 1 << 5)

    /// Supports extended thinking/reasoning.
    public static let thinking = AICapabilities(rawValue: 1 << 6)

    /// Common capabilities for chat models.
    public static let chat: AICapabilities = [.streaming, .systemPrompt]

    /// Full capabilities for advanced models.
    public static let full: AICapabilities = [.streaming, .vision, .tools, .systemPrompt, .jsonMode]
}

/// Credential requirement specification for a provider.
public enum AICredentialRequirement: Sendable, Equatable {
    /// No credentials required (e.g., local Ollama).
    case none

    /// Requires an API key.
    case apiKey

    /// Requires custom credential fields.
    case custom([AICredentialField])

    /// Fields required for credential configuration.
    public var fields: [AICredentialField] {
        switch self {
        case .none:
            return []
        case .apiKey:
            return [AICredentialField(id: "apiKey", label: "API Key", isSecret: true)]
        case .custom(let fields):
            return fields
        }
    }

    /// Whether any credentials are required.
    public var isRequired: Bool {
        switch self {
        case .none: return false
        case .apiKey, .custom: return true
        }
    }
}

/// A credential field definition.
public struct AICredentialField: Sendable, Identifiable, Equatable {
    /// Unique identifier for the field.
    public let id: String

    /// Display label for the field.
    public let label: String

    /// Placeholder text for the input field.
    public let placeholder: String?

    /// Whether this field contains sensitive data (should be masked).
    public let isSecret: Bool

    /// Whether this field is optional.
    public let isOptional: Bool

    public init(
        id: String,
        label: String,
        placeholder: String? = nil,
        isSecret: Bool = false,
        isOptional: Bool = false
    ) {
        self.id = id
        self.label = label
        self.placeholder = placeholder
        self.isSecret = isSecret
        self.isOptional = isOptional
    }
}

/// Rate limit configuration for a provider.
public struct AIRateLimit: Sendable, Equatable {
    /// Maximum requests per interval.
    public let requestsPerInterval: Int

    /// Interval duration in seconds.
    public let intervalSeconds: TimeInterval

    /// Minimum delay between requests.
    public var minDelay: TimeInterval {
        intervalSeconds / Double(requestsPerInterval)
    }

    public init(requestsPerInterval: Int, intervalSeconds: TimeInterval) {
        self.requestsPerInterval = requestsPerInterval
        self.intervalSeconds = intervalSeconds
    }
}
