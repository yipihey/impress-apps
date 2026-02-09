//
//  IOSBibTeXEditorSheet.swift
//  imbib-iOS
//
//  Created by Claude on 2026-01-18.
//

import SwiftUI
import PublicationManagerCore

/// A modal sheet for viewing and editing a publication's BibTeX entry on iOS.
/// Uses RustStoreAdapter for all data access (no Core Data).
struct IOSBibTeXEditorSheet: View {

    // MARK: - Environment

    @Environment(\.dismiss) private var dismiss

    // MARK: - Properties

    /// The publication ID to edit
    let publicationID: UUID

    /// Callback when BibTeX is saved
    var onSave: ((String) -> Void)?

    // MARK: - State

    @State private var bibtexText: String = ""
    @State private var isEditing: Bool = false
    @State private var validationError: String?
    @State private var showingDiscardAlert: Bool = false
    @State private var originalBibTeX: String = ""

    // MARK: - Computed

    private var hasChanges: Bool {
        bibtexText != originalBibTeX
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Validation error banner
                if let error = validationError {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text(error)
                            .font(.caption)
                        Spacer()
                    }
                    .padding(8)
                    .background(Color.red.opacity(0.1))
                }

                // BibTeX content
                if isEditing {
                    IOSBibTeXEditorView(
                        text: $bibtexText,
                        onSave: {
                            saveBibTeX()
                        },
                        onValidate: { newValue in
                            validateBibTeX(newValue)
                        }
                    )
                } else {
                    ScrollView {
                        Text(bibtexText)
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("BibTeX")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isEditing ? "Cancel" : "Done") {
                        if isEditing && hasChanges {
                            showingDiscardAlert = true
                        } else if isEditing {
                            isEditing = false
                        } else {
                            dismiss()
                        }
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    if isEditing {
                        Button("Save") {
                            saveBibTeX()
                        }
                        .disabled(validationError != nil)
                    } else {
                        Menu {
                            Button {
                                isEditing = true
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }

                            Button {
                                copyToClipboard()
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
            .alert("Discard Changes?", isPresented: $showingDiscardAlert) {
                Button("Discard", role: .destructive) {
                    bibtexText = originalBibTeX
                    isEditing = false
                    validationError = nil
                }
                Button("Keep Editing", role: .cancel) {}
            } message: {
                Text("You have unsaved changes that will be lost.")
            }
            .onAppear {
                loadBibTeX()
            }
        }
    }

    // MARK: - Data Loading

    private func loadBibTeX() {
        let store = RustStoreAdapter.shared
        let bibtex = store.exportBibTeX(ids: [publicationID])
        originalBibTeX = bibtex
        bibtexText = bibtex
    }

    // MARK: - Actions

    private func validateBibTeX(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            validationError = "BibTeX entry cannot be empty"
            return
        }

        let entryPattern = #"^@\w+\s*\{"#
        if trimmed.range(of: entryPattern, options: .regularExpression) == nil {
            validationError = "Missing @type{citekey structure"
            return
        }

        var braceCount = 0
        for char in trimmed {
            if char == "{" { braceCount += 1 }
            if char == "}" { braceCount -= 1 }
            if braceCount < 0 {
                validationError = "Unmatched closing brace"
                return
            }
        }

        if braceCount != 0 {
            validationError = "Unmatched braces (\(braceCount) unclosed)"
            return
        }

        if !trimmed.hasSuffix("}") {
            validationError = "Entry must end with }"
            return
        }

        validationError = nil
    }

    private func saveBibTeX() {
        guard validationError == nil else { return }

        // Parse the BibTeX and update fields via Rust store
        do {
            let items = try BibTeXParserFactory.createParser().parse(bibtexText)
            guard let entry = items.compactMap({ item -> BibTeXEntry? in
                if case .entry(let entry) = item { return entry }
                return nil
            }).first else {
                validationError = "Could not parse BibTeX entry"
                return
            }

            let store = RustStoreAdapter.shared
            for (key, value) in entry.fields {
                store.updateField(id: publicationID, field: key, value: value)
            }

            onSave?(bibtexText)
            isEditing = false
            originalBibTeX = bibtexText
        } catch {
            validationError = "Failed to parse: \(error.localizedDescription)"
        }
    }

    private func copyToClipboard() {
        UIPasteboard.general.string = bibtexText
    }
}
