import Foundation

/// The GUI's window onto the Rust AI registry (`crates/impress-ai`).
///
/// Every provider that runs in Rust is reached through this protocol; the
/// Swift layer never speaks a model host's wire protocol itself. The
/// production implementation wraps the UniFFI `SharedAiRegistry`; tests
/// inject a scripted fake. All values crossing the boundary are
/// ImpressAI-owned `Sendable` types so callers never see UniFFI records.
public protocol AIBridge: Sendable {
    func listProviders() async throws -> [AIProviderDescriptor]
    func listTaskCategories(app: String?) async throws -> [AITaskCategory]

    /// Push secret fields read from the keychain; Rust keeps them in memory
    /// only. An empty value clears the field.
    func configureCredentials(providerId: String, fields: [String: String]) async throws
    func clearCredentials(providerId: String) async throws

    /// Tell Rust whether a host-executed provider (Apple on-device) is
    /// usable right now, so the resolution rule can consider it.
    func setForeignProviderAvailable(providerId: String, available: Bool) async throws

    func preferences() async throws -> AIPreferences
    func preferencesChangedSince(updatedAtMs: Int64) async throws -> Bool
    func selectModel(providerId: String, modelId: String?) async throws -> AIPreferences
    func clearSelection() async throws -> AIPreferences
    func setProviderEndpoint(providerId: String, endpoint: String?) async throws -> AIPreferences
    func setAutoStartOMLX(_ enabled: Bool) async throws -> AIPreferences
    func setTaskCategory(_ categoryId: String, assignment: AITaskCategoryAssignment) async throws -> AIPreferences
    func importLegacyPreferences(_ legacy: AILegacyPreferences) async throws -> AIPreferences

    func resolveTarget(providerId: String?, modelId: String?, category: String?) async throws -> AIResolvedTarget

    /// Passive discovery: never launches a host.
    func discoverModels(providerId: String?) async throws -> [AIDiscoveredModel]
    /// Passive health probe: never launches a host.
    func providerHealth(providerId: String) async throws -> AIProviderHealth
    /// Start the managed oMLX server if the preferences allow. Throws
    /// `AIBridgeError` with kind `.hostLaunchRequired` when the app itself
    /// must be launched first.
    func ensureOMLXRunning(timeout: TimeInterval) async throws -> AIProviderHealth

    func complete(_ request: AIBridgeChatRequest) async throws -> AIBridgeChatResponse
    func stream(_ request: AIBridgeChatRequest) async throws -> AsyncThrowingStream<AIBridgeStreamEvent, Error>
}

/// Launches a companion application by bundle id. This is the one piece of
/// host integration that stays in Swift: Launch Services is a platform API.
public protocol AIHostLaunching: Sendable {
    func launchApplication(bundleId: String) async throws
}

// MARK: - Providers and models

/// Reachability of a provider as Rust sees it from this device.
public enum AIProviderReadiness: String, Sendable, Codable, Equatable {
    case ready
    case empty
    case needsCredentials = "needs_credentials"
    case needsEndpoint = "needs_endpoint"
    case unreachable
    case foreign
    case foreignUnavailable = "foreign_unavailable"

    public var isReady: Bool { self == .ready || self == .foreign }
}

/// One catalogue entry, with this device's endpoint and readiness folded in.
public struct AIProviderDescriptor: Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let description: String?
    public let category: AIProviderCategory
    /// True for providers the GUI executes itself (Apple on-device).
    public let isHostExecuted: Bool
    public let credentialFields: [AICredentialField]
    public let configuredCredentialFields: Set<String>
    public let capabilities: AICapabilities
    public let hasDynamicCatalogue: Bool
    public let staticModels: [AIModel]
    public let defaultEndpoint: String?
    public let endpoint: String?
    public let endpointEditable: Bool
    public let canAutoStart: Bool
    public let registrationURL: URL?
    public let iconName: String?
    public let readiness: AIProviderReadiness

    public init(
        id: String,
        name: String,
        description: String? = nil,
        category: AIProviderCategory,
        isHostExecuted: Bool = false,
        credentialFields: [AICredentialField] = [],
        configuredCredentialFields: Set<String> = [],
        capabilities: AICapabilities = .chat,
        hasDynamicCatalogue: Bool = false,
        staticModels: [AIModel] = [],
        defaultEndpoint: String? = nil,
        endpoint: String? = nil,
        endpointEditable: Bool = false,
        canAutoStart: Bool = false,
        registrationURL: URL? = nil,
        iconName: String? = nil,
        readiness: AIProviderReadiness = .unreachable
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.category = category
        self.isHostExecuted = isHostExecuted
        self.credentialFields = credentialFields
        self.configuredCredentialFields = configuredCredentialFields
        self.capabilities = capabilities
        self.hasDynamicCatalogue = hasDynamicCatalogue
        self.staticModels = staticModels
        self.defaultEndpoint = defaultEndpoint
        self.endpoint = endpoint
        self.endpointEditable = endpointEditable
        self.canAutoStart = canAutoStart
        self.registrationURL = registrationURL
        self.iconName = iconName
        self.readiness = readiness
    }

    /// The `AIProviderMetadata` the rest of ImpressAI keys on.
    public var metadata: AIProviderMetadata {
        AIProviderMetadata(
            id: id,
            name: name,
            description: description,
            models: staticModels,
            capabilities: capabilities,
            credentialRequirement: credentialFields.isEmpty ? .none : .custom(credentialFields),
            category: category,
            registrationURL: registrationURL,
            iconName: iconName
        )
    }
}

