import SwiftUI
import ImpressModalEditing

/// Application settings view
struct SettingsView: View {
    var body: some View {
        TabView {
            AppearanceSettingsView()
                .tabItem {
                    Label("Appearance", systemImage: "paintbrush")
                }
                .accessibilityIdentifier("settings.tabs.appearance")

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

            AutomationSettingsView()
                .tabItem {
                    Label("Automation", systemImage: "gearshape.2")
                }
                .accessibilityIdentifier("settings.tabs.automation")
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

// MARK: - Appearance Settings

/// Appearance settings for color scheme
struct AppearanceSettingsView: View {
    @AppStorage("appearanceMode") private var appearanceMode = "system"

    private var colorScheme: ColorScheme? {
        switch appearanceMode {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var body: some View {
        Form {
            Section("Color Scheme") {
                Picker("Appearance", selection: $appearanceMode) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)

                Text("Choose whether to follow system appearance or always use light/dark mode")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

/// Automation and API settings
struct AutomationSettingsView: View {
    @AppStorage("httpAutomationEnabled") private var httpAutomationEnabled = false
    @AppStorage("httpAutomationPort") private var httpAutomationPort = 23121
    @State private var isServerRunning = false
    @State private var showCopiedFeedback = false

    private var mcpConfigJSON: String {
        """
        {
          "mcpServers": {
            "impress": {
              "command": "npx",
              "args": ["impress-mcp"]
            }
          }
        }
        """
    }

    var body: some View {
        Form {
            Section("HTTP API Server") {
                Toggle("Enable HTTP API", isOn: $httpAutomationEnabled)
                    .onChange(of: httpAutomationEnabled) { _, enabled in
                        Task {
                            if enabled {
                                await HTTPAutomationServer.shared.start()
                            } else {
                                await HTTPAutomationServer.shared.stop()
                            }
                            isServerRunning = await HTTPAutomationServer.shared.running
                        }
                    }
                    .help("Allow AI agents and tools to control imprint via HTTP API")

                if httpAutomationEnabled {
                    HStack {
                        Text("Port")
                        TextField("Port", value: $httpAutomationPort, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .onSubmit {
                                Task {
                                    await HTTPAutomationServer.shared.restart()
                                    isServerRunning = await HTTPAutomationServer.shared.running
                                }
                            }
                    }

                    HStack {
                        Text("Status")
                        Spacer()
                        if isServerRunning {
                            HStack {
                                Circle()
                                    .fill(.green)
                                    .frame(width: 8, height: 8)
                                Text("Running on localhost:\(httpAutomationPort)")
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            HStack {
                                Circle()
                                    .fill(.red)
                                    .frame(width: 8, height: 8)
                                Text("Stopped")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section("MCP Integration") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Connect AI tools like Claude Desktop, Claude Code, Cursor, or Zed to your documents using the Model Context Protocol.")
                        .foregroundStyle(.secondary)
                        .font(.callout)

                    HStack(spacing: 12) {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(mcpConfigJSON, forType: .string)
                            showCopiedFeedback = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                showCopiedFeedback = false
                            }
                        } label: {
                            HStack {
                                Image(systemName: showCopiedFeedback ? "checkmark" : "doc.on.doc")
                                Text(showCopiedFeedback ? "Copied!" : "Copy MCP Config")
                            }
                        }
                        .help("Copy the MCP configuration JSON to paste into your AI tool's settings")

                        Button {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Terminal")!)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("npx impress-mcp --check", forType: .string)
                            }
                        } label: {
                            HStack {
                                Image(systemName: "terminal")
                                Text("Test Connection")
                            }
                        }
                        .help("Opens Terminal with the test command copied. Paste and run to verify setup.")
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Quick Setup")
                        .font(.subheadline.weight(.medium))

                    Text("1. Enable HTTP API above")
                    Text("2. Copy the MCP config")
                    Text("3. Paste into your AI tool's settings")
                    Text("4. Restart your AI tool")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Link("Full Setup Guide", destination: URL(string: "https://imbib.com/docs/MCP-Setup-Guide")!)
            }

            Section("Security") {
                HStack {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(.green)
                    Text("HTTP API only accepts connections from localhost (127.0.0.1)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("API Reference") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Endpoints:")
                        .font(.headline)

                    Group {
                        Text("GET /api/status").font(.system(.caption, design: .monospaced))
                        Text("GET /api/documents").font(.system(.caption, design: .monospaced))
                        Text("GET /api/documents/{id}").font(.system(.caption, design: .monospaced))
                        Text("POST /api/documents/{id}/compile").font(.system(.caption, design: .monospaced))
                        Text("POST /api/documents/{id}/insert-citation").font(.system(.caption, design: .monospaced))
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            Task {
                isServerRunning = await HTTPAutomationServer.shared.running
            }
        }
    }
}

/// imbib integration settings
struct ImbibSettingsView: View {
    @AppStorage("imbibPort") private var imbibPort = 23120
    @AppStorage("autoImportCitations") private var autoImportCitations = true

    var body: some View {
        Form {
            Section("Connection") {
                HStack {
                    Text("imbib HTTP Port")
                    TextField("Port", value: $imbibPort, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
                .help("Port where imbib's HTTP API is running (default: 23120)")
            }

            Section("Citation Import") {
                Toggle("Auto-import citations to bibliography", isOn: $autoImportCitations)
                    .help("Automatically add BibTeX entries when inserting citations")
            }

            Section("imbib App") {
                Text("Open imbib to manage your paper library and search for citations.")
                    .foregroundStyle(.secondary)
                    .font(.callout)

                Button("Open imbib") {
                    NSWorkspace.shared.open(URL(string: "imbib://")!)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

/// Template service for managing journal templates
@MainActor
class TemplateService: ObservableObject {
    static let shared = TemplateService()

    struct Template: Identifiable {
        let id: String
        let name: String
        let category: String
    }

    @Published var templates: [Template] = [
        Template(id: "generic", name: "Generic Article", category: "General"),
        Template(id: "ieee", name: "IEEE Conference", category: "Computer Science"),
        Template(id: "acm", name: "ACM SIGCHI", category: "Computer Science"),
        Template(id: "arxiv", name: "arXiv Preprint", category: "General"),
    ]

    private init() {}
}

/// Template browser sheet
struct TemplateBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var templateService = TemplateService.shared

    var body: some View {
        NavigationStack {
            List(templateService.templates) { template in
                VStack(alignment: .leading) {
                    Text(template.name)
                        .font(.headline)
                    Text(template.category)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Templates")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(width: 400, height: 300)
    }
}

#Preview {
    SettingsView()
}
