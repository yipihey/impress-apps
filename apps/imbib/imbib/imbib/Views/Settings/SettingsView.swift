//
//  SettingsView.swift
//  imbib
//
//  Created by Claude on 2026-01-04.
//
//  Stage 6 phase 2 (declarative chassis): this file no longer decides WHICH
//  panes imbib has. It used to — as a `NavigationSplitView` body plus a 16-case
//  `SettingsTab` enum with three parallel `switch`es (displayName, icon,
//  helpText) and a fourth for the detail view. Four switches over one list is
//  four chances to disagree, and the list itself was unreachable from anywhere
//  else: imbib-iOS could not read it, so it re-typed its own nineteen rows by
//  hand, and the two surfaces drifted (iOS grew PDF Storage and a top-level
//  Backup row; macOS grew Flags & Tags and E-Ink; neither knew).
//
//  Now the list is `AppSettingsConfiguration.imbib` in PublicationManagerCore —
//  data both platforms read — and this file contributes only the macOS FACTORIES
//  plus the Settings scene's host. The panes below are untouched.
//
//  Visual equivalence is the constraint: same six sidebar groups, same sixteen
//  panes in the same order, same titles, symbols and tooltips, same window
//  metrics, same `settings.tabView` identifier. `MacSettingsSidebarSceneContent`
//  exists because of that constraint — rendering imbib through phase 1's
//  `TabView` renderer would have been a redesign.
//

import ImpressSpotlight
import ImpressUndoHistory
import PublicationManagerCore
import SwiftUI

// MARK: - Settings scene host

struct SettingsView: View {

    /// Owned here rather than by the renderer because imbib DEEP LINKS into
    /// panes: `.showInboxSettings` and `.showExplorationSettings` are posted at
    /// an already-open Settings window (see the notification handlers below), so
    /// the selection has to be reachable from outside the renderer.
    @State private var selectedSection: SettingsSectionID? = .general

    var body: some View {
        MacSettingsSidebarSceneContent(
            configuration: .imbib,
            selection: $selectedSection,
            // FROZEN: imbib's UI tests address the Settings window by
            // `settings.tabView`, a string that predates the chassis default of
            // `settings.container` (imbibUITests/Tests/SettingsTests.swift).
            containerIdentifier: AccessibilityID.Settings.tabView)
        .environment(\.settingsSectionRegistry, ImbibSettingsSections.registry)
        // Deep link to specific settings panes — only switch panes, don't try to
        // open the settings window (these notifications should only fire when
        // settings is already open via deep link).
        .onReceive(NotificationCenter.default.publisher(for: .showInboxSettings)) { _ in
            selectedSection = .inbox
        }
        .onReceive(NotificationCenter.default.publisher(for: .showExplorationSettings)) { _ in
            selectedSection = .advanced
        }
    }
}

// MARK: - macOS factories

/// imbib's macOS settings REGISTRATIONS — the factory half of the ADR-0021
/// descriptor/factory split.
///
/// The descriptors are `AppSettingsConfiguration.imbib` (PMC, pure data). The
/// factories are here because a factory names concrete views, and these views
/// live in imbib's macOS target: `NSOpenPanel`, `NSColorPanel`, `NSEvent`
/// modifier monitoring, `NSWorkspace`. The chassis must not link them (the
/// `CustomSurface` rule: "the views live in APP TARGETS").
///
/// **Two things imbib does here that imprint did not:**
///
///  1. It REGISTERS OVER the chassis `appearance` builtin. `AppearanceSettingsTab`
///     is a 530-line theme editor over `ThemeSettingsStore`, not the three-way
///     System/Light/Dark picker the builtin is; the `appearanceMode` key is one
///     row inside it. Last registration wins (`composing`), which is exactly the
///     documented reason `register` allows replacement.
///  2. The keyboard pane is WRAPPED, not authored. `KeyboardShortcutsSettingsTab`
///     is driven by `PMC/Settings/KeyboardShortcutsSettings.swift`, which was
///     recently rebuilt over ImpressKeyboard's `ShortcutCatalog` and is not
///     touched here — a factory that names the existing view is the whole
///     integration, and that is the point of keeping factories out of the
///     descriptors.
enum ImbibSettingsSections {

