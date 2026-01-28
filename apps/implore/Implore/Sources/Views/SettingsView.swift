import SwiftUI
import ImpressHelixCore

/// Settings view for implore preferences
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }
                .accessibilityIdentifier("settings.tabs.general")

            RenderingSettingsView()
                .tabItem {
                    Label("Rendering", systemImage: "paintbrush")
                }
                .accessibilityIdentifier("settings.tabs.rendering")

            ColormapSettingsView()
                .tabItem {
                    Label("Colormaps", systemImage: "paintpalette")
                }
                .accessibilityIdentifier("settings.tabs.colormaps")

            KeyboardSettingsView()
                .tabItem {
                    Label("Keyboard", systemImage: "keyboard")
                }
                .accessibilityIdentifier("settings.tabs.keyboard")
        }
        .frame(width: 500, height: 400)
        .accessibilityIdentifier("settings.container")
    }
}

struct GeneralSettingsView: View {
    @AppStorage("autoLoadLastDataset") private var autoLoadLastDataset = true
    @AppStorage("showWelcomeOnLaunch") private var showWelcomeOnLaunch = true
    @ObservedObject private var modalSettings = ModalEditingSettings.shared

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
