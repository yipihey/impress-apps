//
//  SettingsView.swift
//  impel
//
//  Settings tabs (general / AI / counsel).
//  Moved verbatim from ContentView.swift (C0 mechanical decomposition,
//  Stage 2-C of the GUI unification) — no renames, no signature changes.
//

//  Stage 6 phase 2 (declarative chassis): the three tabs are declared as
//  `AppSettingsConfiguration.impel` in PublicationManagerCore; this file
//  contributes the factories and the scene host. The three panes below are
//  untouched.
//
//  impel adopts NO chassis builtin, and phase 2 deliberately does not give it
//  one. It has no Appearance tab and no Spotlight tab, and growing an app's
//  settings surface is a product change rather than a reframe. What the
//  declaration does buy impel is that the absence is now VISIBLE: its three panes
//  are named in data that a test can read, so "impel has no appearance
//  preference" is a statement in the repo instead of a thing nobody noticed.
//
//  Adjacent finding recorded while inventorying, NOT fixed here because it is
//  outside a settings reframe: `ImpelHTTPServer` reads `httpAutomationEnabled`
//  and `httpAutomationPort` from `UserDefaults`, and no impel settings pane
//  writes either — impel's HTTP server is unconfigurable from its GUI. Giving
//  impel an `automation` descriptor would fix that, but it would also add a
//  fourth tab, so it belongs to whoever owns that behaviour.

import SwiftUI
import ImpelCore
import ImpelMail
import CounselEngine
import ImpressKeyboard
import ImpressKit
import PublicationManagerCore

// MARK: - Settings View

struct SettingsView: View {
    var body: some View {
        // `.fixed`: impel shipped `.frame(width: 550, height: 560)`, a pinned
        // size rather than a floor.
        MacSettingsSceneContent.fixed(
            configuration: .impel, width: 550, height: 560)
            .environment(\.settingsSectionRegistry, ImpelSettingsSections.registry)
    }
}

// MARK: - Factories

/// impel's settings registrations.
///
/// `mailGatewayState` is NOT passed here and must not be: `ImpelAISettingsTab` and
/// `CounselSettingsTab` take it as an `@EnvironmentObject`, and `ImpelApp` injects
/// it at the `Settings { }` scene. Factories build their panes inside that scene's
/// view tree, so the object reaches them through the environment exactly as
/// before — which is the property that makes a factory a drop-in for a `TabView`
/// child rather than a call site that has to re-plumb dependencies.
enum ImpelSettingsSections {

    static let factories: [SettingsSectionFactory] = [
        SettingsSectionFactory(section: .general) { GeneralSettingsTab() },
        SettingsSectionFactory(section: .ai) { ImpelAISettingsTab() },
        SettingsSectionFactory(section: .counsel) { CounselSettingsTab() },
    ]

    static let registry: SettingsSectionRegistry =
        SettingsSectionRegistry.builtin.composing(factories)
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
