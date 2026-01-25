//
//  ReferencesTabView.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import SwiftUI

// MARK: - References Tab View

/// A tab view showing references and citations for a paper with import capabilities.
///
/// This view displays:
/// - Citation metrics header with refresh button
/// - Segmented picker to toggle between references and citations
/// - List of papers with library state indicators
/// - Import selected button for adding papers to library
///
/// ## Usage
///
/// ```swift
/// ReferencesTabView(
///     enrichmentData: enrichment,
///     isLoading: $isLoading,
///     onRefresh: { await fetchEnrichment() },
///     onImportPapers: { papers in
///         for paper in papers {
///             await importPaper(paper)
///         }
///     },
///     onNavigateToPaper: { stub in
///         showPaperDetail(stub)
///     }
/// )
/// ```
public struct ReferencesTabView: View {

    // MARK: - Properties

    /// The enrichment data containing references and citations
    public let enrichmentData: EnrichmentData?

    /// Whether enrichment data is currently being fetched
    @Binding public var isLoading: Bool

    /// Action to refresh the enrichment data
    public var onRefresh: (() async -> Void)?

    /// Action to import selected papers to library
    public var onImportPapers: (([PaperStub]) async -> Void)?

    /// Action when navigating to a paper (for exploration)
    public var onNavigateToPaper: ((PaperStub) -> Void)?

    // MARK: - State

    /// Currently selected tab (references or citations)
    @State private var selectedTab: ReferenceTab = .references

    /// Set of selected paper IDs for import
    @State private var selectedPapers: Set<String> = []

    /// Library state lookup for papers
    @State private var libraryStates: [String: LibraryState] = [:]

    /// Whether an import is in progress
    @State private var isImporting: Bool = false

    // MARK: - Initialization

    public init(
        enrichmentData: EnrichmentData?,
        isLoading: Binding<Bool>,
        onRefresh: (() async -> Void)? = nil,
        onImportPapers: (([PaperStub]) async -> Void)? = nil,
        onNavigateToPaper: ((PaperStub) -> Void)? = nil
    ) {
        self.enrichmentData = enrichmentData
        self._isLoading = isLoading
        self.onRefresh = onRefresh
        self.onImportPapers = onImportPapers
        self.onNavigateToPaper = onNavigateToPaper
    }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            // Metrics header
            metricsHeader

            // Tab picker
            Picker("View", selection: $selectedTab) {
                Text("References (\(referenceCount))").tag(ReferenceTab.references)
                Text("Citations (\(citationCount))").tag(ReferenceTab.citations)
            }
            .pickerStyle(.segmented)
            .padding()

            // Paper list
            if isLoading {
                loadingView
            } else if currentPapers.isEmpty {
                emptyStateView
            } else {
                paperList
            }

            // Import button
            if !selectedPapers.isEmpty {
                importBar
            }
        }
    }

    // MARK: - Subviews

    private var metricsHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 16) {
                    // Citation count
                    Label {
                        Text("\(enrichmentData?.citationCount ?? 0)")
                            .fontWeight(.semibold)
                    } icon: {
                        Image(systemName: "quote.bubble.fill")
                            .foregroundStyle(.blue)
                    }

                    // Reference count
                    Label {
                        Text("\(enrichmentData?.referenceCount ?? 0)")
                            .fontWeight(.semibold)
                    } icon: {
                        Image(systemName: "doc.text.fill")
                            .foregroundStyle(.green)
                    }
                }
                .font(.headline)

                // Last updated
                if let date = enrichmentData?.fetchedAt {
                    Text("Updated \(date, style: .relative)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Refresh button
            Button {
                Task {
                    await onRefresh?()
                }
            } label: {
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.bordered)
            .disabled(isLoading || onRefresh == nil)
        }
        .padding()
        .background(Color.secondary.opacity(0.1))
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading \(selectedTab == .references ? "references" : "citations")...")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: selectedTab == .references ? "doc.text" : "quote.bubble")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text(selectedTab == .references ? "No References" : "No Citations")
                .font(.headline)

            Text(selectedTab == .references
                 ? "This paper has no references in the enrichment data."
                 : "This paper has not been cited yet.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if enrichmentData == nil {
                Button("Fetch Enrichment Data") {
                    Task {
                        await onRefresh?()
                    }
                }
                .buttonStyle(.bordered)
                .disabled(onRefresh == nil)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var paperList: some View {
        List(selection: $selectedPapers) {
            ForEach(currentPapers) { paper in
                ReferenceRow(
                    paper: paper,
                    isSelected: selectedPapers.contains(paper.id),
                    libraryState: libraryStates[paper.id] ?? .unknown,
                    onTap: {
                        toggleSelection(paper)
                    },
                    onNavigate: onNavigateToPaper != nil ? {
                        onNavigateToPaper?(paper)
                    } : nil
                )
                .task {
                    await checkLibraryState(for: paper)
                }
            }
        }
        .listStyle(.plain)
    }

    private var importBar: some View {
        HStack {
            Text("\(selectedPapers.count) selected")
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                selectedPapers.removeAll()
            } label: {
                Text("Clear")
            }
            .buttonStyle(.plain)

            Button {
                Task {
                    await importSelected()
                }
            } label: {
                if isImporting {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Label("Import Selected", systemImage: "plus.circle")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isImporting)
        }
        .padding()
        .background(Color.primary.opacity(0.05))
        .overlay(alignment: .top) {
            Divider()
        }
    }

    // MARK: - Computed Properties

    private var currentPapers: [PaperStub] {
        switch selectedTab {
        case .references:
            return enrichmentData?.references ?? []
        case .citations:
            return enrichmentData?.citations ?? []
        }
    }

    private var referenceCount: Int {
        enrichmentData?.references?.count ?? enrichmentData?.referenceCount ?? 0
    }

    private var citationCount: Int {
        enrichmentData?.citations?.count ?? enrichmentData?.citationCount ?? 0
    }

    // MARK: - Actions

    private func toggleSelection(_ paper: PaperStub) {
        // Only allow selection if not already in library
        guard libraryStates[paper.id] != .inLibrary else { return }

        if selectedPapers.contains(paper.id) {
            selectedPapers.remove(paper.id)
        } else {
            selectedPapers.insert(paper.id)
        }
    }

    private func importSelected() async {
        guard !selectedPapers.isEmpty else { return }

        isImporting = true

        let papersToImport = currentPapers.filter { selectedPapers.contains($0.id) }
        await onImportPapers?(papersToImport)

        // Clear selection and refresh library states
        selectedPapers.removeAll()

        // Mark imported papers as in library
        for paper in papersToImport {
            libraryStates[paper.id] = .inLibrary
        }

        isImporting = false
    }

    private func checkLibraryState(for paper: PaperStub) async {
        guard libraryStates[paper.id] == nil else { return }

        libraryStates[paper.id] = .checking

        // Check by DOI or arXiv ID
        var identifiers: [IdentifierType: String] = [:]
        if let doi = paper.doi {
            identifiers[.doi] = doi
        }
        if let arxivID = paper.arxivID {
            identifiers[.arxiv] = arxivID
        }

        if !identifiers.isEmpty {
            let isInLibrary = await DefaultLibraryLookupService.shared.contains(
                identifiers: identifiers
            )
            libraryStates[paper.id] = isInLibrary ? .inLibrary : .notInLibrary
        } else {
            libraryStates[paper.id] = .unknown
        }
    }
}

// MARK: - Reference Tab

/// Which list to show in the references tab
public enum ReferenceTab: String, CaseIterable, Identifiable {
    case references
    case citations

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .references: return "References"
        case .citations: return "Citations"
        }
    }
}

