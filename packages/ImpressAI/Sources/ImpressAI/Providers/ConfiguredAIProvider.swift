import Foundation

/// An `AIProvider` façade that routes every request through the suite-wide
/// provider and model selected in `AISettingsView`.
///
/// Agent engines can depend on this provider without hard-coding Anthropic,
/// OpenAI, or a particular local runtime.
public actor ConfiguredAIProvider: AIProvider {
    public let metadata = AIProviderMetadata(
        id: "configured",
        name: "Configured Impress AI",
        description: "The provider and model selected for the Impress suite",
        models: [],
        capabilities: .full,
        credentialRequirement: .none,
        category: .agent,
        iconName: "sparkles"
    )

    private let manager: AIProviderManager

    public init(manager: AIProviderManager = .shared) {
        self.manager = manager
    }

    public func complete(_ request: AICompletionRequest) async throws -> AICompletionResponse {
        await manager.registerAllProviders()
        return try await manager.complete(request)
    }

    public func stream(_ request: AICompletionRequest) async throws -> AsyncThrowingStream<AIStreamChunk, Error> {
        await manager.registerAllProviders()
        return try await manager.stream(request)
    }

    public func validate() async throws -> AIProviderStatus {
        await manager.registerAllProviders()
        guard await manager.effectiveDefaultProvider() != nil else {
            return .unavailable(reason: "No suite-wide AI provider is ready")
        }
        return .ready
    }
}
