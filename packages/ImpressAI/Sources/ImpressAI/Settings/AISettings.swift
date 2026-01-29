import Foundation

/// Observable settings model for AI provider configuration.
@MainActor
@Observable public final class AISettings {
    /// Shared singleton instance.
    public static let shared = AISettings()

    private let providerManager: AIProviderManager
    private let credentialManager: AICredentialManager
    private var updateTask: Task<Void, Never>?

    /// Currently selected provider ID.
    public var selectedProviderId: String? {
        didSet {
            if oldValue != selectedProviderId {
                Task {
                    await providerManager.setDefaultProviderId(selectedProviderId)
                    await updateProviderInfo()
                }
            }
        }
    }

    /// Currently selected model ID.
    public var selectedModelId: String? {
        didSet {
            if oldValue != selectedModelId {
                Task {
                    await providerManager.setDefaultModelId(selectedModelId)
                }
            }
        }
    }

    /// Metadata for all available providers.
    public private(set) var availableProviders: [AIProviderMetadata] = []

    /// Providers grouped by category.
    public private(set) var providersByCategory: [AIProviderCategory: [AIProviderMetadata]] = [:]

    /// Credential status for all providers.
    public private(set) var credentialStatus: [AIProviderCredentialInfo] = []

    /// Currently selected provider metadata.
    public private(set) var selectedProviderMetadata: AIProviderMetadata?

    /// Available models for the selected provider.
    public private(set) var availableModels: [AIModel] = []

    /// Whether the selected provider is ready.
    public private(set) var isProviderReady: Bool = false

    /// Error message if any.
    public var errorMessage: String?

    /// Creates a new settings instance.
    ///
    /// - Parameters:
    ///   - providerManager: The provider manager to use.
    ///   - credentialManager: The credential manager to use.
    public init(
        providerManager: AIProviderManager = .shared,
        credentialManager: AICredentialManager = .shared
    ) {
        self.providerManager = providerManager
        self.credentialManager = credentialManager
    }

    /// Loads current settings from the provider manager.
    public func load() async {
        // Register all available providers (built-in + extended Rust-backed)
        await providerManager.registerAllProviders()

        let allMetadata = await providerManager.allProviderMetadata
        let byCategory = await providerManager.providersByCategory
        let status = await providerManager.credentialStatus()

        availableProviders = allMetadata
        providersByCategory = byCategory
        credentialStatus = status

        // Set default selection
        if selectedProviderId == nil {
            if let defaultProvider = await providerManager.effectiveDefaultProvider() {
                selectedProviderId = defaultProvider.metadata.id
            } else if let first = allMetadata.first {
                selectedProviderId = first.id
            }
        }

        await updateProviderInfo()
    }

    /// Refreshes credential status for all providers.
    public func refreshCredentialStatus() async {
        credentialStatus = await providerManager.credentialStatus()
        await updateProviderInfo()
    }

    /// Stores a credential value.
    ///
    /// - Parameters:
    ///   - value: The credential value.
    ///   - providerId: The provider ID.
    ///   - field: The credential field ID.
    public func storeCredential(_ value: String, for providerId: String, field: String) async {
        do {
            try await credentialManager.store(value, for: providerId, field: field)
            await refreshCredentialStatus()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Retrieves a credential value.
    ///
    /// - Parameters:
    ///   - providerId: The provider ID.
    ///   - field: The credential field ID.
    /// - Returns: The credential value, or nil if not found.
    public func retrieveCredential(for providerId: String, field: String) async -> String? {
        await credentialManager.retrieve(for: providerId, field: field)
    }

    /// Deletes all credentials for a provider.
    ///
    /// - Parameter providerId: The provider ID.
    public func deleteCredentials(for providerId: String) async {
        await credentialManager.deleteAll(for: providerId)
        await refreshCredentialStatus()
    }

    /// Validates an API key format.
    ///
    /// - Parameters:
    ///   - value: The API key.
    ///   - providerId: The provider ID.
    /// - Returns: True if the format appears valid.
    public nonisolated func validateAPIKey(_ value: String, for providerId: String) -> Bool {
        AICredentialManager.shared.validateAPIKey(value, for: providerId)
    }

    /// Tests the connection to a provider.
    ///
    /// - Parameter providerId: The provider ID.
    /// - Returns: The provider status.
    public func testConnection(for providerId: String) async -> AIProviderStatus {
        guard let provider = await providerManager.provider(for: providerId) else {
            return .error("Provider not found")
        }

        do {
            return try await provider.validate()
        } catch {
            return .error(error.localizedDescription)
        }
    }

    // MARK: - Private Methods

    private func updateProviderInfo() async {
        guard let selectedId = selectedProviderId else {
            selectedProviderMetadata = nil
            availableModels = []
            isProviderReady = false
            return
        }

        guard let provider = await providerManager.provider(for: selectedId) else {
            selectedProviderMetadata = nil
            availableModels = []
            isProviderReady = false
            return
        }

        selectedProviderMetadata = provider.metadata
        availableModels = provider.metadata.models

        // Set default model if not selected
        if selectedModelId == nil || !availableModels.contains(where: { $0.id == selectedModelId }) {
            selectedModelId = provider.metadata.defaultModel?.id ?? availableModels.first?.id
        }

        // Check if provider is ready
        do {
            let status = try await provider.validate()
            isProviderReady = status.isReady
        } catch {
            isProviderReady = false
        }
    }
}

/// UserDefaults keys for AI settings persistence.
public enum AISettingsKey {
    public static let selectedProviderId = "impressai.selectedProviderId"
    public static let selectedModelId = "impressai.selectedModelId"
    public static let categoryAssignments = "impressai.categoryAssignments"
}

// MARK: - Category Integration

extension AISettings {
    /// Get all available model references for category assignment.
    public var availableModelReferences: [AIModelReference] {
        var references: [AIModelReference] = []
        for provider in availableProviders {
            for model in provider.models {
                references.append(AIModelReference.from(provider: provider, model: model))
            }
        }
        return references
    }

    /// Get the model reference for the current selection.
    public var currentModelReference: AIModelReference? {
        guard let provider = selectedProviderMetadata,
              let modelId = selectedModelId,
              let model = provider.models.first(where: { $0.id == modelId })
        else { return nil }
        return AIModelReference.from(provider: provider, model: model)
    }
}
