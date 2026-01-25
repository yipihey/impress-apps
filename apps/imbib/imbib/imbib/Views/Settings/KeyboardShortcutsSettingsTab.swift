//
//  KeyboardShortcutsSettingsTab.swift
//  imbib
//
//  Created by Claude on 2026-01-09.
//

import SwiftUI
import PublicationManagerCore

/// Settings tab for customizing keyboard shortcuts with multi-column layout.
struct KeyboardShortcutsSettingsTab: View {

    // MARK: - State

    @StateObject private var store = KeyboardShortcutsStore.shared
    @State private var searchText = ""
    @State private var expandedCategories: Set<ShortcutCategory> = Set(ShortcutCategory.allCases)
    @State private var recordingBinding: KeyboardShortcutBinding?
    @State private var conflictAlert: ConflictAlert?

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Header with search and reset
            headerView

            Divider()

            // Scrollable shortcuts list
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(ShortcutCategory.allCases, id: \.self) { category in
                        categorySection(category)
                    }
                }
                .padding()
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .sheet(item: $recordingBinding) { binding in
            ShortcutRecorderSheet(
                binding: binding,
                onSave: { newKey, newModifiers in
                    saveShortcut(binding: binding, key: newKey, modifiers: newModifiers)
                },
                onCancel: {
                    recordingBinding = nil
                }
            )
        }
        .alert(item: $conflictAlert) { alert in
            Alert(
                title: Text("Shortcut Conflict"),
                message: Text("'\(alert.newBinding.displayShortcut)' is already assigned to '\(alert.existingBinding.displayName)'. Replace it?"),
                primaryButton: .destructive(Text("Replace")) {
                    replaceConflictingShortcut(alert)
                },
                secondaryButton: .cancel()
            )
        }
    }

    // MARK: - Header View

    private var headerView: some View {
        HStack {
            // Search field
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
            .cornerRadius(8)
            .frame(maxWidth: 300)

            Spacer()

            // Reset button
            Menu {
                Button("Reset All to Defaults") {
                    store.resetToDefaults()
                }
                Divider()
                ForEach(ShortcutCategory.allCases, id: \.self) { category in
                    Button("Reset \(category.displayName)") {
                        store.resetCategory(category)
                    }
                }
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
        }
        .padding()
    }

    // MARK: - Category Section

    @ViewBuilder
    private func categorySection(_ category: ShortcutCategory) -> some View {
        let bindings = filteredBindings(for: category)

        if !bindings.isEmpty {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { expandedCategories.contains(category) },
                    set: { isExpanded in
                        if isExpanded {
                            expandedCategories.insert(category)
                        } else {
                            expandedCategories.remove(category)
                        }
                    }
                )
            ) {
                // Two-column grid for shortcuts
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 16),
                        GridItem(.flexible(), spacing: 16)
                    ],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(bindings) { binding in
                        shortcutRow(binding)
                    }
                }
                .padding(.top, 8)
            } label: {
                Text(category.displayName.uppercased())
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Shortcut Row

    private func shortcutRow(_ binding: KeyboardShortcutBinding) -> some View {
        HStack {
            Text(binding.displayName)
                .lineLimit(1)

            Spacer()

            Button {
                recordingBinding = binding
            } label: {
                Text(binding.displayShortcut)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(hasConflict(binding) ? Color.red : Color.clear, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help("Click to change shortcut")
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
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

    // MARK: - Conflict Detection

    private func hasConflict(_ binding: KeyboardShortcutBinding) -> Bool {
        let conflicts = store.detectConflicts()
        return conflicts.contains { $0.0.id == binding.id || $0.1.id == binding.id }
    }

    // MARK: - Save Shortcut

    private func saveShortcut(binding: KeyboardShortcutBinding, key: ShortcutKey, modifiers: ShortcutModifiers) {
        // Check for conflicts
        if let existing = store.wouldConflict(key: key, modifiers: modifiers, excluding: binding.id) {
            conflictAlert = ConflictAlert(
                newBinding: KeyboardShortcutBinding(
                    id: binding.id,
                    displayName: binding.displayName,
                    category: binding.category,
                    key: key,
                    modifiers: modifiers,
                    notificationName: binding.notificationName
                ),
                existingBinding: existing
            )
            return
        }

        // No conflict, save directly
        var updated = binding
        updated.key = key
        updated.modifiers = modifiers
        store.updateBinding(updated)
        recordingBinding = nil
    }

    private func replaceConflictingShortcut(_ alert: ConflictAlert) {
        // Clear the existing binding's shortcut
        var clearedExisting = alert.existingBinding
        clearedExisting.key = .character("")
        clearedExisting.modifiers = .none
        store.updateBinding(clearedExisting)

        // Set the new binding
        store.updateBinding(alert.newBinding)
        recordingBinding = nil
    }
}

// MARK: - Conflict Alert

private struct ConflictAlert: Identifiable {
    let id = UUID()
    let newBinding: KeyboardShortcutBinding
    let existingBinding: KeyboardShortcutBinding
}

// MARK: - Shortcut Recorder Sheet

private struct ShortcutRecorderSheet: View {
    let binding: KeyboardShortcutBinding
    let onSave: (ShortcutKey, ShortcutModifiers) -> Void
    let onCancel: () -> Void

    @State private var recordedKey: ShortcutKey?
    @State private var recordedModifiers: ShortcutModifiers = .none
    @State private var isRecording = false

    var body: some View {
        VStack(spacing: 20) {
            Text("Set Shortcut for \"\(binding.displayName)\"")
                .font(.headline)

            Text("Press the key combination you want to use")
                .foregroundStyle(.secondary)

            // Recorder view
            ShortcutRecorderView(
                key: $recordedKey,
                modifiers: $recordedModifiers,
                isRecording: $isRecording
            )
            .frame(width: 200, height: 40)

            // Current shortcut display
            if let key = recordedKey {
                Text("New shortcut: \(recordedModifiers.displayString)\(key.displayString)")
                    .font(.system(.body, design: .monospaced))
            } else {
                Text("Current: \(binding.displayShortcut)")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.escape, modifiers: [])

                Button("Clear") {
                    recordedKey = .character("")
                    recordedModifiers = .none
                }

                Button("Save") {
                    if let key = recordedKey {
                        onSave(key, recordedModifiers)
                    }
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(recordedKey == nil)
            }
        }
        .padding(24)
        .frame(width: 350)
        .onAppear {
            isRecording = true
        }
    }
}

// MARK: - Shortcut Recorder View (macOS)

struct ShortcutRecorderView: NSViewRepresentable {
    @Binding var key: ShortcutKey?
    @Binding var modifiers: ShortcutModifiers
    @Binding var isRecording: Bool

    func makeNSView(context: Context) -> ShortcutRecorderNSView {
        let view = ShortcutRecorderNSView()
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderNSView, context: Context) {
        nsView.isRecording = isRecording
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: ShortcutRecorderDelegate {
        var parent: ShortcutRecorderView

        init(_ parent: ShortcutRecorderView) {
            self.parent = parent
        }

        func shortcutRecorder(_ recorder: ShortcutRecorderNSView, didRecordKey key: ShortcutKey, modifiers: ShortcutModifiers) {
            parent.key = key
            parent.modifiers = modifiers
        }
    }
}

// MARK: - ShortcutRecorderNSView

protocol ShortcutRecorderDelegate: AnyObject {
    func shortcutRecorder(_ recorder: ShortcutRecorderNSView, didRecordKey key: ShortcutKey, modifiers: ShortcutModifiers)
}

class ShortcutRecorderNSView: NSView {
    weak var delegate: ShortcutRecorderDelegate?
    var isRecording = false {
        didSet {
            if isRecording {
                window?.makeFirstResponder(self)
            }
            needsDisplay = true
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Background
        let bgColor: NSColor = isRecording ? .controlAccentColor.withAlphaComponent(0.1) : .controlBackgroundColor
        bgColor.setFill()
        let path = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        path.fill()

        // Border
        let borderColor: NSColor = isRecording ? .controlAccentColor : .separatorColor
        borderColor.setStroke()
        path.lineWidth = isRecording ? 2 : 1
        path.stroke()

        // Text
        let text = isRecording ? "Press keys..." : "Click to record"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let size = text.size(withAttributes: attributes)
        let point = NSPoint(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2
        )
        text.draw(at: point, withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        isRecording = true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        let key = parseKey(from: event)
        let modifiers = parseModifiers(from: event)

        delegate?.shortcutRecorder(self, didRecordKey: key, modifiers: modifiers)
        isRecording = false
    }

    private func parseKey(from event: NSEvent) -> ShortcutKey {
        // Check for special keys first
        switch event.keyCode {
        case 36: return .special(.return)
        case 53: return .special(.escape)
        case 51: return .special(.delete)
        case 48: return .special(.tab)
        case 49: return .special(.space)
        case 126: return .special(.upArrow)
        case 125: return .special(.downArrow)
        case 123: return .special(.leftArrow)
        case 124: return .special(.rightArrow)
        case 115: return .special(.home)
        case 119: return .special(.end)
        case 116: return .special(.pageUp)
        case 121: return .special(.pageDown)
        case 24: return .special(.plus)
        case 27: return .special(.minus)
        default:
            if let chars = event.charactersIgnoringModifiers?.lowercased(), !chars.isEmpty {
                return .character(String(chars.first!))
            }
            return .character("")
        }
    }

    private func parseModifiers(from event: NSEvent) -> ShortcutModifiers {
        var result: ShortcutModifiers = []
        if event.modifierFlags.contains(.command) { result.insert(.command) }
        if event.modifierFlags.contains(.shift) { result.insert(.shift) }
        if event.modifierFlags.contains(.option) { result.insert(.option) }
        if event.modifierFlags.contains(.control) { result.insert(.control) }
        return result
    }
}

// MARK: - Preview

#Preview {
    KeyboardShortcutsSettingsTab()
        .frame(width: 700, height: 500)
}
