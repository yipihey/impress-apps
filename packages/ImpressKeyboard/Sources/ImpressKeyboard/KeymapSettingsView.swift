// The same Rust keymap registry drives menu shortcuts and their reference.
// Overrides remain a later device-setting package (D-R13).

import SwiftUI

/// Settings ▸ Keyboard — a read-only view of the registry, grouped by
/// section in the registry's own order (the same grouping
/// `impress-keymap::render_markdown` uses for `docs/keyboard.md`).
public struct KeymapSettingsView: View {
    private let appID: String

    public init(appID: String) {
        self.appID = appID
    }


    @State private var searchText = ""

    private var sections: [(section: String, entries: [KeymapRegistry.Entry])] {
        var order: [String] = []
        var bySection: [String: [KeymapRegistry.Entry]] = [:]
        for entry in KeymapRegistry.shared.entries(forApp: appID) {
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

    public var body: some View {
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
                .accessibilityLabel("Clear shortcut filter")
            }
        }
        .padding(8)
        #if os(macOS)
        .background(Color(nsColor: .controlBackgroundColor))
        #else
        .background(Color.secondary.opacity(0.1))
        #endif
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