public enum AIModelKind: String, Sendable, Codable, Equatable {
    case llm
    case vlm
    case embedding
    case helper
    case unknown
}

/// A model row as the registry reports it: catalogue and discovery merged.
public struct AIDiscoveredModel: Sendable, Identifiable, Equatable {
    public let id: String
    public let displayName: String
    public let kind: AIModelKind
    public let isLoaded: Bool
    public let isLoading: Bool
    public let contextWindow: Int?
    public let maxOutputTokens: Int?
    public let supportsVision: Bool
    public let supportsTools: Bool?
    public let supportsThinking: Bool?
    public let supportsJSONSchema: Bool?
    public let isServerDefault: Bool
    /// Helper pseudo-models (oMLX `MarkItDown`) are listed but never
    /// selectable for chat.
    public let isHelper: Bool
    public let source: String
    public let sourceRepo: String?

    public init(
        id: String,
        displayName: String? = nil,
        kind: AIModelKind = .unknown,
        isLoaded: Bool = false,
        isLoading: Bool = false,
        contextWindow: Int? = nil,
        maxOutputTokens: Int? = nil,
        supportsVision: Bool = false,
        supportsTools: Bool? = nil,
        supportsThinking: Bool? = nil,
        supportsJSONSchema: Bool? = nil,
        isServerDefault: Bool = false,
        isHelper: Bool = false,
        source: String = "discovered",
        sourceRepo: String? = nil
    ) {
        self.id = id
        self.displayName = displayName ?? id
        self.kind = kind
        self.isLoaded = isLoaded
        self.isLoading = isLoading
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.supportsVision = supportsVision
        self.supportsTools = supportsTools
        self.supportsThinking = supportsThinking
        self.supportsJSONSchema = supportsJSONSchema
        self.isServerDefault = isServerDefault
        self.isHelper = isHelper
        self.source = source
        self.sourceRepo = sourceRepo
    }

    /// The `AIModel` shape pickers and category assignment already use.
    public var model: AIModel {
        var capabilities: AICapabilities = [.streaming, .systemPrompt]
        if supportsVision { capabilities.insert(.vision) }
        if supportsTools ?? false { capabilities.insert(.tools) }
        if supportsJSONSchema ?? false { capabilities.insert(.jsonMode) }
        if supportsThinking ?? false { capabilities.insert(.thinking) }
        return AIModel(
            id: id,
            name: displayName,
            description: descriptionLine,
            contextWindow: contextWindow,
            maxOutputTokens: maxOutputTokens,
            isDefault: isServerDefault,
            capabilities: capabilities,
            isLoaded: kind == .llm || kind == .vlm ? isLoaded : nil,
            isServerDefault: isServerDefault,
            isHelper: isHelper,
            kind: kind.rawValue,
            sourceRepo: sourceRepo
        )
    }

