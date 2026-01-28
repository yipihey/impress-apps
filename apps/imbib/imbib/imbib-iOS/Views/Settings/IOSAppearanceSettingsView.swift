//
//  IOSAppearanceSettingsView.swift
//  imbib-iOS
//
//  Created by Claude on 2026-01-14.
//

import SwiftUI
import PublicationManagerCore

/// iOS settings view for theme and appearance customization
struct IOSAppearanceSettingsView: View {

    // MARK: - State

    @State private var settings: ThemeSettings = ThemeSettingsStore.loadSettingsSync()

    // MARK: - Body

    var body: some View {
        List {
            // Color Scheme
            Section {
                Picker("Appearance", selection: Binding(
                    get: { settings.appearanceMode },
                    set: { newMode in
                        Task {
                            await ThemeSettingsStore.shared.updateAppearanceMode(newMode)
                            settings = await ThemeSettingsStore.shared.settings
                        }
                    }
                )) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            } header: {
                Text("Color Scheme")
            } footer: {
                Text("Choose whether to follow system appearance or always use light/dark mode")
            }

            // Theme Selection
            Section {
                ForEach(ThemeID.allCases.filter { $0 != .custom }, id: \.self) { themeID in
                    themeRow(for: themeID)
                }
            } header: {
                Text("Theme")
            } footer: {
                Text("Choose a visual theme for the app")
            }

            // Font Size
            Section {
                fontSizeControl
            } header: {
                Text("Font Size")
            }

            // Accent Color
            Section {
                ColorPicker("Accent Color", selection: accentColorBinding)
            } header: {
                Text("Customization")
            } footer: {
                Text("Custom accent color overrides the selected theme")
            }

            // Unread Indicator
            Section("Unread Indicator") {
                ColorPicker("Dot Color", selection: unreadDotColorBinding)
            }

            // Links
            Section("Links") {
                ColorPicker("Link Color", selection: linkColorBinding)
            }

            // Reset
            Section {
                Button("Reset to Default") {
                    Task {
                        await ThemeSettingsStore.shared.reset()
                        settings = await ThemeSettingsStore.shared.settings
                    }
                }
            }
        }
        .navigationTitle("Appearance")
        .task {
            settings = await ThemeSettingsStore.shared.settings
        }
        .onReceive(NotificationCenter.default.publisher(for: .themeSettingsDidChange)) { _ in
            Task {
                settings = await ThemeSettingsStore.shared.settings
            }
        }
    }

    // MARK: - Font Size Control

    private var fontSizeControl: some View {
        VStack(spacing: 16) {
            // Controls row
            HStack(spacing: 24) {
                // Decrease button
                Button {
                    Task {
                        await ThemeSettingsStore.shared.decreaseFontScale()
                        settings = await ThemeSettingsStore.shared.settings
                    }
                } label: {
                    Image(systemName: "textformat.size.smaller")
                        .font(.title2)
                        .frame(width: 50, height: 50)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(settings.fontScale <= 0.7)

                // Current scale indicator
                VStack(spacing: 2) {
                    Text(fontScaleLabel)
                        .font(.headline)
                    Text("\(Int(settings.fontScale * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 70)

                // Increase button
                Button {
                    Task {
                        await ThemeSettingsStore.shared.increaseFontScale()
                        settings = await ThemeSettingsStore.shared.settings
                    }
                } label: {
                    Image(systemName: "textformat.size.larger")
                        .font(.title2)
                        .frame(width: 50, height: 50)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(settings.fontScale >= 1.4)

                Spacer()

                // Reset button
                if settings.fontScale != 1.0 {
                    Button("Reset") {
                        Task {
                            await ThemeSettingsStore.shared.resetFontScale()
                            settings = await ThemeSettingsStore.shared.settings
                        }
                    }
                    .font(.subheadline)
                }
            }

            // Preview
            fontSizePreview
        }
        .padding(.vertical, 8)
    }

    private var fontScaleLabel: String {
        switch settings.fontScale {
        case ..<0.85: return "Small"
        case 0.85..<0.95: return "Small"
        case 0.95..<1.05: return "Default"
        case 1.05..<1.15: return "Large"
        case 1.15..<1.25: return "Large"
        default: return "Extra Large"
        }
    }

    private var fontSizePreview: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Einstein, A. · 1905")
                .font(.system(size: 17 * settings.fontScale, weight: .semibold))
            Text("On the Electrodynamics of Moving Bodies")
                .font(.system(size: 17 * settings.fontScale))
            Text("We consider Maxwell's equations in a moving frame...")
                .font(.system(size: 15 * settings.fontScale))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Theme Row

    private func themeRow(for themeID: ThemeID) -> some View {
        let theme = ThemeSettings.predefined(themeID)

        return HStack {
            // Color swatch
            HStack(spacing: 4) {
                Circle()
                    .fill(Color(hex: theme.accentColorHex) ?? .blue)
                    .frame(width: 20, height: 20)

                if let dotHex = theme.unreadDotColorHex, dotHex != theme.accentColorHex {
                    Circle()
                        .fill(Color(hex: dotHex) ?? .blue)
                        .frame(width: 12, height: 12)
                }
            }
            .frame(width: 40)

            // Name and description
            VStack(alignment: .leading, spacing: 2) {
                Text(themeID.displayName)
                    .font(.body)
                Text(themeID.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Checkmark for selected
            if settings.themeID == themeID {
                Image(systemName: "checkmark")
                    .foregroundColor(.accentColor)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selectTheme(themeID)
        }
    }

    // MARK: - Color Bindings

    private var accentColorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: settings.accentColorHex) ?? .accentColor },
            set: { newColor in
                settings.accentColorHex = newColor.hexString
                settings.themeID = .custom
                settings.isCustom = true
                saveSettings()
            }
        )
    }

    private var unreadDotColorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: settings.unreadDotColorHex ?? settings.accentColorHex) ?? .blue },
            set: { newColor in
                settings.unreadDotColorHex = newColor.hexString
                settings.themeID = .custom
                settings.isCustom = true
                saveSettings()
            }
        )
    }

    private var linkColorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: settings.linkColorHex ?? settings.accentColorHex) ?? .accentColor },
            set: { newColor in
                settings.linkColorHex = newColor.hexString
                settings.themeID = .custom
                settings.isCustom = true
                saveSettings()
            }
        )
    }

    // MARK: - Actions

    private func selectTheme(_ themeID: ThemeID) {
        Task {
            await ThemeSettingsStore.shared.applyTheme(themeID)
            settings = await ThemeSettingsStore.shared.settings
        }
    }

    private func saveSettings() {
        Task {
            await ThemeSettingsStore.shared.update(settings)
        }
    }
}

// MARK: - Preview

#if DEBUG
struct IOSAppearanceSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            IOSAppearanceSettingsView()
        }
    }
}
#endif
