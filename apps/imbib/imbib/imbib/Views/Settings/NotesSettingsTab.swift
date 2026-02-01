//
//  NotesSettingsTab.swift
//  imbib
//
//  Created by Claude on 2026-01-09.
//

import SwiftUI
import PublicationManagerCore
import ImpressHelixCore

/// Settings tab for customizing quick annotations and notes panel behavior.
struct NotesSettingsTab: View {

    // MARK: - State

    @State private var settings = QuickAnnotationSettings.defaults
    @State private var isLoading = true
    @Bindable private var modalSettings = ModalEditingSettings.shared

    // MARK: - Body

    var body: some View {
        Form {
            quickAnnotationsSection

            Section {
                Button("Reset to Defaults") {
                    Task {
                        await QuickAnnotationSettingsStore.shared.resetToDefaults()
                        settings = await QuickAnnotationSettingsStore.shared.settings
                    }
                }
            }

            editingModeSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding(.horizontal)
        .task {
            settings = await QuickAnnotationSettingsStore.shared.settings
            isLoading = false
        }
        .onChange(of: settings) { _, newSettings in
            guard !isLoading else { return }
            Task {
                await QuickAnnotationSettingsStore.shared.update(newSettings)
            }
        }
    }

    // MARK: - Quick Annotations Section

    private var quickAnnotationsSection: some View {
        Section {
            ForEach($settings.fields) { $field in
                QuickAnnotationFieldRow(field: $field, onDelete: {
                    deleteField(id: field.id)
                })
            }
            .onMove { source, destination in
                settings.fields.move(fromOffsets: source, toOffset: destination)
                saveSettings()
            }

            Button {
                addNewField()
            } label: {
                Label("Add Field", systemImage: "plus.circle")
            }
        } header: {
            Text("Quick Annotations")
        } footer: {
            Text("Customize the quick annotation fields shown in the notes panel. Drag to reorder.")
        }
    }

    // MARK: - Editing Mode Section

    private var editingModeSection: some View {
        Section("Modal Editing") {
            Toggle("Enable modal editing", isOn: $modalSettings.isEnabled)
                .accessibilityIdentifier("settings.notes.modalEditing")

            if modalSettings.isEnabled {
                Picker("Style", selection: $modalSettings.selectedStyle) {
                    ForEach(EditorStyleIdentifier.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .accessibilityIdentifier("settings.notes.modalStyle")

                Toggle("Show mode indicator", isOn: $modalSettings.showModeIndicator)
                    .accessibilityIdentifier("settings.notes.modeIndicator")

                styleDescription
            }
        }
    }

    @ViewBuilder
    private var styleDescription: some View {
        switch modalSettings.selectedStyle {
        case .helix:
            Text("Selection-first editing: select text, then act on it")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .vim:
            Text("Verb-object grammar: type operator (d/c/y), then motion")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .emacs:
            Text("Chorded keys: Control and Meta for commands, always insert mode")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func addNewField() {
        let newField = QuickAnnotationSettings.createNewField()
        settings.fields.append(newField)
        saveSettings()
    }

    private func deleteField(id: String) {
        settings.fields.removeAll { $0.id == id }
        saveSettings()
    }

    private func saveSettings() {
        guard !isLoading else { return }
        Task {
            await QuickAnnotationSettingsStore.shared.update(settings)
        }
    }
}

// MARK: - Quick Annotation Field Row

/// A row for editing a single quick annotation field.
private struct QuickAnnotationFieldRow: View {
    @Binding var field: QuickAnnotationField
    let onDelete: () -> Void

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Label") {
                    TextField("Field label", text: $field.label)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 250)
                }

                LabeledContent("Placeholder") {
                    TextField("Placeholder text", text: $field.placeholder)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 250)
                }

                HStack {
                    Spacer()
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Label("Delete Field", systemImage: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.vertical, 4)
        } label: {
            HStack {
                Toggle("", isOn: $field.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.checkbox)

                Text(field.label)
                    .foregroundStyle(field.isEnabled ? .primary : .secondary)

                Spacer()
            }
        }
    }
}

// MARK: - Preview

#Preview {
    NotesSettingsTab()
        .frame(width: 500, height: 600)
}
