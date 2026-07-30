//
//  ImpressSettingsSections.swift
//  impress (both platforms)
//
//  impress's settings registrations — ONE file for macOS and iOS, because
//  `AppSettingsConfiguration.impress` declares only two panes and one of them
//  is a chassis builtin.
//
//  What impress adopts, and why the surface is this small:
//
//    * `.appearance` — the chassis BUILTIN (`SettingsSectionRegistry.builtin`).
//      Not registered here on purpose: imbib registers over the builtin because
//      its Appearance pane is a theme editor with named themes and font scale;
//      impress has no theme editor, so taking the builtin is the honest choice
//      and re-registering it would fork the pane the builtin exists to share.
//    * `.automation` — `ImpressAutomation.SimpleAutomationSettingsView`, the
//      shared toggle+port pane, over impress's own default port. macOS-only,
//      and the reason is a capability rather than a policy: the HTTP server
//      needs `com.apple.security.network.server`, which iOS never grants
//      (`SettingsRequirement.httpAutomation`).
//
//  NOT declared, each for a reason a reader can check:
//    * `.spotlight` — impress installs no CoreSpotlight coordinator, so the
//      pane would configure an index nothing writes. imprint/imbib/implore/
//      impart each install one; impress would need its own.
//    * `.ai`, `.keyboard`, `.accounts`, `.sync`, … — surfaces impress does not
//      own. A settings tab for a feature the app does not run is the same class
//      of lie as an EmptyView section.
//

import ImpressAutomation
import ImpressKit
import PublicationManagerCore
import SwiftUI

@MainActor
enum ImpressSettingsSections {

    /// The one pane impress registers. Everything else it shows comes from
    /// `SettingsSectionRegistry.builtin`.
    static let factories: [SettingsSectionFactory] = [
        SettingsSectionFactory(section: .automation) { ImpressAutomationSettingsPane() }
    ]

    /// Builtins first, app registrations second — `composing` lets the app win
    /// on a shared id, which is the imbib-over-appearance precedent. impress
    /// shares no id with a builtin, so the order is immaterial here and stated
    /// only so a future registration inherits the right rule.
    static let registry: SettingsSectionRegistry =
        SettingsSectionRegistry.builtin.composing(factories)
}

/// The shared automation pane, over THE port table's row for impress.
private struct ImpressAutomationSettingsPane: View {
    var body: some View {
        SimpleAutomationSettingsView(defaultPort: Int(SiblingApp.impress.httpPort))
    }
}
