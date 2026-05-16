//
//  ImpressAITests.swift
//  ImpressAI
//
//  Tests for the ImpressAI package.
//

import XCTest
@testable import ImpressAI

final class ImpressAITests: XCTestCase {

    // MARK: - AIProviderMetadata Tests

    func testProviderMetadataCreation() {
        let metadata = AIProviderMetadata(
            id: "test",
            name: "Test Provider",
            models: [
                AIModel(id: "test-model", name: "Test Model", isDefault: true)
            ],
            capabilities: .chat,
            credentialRequirement: .apiKey,
            category: .cloud
        )

        XCTAssertEqual(metadata.id, "test")
        XCTAssertEqual(metadata.name, "Test Provider")
        XCTAssertEqual(metadata.models.count, 1)
        XCTAssertEqual(metadata.defaultModel?.id, "test-model")
    }

    // MARK: - AIModel Tests

    func testAIModelCreation() {
        let model = AIModel(
            id: "claude-sonnet-4",
            name: "Claude Sonnet 4",
            contextWindow: 200_000,
            maxOutputTokens: 64_000,
            isDefault: true,
            capabilities: .full
        )

        XCTAssertEqual(model.id, "claude-sonnet-4")
        XCTAssertEqual(model.contextWindow, 200_000)
        XCTAssertTrue(model.isDefault)
    }

    // MARK: - AICapabilities Tests

    func testCapabilitiesCombination() {
        let caps: AICapabilities = [.streaming, .vision, .tools]

        XCTAssertTrue(caps.contains(.streaming))
        XCTAssertTrue(caps.contains(.vision))
        XCTAssertTrue(caps.contains(.tools))
        XCTAssertFalse(caps.contains(.embeddings))
    }

    // MARK: - AIMessage Tests

    func testAIMessageCreation() {
        let message = AIMessage(role: .user, text: "Hello, world!")

        XCTAssertEqual(message.role, .user)
        XCTAssertEqual(message.text, "Hello, world!")
    }

    // MARK: - AICompletionRequest Tests

    func testCompletionRequestCreation() {
        let request = AICompletionRequest(
            providerId: "anthropic",
            modelId: "claude-sonnet-4",
            messages: [AIMessage(role: .user, text: "Hello")],
            systemPrompt: "You are a helpful assistant.",
            maxTokens: 1000
        )

        XCTAssertEqual(request.providerId, "anthropic")
        XCTAssertEqual(request.modelId, "claude-sonnet-4")
        XCTAssertEqual(request.messages.count, 1)
        XCTAssertEqual(request.systemPrompt, "You are a helpful assistant.")
        XCTAssertEqual(request.maxTokens, 1000)
    }

    // MARK: - AIError Tests

    func testAIErrorLocalizedDescription() {
        let error = AIError.unauthorized(message: "Invalid API key")
        XCTAssertTrue(error.errorDescription?.contains("Invalid API key") == true)

        let rateLimited = AIError.rateLimited(retryAfter: 60)
        XCTAssertTrue(rateLimited.isRetryable)
        XCTAssertEqual(rateLimited.suggestedRetryDelay, 60)
    }

    // MARK: - AICredentialRequirement Tests

    func testCredentialRequirementFields() {
        let apiKey = AICredentialRequirement.apiKey
        XCTAssertTrue(apiKey.isRequired)
        XCTAssertEqual(apiKey.fields.count, 1)
        XCTAssertEqual(apiKey.fields.first?.id, "apiKey")

        let none = AICredentialRequirement.none
        XCTAssertFalse(none.isRequired)
        XCTAssertTrue(none.fields.isEmpty)

        let custom = AICredentialRequirement.custom([
            AICredentialField(id: "endpoint", label: "Server URL"),
            AICredentialField(id: "token", label: "Token", isSecret: true)
        ])
        XCTAssertEqual(custom.fields.count, 2)
    }

    // MARK: - AIProviderCategory Tests

    func testProviderCategoryDisplayNames() {
        XCTAssertEqual(AIProviderCategory.cloud.displayName, "Cloud Services")
        XCTAssertEqual(AIProviderCategory.local.displayName, "Local Models")
        XCTAssertEqual(AIProviderCategory.agent.displayName, "AI Agents")
    }

    // MARK: - AIProviderStatus Tests

    func testProviderStatusIsReady() {
        XCTAssertTrue(AIProviderStatus.ready.isReady)
        XCTAssertFalse(AIProviderStatus.needsCredentials(["apiKey"]).isReady)
        XCTAssertFalse(AIProviderStatus.unavailable(reason: "Server down").isReady)
        XCTAssertFalse(AIProviderStatus.error("Something went wrong").isReady)
    }

    // MARK: - AIUsage Tests

    func testAIUsageTotalTokens() {
        let usage = AIUsage(inputTokens: 100, outputTokens: 50)
        XCTAssertEqual(usage.totalTokens, 150)
    }

    // MARK: - AIStreamChunk Tests

    func testStreamChunkTextExtraction() {
        let chunk = AIStreamChunk(
            content: [.text("Hello, "), .text("world!")],
            finishReason: nil
        )
        XCTAssertEqual(chunk.text, "Hello, world!")
    }

    // MARK: - AICompletionResponse Tests

    func testCompletionResponseTextExtraction() {
        let response = AICompletionResponse(
            id: "test-123",
            content: [.text("This is a test response.")],
            model: "claude-sonnet-4",
            finishReason: .stop,
            usage: AIUsage(inputTokens: 10, outputTokens: 20)
        )

        XCTAssertEqual(response.id, "test-123")
        XCTAssertEqual(response.text, "This is a test response.")
        XCTAssertEqual(response.model, "claude-sonnet-4")
        XCTAssertEqual(response.finishReason, .stop)
        XCTAssertEqual(response.usage?.totalTokens, 30)
    }

    // MARK: - AIProviderManager Tests

    func testManagerInitialization() async throws {
        let manager = AIProviderManager()
        await manager.registerBuiltInProviders()
        let providers = await manager.allProviders
        XCTAssertGreaterThan(providers.count, 0, "Manager should have registered providers")
    }
}
