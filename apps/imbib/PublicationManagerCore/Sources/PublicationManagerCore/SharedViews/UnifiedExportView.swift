//
//  UnifiedExportView.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-29.
//

import SwiftUI
import OSLog
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#else
import UIKit
#endif

// MARK: - Export Format

/// The format for unified export.
public enum UnifiedExportFormat: String, CaseIterable, Identifiable {
    case bibtex = "bibtex"
    case mbox = "mbox"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .bibtex:
            return "BibTeX (.bib)"
        case .mbox:
            return "Archive (.mbox)"
        }
    }

    public var fileExtension: String {
        switch self {
        case .bibtex:
            return "bib"
        case .mbox:
            return "mbox"
        }
    }

    public var icon: String {
        switch self {
        case .bibtex:
            return "text.badge.checkmark"
        case .mbox:
            return "envelope"
        }
    }

    public var description: String {
        switch self {
        case .bibtex:
            return "Standard BibTeX format compatible with all reference managers"
        case .mbox:
            return "Archive with all metadata, collections, and embedded files"
        }
    }
}

// MARK: - Export Scope

/// What to export.
public enum ExportScope {
    case library(CDLibrary)
    case selection([CDPublication])

    var displayName: String {
        switch self {
        case .library(let library):
            return "Library \"\(library.displayName)\""
        case .selection(let publications):
            return "\(publications.count) selected publication\(publications.count == 1 ? "" : "s")"
        }
    }

    var publicationCount: Int {
        switch self {
        case .library(let library):
            return library.publications?.count ?? 0
        case .selection(let publications):
            return publications.count
        }
    }
}

// MARK: - Unified Export View

/// Unified export dialog supporting both BibTeX and mbox formats.
///
/// Usage:
/// ```
/// .sheet(isPresented: $showExport) {
///     UnifiedExportView(
///         scope: .library(myLibrary),
///         isPresented: $showExport
///     )
/// }
/// ```
public struct UnifiedExportView: View {

    // MARK: - Properties

    public let scope: ExportScope
    @Binding public var isPresented: Bool

    @State private var selectedFormat: UnifiedExportFormat = .bibtex
    @State private var includeAttachments: Bool = true
    @State private var isExporting: Bool = false
    @State private var exportError: String?
    @State private var showError: Bool = false

    private let logger = Logger(subsystem: "PublicationManagerCore", category: "UnifiedExport")

    // MARK: - Initialization

    public init(scope: ExportScope, isPresented: Binding<Bool>) {
        self.scope = scope
        self._isPresented = isPresented
    }

    // MARK: - Body

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Format picker
                formatPicker
                    .padding()

                Divider()

                // Options
                optionsSection
                    .padding()

                Divider()

                // Summary
                summarySection
                    .padding()

