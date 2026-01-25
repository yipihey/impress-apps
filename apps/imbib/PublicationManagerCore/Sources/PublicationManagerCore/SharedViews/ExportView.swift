//
//  ExportView.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Export View

/// View for exporting publications with template selection.
public struct ExportView: View {

    // MARK: - Properties

    @Binding var isPresented: Bool
    let publications: [CDPublication]

    @State private var selectedFormat: ExportFormat = .bibtex
    @State private var exportedContent: String = ""
    @State private var showPreview = true
    @State private var isCopied = false

    // MARK: - Initialization

    public init(isPresented: Binding<Bool>, publications: [CDPublication]) {
        self._isPresented = isPresented
        self.publications = publications
    }

    // MARK: - Body

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Format selection
                formatPicker

                Divider()

                // Preview/Content
                if showPreview {
                    previewSection
                } else {
                    statsSection
                }
            }
            .navigationTitle("Export Publications")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                toolbarContent
            }
            .onAppear {
                generateExport()
            }
            .onChange(of: selectedFormat) { _, _ in
                generateExport()
            }
        }
        #if os(macOS)
        .frame(minWidth: 600, minHeight: 500)
        #endif
    }

    // MARK: - Format Picker

    private var formatPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(ExportFormat.allCases) { format in
                    FormatButton(
                        format: format,
                        isSelected: selectedFormat == format
                    ) {
                        selectedFormat = format
                    }
                }
            }
            .padding()
        }
        .background(.bar)
    }

    // MARK: - Preview Section

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Preview")
                    .font(.headline)

                Spacer()

                Text("\(publications.count) publication\(publications.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)

                Button {
                    showPreview.toggle()
                } label: {
                    Image(systemName: "eye.slash")
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(.bar)

            Divider()

            // Content
            ScrollView {
                Text(exportedContent)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
    }

    // MARK: - Stats Section

    private var statsSection: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "doc.text")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                Text("\(publications.count) Publications")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Format: \(selectedFormat.displayName)")
                    .foregroundStyle(.secondary)

                Text("\(exportedContent.count) characters")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Button {
                showPreview = true
            } label: {
                Label("Show Preview", systemImage: "eye")
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") {
                isPresented = false
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                copyToClipboard()
            } label: {
                Label(isCopied ? "Copied!" : "Copy", systemImage: isCopied ? "checkmark" : "doc.on.doc")
            }

            Button {
                saveToFile()
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
        }
    }

    // MARK: - Actions

    private func generateExport() {
        exportedContent = TemplateEngine.shared.export(publications, format: selectedFormat)
    }

    private func copyToClipboard() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(exportedContent, forType: .string)
        #else
        UIPasteboard.general.string = exportedContent
        #endif

        withAnimation {
            isCopied = true
        }

        Task {
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run {
                withAnimation {
                    isCopied = false
                }
            }
        }
    }

    private func saveToFile() {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "export.\(selectedFormat.fileExtension)"
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try exportedContent.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                // TODO: Show error
                print("Failed to save: \(error)")
            }
        }
        #else
        // iOS would use a document picker or share sheet
        #endif
    }
}

// MARK: - Format Button

struct FormatButton: View {
    let format: ExportFormat
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: iconName)
                    .font(.title2)

                Text(format.displayName)
                    .font(.caption)
            }
            .frame(width: 80, height: 70)
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            .foregroundStyle(isSelected ? .primary : .secondary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }

    private var iconName: String {
        switch format {
        case .bibtex: return "text.badge.checkmark"
        case .ris: return "doc.badge.arrow.up"
        case .plainText: return "doc.plaintext"
        case .markdown: return "text.document"
        case .html: return "globe"
        case .csv: return "tablecells"
        }
    }
}

// MARK: - Export Template Editor

/// Editor for creating custom export templates.
public struct ExportTemplateEditor: View {

    @Binding var isPresented: Bool
    let onSave: (ExportTemplate) -> Void

