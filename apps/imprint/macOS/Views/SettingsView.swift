//
//  SettingsView.swift
//  imprint
//
//  Stage 6 phase 1: this file used to BE imprint's settings surface — a
//  762-line macOS `TabView` whose body was the only place in the codebase that
//  knew imprint has thirteen preference panes, in that order, with those
//  labels. That made the list unreadable to iOS (which therefore shipped none)
//  and unreadable to tests (which therefore asserted nothing about it).
//
//  Now the list is DATA (`AppSettingsConfiguration.imprint`, PMC), the frame is
//  a shared renderer (`MacSettingsSceneContent`), and this file holds what is
//  genuinely imprint-and-macOS: three panes that name macOS-target services,
//  and the registration table that maps section ids to every imprint pane.
//
//  Four panes LEFT for `Shared/Settings/ImprintSettingsPanes.swift` (General,
//  Editor, Documents, Account) because nothing in them was macOS-specific;
//  Appearance and Spotlight left for the chassis builtins, which is where a
//  segmented System/Light/Dark picker and a `Form { SpotlightSettingsSection() }`
//  belong. `LaTeXSettingsView`, `AITasksSettingsView` and `ImbibSettingsView`
//  are UNTOUCHED in their own files — they are registered, not rewritten. That
//  is the point: an app-specific pane stays app-owned and never gets pasted
//  into a monolithic view.
//

import ImpressGit
import ImpressAI
import SwiftUI
import PublicationManagerCore

/// imprint's macOS Settings scene content — the shared renderer over imprint's
/// declaration. Every tab, its order, label, symbol and accessibility
/// identifier come from `AppSettingsConfiguration.imprint`.
struct SettingsView: View {
    var body: some View {
        MacSettingsSceneContent(configuration: .imprint)
            .environment(\.settingsSectionRegistry, ImprintSettingsSections.registry)
    }
}

// MARK: - Registrations (macOS-only panes)

extension ImprintSettingsSections {

    /// The imprint panes that exist only on macOS, mapped to their section ids.
    ///
    /// Six of the nine macOS-only sections come from files this refactor never
    /// opened — `LaTeXSettingsView`, `AITasksSettingsView`, `ImbibSettingsView`
    /// and `GitSettingsSection` (the last from ImpressGit, already a shared
    /// COMPONENT, wrapped here rather than edited). A factory is a reference,
    /// not a rewrite.
    static let platformFactories: [SettingsSectionFactory] = [
        SettingsSectionFactory(section: .ai) { AIAssistantSettingsView() },
        SettingsSectionFactory(section: .aiTasks) { AITasksSettingsView() },
        SettingsSectionFactory(section: .imbib) { ImbibSettingsView() },
        SettingsSectionFactory(section: .latex) { LaTeXSettingsView() },
        SettingsSectionFactory(section: .export) { ExportSettingsView() },
        SettingsSectionFactory(section: .automation) { AutomationSettingsView() },
        // ImpressGit ships `GitSettingsSection` as its own `Form`, so it is NOT
        // wrapped in `SettingsForm` — doing so would nest two Forms. PMC does
        // not depend on ImpressGit, which is the other reason this stays an
        // imprint registration rather than a chassis builtin.
        SettingsSectionFactory(section: .git) { GitSettingsSection() },
    ]
}

// MARK: - Export Settings

/// Export and LaTeX settings.
///
/// macOS-only because `TemplateService` and the `TemplateBrowserView` sheet it
/// presents live in imprint's macOS target.
struct ExportSettingsView: View {
    @AppStorage("defaultExportFormat") private var defaultExportFormat = "latex"
    @AppStorage("defaultJournalTemplate") private var defaultJournalTemplate = "generic"
    @AppStorage("includeBibliography") private var includeBibliography = true
    @State private var showingTemplateBrowser = false
    private var templateService = TemplateService.shared

