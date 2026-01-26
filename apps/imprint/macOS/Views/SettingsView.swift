import SwiftUI

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
        .frame(width: 500, height: 400)
        .accessibilityIdentifier("settings.container")
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
        }
        .formStyle(.grouped)
        .padding()
    }
}

/// Export and LaTeX settings
struct ExportSettingsView: View {
    @AppStorage("defaultExportFormat") private var defaultExportFormat = "latex"
    @AppStorage("defaultJournalTemplate") private var defaultJournalTemplate = "generic"
    @AppStorage("includeBibliography") private var includeBibliography = true

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

            Section("LaTeX") {
                Picker("Journal Template", selection: $defaultJournalTemplate) {
                    Text("Generic Article").tag("generic")
                    Text("MNRAS").tag("mnras")
                    Text("ApJ").tag("apj")
                    Text("A&A").tag("aa")
                    Text("PhysRevD").tag("physrevd")
                    Text("JCAP").tag("jcap")
                }

                Toggle("Include bibliography file", isOn: $includeBibliography)
            }
        }
        .formStyle(.grouped)
        .padding()
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
