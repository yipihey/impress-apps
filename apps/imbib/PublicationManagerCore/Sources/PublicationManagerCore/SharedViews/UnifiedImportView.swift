//
//  UnifiedImportView.swift
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

// MARK: - Detected Import Format

/// The detected format of an import file.
public enum DetectedImportFormat {
    case bibtex
    case ris
    case mboxLibrary(MboxImportPreview)      // Single library v1.0 mbox
    case mboxEverything(EverythingImportPreview)  // Everything v2.0 mbox
    case unknown(String)

    var displayName: String {
        switch self {
        case .bibtex:
            return "BibTeX"
        case .ris:
            return "RIS"
        case .mboxLibrary:
            return "imbib Library Archive"
        case .mboxEverything:
            return "imbib Everything Archive"
        case .unknown(let ext):
            return "Unknown (\(ext))"
        }
    }
}

// MARK: - Unified Import View

/// Unified import dialog that auto-detects format and shows appropriate preview.
///
/// Usage:
/// ```
/// .sheet(isPresented: $showImport) {
///     UnifiedImportView(
///         fileURL: selectedFileURL,
///         targetLibrary: library,
///         isPresented: $showImport
///     )
/// }
/// ```
public struct UnifiedImportView: View {

    // MARK: - Environment

    @Environment(LibraryManager.self) private var libraryManager

    // MARK: - Properties

    public let fileURL: URL?
    public let targetLibrary: CDLibrary?
    @Binding public var isPresented: Bool

    @State private var selectedFileURL: URL?
    @State private var detectedFormat: DetectedImportFormat?
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?

    // Mbox import state (for v1.0)
    @State private var mboxPreview: MboxImportPreview?

    // Everything import state (for v2.0)
    @State private var everythingPreview: EverythingImportPreview?
    @State private var everythingImportOptions: EverythingImportOptions = .default
    @State private var libraryConflictResolutions: [UUID: LibraryConflictResolution] = [:]

    private let logger = Logger(subsystem: "PublicationManagerCore", category: "UnifiedImport")

    // MARK: - Initialization

    public init(
        fileURL: URL? = nil,
        targetLibrary: CDLibrary? = nil,
        isPresented: Binding<Bool>
    ) {
        self.fileURL = fileURL
        self.targetLibrary = targetLibrary
        self._isPresented = isPresented
        self._selectedFileURL = State(initialValue: fileURL)
    }