                Spacer()
            }
            .navigationTitle("Export")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbarContent }
        }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 350)
        #endif
        .alert("Export Error", isPresented: $showError) {
            Button("OK") { showError = false }
        } message: {
            Text(exportError ?? "An unknown error occurred")
        }
    }

    // MARK: - Format Picker

    private var formatPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Format")
                .font(.headline)

            HStack(spacing: 16) {
                ForEach(UnifiedExportFormat.allCases) { format in
                    formatButton(for: format)
                }
            }
        }
    }

    private func formatButton(for format: UnifiedExportFormat) -> some View {
        Button {
            selectedFormat = format
        } label: {
            VStack(spacing: 8) {
                Image(systemName: format.icon)
                    .font(.title2)

                Text(format.displayName)
                    .font(.subheadline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(selectedFormat == format ? Color.accentColor.opacity(0.15) : Color.clear)
            .foregroundStyle(selectedFormat == format ? .primary : .secondary)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(selectedFormat == format ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: selectedFormat == format ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Options Section

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $includeAttachments) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Include attachments")
                        .fontWeight(.medium)

                    Text(attachmentHelpText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
        }
    }

    private var attachmentHelpText: String {
        switch selectedFormat {
        case .bibtex:
            return "Add Bdsk-File-* fields for BibDesk compatibility"
        case .mbox:
            return "Embed PDFs and other files as MIME attachments"
        }
    }

    // MARK: - Summary Section

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                Text("Exporting: \(scope.displayName)")
            }

            HStack {
                Image(systemName: "number")
                    .foregroundStyle(.secondary)
                Text("\(scope.publicationCount) publication\(scope.publicationCount == 1 ? "" : "s")")
            }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") {
                isPresented = false
            }
            .disabled(isExporting)
        }

        ToolbarItem(placement: .confirmationAction) {
            if isExporting {
                ProgressView()
                    .scaleEffect(0.8)
            } else {
                Button("Export...") {
                    performExport()
                }
            }
        }
    }

    // MARK: - Export Action

    private func performExport() {
        #if os(macOS)
        let panel = NSSavePanel()

        // Configure file extension
        if let contentType = UTType(filenameExtension: selectedFormat.fileExtension) {
            panel.allowedContentTypes = [contentType]
        }

        // Default filename
        let baseName: String
        switch scope {
        case .library(let library):
            baseName = library.displayName
        case .selection:
            baseName = "export"
        }
        panel.nameFieldStringValue = "\(baseName).\(selectedFormat.fileExtension)"

        panel.canCreateDirectories = true
        panel.title = "Export \(selectedFormat.displayName)"
        panel.message = "Choose a location to save the export file"

        if panel.runModal() == .OK, let url = panel.url {
            isExporting = true

            Task {
                do {
                    try await executeExport(to: url)
                    await MainActor.run {
                        isExporting = false
                        isPresented = false
                    }
                } catch {
                    await MainActor.run {
                        isExporting = false
                        exportError = error.localizedDescription
                        showError = true
                    }
                }
            }
        }
        #else
        // iOS: Would use UIDocumentPickerViewController
        logger.warning("Export on iOS not yet implemented")
        #endif
    }

    private func executeExport(to url: URL) async throws {
        switch selectedFormat {
        case .bibtex:
            try await exportBibTeX(to: url)
        case .mbox:
            try await exportMbox(to: url)
        }
    }

    // MARK: - BibTeX Export

    private func exportBibTeX(to url: URL) async throws {
        let publications: [CDPublication]
        let library: CDLibrary?

        switch scope {
        case .library(let lib):
            library = lib
            publications = Array(lib.publications ?? [])
        case .selection(let pubs):
            library = pubs.first?.libraries?.first
            publications = pubs
        }

        var content = "% imbib Library Export\n"
        content += "% Generated: \(Date())\n"
        content += "% Publications: \(publications.count)\n\n"

        let exporter = BibTeXExporter()

        for publication in publications {
            // Get raw BibTeX if available
            var bibtex: String
            if let raw = publication.rawBibTeX, !raw.isEmpty {
                bibtex = raw
            } else {
                let entry = publication.toBibTeXEntry()
                bibtex = exporter.export(entry)
            }

            // Add Bdsk-File-* fields if including attachments
            if includeAttachments, let linkedFiles = publication.linkedFiles, !linkedFiles.isEmpty {
                bibtex = addBdskFileFields(to: bibtex, linkedFiles: Array(linkedFiles))
            }

            content += bibtex
            content += "\n\n"
        }

        try content.write(to: url, atomically: true, encoding: .utf8)
        logger.info("Exported \(publications.count) publications to BibTeX")
    }

    /// Add Bdsk-File-* fields to BibTeX entry for linked files.
    private func addBdskFileFields(to bibtex: String, linkedFiles: [CDLinkedFile]) -> String {
        // Find the closing brace of the entry
        guard let closingIndex = bibtex.lastIndex(of: "}") else {
            return bibtex
        }

        var fields = ""
        for (index, linkedFile) in linkedFiles.enumerated() {
            if let encoded = BdskFileCodec.encode(relativePath: linkedFile.relativePath) {
                fields += ",\n    Bdsk-File-\(index + 1) = {\(encoded)}"
            }
        }

        // Insert before closing brace
        var result = bibtex
        result.insert(contentsOf: fields, at: closingIndex)
        return result
    }

    // MARK: - Mbox Export

    private func exportMbox(to url: URL) async throws {
        let publications: [CDPublication]
        let library: CDLibrary?

        switch scope {
        case .library(let lib):
            library = lib
            publications = Array(lib.publications ?? [])
        case .selection(let pubs):
            library = pubs.first?.libraries?.first
            publications = pubs
        }

        guard let library = library else {
            throw ExportError.noLibrary
        }

        let context = PersistenceController.shared.viewContext
        let options = MboxExportOptions(
            includeFiles: includeAttachments,
            includeBibTeX: true,
            maxFileSize: nil
        )

        let exporter = MboxExporter(context: context, options: options)

        if case .selection = scope {
            // Export selected publications
            try await exporter.export(publications: publications, library: library, to: url)
        } else {
            // Export entire library
            try await exporter.export(library: library, to: url)
        }

        logger.info("Exported \(publications.count) publications to mbox")
    }
}

// MARK: - Export Error

enum ExportError: LocalizedError {
    case noLibrary

    var errorDescription: String? {
        switch self {
        case .noLibrary:
            return "No library found for export"
        }
    }
}

// MARK: - Preview

#if DEBUG
struct UnifiedExportView_Previews: PreviewProvider {
    static var previews: some View {
        // Mock preview
        Text("UnifiedExportView Preview")
            .frame(width: 400, height: 400)
    }
}
#endif
