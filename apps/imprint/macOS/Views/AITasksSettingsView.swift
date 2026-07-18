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

/// Persistence for per-task author preferences (currently: which tasks are
/// disabled). Stored in UserDefaults as an array of disabled action ids.
enum AITaskPreferences {
    private static let disabledKey = "imprint.ai.disabledTasks"

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
}

struct AITasksSettingsView: View {
    private let aiService = AIAssistantService.shared
    @State private var disabled = AITaskPreferences.disabledIDs()

    var body: some View {
        Form {
            Section {
                Label(
                    "Tasks run on \(aiService.provider.displayName). Turn tasks on or off; disabled ones are hidden from the editor's cell-bracket and selection AI menus.",
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
                            Toggle(isOn: binding(for: action.id)) {
                                HStack(spacing: 10) {
                                    Image(systemName: action.effectiveIcon)
                                        .foregroundStyle(.tint)
                                        .frame(width: 20)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(action.title)
                                        Text(Self.outputModeLabel(action.outputMode))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
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
