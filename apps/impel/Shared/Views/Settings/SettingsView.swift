//
//  SettingsView.swift
//  impel
//
//  Settings tabs (general / AI / counsel).
//  Moved verbatim from ContentView.swift (C0 mechanical decomposition,
//  Stage 2-C of the GUI unification) — no renames, no signature changes.
//

import SwiftUI
import ImpelCore
import ImpelMail
import CounselEngine
import ImpressKeyboard
import ImpressKit

// MARK: - Settings View

struct SettingsView: View {
    private enum SettingsTab: Hashable {
        case general
        case ai
        case counsel
    }

    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsTab()
                .tabItem {
                    Label("General", systemImage: "gear")
                }
                .tag(SettingsTab.general)

            ImpelAISettingsTab()
                .tabItem {
                    Label("AI", systemImage: "brain")
                }
                .tag(SettingsTab.ai)

            CounselSettingsTab()
                .tabItem {
                    Label("Counsel", systemImage: "envelope")
                }
                .tag(SettingsTab.counsel)
        }
        .frame(width: 550, height: 560)
    }
}

struct GeneralSettingsTab: View {
    @AppStorage("serverURL") private var serverURL = "http://localhost:3000"
    @AppStorage("refreshInterval") private var refreshInterval = 2.0

    var body: some View {
        Form {
            Section("Server") {
                TextField("Server URL", text: $serverURL)
            }

            Section("Display") {
                Slider(value: $refreshInterval, in: 1...10, step: 1) {
                    Text("Refresh Interval: \(Int(refreshInterval))s")
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ImpelAISettingsTab: View {
    @EnvironmentObject var mailGateway: MailGatewayState
    @AppStorage("counselModel") private var modelName = ""
    @AppStorage("counselSystemPrompt") private var systemPrompt = ""
    @State private var engineAvailable = false

    var body: some View {
        Form {
            Section("Anthropic API") {
                HStack {
                    Text("Status")
                    Spacer()
                    if engineAvailable {
                        Label("Ready", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Not Configured", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                }

                Text("Counsel uses the Anthropic API directly for AI responses. Configure your API key in Settings > AI to enable counsel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Model") {
                TextField("Model (default: sonnet)", text: $modelName)
                Text("The model identifier for the Anthropic API. Leave blank for the default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("System Prompt") {
                TextEditor(text: $systemPrompt)
                    .frame(minHeight: 80)
                    .font(.system(.body, design: .monospaced))
                Text("Custom base system prompt for counsel. Leave blank to use the built-in research assistant prompt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            engineAvailable = mailGateway.counselEngine != nil
        }
    }
}

struct CounselSettingsTab: View {
    @EnvironmentObject var mailGateway: MailGatewayState
    @AppStorage("counselGatewayEnabled") private var counselEnabled = true
    @AppStorage("counselSMTPPort") private var smtpPort = 2525
    @AppStorage("counselIMAPPort") private var imapPort = 1143
    @AppStorage("counselMaxTurns") private var maxTurns = 15
    @AppStorage("counselPersistenceEnabled") private var persistenceEnabled = true

    var body: some View {
        Form {
            Section("Mail Gateway") {
                Toggle("Enable Mail Gateway", isOn: $counselEnabled)
            }

            Section("Ports") {
                TextField("SMTP Port", value: $smtpPort, format: IntegerFormatStyle<Int>().grouping(.never))
                TextField("IMAP Port", value: $imapPort, format: IntegerFormatStyle<Int>().grouping(.never))
            }

            Section("Agent Loop") {
                Stepper("Max Turns: \(maxTurns)", value: $maxTurns, in: 1...50)
                Text("Counsel uses the Anthropic API directly with tool use via HTTP bridges to sibling apps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Toggle("Persist Conversations", isOn: $persistenceEnabled)
                Text("When disabled, counsel still processes requests but does not store conversations, messages, or tool executions in the local database. Replies include List-Id and X-Counsel headers for auto-filing in your email client.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
