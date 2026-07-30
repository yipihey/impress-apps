#if os(macOS)
//
//  ImpressSettingsScene.swift
//  impress
//
//  The whole macOS Settings window. `MacSettingsSceneContent` renders
//  `AppSettingsConfiguration.impress` through the registry — the tab list, the
//  grouping, the availability filtering and the "unregistered pane" warning are
//  all the chassis's. impel's `SettingsView` is the precedent and is the same
//  five lines.
//

import PublicationManagerCore
import SwiftUI

struct ImpressSettingsScene: View {
    var body: some View {
        MacSettingsSceneContent(configuration: .impress)
            .environment(\.settingsSectionRegistry, ImpressSettingsSections.registry)
    }
}
#endif // os(macOS)
