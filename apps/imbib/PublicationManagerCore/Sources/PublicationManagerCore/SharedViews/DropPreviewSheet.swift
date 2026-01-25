//
//  DropPreviewSheet.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-16.
//

import SwiftUI
import OSLog

private let logger = Logger(subsystem: "com.imbib.core", category: "drop-preview")

// MARK: - Drop Preview Sheet

/// Sheet for previewing and confirming import operations from drag-and-drop.
public struct DropPreviewSheet: View {

    // MARK: - Properties

    @Binding var preview: DropPreviewData?
    let libraryID: UUID
    let coordinator: DragDropCoordinator

    @State private var pdfPreviews: [PDFImportPreview] = []
    @State private var bibPreview: BibImportPreview?
    @State private var isImporting = false
    @State private var error: Error?
    @State private var isInitialized = false

    // MARK: - Initialization

    public init(
        preview: Binding<DropPreviewData?>,
        libraryID: UUID,
        coordinator: DragDropCoordinator
    ) {
        self._preview = preview
        self.libraryID = libraryID
        self.coordinator = coordinator
    }

    // MARK: - Body

    public var body: some View {
        NavigationStack {
            Group {
                switch preview {
                case .pdfImport(let previews):
                    PDFImportPreviewView(
                        previews: $pdfPreviews,
                        coordinator: coordinator
                    )
                case .bibImport(let bib):
                    BibImportPreviewView(
                        preview: bib,
                        onUpdateEntry: updateBibEntry
                    )
                case .none:
                    ContentUnavailableView("No Preview", systemImage: "doc.questionmark")
                }
            }
            .navigationTitle(navigationTitle)
            #if os(macOS)
            .frame(minWidth: 600, minHeight: 450)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        coordinator.cancelImport()
                        preview = nil
                    }
                    .disabled(isImporting)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        performImport()
                    }
                    .disabled(isImporting || !canImport)
                }
            }
            .overlay {
                if isImporting {
                    ProgressView("Importing...")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .alert("Import Error", isPresented: .constant(error != nil)) {
                Button("OK") {
                    error = nil
                }
            } message: {
                if let error {
                    Text(error.localizedDescription)
                }
            }
        }
        .onAppear {
            // Initialize state from preview only once
            guard !isInitialized else { return }
            isInitialized = true

            switch preview {
            case .pdfImport(let previews):
                pdfPreviews = previews
            case .bibImport(let bib):
                bibPreview = bib
            case .none:
                break
            }
        }
    }

    // MARK: - Computed Properties

    private var navigationTitle: String {
        switch preview {
        case .pdfImport(let previews):
            return previews.count == 1 ? "Import PDF" : "Import \(previews.count) PDFs"
        case .bibImport(let bib):
            return "Import \(bib.format.rawValue)"
        case .none:
            return "Import"
        }
    }

    private var canImport: Bool {
        switch preview {
        case .pdfImport:
            return pdfPreviews.contains { $0.selectedAction != .skip }
        case .bibImport(let bib):
            return bib.entries.contains { $0.isSelected }
        case .none:
            return false
        }
    }

    // MARK: - Actions

    private func updateBibEntry(_ entryID: UUID, isSelected: Bool) {
        guard var bib = bibPreview else { return }
        if let index = bib.entries.firstIndex(where: { $0.id == entryID }) {
            var entry = bib.entries[index]
            entry = BibImportEntry(
                id: entry.id,
                citeKey: entry.citeKey,
                entryType: entry.entryType,
                title: entry.title,
                authors: entry.authors,
                year: entry.year,
                isSelected: isSelected,
                isDuplicate: entry.isDuplicate,
                existingPublicationID: entry.existingPublicationID,
                rawContent: entry.rawContent
            )
            var entries = bib.entries
            entries[index] = entry
            bibPreview = BibImportPreview(
                id: bib.id,
                sourceURL: bib.sourceURL,
                format: bib.format,
                entries: entries,
                parseErrors: bib.parseErrors
            )
        }
    }

    private func performImport() {
        isImporting = true
        error = nil

        Task {
            do {
                switch preview {
                case .pdfImport:
                    try await coordinator.confirmPDFImport(pdfPreviews, to: libraryID)
                case .bibImport:
                    if let bib = bibPreview {
                        try await coordinator.confirmBibImport(bib, to: libraryID)
                    }
                case .none:
                    break
                }
                preview = nil
            } catch {
                self.error = error
            }
            isImporting = false
        }
    }
}

// MARK: - PDF Import Preview View

struct PDFImportPreviewView: View {