    var body: some View {
        SettingsForm {
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
        .sheet(isPresented: $showingTemplateBrowser) {
            TemplateBrowserView()
        }
    }
}

// MARK: - Automation Settings

/// Automation and API settings.
///
/// macOS-only, and the descriptor says WHY as a capability rather than a
/// platform accident: this pane drives an in-process HTTP server
/// (`SettingsRequirement.httpAutomation`), which needs the
/// `com.apple.security.network.server` entitlement iOS does not grant. The
/// chassis's generic `AutomationSettingsSection` (ImpressAutomation) is a
/// toggle + port and nothing else; imprint's pane additionally owns the server
/// lifecycle, live status, the MCP config block and the endpoint reference, so
/// it stays imprint-registered rather than being flattened into the shared
/// component. Unchanged from the version that shipped.
struct AutomationSettingsView: View {
    @AppStorage("httpAutomationEnabled") private var httpAutomationEnabled = true
    // Default from THE sibling-app table (ImpressKit), not a literal.
    @AppStorage("httpAutomationPort") private var httpAutomationPort = Int(ImprintHTTPServer.defaultPort)
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
        SettingsForm {
            Section("HTTP API Server") {
                Toggle("Enable HTTP API", isOn: $httpAutomationEnabled)
                    .onChange(of: httpAutomationEnabled) { _, enabled in
                        Task {
                            if enabled {
                                await ImprintHTTPServer.shared.start()
                            } else {
                                await ImprintHTTPServer.shared.stop()
                            }
                            isServerRunning = await ImprintHTTPServer.shared.running
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
                                    await ImprintHTTPServer.shared.restart()
                                    isServerRunning = await ImprintHTTPServer.shared.running
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
        .onAppear {
            Task {
                isServerRunning = await ImprintHTTPServer.shared.running
            }
        }
    }
}

// MARK: - AI Assistant Settings

/// Settings for AI writing assistance features.
///
/// macOS-only: `AIAssistantService` and `InlineCompletionService` live in
/// imprint's macOS target, and the API-key editor writes to the macOS keychain.
struct AIAssistantSettingsView: View {
    private let inlineService = InlineCompletionService.shared

    var body: some View {
        AISettingsView {
            Section("Inline Completions") {
                Toggle("Enable Tab completion", isOn: Binding(
                    get: { inlineService.isEnabled },
                    set: { inlineService.isEnabled = $0 }
                ))
                .accessibilityIdentifier("settings.ai.inlineEnabled")
                .help("Show AI suggestions as you type. Press Tab to accept.")

                if inlineService.isEnabled {
                    Stepper(
                        "Minimum characters: \(inlineService.minTriggerLength)",
                        value: Binding(
                            get: { inlineService.minTriggerLength },
                            set: { inlineService.minTriggerLength = $0 }
                        ),
                        in: 5...50
                    )
                    .help("Number of characters before triggering suggestions")

                    Stepper(
                        "Debounce delay: \(inlineService.debounceDelay)ms",
                        value: Binding(
                            get: { inlineService.debounceDelay },
                            set: { inlineService.debounceDelay = $0 }
                        ),
                        in: 200...2000,
                        step: 100
                    )
                    .help("Wait time after typing before requesting completion")
                }

                HStack {
                    Image(systemName: "keyboard")
                        .foregroundStyle(.secondary)
                    Text("Press Tab to accept, Escape to dismiss")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Context Menu Actions") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Select text in the editor and right-click for AI actions:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 16) {
                        actionItem(icon: "pencil", label: "Rewrite")
                        actionItem(icon: "text.quote", label: "Cite")
                        actionItem(icon: "lightbulb", label: "Explain")
                    }

                    HStack(spacing: 16) {
                        actionItem(icon: "list.bullet", label: "Structure")
                        actionItem(icon: "checkmark.circle", label: "Review")
                    }
                }
            }

            Section("Citation Suggestions") {
                Text("When writing, the AI will suggest relevant citations from your imbib library based on context.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Image(systemName: "books.vertical")
                        .foregroundStyle(.orange)
                    Text("Requires imbib to be running with HTTP API enabled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func actionItem(icon: String, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
            Text(label)
                .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
    }
}

#Preview {
    SettingsView()
}
