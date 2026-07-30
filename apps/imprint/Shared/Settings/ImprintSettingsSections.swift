//
//  ImprintSettingsSections.swift
//  imprint
//
//  Stage 6 phase 1: imprint's settings REGISTRATIONS — the factory half of the
//  ADR-0021 descriptor/factory split, living in the app target because that is
//  where the views live.
//
//  The DESCRIPTORS are `AppSettingsConfiguration.imprint` (PMC — pure data, so
//  both renderers and the parity tests can read the same list). The FACTORIES
//  are here, because a factory names concrete views and the chassis must not
//  link `TeXDistributionManager`, `AIAssistantService` or `ImbibIntegrationService`
//  (the `CustomSurface` rule: "the views live in APP TARGETS").
//
//  Three tiers compose into one registry, in this order — later wins:
//
//    1. `SettingsSectionRegistry.builtin`  — chassis generic chrome
//                                            (appearance, spotlight)
//    2. `portableFactories`                — imprint panes that compile on both
//                                            platforms (this file's siblings in
//                                            Shared/Settings/)
//    3. `platformFactories`                — imprint panes that do not. Defined
//                                            per platform, ONCE each, with no
//                                            `#if` here: macOS in
//                                            `macOS/Views/ImprintSettingsFactories.swift`,
//                                            iOS in
//                                            `imprint-iOS/Views/IOSImprintSettingsFactories.swift`.
//
//  Tier 3 is where an iOS pane gets added later: register a factory, widen the
//  descriptor's `availability.platforms`, and the row appears. No renderer edit,
//  no second list to keep in step.
//

import SwiftUI
import PublicationManagerCore

enum ImprintSettingsSections {

    /// Panes whose implementation compiles on macOS AND iOS.
    ///
    /// Registered under the ids the chassis NAMES (`.general`, `.editor`,
    /// `.documents`, `.account`) rather than imprint-private strings, so
    /// imprint's General pane sorts where every app's General pane sorts and
    /// carries the same `settings.tabs.general` identifier.
    static let portableFactories: [SettingsSectionFactory] = [
        SettingsSectionFactory(section: .general) { GeneralSettingsView() },
        SettingsSectionFactory(section: .editor) { EditorSettingsView() },
        SettingsSectionFactory(section: .documents) { DocumentHealthSettingsView() },
        SettingsSectionFactory(section: .account) { AccountSettingsView() },
    ]

    /// Chassis builtins + imprint's portable panes + this platform's panes.
    ///
    /// Injected into the environment by whichever surface renders settings
    /// (`SettingsView` on macOS, the gear sheet in `IOSManuscriptLibraryView`).
    static let registry: SettingsSectionRegistry =
        SettingsSectionRegistry.builtin.composing(portableFactories + platformFactories)
}
