//
//  IOSConsoleView.swift
//  imbib-iOS
//
//  Created by Claude on 2026-01-07.
//

import SwiftUI
import PublicationManagerCore

/// iOS console view for debugging, presented as a sheet.
struct IOSConsoleView: View {

    // MARK: - Environment

    @Environment(\.dismiss) private var dismiss

    // MARK: - State

    @State private var logStore = LogStore.shared
    @State private var searchText = ""
    @State private var showDebug = true
    @State private var showInfo = true
    @State private var showWarning = true
    @State private var showError = true
    @State private var autoScroll = true

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
        NavigationStack {
            VStack(spacing: 0) {
                // Filter bar
                filterBar
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color(uiColor: .systemGroupedBackground))

                // Search
                searchBar
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    .background(Color(uiColor: .systemGroupedBackground))

                Divider()

                // Log list
                if filteredEntries.isEmpty {
                    emptyState
                } else {
                    logList
                }
            }
            .navigationTitle("Console")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            autoScroll.toggle()
                        } label: {
                            Label(
                                autoScroll ? "Auto-scroll On" : "Auto-scroll Off",
                                systemImage: autoScroll ? "checkmark" : ""
                            )
                        }

                        Divider()

                        Button {
                            copyAllLogs()
                        } label: {
                            Label("Copy All", systemImage: "doc.on.doc")
                        }

                        Button {
                            shareLogs()
                        } label: {
                            Label("Share Logs", systemImage: "square.and.arrow.up")
                        }

                        Divider()

                        Button(role: .destructive) {
                            logStore.clear()
                        } label: {
                            Label("Clear Logs", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                IOSFilterToggle(label: "Debug", color: .secondary, isOn: $showDebug)
                IOSFilterToggle(label: "Info", color: .blue, isOn: $showInfo)
                IOSFilterToggle(label: "Warn", color: .orange, isOn: $showWarning)
                IOSFilterToggle(label: "Error", color: .red, isOn: $showError)

                Spacer()

                Text("\(filteredEntries.count) entries")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter logs...", text: $searchText)
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
        .padding(10)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Log List

    private var logList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(filteredEntries) { entry in
                    IOSConsoleRowView(entry: entry)
                        .id(entry.id)
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                        .contextMenu {
                            Button {
                                copyEntry(entry)
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                        }
                }
            }
            .listStyle(.plain)
            .font(.system(.caption, design: .monospaced))
            .onChange(of: filteredEntries.count) { _, _ in
                if autoScroll, let last = filteredEntries.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ContentUnavailableView(
            "No Log Entries",
            systemImage: "doc.text.magnifyingglass",
            description: Text("Logs will appear here as you use the app")
        )
    }

    // MARK: - Actions

    private func copyEntry(_ entry: LogEntry) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let time = formatter.string(from: entry.timestamp)
        let text = "\(time) [\(entry.level.rawValue.uppercased())] [\(entry.category)] \(entry.message)"
        UIPasteboard.general.string = text
    }

    private func copyAllLogs() {
        let text = logStore.export(levels: enabledLevels, searchText: searchText)
        UIPasteboard.general.string = text
    }

    private func shareLogs() {
        let text = logStore.export(levels: enabledLevels, searchText: searchText)
        let filename = "imbib-log-\(Date().ISO8601Format()).txt"

        // Create temp file
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try? text.write(to: tempURL, atomically: true, encoding: .utf8)

        // Present share sheet
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first?.rootViewController else {
            return
        }

        let activityVC = UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)
        activityVC.popoverPresentationController?.sourceView = rootVC.view
        rootVC.present(activityVC, animated: true)
    }
}

// MARK: - iOS Filter Toggle

struct IOSFilterToggle: View {
    let label: String
    let color: Color
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isOn ? color.opacity(0.2) : Color.clear)
                .foregroundStyle(isOn ? color : .secondary)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(isOn ? color : Color.secondary.opacity(0.3), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - iOS Console Row View

struct IOSConsoleRowView: View {
    let entry: LogEntry

    private var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: entry.timestamp)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                // Timestamp
                Text(timeString)
                    .foregroundStyle(.secondary)

                // Level badge
                Text(entry.level.rawValue.uppercased())
                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                    .foregroundStyle(entry.level.color)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(entry.level.color.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 3))

                // Category
                Text(entry.category)
                    .foregroundStyle(.secondary)

                Spacer()
            }

            // Message
            Text(entry.message)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Preview

#Preview {
    IOSConsoleView()
}
