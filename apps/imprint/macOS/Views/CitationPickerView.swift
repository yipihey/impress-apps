import SwiftUI

/// Modal view for searching and inserting citations from imbib
struct CitationPickerView: View {
    @Binding var document: ImprintDocument
    let cursorPosition: Int

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var imbibService = ImbibIntegrationService.shared

    @State private var searchQuery = ""
    @State private var searchResults: [CitationResult] = []
    @State private var isSearching = false
    @State private var selectedCitation: CitationResult?
    @State private var searchError: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Insert Citation")
                    .font(.headline)
                Spacer()
                Button(action: { dismiss() }) {
                    Text("Cancel")
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("citationPicker.cancelButton")
            }
            .padding()

            Divider()

            // Search field
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)

                TextField("Search papers...", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .onSubmit { search() }
                    .accessibilityIdentifier("citationPicker.searchField")

                if isSearching {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            // Results list
            if !imbibService.isAvailable {
                imbibNotAvailableView
            } else if !imbibService.isAutomationEnabled {
                automationDisabledView
            } else if let error = searchError {
                errorView(error)
            } else if searchResults.isEmpty && !searchQuery.isEmpty && !isSearching {
                noResultsView
            } else if searchResults.isEmpty {
                emptyStateView
            } else {
                List(searchResults, selection: $selectedCitation) { result in
                    CitationResultRow(citation: result)
                        .tag(result)
                        .contextMenu {
                            citationContextMenu(for: result)
                        }
                }
                .listStyle(.plain)
                .accessibilityIdentifier("citationPicker.resultsList")
            }

            Divider()

            // Footer with insert button
            HStack {
                if let citation = selectedCitation {
                    VStack(alignment: .leading) {
                        Text(citation.citeKey)
                            .font(.system(.body, design: .monospaced))
                        Text(citation.formattedPreview)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                Button(action: { insertCitation() }) {
                    Text("Insert")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedCitation == nil)
                .accessibilityIdentifier("citationPicker.insertButton")
            }
            .padding()
        }
        .frame(width: 500, height: 400)
        .accessibilityIdentifier("citationPicker.container")
        .onChange(of: searchQuery) { _, newValue in
            if newValue.count >= 2 {
                search()
            } else {
                searchResults = []
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "books.vertical")
                .font(.system(size: 36))
                .foregroundColor(.secondary)

            Text("Search Your Library")
                .font(.headline)
                .foregroundColor(.secondary)

            Text("Type to search papers in imbib")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResultsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36))
                .foregroundColor(.secondary)

            Text("No Results")
                .font(.headline)
                .foregroundColor(.secondary)

            Text("Try a different search term")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var imbibNotAvailableView: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundColor(.orange)

            Text("imbib Not Installed")
                .font(.headline)

            Text("Install imbib to search and insert citations from your library.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var automationDisabledView: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.circle")
                .font(.system(size: 36))
                .foregroundColor(.orange)

            Text("Automation Disabled")
                .font(.headline)

            Text("Enable automation in imbib Settings to search citations.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Open imbib Settings") {
                imbibService.openAutomationSettings()
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 36))
                .foregroundColor(.red)

            Text("Search Error")
                .font(.headline)

            Text(error)
                .font(.caption)
                .foregroundColor(.secondary)
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

    @ViewBuilder
    private func citationContextMenu(for citation: CitationResult) -> some View {
        if citation.hasPDF {
            Button {
                imbibService.openPDF(citeKey: citation.citeKey)
            } label: {
                Label("Open PDF in imbib", systemImage: "doc.fill")
            }
        }

        Button {
            imbibService.openNotes(citeKey: citation.citeKey)
        } label: {
            Label("View Notes", systemImage: "note.text")
        }

        Button {
            imbibService.showPaper(citeKey: citation.citeKey)
        } label: {
            Label("Show in imbib", systemImage: "arrow.up.forward.app")
        }

        Divider()

        Button {
            imbibService.findRelatedPapers(citeKey: citation.citeKey)
        } label: {
            Label("Find Related Papers", systemImage: "link")
        }
    }

    private func search() {
        guard imbibService.isAvailable && imbibService.isAutomationEnabled else {
            return
        }

        isSearching = true
        searchError = nil

        Task {
            do {
                if #available(macOS 13.0, *) {
                    searchResults = try await imbibService.searchPapers(query: searchQuery, maxResults: 20)
                } else {
                    // Fallback for older macOS - show message
                    searchError = "Citation search requires macOS 13 or later."
                    searchResults = []
                }
            } catch {
                searchError = error.localizedDescription
                searchResults = []
            }
            isSearching = false
        }
    }

    private func insertCitation() {
        guard let citation = selectedCitation else { return }

        // Add to bibliography
        document.addCitation(key: citation.citeKey, bibtex: citation.bibtex)

        // Insert citation reference at cursor
        document.insertCitation(key: citation.citeKey, at: cursorPosition)

        dismiss()
    }
}

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

/// Row view for a citation search result
struct CitationResultRow: View {
    let citation: CitationResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                // PDF indicator
                Image(systemName: citation.hasPDF ? "doc.fill" : "doc")
                    .foregroundColor(citation.hasPDF ? .accentColor : .secondary)
                    .font(.headline)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 4) {
                    Text(citation.title)
                        .font(.headline)
                        .lineLimit(2)

                    HStack {
                        Text(citation.authors)
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        if citation.year > 0 {
                            Text("(\(citation.year))")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Text(citation.citeKey)
                            .font(.system(.caption, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.2))
                            .cornerRadius(4)
                    }

                    if !citation.venue.isEmpty {
                        Text(citation.venue)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .italic()
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    CitationPickerView(
        document: .constant(ImprintDocument()),
        cursorPosition: 0
    )
}
