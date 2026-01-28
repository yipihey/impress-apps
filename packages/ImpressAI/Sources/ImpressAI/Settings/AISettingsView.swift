import SwiftUI

/// SwiftUI view for configuring AI providers.
public struct AISettingsView: View {
    @StateObject private var settings: AISettings
    @State private var editingCredentials: [String: String] = [:]
    @State private var showingAPIKeyField: String? = nil
    @State private var isTestingConnection = false
    @State private var testResult: AIProviderStatus?

    public init(settings: AISettings = .shared) {
        _settings = StateObject(wrappedValue: settings)
    }

    public var body: some View {
        Form {
            providerSection
            modelSection
            credentialSection

            if let error = settings.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

            // Show build instructions if extended providers are not available
            if !RustLLMProvider.isAvailable && hasExtendedProviders {
                extendedProvidersInfoSection
            }
        }
        .formStyle(.grouped)
        .task {
            await settings.load()
        }
    }

    // MARK: - Provider Section

    /// IDs of providers backed by the Rust LLM library
    private let extendedProviderIds = RustLLMProvider.providerIds

    private var providerSection: some View {
        Section {
            Picker("Provider", selection: $settings.selectedProviderId) {
                ForEach(AIProviderCategory.allCases, id: \.self) { category in
                    if let providers = settings.providersByCategory[category], !providers.isEmpty {
                        // Separate native and extended providers
                        let nativeProviders = providers.filter { !extendedProviderIds.contains($0.id) }
                        let extendedProviders = providers.filter { extendedProviderIds.contains($0.id) }

                        if !nativeProviders.isEmpty {
                            Section(category.displayName) {
                                ForEach(nativeProviders) { provider in
                                    providerRow(provider)
                                        .tag(Optional(provider.id))
                                }
                            }
                        }

                        if !extendedProviders.isEmpty {
                            Section("\(category.displayName) (Extended)") {
                                ForEach(extendedProviders) { provider in
                                    providerRow(provider, isExtended: true)
                                        .tag(Optional(provider.id))
                                }
                            }
                        }
                    }
                }
            }
            .pickerStyle(.menu)

            if let metadata = settings.selectedProviderMetadata {
                if let description = metadata.description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    statusIndicator(for: metadata.id)
                    Spacer()

                    if let url = metadata.registrationURL {
                        Link("Get API Key", destination: url)
                            .font(.caption)
                    }
                }
            }
        } header: {
            Text("AI Provider")
        }
    }

    private func providerRow(_ provider: AIProviderMetadata, isExtended: Bool = false) -> some View {
        HStack {
            if let iconName = provider.iconName {
                Image(systemName: iconName)
                    .frame(width: 20)
            }
            Text(provider.name)

            if isExtended && !RustLLMProvider.isAvailable {
                Text("(Build Required)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Model Section

    private var modelSection: some View {
        Section {
            if settings.availableModels.isEmpty {
                Text("No models available")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Model", selection: $settings.selectedModelId) {
                    ForEach(settings.availableModels) { model in
                        modelRow(model)
                            .tag(Optional(model.id))
                    }
                }
                .pickerStyle(.menu)

                if let selectedModelId = settings.selectedModelId,
                   let model = settings.availableModels.first(where: { $0.id == selectedModelId }) {
                    if let description = model.description {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        if let contextWindow = model.contextWindow {
                            Label("\(formatNumber(contextWindow)) tokens", systemImage: "text.alignleft")
                                .font(.caption)
                        }
                        if let maxOutput = model.maxOutputTokens {
                            Label("\(formatNumber(maxOutput)) max output", systemImage: "arrow.right")
                                .font(.caption)
                        }
                    }
                    .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Model")
        }
    }

    private func modelRow(_ model: AIModel) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Text(model.name)
                if model.isDefault {
                    Text("Default")
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.2))
                        .cornerRadius(4)
                }
            }
        }
    }

    // MARK: - Credential Section

    private var credentialSection: some View {
        Section {
            if let metadata = settings.selectedProviderMetadata {
                let fields = metadata.credentialRequirement.fields

                if fields.isEmpty {
                    Label("No credentials required", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                } else {
                    ForEach(fields) { field in
                        credentialField(for: field, providerId: metadata.id)
                    }

                    Button {
                        testConnection()
                    } label: {
                        HStack {
                            if isTestingConnection {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text("Test Connection")
                        }
                    }
                    .disabled(isTestingConnection || !settings.isProviderReady)

                    if let result = testResult {
                        testResultView(result)
                    }
                }
            }
        } header: {
            Text("Credentials")
        } footer: {
            if let metadata = settings.selectedProviderMetadata,
               metadata.credentialRequirement.isRequired {
                Text("API keys are stored securely in your system keychain.")
            }
        }
    }

    private func credentialField(for field: AICredentialField, providerId: String) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(field.label)

                if let status = settings.credentialStatus.first(where: { $0.providerId == providerId })?.fieldStatus[field.id] {
                    HStack(spacing: 4) {
                        switch status {
                        case .valid:
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Configured")
                        case .notRequired:
                            Image(systemName: "minus.circle")
                                .foregroundStyle(.secondary)
                            Text("Optional")
                        case .missing:
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(.orange)
                            Text("Required")
                        case .invalid(let reason):
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                            Text(reason)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if showingAPIKeyField == field.id {
                apiKeyInputField(for: field, providerId: providerId)
            } else {
                Button(field.isSecret ? "Edit" : "Configure") {
                    showingAPIKeyField = field.id
                    editingCredentials[field.id] = ""
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func apiKeyInputField(for field: AICredentialField, providerId: String) -> some View {
        HStack {
            if field.isSecret {
                SecureField(field.placeholder ?? "Enter \(field.label)", text: binding(for: field.id))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 250)
            } else {
                TextField(field.placeholder ?? "Enter \(field.label)", text: binding(for: field.id))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 250)
            }

            Button("Save") {
                saveCredential(field: field, providerId: providerId)
            }
            .buttonStyle(.borderedProminent)
            .disabled(editingCredentials[field.id]?.isEmpty ?? true)

            Button("Cancel") {
                showingAPIKeyField = nil
                editingCredentials.removeValue(forKey: field.id)
            }
            .buttonStyle(.bordered)
        }
    }

    private func binding(for fieldId: String) -> Binding<String> {
        Binding(
            get: { editingCredentials[fieldId] ?? "" },
            set: { editingCredentials[fieldId] = $0 }
        )
    }

    private func saveCredential(field: AICredentialField, providerId: String) {
        guard let value = editingCredentials[field.id], !value.isEmpty else { return }

        Task {
            await settings.storeCredential(value, for: providerId, field: field.id)
            showingAPIKeyField = nil
            editingCredentials.removeValue(forKey: field.id)
        }
    }

    private func testConnection() {
        guard let providerId = settings.selectedProviderId else { return }

        isTestingConnection = true
        testResult = nil

        Task {
            testResult = await settings.testConnection(for: providerId)
            isTestingConnection = false
        }
    }

    private func testResultView(_ status: AIProviderStatus) -> some View {
        HStack {
            switch status {
            case .ready:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Connection successful")
            case .needsCredentials(let fields):
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                Text("Missing: \(fields.joined(separator: ", "))")
            case .unavailable(let reason):
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text(reason)
            case .error(let message):
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text(message)
            }
        }
        .font(.callout)
    }

    // MARK: - Extended Providers Section

    /// Whether any extended providers are registered
    private var hasExtendedProviders: Bool {
        settings.availableProviders.contains { extendedProviderIds.contains($0.id) }
    }

    private var extendedProvidersInfoSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Extended Providers Available", systemImage: "sparkles")
                    .font(.headline)

                Text("Additional AI providers (Groq, Phind, Mistral, Cohere, DeepSeek, xAI, HuggingFace) are available but require building the Rust backend first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Run: crates/impress-llm/build-xcframework.sh")
                    .font(.caption)
                    .fontDesign(.monospaced)
                    .padding(8)
                    .background(.secondary.opacity(0.1))
                    .cornerRadius(6)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Helpers

    private func statusIndicator(for providerId: String) -> some View {
        let info = settings.credentialStatus.first { $0.providerId == providerId }

        return HStack(spacing: 4) {
            if let info = info {
                if info.isConfigured {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Ready")
                } else {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                    Text("Needs setup")
                }
            } else {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
                Text("Unknown")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func formatNumber(_ number: Int) -> String {
        if number >= 1_000_000 {
            return String(format: "%.1fM", Double(number) / 1_000_000)
        } else if number >= 1_000 {
            return String(format: "%.0fK", Double(number) / 1_000)
        }
        return "\(number)"
    }
}

#if DEBUG
struct AISettingsView_Previews: PreviewProvider {
    static var previews: some View {
        AISettingsView()
            .frame(width: 500, height: 600)
    }
}
#endif
