//
//  IOSKeyboardShortcutsSettingsView.swift
//  imbib-iOS
//
//  Created by Claude on 2026-01-09.
//

import SwiftUI
import PublicationManagerCore

/// iOS Settings view for customizing keyboard shortcuts (single-column list).
struct IOSKeyboardShortcutsSettingsView: View {

    // MARK: - State

    @StateObject private var store = KeyboardShortcutsStore.shared
    @State private var searchText = ""
    @State private var editingBinding: KeyboardShortcutBinding?
    @State private var showingResetAlert = false

    // MARK: - Body

    var body: some View {
        List {
            ForEach(ShortcutCategory.allCases, id: \.self) { category in
                categorySection(category)
            }
        }
        .searchable(text: $searchText, prompt: "Filter shortcuts")
        .navigationTitle("Keyboard Shortcuts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button(role: .destructive) {
                        showingResetAlert = true
                    } label: {
                        Label("Reset All to Defaults", systemImage: "arrow.counterclockwise")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(item: $editingBinding) { binding in
            IOSShortcutRecorderSheet(
                binding: binding,
                onSave: { newKey, newModifiers in
                    saveShortcut(binding: binding, key: newKey, modifiers: newModifiers)
                },
                onCancel: {
                    editingBinding = nil
                }
            )
        }
        .alert("Reset All Shortcuts?", isPresented: $showingResetAlert) {
            Button("Reset", role: .destructive) {
                store.resetToDefaults()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will restore all keyboard shortcuts to their default values.")
        }
    }

    // MARK: - Category Section

    @ViewBuilder
    private func categorySection(_ category: ShortcutCategory) -> some View {
        let bindings = filteredBindings(for: category)

        if !bindings.isEmpty {
            Section(category.displayName) {
                ForEach(bindings) { binding in
                    shortcutRow(binding)
                }
            }
        }
    }

    // MARK: - Shortcut Row

    private func shortcutRow(_ binding: KeyboardShortcutBinding) -> some View {
        Button {
            editingBinding = binding
        } label: {
            HStack {
                Text(binding.displayName)
                    .foregroundColor(.primary)

                Spacer()

                Text(binding.displayShortcut)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(.secondarySystemBackground))
                    )
            }
        }
    }

    // MARK: - Filtering

    private func filteredBindings(for category: ShortcutCategory) -> [KeyboardShortcutBinding] {
        let categoryBindings = store.bindings(for: category)

        if searchText.isEmpty {
            return categoryBindings
        }

        let lowercasedSearch = searchText.lowercased()
        return categoryBindings.filter {
            $0.displayName.lowercased().contains(lowercasedSearch) ||
            $0.displayShortcut.lowercased().contains(lowercasedSearch)
        }
    }

    // MARK: - Save Shortcut

    private func saveShortcut(binding: KeyboardShortcutBinding, key: ShortcutKey, modifiers: ShortcutModifiers) {
        var updated = binding
        updated.key = key
        updated.modifiers = modifiers
        store.updateBinding(updated)
        editingBinding = nil
    }
}

// MARK: - iOS Shortcut Recorder Sheet

private struct IOSShortcutRecorderSheet: View {
    let binding: KeyboardShortcutBinding
    let onSave: (ShortcutKey, ShortcutModifiers) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedKey: String = ""
    @State private var commandEnabled = false
    @State private var shiftEnabled = false
    @State private var optionEnabled = false
    @State private var controlEnabled = false

    private let commonKeys = [
        ("A", "a"), ("B", "b"), ("C", "c"), ("D", "d"), ("E", "e"),
        ("F", "f"), ("G", "g"), ("H", "h"), ("I", "i"), ("J", "j"),
        ("K", "k"), ("L", "l"), ("M", "m"), ("N", "n"), ("O", "o"),
        ("P", "p"), ("Q", "q"), ("R", "r"), ("S", "s"), ("T", "t"),
        ("U", "u"), ("V", "v"), ("W", "w"), ("X", "x"), ("Y", "y"),
        ("Z", "z"),
        ("1", "1"), ("2", "2"), ("3", "3"), ("4", "4"), ("5", "5"),
        ("6", "6"), ("7", "7"), ("8", "8"), ("9", "9"), ("0", "0"),
        ("/", "/"), ("\\", "\\"), ("-", "-"), ("+", "+"),
    ]

    private let specialKeys: [(String, ShortcutKey.SpecialKey)] = [
        ("Return", .return),
        ("Escape", .escape),
        ("Delete", .delete),
        ("Tab", .tab),
        ("Space", .space),
        ("Up Arrow", .upArrow),
        ("Down Arrow", .downArrow),
        ("Left Arrow", .leftArrow),
        ("Right Arrow", .rightArrow),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Modifiers") {
                    Toggle("Command", isOn: $commandEnabled)
                    Toggle("Shift", isOn: $shiftEnabled)
                    Toggle("Option", isOn: $optionEnabled)
                    Toggle("Control", isOn: $controlEnabled)
                }

                Section("Key") {
                    Picker("Character Key", selection: $selectedKey) {
                        Text("Select a key").tag("")
                        ForEach(commonKeys, id: \.1) { display, value in
                            Text(display).tag(value)
                        }
                    }

                    ForEach(specialKeys, id: \.1.rawValue) { display, special in
                        Button {
                            selectedKey = "special:\(special.rawValue)"
                        } label: {
                            HStack {
                                Text(display)
                                Spacer()
                                if selectedKey == "special:\(special.rawValue)" {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                        .foregroundColor(.primary)
                    }
                }

                Section {
                    HStack {
                        Text("Preview:")
                        Spacer()
                        Text(previewShortcut)
                            .font(.system(.body, design: .monospaced))
                    }
                }
            }
            .navigationTitle(binding.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveAndDismiss()
                    }
                    .disabled(selectedKey.isEmpty)
                }
            }
            .onAppear {
                loadCurrentBinding()
            }
        }
    }

    private var previewShortcut: String {
        var result = ""
        if controlEnabled { result += "^" }
        if optionEnabled { result += "?" }
        if shiftEnabled { result += "?" }
        if commandEnabled { result += "?" }

        if selectedKey.hasPrefix("special:") {
            let specialName = String(selectedKey.dropFirst("special:".count))
            if let special = ShortcutKey.SpecialKey(rawValue: specialName) {
                result += special.displaySymbol
            }
        } else if !selectedKey.isEmpty {
            result += selectedKey.uppercased()
        }

        return result.isEmpty ? "None" : result
    }

    private func loadCurrentBinding() {
        commandEnabled = binding.modifiers.contains(.command)
        shiftEnabled = binding.modifiers.contains(.shift)
        optionEnabled = binding.modifiers.contains(.option)
        controlEnabled = binding.modifiers.contains(.control)

        switch binding.key {
        case .character(let char):
            selectedKey = char
        case .special(let special):
            selectedKey = "special:\(special.rawValue)"
        }
    }

    private func saveAndDismiss() {
        var modifiers: ShortcutModifiers = []
        if commandEnabled { modifiers.insert(.command) }
        if shiftEnabled { modifiers.insert(.shift) }
        if optionEnabled { modifiers.insert(.option) }
        if controlEnabled { modifiers.insert(.control) }

        let key: ShortcutKey
        if selectedKey.hasPrefix("special:") {
            let specialName = String(selectedKey.dropFirst("special:".count))
            if let special = ShortcutKey.SpecialKey(rawValue: specialName) {
                key = .special(special)
            } else {
                key = .character("")
            }
        } else {
            key = .character(selectedKey)
        }

        onSave(key, modifiers)
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        IOSKeyboardShortcutsSettingsView()
    }
}
