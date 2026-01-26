import SwiftUI

/// A view that displays the Helix keybindings reference.
public struct HelixKeybindingsHelp: View {
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                Section("Modes") {
                    KeybindingRow(keys: ["i"], description: "Enter insert mode")
                    KeybindingRow(keys: ["Esc"], description: "Return to normal mode")
                    KeybindingRow(keys: ["v"], description: "Toggle select mode")
                }

                Section("Movement") {
                    KeybindingRow(keys: ["h", "j", "k", "l"], description: "Left, down, up, right")
                    KeybindingRow(keys: ["w", "b"], description: "Word forward, backward")
                    KeybindingRow(keys: ["e"], description: "End of word")
                    KeybindingRow(keys: ["0", "$"], description: "Line start, end")
                    KeybindingRow(keys: ["^"], description: "First non-blank")
                    KeybindingRow(keys: ["gg", "G"], description: "Document start, end")
                }

                Section("Find Character") {
                    KeybindingRow(keys: ["f{char}"], description: "Find character forward")
                    KeybindingRow(keys: ["F{char}"], description: "Find character backward")
                    KeybindingRow(keys: ["t{char}"], description: "Till character forward")
                    KeybindingRow(keys: ["T{char}"], description: "Till character backward")
                    KeybindingRow(keys: [";", ","], description: "Repeat find, reverse")
                }

                Section("Search") {
                    KeybindingRow(keys: ["/"], description: "Search forward")
                    KeybindingRow(keys: ["?"], description: "Search backward")
                    KeybindingRow(keys: ["n", "N"], description: "Next, previous match")
                }

                Section("Selection") {
                    KeybindingRow(keys: ["x"], description: "Select line")
                    KeybindingRow(keys: ["%"], description: "Select all")
                }

                Section("Insert") {
                    KeybindingRow(keys: ["i"], description: "Insert before cursor")
                    KeybindingRow(keys: ["a"], description: "Append after cursor")
                    KeybindingRow(keys: ["I"], description: "Insert at line start")
                    KeybindingRow(keys: ["A"], description: "Append at line end")
                    KeybindingRow(keys: ["o", "O"], description: "Open line below, above")
                }

                Section("Editing") {
                    KeybindingRow(keys: ["d"], description: "Delete selection")
                    KeybindingRow(keys: ["c"], description: "Change (delete + insert)")
                    KeybindingRow(keys: ["s"], description: "Substitute character")
                    KeybindingRow(keys: ["r{char}"], description: "Replace with character")
                    KeybindingRow(keys: ["y"], description: "Yank (copy)")
                    KeybindingRow(keys: ["p", "P"], description: "Paste after, before")
                    KeybindingRow(keys: ["J"], description: "Join lines")
                    KeybindingRow(keys: ["~"], description: "Toggle case")
                    KeybindingRow(keys: [">", "<"], description: "Indent, dedent")
                }

                Section("Repeat & Undo") {
                    KeybindingRow(keys: ["."], description: "Repeat last change")
                    KeybindingRow(keys: ["u"], description: "Undo")
                    KeybindingRow(keys: ["U"], description: "Redo")
                }

                Section("Count Prefix") {
                    KeybindingRow(keys: ["3j"], description: "Move down 3 lines")
                    KeybindingRow(keys: ["5w"], description: "Move 5 words forward")
                    KeybindingRow(keys: ["2fa"], description: "Find 2nd 'a' on line")
                }

                footer
            }
            .padding()
        }
        .frame(minWidth: 400, minHeight: 500)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "keyboard")
                    .font(.title2)
                Text("Helix Keybindings")
                    .font(.title2.bold())
            }

            Text("Helix uses a selection-first model: select text first, then apply actions.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Tip: Most commands accept a numeric prefix (e.g., 3j moves down 3 lines).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }
}

/// A row in the keybindings reference.
struct KeybindingRow: View {
    let keys: [String]
    let description: String

    var body: some View {
        HStack(alignment: .top) {
            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { key in
                    KeyCap(key: key)
                }
            }
            .frame(minWidth: 100, alignment: .leading)

            Text(description)
                .foregroundStyle(.secondary)

            Spacer()
        }
    }
}

/// A styled key cap display.
struct KeyCap: View {
    let key: String

    var body: some View {
        Text(key)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(0.08))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                    }
            }
    }
}

/// A section header with content.
struct Section<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)

            content
        }
    }
}

#Preview("Keybindings Help") {
    HelixKeybindingsHelp()
}
