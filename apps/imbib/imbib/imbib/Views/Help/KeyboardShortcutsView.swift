//
//  KeyboardShortcutsView.swift
//  imbib
//
//  Created by Claude on 2026-01-07.
//

import SwiftUI

/// A reference window showing all keyboard shortcuts grouped by category.
struct KeyboardShortcutsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Navigation
                ShortcutSection(title: "Navigation", shortcuts: [
                    ("Next Paper", "↓"),
                    ("Previous Paper", "↑"),
                    ("First Paper", "⌘↑"),
                    ("Last Paper", "⌘↓"),
                    ("Next Unread", "⌥↓"),
                    ("Previous Unread", "⌥↑"),
                    ("Open Paper", "↩"),
                    ("Back", "⌘["),
                    ("Forward", "⌘]"),
                ])

                // Views
                ShortcutSection(title: "Views", shortcuts: [
                    ("Command Palette", "⇧⌘P"),
                    ("Show Library", "⌘1"),
                    ("Show Search", "⌘2"),
                    ("Show Inbox", "⌘3"),
                    ("Show PDF Tab", "⌘4"),
                    ("Show BibTeX Tab", "⌘5"),
                    ("Show Notes Tab", "⌘6"),
                    ("Toggle Detail Pane", "⌘0"),
                    ("Toggle Sidebar", "⌃⌘S"),
                    ("Increase Text Size", "⇧⌘="),
                    ("Decrease Text Size", "⇧⌘-"),
                ])

                // Focus
                ShortcutSection(title: "Focus", shortcuts: [
                    ("Focus Sidebar", "⌥⌘1"),
                    ("Focus List", "⌥⌘2"),
                    ("Focus Detail", "⌥⌘3"),
                    ("Global Search", "⌘F"),
                ])

                // Paper Actions
                ShortcutSection(title: "Paper Actions", shortcuts: [
                    ("Open Notes", "⌘R"),
                    ("Open References", "⇧⌘R"),
                    ("Toggle Read/Unread", "⇧⌘U"),
                    ("Mark All as Read", "⌥⌘U"),
                    ("Keep to Library", "⌃⌘K"),
                    ("Dismiss from Inbox", "⇧⌘J"),
                    ("Add to Collection", "⌘L"),
                    ("Remove from Collection", "⇧⌘L"),
                    ("Move to Collection", "⌃⌘M"),
                    ("Share", "⇧⌘F"),
                    ("Delete", "⌘⌫"),
                ])

                // Clipboard
                ShortcutSection(title: "Clipboard", shortcuts: [
                    ("Copy BibTeX", "⌘C"),
                    ("Copy as Citation", "⇧⌘C"),
                    ("Copy DOI/URL", "⌥⌘C"),
                    ("Cut", "⌘X"),
                    ("Paste", "⌘V"),
                    ("Select All", "⌘A"),
                ])

                // Filtering
                ShortcutSection(title: "Filtering", shortcuts: [
                    ("Toggle Unread Filter", "⌘\\"),
                    ("Toggle PDF Filter", "⇧⌘\\"),
                ])

                // Inbox Triage (Single Keys)
                ShortcutSection(title: "Inbox Triage (Single Keys)", shortcuts: [
                    ("Keep", "K"),
                    ("Dismiss", "D"),
                    ("Star/Flag", "S"),
                    ("Mark as Read", "R"),
                    ("Mark as Unread", "U"),
                    ("Next (Vim)", "J"),
                    ("Previous (Vim)", "K"),
                    ("Open (Vim)", "O"),
                ])

                // PDF Viewer
                ShortcutSection(title: "PDF Viewer", shortcuts: [
                    ("Page Down", "Space"),
                    ("Page Up", "⇧Space"),
                    ("Zoom In", "⇧⌘="),
                    ("Zoom Out", "⇧⌘-"),
                    ("Go to Page", "⌘G"),
                ])

                // File Operations
                ShortcutSection(title: "File Operations", shortcuts: [
                    ("Import BibTeX", "⌘I"),
                    ("Export Library", "⇧⌘E"),
                    ("Refresh", "⇧⌘N"),
                ])

                // Windows (Multi-Monitor)
                ShortcutSection(title: "Windows (Multi-Monitor)", shortcuts: [
                    ("Detach PDF to Window", "⌥⇧⌘M"),
                    ("Detach Notes to Window", "⌥⇧⌘N"),
                    ("Flip Window Positions", "⌥⇧⌘F"),
                    ("Close Detached Windows", "⌥⇧⌘W"),
                ])

                // PDF Annotations
                ShortcutSection(title: "PDF Annotations", shortcuts: [
                    ("Highlight Selection", "⌃H"),
                    ("Underline Selection", "⌃U"),
                    ("Strikethrough Selection", "⌃T"),
                    ("Add Note at Selection", "⌃N"),
                ])

                // App
                ShortcutSection(title: "App", shortcuts: [
                    ("Preferences", "⌘,"),
                    ("Console", "⌃⌘C"),
                    ("Keyboard Shortcuts", "⌘/"),
                    ("Help", "⌘?"),
                    ("Close Window", "⌘W"),
                ])
            }
            .padding(24)
        }
        .frame(minWidth: 400, idealWidth: 450, minHeight: 500, idealHeight: 700)
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
        }
    }
}

// MARK: - Shortcut Section

struct ShortcutSection: View {
    let title: String
    let shortcuts: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            Divider()

            ForEach(shortcuts, id: \.0) { name, keys in
                HStack {
                    Text(name)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(keys)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                }
                .padding(.vertical, 2)
            }
        }
    }
}

// MARK: - Preview

#Preview {
    KeyboardShortcutsView()
}
