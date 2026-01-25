//
//  ConsoleView.swift
//  imbib
//
//  Created by Claude on 2026-01-04.
//

import SwiftUI
import PublicationManagerCore

// MARK: - Console View

struct ConsoleView: View {

    // MARK: - State

    @State private var logStore = LogStore.shared
    @State private var searchText = ""
    @State private var showDebug = true
    @State private var showInfo = true
    @State private var showWarning = true
    @State private var showError = true
    @State private var autoScroll = true
    @State private var selection: Set<LogEntry.ID> = []

    // MARK: - Computed

    private var enabledLevels: Set<LogLevel> {
        var levels = Set<LogLevel>()
        if showDebug { levels.insert(.debug) }
        if showInfo { levels.insert(.info) }
        if showWarning { levels.insert(.warning) }
        if showError { levels.insert(.error) }
        return levels
    }

    private var filteredEntries: [LogEntry] {
        logStore.filteredEntries(levels: enabledLevels, searchText: searchText)
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            toolbar
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Log list
            if filteredEntries.isEmpty {
                emptyState
            } else {
                logList
            }
        }
        .frame(minWidth: 600, minHeight: 300)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            // Level filters
            HStack(spacing: 8) {
                FilterToggle(label: "Debug", color: .secondary, isOn: $showDebug)
                FilterToggle(label: "Info", color: .blue, isOn: $showInfo)
                FilterToggle(label: "Warn", color: .orange, isOn: $showWarning)
                FilterToggle(label: "Error", color: .red, isOn: $showError)
            }

            Spacer()

            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter", text: $searchText)
                    .textFieldStyle(.plain)
                    .frame(width: 150)
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
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Divider()
                .frame(height: 20)

            // Actions
            Toggle(isOn: $autoScroll) {
                Image(systemName: "arrow.down.to.line")
            }
            .toggleStyle(.button)
            .help("Auto-scroll to bottom")

            Button {
                copySelectedEntries()
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .disabled(selection.isEmpty)
            .help("Copy selected (\(selection.count))")
            .keyboardShortcut("c", modifiers: .command)

            Button {
                logStore.clear()
            } label: {
                Image(systemName: "trash")
            }
            .help("Clear log")

            Button {
                exportLog()
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .help("Export log")
        }
    }

    // MARK: - Log List

    private var logList: some View {
        ScrollViewReader { proxy in
            List(filteredEntries, selection: $selection) { entry in
                ConsoleRowView(entry: entry)
                    .id(entry.id)
            }
            .listStyle(.plain)
            .font(.system(.body, design: .monospaced))
            .onChange(of: filteredEntries.count) { oldValue, newValue in
                if autoScroll, let last = filteredEntries.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .contextMenu {
                Button("Copy Selected") {
                    copySelectedEntries()
                }
                .disabled(selection.isEmpty)

                Button("Select All") {
                    selection = Set(filteredEntries.map { $0.id })
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No log entries")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Logs will appear here as you use the app")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func exportLog() {
        let content = logStore.export(levels: enabledLevels, searchText: searchText)

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "imbib-log-\(Date().ISO8601Format()).txt"

        if panel.runModal() == .OK, let url = panel.url {
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func copySelectedEntries() {
        guard !selection.isEmpty else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"

        // Get selected entries in order
        let selectedEntries = filteredEntries.filter { selection.contains($0.id) }

        // Format entries
        let text = selectedEntries.map { entry in
            let time = formatter.string(from: entry.timestamp)
            let level = entry.level.rawValue.uppercased()
            return "\(time) [\(level)] [\(entry.category)] \(entry.message)"
        }.joined(separator: "\n")

        // Copy to clipboard
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Filter Toggle

struct FilterToggle: View {
    let label: String
    let color: Color
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(isOn ? color.opacity(0.2) : Color.clear)
                .foregroundStyle(isOn ? color : .secondary)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isOn ? color : Color.secondary.opacity(0.3), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Console Row View

struct ConsoleRowView: View {
    let entry: LogEntry

    private var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: entry.timestamp)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Timestamp
            Text(timeString)
                .foregroundStyle(.secondary)
                .frame(width: 65, alignment: .leading)

            // Level
            Text(entry.level.rawValue.uppercased())
                .foregroundStyle(entry.level.color)
                .frame(width: 55, alignment: .leading)

            // Category
            Text(entry.category)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)

            // Message
            Text(entry.message)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Preview

#Preview {
    ConsoleView()
        .frame(width: 800, height: 400)
}
