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
    case library(UUID, String, Int) // libraryID, displayName, publicationCount
    case selection([UUID])          // publication IDs

    var displayName: String {
        switch self {
        case .library(_, let name, _):
            return "Library \"\(name)\""
        case .selection(let ids):
            return "\(ids.count) selected publication\(ids.count == 1 ? "" : "s")"
        }
    }

    var publicationCount: Int {
        switch self {
        case .library(_, _, let count):
            return count
        case .selection(let ids):
            return ids.count
        }
    }
}

// MARK: - Unified Export View

/// Unified export dialog supporting both BibTeX and mbox formats.
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
                formatPicker
                    .padding()

                Divider()

                optionsSection
                    .padding()

                Divider()

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

        if let contentType = UTType(filenameExtension: selectedFormat.fileExtension) {
            panel.allowedContentTypes = [contentType]
        }

        let baseName: String
        switch scope {
        case .library(_, let name, _):
            baseName = name
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
        let store = await MainActor.run { RustStoreAdapter.shared }
        let publicationIDs: [UUID]

        switch scope {
        case .library(let libraryID, _, _):
            publicationIDs = await MainActor.run {
                store.queryPublications(parentId: libraryID).map(\.id)
            }
        case .selection(let ids):
            publicationIDs = ids
        }

        // Export BibTeX via store
        let content = await MainActor.run {
            var bibtex = "% imbib Library Export\n"
            bibtex += "% Generated: \(Date())\n"
            bibtex += "% Publications: \(publicationIDs.count)\n\n"

            let exported = store.exportBibTeX(ids: publicationIDs)

            if includeAttachments {
                // Split into entries and add Bdsk-File-* fields
                // The exported string contains concatenated BibTeX entries
                for pubID in publicationIDs {
                    let linkedFiles = store.listLinkedFiles(publicationId: pubID)
                    if !linkedFiles.isEmpty {
                        // Re-export individually to add file fields
                        var entry = store.exportBibTeX(ids: [pubID])
                        entry = addBdskFileFields(to: entry, linkedFiles: linkedFiles)
                        bibtex += entry + "\n"
                    }
                }
                // Add entries without linked files
                let idsWithFiles = Set(publicationIDs.filter { !store.listLinkedFiles(publicationId: $0).isEmpty })
                let idsWithoutFiles = publicationIDs.filter { !idsWithFiles.contains($0) }
                if !idsWithoutFiles.isEmpty {
                    bibtex += store.exportBibTeX(ids: idsWithoutFiles)
                }
            } else {
                bibtex += exported
            }

            return bibtex
        }

        try Data(content.utf8).write(to: url)
        logger.info("Exported \(publicationIDs.count) publications to BibTeX")
    }

    /// Add Bdsk-File-* fields to BibTeX entry for linked files.
    private func addBdskFileFields(to bibtex: String, linkedFiles: [LinkedFileModel]) -> String {
        guard let closingIndex = bibtex.lastIndex(of: "}") else {
            return bibtex
        }

        var fields = ""
        for (index, linkedFile) in linkedFiles.enumerated() {
            if let relativePath = linkedFile.relativePath {
                if let encoded = BdskFileCodec.encode(relativePath: relativePath) {
                    fields += ",\n    Bdsk-File-\(index + 1) = {\(encoded)}"
                }
            }
        }

        var result = bibtex
        result.insert(contentsOf: fields, at: closingIndex)
        return result
    }

    // MARK: - Mbox Export

    private func exportMbox(to url: URL) async throws {
        let store = await MainActor.run { RustStoreAdapter.shared }
        let libraryID: UUID?

        switch scope {
        case .library(let id, _, _):
            libraryID = id
        case .selection:
            libraryID = nil
        }

        guard let libraryID else {
            throw ExportError.noLibrary
        }

        let options = MboxExportOptions(
            includeFiles: includeAttachments,
            includeBibTeX: true,
            maxFileSize: nil
        )

        let exporter = MboxExporter(options: options)

        let publicationIDs: [UUID]
        switch scope {
        case .library:
            publicationIDs = await MainActor.run {
                store.queryPublications(parentId: libraryID).map(\.id)
            }
        case .selection(let ids):
            publicationIDs = ids
        }

        try await exporter.export(publicationIds: publicationIDs, libraryId: libraryID, to: url)

        logger.info("Exported \(publicationIDs.count) publications to mbox")
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
        Text("UnifiedExportView Preview")
            .frame(width: 400, height: 400)
    }
}
#endif
