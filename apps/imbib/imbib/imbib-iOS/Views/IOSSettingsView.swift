//
//  IOSSettingsView.swift
//  imbib-iOS
//
//  Created by Claude on 2026-01-07.
//

import SwiftUI
import PublicationManagerCore

/// iOS settings view presented as a sheet.
struct IOSSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SettingsViewModel.self) private var viewModel

    @State private var showConsole = false
    @State private var showingResetConfirmation = false
    @State private var showingResetInProgress = false
    @State private var resetResult: ResetResult?

    var body: some View {
        NavigationStack {
            List {
                // Sources Section
                Section {
                    NavigationLink {
                        SourcesSettingsView()
                    } label: {
                        Label("API Keys", systemImage: "key")
                    }
                    .accessibilityIdentifier(AccessibilityID.Settings.Tabs.sources)
                }

                // PDF Settings
                Section {
                    NavigationLink {
                        PDFSettingsView()
                    } label: {
                        Label("PDF Settings", systemImage: "doc")
                    }
                }

                // Search Settings
                Section {
                    NavigationLink {
                        SearchSettingsView()
                    } label: {
                        Label("Search Settings", systemImage: "magnifyingglass")
                    }
                }

                // Enrichment Settings
                Section {
                    NavigationLink {
                        IOSEnrichmentSettingsView()
                    } label: {
                        Label("Citation Sources", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .accessibilityIdentifier(AccessibilityID.Settings.Tabs.enrichment)
                }

                // Inbox Settings
                Section {
                    NavigationLink {
                        IOSInboxSettingsView()
                    } label: {
                        Label("Inbox Settings", systemImage: "tray")
                    }
                }

                // Recommendation Settings
                Section {
                    NavigationLink {
                        IOSRecommendationSettingsView()
                    } label: {
                        Label("Recommendation Engine", systemImage: "sparkles")
                    }
                    .accessibilityIdentifier(AccessibilityID.Settings.Tabs.recommendations)
                }

                // iCloud Sync Settings
                Section {
                    NavigationLink {
                        CloudKitSyncSettingsView()
                    } label: {
                        Label("iCloud Sync", systemImage: "icloud")
                    }
                    .accessibilityIdentifier(AccessibilityID.Settings.Tabs.sync)
                }

                // PDF Storage Settings (iOS-specific)
                Section {
                    NavigationLink {
                        IOSPDFStorageSettingsView()
                    } label: {
                        Label("PDF Storage", systemImage: "externaldrive.fill.badge.icloud")
                    }
                }

                // Display Settings
                Section("Display") {
                    NavigationLink {
                        IOSAppearanceSettingsView()
                    } label: {
                        Label("Appearance", systemImage: "paintbrush")
                    }

                    NavigationLink {
                        ListViewSettingsView()
                    } label: {
                        Label("List View", systemImage: "list.bullet")
                    }
                }

                // Library Settings
                Section("Library") {
                    NavigationLink {
                        IOSNotesSettingsView()
                    } label: {
                        Label("Notes", systemImage: "note.text")
                    }

                    NavigationLink {
                        IOSImportExportSettingsView()
                    } label: {
                        Label("Import/Export", systemImage: "square.and.arrow.up.on.square")
                    }

                    NavigationLink {
                        IOSExplorationSettingsView()
                    } label: {
                        Label("Exploration", systemImage: "arrow.triangle.branch")
                    }
                }

                // Automation Settings
                Section {
                    NavigationLink {
                        IOSAutomationSettingsView()
                    } label: {
                        Label("Automation API", systemImage: "terminal")
                    }
                }

                // Keyboard Shortcuts
                Section {
                    NavigationLink {
                        IOSKeyboardShortcutsSettingsView()
                    } label: {
                        Label("Keyboard Shortcuts", systemImage: "keyboard")
                    }
                }

                // Developer Section
                Section("Developer") {
                    Button {
                        showConsole = true
                    } label: {
                        Label("Console", systemImage: "terminal")
                    }

                    Button(role: .destructive) {
                        showingResetConfirmation = true
                    } label: {
                        Label("Reset to First Run", systemImage: "arrow.counterclockwise")
                    }
                    .disabled(showingResetInProgress)
                }

                // Help & Support Section
                Section("Help & Support") {
                    NavigationLink {
                        IOSHelpView()
                    } label: {
                        Label("imbib Help", systemImage: "questionmark.circle")
                    }

                    Link(destination: URL(string: "https://yipihey.github.io/impress-apps/")!) {
                        Label("Online Documentation", systemImage: "book")
                    }

                    Link(destination: URL(string: "https://github.com/yipihey/impress-apps/issues")!) {
                        Label("Report an Issue", systemImage: "exclamationmark.bubble")
                    }
                }

                // About Section
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Build")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .accessibilityIdentifier(AccessibilityID.Settings.doneButton)
                }
            }
            .sheet(isPresented: $showConsole) {
                IOSConsoleView()
            }
            .confirmationDialog(
                "Reset to First Run?",
                isPresented: $showingResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Reset", role: .destructive) {
                    performReset()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will delete all libraries, papers, collections, smart searches, and settings from this device AND iCloud. API keys will be preserved.\n\nIMPORTANT: Quit imbib on ALL other devices first, or they may sync data back.")
            }
            .alert(
                resetResult?.wasFullySuccessful == true ? "Reset Complete" : "Partial Reset",
                isPresented: Binding(
                    get: { resetResult != nil },
                    set: { if !$0 { resetResult = nil } }
                )
            ) {
                Button("OK") {
                    resetResult = nil
                }
            } message: {
                if let result = resetResult {
                    if result.cloudKitPurged {
                        Text("iCloud data has been deleted. Please force-quit and relaunch the app to complete the reset.\n\nDo not open imbib on other devices until restart is complete.")
                    } else if result.cloudKitError != nil {
                        Text("iCloud data could not be deleted (offline or error). Please force-quit and relaunch the app. You may need to reset again when online.")
                    } else {
                        Text("iCloud was not available. Please force-quit and relaunch the app to complete the reset.")
                    }
                }
            }
            .overlay {
                if showingResetInProgress {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Resetting...")
                            .font(.headline)
                    }
                    .padding(40)
                    .background(.regularMaterial)
                    .clipShape(.rect(cornerRadius: 12))
                }
            }
        }
    }

    // MARK: - Reset Action

    private func performReset() {
        showingResetInProgress = true

        Task {
            do {
                let result = try await FirstRunManager.shared.resetToFirstRun()
                await MainActor.run {
                    showingResetInProgress = false
                    resetResult = result
                }
            } catch {
                await MainActor.run {
                    showingResetInProgress = false
                    // Create a failed result
                    resetResult = ResetResult(
                        cloudKitPurged: false,
                        cloudKitError: error,
                        localDataDeleted: false
                    )
                }
            }
        }
    }
}

