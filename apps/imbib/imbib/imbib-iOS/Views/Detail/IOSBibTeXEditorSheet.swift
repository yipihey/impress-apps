//
//  IOSBibTeXEditorSheet.swift
//  imbib-iOS
//
//  Created by Claude on 2026-01-18.
//

import SwiftUI
import PublicationManagerCore

/// A modal sheet for viewing and editing a publication's BibTeX entry on iOS.
struct IOSBibTeXEditorSheet: View {

    // MARK: - Environment

    @Environment(\.dismiss) private var dismiss

    // MARK: - Properties

    /// The publication to edit
    let publication: CDPublication

    /// Callback when BibTeX is saved
    var onSave: ((String) -> Void)?

    // MARK: - State

    @State private var bibtexText: String = ""
    @State private var isEditing: Bool = false
    @State private var validationError: String?
    @State private var showingDiscardAlert: Bool = false

    // MARK: - Computed

    private var hasChanges: Bool {
        bibtexText != originalBibTeX
    }

    private var originalBibTeX: String {
        if let raw = publication.rawBibTeX, !raw.isEmpty {
            return raw
        }
        // Generate BibTeX entry from LocalPaper wrapper
        if let libraryID = publication.libraries?.first?.id,
           let paper = LocalPaper(publication: publication, libraryID: libraryID) {
            let entry = BibTeXExporter.generateEntry(from: paper)
            return BibTeXExporter().export(entry)
        }
        // Fallback: construct minimal BibTeX manually
        let title = publication.title ?? "Untitled"
        let authors = publication.sortedAuthors.map { $0.bibtexName }.joined(separator: " and ")
        let year = publication.year > 0 ? String(publication.year) : ""
        return """
        @article{\(publication.citeKey),
            title = {\(title)},
            author = {\(authors)},
            year = {\(year)}
        }
        """
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Validation error banner
                if let error = validationError {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.yellow)
                        Text(error)
                            .font(.caption)
                        Spacer()
                    }
                    .padding(8)
                    .background(Color.red.opacity(0.1))
                }

                // BibTeX content
                if isEditing {
                    TextEditor(text: $bibtexText)
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .onChange(of: bibtexText) { _, newValue in
                            validateBibTeX(newValue)
                        }
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
                bibtexText = originalBibTeX
            }
        }
    }

    // MARK: - Actions

    private func validateBibTeX(_ text: String) {
        // Basic validation - check for required structure
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            validationError = "BibTeX entry cannot be empty"
            return
        }

        // Check for opening @type{
        let entryPattern = #"^@\w+\s*\{"#
        if trimmed.range(of: entryPattern, options: .regularExpression) == nil {
            validationError = "Missing @type{citekey structure"
            return
        }

        // Check for matching braces
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

        // Check for closing brace
        if !trimmed.hasSuffix("}") {
            validationError = "Entry must end with }"
            return
        }

        validationError = nil
    }

    private func saveBibTeX() {
        guard validationError == nil else { return }

        // Update the publication's raw BibTeX
        publication.rawBibTeX = bibtexText

        // Try to save
        do {
            try PersistenceController.shared.viewContext.save()
            onSave?(bibtexText)
            isEditing = false
        } catch {
            validationError = "Failed to save: \(error.localizedDescription)"
        }
    }

    private func copyToClipboard() {
        UIPasteboard.general.string = bibtexText
    }
}

// MARK: - Preview

#Preview {
    IOSBibTeXEditorSheet(
        publication: CDPublication()
    )
}
