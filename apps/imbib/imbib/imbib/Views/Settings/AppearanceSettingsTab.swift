//
//  AppearanceSettingsTab.swift
//  imbib
//
//  Created by Claude on 2026-01-14.
//

import SwiftUI
import PublicationManagerCore

// MARK: - Appearance Settings Tab

/// Settings tab for customizing app appearance and themes
struct AppearanceSettingsTab: View {

    // MARK: - State

    @State private var settings: ThemeSettings = ThemeSettingsStore.loadSettingsSync()
    @State private var showAdvanced = false
    @State private var pdfDarkModeEnabled: Bool = false

    // MARK: - Body

    var body: some View {
        Form {
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
                .pickerStyle(.segmented)

                Toggle("PDF dark mode", isOn: $pdfDarkModeEnabled)
                    .onChange(of: pdfDarkModeEnabled) { _, newValue in
                        Task { await PDFSettingsStore.shared.updateDarkMode(enabled: newValue) }
                    }
                    .help("Invert foreground and background colors when viewing PDFs")
            } header: {
                Text("Color Scheme")
            } footer: {
                Text("PDF dark mode inverts colors for comfortable reading in dark environments.")
            }

            // Theme Selection
            Section {
                themePicker
            } header: {
                Text("Theme")
            } footer: {
                Text("Choose a predefined theme or customize colors")
            }

            // Font Size
            Section {
                fontSizeControl
            } header: {
                Text("Font Size")
            }

            // Accent Color
            Section("Accent Color") {
                accentColorPicker
            }

            // Advanced Options
            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                advancedOptions
            }

            // Reset
            Section {
                resetButton
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding(.horizontal)
        .task {
            settings = await ThemeSettingsStore.shared.settings
            let pdfSettings = await PDFSettingsStore.shared.settings
            pdfDarkModeEnabled = pdfSettings.darkModeEnabled
        }
        .onReceive(NotificationCenter.default.publisher(for: .themeSettingsDidChange)) { _ in
            Task {
                settings = await ThemeSettingsStore.shared.settings
            }
        }
    }

    // MARK: - Font Size Control

