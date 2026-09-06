import ImpressKit
import SwiftUI

/// SwiftUI view for configuring AI providers.
///
/// A projection of the Rust registry (ADR-0029): the provider list, health,
/// discovered models and the device selection all come from `AISettings`;
/// opening the pane never persists anything, picking does.
@MainActor
public struct AISettingsView: View {
    @State private var settings: AISettings
    @State private var editingCredentials: [String: String] = [:]
    @State private var showingAPIKeyField: String? = nil
    @State private var endpointDraft = ""
    @State private var isTestingConnection = false
    @State private var testResult: AIProviderStatus?
    @State private var showingCategorySettings = false
    private let additionalSections: AnyView

    public init() {
        _settings = State(wrappedValue: AISettings.shared)
        additionalSections = AnyView(EmptyView())
    }

    public init(settings: AISettings) {
        _settings = State(wrappedValue: settings)
        additionalSections = AnyView(EmptyView())
    }

    /// Creates the common settings form with app-specific sections appended.
    public init<Content: View>(
        @ViewBuilder additionalSections: () -> Content
    ) {
        _settings = State(wrappedValue: AISettings.shared)
        self.additionalSections = AnyView(additionalSections())
    }

    public init<Content: View>(
        settings: AISettings,
        @ViewBuilder additionalSections: () -> Content
    ) {
        _settings = State(wrappedValue: settings)
        self.additionalSections = AnyView(additionalSections())
    }

    /// Provider groups in resolution order: local hosts first.
    static let categoryOrder: [AIProviderCategory] = [.local, .cloud, .aggregator]

