//
//  ImpressAITests.swift
//  ImpressAI
//
//  Tests for the ImpressAI package.
//

import XCTest
@testable import ImpressAI

private actor TestReadyProvider: AIProvider {
    let metadata = AIProviderMetadata(
        id: "test-ready",
        name: "Test Ready",
        models: [AIModel(id: "test-model", name: "Test Model", isDefault: true)],
        capabilities: .full,
        credentialRequirement: .none,
        category: .local
    )

    func complete(_ request: AICompletionRequest) async throws -> AICompletionResponse {
        AICompletionResponse(
            id: "test-response",
            content: [.text("curated")],
            model: request.modelId ?? "test-model",
            finishReason: .stop
        )
    }

    func validate() async throws -> AIProviderStatus { .ready }
}

private actor TestUnavailableSelectedProvider: AIProvider {
    let metadata = AIProviderMetadata(
        id: "test-unavailable-selected",
        name: "Test Unavailable Selected",
        models: [AIModel(id: "test-model", name: "Test Model", isDefault: true)],
        capabilities: .full,
        credentialRequirement: .none,
        category: .local
    )

    func complete(_ request: AICompletionRequest) async throws -> AICompletionResponse {
        AICompletionResponse(
            id: "selected-response",
            content: [.text("selected provider was attempted")],
            model: request.modelId ?? "test-model",
            finishReason: .stop
        )
    }

    func validate() async throws -> AIProviderStatus {
        .unavailable(reason: "Companion service is stopped")
    }
}

private actor TestLaunchProbe {
    private var launches = 0

    func launch() async throws {
        launches += 1
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    func launchCount() -> Int { launches }
}

private final class TestWorkerLaunchProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var launches = 0

    func launch() {
        lock.lock()
        launches += 1
        lock.unlock()
        Thread.sleep(forTimeInterval: 0.05)
    }

    func launchCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return launches
    }
}

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

    func testCategoryExecutionFallsBackToSuiteDefaultWithoutOpeningSettings() async throws {
        let suiteName = "ImpressAITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = AIProviderManager(
            credentialManager: AICredentialManager(accessGroup: nil),
            defaults: defaults
        )
        await manager.register(TestReadyProvider())
        await manager.setDefaultProviderId("test-ready")
        await manager.setDefaultModelId("test-model")

        let categoryManager = AITaskCategoryManager(
            storage: AITaskCategoryStorage(defaults: defaults)
        )
        let executor = AIMultiModelExecutor(
            providerManager: manager,
            categoryManager: categoryManager
        )

        let result = try await executor.executePrimary(
            AICompletionRequest(messages: [AIMessage(role: .user, text: "Curate this paper")]),
            categoryId: "research.search"
        )
        XCTAssertEqual(result?.text, "curated")
        XCTAssertEqual(result?.modelReference.id, "test-ready:test-model")
    }

    func testSelectedProviderIsAttemptedEvenWhenPassiveValidationIsUnavailable() async throws {
        let suiteName = "ImpressAITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = AIProviderManager(
            credentialManager: AICredentialManager(accessGroup: nil),
            defaults: defaults
        )
        await manager.register(TestUnavailableSelectedProvider())
        await manager.setDefaultProviderId("test-unavailable-selected")

        let response = try await manager.complete(AICompletionRequest(
            messages: [AIMessage(role: .user, text: "Try the selected provider")]
        ))
        XCTAssertEqual(response.text, "selected provider was attempted")
    }

    func testOMLXControllerCoalescesConcurrentLaunchRequests() async throws {
        let probe = TestLaunchProbe()
        let controller = OMLXServiceController {
            try await probe.launch()
        }

        async let first: Void = controller.launchApplication(bundleId: OMLXServiceController.bundleIdentifier)
        async let second: Void = controller.launchApplication(bundleId: OMLXServiceController.bundleIdentifier)
        _ = try await (first, second)

        let launchCount = await probe.launchCount()
        XCTAssertEqual(launchCount, 1)
    }

    func testModelWorkerControllerCoalescesConcurrentLaunchRequests() async throws {
        let probe = TestWorkerLaunchProbe()
        let controller = ImpressModelWorkerController {
            probe.launch()
        }

        async let first: Void = controller.startWorker()
        async let second: Void = controller.startWorker()
        _ = try await (first, second)

        XCTAssertEqual(probe.launchCount(), 1)
    }

    private static func jsonResponse(
        _ request: URLRequest,
        object: Any,
        statusCode: Int = 200
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, try! JSONSerialization.data(withJSONObject: object))
    }

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 4096)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
