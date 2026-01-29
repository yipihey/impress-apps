//
//  ImportPreviewView.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import SwiftUI
import OSLog
#if os(macOS)
import AppKit
#endif

// MARK: - Import Preview Entry

/// A unified preview entry that can represent either BibTeX or RIS data.
public struct ImportPreviewEntry: Identifiable {
    public let id: String
    public let title: String
    public let authors: String
    public let year: String
    public let entryType: String
    public let source: ImportSource
    public var isSelected: Bool

    /// Whether this entry is a duplicate of an existing publication
    public var isDuplicate: Bool = false
    /// The existing publication this entry duplicates (if any)
    public var duplicateOfID: UUID?
    /// Human-readable reason why this is considered a duplicate
    public var duplicateReason: String?

    public enum ImportSource {
        case bibtex(BibTeXEntry)
        case ris(RISEntry)
    }

    /// Extract DOI from the entry if available
    public var doi: String? {
        switch source {
        case .bibtex(let entry):
            return entry.fields["doi"]?.trimmingCharacters(in: .whitespaces)
        case .ris(let entry):
            return entry.doi
        }
    }

    /// Extract arXiv ID from the entry if available
    public var arxivID: String? {
        switch source {
        case .bibtex(let entry):
            // Check eprint field or extract from URL
            if let eprint = entry.fields["eprint"] {
                return eprint.trimmingCharacters(in: .whitespaces)
            }
            if let url = entry.fields["url"], url.contains("arxiv.org") {
                // Extract ID from URL like https://arxiv.org/abs/2301.12345
                if let range = url.range(of: #"(\d{4}\.\d{4,5}(v\d+)?)"#, options: .regularExpression) {
                    return String(url[range])
                }
            }
            return nil
        case .ris(let entry):
            // Check for arXiv ID in various fields
            if let url = entry.url, url.contains("arxiv.org") {
                if let range = url.range(of: #"(\d{4}\.\d{4,5}(v\d+)?)"#, options: .regularExpression) {
                    return String(url[range])
                }
            }
            return nil
        }
    }

    /// Extract bibcode from the entry if available
    public var bibcode: String? {
        switch source {
        case .bibtex(let entry):
            // ADS uses adsurl or the cite key might be a bibcode
            if let adsurl = entry.fields["adsurl"], adsurl.contains("abs/") {
                // Extract bibcode from URL like https://ui.adsabs.harvard.edu/abs/2023ApJ...123..456A
                if let range = adsurl.range(of: #"abs/([^/]+)"#, options: .regularExpression) {
                    let match = adsurl[range]
                    return String(match.dropFirst(4)) // Remove "abs/"
                }
            }
            return nil
        case .ris(_):
            return nil
        }
    }

    public init(from entry: BibTeXEntry) {
        self.id = entry.citeKey
        self.title = entry.fields["title"] ?? "Untitled"
        self.authors = entry.fields["author"] ?? "Unknown"
        self.year = entry.fields["year"] ?? ""
        self.entryType = entry.entryType
        self.source = .bibtex(entry)
        self.isSelected = true
    }

    public init(from entry: RISEntry) {
        self.id = entry.id
        self.title = entry.title ?? "Untitled"
        self.authors = entry.authors.joined(separator: "; ")
        self.year = entry.year.map(String.init) ?? ""
        self.entryType = entry.type.rawValue
        self.source = .ris(entry)
        self.isSelected = true
    }
}

// MARK: - Duplicate Handling Mode

/// How to handle duplicate entries during import
public enum DuplicateHandlingMode: String, CaseIterable {
    case skipDuplicates = "skip"
    case replaceWithImported = "replace"

    public var displayName: String {
        switch self {
        case .skipDuplicates:
            return "Skip duplicates"
        case .replaceWithImported:
            return "Replace existing with imported"
        }
    }
}

// MARK: - Import Destination

/// Represents where to import entries
public enum ImportDestination: Hashable {
    case existingLibrary(UUID)
    case createNewLibrary
}

// MARK: - Import Preview View

/// View for previewing entries before import.
public struct ImportPreviewView: View {

    // MARK: - Environment

    @Environment(LibraryManager.self) private var libraryManager

    // MARK: - Properties

    @Binding var isPresented: Bool
    let fileURL: URL
    /// Callback receives entries, target library (nil means create new), new library name, and duplicate handling mode
    let onImport: ([ImportPreviewEntry], CDLibrary?, String?, DuplicateHandlingMode) async throws -> Int

