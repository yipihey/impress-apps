/// ImpressAI - A shared, pluggable AI service abstraction for impress-apps.
///
/// This package provides a protocol-based AI service that supports multiple providers
/// including Claude (Anthropic), OpenAI, Google Gemini, Ollama, and OpenRouter.
///
/// ## Overview
///
/// ImpressAI is built around several key concepts:
///
/// - **AIProvider**: Protocol for implementing AI service providers
/// - **AIProviderManager**: Central actor for managing providers and routing requests
/// - **AIProviderMetadata**: Self-describing provider configuration
/// - **AICredentialManager**: Secure credential storage
///
/// ## Quick Start
///
/// ```swift
/// // Get the shared manager
/// let manager = AIProviderManager.shared
///
/// // Register built-in providers
/// await manager.registerBuiltInProviders()
///
/// // Make a completion request
/// let request = AICompletionRequest(
///     messages: [AIMessage(role: .user, text: "Hello!")]
/// )
/// let response = try await manager.complete(request)
/// print(response.text)
/// ```
///
/// ## Available Providers
///
/// - **AnthropicProvider**: Claude models from Anthropic
/// - **OpenAIProvider**: GPT models from OpenAI
/// - **GoogleProvider**: Gemini models from Google
/// - **OllamaProvider**: Local models via Ollama
/// - **OpenRouterProvider**: Aggregated access to multiple providers
///
/// ## Credential Management
///
/// Credentials are stored securely in the system keychain:
///
/// ```swift
/// let credentialManager = AICredentialManager.shared
/// try await credentialManager.store("sk-...", for: "anthropic", field: "apiKey")
/// ```

// MARK: - Core Types

@_exported import Foundation

// Re-export all public types
public typealias _AIProviderProtocol = AIProvider
public typealias _AIProviderMetadataType = AIProviderMetadata
public typealias _AIModelType = AIModel
public typealias _AICapabilitiesType = AICapabilities
public typealias _AICredentialRequirementType = AICredentialRequirement
public typealias _AICredentialFieldType = AICredentialField
public typealias _AIProviderCategoryType = AIProviderCategory
public typealias _AIProviderStatusType = AIProviderStatus
public typealias _AIRateLimitType = AIRateLimit

public typealias _AICompletionRequestType = AICompletionRequest
public typealias _AICompletionResponseType = AICompletionResponse
public typealias _AIMessageType = AIMessage
public typealias _AIRoleType = AIRole
public typealias _AIContentType = AIContent
public typealias _AIImageContentType = AIImageContent
public typealias _AIToolType = AITool
public typealias _AIToolUseType = AIToolUse
public typealias _AIToolResultType = AIToolResult
public typealias _AIStreamChunkType = AIStreamChunk
public typealias _AIFinishReasonType = AIFinishReason
public typealias _AIUsageType = AIUsage
public typealias _AnySendableType = AnySendable

public typealias _AIErrorType = AIError

// MARK: - Availability Types

public typealias _AIAvailabilityStatusType = AIAvailabilityStatus
public typealias _AIUnavailableReasonType = AIUnavailableReason
public typealias _AIAvailabilityCheckerType = AIAvailabilityChecker

// MARK: - Category Types

public typealias _AITaskCategoryType = AITaskCategory
public typealias _AIModelReferenceType = AIModelReference
public typealias _AITaskCategoryAssignmentType = AITaskCategoryAssignment
public typealias _AITaskCategoryManagerType = AITaskCategoryManager
public typealias _AITaskCategorySettingsType = AITaskCategorySettings

// MARK: - Execution Types

public typealias _AIMultiModelExecutorType = AIMultiModelExecutor
public typealias _AIModelExecutionResultType = AIModelExecutionResult
public typealias _AIComparisonResultType = AIComparisonResult
public typealias _AIStreamingProgressType = AIStreamingProgress
