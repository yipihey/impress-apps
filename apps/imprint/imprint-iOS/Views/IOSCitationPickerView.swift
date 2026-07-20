//
//  IOSCitationPickerView.swift
//  imprint-iOS
//
//  Searchable citation picker backed by the shared App-Group store.
//
//  Publications land in the unified impress store as `bibliography-entry`
//  items (written by imbib). This view reads them through the same
//  `SharedStore` handle `ManuscriptStoreAdapter` already opens at
//  `SharedWorkspace.databasePath`, so no second database connection or
//  cross-app HTTP round-trip is needed. (The macOS `ImbibIntegrationService`
//  is NSWorkspace + HTTP and must NOT be used on iOS.)
//
//  On selection the picker hands a `PickedCitation` back to the caller,
//  which inserts a Typst `@citekey` reference at the cursor and records a
//  synthesized BibTeX stub in the document bibliography so the key survives
//  a save round-trip.
//

import SwiftUI
import OSLog
import ImprintCore
import ImpressLogging
import ImpressRustCore

// MARK: - Picked Citation

/// A publication chosen from the picker, projected from a
/// `bibliography-entry` payload.
struct PickedCitation: Identifiable, Equatable {
    let id: String          // store item id
    let citeKey: String
    let title: String
    let authors: [String]
    let year: Int?

    /// A minimal, valid BibTeX stub so `document.bibliography[citeKey]`
    /// carries enough to round-trip through `bibliography.bib` on save.
    var bibtexStub: String {
        var lines = ["@article{\(citeKey),"]
        lines.append("  title = {\(title)},")
        if !authors.isEmpty {
            lines.append("  author = {\(authors.joined(separator: " and "))},")
        }
        if let year {
            lines.append("  year = {\(year)},")
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    var authorSummary: String {
        guard !authors.isEmpty else { return "" }
        if authors.count <= 2 { return authors.joined(separator: ", ") }
        return "\(authors[0]) et al."
    }
}

// MARK: - Picker View

struct IOSCitationPickerView: View {

    /// Called with the chosen citation. The caller performs insertion.
    let onSelect: (PickedCitation) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var results: [PickedCitation] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Group {
                if let loadError {
                    ContentUnavailableView(
                        "Couldn't Load Citations",
                        systemImage: "exclamationmark.triangle",
                        description: Text(loadError)
                    )
                } else if results.isEmpty && !isLoading {
                    ContentUnavailableView(
                        searchText.isEmpty ? "No Publications" : "No Matches",
                        systemImage: "quote.opening",
                        description: Text(
                            searchText.isEmpty
                            ? "Publications added in imbib will appear here."
                            : "No publications match “\(searchText)”."
                        )
                    )
                } else {
                    List(results) { entry in
                        Button {
                            Logger.imbibIntegration.infoCapture(
                                "Citation picked: @\(entry.citeKey)",
                                category: "citation"
                            )
                            onSelect(entry)
                            dismiss()
                        } label: {
                            citationRow(entry)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("citation.item.\(entry.citeKey)")
                    }
                    .listStyle(.plain)
                    .overlay {
                        if isLoading { ProgressView() }
                    }
                }
            }
            .navigationTitle("Insert Citation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .searchable(text: $searchText, prompt: "Search title, author, cite key")
        }
        .task { await load(query: "") }
        .onChange(of: searchText) { _, newValue in
            searchTask?.cancel()
            let query = newValue
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                await load(query: query)
            }
        }
    }

    @ViewBuilder
    private func citationRow(_ entry: PickedCitation) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.title.isEmpty ? entry.citeKey : entry.title)
                .font(.body.weight(.medium))
                .lineLimit(2)
            HStack(spacing: 6) {
                Text("@\(entry.citeKey)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tint)
                if !entry.authorSummary.isEmpty {
                    Text("·").foregroundStyle(.secondary)
                    Text(entry.authorSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let year = entry.year {
                    Text("·").foregroundStyle(.secondary)
                    Text(String(year))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    // MARK: - Loading

    /// Query the shared store (through the adapter, on the main actor) and
    /// publish projected results. The FFI read is fast and bounded by the
    /// query limit — the same synchronous pattern the adapter uses for its
    /// other reads (SharedStore is not Sendable, so no off-main hop).
    private func load(query: String) async {
        isLoading = true
        loadError = nil

        let rows = ManuscriptStoreAdapter.shared.queryPublications(matching: query)
        let entries = rows.compactMap(Self.project)
        results = entries

        let label = query.trimmingCharacters(in: .whitespacesAndNewlines)
        Logger.imbibIntegration.infoCapture(
            "Citation picker loaded \(entries.count) entries (query=\(label.isEmpty ? "*" : label))",
            category: "citation"
        )
        isLoading = false
    }

    /// Project a `bibliography-entry` row into a `PickedCitation`. Returns
    /// nil only when the payload has no usable cite key.
    private static func project(_ row: SharedItemRow) -> PickedCitation? {
        let data = Data(row.payloadJson.utf8)
        let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        let citeKey = (payload["cite_key"] as? String) ?? ""
        guard !citeKey.isEmpty else { return nil }

        let title = (payload["title"] as? String) ?? ""
        let authors = (payload["authors"] as? [String]) ?? []
        // year is an Int field but may deserialize as NSNumber/String.
        let year: Int?
        if let y = payload["year"] as? Int { year = y }
        else if let y = payload["year"] as? NSNumber { year = y.intValue }
        else if let s = payload["year"] as? String, let y = Int(s) { year = y }
        else { year = nil }

        return PickedCitation(
            id: row.id,
            citeKey: citeKey,
            title: title,
            authors: authors,
            year: year
        )
    }
}

// MARK: - Preview

#Preview {
    IOSCitationPickerView(onSelect: { print("selected \($0.citeKey)") })
}
