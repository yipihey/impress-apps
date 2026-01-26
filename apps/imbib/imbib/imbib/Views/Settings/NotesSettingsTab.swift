//
//  NotesSettingsTab.swift
//  imbib
//
//  Created by Claude on 2026-01-09.
//

import SwiftUI
import PublicationManagerCore

/// Settings tab for customizing quick annotations and notes panel behavior.
struct NotesSettingsTab: View {

    // MARK: - State

    @State private var settings = QuickAnnotationSettings.defaults
    @State private var isLoading = true
    @AppStorage("notesPosition") private var notesPositionRaw: String = "below"
    @AppStorage("helixModeEnabled") private var helixModeEnabled = false
    @AppStorage("helixShowModeIndicator") private var helixShowModeIndicator = true

    // Notes position options
    private let notesPositionOptions: [(value: String, label: String)] = [
        ("below", "Below PDF"),
        ("right", "Right of PDF"),
        ("left", "Left of PDF")
    ]

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

            notesPanelSection

            editingModeSection
        }
        .formStyle(.grouped)
        .padding()
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

    // MARK: - Notes Panel Section

    private var notesPanelSection: some View {
        Section("Notes Panel") {
            Picker("Position", selection: $notesPositionRaw) {
                ForEach(notesPositionOptions, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .pickerStyle(.radioGroup)
            .accessibilityIdentifier(AccessibilityID.Settings.Notes.defaultFormatPicker)

            Text("Choose where the notes panel appears relative to the PDF viewer.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Editing Mode Section

    private var editingModeSection: some View {
        Section("Editing Mode") {
            Toggle("Helix-style modal editing", isOn: $helixModeEnabled)
                .accessibilityIdentifier("settings.notes.helixMode")

            if helixModeEnabled {
                Toggle("Show mode indicator", isOn: $helixShowModeIndicator)
                    .accessibilityIdentifier("settings.notes.helixModeIndicator")

                Text("Use hjkl for movement, i/Escape for insert/normal mode")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
            VStack(alignment: .leading, spacing: 8) {
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
