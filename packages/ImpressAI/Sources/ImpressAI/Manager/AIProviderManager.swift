import Foundation
import ImpressKit
import ImpressLogging

/// Posted in-process after the device selection changed through this manager.
public extension Notification.Name {
    static let impressAIPreferencesDidChange = Notification.Name("impressai.preferencesDidChange")
}

/// Central registry and coordinator for AI providers.
///
/// Since ADR-0029 this is a projection over the Rust registry: the catalogue,
/// the device selection (`<workspace>/ai/preferences.json`) and every wire
/// protocol live in `crates/impress-ai`. The manager creates one
/// `RustBridgedAIProvider` per catalogue entry, executes Apple on-device
/// models itself (the one host-executed provider), keeps native providers
/// registrable for engines and tests, and routes requests.
///
/// ```swift
/// let manager = AIProviderManager.shared
/// await manager.registerBuiltInProviders()
/// let response = try await manager.complete(AICompletionRequest(messages: [...]))
/// ```
public actor AIProviderManager {
    /// Shared singleton instance.
    public static let shared = AIProviderManager()

    private let bridge: any AIBridge
    private let credentialManager: AICredentialManager
    private let hostLauncher: any AIHostLaunching
    private let defaults: UserDefaults

    private var providers: [String: any AIProvider] = [:]
    private var registrationOrder: [String] = []
    private var registeredBuiltIns = false
    private var preferences: AIPreferences?
    /// Selection kept in memory for providers the registry does not know —
    /// natively registered Swift providers (engines, tests) — and when the
    /// registry is unavailable, so the routing rule still holds.
    private var localSelection: AIModelSelection?
    private var localAutoStart = true

    /// Catalogue entries as the registry reported them, in resolution order.
    public private(set) var descriptors: [AIProviderDescriptor] = []
    /// What the registry would use when nothing is selected explicitly.
    public private(set) var resolvedProviderId: String?
    public private(set) var resolvedModelId: String?
    public private(set) var resolutionOrigin: String?
    /// Whether the Rust registry answered; false means on-device only.
    public private(set) var registryAvailable = false

    /// User-selected default provider ID (nil = let the registry resolve).
    public var defaultProviderId: String? {
        localSelection?.providerId ?? preferences?.selected?.providerId
    }

    /// User-selected default model ID.
    public var defaultModelId: String? {
        localSelection?.modelId ?? preferences?.selected?.modelId
    }

    /// A provider registered from Swift that the Rust catalogue does not list.
    private func isNativeOnly(_ providerId: String) -> Bool {
        providers[providerId] != nil && !descriptors.contains { $0.id == providerId }
    }

    /// Whether explicit AI operations may launch oMLX for the conventional
    /// local endpoint when it is not reachable.
    public var automaticallyStartOMLX: Bool {
        preferences?.autoStartOMLX ?? localAutoStart
    }

    /// The last preferences snapshot read from the registry.
    public var currentPreferences: AIPreferences? { preferences }

    /// Models the researcher made available to the suite. Empty means every
    /// model is available.
    public var enabledModels: [AIModelReference] {
        preferences?.enabledModels ?? []
    }

    /// Add or remove one model from that set.
    public func setModelEnabled(_ model: AIModelReference, enabled: Bool) async {
        logInfo("Mutation: \(enabled ? "enable" : "disable") \(model.id) for the suite", category: "ai.preferences")
        do {
            preferences = try await bridge.setModelEnabled(
                providerId: model.providerId, modelId: model.modelId, enabled: enabled)
            logSave()
        } catch {
            logError("Save: availability for \(model.id) not stored: \(error.localizedDescription)", category: "ai.preferences")
        }
        notifyPreferencesChanged()
    }

    /// Creates a new provider manager.
    ///
    /// - Parameters:
    ///   - bridge: The registry bridge (the Rust FFI in production, a fake in tests).
    ///   - credentialManager: The keychain-backed credential store.
    ///   - hostLauncher: Launches companion apps (oMLX.app) when Rust asks.
    ///   - defaults: The suite defaults the one-time migration reads from.
    public init(
        bridge: any AIBridge = RustAIBridge.shared,
        credentialManager: AICredentialManager = .shared,
        hostLauncher: any AIHostLaunching = OMLXServiceController.shared,
        defaults: UserDefaults = SharedDefaults.suite
    ) {
        self.bridge = bridge
        self.credentialManager = credentialManager
        self.hostLauncher = hostLauncher
        self.defaults = defaults
    }

    // MARK: - Provider Registration

    /// Registers an AI provider (native Swift providers and tests).
    public func register(_ provider: some AIProvider) {
        let id = provider.metadata.id
        if providers[id] == nil {
            registrationOrder.append(id)
        }
        providers[id] = provider
    }

    /// Unregisters an AI provider.
    public func unregister(_ providerId: String) {
        providers.removeValue(forKey: providerId)
        registrationOrder.removeAll { $0 == providerId }
    }

    /// Returns a registered provider by ID.
    public func provider(for providerId: String) -> (any AIProvider)? {
        providers[providerId]
    }

    /// Returns all registered providers in registration (= resolution) order.
    public var allProviders: [any AIProvider] {
        registrationOrder.compactMap { providers[$0] }
    }

    /// Returns metadata for all registered providers.
    public var allProviderMetadata: [AIProviderMetadata] {
        allProviders.map(\.metadata)
    }

    /// Registers the catalogue from the Rust registry: Apple on-device is
    /// executed here, every other entry becomes a bridged provider. Then the
    /// preferences are read, the legacy SharedDefaults selection is imported
    /// once, and keychain secrets are pushed into Rust memory. Idempotent.
    public func registerBuiltInProviders() async {
        if registeredBuiltIns { return }
        registeredBuiltIns = true
        do {
            let descriptors = try await bridge.listProviders()
            self.descriptors = descriptors
            registryAvailable = true
            for descriptor in descriptors {
                if descriptor.isHostExecuted {
                    let apple = AppleFoundationModelsProvider()
                    register(apple)
                    try? await bridge.setForeignProviderAvailable(providerId: descriptor.id, available: apple.isAvailable)
                } else {
                    register(RustBridgedAIProvider(descriptor: descriptor, bridge: bridge, hostLauncher: hostLauncher))
                }
            }
            logInfo("Display: AI registry lists \(descriptors.count) providers", category: "ai.bridge")
        } catch {
            registryAvailable = false
            logError("AI registry unavailable (\(error.localizedDescription)); only on-device models are registered", category: "ai.bridge")
            register(AppleFoundationModelsProvider())
        }
        await reloadPreferences()
        if registryAvailable {
            if await AIPreferencesMigration.runIfNeeded(bridge: bridge, credentials: credentialManager, defaults: defaults) != nil {
                await reloadPreferences()
            }
            await syncCredentialsToRust()
        }
    }

    // MARK: - Preferences

    /// Re-read the device selection (another app or an agent may have
    /// changed the file) and recompute what the registry would resolve.
    public func reloadPreferences() async {
        preferences = try? await bridge.preferences()
        if let resolved = try? await bridge.resolveTarget(providerId: nil, modelId: nil, category: nil) {
            resolvedProviderId = resolved.providerId
            resolvedModelId = resolved.modelId
            resolutionOrigin = resolved.origin
        } else {
            resolvedProviderId = nil
            resolvedModelId = nil
            resolutionOrigin = nil
        }
    }

    /// Whether the registry changed the preferences since the given stamp.
    public func preferencesChanged(since updatedAtMs: Int64) async -> Bool {
        (try? await bridge.preferencesChangedSince(updatedAtMs: updatedAtMs)) ?? false
    }

    /// Pins the device's provider; the model resets to the provider's default.
    public func setDefaultProviderId(_ providerId: String?) async {
        logInfo("Mutation: select provider \(providerId ?? "<none>") (was \(defaultProviderId ?? "<none>"))", category: "ai.preferences")
        if let providerId, isNativeOnly(providerId) {
            // Outside the registry's catalogue: kept for this process only.
            localSelection = AIModelSelection(providerId: providerId)
            await refreshResolutionAndNotify()
            return
        }
        do {
            if let providerId {
                preferences = try await bridge.selectModel(providerId: providerId, modelId: nil)
            } else {
                preferences = try await bridge.clearSelection()
            }
            localSelection = nil
            logSave()
        } catch {
            if Self.isRejection(error) {
                logError("Save: registry rejected provider \(providerId ?? "<none>"): \(error.localizedDescription)", category: "ai.preferences")
                return
            }
            localSelection = providerId.map { AIModelSelection(providerId: $0) }
            logError("Save: provider selection not stored by the registry: \(error.localizedDescription)", category: "ai.preferences")
        }
        await refreshResolutionAndNotify()
    }

    /// Pins the model for the selected (or resolved) provider.
    public func setDefaultModelId(_ modelId: String?) async {
        guard let providerId = defaultProviderId ?? resolvedProviderId else {
            logError("Mutation: cannot select model \(modelId ?? "<none>") without a provider", category: "ai.preferences")
            return
        }
        logInfo("Mutation: select model \(modelId ?? "<none>") for \(providerId) (was \(defaultModelId ?? "<none>"))", category: "ai.preferences")
        if isNativeOnly(providerId) {
            localSelection = AIModelSelection(providerId: providerId, modelId: modelId)
            await refreshResolutionAndNotify()
            return
        }
        do {
            preferences = try await bridge.selectModel(providerId: providerId, modelId: modelId)
            localSelection = nil
            logSave()
        } catch {
            if Self.isRejection(error) {
                logError("Save: registry rejected model \(modelId ?? "<none>") for \(providerId): \(error.localizedDescription)", category: "ai.preferences")
                return
            }
            localSelection = AIModelSelection(providerId: providerId, modelId: modelId)
            logError("Save: model selection not stored by the registry: \(error.localizedDescription)", category: "ai.preferences")
        }
        await refreshResolutionAndNotify()
    }

    /// Updates the suite-wide oMLX lifecycle preference.
    public func setAutomaticallyStartOMLX(_ enabled: Bool) async {
        logInfo("Mutation: auto-start oMLX = \(enabled)", category: "ai.preferences")
        do {
            preferences = try await bridge.setAutoStartOMLX(enabled)
            logSave()
        } catch {
            localAutoStart = enabled
            logError("Save: auto-start preference not stored: \(error.localizedDescription)", category: "ai.preferences")
        }
        notifyPreferencesChanged()
    }

    /// Overrides (or with nil resets) a provider's endpoint, e.g. an oMLX
    /// host reached over Tailscale. Secrets never go here.
    public func setEndpointOverride(_ endpoint: String?, for providerId: String) async throws {
        logInfo("Mutation: endpoint for \(providerId) = \(endpoint ?? "<default>")", category: "ai.preferences")
        do {
            preferences = try await bridge.setProviderEndpoint(providerId: providerId, endpoint: endpoint)
            logSave()
        } catch {
            logError("Save: endpoint for \(providerId) not stored: \(error.localizedDescription)", category: "ai.preferences")
            throw AIError.from(error)
        }
        await refreshDescriptor(providerId)
        await refreshResolutionAndNotify()
    }

    /// Push secret fields from the keychain into Rust memory (never the file).
    public func syncCredentialsToRust() async {
        for descriptor in descriptors where !descriptor.isHostExecuted {
            var fields: [String: String] = [:]
            for field in descriptor.credentialFields where field.isSecret {
                if let value = await credentialManager.retrieve(for: descriptor.id, field: field.id), !value.isEmpty {
                    fields[field.id] = value
                }
            }
            do {
                if fields.isEmpty {
                    try await bridge.clearCredentials(providerId: descriptor.id)
                } else {
                    try await bridge.configureCredentials(providerId: descriptor.id, fields: fields)
                }
            } catch {
                logError("Credentials for \(descriptor.id) could not be handed to the registry: \(error.localizedDescription)", category: "ai.credentials")
            }
        }
        await refreshDescriptors()
    }

    /// After credentials changed for one provider: push them and refresh its
    /// descriptor (readiness, configured fields).
    public func credentialsDidChange(for providerId: String) async {
        await syncCredentialsToRust()
        await refreshDescriptor(providerId)
        await refreshResolutionAndNotify()
    }

    // MARK: - Discovery and health

    /// Models for a provider: discovered (catalogue merged with the host's
    /// list) for bridged providers, static for the rest.
    public func models(for providerId: String, forceRefresh: Bool = false, includeHelpers: Bool = false) async throws -> [AIModel] {
        guard let provider = providers[providerId] else { throw AIError.providerNotFound(providerId) }
        if let bridged = provider as? RustBridgedAIProvider {
            return try await bridged.discoverModels(forceRefresh: forceRefresh, includeHelpers: includeHelpers).map(\.model)
        }
        if let discovering = provider as? any AIModelDiscoveringProvider,
           let discovered = try? await discovering.discoverModels(), !discovered.isEmpty {
            return discovered
        }
        return provider.metadata.models
    }

    /// Health for a bridged provider; nil for native ones.
    public func health(for providerId: String, forceRefresh: Bool = false) async -> AIProviderHealth? {
        guard let bridged = providers[providerId] as? RustBridgedAIProvider else { return nil }
        return try? await bridged.health(forceRefresh: forceRefresh)
    }

    // MARK: - Completion Requests

    /// Performs a non-streaming completion request, routed to the explicit
    /// provider, else the selected one, else the resolved default.
    public func complete(_ request: AICompletionRequest) async throws -> AICompletionResponse {
        let provider = try await resolveProvider(for: request)
        return try await provider.complete(request)
    }

    /// Performs a streaming completion request.
    public func stream(_ request: AICompletionRequest) async throws -> AsyncThrowingStream<AIStreamChunk, Error> {
        let provider = try await resolveProvider(for: request)
        return try await provider.stream(request)
    }

    // MARK: - Provider Discovery

    /// Returns providers grouped by category.
    public var providersByCategory: [AIProviderCategory: [AIProviderMetadata]] {
        var result: [AIProviderCategory: [AIProviderMetadata]] = [:]
        for provider in allProviders {
            result[provider.metadata.category, default: []].append(provider.metadata)
        }
        return result
    }

    /// The provider requests go to when none is named: the selection when
    /// pinned, else what the registry resolved, else the first registered
    /// provider whose passive check passes.
    public func effectiveDefaultProvider() async -> (any AIProvider)? {
        if let selected = defaultProviderId, let provider = providers[selected] {
            return provider
        }
        if let resolved = resolvedProviderId, let provider = providers[resolved] {
            return provider
        }
        for provider in allProviders {
            if let status = try? await provider.validate(), status.isReady {
                return provider
            }
        }
        return nil
    }

    /// Returns the effective default model for a provider.
    public func effectiveDefaultModel(for providerId: String? = nil) async -> AIModel? {
        let targetProviderId = providerId ?? defaultProviderId ?? resolvedProviderId
        let provider: (any AIProvider)?
        if let targetProviderId {
            provider = providers[targetProviderId]
        } else {
            provider = await effectiveDefaultProvider()
        }
        guard let provider else { return nil }
        var models = (try? await self.models(for: provider.metadata.id)) ?? []
        if models.isEmpty {
            models = provider.metadata.models
        }

        if let selectedModel = defaultModelId,
           defaultProviderId == provider.metadata.id,
           let selected = models.first(where: { $0.id == selectedModel }) {
            return selected
        }
        if let resolvedModel = resolvedModelId,
           resolvedProviderId == provider.metadata.id,
           let resolved = models.first(where: { $0.id == resolvedModel }) {
            return resolved
        }
        return models.first { $0.isDefault } ?? models.first { $0.isServerDefault } ?? models.first
    }

    // MARK: - Credential Status

    /// Returns credential status for all registered providers.
    public func credentialStatus() async -> [AIProviderCredentialInfo] {
        var result: [AIProviderCredentialInfo] = []
        for provider in allProviders {
            let metadata = provider.metadata
            var fieldStatus: [String: AICredentialFieldStatus] = [:]
            for field in metadata.credentialRequirement.fields {
                if await credentialManager.hasCredential(for: metadata.id, field: field.id) {
                    fieldStatus[field.id] = .valid
                } else if field.isOptional {
                    fieldStatus[field.id] = .notRequired
                } else {
                    fieldStatus[field.id] = .missing
                }
            }
            if metadata.credentialRequirement.fields.isEmpty {
                fieldStatus["_none"] = .notRequired
            }
            result.append(AIProviderCredentialInfo(providerId: metadata.id, providerName: metadata.name, fieldStatus: fieldStatus))
        }
        return result
    }

    /// Checks if a provider has valid credentials configured.
    public func hasValidCredentials(for providerId: String) async -> Bool {
        guard let provider = providers[providerId] else { return false }
        switch provider.metadata.credentialRequirement {
        case .none:
            return true
        case .apiKey:
            return await credentialManager.hasCredential(for: providerId, field: "apiKey")
        case .custom(let fields):
            for field in fields where !field.isOptional {
                if !(await credentialManager.hasCredential(for: providerId, field: field.id)) {
                    return false
                }
            }
            return true
        }
    }

    // MARK: - Private

    private func resolveProvider(for request: AICompletionRequest) async throws -> any AIProvider {
        if let providerId = request.providerId {
            guard let provider = providers[providerId] else {
                throw AIError.providerNotFound(providerId)
            }
            return provider
        }
        // Route an explicitly selected suite default directly. Availability is
        // resolved by the request itself so a stopped local service gets the
        // opportunity to start rather than being silently skipped.
        if let selected = defaultProviderId, let provider = providers[selected] {
            return provider
        }
        if let provider = await effectiveDefaultProvider() {
            return provider
        }
        throw AIError.providerNotConfigured("No AI provider configured. Choose one in Settings › AI.")
    }

    private func refreshResolutionAndNotify() async {
        await reloadPreferences()
        notifyPreferencesChanged()
    }

    private func refreshDescriptors() async {
        guard registryAvailable, let fresh = try? await bridge.listProviders() else { return }
        descriptors = fresh
        for descriptor in fresh where !descriptor.isHostExecuted {
            register(RustBridgedAIProvider(descriptor: descriptor, bridge: bridge, hostLauncher: hostLauncher))
        }
    }

    private func refreshDescriptor(_ providerId: String) async {
        guard registryAvailable, let fresh = try? await bridge.listProviders() else { return }
        descriptors = fresh
        if let descriptor = fresh.first(where: { $0.id == providerId }), !descriptor.isHostExecuted {
            register(RustBridgedAIProvider(descriptor: descriptor, bridge: bridge, hostLauncher: hostLauncher))
        }
    }

    /// A registry that answered but refused (helper model, unknown provider)
    /// is not a registry that is unavailable: nothing is kept locally.
    private static func isRejection(_ error: Error) -> Bool {
        guard let bridgeError = error as? AIBridgeError else { return false }
        if case .invalid = bridgeError.kind { return true }
        return false
    }

    private func logSave() {
        let selection = preferences?.selected.map { "\($0.providerId)/\($0.modelId ?? "<default>")" } ?? "<none>"
        logInfo("Save: preferences v\(preferences?.version ?? 0) written (\(selection); \(preferences?.path ?? "?"))", category: "ai.preferences")
    }

    private nonisolated func notifyPreferencesChanged() {
        NotificationCenter.default.post(name: .impressAIPreferencesDidChange, object: nil)
    }
}
