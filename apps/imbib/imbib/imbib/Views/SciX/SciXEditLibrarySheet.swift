//
//  SciXEditLibrarySheet.swift
//  imbib
//

import SwiftUI
import PublicationManagerCore

/// Sheet for editing SciX library metadata (name, description, public visibility).
/// Available to library owners and admins.
struct SciXEditLibrarySheet: View {

    let library: SciXLibrary
    var viewModel: SciXLibraryViewModel

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var description: String
    @State private var isPublic: Bool
    @State private var isSaving = false
    @State private var saveError: String?

    init(library: SciXLibrary, viewModel: SciXLibraryViewModel) {
        self.library = library
        self.viewModel = viewModel
        _name = State(initialValue: library.name)
        _description = State(initialValue: library.description ?? "")
        _isPublic = State(initialValue: library.isPublic)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Library Name") {
                    TextField("Name", text: $name)
                }

                Section("Description") {
                    TextEditor(text: $description)
                        .frame(minHeight: 80)
                }

                Section {
                    Toggle("Public library", isOn: $isPublic)
                    if isPublic {
                        Text("Public libraries are visible to all ADS/SciX users.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Private libraries are only visible to you and collaborators.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Visibility")
                }

                if let error = saveError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Edit Library")
            #if os(macOS)
            .navigationSubtitle(library.name)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                }
            }
            .disabled(isSaving)
        }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 300)
        #endif
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }
        isSaving = true
        saveError = nil
        Task {
            do {
                try await viewModel.saveMetadata(
                    library: library,
                    name: trimmedName,
                    description: description.isEmpty ? nil : description,
                    isPublic: isPublic
                )
                dismiss()
            } catch {
                saveError = error.localizedDescription
                isSaving = false
            }
        }
    }
}
