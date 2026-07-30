//
//  SettingsView.swift
//  implore
//
//  Stage 6 phase 2 (declarative chassis): the five tabs are declared as
//  `AppSettingsConfiguration.implore` in PublicationManagerCore; this file
//  contributes the factories and the scene host.
//
//  implore is the smallest, cleanest adoption in the suite and worth reading as
//  the minimal example: five `.tabItem` + `.accessibilityIdentifier` stanzas
//  became five descriptors, one of the five panes turned out to be a chassis
//  builtin verbatim, and the four app panes below are untouched.
//
//  What implore gains that is not just tidiness: its tab list is now readable
//  from outside its own macOS target, which is what
//  `SettingsSurfaceContractTests` uses to freeze the inventory. implore has NO
//  unit-test target of its own, so before this there was nowhere a test could
//  assert what implore's settings are — its only settings coverage was an
//  accessibility audit that opens the window and checks nothing about its
//  contents, and its UI-test page object was already one tab behind the view
//  (no Spotlight accessor).
//

import ImpressHelixCore
import ImpressSpotlight
import PublicationManagerCore
import SwiftUI

/// Settings view for implore preferences
struct SettingsView: View {
    var body: some View {
        // `.fixed`: implore shipped `.frame(width: 500, height: 400)`, a pinned
        // size rather than a floor, and the renderer honours that exactly.
        MacSettingsSceneContent.fixed(
            configuration: .implore, width: 500, height: 400)
            .environment(\.settingsSectionRegistry, ImploreSettingsSections.registry)
    }
}

// MARK: - Factories

/// implore's settings registrations.
///
/// Four factories for five tabs. **Spotlight is absent because it is a chassis
/// builtin**, and it is the clearest case in the suite: implore's tab body was
/// literally `Form { SpotlightSettingsSection() }.formStyle(.grouped)`, which is
/// `SpotlightSettingsPane` character for character. That pane is exactly what a
/// builtin is for — "something no app should author for itself" — and implore,
/// impart and imprint had each written it separately.
///
/// implore does NOT adopt the `appearance` builtin, and that is deliberate rather
/// than an oversight: implore has no appearance tab. Adding one would grow the
/// app's settings surface, which is a product decision and not part of a reframe.
enum ImploreSettingsSections {

    static let factories: [SettingsSectionFactory] = [
        SettingsSectionFactory(section: .general) { GeneralSettingsView() },
        SettingsSectionFactory(section: .rendering) { RenderingSettingsView() },
        SettingsSectionFactory(section: .colormaps) { ColormapSettingsView() },
        SettingsSectionFactory(section: .keyboard) { KeyboardSettingsView() },
    ]

    static let registry: SettingsSectionRegistry =
        SettingsSectionRegistry.builtin.composing(factories)
}

struct GeneralSettingsView: View {
    @AppStorage("autoLoadLastDataset") private var autoLoadLastDataset = true
    @AppStorage("showWelcomeOnLaunch") private var showWelcomeOnLaunch = true
    @State private var modalSettings = ModalEditingSettings.shared

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Show welcome screen on launch", isOn: $showWelcomeOnLaunch)
                Toggle("Auto-load last dataset", isOn: $autoLoadLastDataset)
            }

            Section("Modal Editing") {
                Toggle("Enable modal editing", isOn: $modalSettings.isEnabled)
                    .accessibilityIdentifier("settings.general.modalEditing")

                if modalSettings.isEnabled {
                    Picker("Style", selection: $modalSettings.selectedStyle) {
                        ForEach(EditorStyleIdentifier.allCases, id: \.self) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .accessibilityIdentifier("settings.general.modalStyle")

                    Toggle("Show mode indicator", isOn: $modalSettings.showModeIndicator)
                        .accessibilityIdentifier("settings.general.modeIndicator")

                    styleDescription
                }
            }

            Section("Files") {
                Text("Default export location:")
                    .foregroundStyle(.secondary)
                // Path picker would go here
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    @ViewBuilder
    private var styleDescription: some View {
        switch modalSettings.selectedStyle {
        case .helix:
            Text("Selection-first editing in grammar editor: select text, then act on it")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .vim:
            Text("Verb-object grammar in grammar editor: type operator (d/c/y), then motion")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .emacs:
            Text("Chorded keys in grammar editor: Control and Meta for commands")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct RenderingSettingsView: View {
    @AppStorage("pointSize") private var pointSize = 2.0
    @AppStorage("antialiasing") private var antialiasing = true
    @AppStorage("maxFPS") private var maxFPS = 60

    var body: some View {
        Form {
            Section("Point Rendering") {
                Slider(value: $pointSize, in: 0.5...10, step: 0.5) {
                    Text("Point size: \(pointSize, specifier: "%.1f")")
                }

                Toggle("Enable antialiasing", isOn: $antialiasing)
            }

            Section("Performance") {
                Picker("Max FPS", selection: $maxFPS) {
                    Text("30").tag(30)
                    Text("60").tag(60)
                    Text("120").tag(120)
                    Text("Unlimited").tag(0)
                }
            }

            Section("3D Mode") {
                Text("Field of view: 60°")
                    .foregroundStyle(.secondary)
                Text("Near clip: 0.1")
                    .foregroundStyle(.secondary)
                Text("Far clip: 1000")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct ColormapSettingsView: View {
    @State private var selectedColormap = "viridis"

    let colormaps = ["viridis", "plasma", "inferno", "magma", "cividis", "coolwarm", "spectral"]

    var body: some View {
        Form {
            Section("Default Colormap") {
                Picker("Colormap", selection: $selectedColormap) {
                    ForEach(colormaps, id: \.self) { colormap in
                        Text(colormap.capitalized).tag(colormap)
                    }
                }

                // Preview gradient
                LinearGradient(
                    colors: [.blue, .cyan, .green, .yellow, .red],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            Section("Options") {
                Toggle("Reverse colormap", isOn: .constant(false))
                Toggle("Show colorbar", isOn: .constant(true))
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct KeyboardSettingsView: View {
    var body: some View {
        Form {
            Section("Navigation") {
                KeyboardShortcutRow(action: "Pan", shortcut: "Arrow keys / HJKL")
                KeyboardShortcutRow(action: "Zoom", shortcut: "Scroll / +/-")
                KeyboardShortcutRow(action: "Rotate (3D)", shortcut: "Option + Drag")
                KeyboardShortcutRow(action: "Reset view", shortcut: "R")
            }

            Section("Selection") {
                KeyboardShortcutRow(action: "Select all", shortcut: "⌘A")
                KeyboardShortcutRow(action: "Select none", shortcut: "⌘⇧A")
                KeyboardShortcutRow(action: "Invert selection", shortcut: "⌘⇧I")
                KeyboardShortcutRow(action: "Selection grammar", shortcut: "⌘⇧G")
            }

            Section("Modes") {
                KeyboardShortcutRow(action: "Science 2D", shortcut: "1")
                KeyboardShortcutRow(action: "Box 3D", shortcut: "2")
                KeyboardShortcutRow(action: "Art Shader", shortcut: "3")
                KeyboardShortcutRow(action: "Histogram 1D", shortcut: "4")
                KeyboardShortcutRow(action: "Cycle mode", shortcut: "Tab")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct KeyboardShortcutRow: View {
    let action: String
    let shortcut: String

    var body: some View {
        HStack {
            Text(action)
            Spacer()
            Text(shortcut)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    SettingsView()
}
