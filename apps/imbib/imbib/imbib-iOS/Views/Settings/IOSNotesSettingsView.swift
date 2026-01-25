//
//  IOSNotesSettingsView.swift
//  imbib-iOS
//
//  Created by Claude on 2026-01-17.
//

import SwiftUI
import PublicationManagerCore

/// iOS settings view for customizing quick annotations and notes panel behavior.
struct IOSNotesSettingsView: View {

    // MARK: - State

    @State private var settings = QuickAnnotationSettings.defaults
    @State private var isLoading = true
    @State private var editingField: QuickAnnotationField?

    // MARK: - Body

    var body: some View {
        List {
            quickAnnotationsSection
            resetSection
        }
        .navigationTitle("Notes")
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
        .sheet(item: $editingField) { field in
            EditQuickAnnotationFieldSheet(field: field) { updatedField in
                if let index = settings.fields.firstIndex(where: { $0.id == updatedField.id }) {
                    settings.fields[index] = updatedField
                }
            }
        }
    }

    // MARK: - Quick Annotations Section

    private var quickAnnotationsSection: some View {
        Section {
            ForEach($settings.fields) { $field in
                QuickAnnotationFieldRow(field: $field) {
                    editingField = field
                }
            }
            .onMove { source, destination in
                settings.fields.move(fromOffsets: source, toOffset: destination)
            }
            .onDelete { indexSet in
                settings.fields.remove(atOffsets: indexSet)
            }

            Button {
                addNewField()
            } label: {
                Label("Add Field", systemImage: "plus.circle")
            }
        } header: {
            Text("Quick Annotations")
        } footer: {
            Text("Customize the quick annotation fields shown in the notes panel. Tap to edit, swipe to delete, or drag to reorder.")
        }
    }

    // MARK: - Reset Section

    private var resetSection: some View {
        Section {
            Button("Reset to Defaults") {
                Task {
                    await QuickAnnotationSettingsStore.shared.resetToDefaults()
                    settings = await QuickAnnotationSettingsStore.shared.settings
                }
            }
        }
    }

    // MARK: - Actions

    private func addNewField() {
        let newField = QuickAnnotationSettings.createNewField()
        settings.fields.append(newField)
    }
}

// MARK: - Quick Annotation Field Row

/// A row for displaying and toggling a single quick annotation field.
private struct QuickAnnotationFieldRow: View {
    @Binding var field: QuickAnnotationField
    let onEdit: () -> Void

    var body: some View {
        Button(action: onEdit) {
            HStack {
                Toggle("", isOn: $field.isEnabled)
                    .labelsHidden()

                VStack(alignment: .leading, spacing: 2) {
                    Text(field.label)
                        .foregroundStyle(field.isEnabled ? .primary : .secondary)
                    if !field.placeholder.isEmpty {
                        Text(field.placeholder)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Edit Quick Annotation Field Sheet

/// Sheet for editing a quick annotation field's label and placeholder.
private struct EditQuickAnnotationFieldSheet: View {
    @Environment(\.dismiss) private var dismiss

    let field: QuickAnnotationField
    let onSave: (QuickAnnotationField) -> Void

    @State private var label: String = ""
    @State private var placeholder: String = ""
    @State private var isEnabled: Bool = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Label", text: $label)
                    TextField("Placeholder", text: $placeholder)
                }

                Section {
                    Toggle("Enabled", isOn: $isEnabled)
                }
            }
            .navigationTitle("Edit Field")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var updatedField = field
                        updatedField.label = label
                        updatedField.placeholder = placeholder
                        updatedField.isEnabled = isEnabled
                        onSave(updatedField)
                        dismiss()
                    }
                    .disabled(label.isEmpty)
                }
            }
            .onAppear {
                label = field.label
                placeholder = field.placeholder
                isEnabled = field.isEnabled
            }
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        IOSNotesSettingsView()
    }
}
