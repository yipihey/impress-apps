import Foundation
@testable import ImpressAI

/// A scripted `AIBridge` for tests: no Rust, no network. It keeps
/// preferences in memory and applies the same resolution rule Rust does
/// (explicit > category > selected > first ready), so manager-level tests
/// exercise realistic behaviour.
actor FakeAIBridge: AIBridge {
    var descriptors: [AIProviderDescriptor]
    var modelsByProvider: [String: [AIDiscoveredModel]] = [:]
    var healthByProvider: [String: AIProviderHealth] = [:]
    var categories: [AITaskCategory] = AITaskCategory.all
    var stored = AIPreferences(path: "/tmp/fake/ai/preferences.json")
    var foreignAvailability: [String: Bool] = [:]
    var configuredCredentials: [String: [String: String]] = [:]

    /// Scripted answers.
    var completeHandler: (@Sendable (AIBridgeChatRequest) throws -> AIBridgeChatResponse)?
    var streamEvents: [AIBridgeStreamEvent] = []
    var ensureScript: [Result<AIProviderHealth, AIBridgeError>] = []
    var discoverError: AIBridgeError?
    var healthError: AIBridgeError?

    /// Recorded traffic.
    private(set) var completeRequests: [AIBridgeChatRequest] = []
    private(set) var streamRequests: [AIBridgeChatRequest] = []
    private(set) var ensureCalls = 0
    private(set) var discoverCalls = 0
    private(set) var healthCalls = 0

    init(descriptors: [AIProviderDescriptor]) {
        self.descriptors = descriptors
    }

    // MARK: - Scripting helpers

    func setModels(_ models: [AIDiscoveredModel], for providerId: String) {
        modelsByProvider[providerId] = models
    }

    func setHealth(_ health: AIProviderHealth, for providerId: String) {
        healthByProvider[providerId] = health
    }

    func setCompleteHandler(_ handler: @escaping @Sendable (AIBridgeChatRequest) throws -> AIBridgeChatResponse) {
        completeHandler = handler
    }

    func setStreamEvents(_ events: [AIBridgeStreamEvent]) {
        streamEvents = events
    }

    func setEnsureScript(_ script: [Result<AIProviderHealth, AIBridgeError>]) {
        ensureScript = script
    }

    func setDiscoverError(_ error: AIBridgeError?) {
        discoverError = error
    }

    func setHealthError(_ error: AIBridgeError?) {
        healthError = error
    }

    func setStored(_ preferences: AIPreferences) {
        stored = preferences
    }

    // MARK: - AIBridge

    func listProviders() async throws -> [AIProviderDescriptor] {
        descriptors
    }

    func listTaskCategories(app: String?) async throws -> [AITaskCategory] {
        guard let app else { return categories }
        return categories.filter { $0.supportedApps.contains(app) }
    }

    func configureCredentials(providerId: String, fields: [String: String]) async throws {
        configuredCredentials[providerId] = fields.filter { !$0.value.isEmpty }
    }

    func clearCredentials(providerId: String) async throws {
        configuredCredentials[providerId] = nil
    }

    func setForeignProviderAvailable(providerId: String, available: Bool) async throws {
        foreignAvailability[providerId] = available
    }

    func preferences() async throws -> AIPreferences {
        stored
    }

    func preferencesChangedSince(updatedAtMs: Int64) async throws -> Bool {
        stored.updatedAtMs > updatedAtMs
    }

    func selectModel(providerId: String, modelId: String?) async throws -> AIPreferences {
        guard descriptors.contains(where: { $0.id == providerId }) else {
            throw AIBridgeError(kind: .invalid, message: "unknown AI provider '\(providerId)'")
        }
        if let modelId, modelsByProvider[providerId]?.first(where: { $0.id == modelId })?.isHelper == true
            || modelId.lowercased() == "markitdown" {
            throw AIBridgeError(kind: .invalid, message: "\(modelId) is a helper model and cannot be selected for chat")
        }
        let displayName = modelsByProvider[providerId]?.first { $0.id == modelId }?.displayName
        return update { $0 = $0.with(selected: AIModelSelection(providerId: providerId, modelId: modelId, displayName: displayName)) }
    }

    func clearSelection() async throws -> AIPreferences {
        update { $0 = $0.with(selected: nil, clearSelection: true) }
    }

    func setProviderEndpoint(providerId: String, endpoint: String?) async throws -> AIPreferences {
        update {
            var endpoints = $0.endpoints
            endpoints[providerId] = endpoint
            $0 = $0.with(endpoints: endpoints)
        }
    }

    func setAutoStartOMLX(_ enabled: Bool) async throws -> AIPreferences {
        update { $0 = $0.with(autoStartOMLX: enabled) }
    }

    func setTaskCategory(_ categoryId: String, assignment: AITaskCategoryAssignment) async throws -> AIPreferences {
        update {
            var assignments = $0.taskAssignments
            assignments[categoryId] = assignment
            $0 = $0.with(taskAssignments: assignments)
        }
    }

    func importLegacyPreferences(_ legacy: AILegacyPreferences) async throws -> AIPreferences {
        update {
            var preferences = $0
            if preferences.selected == nil, let providerId = legacy.selectedProviderId {
                let mapped = providerId == "openai-compatible" ? "omlx" : providerId
                let model = legacy.selectedModelId?.lowercased() == "markitdown" ? nil : legacy.selectedModelId
                preferences = preferences.with(selected: AIModelSelection(providerId: mapped, modelId: model))
            }
            if let auto = legacy.autoStartOMLX {
                preferences = preferences.with(autoStartOMLX: auto)
            }
            $0 = preferences.with(migratedFromSharedDefaults: true)
        }
    }

    func resolveTarget(providerId: String?, modelId: String?, category: String?) async throws -> AIResolvedTarget {
        let categoryPrimary = category.flatMap { stored.taskAssignments[$0] }
            .flatMap { $0.isEnabled ? $0.primaryModel : nil }
        let provider: String
        let origin: String
        if let providerId {
            provider = providerId
            origin = "explicit"
        } else if let categoryPrimary {
            provider = categoryPrimary.providerId
            origin = "category"
        } else if let selected = stored.selected {
            provider = selected.providerId
            origin = "selected"
        } else if let first = descriptors.first(where: { isReady($0) }) {
            provider = first.id
            origin = "first_ready"
        } else {
            throw AIBridgeError(kind: .notConfigured, providerId: "ai", message: "no AI provider is configured or reachable")
        }
        guard let descriptor = descriptors.first(where: { $0.id == provider }) else {
            throw AIBridgeError(kind: .invalid, message: "unknown AI provider '\(provider)'")
        }
        let selectedModel = stored.selected?.providerId == provider ? stored.selected?.modelId : nil
        let categoryModel = categoryPrimary?.providerId == provider ? categoryPrimary?.modelId : nil
        let defaultModel = descriptor.staticModels.first { $0.isDefault }?.id
            ?? modelsByProvider[provider]?.first { $0.isServerDefault && !$0.isHelper }?.id
            ?? modelsByProvider[provider]?.first { !$0.isHelper }?.id
        guard let model = modelId ?? selectedModel ?? categoryModel ?? defaultModel else {
            throw AIBridgeError(kind: .invalid, message: "choose a model for \(provider)")
        }
        return AIResolvedTarget(providerId: provider, modelId: model, endpointId: "\(provider)-default", origin: origin)
    }

    func discoverModels(providerId: String?) async throws -> [AIDiscoveredModel] {
        discoverCalls += 1
        if let discoverError { throw discoverError }
        let provider: String
        if let providerId {
            provider = providerId
        } else {
            provider = try await resolveTarget(providerId: nil, modelId: nil, category: nil).providerId
        }
        if let descriptor = descriptors.first(where: { $0.id == provider }), !descriptor.hasDynamicCatalogue {
            return descriptor.staticModels.map { AIDiscoveredModel(id: $0.id, displayName: $0.name, kind: .llm, isServerDefault: $0.isDefault, source: "catalogue") }
        }
        return modelsByProvider[provider] ?? []
    }

    func providerHealth(providerId: String) async throws -> AIProviderHealth {
        healthCalls += 1
        if let healthError { throw healthError }
        if let health = healthByProvider[providerId] { return health }
        guard let descriptor = descriptors.first(where: { $0.id == providerId }) else {
            return AIProviderHealth(providerId: providerId, state: .unreachable, detail: "unknown provider")
        }
        return AIProviderHealth(providerId: providerId, state: descriptor.readiness, detail: descriptor.readiness.rawValue)
    }

    func ensureOMLXRunning(timeout: TimeInterval) async throws -> AIProviderHealth {
        ensureCalls += 1
        guard !ensureScript.isEmpty else {
            return try await providerHealth(providerId: "omlx")
        }
        switch ensureScript.removeFirst() {
        case .success(let health):
            healthByProvider["omlx"] = health
            return health
        case .failure(let error):
            throw error
        }
    }

    func complete(_ request: AIBridgeChatRequest) async throws -> AIBridgeChatResponse {
        completeRequests.append(request)
        guard let completeHandler else {
            let target = try await resolveTarget(providerId: request.providerId, modelId: request.modelId, category: request.taskCategory)
            return AIBridgeChatResponse(id: "fake-\(completeRequests.count)", target: target, content: [.text("fake answer")], finishReason: .stop)
        }
        return try completeHandler(request)
    }

    func stream(_ request: AIBridgeChatRequest) async throws -> AsyncThrowingStream<AIBridgeStreamEvent, Error> {
        streamRequests.append(request)
        let events = streamEvents
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    // MARK: - Private

    private func isReady(_ descriptor: AIProviderDescriptor) -> Bool {
        if descriptor.isHostExecuted { return foreignAvailability[descriptor.id] ?? false }
        if let health = healthByProvider[descriptor.id] { return health.isReady }
        return descriptor.readiness.isReady
    }

    private func update(_ mutate: (inout AIPreferences) -> Void) -> AIPreferences {
        var preferences = stored
        mutate(&preferences)
        stored = preferences.with(updatedAtMs: stored.updatedAtMs + 1)
        return stored
    }
}

extension AIPreferences {
    /// Copy-with, since the bridge type is immutable by design.
    func with(
        selected: AIModelSelection?? = nil,
        clearSelection: Bool = false,
        endpoints: [String: String]? = nil,
        autoStartOMLX: Bool? = nil,
        taskAssignments: [String: AITaskCategoryAssignment]? = nil,
        updatedAtMs: Int64? = nil,
        migratedFromSharedDefaults: Bool? = nil
    ) -> AIPreferences {
        AIPreferences(
            version: version,
            selected: clearSelection ? nil : (selected ?? self.selected),
            endpoints: endpoints ?? self.endpoints,
            autoStartOMLX: autoStartOMLX ?? self.autoStartOMLX,
            taskAssignments: taskAssignments ?? self.taskAssignments,
            updatedAtMs: updatedAtMs ?? self.updatedAtMs,
            path: path,
            migratedFromSharedDefaults: migratedFromSharedDefaults ?? self.migratedFromSharedDefaults
        )
    }
}

/// Counts launches without launching anything.
actor FakeHostLauncher: AIHostLaunching {
    private(set) var launches: [String] = []

    func launchApplication(bundleId: String) async throws {
        launches.append(bundleId)
    }

    func launchCount() -> Int { launches.count }
}

enum FakeCatalogue {
    static let omlx = AIProviderDescriptor(
        id: "omlx",
        name: "oMLX — local models on this Mac",
        description: "MLX models served by oMLX",
        category: .local,
        credentialFields: [AICredentialField(id: "apiKey", label: "Bearer token", isSecret: true, isOptional: true)],
        capabilities: [.streaming, .tools, .vision, .jsonMode, .thinking, .systemPrompt],
        hasDynamicCatalogue: true,
        defaultEndpoint: "http://127.0.0.1:8000",
        endpoint: "http://127.0.0.1:8000",
        endpointEditable: true,
        canAutoStart: true,
        iconName: "cpu",
        readiness: .unreachable
    )

    static let apple = AIProviderDescriptor(
        id: "apple-on-device",
        name: "Apple Intelligence (on-device)",
        category: .local,
        isHostExecuted: true,
        staticModels: [AIModel(id: "apple-on-device", name: "Apple Intelligence", isDefault: true)],
        iconName: "apple.logo",
        readiness: .foreignUnavailable
    )

    static let anthropic = AIProviderDescriptor(
        id: "anthropic",
        name: "Claude (Anthropic)",
        category: .cloud,
        credentialFields: [AICredentialField(id: "apiKey", label: "API Key", isSecret: true)],
        capabilities: .full,
        hasDynamicCatalogue: true,
        staticModels: [
            AIModel(id: "claude-opus-5", name: "Claude Opus 5", isDefault: true),
            AIModel(id: "claude-sonnet-5", name: "Claude Sonnet 5"),
        ],
        defaultEndpoint: "https://api.anthropic.com",
        endpoint: "https://api.anthropic.com",
        endpointEditable: true,
        registrationURL: URL(string: "https://console.anthropic.com/account/keys"),
        iconName: "brain.head.profile",
        readiness: .needsCredentials
    )

    static let omlxModels: [AIDiscoveredModel] = [
        AIDiscoveredModel(id: "mlx-community--Qwen3.5-4B-4bit", displayName: "Qwen3.5 4B 4bit", kind: .vlm, isLoaded: true, contextWindow: 262_144, maxOutputTokens: 4096, supportsVision: true, supportsTools: true, supportsJSONSchema: true, isServerDefault: true, sourceRepo: "mlx-community/Qwen3.5-4B-4bit"),
        AIDiscoveredModel(id: "mlx-community--Llama-3.2-3B-Instruct-bf16", displayName: "Llama 3.2 3B Instruct bf16", kind: .llm, contextWindow: 131_072, maxOutputTokens: 4096),
        AIDiscoveredModel(id: "MarkItDown", displayName: "MarkItDown", kind: .helper, isLoaded: true, isHelper: true),
    ]

    static let omlxReady = AIProviderHealth(providerId: "omlx", state: .ready, endpoint: "http://127.0.0.1:8000", defaultModelId: "mlx-community--Qwen3.5-4B-4bit", modelCount: 2, loadedModelCount: 1, serverVersion: "0.6.4", memoryInUseBytes: 30_976_279_402, memoryCeilingBytes: 112_742_891_520, detail: "oMLX 0.6.4 · 1 of 2 loaded")

    static let omlxDown = AIProviderHealth(providerId: "omlx", state: .unreachable, endpoint: "http://127.0.0.1:8000", detail: "omlx is unreachable: connection refused")
}