    @Binding var previews: [PDFImportPreview]
    let coordinator: DragDropCoordinator

    @State private var selectedID: UUID?

    var body: some View {
        NavigationSplitView {
            // List of PDFs
            List(previews, selection: $selectedID) { preview in
                PDFPreviewRow(preview: preview) { action in
                    updatePreviewAction(preview.id, action: action)
                }
            }
            #if os(macOS)
            .frame(minWidth: 200)
            #endif
        } detail: {
            // Detail view
            if let selectedID,
               let index = previews.firstIndex(where: { $0.id == selectedID }) {
                PDFPreviewDetailEditable(
                    preview: $previews[index],
                    coordinator: coordinator
                )
            } else {
                ContentUnavailableView(
                    "Select a PDF",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Select a PDF to view and edit metadata")
                )
            }
        }
        .onAppear {
            if selectedID == nil, let first = previews.first {
                selectedID = first.id
            }
        }
    }

    private func updatePreviewAction(_ id: UUID, action: ImportAction) {
        if let index = previews.firstIndex(where: { $0.id == id }) {
            previews[index].selectedAction = action
        }
    }
}

// MARK: - PDF Preview Row

struct PDFPreviewRow: View {

    let preview: PDFImportPreview
    let onActionChange: (ImportAction) -> Void

