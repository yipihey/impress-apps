import Foundation
import ImpressKit
import ImpressLogging

// `IMPRESS_RUST_AI` is defined by `Package.swift` once `ImpressRustCore` is a
// declared dependency (not merely reachable through the app's package graph):
// `canImport` would flip on inside an app build the moment any sibling links
// the framework, and then fail against bindings that predate the registry.
#if IMPRESS_RUST_AI
import ImpressRustCore

/// The production `AIBridge`: a thin adapter over the UniFFI
/// `SharedAiRegistry` from `crates/impress-store-ffi`.
///
/// Every synchronous registry call runs on a private queue — never on the
/// main thread and never on Swift's cooperative pool, because Rust drives
/// those calls to completion on its own runtime. Streaming pulls events
/// with the registry's async `nextEvent()`, so no thread is parked per
/// stream. Conversion to ImpressAI-owned values happens inside the call:
/// UniFFI records never cross into the rest of the package.
public final class RustAIBridge: AIBridge, @unchecked Sendable {
    public static let shared = RustAIBridge(workspaceDirectory: SharedWorkspace.workspaceDirectory)

    private let workspaceDirectory: URL
    private let queue = DispatchQueue(label: "com.impress.ai.ffi", qos: .userInitiated, attributes: .concurrent)
    private let lock = NSLock()
    private var registry: SharedAiRegistry?
    private var openError: Error?

    public init(workspaceDirectory: URL) {
        self.workspaceDirectory = workspaceDirectory
    }

    // MARK: - Registry access

    private func openRegistry() throws -> SharedAiRegistry {
        lock.lock()
        defer { lock.unlock() }
        if let registry { return registry }
        if let openError { throw openError }
        do {
            try SharedWorkspace.ensureDirectoryExists()
            let opened = try SharedAiRegistry.open(workspacePath: workspaceDirectory.path)
            registry = opened
            logInfo("AI registry opened at \(workspaceDirectory.path)/ai", category: "ai.bridge")
            return opened
        } catch {
            openError = error
            logError("AI registry could not be opened: \(error.localizedDescription)", category: "ai.bridge")
            throw Self.convert(error)
        }
    }