    // MARK: - Body

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle("Import")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar { toolbarContent }
        }
        #if os(macOS)
        .frame(minWidth: 600, minHeight: 500)
        #endif
        .task {
            if let url = fileURL {
                await parseFile(url)
            } else {
                // Show file picker
                showFilePicker()
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoading {
            loadingView
        } else if let error = errorMessage {
            errorView(error)
        } else if selectedFileURL == nil {
            filePickerPrompt
        } else if let format = detectedFormat {
            formatSpecificView(format)
        } else {
            ContentUnavailableView(
                "No File Selected",
                systemImage: "doc",
                description: Text("Select a file to import")
            )
        }
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Analyzing file...")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Error View

    private func errorView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Import Error", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") {
                errorMessage = nil
                showFilePicker()
            }
            Button("Cancel") {
                isPresented = false
            }
        }
    }

    // MARK: - File Picker Prompt

    private var filePickerPrompt: some View {
        ContentUnavailableView {
            Label("Select a File", systemImage: "doc.badge.plus")
        } description: {
            Text("Choose a BibTeX (.bib), RIS (.ris), or imbib archive (.mbox) file to import")
        } actions: {
            Button("Choose File...") {
                showFilePicker()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Format Specific Views

    @ViewBuilder
    private func formatSpecificView(_ format: DetectedImportFormat) -> some View {
        switch format {
        case .bibtex, .ris:
            // Use existing ImportPreviewView inline
            bibTexImportView

        case .mboxLibrary(let preview):
            mboxImportView(preview: preview)

        case .mboxEverything(let preview):
            everythingImportView(preview: preview)

        case .unknown(let ext):
            ContentUnavailableView(
                "Unsupported Format",
                systemImage: "doc.questionmark",
                description: Text("Cannot import files with .\(ext) extension")
            )
        }
    }

    // MARK: - BibTeX/RIS Import View

    @ViewBuilder
    private var bibTexImportView: some View {
        if let url = selectedFileURL {
            ImportPreviewView(
                isPresented: $isPresented,
                fileURL: url,
                preselectedLibrary: targetLibrary
            ) { entries, library, newLibraryName, duplicateHandling in
                try await performBibTeXImport(
                    entries: entries,
                    library: library,
                    newLibraryName: newLibraryName,
                    duplicateHandling: duplicateHandling
                )
            }
        }
    }

    // MARK: - Mbox Import View

    @ViewBuilder
    private func mboxImportView(preview: MboxImportPreview) -> some View {
        VStack(spacing: 0) {
            MboxImportPreviewView(
                preview: preview,
                onImport: { selectedIDs, duplicateDecisions in
                    Task {
                        await performMboxImport(
                            preview: preview,
                            selectedIDs: selectedIDs,
                            duplicateDecisions: duplicateDecisions
                        )
                    }
                },
                onCancel: {
                    isPresented = false
                }
            )
        }
    }

    // MARK: - Everything Import View

    @ViewBuilder
    private func everythingImportView(preview: EverythingImportPreview) -> some View {
        VStack(spacing: 0) {
            EverythingImportPreviewView(
                preview: preview,
                options: $everythingImportOptions,
                libraryConflictResolutions: $libraryConflictResolutions
            )

            Divider()

            // Footer buttons
            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Import") {
                    Task {
                        await performEverythingImport(preview: preview)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") {
                isPresented = false
            }
        }
    }

    // MARK: - File Picker

    private func showFilePicker() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "bib")!,
            UTType(filenameExtension: "ris")!,
            UTType(filenameExtension: "mbox") ?? .data,
            UTType(filenameExtension: "bibtex") ?? .data
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select a BibTeX, RIS, or mbox file to import"

        if panel.runModal() == .OK, let url = panel.url {
            selectedFileURL = url
            Task {
                await parseFile(url)
            }
        }
        #else
        // iOS: Would use UIDocumentPickerViewController
        logger.warning("File picker on iOS not yet implemented")
        #endif
    }

    // MARK: - File Parsing

    private func parseFile(_ url: URL) async {
        isLoading = true
        errorMessage = nil

        // Start accessing security-scoped resource
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let ext = url.pathExtension.lowercased()

            switch ext {
            case "bib", "bibtex":
                detectedFormat = .bibtex
                // ImportPreviewView handles its own parsing

            case "ris":
                detectedFormat = .ris
                // ImportPreviewView handles its own parsing

            case "mbox":
                try await parseMbox(url)

            default:
                detectedFormat = .unknown(ext)
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func parseMbox(_ url: URL) async throws {
        let content = try String(contentsOf: url, encoding: .utf8)

        // Check if this is an Everything export (v2.0) by looking for the manifest marker
        if content.contains("[imbib Everything Export]") {
            // Parse as Everything export using EverythingImporter
            let importer = EverythingImporter(context: PersistenceController.shared.viewContext)
            let preview = try await importer.prepareImport(from: url)

            await MainActor.run {
                detectedFormat = .mboxEverything(preview)
            }
            return
        }

        // Parse as single-library mbox (v1.0) using MboxImporter
        let importer = MboxImporter(context: PersistenceController.shared.viewContext)
        let preview = try await importer.prepareImport(from: url)

        await MainActor.run {
            mboxPreview = preview
            detectedFormat = .mboxLibrary(preview)
        }
    }

    // MARK: - Import Actions

    private func performBibTeXImport(
        entries: [ImportPreviewEntry],
        library: CDLibrary?,
        newLibraryName: String?,
        duplicateHandling: DuplicateHandlingMode
    ) async throws -> Int {
        // Delegate to existing import logic - handled by ImportPreviewView
        // This is just a placeholder as ImportPreviewView has its own onImport callback
        return entries.count
    }

    private func performMboxImport(
        preview: MboxImportPreview,
        selectedIDs: Set<UUID>,
        duplicateDecisions: [UUID: DuplicateAction]
    ) async {
        isLoading = true

        do {
            // Determine target library
            let library: CDLibrary?
            if let target = targetLibrary {
                library = target
            } else if let metadataName = preview.libraryMetadata?.name,
                      let existing = await MainActor.run(body: { libraryManager.libraries.first(where: { $0.displayName == metadataName }) }) {
                library = existing
            } else {
                // Let importer create new library
                library = nil
            }

            let importer = MboxImporter(context: PersistenceController.shared.viewContext)
            _ = try await importer.executeImport(
                preview,
                to: library,
                selectedPublications: selectedIDs.isEmpty ? nil : selectedIDs,
                duplicateDecisions: duplicateDecisions
            )

            await MainActor.run {
                isPresented = false
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func performEverythingImport(preview: EverythingImportPreview) async {
        isLoading = true

        do {
            let importer = EverythingImporter(context: PersistenceController.shared.viewContext)
            _ = try await importer.executeImport(preview)

            await MainActor.run {
                isPresented = false
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
struct UnifiedImportView_Previews: PreviewProvider {
    static var previews: some View {
        UnifiedImportView(isPresented: .constant(true))
            .environment(LibraryManager(persistenceController: .preview))
    }
}
#endif
