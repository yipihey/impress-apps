//
//  AppearanceSettingsSection.swift
//  ImpressTheme
//
//  Shared appearance settings section for all impress apps.
//

import SwiftUI

/// A reusable settings section for appearance mode (System/Light/Dark).
///
/// Usage:
/// ```swift
/// AppearanceSettingsSection(mode: $appearanceMode)
/// ```
public struct AppearanceSettingsSection: View {
    @Binding var mode: AppearanceMode

    public init(mode: Binding<AppearanceMode>) {
        self._mode = mode
    }

    public var body: some View {
        Picker("Appearance", selection: $mode) {
            ForEach(AppearanceMode.allCases, id: \.self) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
    }
}