    /// One factory per macOS-available descriptor in `.imbib`, in preset order.
    static let macFactories: [SettingsSectionFactory] = [
        SettingsSectionFactory(section: .general) { GeneralSettingsTab() },
        // Over the builtin — see the type doc.
        SettingsSectionFactory(section: .appearance) { AppearanceSettingsTab() },
        SettingsSectionFactory(section: .viewing) { ViewingSettingsTab() },
        SettingsSectionFactory(section: .flagsAndTags) { FlagsAndTagsSettingsTab() },
        SettingsSectionFactory(section: .notes) { NotesSettingsTab() },
        SettingsSectionFactory(section: .pdf) { PDFSettingsTab() },
        SettingsSectionFactory(section: .sources) { SourcesSettingsTab() },
        SettingsSectionFactory(section: .searchAI) { EmbeddingSettingsView() },
        SettingsSectionFactory(section: .inbox) { InboxSettingsTab() },
        SettingsSectionFactory(section: .recommendations) { RecommendationSettingsTab() },
        SettingsSectionFactory(section: .sync) { SyncSettingsTab() },
        SettingsSectionFactory(section: .eink) { EInkSettingsTab() },
        SettingsSectionFactory(section: .importExport) { ImportExportSettingsTab() },
        // WRAPPED, not edited — see the type doc.
        SettingsSectionFactory(section: .shortcuts) { KeyboardShortcutsSettingsTab() },
        SettingsSectionFactory(section: .advanced) { AdvancedSettingsTab() },
    ]

    /// Chassis builtins, then imbib's cross-platform panes, then macOS's.
    ///
    /// `enrichment` is absent from `macFactories` because it comes from
    /// `ImbibSettingsSections.portableFactories` in PMC: both platforms' panes
    /// were the same `EnrichmentSettingsView` in the same wrapper, so it is now
    /// declared once. It is the only one of imbib's sixteen panes for which that
    /// was true — see the type doc on `ImbibPortableSettingsSections`.
    static let registry: SettingsSectionRegistry =
        SettingsSectionRegistry.builtin
            .composing(ImbibPortableSettingsSections.factories + macFactories)
}

// MARK: - General Settings

struct GeneralSettingsTab: View {

    @Environment(SettingsViewModel.self) private var viewModel

    @AppStorage("libraryLocation") private var libraryLocation: String = ""
    @AppStorage("openPDFInExternalViewer") private var openPDFExternally = false
    @AppStorage("undoHistoryMaxEntries") private var maxUndoLevels: Int = 50

    @State private var automationSettings = AutomationSettings.default

    /// Mirrors `SyncedSettingsStore.recentPapersToKeep` (iCloud-synced) into
    /// local view state so the stepper/field stay responsive.
    @State private var recentPapersToKeep = SyncedSettingsStore.shared.recentPapersToKeep

