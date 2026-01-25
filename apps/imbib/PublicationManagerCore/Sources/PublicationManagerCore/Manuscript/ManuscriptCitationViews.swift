//
//  ManuscriptCitationViews.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-19.
//

import SwiftUI
import CoreData

// MARK: - Add Citation Sheet (ADR-021)

/// A sheet for adding a publication as a citation to one or more manuscripts.
///
/// Presents a list of manuscripts with checkboxes to indicate which ones
/// cite this publication.
public struct AddCitationSheet: View {

    // MARK: - Properties

    /// The publication to add as a citation
    public let publication: CDPublication

    /// Dismiss action
    @Environment(\.dismiss) private var dismiss

    /// Available manuscripts
    @State private var manuscripts: [CDPublication] = []

    /// Selected manuscript IDs
    @State private var selectedManuscriptIDs: Set<UUID> = []

    /// Search text for filtering manuscripts
    @State private var searchText = ""

    private let persistenceController: PersistenceController

    // MARK: - Initialization

    public init(
        publication: CDPublication,
        persistenceController: PersistenceController = .shared
    ) {
        self.publication = publication
        self.persistenceController = persistenceController
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

            Text(publication.title ?? "Untitled")
                .font(.headline)
                .lineLimit(2)

            if !publication.authorString.isEmpty {
                Text(publication.authorString)
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

    private var filteredManuscripts: [CDPublication] {
        if searchText.isEmpty {
            return manuscripts
        }
        return manuscripts.filter { manuscript in
            manuscript.title?.localizedCaseInsensitiveContains(searchText) ?? false ||
            manuscript.authorString.localizedCaseInsensitiveContains(searchText)
        }
    }

    // MARK: - Actions

    private func loadManuscripts() {
        manuscripts = ManuscriptCollectionManager.shared.fetchAllManuscripts()
            .sortedByManuscriptStatus()

        // Pre-select manuscripts that already cite this publication
        selectedManuscriptIDs = Set(
            manuscripts.filter { $0.cites(publication) }.map(\.id)
        )
    }

    private func toggleSelection(_ manuscript: CDPublication) {
        if selectedManuscriptIDs.contains(manuscript.id) {
            selectedManuscriptIDs.remove(manuscript.id)
        } else {
            selectedManuscriptIDs.insert(manuscript.id)
        }
    }

    private func saveCitations() {
        for manuscript in manuscripts {
            let shouldCite = selectedManuscriptIDs.contains(manuscript.id)
            let currentlyCites = manuscript.cites(publication)

            if shouldCite && !currentlyCites {
                manuscript.addCitation(publication)
            } else if !shouldCite && currentlyCites {
                manuscript.removeCitation(publication)
            }
        }

        persistenceController.save()
    }
}

// MARK: - Manuscript Citation Row

/// A row in the manuscript selection list showing citation status.
struct ManuscriptCitationRow: View {

    let manuscript: CDPublication
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
                    Text(manuscript.title ?? "Untitled")
                        .font(.body)
                        .lineLimit(2)

                    HStack(spacing: 8) {
                        // Status badge
                        if let status = manuscript.manuscriptStatus {
                            Label(status.displayName, systemImage: status.systemImage)
                                .font(.caption)
                                .foregroundStyle(status.color)
                        }

                        // Venue
                        if let venue = manuscript.submissionVenue {
                            Text(venue)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        // Citation count
                        let citationCount = manuscript.citedPublicationCount
                        if citationCount > 0 {
                            Text("\(citationCount) refs")
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
    public let manuscript: CDPublication

    /// Cited publications
    @State private var citedPublications: [CDPublication] = []

    /// Search text
    @State private var searchText = ""

    /// Selected publication for detail
    @State private var selectedPublication: CDPublication?

    // MARK: - Initialization

    public init(manuscript: CDPublication) {
        self.manuscript = manuscript
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

    private var filteredPublications: [CDPublication] {
        if searchText.isEmpty {
            return citedPublications
        }
        return citedPublications.filter { pub in
            pub.title?.localizedCaseInsensitiveContains(searchText) ?? false ||
            pub.authorString.localizedCaseInsensitiveContains(searchText)
        }
    }

    // MARK: - Actions

    private func loadCitations() {
        citedPublications = ManuscriptCollectionManager.shared
            .fetchCitedPublications(for: manuscript)
    }

    private func removeCitation(_ publication: CDPublication) {
        manuscript.removeCitation(publication)
        PersistenceController.shared.save()
        loadCitations()
    }
}

// MARK: - Cited Publication Row

/// A row showing a cited publication.
struct CitedPublicationRow: View {

    let publication: CDPublication

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(publication.title ?? "Untitled")
                .font(.body)
                .lineLimit(2)

            HStack(spacing: 8) {
                Text(publication.authorString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if publication.year > 0 {
                    Text("(\(String(publication.year)))")
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

    /// The publication to check
    public let publication: CDPublication

    /// Manuscripts that cite this publication
    @State private var citingManuscripts: [CDPublication] = []

    // MARK: - Initialization

    public init(publication: CDPublication) {
        self.publication = publication
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
            .fetchManuscriptsCiting(publication)
            .sortedByManuscriptStatus()
    }
}

// MARK: - Manuscript Row

/// A row showing a manuscript.
struct ManuscriptRow: View {

    let manuscript: CDPublication

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(manuscript.title ?? "Untitled")
                .font(.body)
                .lineLimit(2)

            HStack(spacing: 8) {
                // Status badge
                if let status = manuscript.manuscriptStatus {
                    Label(status.displayName, systemImage: status.systemImage)
                        .font(.caption)
                        .foregroundStyle(status.color)
                }

                // Venue
                if let venue = manuscript.submissionVenue {
                    Text(venue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Citation count
                let citationCount = manuscript.citedPublicationCount
                Text("\(citationCount) refs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Citation Badge

/// A badge showing how many manuscripts cite a publication.
public struct ManuscriptCitationBadge: View {

    /// The publication to check
    public let publication: CDPublication

    /// Number of manuscripts citing this publication
    @State private var citationCount = 0

    public init(publication: CDPublication) {
        self.publication = publication
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
            .fetchManuscriptsCiting(publication)
            .count
    }
}

// MARK: - Uncited Papers View

/// A view showing papers that have been read but never cited.
public struct UncitedPapersView: View {

    // MARK: - Properties

    /// Library to filter by (nil for all)
    public let library: CDLibrary?

    /// Uncited publications
    @State private var uncitedPublications: [CDPublication] = []

    /// Search text
    @State private var searchText = ""

    // MARK: - Initialization

    public init(library: CDLibrary? = nil) {
        self.library = library
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

    private var filteredPublications: [CDPublication] {
        if searchText.isEmpty {
            return uncitedPublications
        }
        return uncitedPublications.filter { pub in
            pub.title?.localizedCaseInsensitiveContains(searchText) ?? false ||
            pub.authorString.localizedCaseInsensitiveContains(searchText)
        }
    }

    // MARK: - Actions

    private func loadUncitedPapers() {
        uncitedPublications = ManuscriptCollectionManager.shared
            .fetchUncitedPublications(in: library)
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
        // ManuscriptCitationBadge requires CDPublication
    }
    .padding()
}
