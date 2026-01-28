import SwiftUI

/// A picker view for selecting the editor style.
///
/// Shows all available styles with descriptions.
public struct StylePicker: View {
    @Binding var selection: EditorStyleIdentifier

    public init(selection: Binding<EditorStyleIdentifier>) {
        self._selection = selection
    }

    public var body: some View {
        Picker("Editor Style", selection: $selection) {
            ForEach(EditorStyleIdentifier.allCases, id: \.self) { style in
                HStack {
                    Text(style.displayName)
                    Text("– \(style.description)")
                        .foregroundStyle(.secondary)
                }
                .tag(style)
            }
        }
    }
}

/// A more detailed style picker with descriptions and preview.
public struct DetailedStylePicker: View {
    @Binding var selection: EditorStyleIdentifier
    @State private var showingHelp = false

    public init(selection: Binding<EditorStyleIdentifier>) {
        self._selection = selection
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(EditorStyleIdentifier.allCases, id: \.self) { style in
                StyleOptionRow(
                    style: style,
                    isSelected: selection == style,
                    onSelect: { selection = style }
                )
            }
        }
    }
}

/// A single row in the detailed style picker.
struct StyleOptionRow: View {
    let style: EditorStyleIdentifier
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                // Selection indicator
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .blue : .secondary)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(style.displayName)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text(style.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    // Key features
                    Text(keyFeatures(for: style))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func keyFeatures(for style: EditorStyleIdentifier) -> String {
        switch style {
        case .helix:
            return "hjkl, w/b/e, d/c/y, i/a text objects"
        case .vim:
            return "hjkl, w/b/e, d/c/y + motion, visual mode"
        case .emacs:
            return "C-f/b/n/p, C-k, C-y, M-w, C-Space"
        }
    }
}

/// Complete modal editing settings section for use in app settings views.
public struct ModalEditingSettingsSection: View {
    @ObservedObject var settings: ModalEditingSettings
    @State private var showingKeybindingsHelp = false

    public init(settings: ModalEditingSettings = .shared) {
        self.settings = settings
    }

