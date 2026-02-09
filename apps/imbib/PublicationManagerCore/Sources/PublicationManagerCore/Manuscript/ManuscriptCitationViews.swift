//
//  ManuscriptCitationViews.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-19.
//

import SwiftUI

// MARK: - Add Citation Sheet (ADR-021)

/// A sheet for adding a publication as a citation to one or more manuscripts.
///
/// Presents a list of manuscripts with checkboxes to indicate which ones
/// cite this publication.
public struct AddCitationSheet: View {

    // MARK: - Properties

    /// The publication ID to add as a citation
    public let publicationID: UUID

    /// Dismiss action
    @Environment(\.dismiss) private var dismiss

    /// The publication data
    @State private var publication: PublicationRowData?

    /// Available manuscripts
    @State private var manuscripts: [PublicationRowData] = []

    /// Selected manuscript IDs
    @State private var selectedManuscriptIDs: Set<UUID> = []

    /// Search text for filtering manuscripts
    @State private var searchText = ""

    private let store = RustStoreAdapter.shared

    // MARK: - Initialization

    public init(publicationID: UUID) {
        self.publicationID = publicationID
    }

    // MARK: - Body

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Publication being cited
                citedPublicationHeader

                Divider()

                // Manuscript list
                if filteredManuscripts.isEmpty {
                    emptyState
                } else {
                    manuscriptList
                }
            }
            .navigationTitle("Add Citation")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        saveCitations()
                        dismiss()
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Filter manuscripts")
            .onAppear {
                loadManuscripts()
            }
        }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 500)
        #endif
    }

    // MARK: - Subviews

    private var citedPublicationHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Citing:")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(publication?.title ?? "Untitled")
                .font(.headline)
                .lineLimit(2)

            if let authorStr = publication?.authorString, !authorStr.isEmpty {
                Text(authorStr)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        #if os(iOS)
        .background(Color(.secondarySystemBackground))
        #else
        .background(Color(.windowBackgroundColor).opacity(0.5))
        #endif
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Manuscripts", systemImage: "doc.text")
        } description: {
            Text("Create a manuscript first to track citations.")
        }
    }

    private var manuscriptList: some View {
        List {
            ForEach(filteredManuscripts, id: \.id) { manuscript in
                ManuscriptCitationRow(
                    manuscript: manuscript,
                    isSelected: selectedManuscriptIDs.contains(manuscript.id),
                    onToggle: { toggleSelection(manuscript) }
                )
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Computed Properties

    private var filteredManuscripts: [PublicationRowData] {
        if searchText.isEmpty {
            return manuscripts
        }
        return manuscripts.filter { manuscript in
            manuscript.title.localizedCaseInsensitiveContains(searchText) ||
            manuscript.authorString.localizedCaseInsensitiveContains(searchText)
        }
    }

    // MARK: - Actions

    private func loadManuscripts() {
        publication = store.getPublication(id: publicationID)

        // Fetch all manuscripts — publications with _manuscript_status in fields
        // Use search to find manuscripts, then filter
        manuscripts = ManuscriptCollectionManager.shared.fetchAllManuscripts()

        // Pre-select manuscripts that already cite this publication
        // Check via the manuscript's fields for cited publication IDs
        selectedManuscriptIDs = Set(
            manuscripts.filter { manuscript in
                guard let detail = store.getPublicationDetail(id: manuscript.id) else { return false }
                let citedIDs = ManuscriptCollectionManager.parseCitedIDs(from: detail.fields)
                return citedIDs.contains(publicationID)
            }.map(\.id)
        )
    }

    private func toggleSelection(_ manuscript: PublicationRowData) {
        if selectedManuscriptIDs.contains(manuscript.id) {
            selectedManuscriptIDs.remove(manuscript.id)
        } else {
            selectedManuscriptIDs.insert(manuscript.id)
        }
    }

    private func saveCitations() {
        for manuscript in manuscripts {
            let shouldCite = selectedManuscriptIDs.contains(manuscript.id)
            guard let detail = store.getPublicationDetail(id: manuscript.id) else { continue }
            var citedIDs = ManuscriptCollectionManager.parseCitedIDs(from: detail.fields)
            let currentlyCites = citedIDs.contains(publicationID)

            if shouldCite && !currentlyCites {
                citedIDs.insert(publicationID)
                let idsJSON = ManuscriptCollectionManager.encodeCitedIDs(citedIDs)
                store.updateField(id: manuscript.id, field: "_cited_publication_ids", value: idsJSON)
            } else if !shouldCite && currentlyCites {
                citedIDs.remove(publicationID)
                let idsJSON = ManuscriptCollectionManager.encodeCitedIDs(citedIDs)
                store.updateField(id: manuscript.id, field: "_cited_publication_ids", value: idsJSON)
            }
        }
    }
}

// MARK: - Manuscript Citation Row

/// A row in the manuscript selection list showing citation status.
struct ManuscriptCitationRow: View {

    let manuscript: PublicationRowData
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                // Selection indicator
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .blue : .secondary)
                    .font(.title3)

                // Manuscript info
                VStack(alignment: .leading, spacing: 4) {
                    Text(manuscript.title)
                        .font(.body)
                        .lineLimit(2)

                    HStack(spacing: 8) {
                        // Venue
                        if let venue = manuscript.venue {
                            Text(venue)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Cited Publications View

/// A view showing all publications cited by a manuscript.
public struct CitedPublicationsView: View {

    // MARK: - Properties

    /// The manuscript whose citations to show
    public let manuscriptID: UUID

    /// Cited publications
    @State private var citedPublications: [PublicationRowData] = []

    /// Search text
    @State private var searchText = ""

    private let store = RustStoreAdapter.shared

    // MARK: - Initialization

    public init(manuscriptID: UUID) {
        self.manuscriptID = manuscriptID
    }

    // MARK: - Body

    public var body: some View {
        Group {
            if citedPublications.isEmpty {
                emptyState
            } else {
                citationList
            }
        }
        .navigationTitle("Citations")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .searchable(text: $searchText, prompt: "Search citations")
        .onAppear {
            loadCitations()
        }
    }

    // MARK: - Subviews

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Citations", systemImage: "doc.text")
        } description: {
            Text("This manuscript has no linked citations yet.")
        } actions: {
            Text("Add citations from the library using the context menu.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var citationList: some View {
        List {
            Section {
                ForEach(filteredPublications, id: \.id) { publication in
                    CitedPublicationRow(publication: publication)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                removeCitation(publication)
                            } label: {
                                Label("Remove", systemImage: "minus.circle")
                            }
                        }
                }
            } header: {
                Text("\(citedPublications.count) citation\(citedPublications.count == 1 ? "" : "s")")
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
    }

    // MARK: - Computed Properties

    private var filteredPublications: [PublicationRowData] {
        if searchText.isEmpty {
            return citedPublications
        }
        return citedPublications.filter { pub in
            pub.title.localizedCaseInsensitiveContains(searchText) ||
            pub.authorString.localizedCaseInsensitiveContains(searchText)
        }
    }

    // MARK: - Actions

    private func loadCitations() {
        citedPublications = ManuscriptCollectionManager.shared
            .fetchCitedPublications(for: manuscriptID)
    }

    private func removeCitation(_ publication: PublicationRowData) {
        guard let detail = store.getPublicationDetail(id: manuscriptID) else { return }
        var citedIDs = ManuscriptCollectionManager.parseCitedIDs(from: detail.fields)
        citedIDs.remove(publication.id)
        let idsJSON = ManuscriptCollectionManager.encodeCitedIDs(citedIDs)
        store.updateField(id: manuscriptID, field: "_cited_publication_ids", value: idsJSON)
        loadCitations()
    }
}

// MARK: - Cited Publication Row

/// A row showing a cited publication.
struct CitedPublicationRow: View {

    let publication: PublicationRowData

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(publication.title)
                .font(.body)
                .lineLimit(2)

            HStack(spacing: 8) {
                Text(publication.authorString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let year = publication.year, year > 0 {
                    Text("(\(String(year)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Show identifiers if available
            if let doi = publication.doi {
                Text("DOI: \(doi)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Manuscripts Citing View

/// A view showing all manuscripts that cite a specific publication.
public struct ManuscriptsCitingView: View {

    // MARK: - Properties

    /// The publication ID to check
    public let publicationID: UUID

    /// Manuscripts that cite this publication
    @State private var citingManuscripts: [PublicationRowData] = []

    // MARK: - Initialization

    public init(publicationID: UUID) {
        self.publicationID = publicationID
    }

    // MARK: - Body

    public var body: some View {
        Group {
            if citingManuscripts.isEmpty {
                emptyState
            } else {
                manuscriptList
            }
        }
        .navigationTitle("Cited By")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            loadManuscripts()
        }
    }

    // MARK: - Subviews

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Not Cited", systemImage: "doc.text")
        } description: {
            Text("This paper is not cited in any manuscripts.")
        }
    }

    private var manuscriptList: some View {
        List {
            Section {
                ForEach(citingManuscripts, id: \.id) { manuscript in
                    ManuscriptRow(manuscript: manuscript)
                }
            } header: {
                Text("Cited in \(citingManuscripts.count) manuscript\(citingManuscripts.count == 1 ? "" : "s")")
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
    }

    // MARK: - Actions

    private func loadManuscripts() {
        citingManuscripts = ManuscriptCollectionManager.shared
            .fetchManuscriptsCiting(publicationID)
    }
}

// MARK: - Manuscript Row

/// A row showing a manuscript.
struct ManuscriptRow: View {

    let manuscript: PublicationRowData

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(manuscript.title)
                .font(.body)
                .lineLimit(2)

            HStack(spacing: 8) {
                // Venue
                if let venue = manuscript.venue {
                    Text(venue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Citation Badge

/// A badge showing how many manuscripts cite a publication.
public struct ManuscriptCitationBadge: View {

    /// The publication ID to check
    public let publicationID: UUID

    /// Number of manuscripts citing this publication
    @State private var citationCount = 0

    public init(publicationID: UUID) {
        self.publicationID = publicationID
    }

    public var body: some View {
        if citationCount > 0 {
            HStack(spacing: 4) {
                Image(systemName: "doc.text")
                    .font(.caption2)
                Text("\(citationCount)")
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.purple.opacity(0.2))
            .foregroundStyle(.purple)
            .clipShape(Capsule())
            .help("Cited in \(citationCount) manuscript\(citationCount == 1 ? "" : "s")")
            .onAppear {
                loadCount()
            }
        }
    }

    private func loadCount() {
        citationCount = ManuscriptCollectionManager.shared
            .fetchManuscriptsCiting(publicationID)
            .count
    }
}

// MARK: - Uncited Papers View

/// A view showing papers that have been read but never cited.
public struct UncitedPapersView: View {

    // MARK: - Properties

    /// Library ID to filter by (nil for all)
    public let libraryID: UUID?

    /// Uncited publications
    @State private var uncitedPublications: [PublicationRowData] = []

    /// Search text
    @State private var searchText = ""

    // MARK: - Initialization

    public init(libraryID: UUID? = nil) {
        self.libraryID = libraryID
    }

    // MARK: - Body

    public var body: some View {
        Group {
            if uncitedPublications.isEmpty {
                emptyState
            } else {
                publicationList
            }
        }
        .navigationTitle("Uncited Papers")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .searchable(text: $searchText, prompt: "Search papers")
        .onAppear {
            loadUncitedPapers()
        }
    }

    // MARK: - Subviews

    private var emptyState: some View {
        ContentUnavailableView {
            Label("All Caught Up", systemImage: "checkmark.circle")
        } description: {
            Text("All read papers have been cited in at least one manuscript.")
        }
    }

    private var publicationList: some View {
        List {
            Section {
                ForEach(filteredPublications, id: \.id) { publication in
                    CitedPublicationRow(publication: publication)
                }
            } header: {
                Text("\(uncitedPublications.count) paper\(uncitedPublications.count == 1 ? "" : "s") read but not cited")
            } footer: {
                Text("These papers have been marked as read but are not cited in any of your manuscripts.")
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
    }

    // MARK: - Computed Properties

    private var filteredPublications: [PublicationRowData] {
        if searchText.isEmpty {
            return uncitedPublications
        }
        return uncitedPublications.filter { pub in
            pub.title.localizedCaseInsensitiveContains(searchText) ||
            pub.authorString.localizedCaseInsensitiveContains(searchText)
        }
    }

    // MARK: - Actions

    private func loadUncitedPapers() {
        uncitedPublications = ManuscriptCollectionManager.shared
            .fetchUncitedPublications(in: libraryID)
    }
}

// MARK: - Preview

#Preview("Add Citation Sheet") {
    Text("Preview requires publication")
}

#Preview("Citation Badge") {
    HStack {
        Text("Paper Title")
        Spacer()
        // ManuscriptCitationBadge requires publicationID
    }
    .padding()
}