    private var descriptionLine: String? {
        var parts: [String] = []
        if isHelper { parts.append("Helper model") }
        if isLoading { parts.append("Loading") } else if isLoaded { parts.append("Loaded") }
        if let sourceRepo { parts.append(sourceRepo) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

public struct AIProviderHealth: Sendable, Equatable {
    public let providerId: String
    public let state: AIProviderReadiness
    public let endpoint: String?
    public let checkedAt: Date
    public let defaultModelId: String?
    public let modelCount: Int
    public let loadedModelCount: Int?
    public let serverVersion: String?
    public let memoryInUseBytes: Int64?
    public let memoryCeilingBytes: Int64?
    public let detail: String

    public init(
        providerId: String,
        state: AIProviderReadiness,
        endpoint: String? = nil,
        checkedAt: Date = Date(),
        defaultModelId: String? = nil,
        modelCount: Int = 0,
        loadedModelCount: Int? = nil,
        serverVersion: String? = nil,
        memoryInUseBytes: Int64? = nil,
        memoryCeilingBytes: Int64? = nil,
        detail: String = ""
    ) {
        self.providerId = providerId
        self.state = state
        self.endpoint = endpoint
        self.checkedAt = checkedAt
        self.defaultModelId = defaultModelId
        self.modelCount = modelCount
        self.loadedModelCount = loadedModelCount
        self.serverVersion = serverVersion
        self.memoryInUseBytes = memoryInUseBytes
        self.memoryCeilingBytes = memoryCeilingBytes
        self.detail = detail
    }

    public var isReady: Bool { state.isReady }
}

// MARK: - Preferences

/// The device's selection: a provider, optionally pinned to one model.
public struct AIModelSelection: Sendable, Equatable, Codable {
    public let providerId: String
    public let modelId: String?
    public let displayName: String?

    public init(providerId: String, modelId: String? = nil, displayName: String? = nil) {
        self.providerId = providerId
        self.modelId = modelId
        self.displayName = displayName
    }
}

public struct AIPreferences: Sendable, Equatable {
    public let version: Int
    public let selected: AIModelSelection?
    public let endpoints: [String: String]
    public let autoStartOMLX: Bool
    public let taskAssignments: [String: AITaskCategoryAssignment]
    public let updatedAtMs: Int64
    public let path: String
    public let migratedFromSharedDefaults: Bool

    public init(
        version: Int = 1,
        selected: AIModelSelection? = nil,
        endpoints: [String: String] = [:],
        autoStartOMLX: Bool = true,
        taskAssignments: [String: AITaskCategoryAssignment] = [:],
        updatedAtMs: Int64 = 0,
        path: String = "",
        migratedFromSharedDefaults: Bool = false
    ) {
        self.version = version
        self.selected = selected
        self.endpoints = endpoints
        self.autoStartOMLX = autoStartOMLX
        self.taskAssignments = taskAssignments
        self.updatedAtMs = updatedAtMs
        self.path = path
        self.migratedFromSharedDefaults = migratedFromSharedDefaults
    }
}

/// What the Swift layer stored before Rust owned the selection.
public struct AILegacyPreferences: Sendable, Equatable {
    public let selectedProviderId: String?
    public let selectedModelId: String?
    public let autoStartOMLX: Bool?
    public let taskCategoryAssignmentsJSON: String?
    public let endpoints: [String: String]

    public init(
        selectedProviderId: String? = nil,
        selectedModelId: String? = nil,
        autoStartOMLX: Bool? = nil,
        taskCategoryAssignmentsJSON: String? = nil,
        endpoints: [String: String] = [:]
    ) {
        self.selectedProviderId = selectedProviderId
        self.selectedModelId = selectedModelId
        self.autoStartOMLX = autoStartOMLX
        self.taskCategoryAssignmentsJSON = taskCategoryAssignmentsJSON
        self.endpoints = endpoints
    }
}

public struct AIResolvedTarget: Sendable, Equatable {
    public let providerId: String
    public let modelId: String
    public let endpointId: String
    /// `explicit`, `category`, `selected` or `first_ready`.
    public let origin: String

    public init(providerId: String, modelId: String, endpointId: String, origin: String) {
        self.providerId = providerId
        self.modelId = modelId
        self.endpointId = endpointId
        self.origin = origin
    }
}

// MARK: - Chat

public enum AIBridgeContentPart: Sendable, Equatable {
    case text(String)
    case image(base64: String, mediaType: String, detail: String?)
    case imageURL(String, detail: String?)
    case toolUse(id: String, name: String, inputJSON: String)
    case toolResult(toolUseId: String, content: String, isError: Bool)
}

public struct AIBridgeMessage: Sendable, Equatable {
    public let role: AIRole
    public let content: [AIBridgeContentPart]

    public init(role: AIRole, content: [AIBridgeContentPart]) {
        self.role = role
        self.content = content
    }
}

public struct AIBridgeToolSpec: Sendable, Equatable {
    public let name: String
    public let description: String
    public let inputSchemaJSON: String

    public init(name: String, description: String, inputSchemaJSON: String) {
        self.name = name
        self.description = description
        self.inputSchemaJSON = inputSchemaJSON
    }
}

public enum AIBridgeResponseFormat: Sendable, Equatable {
    case text
    case jsonObject
    case jsonSchema(name: String, schemaJSON: String, strict: Bool)
}

public struct AIBridgeChatRequest: Sendable, Equatable {
    public var providerId: String?
    public var modelId: String?
    public var taskCategory: String?
    public var messages: [AIBridgeMessage]
    public var systemPrompt: String?
    public var maxTokens: Int?
    public var temperature: Double?
    public var topP: Double?
    public var stopSequences: [String]
    public var tools: [AIBridgeToolSpec]
    public var responseFormat: AIBridgeResponseFormat?
    public var thinking: Bool

    public init(
        providerId: String? = nil,
        modelId: String? = nil,
        taskCategory: String? = nil,
        messages: [AIBridgeMessage],
        systemPrompt: String? = nil,
        maxTokens: Int? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        stopSequences: [String] = [],
        tools: [AIBridgeToolSpec] = [],
        responseFormat: AIBridgeResponseFormat? = nil,
        thinking: Bool = false
    ) {
        self.providerId = providerId
        self.modelId = modelId
        self.taskCategory = taskCategory
        self.messages = messages
        self.systemPrompt = systemPrompt
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.stopSequences = stopSequences
        self.tools = tools
        self.responseFormat = responseFormat
        self.thinking = thinking
    }
}

public struct AIBridgeChatResponse: Sendable, Equatable {
    public let id: String
    public let target: AIResolvedTarget
    public let content: [AIBridgeContentPart]
    public let reasoning: String?
    public let finishReason: AIFinishReason?
    public let usage: AIUsage?

    public init(
        id: String,
        target: AIResolvedTarget,
        content: [AIBridgeContentPart],
        reasoning: String? = nil,
        finishReason: AIFinishReason? = nil,
        usage: AIUsage? = nil
    ) {
        self.id = id
        self.target = target
        self.content = content
        self.reasoning = reasoning
        self.finishReason = finishReason
        self.usage = usage
    }
}

public enum AIBridgeStreamEvent: Sendable, Equatable {
    case started(AIResolvedTarget)
    case text(String)
    case reasoning(String)
    case toolCallDelta(index: Int, id: String?, name: String?, arguments: String)
    case toolCall(id: String, name: String, inputJSON: String)
    case usage(AIUsage)
    case done(finishReason: AIFinishReason?)
    case failed(AIBridgeError)
}

// MARK: - Errors

/// The Rust error vocabulary, one case per `impress_ai::Error` family.
public struct AIBridgeError: Error, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case notConfigured
        case unauthorized
        case unreachable
        case rateLimited
        case provider(status: Int?)
        case invalid
        case foreignExecutor
        case hostLaunchRequired
        case cancelled
        case storage
    }

    public let kind: Kind
    public let providerId: String?
    public let message: String
    public let retryAfter: TimeInterval?
    public let bundleId: String?

    public init(
        kind: Kind,
        providerId: String? = nil,
        message: String,
        retryAfter: TimeInterval? = nil,
        bundleId: String? = nil
    ) {
        self.kind = kind
        self.providerId = providerId
        self.message = message
        self.retryAfter = retryAfter
        self.bundleId = bundleId
    }

    /// The `AIError` callers already handle.
    public var asAIError: AIError {
        switch kind {
        case .notConfigured:
            return .providerNotConfigured(message)
        case .unauthorized:
            return .unauthorized(message: message)
        case .unreachable:
            return .networkError(underlying: URLError(.cannotConnectToHost, userInfo: [NSLocalizedDescriptionKey: message]))
        case .rateLimited:
            return .rateLimited(retryAfter: retryAfter)
        case .provider(let status):
            return .apiError(statusCode: status ?? 0, message: message)
        case .invalid:
            return .invalidRequest(message)
        case .foreignExecutor:
            return .providerNotConfigured(message)
        case .hostLaunchRequired:
            return .providerNotConfigured(message)
        case .cancelled:
            return .cancelled
        case .storage:
            return .unknown(message)
        }
    }
}
