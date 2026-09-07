import XCTest
@testable import ImpressAI

/// The Swift adapter over the Rust registry: request/response mapping,
/// stream folding, passive validation, and the one host-launch retry.
final class RustBridgedAIProviderTests: XCTestCase {

    private func makeProvider(
        descriptor: AIProviderDescriptor = FakeCatalogue.omlx,
        bridge: FakeAIBridge,
        launcher: FakeHostLauncher = FakeHostLauncher()
    ) -> RustBridgedAIProvider {
        RustBridgedAIProvider(descriptor: descriptor, bridge: bridge, hostLauncher: launcher, startupTimeout: 0.5)
    }

    // MARK: - Metadata

    func testMetadataComesFromTheDescriptor() {
        let provider = makeProvider(bridge: FakeAIBridge(descriptors: [FakeCatalogue.omlx]))
        XCTAssertEqual(provider.metadata.id, "omlx")
        XCTAssertEqual(provider.metadata.category, .local)
        XCTAssertEqual(provider.metadata.iconName, "cpu")
        XCTAssertEqual(provider.metadata.credentialRequirement.fields.map(\.id), ["apiKey"])
        XCTAssertTrue(provider.metadata.capabilities.contains(.tools))

        let apple = makeProvider(descriptor: FakeCatalogue.apple, bridge: FakeAIBridge(descriptors: [FakeCatalogue.apple]))
        XCTAssertEqual(apple.metadata.credentialRequirement, .none)
        XCTAssertEqual(apple.metadata.defaultModel?.id, "apple-on-device")
    }

    // MARK: - Completion mapping

    func testCompletionMapsRequestAndResponseThroughTheBridge() async throws {
        let bridge = FakeAIBridge(descriptors: [FakeCatalogue.omlx])
        await bridge.setCompleteHandler { request in
            XCTAssertEqual(request.providerId, "omlx")
            XCTAssertEqual(request.modelId, "mlx-community--Qwen3.5-4B-4bit")
            XCTAssertEqual(request.systemPrompt, "You are an MNRAS manuscript editor.")
            XCTAssertEqual(request.messages.count, 1)
            XCTAssertEqual(request.messages[0].role, .user)
            XCTAssertEqual(request.messages[0].content, [.text("Refine this paragraph on primordial chemistry.")])
            XCTAssertEqual(request.maxTokens, 512)
            XCTAssertEqual(request.temperature, 0.2)
            XCTAssertTrue(request.thinking)
            return AIBridgeChatResponse(
                id: "refinement-1",
                target: AIResolvedTarget(providerId: "omlx", modelId: request.modelId ?? "", endpointId: "local-omlx", origin: "explicit"),
                content: [.text("The revised paragraph is clearer and preserves the numerical claim.")],
                reasoning: "checked units",
                finishReason: .stop,
                usage: AIUsage(inputTokens: 31, outputTokens: 12)
            )
        }
        let provider = makeProvider(bridge: bridge)
        let response = try await provider.complete(AICompletionRequest(
            modelId: "mlx-community--Qwen3.5-4B-4bit",
            messages: [AIMessage(role: .user, text: "Refine this paragraph on primordial chemistry.")],
            systemPrompt: "You are an MNRAS manuscript editor.",
            maxTokens: 512,
            temperature: 0.2,
            additionalParameters: [AIBridgeMapping.thinkingParameter: AnySendable(true)]
        ))
        XCTAssertTrue(response.text.contains("revised paragraph"))
        XCTAssertEqual(response.model, "mlx-community--Qwen3.5-4B-4bit")
        XCTAssertEqual(response.usage?.totalTokens, 43)
        XCTAssertEqual(response.finishReason, .stop)
    }

    func testToolDefinitionsAndToolCallsRoundTrip() async throws {
        let bridge = FakeAIBridge(descriptors: [FakeCatalogue.omlx])
        await bridge.setCompleteHandler { request in
            XCTAssertEqual(request.tools.count, 1)
            XCTAssertEqual(request.tools[0].name, "curate_publication")
            XCTAssertTrue(request.tools[0].inputSchemaJSON.contains("\"type\":\"object\""))
            return AIBridgeChatResponse(
                id: "curation-1",
                target: AIResolvedTarget(providerId: "omlx", modelId: "curator-model", endpointId: "local-omlx", origin: "explicit"),
                content: [.toolUse(id: "call-1", name: "curate_publication", inputJSON: "{\"tags\":[\"primordial-chemistry\",\"reaction-network\"],\"keep\":true}")],
                finishReason: .toolUse
            )
        }
        let provider = makeProvider(bridge: bridge)
        let response = try await provider.complete(AICompletionRequest(
            modelId: "curator-model",
            messages: [AIMessage(role: .user, text: "Curate this publication for the chemistry manuscript.")],
            tools: [AITool(
                name: "curate_publication",
                description: "Assign tags and decide whether to keep a publication",
                inputSchema: ["type": AnySendable("object")]
            )]
        ))
        XCTAssertEqual(response.finishReason, .toolUse)
        guard case .toolUse(let call) = try XCTUnwrap(response.content.first) else {
            return XCTFail("Expected a parsed tool call")
        }
        XCTAssertEqual(call.name, "curate_publication")
        XCTAssertEqual(call.input["keep"]?.get() as Bool?, true)
        XCTAssertEqual(call.input["tags"]?.get() as [AnySendable]?, [AnySendable("primordial-chemistry"), AnySendable("reaction-network")])

        // Tool results and prior tool uses travel back to Rust in the
        // transcript shape it expects.
        let followUp = AICompletionRequest(
            messages: [
                AIMessage(role: .assistant, content: [.toolUse(call)]),
                AIMessage(role: .tool, content: [.toolResult(AIToolResult(toolUseId: "call-1", content: "{\"ok\":true}"))]),
            ]
        )
        let bridged = AIBridgeMapping.bridgeRequest(followUp)
        XCTAssertEqual(bridged.messages[0].role, .assistant)
        guard case .toolUse(let id, let name, let inputJSON) = bridged.messages[0].content[0] else {
            return XCTFail("Expected a tool use part")
        }
        XCTAssertEqual(id, "call-1")
        XCTAssertEqual(name, "curate_publication")
        XCTAssertTrue(inputJSON.contains("\"keep\":true"))
        XCTAssertEqual(bridged.messages[1].content, [.toolResult(toolUseId: "call-1", content: "{\"ok\":true}", isError: false)])
    }

