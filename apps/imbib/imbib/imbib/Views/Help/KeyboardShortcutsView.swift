//
//  KeyboardShortcutsView.swift
//  imbib
//
//  Created by Claude on 2026-01-07.
//

import SwiftUI
import PublicationManagerCore

/// A reference window showing all keyboard shortcuts grouped by category.
/// This view reads from KeyboardShortcutsSettings to ensure documentation
/// always matches the actual implementation.
struct KeyboardShortcutsView: View {
    @Environment(\.dismiss) private var dismiss

    /// Shortcuts grouped by category, with related shortcuts merged
    private var groupedShortcuts: [(category: ShortcutCategory, shortcuts: [(name: String, keys: String)])] {
        let settings = KeyboardShortcutsSettings.defaults

        // Group bindings by category
        var categoryBindings: [ShortcutCategory: [KeyboardShortcutBinding]] = [:]
        for binding in settings.bindings {
            categoryBindings[binding.category, default: []].append(binding)
        }

        // Convert to display format, merging related shortcuts
        var result: [(category: ShortcutCategory, shortcuts: [(name: String, keys: String)])] = []

        for category in ShortcutCategory.allCases {
            guard let bindings = categoryBindings[category], !bindings.isEmpty else { continue }

            // Merge shortcuts that post the same notification (e.g., arrow + vim variants)
            var merged: [(name: String, keys: String)] = []
            var processedNotifications: Set<String> = []

            for binding in bindings {
                // Skip if we already processed this notification
                guard !processedNotifications.contains(binding.notificationName) else { continue }

                // Find all bindings for the same notification
                let related = bindings.filter { $0.notificationName == binding.notificationName }

                if related.count > 1 {
                    // Merge multiple bindings: use the shortest displayName, combine keys
                    let name = related.map { $0.displayName }.min(by: { $0.count < $1.count }) ?? binding.displayName
                    let keys = related.map { $0.displayShortcut }.joined(separator: " / ")
                    merged.append((name: name, keys: keys))
                } else {
                    merged.append((name: binding.displayName, keys: binding.displayShortcut))
                }

                processedNotifications.insert(binding.notificationName)
            }

            result.append((category: category, shortcuts: merged))
        }

        return result
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Dynamic sections from KeyboardShortcutsSettings
                ForEach(groupedShortcuts, id: \.category) { group in
                    ShortcutSection(
                        title: group.category.displayName,
                        shortcuts: group.shortcuts.map { ($0.name, $0.keys) }
                    )
                }

                // Additional hardcoded sections for shortcuts not in settings

                // PDF Annotations (handled separately in PDF viewer)
                ShortcutSection(title: "PDF Annotations", shortcuts: [
                    ("Highlight Selection", "⌃h"),
                    ("Underline Selection", "⌃u"),
                    ("Strikethrough Selection", "⌃t"),
                    ("Add Note at Selection", "⌃n"),
                ])

                // Windows (Fullscreen)
                ShortcutSection(title: "Windows (Fullscreen)", shortcuts: [
                    ("Open PDF in Fullscreen", "Shift+p"),
                    ("Open Notes in Fullscreen", "Shift+n"),
                    ("Open Info in Fullscreen", "Shift+i"),
                    ("Open BibTeX in Fullscreen", "Shift+b"),
                    ("Flip Window Positions", "Shift+f"),
                    ("Close Detached Windows", "⌥⇧⌘w"),
                ])

                // Standard App shortcuts
                ShortcutSection(title: "App", shortcuts: [
                    ("Preferences", "⌘,"),
                    ("Console", "⌃⌘c"),
                    ("Keyboard Shortcuts", "⌘/"),
                    ("Help", "⌘?"),
                    ("Close Window", "⌘w"),
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
