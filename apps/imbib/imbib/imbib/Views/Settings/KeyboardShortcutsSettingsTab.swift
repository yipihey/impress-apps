//
//  KeyboardShortcutsSettingsTab.swift
//  imbib
//
//  Created by Claude on 2026-01-09.
//  R2b (plan-self-reflective-layer.md § Registries): now shows the ONE
//  keymap registry (`impress-keymap`, decoded here through
//  `KeymapRegistry`), not the menu's own literals — imbib's menu bar and
//  this settings tab were two independent hand-typed lists before R2, and
//  drift between them was invisible (RG-4). A plain, read-only list on
//  purpose: chord overrides are a device setting for later (D-R13), out of
//  this pass's scope.
//

import ImpressKeyboard
import SwiftUI

/// Settings ▸ Keyboard — a read-only view of the registry, grouped by
/// section in the registry's own order (the same grouping
/// `impress-keymap::render_markdown` uses for `docs/keyboard.md`).
struct KeyboardShortcutsSettingsTab: View {

    @State private var searchText = ""

    private var sections: [(section: String, entries: [KeymapRegistry.Entry])] {
        var order: [String] = []
        var bySection: [String: [KeymapRegistry.Entry]] = [:]
        for entry in KeymapRegistry.shared.entries {
            if !order.contains(entry.section) {
                order.append(entry.section)
            }
            bySection[entry.section, default: []].append(entry)
        }
        return order.compactMap { section in
            let entries = filtered(bySection[section] ?? [])
            return entries.isEmpty ? nil : (section, entries)
        }
    }

    private func filtered(_ entries: [KeymapRegistry.Entry]) -> [KeymapRegistry.Entry] {
        guard !searchText.isEmpty else { return entries }
        let needle = searchText.lowercased()
        return entries.filter {
            $0.label.lowercased().contains(needle) || $0.chord.lowercased().contains(needle)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            List {
                ForEach(sections, id: \.section) { group in
                    Section(group.section) {
                        ForEach(Array(group.entries.enumerated()), id: \.offset) { _, entry in
                            row(entry)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 500, minHeight: 400)
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter shortcuts...", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(.rect(cornerRadius: 8))
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func row(_ entry: KeymapRegistry.Entry) -> some View {
        HStack {
            Text(entry.label)
                .lineLimit(1)
            Spacer()
            Text(entry.chordless || entry.chord.isEmpty ? "—" : entry.chord)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Preview

#Preview {
    KeyboardShortcutsSettingsTab()
        .frame(width: 600, height: 500)
}