    // MARK: - Streaming

    func testStreamFoldsTokensReasoningUsageAndDone() async throws {
        let bridge = FakeAIBridge(descriptors: [FakeCatalogue.omlx])
        await bridge.setStreamEvents([
            .started(AIResolvedTarget(providerId: "omlx", modelId: "m", endpointId: "local-omlx", origin: "selected")),
            .reasoning("think"),
            .text("Hel"),
            .text("lo"),
            .usage(AIUsage(inputTokens: 3, outputTokens: 2)),
            .done(finishReason: .stop),
        ])
        let provider = makeProvider(bridge: bridge)
        var text = ""
        var reasoning = ""
        var finish: AIFinishReason?
        var usage: AIUsage?
        for try await chunk in try await provider.stream(AICompletionRequest(messages: [AIMessage(role: .user, text: "hi")])) {
            text += chunk.text
            reasoning += chunk.reasoning ?? ""
            if let reason = chunk.finishReason { finish = reason }
            if let chunkUsage = chunk.usage { usage = chunkUsage }
        }
        XCTAssertEqual(text, "Hello")
        XCTAssertEqual(reasoning, "think")
        XCTAssertEqual(finish, .stop)
        XCTAssertEqual(usage?.totalTokens, 5)
    }

    func testStreamAccumulatesToolCallDeltasIntoOneToolUse() async throws {
        let bridge = FakeAIBridge(descriptors: [FakeCatalogue.omlx])
        await bridge.setStreamEvents([
            .toolCallDelta(index: 0, id: "call-1", name: "scix", arguments: "{\"query\":"),
            .toolCallDelta(index: 0, id: nil, name: nil, arguments: "\"stars\"}"),
            .done(finishReason: nil),
        ])
        let provider = makeProvider(bridge: bridge)
        var uses: [AIToolUse] = []
        var finish: AIFinishReason?
        for try await chunk in try await provider.stream(AICompletionRequest(messages: [AIMessage(role: .user, text: "find")])) {
            for content in chunk.content {
                if case .toolUse(let use) = content { uses.append(use) }
            }
            if let reason = chunk.finishReason { finish = reason }
        }
        XCTAssertEqual(uses.count, 1)
        XCTAssertEqual(uses[0].id, "call-1")
        XCTAssertEqual(uses[0].name, "scix")
        XCTAssertEqual(uses[0].input["query"]?.get() as String?, "stars")
        XCTAssertEqual(finish, .toolUse)
    }

    func testStreamFailureSurfacesAsAIError() async throws {
        let bridge = FakeAIBridge(descriptors: [FakeCatalogue.omlx])
        await bridge.setStreamEvents([
            .text("partial"),
            .failed(AIBridgeError(kind: .provider(status: 500), providerId: "omlx", message: "context length exceeded")),
        ])
        let provider = makeProvider(bridge: bridge)
        do {
            for try await _ in try await provider.stream(AICompletionRequest(messages: [AIMessage(role: .user, text: "hi")])) {}
            XCTFail("Expected the stream to throw")
        } catch let error as AIError {
            guard case .apiError(let status, let message) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(status, 500)
            XCTAssertEqual(message, "context length exceeded")
        }
    }

    // MARK: - Discovery and validation

