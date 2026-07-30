//
//  IOSImpartSettingsFactories.swift
//  impart-iOS
//
//  impart-iOS's settings, on the chassis (Stage 5c).
//
//  The wave-3 settings migration put impart's macOS tabs on
//  `AppSettingsConfiguration.impart` but had to declare every one of the six
//  `.macOSOnly()`, and wrote down why: "impart DOES have an iOS target with its
//  own settings `List`, but `impart-iOS` does not link PublicationManagerCore,
//  so no chassis renderer can run there today … claiming `.everywhere` would
//  describe a screen that cannot be built." A `Phase2SettingsPersistenceTests`
//  case pinned the consequence — impart-iOS's `IOSAppearanceSettingsView` was a
//  THIRD hand-rolled clone of `ImpressTheme.AppearanceSettingsSection` over the
//  `appearanceMode` key, and the test existed only to stop the two platforms
//  forking that key.
//
//  Linking the package retired that sentence, so `.general` and `.accounts` are
//  now `.everywhere` in the preset and this file registers their iOS panes.
//  Everything else about the screen — which rows appear, in what order, with
//  what titles, subtitles and icons, and the footer explaining the four rows
//  that stay on the Mac and WHY (derived from each hidden section's
//  `SettingsRequirement`s) — is `IOSSettingsScreen` over the declaration.
//
//  The two panes deliberately mirror macOS's rather than improving on them:
//  General is the same two pickers over the same two keys, so the preference
//  cannot fork; Accounts is the one place they differ, and it differs because
//  the platforms genuinely do (see below).
//

import MessageManagerCore
import PublicationManagerCore
import SwiftUI

/// impart-iOS's registry: the chassis builtins (Appearance, Spotlight) composed
/// with impart's own iOS panes — the `ImprintSettingsSections` shape.
@MainActor
enum ImpartIOSSettingsSections {

    static let factories: [SettingsSectionFactory] = [
        SettingsSectionFactory(section: .general) { IOSImpartGeneralSettingsPane() },
        SettingsSectionFactory(section: .accounts) { IOSImpartAccountsSettingsPane() },
    ]

    /// Builtins first, app panes second — `composing(_:)` applies the additions
    /// after the builtins, so an app registration wins for a shared id.
    static let registry: SettingsSectionRegistry =
        SettingsSectionRegistry.builtin.composing(factories)
}

// MARK: - General

/// Appearance + default view: the same two controls, the same two keys and the
/// same three appearance tags as macOS's `GeneralSettingsView`.
///
/// It is NOT the chassis appearance builtin, for the reason phase 2 recorded:
/// the picker is one of TWO controls inside General rather than a tab of its
/// own, and promoting it would move a control between panes — a visible change
/// to a surface this migration must keep equivalent. What the key agreement buys
/// is that the deferred promotion stays a pure UI change with no migration.
struct IOSImpartGeneralSettingsPane: View {

    @AppStorage("appearanceMode") private var appearanceMode = "system"
    @AppStorage("defaultViewMode") private var defaultViewMode = "email"

    var body: some View {
        SettingsForm {
            Section {
                Picker("Appearance", selection: $appearanceMode) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings.general.appearance")
            } footer: {
                Text("Choose whether to follow system appearance or always use light/dark mode.")
            }

            Section {
                // The mode list comes from `MessageViewMode` (MessageManagerCore,
                // cross-platform) exactly as macOS's picker does, so a new view
                // mode appears on both platforms at once.
                Picker("Default View", selection: $defaultViewMode) {
                    ForEach(MessageViewMode.allCases, id: \.rawValue) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .accessibilityIdentifier("settings.general.defaultView")
            } footer: {
                // Honest about the asymmetry rather than silent about it: the
                // four non-mail view modes are macOS custom surfaces, and this
                // shell registers none of them (they read an `InboxViewModel`
                // whose `accounts` nothing assigns).
                Text("impart on iPhone and iPad shows mail only; the other view modes are Mac surfaces.")
            }
        }
    }
}

// MARK: - Accounts

/// The accounts this device can SEE, read from the shared store's `mail-account`
/// rows.
///
/// This is the one pane that is not a transcription of macOS's, and the
/// difference is the platform's, not a design choice: adding an account is an
/// IMAP-settings + Keychain + connection-test flow, and impart-iOS has no path
/// to any of it (there is no IMAP client anywhere in impart —
/// `RustMailProvider.fetchMessages` returns `[]` and `ImpartRustCore` is a
/// placeholder package). The deleted `IOSAccountsSettingsView` acknowledged this
/// by shipping a `+` button whose body was the comment `// Add account`.
///
/// So the iOS pane reports rather than pretends: the accounts the Mac has
/// mirrored into this app group, with their mailbox counts. That is genuinely
/// useful — it is the answer to "why is my inbox empty on my phone" — and it
/// offers no affordance that does nothing. (macOS's own pane is currently a
/// placeholder too; presenting `AccountSetupView` there is a separate product
/// decision, noted in `ImpartSettingsScene`.)
struct IOSImpartAccountsSettingsPane: View {

    @State private var tree: MailSidebarSnapshot = .empty

    var body: some View {
        SettingsForm {
            if tree.accounts.isEmpty {
                Section {
                    Text("No accounts have been mirrored to this device yet.")
                        .foregroundStyle(.secondary)
                } footer: {
                    Text(
                        "impart on iOS reads the mail impart on your Mac writes to the shared "
                            + "impress workspace. Add accounts there.")
                }
            } else {
                ForEach(tree.accounts) { account in
                    Section {
                        LabeledContent("Name", value: account.name)
                        if let address = account.address, address != account.name {
                            LabeledContent("Address", value: address)
                        }
                        LabeledContent("Mailboxes", value: "\(account.folders.count)")
                    } header: {
                        Text(account.address ?? account.name)
                    }
                    .accessibilityIdentifier("settings.accounts.\(account.storeID)")
                }
            }
        }
        .task { tree = MailSidebarSnapshot.load() }
    }
}
