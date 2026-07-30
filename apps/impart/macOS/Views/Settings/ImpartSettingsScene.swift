//
//  ImpartSettingsScene.swift
//  impart (macOS)
//
//  Stage 4c: EXTRACTED VERBATIM from the classic `ContentView.swift`, which
//  declared impart's whole Settings scene alongside the three-column mail window
//  it is unrelated to. That co-location is why deleting the classic window had to
//  start here: the `Settings { SettingsView() }` scene, the registry that wave 3
//  migrated onto `AppSettingsConfiguration.impart`, and four settings panes all
//  lived in the file being deleted.
//
//  Nothing below changed. The wave-3 declarative wiring
//  (`MacSettingsSceneContent.fixed(configuration: .impart, …)` +
//  `\.settingsSectionRegistry`) is preserved exactly, including both documented
//  hand-rolled clones and the reasons they stay.
//

import MessageManagerCore
import PublicationManagerCore
import SwiftUI

// MARK: - Settings View

/// Application settings.
///
/// Stage 6 phase 2 (declarative chassis): the six tabs are declared as
/// `AppSettingsConfiguration.impart` in PublicationManagerCore; this struct is the
/// scene host and `ImpartSettingsSections` below holds the factories. The panes
/// themselves are untouched.
struct SettingsView: View {
    var body: some View {
        // `.fixed`: impart shipped `.frame(width: 550, height: 500)`, a pinned
        // size rather than a floor.
        MacSettingsSceneContent.fixed(
            configuration: .impart, width: 550, height: 500)
            .environment(\.settingsSectionRegistry, ImpartSettingsSections.registry)
    }
}

// MARK: - Settings factories

/// impart's settings registrations.
///
/// **Spotlight becomes the chassis builtin** — impart's tab body was the same
/// `Form { SpotlightSettingsSection() }.formStyle(.grouped)` wrapper implore and
/// imprint had each written independently, which is precisely the "no app should
/// author this for itself" bar a builtin has to clear.
///
/// **Two hand-rolled clones of shared components are left in place on purpose,
/// and both are recorded rather than silently migrated:**
///
///  * `GeneralSettingsView`'s appearance `Picker` duplicates
///    `ImpressTheme.AppearanceSettingsSection` over the same `appearanceMode` key
///    with the same three `system`/`light`/`dark` tags. It is not swapped for the
///    `appearance` BUILTIN because it is not a whole tab — it is one of two
///    pickers inside General, and promoting it would move a control between tabs.
///  * `AutomationSettingsView` duplicates `ImpressAutomation.AutomationSettingsSection`
///    but has NO `logRequests` row. Swapping in the shared section would ADD a
///    control to a surface the migration promises not to change.
///
/// Both are real alignments and both are phase-3 product decisions. The value of
/// the reframe here is that they are now stated next to the declaration instead of
/// being invisible in a `TabView` body.
enum ImpartSettingsSections {

    static let factories: [SettingsSectionFactory] = [
        SettingsSectionFactory(section: .accounts) { AccountsSettingsView() },
        SettingsSectionFactory(section: .ai) { AISettingsTab() },
        SettingsSectionFactory(section: .general) { GeneralSettingsView() },
        SettingsSectionFactory(section: .keyboard) { KeyboardSettingsView() },
        SettingsSectionFactory(section: .automation) { AutomationSettingsView() },
    ]

    static let registry: SettingsSectionRegistry =
        SettingsSectionRegistry.builtin.composing(factories)
}

/// Account settings.
///
/// Stage 4c note, recorded rather than fixed: this pane is placeholder TEXT, and
/// `AccountSetupView` (`apps/impart/Shared/Views/AccountSetupView.swift`) — a
/// complete IMAP/SMTP setup flow — is referenced by NOTHING in the repo. There is
/// therefore no way to add an email account from the GUI, on either window. That
/// predates the chassis by a long way and is why the classic window's mail lists
/// were always empty; presenting `AccountSetupView` from here is the obvious next
/// step, and a product decision rather than part of a window cutover.
struct AccountsSettingsView: View {
    var body: some View {
        VStack {
            Text("Account Settings")
                .font(.headline)
            Text("Configure email accounts here.")
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

struct GeneralSettingsView: View {
    @AppStorage("appearanceMode") private var appearanceMode = "system"
    @AppStorage("defaultViewMode") private var defaultViewMode = "email"

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearanceMode) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            .pickerStyle(.segmented)

            Picker("Default View", selection: $defaultViewMode) {
                ForEach(MessageViewMode.allCases, id: \.rawValue) { mode in
                    Text(mode.displayName).tag(mode.rawValue)
                }
            }
        }
        .padding()
    }
}

struct KeyboardSettingsView: View {
    @State private var store = ImpartKeyboardShortcutsStore.shared

    var body: some View {
        VStack(alignment: .leading) {
            Text("Keyboard Shortcuts")
                .font(.headline)

            List {
                ForEach(ImpartShortcutCategory.allCases, id: \.self) { category in
                    Section(category.displayName) {
                        ForEach(store.settings.bindings(for: category)) { binding in
                            HStack {
                                Text(binding.displayName)
                                Spacer()
                                Text(binding.displayShortcut)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.1))
                                    .cornerRadius(4)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)

            HStack {
                Spacer()
                Button("Reset to Defaults") {
                    store.resetToDefaults()
                }
            }
        }
        .padding()
    }
}

struct AutomationSettingsView: View {
    @AppStorage("httpAutomationEnabled") private var httpEnabled = true
    // Default from THE sibling-app table (ImpressKit), not a literal.
    @AppStorage("httpAutomationPort") private var httpPort = Int(ImpartHTTPServer.defaultPort)

    var body: some View {
        Form {
            Toggle("Enable HTTP API", isOn: $httpEnabled)
            TextField("Port", value: $httpPort, format: .number)
                .disabled(!httpEnabled)
        }
        .padding()
    }
}
