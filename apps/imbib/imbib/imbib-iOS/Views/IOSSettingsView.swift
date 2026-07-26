//
//  IOSSettingsView.swift
//  imbib-iOS
//
//  Created by Claude on 2026-01-07.
//

import SwiftUI
import PublicationManagerCore
import os
import UniformTypeIdentifiers

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

                // NOTE: the original "iCloud Sync" row lived here until
                // 2026-07-23. It was wired to CloudKitSyncSettingsStore, whose
                // engine (CommentCloudKitEngine) died in the Rust migration —
                // the toggle advertised cross-device sync that did not exist,
                // which misled users into perceiving "sync" as broken/slow.
                // Real sync arrived with ADR-0007 Phase 3; its pane now lives
                // in the Library section below (IOSSyncSettingsView).

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

                    // iCloud Sync (ADR-0007 Phase 3). This is the honest
                    // successor to the row deleted on 2026-07-23, which
                    // pointed at a CloudKit stack that no longer existed and
                    // implied syncing that wasn't happening.
                    NavigationLink {
                        IOSSyncSettingsView()
                    } label: {
                        Label("iCloud Sync", systemImage: "arrow.triangle.2.circlepath.icloud")
                    }

                    // Backup lives beside sync rather than inside it (macOS
                    // nests it in the Sync tab): on a phone the Sync pane is
                    // already a full screen, and a backup is the thing you
                    // reach for when sync is the problem.
                    NavigationLink {
                        IOSBackupSettingsView()
                    } label: {
                        Label("Library Backup", systemImage: "arrow.down.doc")
                    }
                    .accessibilityIdentifier(AccessibilityID.Settings.Tabs.backup)
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
                    if result.wasFullySuccessful {
                        Text("Local settings and files were cleared. Please force-quit and relaunch the app to complete the reset.")
                    } else {
                        Text("Some local data could not be cleared. Please force-quit and relaunch the app and try again if needed.")
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
                    resetResult = ResetResult(error: error, localDataDeleted: false)
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

    /// Mirrors `SyncedSettingsStore.recentPapersToKeep` (iCloud-synced).
    @State private var recentPapersToKeep = SyncedSettingsStore.shared.recentPapersToKeep

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

            // Recent
            Section {
                Stepper(
                    "Recent Papers to Keep: \(recentPapersToKeep)",
                    value: $recentPapersToKeep,
                    in: 10...200,
                    step: 10
                )
            } header: {
                Text("Recent")
            } footer: {
                Text(
                    "How many papers the Recent list shows. Recent tracks papers you open "
                        + "or add by hand — not papers that arrive from feeds."
                )
            }
        }
        .navigationTitle("List View")
        .onChange(of: recentPapersToKeep) { _, newValue in
            SyncedSettingsStore.shared.recentPapersToKeep = newValue
        }
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

    @State private var mutedItems: [MutedItem] = []
    @State private var showAddMute = false
    @State private var selectedSaveLibraryID: UUID?

    var body: some View {
        List {
            // Save Destination Section
            Section {
                Picker("Save to", selection: $selectedSaveLibraryID) {
                    Text("Auto (create Save library)").tag(nil as UUID?)
                    ForEach(availableSaveLibraries, id: \.id) { library in
                        Text(library.name).tag(library.id as UUID?)
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
                                if let muteType = MuteType(rawValue: item.muteType) {
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

    private var availableSaveLibraries: [LibraryModel] {
        libraryManager.libraries.filter { library in
            // TODO: Re-add filters for isDismissedLibrary and isSystemLibrary
            // when those properties are added to LibraryModel (mirrors macOS SettingsView).
            !library.isInbox
        }.sorted { $0.name < $1.name }
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

    @State private var selectedType: MuteType = .author
    @State private var value: String = ""

    let onAdd: (MuteType, String) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Picker("Type", selection: $selectedType) {
                    ForEach(MuteType.allCases, id: \.self) { type in
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

extension MuteType {
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
    @State private var httpServerEnabled = false
    @State private var httpServerPort: UInt16 = HTTPAutomationServer.defaultPort
    @State private var networkAccessEnabled = false
    @State private var networkToken: String?
    @State private var deviceAddresses: [String] = []
    @State private var tokenCopied = false

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
                Toggle("Enable HTTP Server", isOn: $httpServerEnabled)
                HStack {
                    Text("Port")
                    Spacer()
                    Text("\(String(httpServerPort))")
                        .foregroundStyle(.secondary)
                        .fontDesign(.monospaced)
                }
            } header: {
                Text("HTTP Server")
            } footer: {
                Text("Serve the automation API on localhost:\(String(httpServerPort)). On the simulator this lets agents drive and verify imbib from the host (e.g. /api/status, /api/logs).")
            }

            Section {
                Toggle("Allow Network Access (Tailscale)", isOn: $networkAccessEnabled)
                    .disabled(!httpServerEnabled)
                    .accessibilityIdentifier("automation.networkAccess")

                if networkAccessEnabled, let token = networkToken {
                    Button {
                        UIPasteboard.general.string = token
                        tokenCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            tokenCopied = false
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Bearer Token")
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                Text(token)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Image(systemName: tokenCopied ? "checkmark" : "doc.on.doc")
                                .foregroundStyle(tokenCopied ? .green : .secondary)
                        }
                    }
                    .buttonStyle(.plain)

                    Button("Regenerate Token", role: .destructive) {
                        Task {
                            networkToken = await AutomationSettingsStore.shared.regenerateNetworkToken()
                            await HTTPAutomationServer.shared.restart()
                        }
                    }

                    ForEach(deviceAddresses, id: \.self) { addr in
                        HStack {
                            Text(addr.hasPrefix("100.") ? "Tailscale" : "Local")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(addr):\(String(httpServerPort))")
                                .font(.caption.monospaced())
                        }
                    }
                }
            } header: {
                Text("Network Access")
            } footer: {
                Text("Off: the server accepts connections from this device only. On: agents on your Tailscale network (e.g. Claude Code on your Mac) can drive imbib with the bearer token — every remote request must present it. The server runs while imbib is open; iOS pauses it in the background.")
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
            httpServerEnabled = await AutomationSettingsStore.shared.isHTTPServerEnabled
            httpServerPort = await AutomationSettingsStore.shared.httpServerPort
            networkAccessEnabled = await AutomationSettingsStore.shared.allowNetworkAccess
            networkToken = await AutomationSettingsStore.shared.networkAuthToken
            deviceAddresses = DeviceAddresses.nonLoopbackIPv4()
        }
        .onChange(of: networkAccessEnabled) { _, newValue in
            Task {
                networkToken = await AutomationSettingsStore.shared.setAllowNetworkAccess(newValue)
                deviceAddresses = DeviceAddresses.nonLoopbackIPv4()
                await HTTPAutomationServer.shared.restart()
            }
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
        .onChange(of: httpServerEnabled) { _, newValue in
            Task {
                await AutomationSettingsStore.shared.setHTTPServerEnabled(newValue)
                if newValue {
                    await HTTPAutomationServer.shared.start()
                } else {
                    await HTTPAutomationServer.shared.stop()
                }
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

// MARK: - Device Addresses

/// Non-loopback IPv4 addresses of this device's interfaces, so the user can
/// read the Tailscale address (100.x.y.z) straight off the Automation
/// settings screen when enabling network access.
enum DeviceAddresses {
    static func nonLoopbackIPv4() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }
            guard let sa = current.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }
            let flags = Int32(current.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(
                sa, socklen_t(sa.pointee.sa_len),
                &host, socklen_t(host.count),
                nil, 0, NI_NUMERICHOST
            ) == 0 {
                let addr = String(cString: host)
                if !addr.isEmpty && !addresses.contains(addr) {
                    addresses.append(addr)
                }
            }
        }
        // Tailscale (CGNAT 100.64/10 — in practice 100.x) first, then the rest.
        return addresses.sorted { a, b in
            let at = a.hasPrefix("100."), bt = b.hasPrefix("100.")
            if at != bt { return at }
            return a < b
        }
    }
}

// MARK: - iCloud Sync

/// iOS Sync pane (ADR-0007 Phase 3, Phase E).
///
/// The honest successor to the "iCloud Sync" row deleted on 2026-07-23: that
/// one pointed at a CloudKit stack which no longer existed, so it implied a
/// syncing that was not happening. This pane shows real state from
/// `SyncStatusModel` — the same source the macOS tab and
/// `GET /api/sync/status` read — and states plainly what does and does not
/// sync, so nobody has to infer it.
struct IOSSyncSettingsView: View {
    @State private var model = SyncStatusModel.shared

    var body: some View {
        List {
            Section {
                SyncStatusSection(model: model)
            } footer: {
                Text("Keeps your library in step across your Mac and iOS devices "
                     + "using your personal iCloud account. Your data stays in your "
                     + "own iCloud — it is never sent anywhere else.")
            }

            Section("Status") {
                SyncDiagnosticsSection(snapshot: model.snapshot)
            }

            Section {
                SyncScopeFooter()
            }

            Section("Actions") {
                SyncActionsSection(model: model)
            }
        }
        .navigationTitle("iCloud Sync")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            model.startAutoRefresh()
        }
        .onDisappear {
            model.stopAutoRefresh()
        }
    }
}

// MARK: - Library Backup

// The iOS counterpart of macOS `BackupSettingsSection`. Same engine
// (`LibraryBackupService` → `impress_core::backup`), same scope (a snapshot of
// the WHOLE shared impress store, not just imbib), same refusal to restore
// while iCloud sync is on.
//
// Three things differ, and only because the platform differs:
//
//  * **Location.** Snapshots land in `Documents/Backups` rather than
//    Application Support, so `UIFileSharingEnabled` surfaces them in the Files
//    app. A backup the user cannot reach is not a backup — see
//    `LibraryBackupService.backupsDirectory`.
//  * **Export.** `ShareLink` on the file URL replaces "Show in Finder"; that is
//    how a snapshot gets off the phone and into iCloud Drive or onto the Mac.
//  * **Relaunch.** iOS apps must not terminate themselves, so where macOS
//    offers "Quit imbib" this asks the user to force-quit from the App
//    Switcher. The instruction is not optional: every in-memory cache in this
//    process now describes rows that no longer exist.

struct IOSBackupSettingsView: View {
    @State private var backups: [LibraryBackupRecord] = []
    @State private var isWorking = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    // Restore flow
    @State private var pendingRestore: LibraryBackupRecord?
    @State private var restoreReport: LibraryRestoreReport?
    @State private var showingImporter = false

    /// The security-scoped URL handed over by `.fileImporter`, held open from
    /// the moment it is picked until the restore it feeds finishes or is
    /// cancelled. Files outside the container are unreadable — by Foundation
    /// *and* by the Rust engine opening the same path — without it.
    @State private var scopedPick: URL?

    // Deletion is confirmed here though macOS deletes outright: a swipe is far
    // easier to trigger by accident than a click on a trash button, and the
    // file it removes may be the only copy.
    @State private var pendingDelete: LibraryBackupRecord?

    private var syncIsOn: Bool { SyncSettings.isEnabled }

    var body: some View {
        List {
            actionsSection

            if syncIsOn {
                syncWarningSection
            }

            messagesSection
            backupsSection
        }
        .navigationTitle("Library Backup")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .onDisappear { releaseScopedPick() }
        // `.data` rather than a declared backup UTI, mirroring the macOS panel's
        // `allowsOtherFileTypes`: a snapshot copied through Files or a sibling
        // Mac may arrive with any extension, and `inspect` is the real gate.
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            handlePickedFile(result)
        }
        .confirmationDialog(
            "Restore this backup?",
            isPresented: Binding(
                get: { pendingRestore != nil },
                set: { if !$0 { cancelPendingRestore() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Restore and Replace Library", role: .destructive) {
                if let record = pendingRestore {
                    pendingRestore = nil
                    performRestore(record)
                }
            }
            Button("Cancel", role: .cancel) { cancelPendingRestore() }
        } message: {
            Text(restoreWarningText)
        }
        .confirmationDialog(
            "Delete this backup?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let record = pendingDelete {
                    pendingDelete = nil
                    delete(record)
                }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(deleteWarningText)
        }
        .alert(
            "Library Restored",
            isPresented: Binding(
                get: { restoreReport != nil },
                set: { if !$0 { restoreReport = nil } }
            )
        ) {
            Button("OK") { restoreReport = nil }
        } message: {
            if let report = restoreReport {
                Text(restoreResultText(report))
            }
        }
    }

    // MARK: - Sections

    private var actionsSection: some View {
        Section {
            Button {
                createBackup()
            } label: {
                HStack {
                    Label("Back Up Now", systemImage: "arrow.down.doc")
                    Spacer()
                    if isWorking {
                        ProgressView()
                    }
                }
            }
            .disabled(isWorking)
            .accessibilityIdentifier("settings.backup.createButton")

            Button {
                showingImporter = true
            } label: {
                Label("Restore from a File…", systemImage: "arrow.uturn.backward")
            }
            .disabled(isWorking || syncIsOn)
            .accessibilityIdentifier("settings.backup.restoreFromFileButton")
        } header: {
            Text("Backup")
        } footer: {
            Text(actionsFooterText)
        }
    }

    private var syncWarningSection: some View {
        Section {
            Label(
                "iCloud sync is on. Restoring rewinds every record, and your other devices "
                    + "would overwrite the restored data with what they already hold. Turn sync "
                    + "off in Settings › iCloud Sync before restoring.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var messagesSection: some View {
        if statusMessage != nil || errorMessage != nil {
            Section {
                if let statusMessage {
                    Label(statusMessage, systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    @ViewBuilder
    private var backupsSection: some View {
        Section {
            if backups.isEmpty {
                Text("No backups yet")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(backups) { backup in
                    IOSBackupRow(
                        backup: backup,
                        restoreDisabled: isWorking || syncIsOn,
                        onRestore: { pendingRestore = backup },
                        onDelete: { pendingDelete = backup }
                    )
                }
            }
        } header: {
            Text("Backups")
        } footer: {
            if !backups.isEmpty {
                Text("Share a backup to copy it off this device. Swipe a row to delete it.")
            }
        }
    }

    // MARK: - Text

    // Built outside the view builders: these run past the type checker's
    // budget when interpolated inline (the macOS pane hit the same wall).

    private var actionsFooterText: String {
        let opener: String
        if let latest = backups.first {
            let when = latest.manifest.createdAt.formatted(date: .abbreviated, time: .shortened)
            opener = "Last backup \(when) — \(latest.manifest.contentItemCount) records, "
                + latest.manifest.sizeString + "."
        } else {
            opener = "A backup is a complete, consistent snapshot of your whole impress library "
                + "— papers, tags, collections, manuscripts and annotations — in a single SQLite "
                + "file that opens anywhere."
        }
        return opener + "\n\n" + locationBlurb
    }

    private var locationBlurb: String {
        "Backups are kept in Files › On My \(UIDevice.current.model) › imbib › Backups."
    }

    private var restoreWarningText: String {
        guard let record = pendingRestore else { return "" }
        let when = record.manifest.createdAt.formatted(date: .abbreviated, time: .shortened)
        return """
            \(record.filename) — \(record.manifest.contentItemCount) records from \(when).

            This replaces your ENTIRE impress library, including imprint manuscripts and impel \
            tasks. Anything added since this backup will be gone. The current library is \
            snapshotted first, so this is reversible.

            imbib must be force-quit and reopened afterwards.
            """
    }

    private var deleteWarningText: String {
        guard let record = pendingDelete else { return "" }
        let when = record.manifest.createdAt.formatted(date: .abbreviated, time: .shortened)
        return "\(record.filename) — \(when). If you have not shared a copy off this device, "
            + "this is the only one. Deleting it cannot be undone."
    }

    private func restoreResultText(_ report: LibraryRestoreReport) -> String {
        let safety: String
        if let path = report.safetySnapshot {
            safety = " to " + URL(fileURLWithPath: path).lastPathComponent
        } else {
            safety = ""
        }
        let counts = "\(report.itemCountAfter) records restored (was \(report.itemCountBefore))."
        let saved = "A snapshot of the replaced library was saved first" + safety + "."
        let relaunch = "Force-quit imbib from the App Switcher and open it again — and quit any "
            + "running imprint or impel — so they stop showing records from the previous library."
        return counts + "\n\n" + saved + "\n\n" + relaunch
    }

    /// The engine reports one issue per failed probe, so a plainly wrong file
    /// (a manifest sidecar, a PDF) comes back saying "file is not a database"
    /// four times over. Only the first is shown — the macOS panel has a wide
    /// sheet to spend on the rest; a phone does not.
    private func pickFailureText(_ issues: [String]) -> String {
        let detail = issues.first ?? "the file could not be read"
        return "Not a usable backup: \(detail).\n\nIf the file lives in iCloud Drive, open it once "
            + "in the Files app so it downloads to this device, then try again."
    }

    // MARK: - Actions

    private func reload() async {
        backups = await LibraryBackupService.shared.listBackups()
    }

    private func createBackup() {
        isWorking = true
        errorMessage = nil
        statusMessage = nil
        Task {
            do {
                let record = try await LibraryBackupService.shared.createBackup()
                statusMessage = "Backed up \(record.manifest.contentItemCount) records to "
                    + record.filename
            } catch {
                errorMessage = error.localizedDescription
            }
            await reload()
            isWorking = false
        }
    }

    private func performRestore(_ record: LibraryBackupRecord) {
        // Captured before the Task: @State is heap-backed and the dialog that
        // set `pendingRestore` has already dismissed (root CLAUDE.md).
        let url = record.url
        let scoped = scopedPick
        isWorking = true
        errorMessage = nil
        statusMessage = nil
        Task {
            do {
                let report = try await LibraryBackupService.shared.restore(from: url)
                await LibraryBackupService.announceRestoreToUI()
                restoreReport = report
            } catch {
                errorMessage = error.localizedDescription
            }
            scoped?.stopAccessingSecurityScopedResource()
            scopedPick = nil
            await reload()
            isWorking = false
        }
    }

    private func delete(_ record: LibraryBackupRecord) {
        let url = record.url
        Task {
            do {
                _ = try await LibraryBackupService.shared.delete(url)
            } catch {
                errorMessage = error.localizedDescription
            }
            await reload()
        }
    }

    // MARK: - File import

    private func handlePickedFile(_ result: Result<[URL], Error>) {
        switch result {
        case let .failure(error):
            errorMessage = error.localizedDescription
        case let .success(urls):
            guard let url = urls.first else { return }
            inspectPickedFile(url)
        }
    }

    /// Validate a hand-picked file, then hand it to the same confirmation
    /// dialog the in-list rows use. Nothing is copied into the container: a
    /// snapshot can be hundreds of megabytes, and the device a user is
    /// restoring on is often the one that ran out of room.
    private func inspectPickedFile(_ url: URL) {
        releaseScopedPick()
        let scoped = url.startAccessingSecurityScopedResource() ? url : nil
        scopedPick = scoped
        isWorking = true
        errorMessage = nil
        statusMessage = nil
        Logger.library.infoCapture(
            "Backup restore picked \(url.lastPathComponent) (scoped=\(scoped != nil))",
            category: "backup"
        )
        Task {
            do {
                let inspection = try await LibraryBackupService.shared.inspect(url)
                if inspection.valid, let manifest = inspection.manifest {
                    pendingRestore = LibraryBackupRecord(
                        path: url.path, manifestPath: nil, manifest: manifest)
                } else {
                    errorMessage = pickFailureText(inspection.issues)
                    scoped?.stopAccessingSecurityScopedResource()
                    scopedPick = nil
                }
            } catch {
                errorMessage = pickFailureText([error.localizedDescription])
                scoped?.stopAccessingSecurityScopedResource()
                scopedPick = nil
            }
            isWorking = false
        }
    }

    private func cancelPendingRestore() {
        pendingRestore = nil
        releaseScopedPick()
    }

    private func releaseScopedPick() {
        if let scopedPick {
            scopedPick.stopAccessingSecurityScopedResource()
        }
        scopedPick = nil
    }
}

// MARK: - Backup Row (iOS)

private struct IOSBackupRow: View {
    let backup: LibraryBackupRecord
    let restoreDisabled: Bool
    let onRestore: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(backup.manifest.createdAt.formatted(date: .abbreviated, time: .shortened))
                Text(detailLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            ShareLink(item: backup.url) {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)

            Button("Restore", action: onRestore)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(restoreDisabled)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
        .contextMenu {
            ShareLink(item: backup.url) {
                Label("Share Backup…", systemImage: "square.and.arrow.up")
            }
            Button(action: onRestore) {
                Label("Restore…", systemImage: "arrow.uturn.backward")
            }
            .disabled(restoreDisabled)
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var detailLine: String {
        var parts = ["\(backup.manifest.publicationCount) papers"]
        parts.append("\(backup.manifest.contentItemCount) records")
        parts.append(backup.manifest.sizeString)
        if let label = backup.manifest.label, !label.isEmpty {
            parts.append("“\(label)”")
        }
        return parts.joined(separator: " · ")
    }
}
