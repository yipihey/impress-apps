import SwiftUI
import ImpressKit

/// Modal view for searching and inserting citations from imbib.
///
/// Searches the local imbib library first. When library hits are thin, the
/// user can trigger an external search (ADS / arXiv / Crossref / …) that asks
/// imbib to fetch and import the chosen paper in one step, then inserts the
/// citation into the manuscript with the cite key imbib assigns.
struct CitationPickerView: View {
    @Binding var document: ImprintDocument
    let cursorPosition: Int

    @Environment(\.dismiss) private var dismiss
    var imbibService = ImbibIntegrationService.shared

    @State private var searchQuery = ""
    @State private var searchResults: [CitationResult] = []
    @State private var externalResults: [ImbibExternalCandidate] = []
    @State private var isSearching = false
    @State private var isSearchingExternal = false
    @State private var selectedCitation: CitationResult?
    @State private var selectedExternalID: String?
    @State private var searchError: String?
    @State private var importingIdentifier: String?
    @State private var importError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            searchField
            Divider()
            resultsArea
            Divider()
            footer
        }
        .frame(width: 560, height: 480)
        .accessibilityIdentifier("citationPicker.container")
        .onChange(of: searchQuery) { _, newValue in
            if newValue.count >= 2 {
                search()
            } else {
                searchResults = []
                externalResults = []
            }
        }
        .task {
            await imbibService.refreshHTTPAvailability(force: true)
        }
    }

    // MARK: - Layout sections

    private var header: some View {
        HStack {
            Text("Insert Citation").font(.headline)
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("citationPicker.cancelButton")
        }
        .padding()
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Title, author, cite key, DOI, or arXiv id…", text: $searchQuery)
                .textFieldStyle(.plain)
                .onSubmit { searchEverywhere() }
                .accessibilityIdentifier("citationPicker.searchField")
            if isSearching || isSearchingExternal {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var resultsArea: some View {
        if !imbibService.isAvailable {
            imbibNotAvailableView
        } else if let error = searchError {
            errorView(error)
        } else if searchResults.isEmpty && externalResults.isEmpty && searchQuery.isEmpty {
            emptyStateView
        } else {
            resultsList
        }
    }

    private var resultsList: some View {
        List(selection: $selectedCitation) {
            if !searchResults.isEmpty {
                Section(header: Text("In your library")) {
                    ForEach(searchResults) { result in
                        CitationResultRow(citation: result)
                            .tag(result)
                            .contextMenu { citationContextMenu(for: result) }
                    }
                }
            }

            if !externalResults.isEmpty {
                Section(header: externalSectionHeader) {
                    ForEach(externalResults) { candidate in
                        ExternalCandidateRow(
                            candidate: candidate,
                            isImporting: importingIdentifier == candidate.identifier,
                            onAddAndCite: { Task { await importAndCite(candidate) } }
                        )
                    }
                }
            }

            if searchResults.isEmpty && externalResults.isEmpty && !isSearching {
                noResultsSection
            }

            if let importError {
                Text(importError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if !imbibService.isAutomationEnabled {
                automationBanner
            }
        }
        .listStyle(.inset)
        .accessibilityIdentifier("citationPicker.resultsList")
    }

    private var externalSectionHeader: some View {
        HStack {
            Text("Found via ADS / arXiv / Crossref")
            if isSearchingExternal {
                Spacer()
                ProgressView().controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var noResultsSection: some View {
        if !searchQuery.isEmpty {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("No library matches for “\(searchQuery)”").font(.subheadline)
                    Text("Search external sources to find and add it to imbib.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Search external sources") { runExternalSearch() }
                    .disabled(!imbibService.isAutomationEnabled || isSearchingExternal)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var automationBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.slash.circle")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("imbib automation server is off").font(.caption).bold()
                Text("Enable it in imbib → Settings → Automation to fetch missing papers.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Settings") { imbibService.openAutomationSettings() }
                .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private var footer: some View {
        HStack {
            if let citation = selectedCitation {
                VStack(alignment: .leading) {
                    Text(citation.citeKey).font(.system(.body, design: .monospaced))
                    Text(citation.formattedPreview).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Insert") { insertCitation() }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedCitation == nil)
                .accessibilityIdentifier("citationPicker.insertButton")
        }
        .padding()
    }

    // MARK: - Placeholder states

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "books.vertical").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("Search Your Library").font(.headline).foregroundStyle(.secondary)
            Text("Type to search papers in imbib. If nothing matches locally, imprint can ask imbib to look online.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var imbibNotAvailableView: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 36)).foregroundStyle(.orange)
            Text("imbib Not Installed").font(.headline)
            Text("Install imbib to search and insert citations from your library.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.circle").font(.system(size: 36)).foregroundStyle(.red)
            Text("Search Error").font(.headline)
            Text(error)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Try Again") {
                searchError = nil
                search()
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Context menu

    @ViewBuilder
    private func citationContextMenu(for citation: CitationResult) -> some View {
        if citation.hasPDF {
            Button {
                imbibService.openPDF(citeKey: citation.citeKey)
            } label: { Label("Open PDF in imbib", systemImage: "doc.fill") }
        }
        Button {
            imbibService.openNotes(citeKey: citation.citeKey)
        } label: { Label("View Notes", systemImage: "note.text") }
        Button {
            imbibService.showPaper(citeKey: citation.citeKey)
        } label: { Label("Show in imbib", systemImage: "arrow.up.forward.app") }
        Divider()
        Button {
            imbibService.findRelatedPapers(citeKey: citation.citeKey)
        } label: { Label("Find Related Papers", systemImage: "link") }
    }

    // MARK: - Actions

    private func search() {
        guard imbibService.isAvailable else { return }
        isSearching = true
        searchError = nil
        importError = nil

        Task {
            do {
                searchResults = try await imbibService.searchPapers(query: searchQuery, maxResults: 20)
                // Reset external when a fresh library search returns hits.
                if !searchResults.isEmpty { externalResults = [] }
            } catch let err as ImbibIntegrationError {
                searchResults = []
                // Automation-disabled is not an "error" — it's a state shown via the banner.
                if err != .automationDisabled {
                    searchError = err.localizedDescription
                }
            } catch {
                searchResults = []
                searchError = error.localizedDescription
            }
            isSearching = false
        }
    }

    /// Cmd+Return: search library and, when thin, immediately search externally too.
    private func searchEverywhere() {
        search()
        if searchResults.count < 3 {
            runExternalSearch()
        }
    }

    private func runExternalSearch() {
        guard imbibService.isAvailable, imbibService.isAutomationEnabled else { return }
        guard !searchQuery.isEmpty else { return }
        isSearchingExternal = true
        Task {
            do {
                externalResults = try await imbibService.searchExternal(query: searchQuery, source: nil, limit: 10)
            } catch let err as ImbibIntegrationError {
                externalResults = []
                searchError = err.localizedDescription
            } catch {
                externalResults = []
                searchError = error.localizedDescription
            }
            isSearchingExternal = false
        }
    }

    private func importAndCite(_ candidate: ImbibExternalCandidate) async {
        guard !candidate.identifier.isEmpty else {
            importError = "This result has no DOI or arXiv id to import by."
            return
        }
        importingIdentifier = candidate.identifier
        importError = nil
        defer { importingIdentifier = nil }

        do {
            _ = try await imbibService.importPapers(citeKeys: [candidate.identifier])
            // Re-query the library for the freshly imported paper.
            let hits = try await imbibService.searchPapers(query: candidate.identifier, maxResults: 5)
            let match = hits.first(where: { $0.title.lowercased().contains(candidate.title.prefix(20).lowercased()) })
                ?? hits.first
            guard let citation = match else {
                importError = "imbib accepted the import but the paper isn't showing up yet. Try searching again."
                return
            }
            // Refresh the library section and insert.
            searchResults = hits
            document.addCitation(key: citation.citeKey, bibtex: citation.bibtex)
            document.insertCitation(key: citation.citeKey, at: cursorPosition)
            dismiss()
        } catch {
            importError = "Failed to import: \(error.localizedDescription)"
        }
    }

    private func insertCitation() {
        guard let citation = selectedCitation else { return }
        document.addCitation(key: citation.citeKey, bibtex: citation.bibtex)
        document.insertCitation(key: citation.citeKey, at: cursorPosition)
        dismiss()
    }
}

/// Row view for a citation from imbib's library.
struct CitationResultRow: View {
    let citation: CitationResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: citation.hasPDF ? "doc.fill" : "doc")
                    .foregroundStyle(citation.hasPDF ? Color.accentColor : Color.secondary)
                    .font(.headline)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 4) {
                    Text(citation.title).font(.headline).lineLimit(2)
                    HStack {
                        Text(citation.authors).font(.subheadline).foregroundStyle(.secondary)
                        if citation.year > 0 {
                            Text("·").foregroundStyle(.secondary)
                            Text(String(citation.year)).font(.subheadline).foregroundStyle(.secondary)
                        }
                        if !citation.venue.isEmpty {
                            Text("·").foregroundStyle(.secondary)
                            Text(citation.venue).font(.subheadline).foregroundStyle(.secondary).italic()
                        }
                    }
                    .lineLimit(1)
                    Text(citation.citeKey).font(.system(.caption, design: .monospaced)).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Row for an external candidate with an "Add & cite" action.
struct ExternalCandidateRow: View {
    let candidate: ImbibExternalCandidate
    let isImporting: Bool
    let onAddAndCite: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "globe").foregroundStyle(.secondary).font(.headline).frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(candidate.title).font(.headline).lineLimit(2)
                HStack {
                    Text(candidate.authors).font(.subheadline).foregroundStyle(.secondary)
                    if let y = candidate.year {
                        Text("·").foregroundStyle(.secondary)
                        Text(String(y)).font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let v = candidate.venue, !v.isEmpty {
                        Text("·").foregroundStyle(.secondary)
                        Text(v).font(.subheadline).foregroundStyle(.secondary).italic()
                    }
                }
                .lineLimit(1)
                Text("\(candidate.sourceID) · \(identifierLabel)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button(action: onAddAndCite) {
                if isImporting {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Add & cite", systemImage: "plus.circle")
                }
            }
            .disabled(isImporting || candidate.identifier.isEmpty)
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    private var identifierLabel: String {
        if let doi = candidate.doi, !doi.isEmpty { return "doi:\(doi)" }
        if let arxiv = candidate.arxivID, !arxiv.isEmpty { return "arXiv:\(arxiv)" }
        if let bibcode = candidate.bibcode, !bibcode.isEmpty { return bibcode }
        return candidate.identifier
    }
}

// MARK: - CitationResult

/// Search result from imbib
public struct CitationResult: Identifiable, Hashable {
    public let id: UUID
    public let citeKey: String
    public let title: String
    public let authors: String
    public let year: Int
    public let venue: String
    public let formattedPreview: String
    public let bibtex: String
    public let hasPDF: Bool

    public init(
        id: UUID,
        citeKey: String,
        title: String,
        authors: String,
        year: Int,
        venue: String,
        formattedPreview: String,
        bibtex: String,
        hasPDF: Bool = false
    ) {
        self.id = id
        self.citeKey = citeKey
        self.title = title
        self.authors = authors
        self.year = year
        self.venue = venue
        self.formattedPreview = formattedPreview
        self.bibtex = bibtex
        self.hasPDF = hasPDF
    }
}