    func testDiscoveryHidesHelpersUnlessAskedAndCarriesHostDetail() async throws {
        let bridge = FakeAIBridge(descriptors: [FakeCatalogue.omlx])
        await bridge.setModels(FakeCatalogue.omlxModels, for: "omlx")
        let provider = makeProvider(bridge: bridge)

        let models = try await provider.discoverModels()
        XCTAssertEqual(models.map(\.id), ["mlx-community--Qwen3.5-4B-4bit", "mlx-community--Llama-3.2-3B-Instruct-bf16"])
        XCTAssertEqual(models[0].name, "Qwen3.5 4B 4bit")
        XCTAssertEqual(models[0].isLoaded, true)
        XCTAssertTrue(models[0].isServerDefault)
        XCTAssertTrue(models[0].isDefault)
        XCTAssertEqual(models[0].contextWindow, 262_144)
        XCTAssertTrue(models[0].capabilities?.contains(.vision) == true)
        XCTAssertEqual(models[0].kind, "vlm")

        let all = try await provider.discoverModels(forceRefresh: false, includeHelpers: true)
        XCTAssertEqual(all.count, 3)
        XCTAssertTrue(all[2].isHelper)
        let calls = await bridge.discoverCalls
        XCTAssertEqual(calls, 1, "the second call is served from the cache")
    }

    func testValidateIsPassiveAndNeverLaunchesTheHost() async throws {
        let bridge = FakeAIBridge(descriptors: [FakeCatalogue.omlx])
        await bridge.setHealth(FakeCatalogue.omlxDown, for: "omlx")
        let launcher = FakeHostLauncher()
        let provider = makeProvider(bridge: bridge, launcher: launcher)

        let status = try await provider.validate()
        XCTAssertFalse(status.isReady)
        let launches = await launcher.launchCount()
        XCTAssertEqual(launches, 0)
        let ensures = await bridge.ensureCalls
        XCTAssertEqual(ensures, 0)

        await bridge.setHealth(FakeCatalogue.omlxReady, for: "omlx")
        let ready = try await provider.health(forceRefresh: true)
        XCTAssertEqual(ready.serverVersion, "0.6.4")
        XCTAssertEqual(ready.loadedModelCount, 1)
        let readyStatus = try await provider.validate()
        XCTAssertEqual(readyStatus, .ready)
    }

    // MARK: - Host launch

    func testCompletionLaunchesTheHostOnceWhenRustAsksAndRetries() async throws {
        let bridge = FakeAIBridge(descriptors: [FakeCatalogue.omlx])
        let attempts = Counter()
        await bridge.setCompleteHandler { request in
            let attempt = attempts.increment()
            if attempt == 1 {
                throw AIBridgeError(kind: .hostLaunchRequired, providerId: "omlx", message: "app.omlx must be launched", bundleId: "app.omlx")
            }
            return AIBridgeChatResponse(
                id: "retry-response",
                target: AIResolvedTarget(providerId: "omlx", modelId: "local-model", endpointId: "local-omlx", origin: "explicit"),
                content: [.text("ready after launch")],
                finishReason: .stop
            )
        }
        await bridge.setEnsureScript([.success(FakeCatalogue.omlxReady)])
        let launcher = FakeHostLauncher()
        let provider = makeProvider(bridge: bridge, launcher: launcher)

        let response = try await provider.complete(AICompletionRequest(
            modelId: "local-model",
            messages: [AIMessage(role: .user, text: "Hello")]
        ))
        XCTAssertEqual(response.text, "ready after launch")
        XCTAssertEqual(attempts.value, 2)
        let launched = await launcher.launches
        XCTAssertEqual(launched, ["app.omlx"])
        let ensures = await bridge.ensureCalls
        XCTAssertEqual(ensures, 1)
    }

    func testPlainUnreachableNeverLaunchesAnything() async throws {
        let bridge = FakeAIBridge(descriptors: [FakeCatalogue.omlx])
        await bridge.setCompleteHandler { _ in
            throw AIBridgeError(kind: .unreachable, providerId: "omlx", message: "connection refused")
        }
        let launcher = FakeHostLauncher()
        let provider = makeProvider(bridge: bridge, launcher: launcher)
        do {
            _ = try await provider.complete(AICompletionRequest(
                modelId: "other-runtime-model",
                messages: [AIMessage(role: .user, text: "Hello")]
            ))
            XCTFail("Expected the unreachable host to fail")
        } catch let error as AIError {
            guard case .networkError = error else { return XCTFail("\(error)") }
        }
        let launches = await launcher.launchCount()
        XCTAssertEqual(launches, 0)
    }

    func testActivateServiceLaunchesOnlyForAutoStartProviders() async throws {
        let bridge = FakeAIBridge(descriptors: [FakeCatalogue.omlx, FakeCatalogue.anthropic])
        await bridge.setEnsureScript([
            .failure(AIBridgeError(kind: .hostLaunchRequired, providerId: "omlx", message: "launch", bundleId: "app.omlx")),
            .success(FakeCatalogue.omlxReady),
        ])
        let launcher = FakeHostLauncher()
        let omlx = makeProvider(bridge: bridge, launcher: launcher)
        try await omlx.activateServiceIfNeeded()
        let launched = await launcher.launches
        XCTAssertEqual(launched, ["app.omlx"])

        let anthropic = makeProvider(descriptor: FakeCatalogue.anthropic, bridge: bridge, launcher: launcher)
        try await anthropic.activateServiceIfNeeded()
        let ensures = await bridge.ensureCalls
        XCTAssertEqual(ensures, 2, "cloud providers never consult the oMLX starter")
    }
}

/// Thread-safe counter for scripted handlers.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
