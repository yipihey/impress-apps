import AppKit
import ImpressLogging
import OSLog
import SwiftUI

//
//  NewManuscriptFromTemplateView.swift
//
//  File ▸ New Manuscript from Template… (⇧⌘N)
//
//  Collects a title, a template, and optional front-matter, then asks the Rust
//  scaffolder for a complete starter document and stores it as a new
//  manuscript. No template content is assembled here — this view only gathers
//  values and forwards them to `TemplateService.starterDocument`.
//
//  Form layout follows the macOS conventions documented in
//  apps/imbib/CLAUDE.md: `LabeledContent` for rows, and no `List` inside a
//  `Form` `Section` (which collapses to zero height on macOS). The template
//  chooser is therefore a sectioned `Picker`, not a list.
//

struct NewManuscriptFromTemplateView: View {
    /// Called with the new manuscript's id once creation succeeds.
    let onCreate: (UUID) -> Void
    /// Called when the user cancels or after a successful create.
    let onClose: () -> Void

    @State private var templateService = TemplateService.shared

    @State private var title: String = "Untitled"
    @State private var templateID: String = "generic"
    @State private var authorsText: String = ""
    @State private var affiliationsText: String = ""
    @State private var abstractText: String = ""
    @State private var keywordsText: String = ""
    @State private var includeSections: Bool = true
    @State private var errorMessage: String?

    @FocusState private var titleFocused: Bool

    private var selectedTemplate: TemplateMetadata? {
        templateService.templates.first { $0.id == templateID }
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("Title") {
                        TextField("Manuscript title", text: $title)
                            .textFieldStyle(.roundedBorder)
                            .focused($titleFocused)
                    }

                    LabeledContent("Template") {
                        Picker("Template", selection: $templateID) {
                            ForEach(templateService.groupedTemplates(), id: \.category) { group in
                                Section(group.category.displayName) {
                                    ForEach(group.templates) { template in
                                        Text(template.name).tag(template.id)
                                    }
                                }
                            }
                        }
                        .labelsHidden()
                    }

                    if let template = selectedTemplate {
                        LabeledContent("Format") {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(template.description)
                                    .font(.callout)
                                Text(templateSummary(template))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Front Matter") {
                    LabeledContent("Authors") {
                        TextField("Comma separated", text: $authorsText)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("Affiliations") {
                        TextField("Comma separated", text: $affiliationsText)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("Keywords") {
                        TextField("Comma separated", text: $keywordsText)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("Abstract") {
                        TextField("Optional", text: $abstractText, axis: .vertical)
                            .lineLimit(2...5)
                            .textFieldStyle(.roundedBorder)
                    }
                    Toggle("Include section skeleton", isOn: $includeSections)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedTitle.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 520, height: 560)
        .onAppear { titleFocused = true }
    }

    private func templateSummary(_ template: TemplateMetadata) -> String {
        var parts: [String] = []
        if let journal = template.journal { parts.append(journal.publisher) }
        parts.append(template.pageDefaults.size.uppercased())
        parts.append(template.pageDefaults.columns == 2 ? "2-column" : "1-column")
        parts.append("\(Int(template.pageDefaults.fontSize))pt")
        return parts.joined(separator: " · ")
    }

    /// Split a comma-separated field into trimmed, non-empty entries.
    private func splitList(_ text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func create() {
        // Capture @State into locals before any work — see the SwiftUI
        // concurrency rules in the root CLAUDE.md.
        let newTitle = trimmedTitle
        let chosenTemplate = templateID
        let authors = splitList(authorsText)
        let affiliations = splitList(affiliationsText)
        let keywords = splitList(keywordsText)
        let abstract = abstractText.trimmingCharacters(in: .whitespacesAndNewlines)
        let sections = includeSections

        Logger.documents.infoCapture(
            "New from template: template='\(chosenTemplate)' title='\(newTitle)' "
                + "authors=\(authors.count) sections=\(sections)",
            category: "templates")

        guard
            let starter = templateService.starterDocument(
                templateID: chosenTemplate,
                title: newTitle,
                authors: authors,
                affiliations: affiliations,
                abstract: abstract.isEmpty ? nil : abstract,
                keywords: keywords,
                includeSections: sections)
        else {
            errorMessage = "Template '\(chosenTemplate)' could not be loaded."
            Logger.documents.errorCapture(
                "Scaffold failed for template '\(chosenTemplate)'", category: "templates")
            return
        }

        do {
            let id = try ManuscriptStoreAdapter.shared.createManuscript(
                title: newTitle, format: .typst, body: starter, authors: authors)
            Logger.documents.infoCapture(
                "Created manuscript \(id.uuidString) from '\(chosenTemplate)' "
                    + "(\(starter.count) chars seeded)",
                category: "templates")
            onCreate(id)
            onClose()
        } catch {
            errorMessage = error.localizedDescription
            Logger.documents.errorCapture(
                "createManuscript failed for template '\(chosenTemplate)': "
                    + error.localizedDescription,
                category: "templates")
        }
    }
}