    var body: some View {
        Form {
            Section("Library") {
                HStack {
                    TextField("Library Location", text: $libraryLocation)
                        .disabled(true)
                        .accessibilityIdentifier(AccessibilityID.Settings.General.libraryLocationField)

                    Button("Choose...") {
                        chooseLibraryLocation()
                    }
                    .accessibilityIdentifier(AccessibilityID.Settings.General.chooseLocationButton)
                }

                Toggle("Open PDFs in external viewer", isOn: $openPDFExternally)
                    .accessibilityIdentifier(AccessibilityID.Settings.PDF.openExternalToggle)

                HStack {
                    Text("Recent papers to keep:")

                    TextField(
                        "Count",
                        value: $recentPapersToKeep,
                        format: .number
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)

                    Stepper("", value: $recentPapersToKeep, in: 10...200, step: 10)
                        .labelsHidden()
                }

                Text(
                    "How many papers the Recent list shows. Recent tracks papers you open "
                        + "or add by hand — not papers that arrive from feeds."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .onChange(of: recentPapersToKeep) { _, newValue in
                    SyncedSettingsStore.shared.recentPapersToKeep = newValue
                }
            }

            Section("Smart Search") {
                HStack {
                    Text("Default result limit:")

                    TextField(
                        "Limit",
                        value: Binding(
                            get: { Int(viewModel.smartSearchSettings.defaultMaxResults) },
                            set: { newValue in
                                let clamped = max(10, min(30000, newValue))
                                Task {
                                    await viewModel.updateDefaultMaxResults(Int16(clamped))
                                }
                            }
                        ),
                        format: .number
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)

                    Stepper(
                        "",
                        value: Binding(
                            get: { Int(viewModel.smartSearchSettings.defaultMaxResults) },
                            set: { newValue in
                                Task {
                                    await viewModel.updateDefaultMaxResults(Int16(newValue))
                                }
                            }
                        ),
                        in: 10...30000,
                        step: 50
                    )
                    .labelsHidden()
                }

                Text("Maximum records to retrieve per smart search query (10–30000)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Automation") {
                Toggle("Enable automation API", isOn: $automationSettings.isEnabled)
                    .help("Allow external programs and AI agents to control imbib via URL schemes")
                    .onChange(of: automationSettings.isEnabled) { _, _ in
                        saveAutomationSettings()
                    }
                    .accessibilityIdentifier(AccessibilityID.Settings.General.autoImportToggle)

                Toggle("Log automation requests", isOn: $automationSettings.logRequests)
                    .help("Record automation commands in the Console window")
                    .disabled(!automationSettings.isEnabled)
                    .onChange(of: automationSettings.logRequests) { _, _ in
                        saveAutomationSettings()
                    }
                    .accessibilityIdentifier(AccessibilityID.Settings.Advanced.debugModeToggle)

                Text("When enabled, imbib responds to `imbib://` URL commands from CLI tools and AI agents")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("HTTP Server (Browser Extension)") {
                Toggle("Enable HTTP server", isOn: $automationSettings.isHTTPServerEnabled)
                    .help("Run a local HTTP server for browser extension integration")
                    .disabled(!automationSettings.isEnabled)
                    .onChange(of: automationSettings.isHTTPServerEnabled) { _, newValue in
                        saveAutomationSettings()
                        handleHTTPServerToggle(enabled: newValue)
                    }

                HStack {
                    Text("Port:")
                    TextField("Port", value: $automationSettings.httpServerPort, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .disabled(!automationSettings.isHTTPServerEnabled)
                        .onChange(of: automationSettings.httpServerPort) { _, _ in
                            saveAutomationSettings()
                        }
                    Text("(default: 23120)")
                        .foregroundStyle(.secondary)
                }
                .disabled(!automationSettings.isEnabled)

                if automationSettings.isHTTPServerEnabled {
                    HStack {
                        Image(systemName: "circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption2)
                        Text("Server running at http://127.0.0.1:\(automationSettings.httpServerPort)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text("Enables the Safari extension to search your library and insert citations. The server only accepts connections from localhost.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SpotlightSettingsSection()

            UndoHistorySettingsSection(maxUndoLevels: $maxUndoLevels)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding(.horizontal)
        .task {
            await viewModel.loadSmartSearchSettings()
            automationSettings = await AutomationSettingsStore.shared.settings
        }
        .onChange(of: maxUndoLevels) { _, newValue in
            UndoCoordinator.shared.maxUndoLevels = newValue
        }
    }

    private func saveAutomationSettings() {
        Task {
            await AutomationSettingsStore.shared.update(automationSettings)
        }
    }

    private func handleHTTPServerToggle(enabled: Bool) {
        Task {
            if enabled {
                await HTTPAutomationServer.shared.start()
            } else {
                await HTTPAutomationServer.shared.stop()
            }
        }
    }

    private func chooseLibraryLocation() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            libraryLocation = url.path
        }
        #endif
    }
}

// MARK: - Sources Settings

struct SourcesSettingsTab: View {

    @Environment(SettingsViewModel.self) private var viewModel

    var body: some View {
        List {
            ForEach(viewModel.sourceCredentials) { info in
                SourceCredentialRow(info: info)
            }
        }
        .task {
            await viewModel.loadCredentialStatus()
        }
    }
}

// MARK: - Source Credential Row

struct SourceCredentialRow: View {
    let info: SourceCredentialInfo

    @Environment(SettingsViewModel.self) private var viewModel

    @State private var isExpanded = false
    @State private var apiKeyInput = ""
    @State private var emailInput = ""
    @State private var showError = false
    @State private var errorMessage = ""

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                // API Key input (if required or optional)
                if requiresAPIKey {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("API Key")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack {
                            SecureField("Enter API key", text: $apiKeyInput)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier(AccessibilityID.Settings.Sources.apiKeyField(info.sourceID))

                            Button("Save") {
                                saveAPIKey()
                            }
                            .disabled(apiKeyInput.isEmpty)
                            .accessibilityIdentifier(AccessibilityID.Dialog.Credential.saveButton)
                        }
                    }
                }

                // Email input (if required or optional)
                if requiresEmail {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Email (for API identification)")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack {
                            TextField("Enter email", text: $emailInput)
                                .textFieldStyle(.roundedBorder)

                            Button("Save") {
                                saveEmail()
                            }
                            .disabled(emailInput.isEmpty)
                        }
                    }
                }

                // Registration link
                if let url = info.registrationURL {
                    Link("Get API Key", destination: url)
                        .font(.caption)
                        .help("Get API key from source website")
                }

                // Error message
                if showError {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(.vertical, 8)
        } label: {
            HStack {
                Text(info.sourceName)
                    .font(.headline)

                Spacer()

                statusBadge
            }
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
                .help(statusTooltip)

            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusTooltip: String {
        switch info.status {
        case .valid, .optionalValid:
            return "API key configured"
        case .missing, .invalid:
            return "API key required"
        case .optionalMissing:
            return "Optional - enhances results"
        case .notRequired:
            return "No credentials needed"
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
            return "No credentials needed"
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

// MARK: - Enrichment Settings
//
// `EnrichmentSettingsTab` was DELETED in Stage 6 phase 2, not moved to a MARK
// with no body. It and imbib-iOS's `IOSEnrichmentSettingsView` were the same
// four lines around the same `EnrichmentSettingsView`, so both were replaced by
// one `ImbibEnrichmentSettingsPane` in PublicationManagerCore, registered from
// `ImbibPortableSettingsSections.factories`. It is the only one of imbib's
// sixteen panes for which the two platforms' implementations were genuinely the
// same view — that file's header explains why the other fifteen are not.

// MARK: - Inbox Settings

struct InboxSettingsTab: View {

    @Environment(SettingsViewModel.self) private var viewModel
    @Environment(LibraryManager.self) private var libraryManager

    @State private var mutedItems: [MutedItem] = []
    @State private var dismissedPaperCount: Int = 0
    @State private var selectedMuteType: MuteType = .author
    @State private var newMuteValue: String = ""
    @State private var selectedSaveLibraryID: UUID?

    var body: some View {
        Form {
            Section("Save Destination") {
                Picker("Save to", selection: $selectedSaveLibraryID) {
                    Text("Auto (create Save library)").tag(nil as UUID?)
                    ForEach(availableSaveLibraries, id: \.id) { library in
                        Text(library.name).tag(library.id as UUID?)
                    }
                }
                .onChange(of: selectedSaveLibraryID) { _, newValue in
                    saveSaveLibrarySetting(newValue)
                }

                Text("When you press S on a paper in the Inbox, it will be moved to this library")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Age Limit") {
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
                .help("Hide papers older than this")

                Text("Papers older than this limit (based on when they were added to the Inbox) will be hidden")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Muted Items") {
                if mutedItems.isEmpty {
                    Text("No muted items")
                        .foregroundStyle(.secondary)
                        .italic()
                } else {
                    List {
                        ForEach(groupedMutedItems.keys.sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { muteType in
                            Section(muteType.displayName) {
                                ForEach(groupedMutedItems[muteType] ?? [], id: \.id) { item in
                                    MutedItemRow(item: item) {
                                        unmute(item)
                                    }
                                }
                            }
                        }
                    }
                    .frame(height: 200)
                }
            }

            Section("Add Mute Rule") {
                Picker("Type", selection: $selectedMuteType) {
                    ForEach(MuteType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .help("Choose what type of content to mute")

                HStack {
                    TextField(placeholderText, text: $newMuteValue)
                        .textFieldStyle(.roundedBorder)

                    Button("Add") {
                        addMuteRule()
                    }
                    .disabled(newMuteValue.isEmpty)
                    .help("Add this mute rule")
                }

                Text(helpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Actions") {
                Button("Clear All Muted Items", role: .destructive) {
                    clearAllMutedItems()
                }
                .disabled(mutedItems.isEmpty)
                .help("Remove all mute rules")

                Button("Clear Dismissed Papers (\(dismissedPaperCount))", role: .destructive) {
                    clearDismissedPapers()
                }
                .disabled(dismissedPaperCount == 0)
                .help("Allow previously dismissed papers to reappear in feeds")

                Text("Dismissed papers are hidden from future feed results. Clear this to allow them to reappear.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding(.horizontal)
        .task {
            await viewModel.loadInboxSettings()
            loadMutedItems()
            loadDismissedPaperCount()
            loadSaveLibrarySetting()
        }
        .onReceive(NotificationCenter.default.publisher(for: .syncedSettingsDidChange)) { _ in
            // Reload inbox settings when they change from elsewhere (e.g., sidebar dropdown)
            Task {
                await viewModel.loadInboxSettings()
            }
        }
    }

    // MARK: - Save Library

    /// Libraries available as save destinations (excludes Inbox, Dismissed, system libraries)
    private var availableSaveLibraries: [LibraryModel] {
        libraryManager.libraries.filter { library in
            // TODO: Re-add filters for isDismissedLibrary and isSystemLibrary when those properties are added to LibraryModel
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

    // MARK: - Grouped Items

    private var groupedMutedItems: [MuteType: [MutedItem]] {
        Dictionary(grouping: mutedItems) { item in
            MuteType(rawValue: item.muteType) ?? .author
        }
    }

    // MARK: - Placeholder Text

    private var placeholderText: String {
        switch selectedMuteType {
        case .author:
            return "Author name (e.g., Einstein)"
        case .doi:
            return "DOI (e.g., 10.1234/example)"
        case .bibcode:
            return "Bibcode (e.g., 2024ApJ...123..456E)"
        case .venue:
            return "Venue name (e.g., Nature)"
        case .arxivCategory:
            return "arXiv category (e.g., astro-ph.CO)"
        }
    }

    private var helpText: String {
        switch selectedMuteType {
        case .author:
            return "Papers by this author will be hidden from Inbox feeds"
        case .doi:
            return "This specific paper will be hidden"
        case .bibcode:
            return "This specific paper (by ADS bibcode) will be hidden"
        case .venue:
            return "Papers from journals/conferences containing this name will be hidden"
        case .arxivCategory:
            return "Papers from this arXiv category will be hidden"
        }
    }

    // MARK: - Actions

    private func loadMutedItems() {
        mutedItems = InboxManager.shared.mutedItems
    }

    private func addMuteRule() {
        guard !newMuteValue.isEmpty else { return }
        InboxManager.shared.mute(type: selectedMuteType, value: newMuteValue)
        newMuteValue = ""
        loadMutedItems()
    }

    private func unmute(_ item: MutedItem) {
        InboxManager.shared.unmute(item)
        loadMutedItems()
    }

    private func clearAllMutedItems() {
        InboxManager.shared.clearAllMutedItems()
        loadMutedItems()
    }

    private func loadDismissedPaperCount() {
        dismissedPaperCount = InboxManager.shared.dismissedPaperCount
    }

    private func clearDismissedPapers() {
        InboxManager.shared.clearAllDismissedPapers()
        loadDismissedPaperCount()
    }
}

// MARK: - Muted Item Row

struct MutedItemRow: View {
    let item: MutedItem
    let onUnmute: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.value)
                    .font(.body)

                Text("Added \(item.dateAdded.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                onUnmute()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Unmute")
        }
    }
}

// MARK: - MuteType Display Name

extension MuteType {
    var displayName: String {
        switch self {
        case .author: return "Authors"
        case .doi: return "Papers (DOI)"
        case .bibcode: return "Papers (Bibcode)"
        case .venue: return "Venues"
        case .arxivCategory: return "arXiv Categories"
        }
    }
}

// MARK: - Sync Settings

/// CloudKit sync settings (ADR-0007 Phase 3).
///
/// Replaces the "available after CloudKit reconnection" placeholder that stood
/// here while the graph store had no sync at all. Every row is driven by
/// `SyncStatusModel` — this view computes nothing itself, so it can never
/// disagree with the iOS pane or `GET /api/sync/status`.
struct SyncSettingsTab: View {
    @State private var model = SyncStatusModel.shared

    var body: some View {
        Form {
            Section("iCloud Sync") {
                SyncStatusSection(model: model)
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

            Section("Backup") {
                BackupSettingsSection()
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding(.horizontal)
        // Poll only while the pane is on screen.
        .task {
            model.startAutoRefresh()
        }
        .onDisappear {
            model.stopAutoRefresh()
        }
    }
}

// MARK: - Backup Settings Section

// A backup is a consistent SQLite snapshot of the WHOLE shared impress store
// (imbib + imprint + impel), produced by `impress_core::backup` via
// `LibraryBackupService`. Whole-store rather than per-library: the graph store
// interleaves publications, tags, collections, manuscripts and annotations in
// one item table, and a partial restore is a merge problem, not a copy.
//
// Form gotchas honoured (see apps/imbib/CLAUDE.md): no `List` inside a Form
// Section — the backup rows are a hand-built `VStack` — and no bare
// `TextField` in an `HStack`.

struct BackupSettingsSection: View {
    @State private var backups: [LibraryBackupRecord] = []
    @State private var isWorking = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    // Restore flow
    @State private var pendingRestore: LibraryBackupRecord?
    @State private var restoreReport: LibraryRestoreReport?

    private var syncIsOn: Bool { SyncSettings.isEnabled }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if syncIsOn {
                syncWarning
            }

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

            Divider()

            backupList
        }
        .task { await reload() }
        // Confirmation is deliberately a dialog, not an inline toggle:
        // restore replaces every row in the shared store.
        .confirmationDialog(
            "Restore this backup?",
            isPresented: Binding(
                get: { pendingRestore != nil },
                set: { if !$0 { pendingRestore = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Restore and Replace Library", role: .destructive) {
                if let record = pendingRestore {
                    pendingRestore = nil
                    performRestore(record)
                }
            }
            Button("Cancel", role: .cancel) { pendingRestore = nil }
        } message: {
            Text(restoreWarningText)
        }
        .alert(
            "Library Restored",
            isPresented: Binding(
                get: { restoreReport != nil },
                set: { if !$0 { restoreReport = nil } }
            )
        ) {
            Button("Quit imbib") {
                restoreReport = nil
                NSApplication.shared.terminate(nil)
            }
            Button("Later", role: .cancel) { restoreReport = nil }
        } message: {
            if let report = restoreReport {
                Text(restoreResultText(report))
            }
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Library Backup")
                    .font(.headline)
                if let latest = backups.first {
                    // Split out of the view builder: a single interpolation
                    // with a relative date plus two more values blows past the
                    // type checker's budget.
                    Text(lastBackupSummary(latest))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No backups yet. A backup is a complete, consistent snapshot of your whole impress library — papers, tags, collections, manuscripts and annotations — in a single SQLite file that opens anywhere.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            if isWorking {
                ProgressView().controlSize(.small)
            }

            Button {
                createBackup()
            } label: {
                Label("Back Up Now", systemImage: "arrow.down.doc")
            }
            .disabled(isWorking)
            .help("Snapshot the whole library. Safe to run while you keep working.")

            Button {
                revealBackupsFolder()
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Show the backups folder in Finder")

            Button {
                restoreFromFile()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .disabled(isWorking)
            .help("Restore from a backup file elsewhere on disk…")
        }
    }

    private var syncWarning: some View {
        Label(
            "iCloud sync is on. Restoring rewinds every record, and your other devices would "
                + "overwrite the restored data with what they already hold. Turn sync off in the "
                + "iCloud Sync section above before restoring.",
            systemImage: "exclamationmark.triangle.fill"
        )
        .font(.caption)
        .foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var backupList: some View {
        if backups.isEmpty {
            Text("No backups found")
                .font(.caption)
                .foregroundStyle(.secondary)
                .italic()
        } else {
            Text("Recent Backups")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                ForEach(backups.prefix(5)) { backup in
                    BackupRow(
                        backup: backup,
                        restoreDisabled: isWorking || syncIsOn,
                        onRestore: { pendingRestore = backup },
                        onReveal: { reveal(backup.url) },
                        onDelete: { delete(backup) }
                    )
                }
            }
        }
    }

    /// Built outside the view builder — string concatenation of this size in a
    /// `Text(...)` argument exceeds the type checker's budget.
    private func restoreResultText(_ report: LibraryRestoreReport) -> String {
        let safety: String
        if let path = report.safetySnapshot {
            safety = " to " + URL(fileURLWithPath: path).lastPathComponent
        } else {
            safety = ""
        }
        let counts = "\(report.itemCountAfter) records restored (was \(report.itemCountBefore))."
        let saved = "A snapshot of the replaced library was saved first" + safety + "."
        let relaunch = "Quit and reopen imbib — and any running imprint or impel — so they stop "
            + "showing records from the previous library."
        return counts + "\n\n" + saved + "\n\n" + relaunch
    }

    private func lastBackupSummary(_ record: LibraryBackupRecord) -> String {
        let when = record.manifest.createdAt.formatted(date: .abbreviated, time: .shortened)
        let records = record.manifest.contentItemCount
        return "Last backup \(when) — \(records) records, \(record.manifest.sizeString)"
    }

    private var restoreWarningText: String {
        guard let record = pendingRestore else { return "" }
        return """
            \(record.filename) — \(record.manifest.contentItemCount) records from \
            \(record.manifest.createdAt.formatted(date: .abbreviated, time: .shortened)).

            This replaces your ENTIRE impress library, including imprint manuscripts and impel \
            tasks. Anything added since this backup will be gone. The current library is \
            snapshotted first, so this is reversible.

            imbib must be relaunched afterwards.
            """
    }

    // MARK: - Actions

    private func reload() async {
        let records = await LibraryBackupService.shared.listBackups()
        backups = records
    }

    private func createBackup() {
        isWorking = true
        errorMessage = nil
        statusMessage = nil
        Task {
            do {
                let record = try await LibraryBackupService.shared.createBackup()
                statusMessage = "Backed up \(record.manifest.contentItemCount) records to \(record.filename)"
            } catch {
                errorMessage = error.localizedDescription
            }
            await reload()
            isWorking = false
        }
    }

    private func performRestore(_ record: LibraryBackupRecord) {
        // Capture before the Task: @State is heap-backed and the dialog that
        // set `pendingRestore` has already dismissed (root CLAUDE.md).
        let url = record.url
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

    private func restoreFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose an imbib backup (.impressbackup) to restore."
        panel.directoryURL = LibraryBackupService.backupsDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }

        isWorking = true
        errorMessage = nil
        Task {
            do {
                let inspection = try await LibraryBackupService.shared.inspect(url)
                guard inspection.valid, let manifest = inspection.manifest else {
                    errorMessage = "Not a usable backup: \(inspection.issues.joined(separator: "; "))"
                    isWorking = false
                    return
                }
                isWorking = false
                pendingRestore = LibraryBackupRecord(
                    path: url.path, manifestPath: nil, manifest: manifest)
            } catch {
                errorMessage = error.localizedDescription
                isWorking = false
            }
        }
    }

    private func revealBackupsFolder() {
        let dir = LibraryBackupService.backupsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dir.path)
    }

    private func reveal(_ url: URL) {
        NSWorkspace.shared.selectFile(
            url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
    }
}

// MARK: - Backup Row

private struct BackupRow: View {
    let backup: LibraryBackupRecord
    let restoreDisabled: Bool
    let onRestore: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(backup.manifest.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                Text(detailLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(backup.manifest.sizeString)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Restore", action: onRestore)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(restoreDisabled)
                .help(
                    restoreDisabled
                        ? "Turn iCloud sync off before restoring"
                        : "Replace the library with this backup")

            Button(action: onReveal) { Image(systemName: "folder") }
                .buttonStyle(.borderless)
                .help("Show in Finder")

            Button(action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Delete this backup")
        }
    }

    private var detailLine: String {
        var parts = ["\(backup.manifest.publicationCount) papers"]
        parts.append("\(backup.manifest.contentItemCount) records")
        if let label = backup.manifest.label, !label.isEmpty {
            parts.append("“\(label)”")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Advanced Settings

struct AdvancedSettingsTab: View {

    @Environment(LibraryManager.self) private var libraryManager

    @State private var isOptionKeyPressed = false
    @State private var showingResetConfirmation = false
    @State private var showingResetInProgress = false
    @State private var resetError: String?
    @State private var showingDefaultSetEditor = false
    @State private var explorationRetention: ExplorationRetention = .oneMonth

    var body: some View {
        Form {
            Section("Exploration") {
                Picker("Keep exploration results for", selection: $explorationRetention) {
                    ForEach(ExplorationRetention.allCases, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .onChange(of: explorationRetention) { _, newValue in
                    SyncedSettingsStore.shared.explorationRetention = newValue
                }

                Text("Exploration results (References, Citations, Similar, Co-Reads) will be automatically removed after this period.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Clear All Exploration Results Now") {
                    libraryManager.clearExplorationLibrary()
                }
                .help("Delete all exploration collections immediately")
            }

            // Developer section - visible when Option key is held
            if isOptionKeyPressed {
                Section("Developer") {
                    Button("Reset to First Run...", role: .destructive) {
                        showingResetConfirmation = true
                    }
                    .disabled(showingResetInProgress)
                    .help("Delete all libraries, papers, and settings (preserves API keys)")

                    Button("Edit Default Library Set...") {
                        showingDefaultSetEditor = true
                    }
                    .help("Configure what new users see on first launch")

                    Text("Hold Option key to show these options")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Developer") {
                    Text("Hold the Option key to reveal developer tools")
                        .foregroundStyle(.secondary)
                        .italic()
                }
            }

            Section("Diagnostics") {
                HStack {
                    Text("First Run Status:")
                    Spacer()
                    Text(FirstRunManager.shared.isFirstRun ? "Yes" : "No")
                        .foregroundStyle(.secondary)
                }

                if let error = resetError {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding(.horizontal)
        .onAppear {
            startOptionKeyMonitoring()
            explorationRetention = SyncedSettingsStore.shared.explorationRetention
        }
        .onDisappear {
            stopOptionKeyMonitoring()
        }
        .onReceive(NotificationCenter.default.publisher(for: .syncedSettingsDidChange)) { _ in
            // Reload exploration retention when it changes from elsewhere (e.g., sidebar dropdown)
            explorationRetention = SyncedSettingsStore.shared.explorationRetention
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
            Text("This will delete all libraries, papers, collections, smart searches, and settings from this device AND iCloud. API keys will be preserved.\n\nIMPORTANT: Quit imbib on ALL other devices first, or they may sync data back.\n\nThe app will need to be restarted after the reset.")
        }
        .sheet(isPresented: $showingDefaultSetEditor) {
            DefaultLibrarySetEditor()
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

    // MARK: - Option Key Monitoring

    private var eventMonitor: Any?

    private func startOptionKeyMonitoring() {
        #if os(macOS)
        // Use a local event monitor to detect Option key state
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            isOptionKeyPressed = event.modifierFlags.contains(.option)
            return event
        }
        #endif
    }

    private func stopOptionKeyMonitoring() {
        // Local monitors are automatically removed when the view disappears
    }

    // MARK: - Reset Action

    private func performReset() {
        showingResetInProgress = true
        resetError = nil

        Task {
            do {
                let result = try await FirstRunManager.shared.resetToFirstRun()
                showingResetInProgress = false

                // Show alert with result
                #if os(macOS)
                await MainActor.run {
                    let alert = NSAlert()

                    if result.wasFullySuccessful {
                        alert.messageText = "Reset Prepared"
                        alert.informativeText = "Local settings and files were cleared. Please restart the app to complete the reset."
                        alert.alertStyle = .informational
                    } else {
                        alert.messageText = "Partial Reset"
                        alert.informativeText = "Some local data could not be cleared. Please restart the app and try again if needed."
                        alert.alertStyle = .warning
                    }

                    alert.addButton(withTitle: "Quit Now")
                    alert.addButton(withTitle: "Later")

                    if alert.runModal() == .alertFirstButtonReturn {
                        NSApplication.shared.terminate(nil)
                    }
                }
                #endif
            } catch {
                await MainActor.run {
                    showingResetInProgress = false
                    resetError = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Import/Export Settings

struct ImportExportSettingsTab: View {

    @AppStorage("autoGenerateCiteKeys") private var autoGenerateCiteKeys = true
    @AppStorage("defaultEntryType") private var defaultEntryType = "article"
    @AppStorage("exportPreserveRawBibTeX") private var preserveRawBibTeX = true

    @State private var citeKeySettings = CiteKeyFormatSettings.default
    @State private var showFormatHelp = false

    var body: some View {
        Form {
            Section("Cite Key Format") {
                // Preset picker
                Picker("Format", selection: $citeKeySettings.preset) {
                    ForEach(CiteKeyFormatPreset.allCases, id: \.self) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: citeKeySettings.preset) { _, newValue in
                    Task {
                        await ImportExportSettingsStore.shared.updateCiteKeyFormatPreset(newValue)
                    }
                }

                // Custom format field (only when custom is selected)
                if citeKeySettings.preset == .custom {
                    HStack {
                        TextField("Custom Format", text: $citeKeySettings.customFormat)
                            .textFieldStyle(.roundedBorder)
                            .fontDesign(.monospaced)
                            .onChange(of: citeKeySettings.customFormat) { _, newValue in
                                Task {
                                    await ImportExportSettingsStore.shared.updateCiteKeyCustomFormat(newValue)
                                }
                            }

                        Button {
                            showFormatHelp = true
                        } label: {
                            Image(systemName: "questionmark.circle")
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showFormatHelp) {
                            CiteKeyFormatHelpView()
                        }
                    }
                }

                // Preview
                HStack {
                    Text("Preview:")
                        .foregroundStyle(.secondary)
                    Text(citeKeyPreview)
                        .fontDesign(.monospaced)
                        .foregroundStyle(citeKeySettings.lowercase ? .secondary : .primary)
                }

                // Lowercase toggle
                Toggle("Generate lowercase", isOn: $citeKeySettings.lowercase)
                    .onChange(of: citeKeySettings.lowercase) { _, newValue in
                        Task {
                            await ImportExportSettingsStore.shared.updateCiteKeyLowercase(newValue)
                        }
                    }
            }

            Section("Import") {
                Toggle("Auto-generate cite keys", isOn: $autoGenerateCiteKeys)
                    .accessibilityIdentifier(AccessibilityID.Settings.ImportExport.includeAbstractsToggle)

                Picker("Default entry type", selection: $defaultEntryType) {
                    Text("Article").tag("article")
                    Text("Book").tag("book")
                    Text("InProceedings").tag("inproceedings")
                    Text("Misc").tag("misc")
                }
                .accessibilityIdentifier(AccessibilityID.Settings.ImportExport.exportFormatPicker)

                Text("When enabled, cite keys are generated using the format above for entries with missing or ADS-style cite keys")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Export") {
                Toggle("Preserve original BibTeX formatting", isOn: $preserveRawBibTeX)
                    .accessibilityIdentifier(AccessibilityID.Settings.ImportExport.includeNotesToggle)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding(.horizontal)
        .task {
            citeKeySettings = await ImportExportSettingsStore.shared.citeKeyFormatSettings
        }
    }

    private var citeKeyPreview: String {
        let generator = FormatBasedCiteKeyGenerator(settings: citeKeySettings)
        return generator.preview()
    }
}

// MARK: - E-Ink Settings

struct EInkSettingsTab: View {
    var body: some View {
        EInkSettingsView()
            .padding(.horizontal)
    }
}

// MARK: - Cite Key Format Help View

struct CiteKeyFormatHelpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Format Specifiers")
                .font(.headline)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(citeKeyFormatSpecifiers) { spec in
                        HStack(alignment: .top) {
                            Text(spec.specifier)
                                .fontDesign(.monospaced)
                                .foregroundStyle(.blue)
                                .frame(width: 70, alignment: .leading)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(spec.description)
                                Text(spec.example)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Divider()
                    }
                }
            }

            Text("Example: %a%Y%t produces Smith2024Machine")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 350, height: 350)
    }
}

#Preview {
    SettingsView()
        .environment(SettingsViewModel(
            sourceManager: SourceManager(),
            credentialManager: CredentialManager()
        ))
}
