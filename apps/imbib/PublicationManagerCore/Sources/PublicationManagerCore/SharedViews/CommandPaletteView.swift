//
//  CommandPaletteView.swift
//  PublicationManagerCore
//
//  Global command palette UI (Cmd+Shift+P).
//

import SwiftUI

// MARK: - Command Palette View

/// A command palette overlay for executing app commands.
///
/// Displays a centered modal with:
/// - Auto-focused search field
/// - Scrollable command list grouped by category
/// - Keyboard shortcuts displayed inline
/// - Keyboard navigation (arrow keys, Enter, Escape)
public struct CommandPaletteView: View {

    // MARK: - Bindings

    @Binding var isPresented: Bool

    // MARK: - State

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var isSearchFieldFocused: Bool

    // MARK: - Properties

    private var filteredCommands: [Command] {
        CommandRegistry.shared.search(query)
    }

    // MARK: - Initialization

    public init(isPresented: Binding<Bool>) {
        self._isPresented = isPresented
    }

    // MARK: - Body

    public var body: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture {
                    dismiss()
                }

            // Palette container
            VStack(spacing: 0) {
                // Search field
                searchField

                Divider()

                // Commands list
                if filteredCommands.isEmpty {
                    noResultsView
                } else {
                    commandsList
                }
            }
            .frame(width: 500, height: 400)
            .background(paletteBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
            // Keyboard handlers
            .onKeyPress(.upArrow) {
                selectPrevious()
                return .handled
            }
            .onKeyPress(.downArrow) {
                selectNext()
                return .handled
            }
            .onKeyPress(.return) {
                executeSelectedCommand()
                return .handled
            }
            .onKeyPress(.escape) {
                dismiss()
                return .handled
            }
        }
        .onAppear {
            // Delay focus slightly to ensure the view is fully rendered
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isSearchFieldFocused = true
            }
        }
        .onChange(of: query) { _, _ in
            // Reset selection when query changes
            selectedIndex = 0
        }
    }

    // MARK: - Search Field

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "command")
                .foregroundStyle(.secondary)
                .font(.title3)

            TextField("Type a command...", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($isSearchFieldFocused)
                .onSubmit {
                    executeSelectedCommand()
                }

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Commands List

    private var commandsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(filteredCommands.enumerated()), id: \.element.id) { index, command in
                        commandRow(command: command, index: index)
                    }
                }
            }
            .onChange(of: selectedIndex) { _, newIndex in
                if let command = filteredCommands[safe: newIndex] {
                    proxy.scrollTo(command.id, anchor: .center)
                }
            }
        }
    }

    private func commandRow(command: Command, index: Int) -> some View {
        let isSelected = index == selectedIndex

        return Button {
            execute(command)
        } label: {
            HStack(spacing: 12) {
                // Category badge
                Text(command.category.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.15))
                    )

                // Command title
                Text(command.title)
                    .font(.body)

                Spacer()

                // Keyboard shortcut
                if let shortcut = command.shortcut {
                    Text(shortcut)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(command.id)
        .onHover { hovering in
            if hovering {
                selectedIndex = index
            }
        }
    }

    // MARK: - Empty State

    private var noResultsView: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.title)
                .foregroundStyle(.tertiary)

            Text("No commands found")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("Try a different search term")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Actions

    private func selectPrevious() {
        if selectedIndex > 0 {
            selectedIndex -= 1
        }
    }

    private func selectNext() {
        if selectedIndex < filteredCommands.count - 1 {
            selectedIndex += 1
        }
    }

    private func executeSelectedCommand() {
        guard let command = filteredCommands[safe: selectedIndex] else { return }
        execute(command)
    }

    private func execute(_ command: Command) {
        dismiss()
        // Small delay to let the palette dismiss before executing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            command.execute()
        }
    }

    private func dismiss() {
        isPresented = false
    }

    // MARK: - Styling

    private var paletteBackground: some View {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(.systemBackground)
        #endif
    }
}

// MARK: - Array Safe Access

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