// MARK: - Sources Settings

struct SourcesSettingsView: View {
    @Environment(SettingsViewModel.self) private var viewModel

    var body: some View {
        List {
            ForEach(viewModel.sourceCredentials) { info in
                IOSSourceCredentialRow(info: info)
            }
        }
        .navigationTitle("API Keys")
        .task {
            await viewModel.loadCredentialStatus()
        }
    }
}

// MARK: - iOS Source Credential Row

struct IOSSourceCredentialRow: View {
    let info: SourceCredentialInfo

    @Environment(SettingsViewModel.self) private var viewModel

    @State private var apiKeyInput = ""
    @State private var emailInput = ""
    @State private var showError = false
    @State private var errorMessage = ""

    var body: some View {
        Section {
            // Status
            HStack {
                Text("Status")
                Spacer()
                statusBadge
            }

            // API Key input (if required or optional)
            if requiresAPIKey {
                SecureField("API Key", text: $apiKeyInput)
                    .textContentType(.password)

                Button("Save API Key") {
                    saveAPIKey()
                }
                .disabled(apiKeyInput.isEmpty)
            }

            // Email input (if required or optional)
            if requiresEmail {
                TextField("Email", text: $emailInput)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .autocapitalization(.none)

                Button("Save Email") {
                    saveEmail()
                }
                .disabled(emailInput.isEmpty)
            }

            // Registration link
            if let url = info.registrationURL {
                Link("Get API Key", destination: url)
            }

            // No credentials needed message
            if !requiresAPIKey && !requiresEmail {
                Text("No API key required for this source")
                    .foregroundStyle(.secondary)
            }

            // Error message
            if showError {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        } header: {
            Text(info.sourceName)
        }
        .task {
            await loadExistingCredentials()
        }
    }

    // MARK: - Status Badge

    private var statusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color {
        switch info.status {
        case .valid, .optionalValid:
            return .green
        case .missing, .invalid:
            return .red
        case .optionalMissing:
            return .orange
        case .notRequired:
            return .gray
        }
    }

    private var statusText: String {
        switch info.status {
        case .valid:
            return "Configured"
        case .optionalValid:
            return "Configured (optional)"
        case .missing:
            return "Required"
        case .invalid(let reason):
            return "Invalid: \(reason)"
        case .optionalMissing:
            return "Not configured"
        case .notRequired:
            return "Not required"
        }
    }

    // MARK: - Helpers

    private var requiresAPIKey: Bool {
        switch info.requirement {
        case .apiKey, .apiKeyOptional, .apiKeyAndEmail:
            return true
        case .none, .email, .emailOptional:
            return false
        }
    }

    private var requiresEmail: Bool {
        switch info.requirement {
        case .email, .emailOptional, .apiKeyAndEmail:
            return true
        case .none, .apiKey, .apiKeyOptional:
            return false
        }
    }

    private func loadExistingCredentials() async {
        if requiresAPIKey {
            if let key = await viewModel.getAPIKey(for: info.sourceID) {
                apiKeyInput = key
            }
        }
        if requiresEmail {
            if let email = await viewModel.getEmail(for: info.sourceID) {
                emailInput = email
            }
        }
    }

    private func saveAPIKey() {
        Task {
            do {
                try await viewModel.saveAPIKey(apiKeyInput, for: info.sourceID)
                showError = false
                await viewModel.loadCredentialStatus()
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    private func saveEmail() {
        Task {
            do {
                try await viewModel.saveEmail(emailInput, for: info.sourceID)
                showError = false
                await viewModel.loadCredentialStatus()
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }
}

// MARK: - PDF Settings

struct PDFSettingsView: View {
    @State private var settings = PDFSettings.default
    @State private var customProxyURL = ""
    @State private var selectedProxyIndex: Int? = nil

    var body: some View {
        List {
            // Source Priority
            Section {
                Picker("PDF Source Priority", selection: $settings.sourcePriority) {
                    Text("Preprint First (arXiv)").tag(PDFSourcePriority.preprint)
                    Text("Publisher First").tag(PDFSourcePriority.publisher)
                }
            } header: {
                Text("Source Priority")
            } footer: {
                Text("Choose whether to prefer preprint versions (faster, open access) or publisher versions.")
            }

            // Library Proxy
            Section {
                Toggle("Enable Library Proxy", isOn: $settings.proxyEnabled)

                if settings.proxyEnabled {
                    Picker("Preset", selection: $selectedProxyIndex) {
                        Text("Custom").tag(nil as Int?)
                        ForEach(Array(PDFSettings.commonProxies.enumerated()), id: \.offset) { index, proxy in
                            Text(proxy.name).tag(index as Int?)
                        }
                    }

                    TextField("Proxy URL", text: $customProxyURL)
                        .textContentType(.URL)
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                }
            } header: {
                Text("Library Proxy")
            } footer: {
                Text("Use your institution's library proxy to access paywalled PDFs.")
            }
        }
        .navigationTitle("PDF Settings")
        .task {
            settings = await PDFSettingsStore.shared.settings
            customProxyURL = settings.libraryProxyURL
            selectedProxyIndex = PDFSettings.commonProxies.firstIndex { $0.url == settings.libraryProxyURL }
        }
        .onChange(of: settings.sourcePriority) { _, _ in
            saveSettings()
        }
        .onChange(of: settings.proxyEnabled) { _, _ in
            saveSettings()
        }
        .onChange(of: selectedProxyIndex) { _, newValue in
            if let index = newValue {
                customProxyURL = PDFSettings.commonProxies[index].url
            }
            saveSettings()
        }
        .onChange(of: customProxyURL) { _, _ in
            saveSettings()
        }
    }

    private func saveSettings() {
        Task {
            await PDFSettingsStore.shared.updateSourcePriority(settings.sourcePriority)
            await PDFSettingsStore.shared.updateLibraryProxy(url: customProxyURL, enabled: settings.proxyEnabled)
        }
    }
}

// MARK: - Search Settings

struct SearchSettingsView: View {
    @Environment(SettingsViewModel.self) private var viewModel
    @State private var maxResults: Int = 100

    var body: some View {
        List {
            Section {
                Stepper(
                    "Results: \(maxResults)",
                    value: $maxResults,
                    in: 10...30000,
                    step: 50
                )
            } header: {
                Text("Smart Search Results")
            } footer: {
                Text("Maximum number of results to fetch per smart search query (10–30000).")
            }
        }
        .navigationTitle("Search Settings")
        .task {
            await viewModel.loadSmartSearchSettings()
            maxResults = Int(viewModel.smartSearchSettings.defaultMaxResults)
        }
        .onChange(of: maxResults) { _, newValue in
            Task {
                await viewModel.updateDefaultMaxResults(Int16(newValue))
            }
        }
    }
}

// MARK: - List View Settings

struct ListViewSettingsView: View {
    @State private var settings: ListViewSettings = .default

    var body: some View {
        List {
            // Field Visibility
            Section {
                Toggle("Show Year", isOn: $settings.showYear)
                Toggle("Show Title", isOn: $settings.showTitle)
                Toggle("Show Venue", isOn: $settings.showVenue)
                Toggle("Show Citation Count", isOn: $settings.showCitationCount)
                Toggle("Show Unread Indicator", isOn: $settings.showUnreadIndicator)
                Toggle("Show Attachment Indicator", isOn: $settings.showAttachmentIndicator)
                Toggle("Show arXiv Categories", isOn: $settings.showCategories)
            } header: {
                Text("Field Visibility")
            }

            // Abstract Preview
            Section {
                Stepper(
                    "Abstract Lines: \(settings.abstractLineLimit)",
                    value: $settings.abstractLineLimit,
                    in: 0...5
                )
            } header: {
                Text("Abstract Preview")
            } footer: {
                Text("Number of abstract lines to show (0 to hide).")
            }

            // Row Density
            Section {
                Picker("Row Density", selection: $settings.rowDensity) {
                    ForEach(RowDensity.allCases, id: \.self) { density in
                        Text(density.displayName).tag(density)
                    }
                }
            } header: {
                Text("Density")
            }
        }
        .navigationTitle("List View")
        .task {
            settings = await ListViewSettingsStore.shared.settings
        }
        .onChange(of: settings) { _, newSettings in
            saveSettings(newSettings)
        }
    }

    private func saveSettings(_ newSettings: ListViewSettings) {
        Task {
            await ListViewSettingsStore.shared.update(newSettings)
        }
    }
}

// MARK: - Inbox Settings

struct IOSInboxSettingsView: View {
    @Environment(SettingsViewModel.self) private var viewModel
    @Environment(LibraryManager.self) private var libraryManager

    @State private var mutedItems: [CDMutedItem] = []
    @State private var showAddMute = false
    @State private var selectedSaveLibraryID: UUID?

    var body: some View {
        List {
            // Save Destination Section
            Section {
                Picker("Save to", selection: $selectedSaveLibraryID) {
                    Text("Auto (create Save library)").tag(nil as UUID?)
                    ForEach(availableSaveLibraries, id: \.id) { library in
                        Text(library.displayName).tag(library.id as UUID?)
                    }
                }
                .onChange(of: selectedSaveLibraryID) { _, newValue in
                    saveSaveLibrarySetting(newValue)
                }
            } header: {
                Text("Save Destination")
            } footer: {
                Text("When you swipe right to save a paper in the Inbox, it will be moved to this library")
            }

            // Age Limit Section
            Section {
                Picker("Keep papers for", selection: Binding(
                    get: { viewModel.inboxSettings.ageLimit },
                    set: { newValue in
                        Task {
                            await viewModel.updateInboxAgeLimit(newValue)
                        }
                    }
                )) {
                    ForEach(AgeLimitPreset.allCases, id: \.self) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
            } header: {
                Text("Age Limit")
            } footer: {
                Text("Papers older than this limit (based on when they were added to the Inbox) will be hidden.")
            }

            // Muted Items Section
            Section {
                if mutedItems.isEmpty {
                    Text("No muted items")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(mutedItems) { item in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(item.value)
                                if let muteType = item.muteType {
                                    Text(muteType.displayName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                    }
                    .onDelete(perform: deleteMutedItems)
                }

                Button("Add Mute Rule") {
                    showAddMute = true
                }
            } header: {
                Text("Muted Items")
            } footer: {
                Text("Muted items will be hidden from Inbox feeds.")
            }

            // Clear All Section
            if !mutedItems.isEmpty {
                Section {
                    Button("Clear All Muted Items", role: .destructive) {
                        InboxManager.shared.clearAllMutedItems()
                        loadMutedItems()
                    }
                }
            }
        }
        .navigationTitle("Inbox Settings")
        .task {
            await viewModel.loadInboxSettings()
            loadMutedItems()
            loadSaveLibrarySetting()
        }
        .sheet(isPresented: $showAddMute) {
            AddMuteRuleSheet { type, value in
                InboxManager.shared.mute(type: type, value: value)
                loadMutedItems()
            }
        }
    }

    private func loadMutedItems() {
        mutedItems = InboxManager.shared.mutedItems
    }

    // MARK: - Save Library Setting

    private var availableSaveLibraries: [CDLibrary] {
        libraryManager.libraries.filter { library in
            !library.isInbox &&
            !library.isDismissedLibrary &&
            !library.isSystemLibrary
        }.sorted { $0.displayName < $1.displayName }
    }

    private func loadSaveLibrarySetting() {
        selectedSaveLibraryID = SyncedSettingsStore.shared.string(forKey: .inboxSaveLibraryID)
            .flatMap { UUID(uuidString: $0) }
    }

    private func saveSaveLibrarySetting(_ id: UUID?) {
        if let id = id {
            SyncedSettingsStore.shared.set(id.uuidString, forKey: .inboxSaveLibraryID)
        } else {
            SyncedSettingsStore.shared.set(nil as String?, forKey: .inboxSaveLibraryID)
        }
    }

    private func deleteMutedItems(at offsets: IndexSet) {
        for index in offsets {
            let item = mutedItems[index]
            InboxManager.shared.unmute(item)
        }
        loadMutedItems()
    }
}

// MARK: - Add Mute Rule Sheet

struct AddMuteRuleSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var selectedType: CDMutedItem.MuteType = .author
    @State private var value: String = ""

    let onAdd: (CDMutedItem.MuteType, String) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Picker("Type", selection: $selectedType) {
                    ForEach(CDMutedItem.MuteType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }

                TextField(placeholderText, text: $value)
                    .autocapitalization(.none)

                Text(helpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("Add Mute Rule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd(selectedType, value)
                        dismiss()
                    }
                    .disabled(value.isEmpty)
                }
            }
        }
    }

    private var placeholderText: String {
        switch selectedType {
        case .author: return "Author name"
        case .doi: return "DOI"
        case .bibcode: return "ADS Bibcode"
        case .venue: return "Venue name"
        case .arxivCategory: return "arXiv category"
        }
    }

    private var helpText: String {
        switch selectedType {
        case .author: return "Papers by this author will be hidden"
        case .doi: return "This specific paper will be hidden"
        case .bibcode: return "This specific paper (by ADS bibcode) will be hidden"
        case .venue: return "Papers from this venue will be hidden"
        case .arxivCategory: return "Papers from this arXiv category will be hidden"
        }
    }
}

// MARK: - MuteType Display Name (iOS)

extension CDMutedItem.MuteType {
    var displayName: String {
        switch self {
        case .author: return "Author"
        case .doi: return "DOI"
        case .bibcode: return "Bibcode"
        case .venue: return "Venue"
        case .arxivCategory: return "arXiv Category"
        }
    }
}

// MARK: - Automation Settings

struct IOSAutomationSettingsView: View {
    @State private var automationEnabled = false
    @State private var loggingEnabled = false

    var body: some View {
        List {
            Section {
                Toggle("Enable Automation API", isOn: $automationEnabled)
            } header: {
                Text("URL Scheme")
            } footer: {
                Text("Allow external apps and scripts to control imBib via the imbib:// URL scheme.")
            }

            Section {
                Toggle("Log Automation Requests", isOn: $loggingEnabled)
            } header: {
                Text("Debugging")
            } footer: {
                Text("Log all incoming automation requests to the console for debugging.")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Example URLs:")
                        .font(.headline)

                    Group {
                        Text("imbib://search?query=dark+matter")
                        Text("imbib://navigate/inbox")
                        Text("imbib://selected/toggle-read")
                    }
                    .font(.caption)
                    .fontDesign(.monospaced)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Documentation")
            }
        }
        .navigationTitle("Automation")
        .task {
            automationEnabled = await AutomationSettingsStore.shared.isEnabled
            loggingEnabled = await AutomationSettingsStore.shared.isLoggingEnabled
        }
        .onChange(of: automationEnabled) { _, newValue in
            Task {
                await AutomationSettingsStore.shared.setEnabled(newValue)
            }
        }
        .onChange(of: loggingEnabled) { _, newValue in
            Task {
                await AutomationSettingsStore.shared.setLoggingEnabled(newValue)
            }
        }
    }
}

// MARK: - Enrichment Settings

struct IOSEnrichmentSettingsView: View {
    @Environment(SettingsViewModel.self) private var viewModel

    var body: some View {
        EnrichmentSettingsView(viewModel: viewModel)
            .task {
                await viewModel.loadEnrichmentSettings()
            }
    }
}

// MARK: - PDF Storage Settings (iOS)

/// iOS-specific settings for on-demand PDF storage.
///
/// Controls whether PDFs are automatically synced to the device or downloaded on-demand.
struct IOSPDFStorageSettingsView: View {
    @State private var syncAllPDFs: Bool = false
    @State private var localStorageSize: Int64 = 0
    @State private var isClearing = false
    @State private var showClearConfirmation = false

    var body: some View {
        List {
            // Sync Mode Section
            Section {
                Toggle("Sync All PDFs", isOn: $syncAllPDFs)
            } header: {
                Text("Download Mode")
            } footer: {
                if syncAllPDFs {
                    Text("All PDFs will be automatically downloaded to this device. Uses more storage but PDFs are always available offline.")
                } else {
                    Text("PDFs are downloaded only when you open them. Saves device storage. PDFs can be re-downloaded anytime from iCloud.")
                }
            }

            // Storage Info Section
            Section {
                HStack {
                    Text("Local PDFs")
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: localStorageSize, countStyle: .file))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Storage")
            } footer: {
                Text("Storage used by PDFs downloaded to this device.")
            }

            // Clear Downloads Section
            if localStorageSize > 0 && !syncAllPDFs {
                Section {
                    Button(role: .destructive) {
                        showClearConfirmation = true
                    } label: {
                        if isClearing {
                            HStack {
                                ProgressView()
                                    .padding(.trailing, 8)
                                Text("Clearing...")
                            }
                        } else {
                            Label("Clear Downloaded PDFs", systemImage: "trash")
                        }
                    }
                    .disabled(isClearing)
                } footer: {
                    Text("Remove all downloaded PDFs from this device. They can be re-downloaded from iCloud when needed.")
                }
            }
        }
        .navigationTitle("PDF Storage")
        .task {
            loadSettings()
            await loadStorageSize()
        }
        .onChange(of: syncAllPDFs) { _, newValue in
            saveSettings(newValue)
        }
        .confirmationDialog(
            "Clear Downloaded PDFs?",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                clearDownloadedPDFs()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove all downloaded PDFs from this device. They can be re-downloaded from iCloud when needed.")
        }
    }

    private func loadSettings() {
        syncAllPDFs = SyncedSettingsStore.shared.bool(forKey: .iosSyncAllPDFs) ?? false
    }

    private func saveSettings(_ value: Bool) {
        Task {
            await PDFCloudService.shared.setSyncAllPDFs(value)
        }
    }

    private func loadStorageSize() async {
        localStorageSize = await PDFCloudService.shared.localPDFStorageSizeOnDisk()
    }

    private func clearDownloadedPDFs() {
        isClearing = true
        Task {
            do {
                try await PDFCloudService.shared.clearAllDownloadedPDFs()
                await loadStorageSize()
            } catch {
                // Log error but don't show alert - the size will update on next load
            }
            await MainActor.run {
                isClearing = false
            }
        }
    }
}

// MARK: - Exploration Settings (iOS)

struct IOSExplorationSettingsView: View {
    @Environment(LibraryManager.self) private var libraryManager

    @State private var explorationRetention: ExplorationRetention = .oneMonth
    @State private var showingClearConfirmation = false

    var body: some View {
        List {
            Section {
                Picker("Keep Results", selection: $explorationRetention) {
                    ForEach(ExplorationRetention.allCases, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .onChange(of: explorationRetention) { _, newValue in
                    SyncedSettingsStore.shared.explorationRetention = newValue
                }
            } header: {
                Text("Retention Period")
            } footer: {
                Text("Exploration results (References, Citations, Similar, Co-Reads) will be automatically removed after this period.")
            }

            Section {
                Button("Clear All Exploration Results", role: .destructive) {
                    showingClearConfirmation = true
                }
            } footer: {
                Text("Immediately delete all exploration collections.")
            }
        }
        .navigationTitle("Exploration")
        .onAppear {
            explorationRetention = SyncedSettingsStore.shared.explorationRetention
        }
        .confirmationDialog(
            "Clear All Exploration Results?",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                libraryManager.clearExplorationLibrary()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will delete all exploration collections (References, Citations, Similar, Co-Reads). This action cannot be undone.")
        }
    }
}

// MARK: - Preview

#Preview {
    IOSSettingsView()
        .environment(SettingsViewModel(
            sourceManager: SourceManager(),
            credentialManager: CredentialManager()
        ))
}