    private var fontSizeControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Controls row
            HStack(spacing: 20) {
                // Decrease button
                Button {
                    Task {
                        await ThemeSettingsStore.shared.decreaseFontScale()
                        settings = await ThemeSettingsStore.shared.settings
                    }
                } label: {
                    Image(systemName: "textformat.size.smaller")
                        .font(.title2)
                        .frame(width: 44, height: 44)
                        .background(Color(.controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
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
                .frame(width: 80)

                // Increase button
                Button {
                    Task {
                        await ThemeSettingsStore.shared.increaseFontScale()
                        settings = await ThemeSettingsStore.shared.settings
                    }
                } label: {
                    Image(systemName: "textformat.size.larger")
                        .font(.title2)
                        .frame(width: 44, height: 44)
                        .background(Color(.controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
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
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            // Preview
            fontSizePreview
        }
        .padding(.vertical, 4)
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
            Text("We consider Maxwell's equations in a moving frame of reference...")
                .font(.system(size: 15 * settings.fontScale))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Theme Picker

    private var themePicker: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 130))], spacing: 12) {
            ForEach(ThemeID.allCases.filter { $0 != .custom }, id: \.self) { themeID in
                ThemePreviewCard(
                    themeID: themeID,
                    isSelected: settings.themeID == themeID
                )
                .onTapGesture {
                    selectTheme(themeID)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier(AccessibilityID.Settings.Appearance.themeGrid)
    }

    // MARK: - Accent Color Picker

    private var accentColorPicker: some View {
        HStack {
            Text("Accent Color")
            Spacer()
            ColorPicker("", selection: accentColorBinding)
                .labelsHidden()
                .accessibilityIdentifier(AccessibilityID.Settings.Appearance.accentColorPicker)
            Text(settings.accentColorHex)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 70)
        }
    }

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

    // MARK: - Advanced Options

    private var advancedOptions: some View {
        Group {
            // Unread Indicator Color (single row, no section header)
            HStack {
                Text("Unread Indicator Color")
                Spacer()
                ColorPicker("", selection: unreadDotColorBinding)
                    .labelsHidden()
            }

            // Sidebar Style
            Picker("Sidebar Style", selection: $settings.sidebarStyle) {
                ForEach(SidebarStyle.allCases, id: \.self) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .onChange(of: settings.sidebarStyle) { _, _ in
                settings.themeID = .custom
                settings.isCustom = true
                saveSettings()
            }

            if settings.sidebarStyle != .system {
                HStack {
                    Text("Sidebar Tint Color")
                    Spacer()
                    ColorPicker("", selection: sidebarTintBinding)
                        .labelsHidden()
                }
            }

            // Typography (no section header)
            Toggle("Use serif fonts for titles", isOn: $settings.useSerifTitles)
                .onChange(of: settings.useSerifTitles) { _, _ in
                    settings.themeID = .custom
                    settings.isCustom = true
                    saveSettings()
                }

            // Text Colors
            Section("Text Colors") {
                HStack {
                    Text("Primary Text")
                    Spacer()
                    ColorPicker("", selection: primaryTextColorBinding)
                        .labelsHidden()
                    Button("Reset") {
                        settings.primaryTextColorHex = nil
                        settings.themeID = .custom
                        settings.isCustom = true
                        saveSettings()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                }

                HStack {
                    Text("Secondary Text")
                    Spacer()
                    ColorPicker("", selection: secondaryTextColorBinding)
                        .labelsHidden()
                    Button("Reset") {
                        settings.secondaryTextColorHex = nil
                        settings.themeID = .custom
                        settings.isCustom = true
                        saveSettings()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                }

                HStack {
                    Text("Link Color")
                    Spacer()
                    ColorPicker("", selection: linkColorBinding)
                        .labelsHidden()
                }
            }

            // Background Color (no section header)
            HStack {
                Text("Background Color")
                Spacer()
                ColorPicker("", selection: detailBackgroundColorBinding)
                    .labelsHidden()
                Button("Reset") {
                    settings.detailBackgroundColorHex = nil
                    settings.themeID = .custom
                    settings.isCustom = true
                    saveSettings()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.caption)
            }
        }
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

    private var sidebarTintBinding: Binding<Color> {
        Binding(
            get: { Color(hex: settings.sidebarTintHex ?? settings.accentColorHex) ?? .accentColor },
            set: { newColor in
                settings.sidebarTintHex = newColor.hexString
                settings.themeID = .custom
                settings.isCustom = true
                saveSettings()
            }
        )
    }

    private var primaryTextColorBinding: Binding<Color> {
        Binding(
            get: {
                if let hex = settings.primaryTextColorHex {
                    return Color(hex: hex) ?? Color(.labelColor)
                }
                return Color(.labelColor)
            },
            set: { newColor in
                settings.primaryTextColorHex = newColor.hexString
                settings.themeID = .custom
                settings.isCustom = true
                saveSettings()
            }
        )
    }

    private var secondaryTextColorBinding: Binding<Color> {
        Binding(
            get: {
                if let hex = settings.secondaryTextColorHex {
                    return Color(hex: hex) ?? .secondary
                }
                return .secondary
            },
            set: { newColor in
                settings.secondaryTextColorHex = newColor.hexString
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

    private var detailBackgroundColorBinding: Binding<Color> {
        Binding(
            get: {
                if let hex = settings.detailBackgroundColorHex {
                    return Color(hex: hex) ?? Color(.textBackgroundColor)
                }
                return Color(.textBackgroundColor)
            },
            set: { newColor in
                settings.detailBackgroundColorHex = newColor.hexString
                settings.themeID = .custom
                settings.isCustom = true
                saveSettings()
            }
        )
    }

    // MARK: - Reset Button

    private var resetButton: some View {
        Button("Reset to Default Theme") {
            Task {
                await ThemeSettingsStore.shared.reset()
                settings = await ThemeSettingsStore.shared.settings
            }
        }
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

// MARK: - Theme Preview Card

struct ThemePreviewCard: View {
    let themeID: ThemeID
    let isSelected: Bool

    @State private var isHovered = false

    private var theme: ThemeSettings {
        ThemeSettings.predefined(themeID)
    }

    var body: some View {
        VStack(spacing: 6) {
            // Color swatch preview
            HStack(spacing: 4) {
                // Accent color
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(hex: theme.accentColorHex) ?? .blue)
                    .frame(width: 30, height: 40)

                // Unread dot color
                Circle()
                    .fill(Color(hex: theme.unreadDotColorHex ?? theme.accentColorHex) ?? .blue)
                    .frame(width: 12, height: 12)

                // Sidebar tint (if applicable)
                if theme.sidebarStyle != .system, let tint = theme.sidebarTintHex {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(hex: tint)?.opacity(0.3) ?? .clear)
                        .frame(width: 20, height: 40)
                }
            }
            .frame(height: 44)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.controlBackgroundColor))
            )

            // Theme name
            Text(themeID.displayName)
                .font(.caption)
                .lineLimit(1)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Preview

#if DEBUG
struct AppearanceSettingsTab_Previews: PreviewProvider {
    static var previews: some View {
        AppearanceSettingsTab()
            .frame(width: 650, height: 550)
    }
}
#endif