    public var body: some View {
        Section("Editor") {
            Toggle("Modal editing", isOn: $settings.isEnabled)

            if settings.isEnabled {
                Picker("Style", selection: $settings.selectedStyle) {
                    ForEach(EditorStyleIdentifier.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }

                Toggle("Show mode indicator", isOn: $settings.showModeIndicator)

                if settings.showModeIndicator {
                    Picker("Indicator position", selection: $settings.modeIndicatorPosition) {
                        ForEach(ModeIndicatorPosition.allCases, id: \.self) { position in
                            Text(position.displayName).tag(position)
                        }
                    }
                }

                Button("View Keybindings") {
                    showingKeybindingsHelp = true
                }

                Text("Style syncs across all Impress apps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showingKeybindingsHelp) {
            KeybindingsHelpView(style: settings.selectedStyle)
        }
    }
}

/// Help view showing keybindings for the selected style.
struct KeybindingsHelpView: View {
    let style: EditorStyleIdentifier
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(style.displayName)
                        .font(.largeTitle)
                        .bold()

                    Text(style.description)
                        .font(.title3)
                        .foregroundStyle(.secondary)

                    Divider()

                    keybindingsContent
                }
                .padding()
            }
            .navigationTitle("Keybindings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 500, minHeight: 400)
        #endif
    }

    @ViewBuilder
    private var keybindingsContent: some View {
        switch style {
        case .helix:
            helixKeybindings
        case .vim:
            vimKeybindings
        case .emacs:
            emacsKeybindings
        }
    }

    private var helixKeybindings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Section("Modes") {
                KeybindingRow(keys: ["i"], description: "Enter insert mode")
                KeybindingRow(keys: ["Esc"], description: "Return to normal mode")
                KeybindingRow(keys: ["v"], description: "Toggle select mode")
            }

            Section("Movement") {
                KeybindingRow(keys: ["h", "j", "k", "l"], description: "Left/down/up/right")
                KeybindingRow(keys: ["w", "b", "e"], description: "Word forward/backward/end")
                KeybindingRow(keys: ["0", "$"], description: "Line start/end")
                KeybindingRow(keys: ["gg", "G"], description: "Document start/end")
            }

            Section("Editing") {
                KeybindingRow(keys: ["d"], description: "Delete (+ motion/object)")
                KeybindingRow(keys: ["c"], description: "Change (+ motion/object)")
                KeybindingRow(keys: ["y"], description: "Yank (+ motion/object)")
                KeybindingRow(keys: ["p", "P"], description: "Paste after/before")
            }

            Section("Text Objects") {
                KeybindingRow(keys: ["diw"], description: "Delete inner word")
                KeybindingRow(keys: ["ci\""], description: "Change inner quotes")
                KeybindingRow(keys: ["da("], description: "Delete around parens")
            }
        }
    }

    private var vimKeybindings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Section("Modes") {
                KeybindingRow(keys: ["i", "a"], description: "Insert before/after cursor")
                KeybindingRow(keys: ["I", "A"], description: "Insert at line start/end")
                KeybindingRow(keys: ["o", "O"], description: "Open line below/above")
                KeybindingRow(keys: ["Esc"], description: "Return to normal mode")
                KeybindingRow(keys: ["v", "V"], description: "Visual/visual line mode")
            }

            Section("Movement") {
                KeybindingRow(keys: ["h", "j", "k", "l"], description: "Left/down/up/right")
                KeybindingRow(keys: ["w", "b", "e"], description: "Word forward/backward/end")
                KeybindingRow(keys: ["0", "$"], description: "Line start/end")
                KeybindingRow(keys: ["gg", "G"], description: "Document start/end")
                KeybindingRow(keys: ["{", "}"], description: "Paragraph backward/forward")
            }

            Section("Operators") {
                KeybindingRow(keys: ["d"], description: "Delete")
                KeybindingRow(keys: ["c"], description: "Change")
                KeybindingRow(keys: ["y"], description: "Yank")
                KeybindingRow(keys: ["dd", "cc", "yy"], description: "Operate on line")
            }

            Section("Search") {
                KeybindingRow(keys: ["/"], description: "Search forward")
                KeybindingRow(keys: ["?"], description: "Search backward")
                KeybindingRow(keys: ["n", "N"], description: "Next/previous match")
            }
        }
    }

    private var emacsKeybindings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Section("Movement") {
                KeybindingRow(keys: ["C-f", "C-b"], description: "Forward/backward character")
                KeybindingRow(keys: ["C-n", "C-p"], description: "Next/previous line")
                KeybindingRow(keys: ["M-f", "M-b"], description: "Forward/backward word")
                KeybindingRow(keys: ["C-a", "C-e"], description: "Beginning/end of line")
                KeybindingRow(keys: ["M-<", "M->"], description: "Beginning/end of buffer")
            }

            Section("Editing") {
                KeybindingRow(keys: ["C-d"], description: "Delete character")
                KeybindingRow(keys: ["M-d"], description: "Kill word forward")
                KeybindingRow(keys: ["C-k"], description: "Kill to end of line")
                KeybindingRow(keys: ["C-w"], description: "Kill region")
            }

            Section("Kill Ring") {
                KeybindingRow(keys: ["C-y"], description: "Yank (paste)")
                KeybindingRow(keys: ["M-y"], description: "Yank-pop (cycle)")
                KeybindingRow(keys: ["M-w"], description: "Copy region")
            }

            Section("Selection") {
                KeybindingRow(keys: ["C-Space"], description: "Set mark")
                KeybindingRow(keys: ["C-x h"], description: "Select all")
            }

            Section("Search") {
                KeybindingRow(keys: ["C-s"], description: "Incremental search forward")
                KeybindingRow(keys: ["C-r"], description: "Incremental search backward")
            }

            Section("Undo") {
                KeybindingRow(keys: ["C-/"], description: "Undo")
            }
        }
    }
}

// Note: KeybindingRow and Section are defined in HelixKeybindingsHelp.swift

#Preview("Style Picker") {
    @Previewable @State var selection: EditorStyleIdentifier = .helix

    Form {
        StylePicker(selection: $selection)
    }
    .padding()
}

#Preview("Settings Section") {
    Form {
        ModalEditingSettingsSection()
    }
    .padding()
}
