import Foundation
import ImpressLogging

/// Observable settings model for AI provider configuration.
///
/// A projection of the Rust registry for SwiftUI: it distinguishes what the
/// user *selected* from what the registry *resolved*, never persists a
/// selection just because a pane was opened, and re-reads the shared
/// preferences file when another app or an agent changed it.
@MainActor
@Observable public final class AISettings {
    /// Shared singleton instance.
    public static let shared = AISettings()

    private let providerManager: AIProviderManager
    private let credentialManager: AICredentialManager
    /// Suppresses the `didSet` persistence while state is copied from Rust.
    private var isApplyingRemoteState = false
    private var observers: [Any] = []

    /// User-pinned provider ID; nil means "let the registry resolve".
    public var selectedProviderId: String? {
        didSet {
            guard !isApplyingRemoteState, oldValue != selectedProviderId else { return }
            let providerId = selectedProviderId
            Task {
                await providerManager.setDefaultProviderId(providerId)
                await refreshSelectionDerivedState()
            }
        }
    }

    /// User-pinned model ID within the selected provider.
    public var selectedModelId: String? {
        didSet {
            guard !isApplyingRemoteState, oldValue != selectedModelId else { return }
            let modelId = selectedModelId
            Task {
                await providerManager.setDefaultModelId(modelId)
                await applyPreferences()
            }
        }
    }

    /// Whether explicit requests may launch the oMLX companion application
    /// when its conventional local endpoint is unavailable.
    public var automaticallyStartOMLX = true {
        didSet {
            guard !isApplyingRemoteState, oldValue != automaticallyStartOMLX else { return }
            let enabled = automaticallyStartOMLX
            Task { await providerManager.setAutomaticallyStartOMLX(enabled) }
        }
    }

    /// Whether helper pseudo-models are listed (never selectable).
    public var showHelperModels = false

    /// What the registry would use right now when nothing is pinned.
    public private(set) var resolvedProviderId: String?
    public private(set) var resolvedModelId: String?
    /// `explicit`, `category`, `selected` or `first_ready`.
    public private(set) var resolutionOrigin: String?

    /// Metadata for all available providers, in resolution order.
    public private(set) var availableProviders: [AIProviderMetadata] = []
    /// Providers grouped by category.
    public private(set) var providersByCategory: [AIProviderCategory: [AIProviderMetadata]] = [:]
    /// Credential status for all providers.
    public private(set) var credentialStatus: [AIProviderCredentialInfo] = []
    /// Metadata of the displayed provider.
    public private(set) var selectedProviderMetadata: AIProviderMetadata?
    /// Descriptor of the displayed provider (endpoint, readiness, auto-start).
    public private(set) var selectedProviderDescriptor: AIProviderDescriptor?
    /// Models of the displayed provider without helpers.
    public private(set) var availableModels: [AIModel] = []
    /// Models of the displayed provider including helpers.
    public private(set) var allModels: [AIModel] = []
    /// Passive health of the displayed provider (bridged providers only).
    public private(set) var health: AIProviderHealth?
    public private(set) var isRefreshingModels = false
    public private(set) var lastModelRefresh: Date?
    /// Whether the displayed provider is ready.
    public private(set) var isProviderReady = false
    /// Endpoint overrides from the preferences file.
    public private(set) var endpointOverrides: [String: String] = [:]
    /// Selectable models grouped by provider (`AIModelOptions`) — the same
    /// list the task-category sheet and the quick switcher offer.
    public private(set) var modelGroups: [AIModelOptionGroup] = []
    /// `provider:model` ids the researcher made available to the suite. Empty
    /// means every model is available.
    public private(set) var enabledModelIds: Set<String> = []
    /// Whether the Rust registry answered; false means on-device only.
    public private(set) var registryAvailable = false
    /// Error message if any.
    public var errorMessage: String?

    /// The provider the pane shows: the pinned one, else the resolved one.
    public var displayedProviderId: String? {
        selectedProviderId ?? resolvedProviderId
    }

    /// The model the pane shows: the pinned one, else the resolved one.
    public var displayedModelId: String? {
        selectedModelId ?? resolvedModelId
    }

    /// One line for status menus: "oMLX — Qwen3.5 4B 4bit".
    public var selectionSummary: String {
        guard let providerId = displayedProviderId else { return "No AI provider" }
        let providerName = availableProviders.first { $0.id == providerId }?.name ?? providerId
        guard let modelId = displayedModelId else { return providerName }
        let modelName = allModels.first { $0.id == modelId }?.name ?? modelId
        return "\(providerName) — \(modelName)"
    }

