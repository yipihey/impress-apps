//
//  ShortcutsHelpView.swift
//  imprint
//
//  Keyboard-shortcuts reference (⌘/, matching imbib). Data-driven so it stays
//  honest: one table, grouped by area, searchable. Chords marked "universal"
//  are part of the cross-app impress grammar (ImpressKeyboard
//  UniversalShortcut / docs/keyboard-grammar.md).
//

import SwiftUI

struct ShortcutsHelpView: View {
    private struct Entry: Identifiable {
        let id = UUID()
        let chord: String
        let action: String
        var universal = false
    }

    private struct Group: Identifiable {
        let id = UUID()
        let title: String
        let entries: [Entry]
    }

    private static let groups: [Group] = [
        Group(title: "Views & Panes", entries: [
            Entry(chord: "⌘1 / ⌘2 / ⌘3", action: "Text Only / Split View / Direct PDF", universal: true),
            Entry(chord: "⇥", action: "Cycle edit mode"),
            Entry(chord: "⌃⌘S", action: "Show/hide outline sidebar", universal: true),
            Entry(chord: "⌘0", action: "Show/hide preview pane", universal: true),
            Entry(chord: "⌘\\", action: "Split editor (two views, same document)", universal: true),
            Entry(chord: "⌥⌘\\", action: "Split editor: side by side ↔ stacked"),
            Entry(chord: "⌃⌘P", action: "Open PDF on second display", universal: true),
            Entry(chord: "⌃⌘1…9", action: "Apply saved layout 1–9", universal: true),
            Entry(chord: "⌥⌘F", action: "Focus mode"),
            Entry(chord: "⌘.", action: "AI assistant sidebar"),
            Entry(chord: "⌥⌘K", action: "Comments sidebar"),
            Entry(chord: "⌥⌘P", action: "Plots panel"),
        ]),
        Group(title: "Appearance", entries: [
            Entry(chord: "⌃⌘D", action: "All dark / all light", universal: true),
        ]),
        Group(title: "Writing", entries: [
            Entry(chord: "⌘B / ⌘I", action: "Bold / Italic"),
            Entry(chord: "⌥⌘1…3", action: "Heading level 1–3"),
            Entry(chord: "⌘⇧K", action: "Insert citation"),
            Entry(chord: "⌘⇧M", action: "Add comment at selection"),
            Entry(chord: "⌘⇧Y", action: "Symbol palette"),
            Entry(chord: "⌃⌘V", action: "Insert Veusz plot"),
        ]),
        Group(title: "AI Assist (selection or cell bracket)", entries: [
            Entry(chord: "⌃⌘C", action: "Improve clarity"),
            Entry(chord: "⌃⌘S (in editor)", action: "Make concise"),
            Entry(chord: "⌃⌘E", action: "Expand"),
            Entry(chord: "⌃⌘I", action: "Integrate with the rest"),
            Entry(chord: "⌃⌘R", action: "Review → margin comments"),
            Entry(chord: "⌃⌘K", action: "Suggest citations"),
        ]),
        Group(title: "Compile & Document", entries: [
            Entry(chord: "⌘↩", action: "Compile to PDF"),
            Entry(chord: "⌘⇧E", action: "Export PDF"),
            Entry(chord: "⌘⇧F", action: "Search across manuscripts"),
            Entry(chord: "⌘⇧L", action: "Manuscript library"),
            Entry(chord: "⌥⌘H", action: "Version history"),
        ]),
        Group(title: "Git", entries: [
            Entry(chord: "⌥⌘G", action: "Commit"),
            Entry(chord: "⌘⇧P / ⌘⇧U", action: "Push / Pull"),
        ]),
    ]

    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Filter shortcuts…", text: $filter)
                .textFieldStyle(.roundedBorder)
                .padding(12)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(filteredGroups) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.title)
                                .font(.headline)
                            ForEach(group.entries) { entry in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(entry.chord)
                                        .font(.system(.callout, design: .monospaced))
                                        .frame(width: 130, alignment: .leading)
                                    Text(entry.action)
                                        .font(.callout)
                                    if entry.universal {
                                        Text("universal")
                                            .font(.caption2)
                                            .padding(.horizontal, 5).padding(.vertical, 1)
                                            .background(.tint.opacity(0.15), in: Capsule())
                                            .foregroundStyle(.tint)
                                            .help("Same chord across all impress apps")
                                    }
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
        .frame(minWidth: 460, minHeight: 420)
    }

    private var filteredGroups: [Group] {
        guard !filter.isEmpty else { return Self.groups }
        return Self.groups.compactMap { group in
            let hits = group.entries.filter {
                $0.action.localizedCaseInsensitiveContains(filter)
                    || $0.chord.localizedCaseInsensitiveContains(filter)
            }
            return hits.isEmpty ? nil : Group(title: group.title, entries: hits)
        }
    }
}