    @State private var name = "My Template"
    @State private var template = "{{authors}} ({{year}}). {{title}}. {{venue}}."
    @State private var headerTemplate = ""
    @State private var footerTemplate = ""
    @State private var separator = "\n\n"
    @State private var showPlaceholders = false

    public init(isPresented: Binding<Bool>, onSave: @escaping (ExportTemplate) -> Void) {
        self._isPresented = isPresented
        self.onSave = onSave
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Template Name") {
                    TextField("Name", text: $name)
                }

                Section {
                    TextEditor(text: $template)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 150)
                } header: {
                    HStack {
                        Text("Entry Template")
                        Spacer()
                        Button("Placeholders") {
                            showPlaceholders.toggle()
                        }
                        .font(.caption)
                    }
                } footer: {
                    Text("Use {{fieldName}} to insert publication fields")
                }

                Section("Header (optional)") {
                    TextEditor(text: $headerTemplate)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 60)
                }

                Section("Footer (optional)") {
                    TextEditor(text: $footerTemplate)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 60)
                }

                Section("Separator") {
                    TextField("Separator between entries", text: $separator)
                        .font(.system(.body, design: .monospaced))
                }
            }
            .navigationTitle("Custom Template")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .disabled(name.isEmpty || template.isEmpty)
                }
            }
            .sheet(isPresented: $showPlaceholders) {
                PlaceholderHelpView()
            }
        }
        #if os(macOS)
        .frame(minWidth: 500, minHeight: 500)
        #endif
    }

    private func save() {
        let exportTemplate = ExportTemplate(
            name: name,
            format: "custom",
            template: template,
            headerTemplate: headerTemplate.isEmpty ? nil : headerTemplate,
            footerTemplate: footerTemplate.isEmpty ? nil : footerTemplate,
            separator: separator,
            isBuiltIn: false
        )
        onSave(exportTemplate)
        isPresented = false
    }
}

// MARK: - Placeholder Help View

struct PlaceholderHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Basic Fields") {
                    placeholderRow("{{citeKey}}", "Citation key")
                    placeholderRow("{{title}}", "Publication title")
                    placeholderRow("{{authors}}", "All authors")
                    placeholderRow("{{year}}", "Publication year")
                    placeholderRow("{{entryType}}", "Entry type (article, book, etc.)")
                }

                Section("Venue Fields") {
                    placeholderRow("{{journal}}", "Journal name")
                    placeholderRow("{{booktitle}}", "Book/proceedings title")
                    placeholderRow("{{venue}}", "Journal or booktitle (whichever exists)")
                    placeholderRow("{{publisher}}", "Publisher name")
                    placeholderRow("{{volume}}", "Volume number")
                    placeholderRow("{{number}}", "Issue number")
                    placeholderRow("{{pages}}", "Page range")
                }

                Section("Author Helpers") {
                    placeholderRow("{{firstAuthor}}", "First author's full name")
                    placeholderRow("{{firstAuthorLastName}}", "First author's last name")
                    placeholderRow("{{authorList}}", "Authors (with 'et al.' if > 2)")
                }

                Section("Other Fields") {
                    placeholderRow("{{abstract}}", "Abstract")
                    placeholderRow("{{doi}}", "DOI")
                    placeholderRow("{{doiURL}}", "Full DOI URL")
                    placeholderRow("{{url}}", "URL field")
                    placeholderRow("{{keywords}}", "Keywords")
                    placeholderRow("{{note}}", "Notes")
                }

                Section("Header/Footer Only") {
                    placeholderRow("{{count}}", "Number of publications")
                    placeholderRow("{{date}}", "Current date")
                }
            }
            .navigationTitle("Available Placeholders")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func placeholderRow(_ placeholder: String, _ description: String) -> some View {
        HStack {
            Text(placeholder)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.blue)
            Spacer()
            Text(description)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Preview

#Preview("Export View") {
    Text("Export View Preview")
}

#Preview("Template Editor") {
    ExportTemplateEditor(isPresented: .constant(true)) { template in
        print("Saved: \(template.name)")
    }
}