    public var body: some View {
        Form {
            providerSection
            if settings.selectedProviderDescriptor?.canAutoStart == true
                || settings.selectedProviderDescriptor?.endpointEditable == true {
                endpointSection
            }
            modelSection
            credentialSection
            categorySection
            additionalSections

            if let error = settings.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            await settings.load()
            syncEndpointDraft()
        }
        .onChange(of: settings.displayedProviderId) { _, _ in
            testResult = nil
            syncEndpointDraft()
        }
        .onChange(of: settings.endpointOverrides) { _, _ in
            syncEndpointDraft()
        }
        .sheet(isPresented: $showingCategorySettings) {
            NavigationStack {
                AITaskCategorySettingsView()
                    .navigationTitle("Task Categories")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                showingCategorySettings = false
                            }
                        }
                    }
            }
            // Resizable by default (impress rule for modal sheets): a long
            // model name once overflowed this sheet with no way to widen it.
            .impressResizableSheet(minWidth: 500, idealWidth: 560, minHeight: 500, idealHeight: 620)
        }
    }

    // MARK: - Provider Section

    private var providerSection: some View {
        Section {
            Picker("Provider", selection: $settings.selectedProviderId) {
                Text(automaticLabel).tag(String?.none)
                ForEach(Self.categoryOrder, id: \.self) { category in
                    if let providers = settings.providersByCategory[category], !providers.isEmpty {
                        Section(category.displayName) {
                            ForEach(providers) { provider in
                                providerRow(provider)
                                    .tag(Optional(provider.id))
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

                HStack(alignment: .firstTextBaseline) {
                    providerStatusLine
                    Spacer()
                    if let url = metadata.registrationURL {
                        Link("Get API Key", destination: url)
                            .font(.caption)
                    }
                }

                if settings.selectedProviderId == nil {
                    Text("Resolved automatically (\(originLabel)). Choose a provider to pin it for every impress app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if !settings.registryAvailable {
                Label("The Rust AI registry is unavailable; only on-device models can be used.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("AI Provider")
        } footer: {
            Text("One selection for the whole suite: imbib, imprint, impel, impart, implore and impress read the same preference, and agents can change it with the `impress select-model` verb.")
        }
    }

    private var automaticLabel: String {
        if let resolved = settings.resolvedProviderId,
           let name = settings.availableProviders.first(where: { $0.id == resolved })?.name {
            return "Automatic (\(name))"
        }
        return "Automatic"
    }

    private var originLabel: String {
        switch settings.resolutionOrigin {
        case "first_ready": return "first ready provider"
        case "category": return "task category"
        case "selected": return "selected"
        case .some(let other): return other
        case .none: return "nothing is ready"
        }
    }

    private func providerRow(_ provider: AIProviderMetadata) -> some View {
        HStack {
            if let iconName = provider.iconName {
                Image(systemName: iconName)
                    .frame(width: 20)
            }
            Text(provider.name)
        }
    }

    /// `● oMLX 0.6.4 · 2 of 10 loaded · 28.9 GB of 105 GB` for local hosts,
    /// the credential status for cloud providers.
    private var providerStatusLine: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(readinessColor)
                .frame(width: 8, height: 8)
            Text(statusText)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var readinessColor: Color {
        switch settings.health?.state ?? settings.selectedProviderDescriptor?.readiness {
        case .ready, .foreign: return .green
        case .empty, .needsCredentials, .needsEndpoint: return .orange
        case .unreachable, .foreignUnavailable: return .red
        case .none: return settings.isProviderReady ? .green : .gray
        }
    }

    private var statusText: String {
        if let health = settings.health {
            var parts: [String] = []
            let name = settings.selectedProviderMetadata?.name ?? health.providerId
            parts.append(health.serverVersion.map { "\(name) \($0)" } ?? name)
            switch health.state {
            case .ready, .empty:
                if let loaded = health.loadedModelCount {
                    parts.append("\(loaded) of \(health.modelCount) loaded")
                } else {
                    parts.append("\(health.modelCount) models")
                }
                if let inUse = health.memoryInUseBytes, let ceiling = health.memoryCeilingBytes {
                    parts.append("\(formatBytes(inUse)) of \(formatBytes(ceiling))")
                }
            default:
                parts.append(health.detail)
            }
            return parts.joined(separator: " · ")
        }
        if let descriptor = settings.selectedProviderDescriptor {
            switch descriptor.readiness {
            case .ready: return "Ready"
            case .empty: return "Reachable, no models"
            case .needsCredentials: return "Needs an API key"
            case .needsEndpoint: return "Needs an endpoint"
            case .unreachable: return "Not reachable"
            case .foreign: return "Available on this device"
            case .foreignUnavailable: return "Not available on this device"
            }
        }
        return settings.isProviderReady ? "Ready" : "Needs setup"
    }

    // MARK: - Endpoint / local service

    private var endpointSection: some View {
        Section {
            if let descriptor = settings.selectedProviderDescriptor {
                if descriptor.endpointEditable {
                    HStack {
                        TextField(descriptor.defaultEndpoint ?? "http://host:port", text: $endpointDraft)
                            .textFieldStyle(.roundedBorder)
                        Button("Save") {
                            let value = endpointDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            let providerId = descriptor.id
                            Task { await settings.setEndpoint(value.isEmpty ? nil : value, for: providerId) }
                        }
                        .disabled(endpointDraft == (settings.endpointOverrides[descriptor.id] ?? ""))
                        if settings.endpointOverrides[descriptor.id] != nil {
                            Button("Reset") {
                                let providerId = descriptor.id
                                Task { await settings.setEndpoint(nil, for: providerId) }
                            }
                        }
                    }
                    if let current = descriptor.endpoint {
                        Text("Currently \(current)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if descriptor.canAutoStart {
                    Toggle("Start oMLX when needed", isOn: $settings.automaticallyStartOMLX)
                }
            }
        } header: {
            Text(settings.selectedProviderDescriptor?.canAutoStart == true ? "Local Service" : "Endpoint")
        } footer: {
            if settings.selectedProviderDescriptor?.canAutoStart == true {
                Text("For the local oMLX endpoint, an explicit AI request or Test Connection can launch oMLX.app and wait for it to become ready. Opening Settings never launches it. A Tailscale host can be entered above; endpoints are preferences, not secrets.")
            } else {
                Text("The endpoint is stored in the suite's AI preferences; an API key, if any, stays in the keychain.")
            }
        }
    }

    private func syncEndpointDraft() {
        guard let providerId = settings.displayedProviderId else {
            endpointDraft = ""
            return
        }
        endpointDraft = settings.endpointOverrides[providerId] ?? ""
    }

    // MARK: - Model Section

    private var modelSection: some View {
        Section {
            if settings.allModels.isEmpty {
                if settings.isRefreshingModels {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Discovering models…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(emptyModelsText)
                        .foregroundStyle(.secondary)
                }
            } else {
                AIModelPickerList(
                    models: settings.allModels,
                    selection: $settings.selectedModelId,
                    showHelpers: settings.showHelperModels
                )
                if let modelId = settings.displayedModelId,
                   settings.selectedModelId == nil,
                   let model = settings.allModels.first(where: { $0.id == modelId }) {
                    Text("Using \(model.name) until a model is pinned.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            HStack {
                Text("Model")
                Spacer()
                if settings.allModels.contains(where: \.isHelper) {
                    Toggle("Show helper models", isOn: $settings.showHelperModels)
                        #if os(macOS)
                        .toggleStyle(.checkbox)
                        #endif
                        .font(.caption)
                }
                Button {
                    Task { await settings.refreshModels() }
                } label: {
                    if settings.isRefreshingModels {
                        ProgressView().controlSize(.mini)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(settings.isRefreshingModels || settings.displayedProviderId == nil)
                .help("Discover models again")
            }
        } footer: {
            Text(modelFooter)
        }
    }

    private var emptyModelsText: String {
        if settings.health?.state == .unreachable, settings.selectedProviderDescriptor?.canAutoStart == true {
            return "oMLX is not running. Test Connection will start it."
        }
        if settings.health?.state == .unreachable {
            return "The provider is not reachable."
        }
        return "No models available"
    }

    private var modelFooter: String {
        if settings.health?.state == .unreachable, settings.selectedProviderDescriptor?.canAutoStart == true {
            return "oMLX is not running. Test Connection will start it."
        }
        return AIModelPickerList.summary(models: settings.allModels, refreshedAt: settings.lastModelRefresh)
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
                .disabled(isTestingConnection)

                if let result = testResult {
                    testResultView(result)
                }
            }
        } header: {
            Text("Credentials")
        } footer: {
            if let metadata = settings.selectedProviderMetadata,
               metadata.credentialRequirement.isRequired {
                Text("API keys are stored in your keychain and handed to the Rust registry in memory; they never enter the preferences file.")
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
        guard let providerId = settings.displayedProviderId else { return }

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

    // MARK: - Category Section

    private var categorySection: some View {
        Section {
            Button {
                showingCategorySettings = true
            } label: {
                HStack {
                    Label("Configure Task Categories", systemImage: "slider.horizontal.3")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            Text("Assign models to task types (summaries, RAG, inline edits, agent runs) or compare several side by side.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Task Categories")
        }
    }

    // MARK: - Helpers

    private func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 100 { return String(format: "%.0f GB", gb) }
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(bytes) / 1_048_576)
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