    @State private var entries: [ImportPreviewEntry] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var isImporting = false
    @State private var importResult: Int?
    @State private var selectedEntryID: String?

    // Library selection state
    @State private var selectedDestination: ImportDestination = .createNewLibrary
    @State private var newLibraryName: String = ""

    // Duplicate handling state
    @State private var duplicateHandlingMode: DuplicateHandlingMode = .skipDuplicates
    @State private var duplicateCount: Int = 0

    /// Optional pre-selected library (e.g., when dropping file onto a library)
    let preselectedLibrary: CDLibrary?
    /// When true, defaults to "Create new library" instead of first existing library
    let preferCreateNewLibrary: Bool

    // MARK: - Initialization

    public init(
        isPresented: Binding<Bool>,
        fileURL: URL,
        preselectedLibrary: CDLibrary? = nil,
        preferCreateNewLibrary: Bool = false,
        onImport: @escaping ([ImportPreviewEntry], CDLibrary?, String?, DuplicateHandlingMode) async throws -> Int
    ) {
        self._isPresented = isPresented
        self.fileURL = fileURL
        self.preselectedLibrary = preselectedLibrary
        self.preferCreateNewLibrary = preferCreateNewLibrary
        self.onImport = onImport
    }

    /// Suggested library name from the file (filename without extension)
    private var suggestedLibraryName: String {
        let filename = fileURL.deletingPathExtension().lastPathComponent
        // Clean up common suffixes like "_export", "-library", etc.
        return filename
            .replacingOccurrences(of: "_export", with: "")
            .replacingOccurrences(of: "-export", with: "")
            .replacingOccurrences(of: "_library", with: "")
            .replacingOccurrences(of: "-library", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Available user libraries (excluding system libraries)
    private var availableLibraries: [CDLibrary] {
        libraryManager.libraries.filter { !$0.isSystemLibrary }
    }

    // MARK: - Body

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle("Import Preview")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar { toolbarContent }
        }
        #if os(macOS)
        .frame(minWidth: 600, minHeight: 500)
        #endif
        .task {
            // Initialize new library name with suggested name
            newLibraryName = suggestedLibraryName

            // Set initial destination based on preselected library or defaults
            if let preselected = preselectedLibrary {
                // Use preselected library (e.g., from drag-and-drop on library)
                selectedDestination = .existingLibrary(preselected.id)
            } else if preferCreateNewLibrary {
                // Explicitly prefer "Create new library" (e.g., from sidebar-wide drop)
                selectedDestination = .createNewLibrary
            } else if let firstLibrary = availableLibraries.first {
                // Default to first existing library (e.g., from File menu import)
                selectedDestination = .existingLibrary(firstLibrary.id)
            } else {
                // No libraries exist, default to create new
                selectedDestination = .createNewLibrary
            }
            await parseFile()
            // Check for duplicates after parsing
            await checkForDuplicates()
        }
        .onChange(of: selectedDestination) { _, _ in
            // Re-check duplicates when destination changes
            Task {
                await checkForDuplicates()
            }
        }
        .onChange(of: duplicateHandlingMode) { _, newMode in
            // Update selection based on duplicate handling mode
            updateDuplicateSelections(mode: newMode)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoading {
            loadingView
        } else if let error = errorMessage {
            errorView(error)
        } else if entries.isEmpty {
            emptyView
        } else {
            entryList
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Parsing \(fileURL.lastPathComponent)...")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Parse Error", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Close") {
                isPresented = false
            }
        }
    }

    private var emptyView: some View {
        ContentUnavailableView {
            Label("No Entries Found", systemImage: "doc.text")
        } description: {
            Text("The file doesn't contain any valid entries.")
        } actions: {
            Button("Close") {
                isPresented = false
            }
        }
    }

