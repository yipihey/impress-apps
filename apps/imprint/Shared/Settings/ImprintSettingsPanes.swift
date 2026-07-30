//
//  ImprintSettingsPanes.swift
//  imprint
//
//  Stage 6 phase 1: imprint's CROSS-PLATFORM settings panes.
//
//  These four panes (General, Editor, Documents, Account) were verbatim
//  members of `macOS/Views/SettingsView.swift` and therefore existed only on
//  macOS — not because anything in them is macOS-specific (they are
//  `@AppStorage` over plain SwiftUI `Form`s) but because the FILE they lived in
//  was in the macOS target. `Shared/` is compiled by both the `imprint` and
//  `imprint-iOS` targets, so moving them here is the entire iOS port.
//
//  NOT gated, on purpose: gating this file would recreate the problem.
//
//  PERSISTENCE IS UNCHANGED. Every `@AppStorage` key below is byte-identical to
//  the one the macOS pane used before the move — `defaultEditMode`,
//  `autoSaveInterval`, `createBackups`, `imprint.autoCompile`,
//  `imprint.compileDebounceMs`, `imprint.previewFormat`, `editorFontSize`,
//  `editorFontFamily`, `showLineNumbers`, `highlightCurrentLine`, `wrapLines`,
//  `validateCRDTOnOpen`, `autoBackupBeforeMigration` — plus
//  `ModalEditingSettings`' own `modalEditing.*` keys, which it owns and this
//  file only reads through. A settings reframe that renamed a key would silently
//  reset every existing user's preferences; `ImprintSettingsPersistenceTests`
//  pins the list.
//
//  The one deliberate difference from the originals: `Form { … }
//  .formStyle(.grouped).padding()` became `SettingsForm { … }`, the chassis's
//  pane chrome, because the `.padding()` is right for a macOS Settings tab and
//  wrong for an iOS pushed screen. Controls, sections, order, help text and
//  accessibility identifiers are untouched.
//

import SwiftUI
import ImpressHelixCore
import PublicationManagerCore

// MARK: - General

/// General application settings.
struct GeneralSettingsView: View {
    @AppStorage("defaultEditMode") private var defaultEditMode = "split_view"
    @AppStorage("autoSaveInterval") private var autoSaveInterval = 60
    @AppStorage("createBackups") private var createBackups = true
    @AppStorage("imprint.autoCompile") private var autoCompileEnabled = true
    @AppStorage("imprint.compileDebounceMs") private var compileDebounceMs = 300
    @AppStorage("imprint.previewFormat") private var previewFormat = "pdf"

    var body: some View {
        SettingsForm {
            Section("Editing") {
                Picker("Default Edit Mode", selection: $defaultEditMode) {
                    Text("Direct PDF").tag("direct_pdf")
                    Text("Split View").tag("split_view")
                    Text("Text Only").tag("text_only")
                }

                Stepper(
                    "Auto-save every \(autoSaveInterval) seconds",
                    value: $autoSaveInterval, in: 10...300, step: 10)
            }

            Section("Live Preview") {
                Toggle("Live preview", isOn: $autoCompileEnabled)
                    .help("Automatically recompile as you type")
                    .accessibilityIdentifier("settings.general.livePreview")

                if autoCompileEnabled {
                    Stepper(
                        "Update delay: \(compileDebounceMs)ms",
                        value: $compileDebounceMs,
                        in: 200...2000,
                        step: 100
                    )
                    .help("Milliseconds to wait after typing before recompiling. Lower = more responsive, higher = less CPU usage.")
                }

                Picker("Preview format", selection: $previewFormat) {
                    Text("PDF").tag("pdf")
                    Text("SVG (faster)").tag("svg")
                }
                .help("SVG renders individual pages for faster updates on long documents. PDF is used for Direct PDF mode regardless of this setting.")
            }

            Section("Backup") {
                Toggle("Create automatic backups", isOn: $createBackups)
                    .accessibilityIdentifier("settings.general.createBackups")
            }
        }
    }
}

// MARK: - Editor

/// Editor appearance and behavior settings.
struct EditorSettingsView: View {
    @AppStorage("editorFontSize") private var editorFontSize = 14
    @AppStorage("editorFontFamily") private var editorFontFamily = "SF Mono"
    @AppStorage("showLineNumbers") private var showLineNumbers = true
    @AppStorage("highlightCurrentLine") private var highlightCurrentLine = true
    @AppStorage("wrapLines") private var wrapLines = true
    @Bindable private var modalSettings = ModalEditingSettings.shared

    var body: some View {
        SettingsForm {
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
                    .accessibilityIdentifier("settings.editor.showLineNumbers")
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

// MARK: - Documents

/// Settings for document health, validation, and backup.
struct DocumentHealthSettingsView: View {
    @AppStorage("validateCRDTOnOpen") private var validateCRDTOnOpen = true
    @AppStorage("autoBackupBeforeMigration") private var autoBackupBeforeMigration = true
    @State private var isValidating = false
    @State private var validationResult: String?

    var body: some View {
        SettingsForm {
            Section("Document Validation") {
                Toggle("Validate CRDT state when opening documents", isOn: $validateCRDTOnOpen)
                    .help("Check document integrity when opening to detect corruption early")
                    .accessibilityIdentifier("settings.documents.validateCRDT")

                Toggle("Create backup before document migration", isOn: $autoBackupBeforeMigration)
                    .help("Automatically backup documents before schema version upgrades")
            }

            Section("Schema Version") {
                HStack {
                    Text("Current Format Version")
                    Spacer()
                    Text("v\(DocumentSchemaVersion.current.displayString)")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Minimum Readable Version")
                    Spacer()
                    Text("v\(DocumentSchemaVersion.minimumReadable.displayString)")
                        .foregroundStyle(.secondary)
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
                            .foregroundStyle(.green)
                        Text(result)
                    }
                }
            }
        }
    }
}

// MARK: - Account

/// Account and sync settings.
struct AccountSettingsView: View {
    @State private var isSignedIn = false

    var body: some View {
        SettingsForm {
            Section("iCloud") {
                if isSignedIn {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Signed in with iCloud")
                    }
                } else {
                    HStack {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(.secondary)
                        Text("Not signed in to iCloud")
                    }
                    Text("Sign in to iCloud in System Settings if you want to sync the impress store across devices.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Sync") {
                Text("Manuscripts live in the shared impress store. Multi-device sync of that store is a suite-wide setting configured in imbib — imprint has no separate sync of its own.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Text("Manuscript bodies over 1 MB and PDF attachments are stored outside the synced store and do not travel between devices.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            // Check iCloud status
            isSignedIn = FileManager.default.ubiquityIdentityToken != nil
        }
    }
}
