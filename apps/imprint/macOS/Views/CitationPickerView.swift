import SwiftUI

/// Modal view for searching and inserting citations from imbib
struct CitationPickerView: View {
    @Binding var document: ImprintDocument
    let cursorPosition: Int

    @Environment(\.dismiss) private var dismiss

    @State private var searchQuery = ""
    @State private var searchResults: [CitationResult] = []
    @State private var isSearching = false
    @State private var selectedCitation: CitationResult?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Insert Citation")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
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

                if isSearching {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            // Results list
            if searchResults.isEmpty && !searchQuery.isEmpty && !isSearching {
                noResultsView
            } else if searchResults.isEmpty {
                emptyStateView
            } else {
                List(searchResults, selection: $selectedCitation) { result in
                    CitationResultRow(citation: result)
                        .tag(result)
                }
                .listStyle(.plain)
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

                Button("Insert") {
                    insertCitation()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedCitation == nil)
            }
            .padding()
        }
        .frame(width: 500, height: 400)
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

    private func search() {
        isSearching = true

        // TODO: Call imbib via CloudKit or IPC
        // For now, simulate with sample data
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)

            // Sample results
            searchResults = [
                CitationResult(
                    id: UUID(),
                    citeKey: "einstein1905special",
                    title: "On the Electrodynamics of Moving Bodies",
                    authors: "Einstein, A.",
                    year: 1905,
                    venue: "Annalen der Physik",
                    formattedPreview: "Einstein (1905)",
                    bibtex: "@article{einstein1905special, author={Einstein, Albert}, title={On the Electrodynamics of Moving Bodies}, year={1905}}"
                ),
                CitationResult(
                    id: UUID(),
                    citeKey: "einstein1905photon",
                    title: "On a Heuristic Viewpoint Concerning the Production and Transformation of Light",
                    authors: "Einstein, A.",
                    year: 1905,
                    venue: "Annalen der Physik",
                    formattedPreview: "Einstein (1905)",
                    bibtex: "@article{einstein1905photon, author={Einstein, Albert}, title={On a Heuristic Viewpoint}, year={1905}}"
                ),
            ].filter { result in
                result.title.localizedCaseInsensitiveContains(searchQuery) ||
                result.authors.localizedCaseInsensitiveContains(searchQuery) ||
                result.citeKey.localizedCaseInsensitiveContains(searchQuery)
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
struct CitationResult: Identifiable, Hashable {
    let id: UUID
    let citeKey: String
    let title: String
    let authors: String
    let year: Int
    let venue: String
    let formattedPreview: String
    let bibtex: String
}

/// Row view for a citation search result
struct CitationResultRow: View {
    let citation: CitationResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(citation.title)
                .font(.headline)
                .lineLimit(2)

            HStack {
                Text(citation.authors)
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Text("(\(citation.year))")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

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
        .padding(.vertical, 4)
    }
}

#Preview {
    CitationPickerView(
        document: .constant(ImprintDocument()),
        cursorPosition: 0
    )
}
