//
//  LibraryPickerView.swift
//  imbib
//
//  Created by Claude on 2026-01-04.
//

import SwiftUI
import PublicationManagerCore

struct LibraryPickerView: View {

    // MARK: - Environment

    @Environment(\.dismiss) private var dismiss
    @Environment(LibraryManager.self) private var libraryManager

    // MARK: - State

    @State private var showingNewLibrary = false
    @State private var newLibraryName = ""

    // MARK: - Body

    var body: some View {
        NavigationStack {
            List {
                // Existing libraries
                Section("Libraries") {
                    ForEach(libraryManager.libraries, id: \.id) { library in
                        LibraryRowView(library: library, isActive: library.id == libraryManager.activeLibrary?.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                libraryManager.setActive(library)
                                dismiss()
                            }
                    }
                }

                // Actions
                Section {
                    Button {
                        showingNewLibrary = true
                    } label: {
                        Label("New Library", systemImage: "plus")
                    }
                }
            }
            .navigationTitle("Libraries")
            #if os(macOS)
            .frame(minWidth: 350, minHeight: 300)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .alert("New Library", isPresented: $showingNewLibrary) {
                TextField("Library Name", text: $newLibraryName)
                Button("Cancel", role: .cancel) {
                    newLibraryName = ""
                }
                Button("Create") {
                    createNewLibrary()
                }
            } message: {
                Text("Enter a name for your new library")
            }
        }
    }

    // MARK: - Actions

    private func createNewLibrary() {
        guard !newLibraryName.isEmpty else { return }

        let library = libraryManager.createLibrary(name: newLibraryName)
        libraryManager.setActive(library)
        newLibraryName = ""
        dismiss()
    }
}

// MARK: - Library Row

struct LibraryRowView: View {
    let library: CDLibrary
    let isActive: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(library.displayName)
                        .font(.headline)
                    if library.isDefault {
                        Text("Default")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.2))
                            .clipShape(Capsule())
                    }
                }

                if let path = library.bibFilePath {
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if isActive {
                Image(systemName: "checkmark")
                    .foregroundStyle(.blue)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    LibraryPickerView()
        .environment(LibraryManager())
}