    /// Run a synchronous registry call off the caller's thread.
    private func onQueue<T: Sendable>(_ body: @escaping @Sendable (SharedAiRegistry) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let registry = try self.openRegistry()
                    continuation.resume(returning: try body(registry))
                } catch {
                    continuation.resume(throwing: Self.convert(error))
                }
            }
        }
    }

    // MARK: - AIBridge

    public func listProviders() async throws -> [AIProviderDescriptor] {
        try await onQueue { registry in registry.listProviders().map(Self.descriptor) }
    }

    public func listTaskCategories(app: String?) async throws -> [AITaskCategory] {
        try await onQueue { registry in
            registry.listTaskCategories(app: app).map { info in
                AITaskCategory(
                    id: info.id,
                    name: info.name,
                    icon: info.icon,
                    description: info.description,
                    parentId: info.parentId,
                    supportedApps: Set(info.apps),
                    supportsComparison: info.supportsComparison
                )
            }
        }
    }

    public func configureCredentials(providerId: String, fields: [String: String]) async throws {
        try await onQueue { registry in registry.configureCredentials(provider: providerId, fields: fields) }
    }

    public func clearCredentials(providerId: String) async throws {
        try await onQueue { registry in registry.clearCredentials(provider: providerId) }
    }

    public func setForeignProviderAvailable(providerId: String, available: Bool) async throws {
        try await onQueue { registry in registry.setForeignProviderAvailable(provider: providerId, available: available) }
    }

    public func preferences() async throws -> AIPreferences {
        try await onQueue { registry in Self.preferences(try registry.preferences()) }
    }

    public func preferencesChangedSince(updatedAtMs: Int64) async throws -> Bool {
        try await onQueue { registry in registry.preferencesChangedSince(updatedAtMs: updatedAtMs) }
    }

    public func selectModel(providerId: String, modelId: String?) async throws -> AIPreferences {
        try await onQueue { registry in Self.preferences(try registry.selectModel(provider: providerId, model: modelId)) }
    }

    public func clearSelection() async throws -> AIPreferences {
        try await onQueue { registry in Self.preferences(try registry.clearSelection()) }
    }

    public func setProviderEndpoint(providerId: String, endpoint: String?) async throws -> AIPreferences {
        try await onQueue { registry in Self.preferences(try registry.setProviderEndpoint(provider: providerId, endpoint: endpoint)) }
    }

    public func setAutoStartOMLX(_ enabled: Bool) async throws -> AIPreferences {
        try await onQueue { registry in Self.preferences(try registry.setAutoStartOmlx(enabled: enabled)) }
    }

    public func setTaskCategory(_ categoryId: String, assignment: AITaskCategoryAssignment) async throws -> AIPreferences {
        try await onQueue { registry in
            Self.preferences(try registry.setTaskCategory(category: categoryId, assignment: Self.assignment(assignment)))
        }
    }

    public func importLegacyPreferences(_ legacy: AILegacyPreferences) async throws -> AIPreferences {
        try await onQueue { registry in
            let result = try registry.importLegacyPreferences(legacy: AiLegacyPreferences(
                selectedProvider: legacy.selectedProviderId,
                selectedModel: legacy.selectedModelId,
                autoStartOmlx: legacy.autoStartOMLX,
                taskCategoryAssignmentsJson: legacy.taskCategoryAssignmentsJSON,
                endpoints: legacy.endpoints
            ))
            logInfo("Migration: \(result.summary)", category: "ai.migration")
            return Self.preferences(result.preferences)
        }
    }

    public func resolveTarget(providerId: String?, modelId: String?, category: String?) async throws -> AIResolvedTarget {
        try await onQueue { registry in
            Self.target(try registry.resolveTarget(provider: providerId, model: modelId, category: category))
        }
    }

    public func discoverModels(providerId: String?) async throws -> [AIDiscoveredModel] {
        try await onQueue { registry in try registry.discoverModels(provider: providerId).map(Self.model) }
    }

    public func providerHealth(providerId: String) async throws -> AIProviderHealth {
        try await onQueue { registry in Self.health(registry.providerHealth(provider: providerId)) }
    }

    public func ensureOMLXRunning(timeout: TimeInterval) async throws -> AIProviderHealth {
        try await onQueue { registry in
            Self.health(try registry.ensureOmlxRunning(timeoutSecs: UInt32(max(1, timeout.rounded()))))
        }
    }

    public func complete(_ request: AIBridgeChatRequest) async throws -> AIBridgeChatResponse {
        let ffiRequest = Self.request(request)
        return try await onQueue { registry in Self.response(try registry.chatComplete(request: ffiRequest)) }
    }

    public func stream(_ request: AIBridgeChatRequest) async throws -> AsyncThrowingStream<AIBridgeStreamEvent, Error> {
        let ffiRequest = Self.request(request)
        let stream: AiChatStream = try await onQueue { registry in try registry.chatStream(request: ffiRequest) }
        return AsyncThrowingStream { continuation in
            let task = Task {
                while let event = await stream.nextEvent() {
                    if Task.isCancelled { break }
                    continuation.yield(Self.event(event))
                    if case .failed = event { break }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
                stream.cancel()
            }
        }
    }

    // MARK: - Conversions (UniFFI → ImpressAI)

    static func convert(_ error: Error) -> Error {
        guard let ffi = error as? AiError else { return error }
        switch ffi {
        case .NotConfigured(let message):
            return AIBridgeError(kind: .notConfigured, message: message)
        case .Unauthorized(let provider, let message):
            return AIBridgeError(kind: .unauthorized, providerId: provider, message: message)
        case .Unreachable(let provider, let message):
            return AIBridgeError(kind: .unreachable, providerId: provider, message: message)
        case .RateLimited(let provider, let retryAfterSecs):
            return AIBridgeError(kind: .rateLimited, providerId: provider, message: "\(provider) is rate limited", retryAfter: retryAfterSecs.map { TimeInterval($0) })
        case .Provider(let provider, let status, let message):
            return AIBridgeError(kind: .provider(status: status.map(Int.init)), providerId: provider, message: message)
        case .Invalid(let message):
            return AIBridgeError(kind: .invalid, message: message)
        case .ForeignExecutor(let provider):
            return AIBridgeError(kind: .foreignExecutor, providerId: provider, message: "\(provider) is executed by the host application")
        case .HostLaunchRequired(let bundleId):
            return AIBridgeError(kind: .hostLaunchRequired, message: "\(bundleId) must be launched first", bundleId: bundleId)
        case .Cancelled:
            return AIBridgeError(kind: .cancelled, message: "cancelled")
        case .Storage(let message):
            return AIBridgeError(kind: .storage, message: message)
        }
    }

    static func descriptor(_ info: AiProviderInfo) -> AIProviderDescriptor {
        AIProviderDescriptor(
            id: info.id,
            name: info.displayName,
            description: info.description.isEmpty ? nil : info.description,
            category: category(info.category),
            isHostExecuted: info.host == "foreign",
            credentialFields: info.credentialFields.map { field in
                AICredentialField(id: field.id, label: field.label, placeholder: field.placeholder, isSecret: field.secret, isOptional: field.optional)
            },
            configuredCredentialFields: Set(info.credentialFields.filter(\.configured).map(\.id)),
            capabilities: capabilities(info.capabilities),
            hasDynamicCatalogue: info.hasDynamicCatalogue,
            staticModels: info.staticModels.map { model($0).model },
            defaultEndpoint: info.defaultEndpoint,
            endpoint: info.endpoint,
            endpointEditable: info.endpointEditable,
            canAutoStart: info.canAutoStart,
            registrationURL: info.registrationUrl.flatMap(URL.init(string:)),
            iconName: info.icon.isEmpty ? nil : info.icon,
            readiness: AIProviderReadiness(rawValue: info.readiness) ?? .unreachable
        )
    }

    static func category(_ label: String) -> AIProviderCategory {
        switch label {
        case "cloud": return .cloud
        case "aggregator": return .aggregator
        default: return .local
        }
    }

    static func capabilities(_ caps: AiCapabilities) -> AICapabilities {
        var result: AICapabilities = []
        if caps.streaming { result.insert(.streaming) }
        if caps.tools { result.insert(.tools) }
        if caps.vision { result.insert(.vision) }
        if caps.jsonSchema { result.insert(.jsonMode) }
        if caps.thinking { result.insert(.thinking) }
        if caps.embeddings { result.insert(.embeddings) }
        if caps.systemPrompt { result.insert(.systemPrompt) }
        return result
    }

    static func model(_ info: AiModelInfo) -> AIDiscoveredModel {
        AIDiscoveredModel(
            id: info.id,
            displayName: info.displayName,
            kind: AIModelKind(rawValue: info.kind) ?? .unknown,
            isLoaded: info.loaded,
            isLoading: info.isLoading,
            contextWindow: info.maxContextWindow.map { Int(clamping: $0) },
            maxOutputTokens: info.maxOutputTokens.map { Int(clamping: $0) },
            supportsVision: info.vision,
            supportsTools: info.tools,
            supportsThinking: info.thinking,
            supportsJSONSchema: info.jsonSchema,
            isServerDefault: info.isDefault,
            isHelper: info.isHelper,
            source: info.source,
            sourceRepo: info.sourceRepo
        )
    }

    static func health(_ record: AiProviderHealth) -> AIProviderHealth {
        AIProviderHealth(
            providerId: record.provider,
            state: AIProviderReadiness(rawValue: record.state) ?? .unreachable,
            endpoint: record.endpoint,
            checkedAt: Date(timeIntervalSince1970: TimeInterval(record.checkedAtMs) / 1000),
            defaultModelId: record.defaultModel,
            modelCount: Int(record.modelCount),
            loadedModelCount: record.loadedCount.map(Int.init),
            serverVersion: record.serverVersion,
            memoryInUseBytes: record.memoryInUseBytes.map { Int64(clamping: $0) },
            memoryCeilingBytes: record.memoryCeilingBytes.map { Int64(clamping: $0) },
            detail: record.detail
        )
    }

    static func preferences(_ record: AiPreferencesRecord) -> AIPreferences {
        var assignments: [String: AITaskCategoryAssignment] = [:]
        for entry in record.taskCategories {
            assignments[entry.category] = AITaskCategoryAssignment(
                categoryId: entry.category,
                primaryModel: entry.assignment.primary.map(reference),
                comparisonModels: entry.assignment.comparison.map(reference),
                isEnabled: entry.assignment.enabled
            )
        }
        return AIPreferences(
            version: Int(record.version),
            selected: record.selected.map { AIModelSelection(providerId: $0.provider, modelId: $0.model, displayName: $0.displayName) },
            endpoints: record.endpoints,
            autoStartOMLX: record.autoStartOmlx,
            taskAssignments: assignments,
            updatedAtMs: record.updatedAtMs,
            path: record.path,
            migratedFromSharedDefaults: record.migratedFromSharedDefaults
        )
    }

    static func reference(_ ref: AiModelRef) -> AIModelReference {
        AIModelReference(providerId: ref.provider, modelId: ref.model ?? "", displayName: ref.displayName ?? (ref.model ?? ref.provider))
    }

    static func assignment(_ assignment: AITaskCategoryAssignment) -> AiCategoryAssignment {
        AiCategoryAssignment(
            primary: assignment.primaryModel.map(modelRef),
            comparison: assignment.comparisonModels.map(modelRef),
            enabled: assignment.isEnabled
        )
    }

    static func modelRef(_ reference: AIModelReference) -> AiModelRef {
        AiModelRef(provider: reference.providerId, model: reference.modelId.isEmpty ? nil : reference.modelId, displayName: reference.displayName)
    }

    static func target(_ target: AiResolvedTarget) -> AIResolvedTarget {
        AIResolvedTarget(providerId: target.provider, modelId: target.model, endpointId: target.endpointId, origin: target.origin)
    }

    static func request(_ request: AIBridgeChatRequest) -> AiChatRequest {
        AiChatRequest(
            provider: request.providerId,
            model: request.modelId,
            taskCategory: request.taskCategory,
            messages: request.messages.map { message in
                AiChatMessage(role: role(message.role), content: message.content.map(part))
            },
            systemPrompt: request.systemPrompt,
            maxTokens: request.maxTokens.map { UInt32(clamping: $0) },
            temperature: request.temperature,
            topP: request.topP,
            stopSequences: request.stopSequences,
            tools: request.tools.map { AiToolSpec(name: $0.name, description: $0.description, inputSchemaJson: $0.inputSchemaJSON) },
            responseFormat: request.responseFormat.map(format),
            thinking: request.thinking
        )
    }

    static func role(_ role: AIRole) -> AiRole {
        switch role {
        case .system: return .system
        case .user: return .user
        case .assistant: return .assistant
        case .tool: return .tool
        }
    }

    static func part(_ part: AIBridgeContentPart) -> AiContentPart {
        switch part {
        case .text(let text):
            return .text(text: text)
        case .image(let base64, let mediaType, let detail):
            return .imageBase64(data: base64, mediaType: mediaType, detail: detail)
        case .imageURL(let url, let detail):
            return .imageUrl(url: url, detail: detail)
        case .toolUse(let id, let name, let inputJSON):
            return .toolUse(id: id, name: name, inputJson: inputJSON)
        case .toolResult(let toolUseId, let content, let isError):
            return .toolResult(toolUseId: toolUseId, content: content, isError: isError)
        }
    }

    static func part(_ part: AiContentPart) -> AIBridgeContentPart {
        switch part {
        case .text(let text):
            return .text(text)
        case .imageBase64(let data, let mediaType, let detail):
            return .image(base64: data, mediaType: mediaType, detail: detail)
        case .imageUrl(let url, let detail):
            return .imageURL(url, detail: detail)
        case .toolUse(let id, let name, let inputJson):
            return .toolUse(id: id, name: name, inputJSON: inputJson)
        case .toolResult(let toolUseId, let content, let isError):
            return .toolResult(toolUseId: toolUseId, content: content, isError: isError)
        }
    }

    static func format(_ format: AIBridgeResponseFormat) -> AiResponseFormat {
        switch format {
        case .text: return .text
        case .jsonObject: return .jsonObject
        case .jsonSchema(let name, let schemaJSON, let strict): return .jsonSchema(name: name, schemaJson: schemaJSON, strict: strict)
        }
    }

    static func finishReason(_ reason: AiFinishReason?) -> AIFinishReason? {
        switch reason {
        case .none: return nil
        case .stop: return .stop
        case .length: return .length
        case .toolUse: return .toolUse
        case .contentFilter: return .contentFilter
        case .error: return .error
        }
    }

    static func usage(_ usage: AiUsage) -> AIUsage {
        AIUsage(inputTokens: Int(clamping: usage.inputTokens), outputTokens: Int(clamping: usage.outputTokens))
    }

    static func response(_ response: AiChatResponse) -> AIBridgeChatResponse {
        AIBridgeChatResponse(
            id: response.id,
            target: target(response.target),
            content: response.content.map(part),
            reasoning: response.reasoning,
            finishReason: finishReason(response.finishReason),
            usage: response.usage.map(usage)
        )
    }

    static func event(_ event: AiStreamEvent) -> AIBridgeStreamEvent {
        switch event {
        case .started(let target):
            return .started(Self.target(target))
        case .text(let text):
            return .text(text)
        case .reasoning(let text):
            return .reasoning(text)
        case .toolCallDelta(let index, let id, let name, let arguments):
            return .toolCallDelta(index: Int(index), id: id, name: name, arguments: arguments)
        case .toolCall(let id, let name, let inputJson):
            return .toolCall(id: id, name: name, inputJSON: inputJson)
        case .usage(let usage):
            return .usage(Self.usage(usage))
        case .done(let finishReason):
            return .done(finishReason: Self.finishReason(finishReason))
        case .failed(let error):
            let converted = convert(error)
            return .failed(converted as? AIBridgeError ?? AIBridgeError(kind: .storage, message: converted.localizedDescription))
        }
    }
}

