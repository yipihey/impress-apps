//
//  CommandPaletteView.swift
//  ImpressCommandPalette
//
//  Universal command palette UI for cross-app command discovery and execution.
//

import SwiftUI

// MARK: - Command Palette View

/// Universal command palette that searches across all running impress apps.
///
/// Usage:
/// ```swift
/// .sheet(isPresented: $showCommandPalette) {
///     CommandPaletteView { command in
///         // Execute the command via its URI
///         NSWorkspace.shared.open(URL(string: command.uri)!)
///     }
/// }
/// ```
public struct CommandPaletteView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var commands: [Command] = []
    @State private var filteredCommands: [Command] = []
    @State private var selectedIndex = 0
    @State private var isLoading = true
    @State private var runningApps: [String] = []

    private let client: CommandPaletteClient
    private let onExecute: (Command) -> Void

    public init(
        client: CommandPaletteClient = CommandPaletteClient(),
        onExecute: @escaping (Command) -> Void
    ) {
        self.client = client
        self.onExecute = onExecute
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Search field
            searchField

            Divider()

            // Results
            if isLoading {
                loadingView
            } else if filteredCommands.isEmpty {
                emptyView
            } else {
                resultsList
            }

            Divider()

            // Footer with running apps
            footer
        }
        .frame(width: 600, height: 400)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 20)
        .task {
            await loadCommands()
        }
        .onChange(of: searchText) { _, newValue in
            updateFiltered()
            selectedIndex = 0
        }
    }

    // MARK: - Subviews

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.title2)

            TextField("Search commands across all apps...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.title3)
                .onSubmit {
                    executeSelected()
                }

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Discovering commands...")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.largeTitle)
                .foregroundColor(.secondary)

            if searchText.isEmpty {
                Text("No commands available")
                    .foregroundColor(.secondary)
                Text("Make sure at least one impress app is running")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("No commands match \"\(searchText)\"")
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            List(selection: Binding(
                get: { filteredCommands.indices.contains(selectedIndex) ? filteredCommands[selectedIndex].id : nil },
                set: { newValue in
                    if let id = newValue,
                       let index = filteredCommands.firstIndex(where: { $0.id == id }) {
                        selectedIndex = index
                    }
                }
            )) {
                ForEach(Array(filteredCommands.enumerated()), id: \.element.id) { index, command in
                    CommandRow(command: command, isSelected: index == selectedIndex)
                        .id(command.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedIndex = index
                            executeSelected()
                        }
                }
            }
            .listStyle(.plain)
            .onChange(of: selectedIndex) { _, newIndex in
                if filteredCommands.indices.contains(newIndex) {
                    withAnimation {
                        proxy.scrollTo(filteredCommands[newIndex].id, anchor: .center)
                    }
                }
            }
        }
        .onKeyPress(.upArrow) {
            moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.return) {
            executeSelected()
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }

    private var footer: some View {
        HStack {
            if runningApps.isEmpty {
                Text("No apps running")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                HStack(spacing: 4) {
                    ForEach(runningApps, id: \.self) { app in
                        AppBadge(app: app)
                    }
                }
            }

            Spacer()

            HStack(spacing: 16) {
                KeyHint(key: "↑↓", label: "Navigate")
                KeyHint(key: "↩", label: "Execute")
                KeyHint(key: "esc", label: "Close")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Actions

    private func loadCommands() async {
        isLoading = true

        async let commandsTask = client.allCommands(forceRefresh: true)
        async let appsTask = client.runningApps()

        commands = await commandsTask
        runningApps = await appsTask

        updateFiltered()
        isLoading = false
    }

    private func updateFiltered() {
        filteredCommands = commands.filtered(by: searchText)
    }

    private func moveSelection(by delta: Int) {
        let newIndex = selectedIndex + delta
        if filteredCommands.indices.contains(newIndex) {
            selectedIndex = newIndex
        }
    }

    private func executeSelected() {
        guard filteredCommands.indices.contains(selectedIndex) else { return }
        let command = filteredCommands[selectedIndex]
        dismiss()
        onExecute(command)
    }
}

// MARK: - Command Row

struct CommandRow: View {
    let command: Command
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            if let icon = command.icon {
                Image(systemName: icon)
                    .frame(width: 24)
                    .foregroundColor(isSelected ? .white : .secondary)
            } else {
                Image(systemName: "command")
                    .frame(width: 24)
                    .foregroundColor(isSelected ? .white : .secondary)
            }

            // Name and description
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(command.name)
                        .fontWeight(.medium)

                    Text(command.app)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(isSelected ? Color.white.opacity(0.2) : Color.secondary.opacity(0.2))
                        .cornerRadius(4)
                }

                if let description = command.description {
                    Text(description)
                        .font(.caption)
                        .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Shortcut
            if let shortcut = command.shortcut {
                Text(shortcut)
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(isSelected ? Color.white.opacity(0.2) : Color.secondary.opacity(0.15))
                    .cornerRadius(4)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(isSelected ? Color.accentColor : Color.clear)
        .foregroundColor(isSelected ? .white : .primary)
        .cornerRadius(6)
    }
}

// MARK: - App Badge

struct AppBadge: View {
    let app: String

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.green)
                .frame(width: 6, height: 6)
            Text(app)
                .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(4)
    }
}

// MARK: - Key Hint

struct KeyHint: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(.caption2, design: .monospaced))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.2))
                .cornerRadius(3)

            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Preview

#Preview {
    CommandPaletteView { command in
        print("Execute: \(command.uri)")
    }
    .padding(40)
    .background(Color.gray.opacity(0.3))
}