    private var entryList: some View {
        VStack(spacing: 0) {
            // Header with stats
            headerBar

            Divider()

            // Split view: list on left, detail on right
            #if os(macOS)
            HSplitView {
                // Entry list
                List(selection: $selectedEntryID) {
                    ForEach($entries) { $entry in
                        ImportPreviewRow(entry: $entry)
                            .tag(entry.id)
                    }
                }
                .listStyle(.inset)
                .frame(minWidth: 250)

                // Detail view
                if let entry = entries.first(where: { $0.id == selectedEntryID }) {
                    ImportPreviewDetail(entry: entry)
                        .frame(minWidth: 300)
                } else {
                    Text("Select an entry to view details")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            #else
            // iOS: List only, tap to see detail in sheet
            List(selection: $selectedEntryID) {
                ForEach($entries) { $entry in
                    ImportPreviewRow(entry: $entry)
                        .tag(entry.id)
                }
            }
            .listStyle(.inset)
            .sheet(item: Binding(
                get: { entries.first { $0.id == selectedEntryID } },
                set: { _ in selectedEntryID = nil }
            )) { entry in
                NavigationStack {
                    ImportPreviewDetail(entry: entry)
                        .navigationTitle("Entry Details")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { selectedEntryID = nil }
                            }
                        }
                }
            }
            #endif
        }
    }

