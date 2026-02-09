//
//  IOSBibTeXTab.swift
//  imbib-iOS
//
//  Created by Claude on 2026-01-07.
//

import SwiftUI
import PublicationManagerCore

/// iOS BibTeX tab for viewing and editing BibTeX entries.
/// Uses RustStoreAdapter for all data access (no Core Data).
struct IOSBibTeXTab: View {
    let publicationID: UUID

    @State private var bibtexContent: String = ""
    @State private var isEditing = false
    @State private var hasChanges = false
    @State private var showSaveAlert = false

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Spacer()

                if isEditing {
                    Button("Cancel") {
                        cancelEditing()
                    }

                    Button("Save") {
                        saveBibTeX()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasChanges)
                } else {
                    Button {
                        isEditing = true
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                }
            }
            .padding()
            .background(.bar)

            // Editor
            BibTeXEditor(
                text: $bibtexContent,
                isEditable: isEditing,
                showLineNumbers: true
            ) { _ in
                saveBibTeX()
            }
            .onChange(of: bibtexContent) { _, _ in
                if isEditing {
                    hasChanges = true
                }
            }
        }
        .onChange(of: publicationID, initial: true) { _, _ in
            loadBibTeX()
            isEditing = false
            hasChanges = false
        }
        .alert("Unsaved Changes", isPresented: $showSaveAlert) {
            Button("Discard", role: .destructive) {
                isEditing = false
                hasChanges = false
                loadBibTeX()
            }
            Button("Save") {
                saveBibTeX()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You have unsaved changes. Would you like to save them?")
        }
    }

    // MARK: - Private Methods

    private func loadBibTeX() {
        let store = RustStoreAdapter.shared
        let bibtex = store.exportBibTeX(ids: [publicationID])
        bibtexContent = bibtex
    }

    private func saveBibTeX() {
        Task {
            do {
                // Parse and validate
                let items = try BibTeXParserFactory.createParser().parse(bibtexContent)
                guard let entry = items.compactMap({ item -> BibTeXEntry? in
                    if case .entry(let entry) = item { return entry }
                    return nil
                }).first else {
                    return
                }

                // Update via Rust store - update fields from the parsed entry
                let store = RustStoreAdapter.shared
                for (key, value) in entry.fields {
                    store.updateField(id: publicationID, field: key, value: value)
                }

                await MainActor.run {
                    isEditing = false
                    hasChanges = false
                }
            } catch {
                // BibTeXEditor handles validation errors
            }
        }
    }

    private func cancelEditing() {
        if hasChanges {
            showSaveAlert = true
        } else {
            isEditing = false
            loadBibTeX()
        }
    }
}
