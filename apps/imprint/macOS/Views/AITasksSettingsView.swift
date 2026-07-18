//
//  AITasksSettingsView.swift
//  imprint
//
//  Settings editor for the configurable AI author-tasks. Lets the author
//  enable/disable each task; disabled tasks are hidden from the cell-bracket
//  and selection "AI" menus. (Prompt editing + per-task model overrides are a
//  planned follow-up.)
//

import SwiftUI

/// Persistence for per-task author preferences: which tasks are disabled, and
/// per-task prompt overrides. Stored in UserDefaults.
enum AITaskPreferences {
    private static let disabledKey = "imprint.ai.disabledTasks"
    private static let promptsKey = "imprint.ai.promptOverrides"

    static func disabledIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: disabledKey) ?? [])
    }

    static func isEnabled(_ id: String) -> Bool {
        !disabledIDs().contains(id)
    }

    static func setEnabled(_ enabled: Bool, for id: String) {
        var ids = disabledIDs()
        if enabled { ids.remove(id) } else { ids.insert(id) }
        UserDefaults.standard.set(Array(ids), forKey: disabledKey)
    }

    // MARK: - Prompt overrides

    private static func promptMap() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: promptsKey) as? [String: String] ?? [:]
    }

    /// A user-edited prompt for `id`, if any (else the built-in is used).
    static func promptOverride(for id: String) -> String? {
        promptMap()[id]
    }

    /// Set (or clear, when `prompt` is nil/blank) a per-task prompt override.
    static func setPromptOverride(_ prompt: String?, for id: String) {
        var map = promptMap()
        if let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            map[id] = prompt
        } else {
            map.removeValue(forKey: id)
        }
        UserDefaults.standard.set(map, forKey: promptsKey)
    }
}

struct AITasksSettingsView: View {
    private let aiService = AIAssistantService.shared
    @State private var disabled = AITaskPreferences.disabledIDs()
    @State private var editingAction: AIAction?
    /// Bumped when a prompt override changes, to refresh the "Custom prompt" badges.
    @State private var promptsVersion = 0

    var body: some View {
        Form {
            Section {
                Label(
                    "Tasks run on \(aiService.provider.displayName). Turn tasks on or off, or edit a task's prompt. Disabled ones are hidden from the editor's cell-bracket and selection AI menus.",
                    systemImage: "sparkles"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            ForEach(AIActionCategory.allCases) { category in
                let actions = AIContextMenuService.shared.actions.filter { $0.category == category }
                if !actions.isEmpty {
                    Section(category.title) {
                        ForEach(actions) { action in
                            taskRow(action)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .sheet(item: $editingAction) { action in
            AITaskPromptEditor(action: action) {
                promptsVersion += 1
            }
        }
    }

    @ViewBuilder
    private func taskRow(_ action: AIAction) -> some View {
        let hasOverride = AITaskPreferences.promptOverride(for: action.id) != nil
        HStack(spacing: 10) {
            Image(systemName: action.effectiveIcon)
                .foregroundStyle(.tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(action.title)
                HStack(spacing: 6) {
                    Text(Self.outputModeLabel(action.outputMode))
                    if hasOverride {
                        Text("· Custom prompt").foregroundStyle(.tint)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                editingAction = action
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit this task's prompt")
            Toggle("", isOn: binding(for: action.id))
                .labelsHidden()
        }
        .id(promptsVersion)  // refresh badge after an edit
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { !disabled.contains(id) },
            set: { isOn in
                AITaskPreferences.setEnabled(isOn, for: id)
                disabled = AITaskPreferences.disabledIDs()
            }
        )
    }

    private static func outputModeLabel(_ mode: TaskOutputMode) -> String {
        switch mode {
        case .replace: return "Rewrites the selection"
        case .insertAfter: return "Inserts after the selection"
        case .advisory: return "Shows advice (read-only)"
        case .annotateAsComment: return "Adds inline review comments"
        case .proposeCitations: return "Suggests citations from imbib"
        case .sideBySideDiff: return "Shows a diff to accept or reject"
        }
    }
}

/// Sheet for editing a single task's prompt template.
private struct AITaskPromptEditor: View {
    let action: AIAction
    var onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var prompt: String

    init(action: AIAction, onSaved: @escaping () -> Void) {
        self.action = action
        self.onSaved = onSaved
        _prompt = State(initialValue: AITaskPreferences.promptOverride(for: action.id) ?? action.systemPrompt)
    }

    private var isOverridden: Bool { AITaskPreferences.promptOverride(for: action.id) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: action.effectiveIcon).foregroundStyle(.tint)
                Text(action.title).font(.headline)
                Spacer()
            }
            Text("Prompt sent to the model. Available variables:")
                .font(.caption).foregroundStyle(.secondary)
            Text("{{selection}} · {{paragraph}} · {{section_heading}} · {{document_title}} · {{outline}} · {{surrounding_sections}} · {{cited_papers}}")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            TextEditor(text: $prompt)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 200)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))

            HStack {
                Button("Reset to Default") {
                    AITaskPreferences.setPromptOverride(nil, for: action.id)
                    onSaved()
                    dismiss()
                }
                .disabled(!isOverridden && prompt == action.systemPrompt)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Save") {
                    // Store nil (built-in) when unchanged, else the edited prompt.
                    let override = prompt == action.systemPrompt ? nil : prompt
                    AITaskPreferences.setPromptOverride(override, for: action.id)
                    onSaved()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .padding(20)
        .frame(width: 540, height: 440)
    }
}