#else

/// Built without `IMPRESS_RUST_AI` (the `ImpressRustCore` package is not a
/// declared dependency): every call reports the registry as unavailable so
/// callers fall back to on-device providers instead of crashing.
public final class RustAIBridge: AIBridge, @unchecked Sendable {
    public static let shared = RustAIBridge(workspaceDirectory: SharedWorkspace.workspaceDirectory)

    public init(workspaceDirectory: URL) {}

    private var unavailable: AIBridgeError {
        AIBridgeError(kind: .notConfigured, message: "the Rust AI registry is not linked into this build")
    }

    public func listProviders() async throws -> [AIProviderDescriptor] { throw unavailable }
    public func listTaskCategories(app: String?) async throws -> [AITaskCategory] { throw unavailable }
    public func configureCredentials(providerId: String, fields: [String: String]) async throws { throw unavailable }
    public func clearCredentials(providerId: String) async throws { throw unavailable }
    public func setForeignProviderAvailable(providerId: String, available: Bool) async throws { throw unavailable }
    public func preferences() async throws -> AIPreferences { throw unavailable }
    public func preferencesChangedSince(updatedAtMs: Int64) async throws -> Bool { throw unavailable }
    public func selectModel(providerId: String, modelId: String?) async throws -> AIPreferences { throw unavailable }
    public func clearSelection() async throws -> AIPreferences { throw unavailable }
    public func setProviderEndpoint(providerId: String, endpoint: String?) async throws -> AIPreferences { throw unavailable }
    public func setAutoStartOMLX(_ enabled: Bool) async throws -> AIPreferences { throw unavailable }
    public func setTaskCategory(_ categoryId: String, assignment: AITaskCategoryAssignment) async throws -> AIPreferences { throw unavailable }
    public func importLegacyPreferences(_ legacy: AILegacyPreferences) async throws -> AIPreferences { throw unavailable }
    public func resolveTarget(providerId: String?, modelId: String?, category: String?) async throws -> AIResolvedTarget { throw unavailable }
    public func discoverModels(providerId: String?) async throws -> [AIDiscoveredModel] { throw unavailable }
    public func providerHealth(providerId: String) async throws -> AIProviderHealth { throw unavailable }
    public func ensureOMLXRunning(timeout: TimeInterval) async throws -> AIProviderHealth { throw unavailable }
    public func complete(_ request: AIBridgeChatRequest) async throws -> AIBridgeChatResponse { throw unavailable }
    public func stream(_ request: AIBridgeChatRequest) async throws -> AsyncThrowingStream<AIBridgeStreamEvent, Error> { throw unavailable }
}

#endif