    public init(
        providerManager: AIProviderManager = .shared,
        credentialManager: AICredentialManager = .shared
    ) {
        self.providerManager = providerManager
        self.credentialManager = credentialManager
        observers.append(NotificationCenter.default.addObserver(
            forName: .impressAIPreferencesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.applyPreferences() }
        })
    }

    /// Loads current settings from the registry. Never writes a selection.
    public func load() async {
        await providerManager.registerBuiltInProviders()
        availableProviders = await providerManager.allProviderMetadata
        providersByCategory = await providerManager.providersByCategory
        credentialStatus = await providerManager.credentialStatus()
        registryAvailable = await providerManager.registryAvailable
        await applyPreferences()
        await refreshSelectionDerivedState()
        modelGroups = await AIModelOptions.load(from: providerManager)
        enabledModelIds = Set(await providerManager.enabledModels.map(\.id))
        logInfo(
            "Display: settings show \(selectionSummary) (origin \(selectionOriginDescription); \(availableModels.count) models, \(allModels.count - availableModels.count) helpers hidden)",
            category: "ai.settings"
        )
    }

    /// Re-read the preferences file (another app or an agent may have
    /// changed it) and refresh the derived state.
    public func reloadFromRegistry() async {
        await providerManager.reloadPreferences()
        await applyPreferences()
        await refreshSelectionDerivedState()
    }

    /// Make a model available to the impress apps, or withdraw it. The
    /// per-task pickers offer exactly what is enabled here.
    public func setModelEnabled(_ model: AIModel, provider: AIProviderMetadata, enabled: Bool) async {
        let reference = AIModelReference.from(provider: provider, model: model)
        await providerManager.setModelEnabled(reference, enabled: enabled)
        enabledModelIds = Set(await providerManager.enabledModels.map(\.id))
    }

    /// Whether a model may be used by the suite. With nothing curated every
    /// model may, which is what a fresh device should see.
    public func isModelEnabled(_ model: AIModel, provider: AIProviderMetadata) -> Bool {
        enabledModelIds.isEmpty || enabledModelIds.contains("\(provider.id):\(model.id)")
    }

    /// Force a fresh discovery + health probe for the displayed provider.
    public func refreshModels() async {
        guard let providerId = displayedProviderId else { return }
        isRefreshingModels = true
        defer { isRefreshingModels = false }
        do {
            allModels = try await providerManager.models(for: providerId, forceRefresh: true, includeHelpers: true)
            availableModels = allModels.filter { !$0.isHelper }
            lastModelRefresh = Date()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        health = await providerManager.health(for: providerId, forceRefresh: true)
        isProviderReady = health?.isReady ?? isProviderReady
        // Keep every other picker (task categories, the quick switcher) on the
        // same list this refresh just produced.
        modelGroups = await AIModelOptions.load(from: providerManager)
        enabledModelIds = Set(await providerManager.enabledModels.map(\.id))
    }

    /// Refreshes credential status for all providers.
    public func refreshCredentialStatus() async {
        credentialStatus = await providerManager.credentialStatus()
        await refreshSelectionDerivedState()
    }

    /// Stores a credential value. Secrets go to the keychain and are pushed
    /// into Rust memory; the non-secret `endpoint` field is a preference.
    public func storeCredential(_ value: String, for providerId: String, field: String) async {
        do {
            if field == "endpoint" {
                try await providerManager.setEndpointOverride(value.isEmpty ? nil : value, for: providerId)
            } else {
                try await credentialManager.store(value, for: providerId, field: field)
                await providerManager.credentialsDidChange(for: providerId)
            }
            await refreshCredentialStatus()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Retrieves a credential value.
    public func retrieveCredential(for providerId: String, field: String) async -> String? {
        if field == "endpoint" {
            return endpointOverrides[providerId]
        }
        return await credentialManager.retrieve(for: providerId, field: field)
    }

    /// Deletes all credentials for a provider (its declared fields).
    public func deleteCredentials(for providerId: String) async {
        let fields = availableProviders.first { $0.id == providerId }?.credentialRequirement.fields ?? []
        await credentialManager.deleteAll(for: providerId, fields: fields)
        await providerManager.credentialsDidChange(for: providerId)
        await refreshCredentialStatus()
    }

    /// Sets (or with nil resets) a provider's endpoint override.
    public func setEndpoint(_ endpoint: String?, for providerId: String) async {
        do {
            try await providerManager.setEndpointOverride(endpoint, for: providerId)
            await applyPreferences()
            await refreshSelectionDerivedState()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Validates an API key format.
    public nonisolated func validateAPIKey(_ value: String, for providerId: String) -> Bool {
        AICredentialManager.shared.validateAPIKey(value, for: providerId)
    }

    /// Tests the connection to a provider. This is the one explicit action
    /// that may start the managed oMLX server.
    public func testConnection(for providerId: String) async -> AIProviderStatus {
        guard let provider = await providerManager.provider(for: providerId) else {
            return .error("Provider not found")
        }
        do {
            if let activatingProvider = provider as? any AIServiceActivatingProvider {
                try await activatingProvider.activateServiceIfNeeded()
            }
            let status = try await provider.validate()
            await refreshModels()
            return status
        } catch {
            return .error(error.localizedDescription)
        }
    }

    // MARK: - Private

    private var selectionOriginDescription: String {
        selectedProviderId != nil ? "selected" : (resolutionOrigin ?? "unresolved")
    }

    /// Copy the registry's state into the observable properties without
    /// triggering persistence.
    private func applyPreferences() async {
        let preferences = await providerManager.currentPreferences
        let resolvedProvider = await providerManager.resolvedProviderId
        let resolvedModel = await providerManager.resolvedModelId
        let origin = await providerManager.resolutionOrigin
        let selectedProvider = await providerManager.defaultProviderId
        let selectedModel = await providerManager.defaultModelId
        let autoStart = await providerManager.automaticallyStartOMLX
        isApplyingRemoteState = true
        defer { isApplyingRemoteState = false }
        selectedProviderId = selectedProvider
        selectedModelId = selectedModel
        automaticallyStartOMLX = autoStart
        resolvedProviderId = resolvedProvider
        resolvedModelId = resolvedModel
        resolutionOrigin = origin
        endpointOverrides = preferences?.endpoints ?? [:]
    }

    private func refreshSelectionDerivedState() async {
        guard let providerId = displayedProviderId,
              let provider = await providerManager.provider(for: providerId)
        else {
            selectedProviderMetadata = nil
            selectedProviderDescriptor = nil
            availableModels = []
            allModels = []
            health = nil
            isProviderReady = false
            return
        }
        selectedProviderMetadata = provider.metadata
        selectedProviderDescriptor = await providerManager.descriptors.first { $0.id == providerId }
        if let models = try? await providerManager.models(for: providerId, includeHelpers: true), !models.isEmpty {
            allModels = models
        } else {
            allModels = provider.metadata.models
        }
        availableModels = allModels.filter { !$0.isHelper }
        lastModelRefresh = Date()
        health = await providerManager.health(for: providerId)
        if let health {
            isProviderReady = health.isReady
        } else {
            isProviderReady = (try? await provider.validate())?.isReady ?? false
        }
    }
}

/// Legacy UserDefaults keys. Only the one-time migration reads them now;
/// nothing writes them. Kept so app code that still names them compiles.
public enum AISettingsKey {
    @available(*, deprecated, message: "The selection lives in the Rust preferences file; read AISettings.shared instead.")
    public static let selectedProviderId = "impressai.selectedProviderId"
    @available(*, deprecated, message: "The selection lives in the Rust preferences file; read AISettings.shared instead.")
    public static let selectedModelId = "impressai.selectedModelId"
    @available(*, deprecated, message: "The preference lives in the Rust preferences file.")
    public static let automaticallyStartOMLX = "impressai.automaticallyStartOMLX"
    @available(*, deprecated, message: "Task categories live in the Rust preferences file.")
    public static let categoryAssignments = "impressai.categoryAssignments"
}

// MARK: - Category Integration

extension AISettings {
    /// Model references for category assignment — one implementation, shared
    /// with the task-category sheet and the quick switcher.
    public var availableModelReferences: [AIModelReference] {
        modelGroups.flatMap(\.models)
    }

    /// The model reference for the current selection.
    public var currentModelReference: AIModelReference? {
        guard let provider = selectedProviderMetadata,
              let modelId = displayedModelId,
              let model = allModels.first(where: { $0.id == modelId })
        else { return nil }
        return AIModelReference.from(provider: provider, model: model)
    }
}