// MARK: - Reference Row

/// A row displaying a reference or citation with selection and library state
public struct ReferenceRow: View {

    // MARK: - Properties

    public let paper: PaperStub
    public let isSelected: Bool
    public let libraryState: LibraryState
    public var onTap: (() -> Void)?
    public var onNavigate: (() -> Void)?

    // MARK: - Initialization

    public init(
        paper: PaperStub,
        isSelected: Bool,
        libraryState: LibraryState,
        onTap: (() -> Void)? = nil,
        onNavigate: (() -> Void)? = nil
    ) {
        self.paper = paper
        self.isSelected = isSelected
        self.libraryState = libraryState
        self.onTap = onTap
        self.onNavigate = onNavigate
    }

    // MARK: - Body

    public var body: some View {
        HStack(spacing: 12) {
            // Selection/library state indicator
            selectionIndicator

            // Paper info
            VStack(alignment: .leading, spacing: 4) {
                Text(paper.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)

                Text(authorString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    if let year = paper.year {
                        Text(String(year))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if let venue = paper.venue {
                        Text(venue)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if let count = paper.citationCount, count > 0 {
                        Label("\(count)", systemImage: "quote.bubble")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    }

                    if paper.isOpenAccess == true {
                        Image(systemName: "lock.open.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
            }

            Spacer()

            // Navigate button
            if onNavigate != nil {
                Button {
                    onNavigate?()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            onTap?()
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var selectionIndicator: some View {
        switch libraryState {
        case .inLibrary:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .help("Already in library")

        case .checking:
            ProgressView()
                .scaleEffect(0.6)

        case .notInLibrary, .unknown:
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
        }
    }

    // MARK: - Computed Properties

    private var authorString: String {
        if paper.authors.isEmpty {
            return "Unknown authors"
        } else if paper.authors.count == 1 {
            return paper.authors[0]
        } else if paper.authors.count <= 3 {
            return paper.authors.joined(separator: ", ")
        } else {
            return "\(paper.authors[0]) et al."
        }
    }
}

// MARK: - Preview

#Preview("References Tab") {
    let sampleReferences = [
        PaperStub(
            id: "ref1",
            title: "Attention Is All You Need",
            authors: ["Vaswani", "Shazeer", "Parmar"],
            year: 2017,
            venue: "NeurIPS",
            citationCount: 50000,
            isOpenAccess: true
        ),
        PaperStub(
            id: "ref2",
            title: "BERT: Pre-training of Deep Bidirectional Transformers",
            authors: ["Devlin", "Chang", "Lee", "Toutanova"],
            year: 2019,
            venue: "NAACL",
            doi: "10.18653/v1/N19-1423",
            citationCount: 35000
        ),
        PaperStub(
            id: "ref3",
            title: "Language Models are Few-Shot Learners",
            authors: ["Brown", "Mann", "Ryder"],
            year: 2020,
            venue: "NeurIPS",
            arxivID: "2005.14165",
            citationCount: 8000,
            isOpenAccess: true
        )
    ]

    let sampleCitations = [
        PaperStub(
            id: "cite1",
            title: "Scaling Laws for Neural Language Models",
            authors: ["Kaplan", "McCandlish", "Henighan"],
            year: 2020,
            citationCount: 500
        )
    ]

    let enrichment = EnrichmentData(
        citationCount: 1,
        referenceCount: 3,
        references: sampleReferences,
        citations: sampleCitations,
        source: .ads
    )

    ReferencesTabView(
        enrichmentData: enrichment,
        isLoading: .constant(false),
        onRefresh: { try? await Task.sleep(for: .seconds(1)) },
        onImportPapers: { papers in
            print("Importing \(papers.count) papers")
        },
        onNavigateToPaper: { paper in
            print("Navigate to: \(paper.title)")
        }
    )
}
