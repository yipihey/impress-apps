import SwiftUI
import ImpressModalEditing

/// Application settings view
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }
                .accessibilityIdentifier("settings.tabs.general")

            EditorSettingsView()
                .tabItem {
                    Label("Editor", systemImage: "doc.text")
                }
                .accessibilityIdentifier("settings.tabs.editor")

            ImbibSettingsView()
                .tabItem {
                    Label("Citations", systemImage: "books.vertical")
                }
                .accessibilityIdentifier("settings.tabs.imbib")

            DocumentHealthSettingsView()
                .tabItem {
                    Label("Documents", systemImage: "doc.badge.gearshape")
                }
                .accessibilityIdentifier("settings.tabs.documents")

            ExportSettingsView()
                .tabItem {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("settings.tabs.export")

            AccountSettingsView()
                .tabItem {
                    Label("Account", systemImage: "person.circle")
                }
                .accessibilityIdentifier("settings.tabs.account")
        }
        .frame(width: 500, height: 450)
        .accessibilityIdentifier("settings.container")
    }
}

// MARK: - Document Health Settings

/// Settings for document health, validation, and backup
struct DocumentHealthSettingsView: View {
    @AppStorage("validateCRDTOnOpen") private var validateCRDTOnOpen = true
    @AppStorage("autoBackupBeforeMigration") private var autoBackupBeforeMigration = true
    @State private var isValidating = false
    @State private var validationResult: String?

    var body: some View {
        Form {
            Section("Document Validation") {
                Toggle("Validate CRDT state when opening documents", isOn: $validateCRDTOnOpen)
                    .help("Check document integrity when opening to detect corruption early")

                Toggle("Create backup before document migration", isOn: $autoBackupBeforeMigration)
                    .help("Automatically backup documents before schema version upgrades")
            }

            Section("Schema Version") {
                HStack {
                    Text("Current Format Version")
                    Spacer()
                    Text("v\(DocumentSchemaVersion.current.displayString)")
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Minimum Readable Version")
                    Spacer()
                    Text("v\(DocumentSchemaVersion.minimumReadable.displayString)")
                        .foregroundColor(.secondary)
                }
            }

            Section("Diagnostics") {
                Button {
                    // This would validate the currently open document
                    isValidating = true
                    Task {
                        // Simulated validation
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        await MainActor.run {
                            validationResult = "Document is healthy"
                            isValidating = false
                        }
                    }
                } label: {
                    if isValidating {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Validate Current Document")
                    }
                }
                .disabled(isValidating)

                if let result = validationResult {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text(result)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

/// General application settings
struct GeneralSettingsView: View {
    @AppStorage("defaultEditMode") private var defaultEditMode = "split_view"
    @AppStorage("autoSaveInterval") private var autoSaveInterval = 60
    @AppStorage("createBackups") private var createBackups = true

    var body: some View {
        Form {
            Section("Editing") {
                Picker("Default Edit Mode", selection: $defaultEditMode) {
                    Text("Direct PDF").tag("direct_pdf")
                    Text("Split View").tag("split_view")
                    Text("Text Only").tag("text_only")
                }

                Stepper("Auto-save every \(autoSaveInterval) seconds", value: $autoSaveInterval, in: 10...300, step: 10)
            }

            Section("Backup") {
                Toggle("Create automatic backups", isOn: $createBackups)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

/// Editor appearance and behavior settings
struct EditorSettingsView: View {
    @AppStorage("editorFontSize") private var editorFontSize = 14
    @AppStorage("editorFontFamily") private var editorFontFamily = "SF Mono"
    @AppStorage("showLineNumbers") private var showLineNumbers = true
    @AppStorage("highlightCurrentLine") private var highlightCurrentLine = true
    @AppStorage("wrapLines") private var wrapLines = true
    @ObservedObject private var modalSettings = ModalEditingSettings.shared

    var body: some View {
        Form {
            Section("Font") {
                Picker("Font Family", selection: $editorFontFamily) {
                    Text("SF Mono").tag("SF Mono")
                    Text("Menlo").tag("Menlo")
                    Text("Monaco").tag("Monaco")
                    Text("Courier New").tag("Courier New")
                }

                Stepper("Font Size: \(editorFontSize)", value: $editorFontSize, in: 10...24)
            }

            Section("Display") {
                Toggle("Show line numbers", isOn: $showLineNumbers)
                Toggle("Highlight current line", isOn: $highlightCurrentLine)
                Toggle("Wrap long lines", isOn: $wrapLines)
            }

            Section("Modal Editing") {
                Toggle("Enable modal editing", isOn: $modalSettings.isEnabled)
                    .accessibilityIdentifier("settings.editor.modalEditing")

                if modalSettings.isEnabled {
                    Picker("Style", selection: $modalSettings.selectedStyle) {
                        ForEach(EditorStyleIdentifier.allCases, id: \.self) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .accessibilityIdentifier("settings.editor.modalStyle")

                    Toggle("Show mode indicator", isOn: $modalSettings.showModeIndicator)
                        .accessibilityIdentifier("settings.editor.modeIndicator")

                    styleDescription
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    @ViewBuilder
    private var styleDescription: some View {
        switch modalSettings.selectedStyle {
        case .helix:
            Text("Selection-first editing: select text, then act on it")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .vim:
            Text("Verb-object grammar: type operator (d/c/y), then motion")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .emacs:
            Text("Chorded keys: Control and Meta for commands, always insert mode")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Export and LaTeX settings
struct ExportSettingsView: View {
    @AppStorage("defaultExportFormat") private var defaultExportFormat = "latex"
    @AppStorage("defaultJournalTemplate") private var defaultJournalTemplate = "generic"
    @AppStorage("includeBibliography") private var includeBibliography = true
    @State private var showingTemplateBrowser = false
    @StateObject private var templateService = TemplateService.shared

    var body: some View {
        Form {
            Section("Default Format") {
                Picker("Export Format", selection: $defaultExportFormat) {
                    Text("LaTeX").tag("latex")
                    Text("PDF").tag("pdf")
                    Text("HTML").tag("html")
                    Text("Markdown").tag("markdown")
                }
            }

            Section("Templates") {
                Picker("Default Template", selection: $defaultJournalTemplate) {
                    ForEach(templateService.templates) { template in
                        Text(template.name).tag(template.id)
                    }
                }

                Button("Manage Templates...") {
                    showingTemplateBrowser = true
                }
                .accessibilityIdentifier("settings.export.manageTemplates")
            }

            Section("Bibliography") {
                Toggle("Include bibliography file", isOn: $includeBibliography)
            }
        }
        .formStyle(.grouped)
        .padding()
        .sheet(isPresented: $showingTemplateBrowser) {
            TemplateBrowserView()
        }
    }
}

/// Account and sync settings
struct AccountSettingsView: View {
    @State private var isSignedIn = false
    @State private var syncEnabled = true

    var body: some View {
        Form {
            Section("iCloud") {
                if isSignedIn {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Signed in with iCloud")
                    }

                    Toggle("Sync documents", isOn: $syncEnabled)
                } else {
                    Text("Sign in to iCloud in System Settings to enable sync")
                        .foregroundColor(.secondary)
                }
            }

            Section("Collaboration") {
                Text("Real-time collaboration uses CloudKit")
                    .foregroundColor(.secondary)

                Link("Learn more about collaboration", destination: URL(string: "https://imbib.com/imprint/collaboration")!)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            // Check iCloud status
            isSignedIn = FileManager.default.ubiquityIdentityToken != nil
        }
    }
}

#Preview {
    SettingsView()
}