    private var headerBar: some View {
        VStack(spacing: 12) {
            // Top row: File info and selection controls
            HStack {
                // File info
                Label(fileURL.lastPathComponent, systemImage: formatIcon)
                    .font(.headline)

                Spacer()

                // Selection controls
                let selectedCount = entries.filter(\.isSelected).count

                Text("\(selectedCount) of \(entries.count) selected")
                    .foregroundStyle(.secondary)

                Button("Select All") {
                    for i in entries.indices {
                        entries[i].isSelected = true
                    }
                }
                .disabled(selectedCount == entries.count)

                Button("Deselect All") {
                    for i in entries.indices {
                        entries[i].isSelected = false
                    }
                }
                .disabled(selectedCount == 0)
            }

            Divider()

            // Library destination selection row
            HStack(spacing: 16) {
                Text("Import to:")
                    .foregroundStyle(.secondary)

                Picker("Destination", selection: $selectedDestination) {
                    // Existing libraries
                    ForEach(availableLibraries) { library in
                        Label(library.displayName, systemImage: "books.vertical")
                            .tag(ImportDestination.existingLibrary(library.id))
                    }

                    if !availableLibraries.isEmpty {
                        Divider()
                    }

                    // Create new option
                    Label("Create New Library...", systemImage: "plus.circle")
                        .tag(ImportDestination.createNewLibrary)
                }
                .labelsHidden()
                #if os(macOS)
                .pickerStyle(.menu)
                .frame(minWidth: 200)
                #else
                .pickerStyle(.menu)
                #endif

                // New library name field (only shown when creating new)
                if case .createNewLibrary = selectedDestination {
                    TextField("Library Name", text: $newLibraryName)
                        .textFieldStyle(.roundedBorder)
                        #if os(macOS)
                        .frame(maxWidth: 200)
                        #endif
                }

                Spacer()
            }

            // Duplicate handling row (only shown when duplicates found)
            if duplicateCount > 0 {
                Divider()

                HStack(spacing: 16) {
                    // Duplicate count badge
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc.fill")
                            .foregroundStyle(.orange)
                        Text("\(duplicateCount) duplicate\(duplicateCount == 1 ? "" : "s") found")
                            .foregroundStyle(.orange)
                            .fontWeight(.medium)
                    }

                    Spacer()

                    // Duplicate handling picker
                    Picker("Duplicates", selection: $duplicateHandlingMode) {
                        Text("Skip duplicates").tag(DuplicateHandlingMode.skipDuplicates)
                        Text("Replace with imported").tag(DuplicateHandlingMode.replaceWithImported)
                    }
                    .pickerStyle(.segmented)
                    #if os(macOS)
                    .frame(maxWidth: 300)
                    #endif
                }
            }
        }
        .padding()
        .background(.bar)
    }

    private var formatIcon: String {
        switch fileURL.pathExtension.lowercased() {
        case "bib", "bibtex":
            return "text.badge.checkmark"
        case "ris":
            return "doc.badge.arrow.up"
        default:
            return "doc.text"
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") {
                isPresented = false
            }
            .disabled(isImporting)
        }

        ToolbarItem(placement: .confirmationAction) {
            if isImporting {
                ProgressView()
                    .scaleEffect(0.8)
            } else if let count = importResult {
                Label("Imported \(count)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Import") {
                    Task { await performImport() }
                }
                .disabled(isImportDisabled)
            }
        }
    }

    // MARK: - Actions

    private func parseFile() async {
        isLoading = true
        errorMessage = nil

        do {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            let ext = fileURL.pathExtension.lowercased()

            switch ext {
            case "bib", "bibtex":
                let parser = BibTeXParserFactory.createParser()
                let bibtexEntries = try parser.parseEntries(content)
                entries = bibtexEntries.map { ImportPreviewEntry(from: $0) }

            case "ris":
                let parser = RISParserFactory.createParser()
                let risEntries = try parser.parse(content)
                entries = risEntries.map { ImportPreviewEntry(from: $0) }

            default:
                throw ImportError.unsupportedFormat(ext)
            }

            // Auto-select first entry
            selectedEntryID = entries.first?.id

        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func performImport() async {
        isImporting = true

        do {
            let selected = entries.filter(\.isSelected)

            // Determine target library
            let targetLibrary: CDLibrary?
            let newLibraryNameToCreate: String?

            switch selectedDestination {
            case .existingLibrary(let libraryID):
                targetLibrary = availableLibraries.first { $0.id == libraryID }
                newLibraryNameToCreate = nil
            case .createNewLibrary:
                targetLibrary = nil
                newLibraryNameToCreate = newLibraryName.trimmingCharacters(in: .whitespaces).isEmpty
                    ? suggestedLibraryName
                    : newLibraryName.trimmingCharacters(in: .whitespaces)
            }

            let count = try await onImport(selected, targetLibrary, newLibraryNameToCreate, duplicateHandlingMode)
            importResult = count

            // Close after short delay
            try? await Task.sleep(for: .seconds(1))
            isPresented = false
        } catch {
            errorMessage = error.localizedDescription
            isImporting = false
        }
    }

    // MARK: - Duplicate Detection

    /// Check for duplicates against the target library
    @MainActor
    private func checkForDuplicates() async {
        // Get the target library for duplicate checking
        guard let targetLibrary = targetLibraryForDuplicateCheck else {
            // No library to check against (creating new library) - clear duplicate flags
            for i in entries.indices {
                entries[i].isDuplicate = false
                entries[i].duplicateOfID = nil
                entries[i].duplicateReason = nil
            }
            duplicateCount = 0
            return
        }

        // Get all publications in the target library
        let publications = targetLibrary.publications ?? []

        var foundDuplicates = 0

        for i in entries.indices {
            let entry = entries[i]
            var isDuplicate = false
            var duplicateID: UUID?
            var reason: String?

            // Check by DOI (most reliable)
            if let doi = entry.doi, !doi.isEmpty {
                if let match = publications.first(where: { $0.doi?.lowercased() == doi.lowercased() }) {
                    isDuplicate = true
                    duplicateID = match.id
                    reason = "Same DOI: \(doi)"
                }
            }

            // Check by arXiv ID
            if !isDuplicate, let arxivID = entry.arxivID, !arxivID.isEmpty {
                // Normalize arXiv ID (remove version suffix for comparison)
                let normalizedImportID = arxivID.replacingOccurrences(of: #"v\d+$"#, with: "", options: .regularExpression)
                if let match = publications.first(where: {
                    guard let pubArxiv = $0.arxivID else { return false }
                    let normalizedPubID = pubArxiv.replacingOccurrences(of: #"v\d+$"#, with: "", options: .regularExpression)
                    return normalizedPubID == normalizedImportID
                }) {
                    isDuplicate = true
                    duplicateID = match.id
                    reason = "Same arXiv ID: \(arxivID)"
                }
            }

            // Check by bibcode
            if !isDuplicate, let bibcode = entry.bibcode, !bibcode.isEmpty {
                if let match = publications.first(where: { $0.bibcode == bibcode }) {
                    isDuplicate = true
                    duplicateID = match.id
                    reason = "Same bibcode: \(bibcode)"
                }
            }

            // Check by normalized title (fuzzy match)
            if !isDuplicate {
                let normalizedTitle = normalizeTitle(entry.title)
                if normalizedTitle.count > 10 { // Only check titles with sufficient length
                    if let match = publications.first(where: {
                        guard let pubTitle = $0.title else { return false }
                        let normalizedPubTitle = normalizeTitle(pubTitle)
                        return normalizedPubTitle == normalizedTitle
                    }) {
                        isDuplicate = true
                        duplicateID = match.id
                        reason = "Same title"
                    }
                }
            }

            entries[i].isDuplicate = isDuplicate
            entries[i].duplicateOfID = duplicateID
            entries[i].duplicateReason = reason

            if isDuplicate {
                foundDuplicates += 1
                // Deselect duplicates by default
                entries[i].isSelected = false
            }
        }

        duplicateCount = foundDuplicates
    }

    /// Get the target library for duplicate checking (nil if creating new)
    private var targetLibraryForDuplicateCheck: CDLibrary? {
        switch selectedDestination {
        case .existingLibrary(let libraryID):
            return availableLibraries.first { $0.id == libraryID }
        case .createNewLibrary:
            return nil
        }
    }

    /// Normalize a title for comparison (lowercase, remove punctuation, collapse whitespace)
    private func normalizeTitle(_ title: String) -> String {
        title
            .lowercased()
            .replacingOccurrences(of: #"[^\w\s]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Update duplicate selections based on handling mode
    private func updateDuplicateSelections(mode: DuplicateHandlingMode) {
        for i in entries.indices where entries[i].isDuplicate {
            switch mode {
            case .skipDuplicates:
                entries[i].isSelected = false
            case .replaceWithImported:
                entries[i].isSelected = true
            }
        }
    }

    /// Whether the import button should be disabled
    private var isImportDisabled: Bool {
        let hasSelectedEntries = !entries.filter(\.isSelected).isEmpty

        if case .createNewLibrary = selectedDestination {
            let name = newLibraryName.trimmingCharacters(in: .whitespaces)
            return !hasSelectedEntries || name.isEmpty
        }

        return !hasSelectedEntries
    }
}

// MARK: - Import Preview Row

struct ImportPreviewRow: View {
    @Binding var entry: ImportPreviewEntry

    var body: some View {
        HStack {
            Toggle("", isOn: $entry.isSelected)
                .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.title)
                        .lineLimit(2)
                        .font(.body)

                    // Duplicate indicator
                    if entry.isDuplicate {
                        Image(systemName: "doc.on.doc.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                            .help(entry.duplicateReason ?? "Duplicate entry")
                    }
                }

                HStack(spacing: 8) {
                    Text(entry.authors)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)

                    if !entry.year.isEmpty {
                        Text("(\(entry.year))")
                            .foregroundStyle(.tertiary)
                    }

                    // Show duplicate reason if present
                    if entry.isDuplicate, let reason = entry.duplicateReason {
                        Text("• \(reason)")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
            }

            Spacer()

            // Entry type badge
            Text(entry.entryType)
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.fill.tertiary)
                .clipShape(Capsule())
        }
        .contentShape(Rectangle())
        // Dim duplicates slightly when not selected
        .opacity(entry.isDuplicate && !entry.isSelected ? 0.7 : 1.0)
    }
}

// MARK: - Import Preview Detail

struct ImportPreviewDetail: View {
    let entry: ImportPreviewEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Title
                Text(entry.title)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .textSelection(.enabled)

                // Metadata
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("Authors")
                            .foregroundStyle(.secondary)
                        Text(entry.authors)
                            .textSelection(.enabled)
                    }

                    if !entry.year.isEmpty {
                        GridRow {
                            Text("Year")
                                .foregroundStyle(.secondary)
                            Text(entry.year)
                        }
                    }

                    GridRow {
                        Text("Type")
                            .foregroundStyle(.secondary)
                        Text(entry.entryType)
                    }

                    GridRow {
                        Text("Cite Key")
                            .foregroundStyle(.secondary)
                        Text(entry.id)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }

                Divider()

                // Raw content preview
                Text("Raw Entry")
                    .font(.headline)

                ScrollView(.horizontal) {
                    Text(rawContent)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                .padding()
                .background(.fill.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding()
        }
    }

    private var rawContent: String {
        switch entry.source {
        case .bibtex(let bibtex):
            return bibtex.rawBibTeX ?? BibTeXExporter().export([bibtex])
        case .ris(let ris):
            return ris.rawRIS ?? RISExporter().export([ris])
        }
    }
}

// MARK: - Preview

#Preview("Import Preview") {
    ImportPreviewView(
        isPresented: .constant(true),
        fileURL: URL(fileURLWithPath: "/tmp/sample.bib")
    ) { entries, library, newLibraryName, duplicateHandling in
        try? await Task.sleep(for: .seconds(1))
        return entries.count
    }
    .environment(LibraryManager(persistenceController: .preview))
}