    var body: some View {
        HStack {
            // Status indicator
            statusIcon
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                // Title or filename
                Text(preview.effectiveTitle ?? preview.filename)
                    .font(.headline)
                    .lineLimit(1)

                // Metadata summary
                HStack(spacing: 8) {
                    if !preview.effectiveAuthors.isEmpty {
                        Text(preview.effectiveAuthors.first ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let year = preview.effectiveYear {
                        Text(String(year))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if preview.enrichedMetadata != nil {
                        Label(preview.enrichedMetadata!.source, systemImage: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                    if preview.isDuplicate {
                        Label("Duplicate", systemImage: "doc.on.doc")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Spacer()

            // Action picker
            Picker("", selection: Binding(
                get: { preview.selectedAction },
                set: { onActionChange($0) }
            )) {
                Text("Import").tag(ImportAction.importAsNew)
                if preview.isDuplicate {
                    Text("Attach").tag(ImportAction.attachToExisting)
                    Text("Replace").tag(ImportAction.replace)
                }
                Text("Skip").tag(ImportAction.skip)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 100)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch preview.status {
        case .pending, .ready:
            Image(systemName: "doc.fill")
                .foregroundStyle(.blue)
        case .extractingMetadata, .enriching:
            ProgressView()
                .scaleEffect(0.6)
        case .importing:
            ProgressView()
                .scaleEffect(0.6)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        case .skipped:
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - PDF Preview Detail (Editable)

struct PDFPreviewDetailEditable: View {

    @Binding var preview: PDFImportPreview
    let coordinator: DragDropCoordinator

    @State private var isLookingUp = false
    @State private var lookupMessage: String?
    @State private var lookupSuccess = false

    // Local editing state
    @State private var editedTitle: String = ""
    @State private var editedAuthors: String = ""
    @State private var editedYear: String = ""
    @State private var editedDOI: String = ""
    @State private var editedArXivID: String = ""
    @State private var editedJournal: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // File info
                GroupBox("File") {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Filename", value: preview.filename)
                        LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: preview.fileSize, countStyle: .file))
                    }
                }

                // Editable metadata
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        // Title
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Title")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("Enter title", text: $editedTitle)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: editedTitle) { _, newValue in
                                    preview.userEditedTitle = newValue.isEmpty ? nil : newValue
                                }
                        }

                        // Authors
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Authors (comma-separated)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("Author 1, Author 2, ...", text: $editedAuthors)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: editedAuthors) { _, newValue in
                                    preview.userEditedAuthors = newValue.isEmpty ? nil : newValue
                                }
                        }

                        // Year
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Year")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField("YYYY", text: $editedYear)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 80)
                                    .onChange(of: editedYear) { _, newValue in
                                        preview.userEditedYear = newValue.isEmpty ? nil : newValue
                                    }
                            }

                            Spacer()

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Journal")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField("Journal name", text: $editedJournal)
                                    .textFieldStyle(.roundedBorder)
                                    .onChange(of: editedJournal) { _, newValue in
                                        preview.userEditedJournal = newValue.isEmpty ? nil : newValue
                                    }
                            }
                        }

                        Divider()

                        // Identifiers for lookup
                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("DOI")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField("10.xxxx/...", text: $editedDOI)
                                    .textFieldStyle(.roundedBorder)
                                    .onChange(of: editedDOI) { _, newValue in
                                        preview.userEditedDOI = newValue.isEmpty ? nil : newValue
                                    }
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("arXiv ID")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField("2401.12345", text: $editedArXivID)
                                    .textFieldStyle(.roundedBorder)
                                    .onChange(of: editedArXivID) { _, newValue in
                                        preview.userEditedArXivID = newValue.isEmpty ? nil : newValue
                                    }
                            }
                        }

                        // Lookup button
                        HStack {
                            Button {
                                performLookup()
                            } label: {
                                HStack {
                                    if isLookingUp {
                                        ProgressView()
                                            .scaleEffect(0.7)
                                    } else {
                                        Image(systemName: "magnifyingglass")
                                    }
                                    Text("Look Up Metadata")
                                }
                            }
                            .disabled(isLookingUp || !canLookup)

                            Spacer()

                            // Lookup status
                            if let message = lookupMessage {
                                HStack(spacing: 4) {
                                    Image(systemName: lookupSuccess ? "checkmark.circle.fill" : "info.circle")
                                        .foregroundStyle(lookupSuccess ? .green : .secondary)
                                    Text(message)
                                        .font(.caption)
                                        .foregroundStyle(lookupSuccess ? .green : .secondary)
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                } label: {
                    HStack {
                        Text("Metadata")
                        Spacer()
                        if preview.enrichedMetadata != nil {
                            Label("Found: \(preview.enrichedMetadata!.source)", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                }

                // Abstract (if available, read-only)
                if let abstract = preview.enrichedMetadata?.abstract, !abstract.isEmpty {
                    GroupBox("Abstract") {
                        Text(abstract)
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                }

                // Duplicate warning
                if preview.isDuplicate {
                    GroupBox {
                        Label("This PDF may be a duplicate of an existing publication.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .padding()
        }
        .onAppear {
            initializeEditingState()
        }
        .onChange(of: preview.id) { _, _ in
            initializeEditingState()
        }
    }

    // MARK: - Helpers

    private var canLookup: Bool {
        // Can lookup if there's a DOI, arXiv ID, or title+authors
        let hasDOI = !editedDOI.isEmpty
        let hasArXiv = !editedArXivID.isEmpty
        let hasTitle = !editedTitle.isEmpty
        let hasAuthors = !editedAuthors.isEmpty
        return hasDOI || hasArXiv || (hasTitle && (hasAuthors || !editedYear.isEmpty))
    }

    private func initializeEditingState() {
        // Initialize with effective values (user-edited → enriched → extracted)
        editedTitle = preview.userEditedTitle
            ?? preview.enrichedMetadata?.title
            ?? preview.extractedMetadata?.bestTitle
            ?? ""

        let authors = preview.userEditedAuthors
            ?? (preview.enrichedMetadata?.authors.joined(separator: ", "))
            ?? (preview.extractedMetadata?.heuristicAuthors.joined(separator: ", "))
            ?? preview.extractedMetadata?.author
            ?? ""
        editedAuthors = authors

        if let year = preview.userEditedYear {
            editedYear = year
        } else if let year = preview.enrichedMetadata?.year {
            editedYear = String(year)
        } else if let year = preview.extractedMetadata?.heuristicYear {
            editedYear = String(year)
        } else {
            editedYear = ""
        }

        editedDOI = preview.userEditedDOI
            ?? preview.enrichedMetadata?.doi
            ?? preview.extractedMetadata?.extractedDOI
            ?? ""

        editedArXivID = preview.userEditedArXivID
            ?? preview.enrichedMetadata?.arxivID
            ?? preview.extractedMetadata?.extractedArXivID
            ?? ""

        editedJournal = preview.userEditedJournal
            ?? preview.enrichedMetadata?.journal
            ?? preview.extractedMetadata?.heuristicJournal
            ?? ""
    }

    private func performLookup() {
        isLookingUp = true
        lookupMessage = nil
        lookupSuccess = false

        Task {
            do {
                let enriched = try await coordinator.lookupMetadata(
                    doi: editedDOI.isEmpty ? nil : editedDOI,
                    arxivID: editedArXivID.isEmpty ? nil : editedArXivID,
                    title: editedTitle.isEmpty ? nil : editedTitle,
                    authors: editedAuthors.isEmpty ? [] : editedAuthors.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
                    year: Int(editedYear)
                )

                await MainActor.run {
                    if let enriched {
                        preview.enrichedMetadata = enriched
                        lookupMessage = "Found in \(enriched.source)"
                        lookupSuccess = true

                        // Update fields with enriched data if user hasn't edited them
                        if preview.userEditedTitle == nil, let title = enriched.title {
                            editedTitle = title
                        }
                        if preview.userEditedAuthors == nil, !enriched.authors.isEmpty {
                            editedAuthors = enriched.authors.joined(separator: ", ")
                        }
                        if preview.userEditedYear == nil, let year = enriched.year {
                            editedYear = String(year)
                        }
                        if preview.userEditedDOI == nil, let doi = enriched.doi {
                            editedDOI = doi
                        }
                        if preview.userEditedArXivID == nil, let arxiv = enriched.arxivID {
                            editedArXivID = arxiv
                        }
                        if preview.userEditedJournal == nil, let journal = enriched.journal {
                            editedJournal = journal
                        }

                        logger.info("Lookup succeeded: \(enriched.source)")
                    } else {
                        lookupMessage = "No match found"
                        lookupSuccess = false
                        logger.info("Lookup returned no results")
                    }
                }
            } catch {
                await MainActor.run {
                    lookupMessage = "Lookup failed"
                    lookupSuccess = false
                    logger.error("Lookup failed: \(error.localizedDescription)")
                }
            }
            await MainActor.run {
                isLookingUp = false
            }
        }
    }
}

// MARK: - Bib Import Preview View

struct BibImportPreviewView: View {

    let preview: BibImportPreview
    let onUpdateEntry: (UUID, Bool) -> Void

    @State private var selectedID: UUID?

    var body: some View {
        NavigationSplitView {
            // List of entries
            List(preview.entries, selection: $selectedID) { entry in
                BibEntryRow(entry: entry) { isSelected in
                    onUpdateEntry(entry.id, isSelected)
                }
            }
            #if os(macOS)
            .frame(minWidth: 200)
            #endif
        } detail: {
            // Detail view
            if let selectedID,
               let entry = preview.entries.first(where: { $0.id == selectedID }) {
                BibEntryDetail(entry: entry)
            } else {
                ContentUnavailableView(
                    "Select an entry",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Select an entry to see details")
                )
            }
        }
        .onAppear {
            if selectedID == nil, let first = preview.entries.first {
                selectedID = first.id
            }
        }
    }
}

// MARK: - Bib Entry Row

struct BibEntryRow: View {

    let entry: BibImportEntry
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack {
            Toggle("", isOn: Binding(
                get: { entry.isSelected },
                set: { onToggle($0) }
            ))
            .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title ?? entry.citeKey)
                    .font(.headline)
                    .lineLimit(1)
                    .foregroundStyle(entry.isDuplicate ? .secondary : .primary)

                HStack(spacing: 8) {
                    Text(entry.citeKey)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let year = entry.year {
                        Text(String(year))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if entry.isDuplicate {
                        Label("Duplicate", systemImage: "doc.on.doc")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Bib Entry Detail

struct BibEntryDetail: View {

    let entry: BibImportEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Entry") {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Cite Key", value: entry.citeKey)
                        LabeledContent("Type", value: entry.entryType)
                        if let title = entry.title {
                            LabeledContent("Title", value: title)
                        }
                        if !entry.authors.isEmpty {
                            LabeledContent("Authors", value: entry.authors.joined(separator: ", "))
                        }
                        if let year = entry.year {
                            LabeledContent("Year", value: String(year))
                        }
                    }
                }

                if let raw = entry.rawContent {
                    GroupBox("Raw Content") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(raw)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }

                if entry.isDuplicate {
                    GroupBox {
                        Label("An entry with this cite key already exists.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .padding()
        }
    }
}

// MARK: - Preview

#Preview {
    let pdfPreview = PDFImportPreview(
        sourceURL: URL(fileURLWithPath: "/tmp/test.pdf"),
        filename: "Einstein_1905_Relativity.pdf",
        fileSize: 1024 * 1024 * 2,
        extractedMetadata: PDFExtractedMetadata(
            title: "On the Electrodynamics of Moving Bodies",
            author: "A. Einstein",
            extractedDOI: "10.1002/andp.19053221004",
            confidence: .high
        ),
        enrichedMetadata: EnrichedMetadata(
            title: "On the Electrodynamics of Moving Bodies",
            authors: ["Albert Einstein"],
            year: 1905,
            journal: "Annalen der Physik",
            doi: "10.1002/andp.19053221004",
            source: "Crossref"
        )
    )

    DropPreviewSheet(
        preview: .constant(.pdfImport([pdfPreview])),
        libraryID: UUID(),
        coordinator: DragDropCoordinator.shared
    )
}
