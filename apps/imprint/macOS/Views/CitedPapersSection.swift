//
//  CitedPapersSection.swift
//  imprint
//
//  Sidebar section showing papers cited in the current manuscript.
//  Auto-updates when manuscript content changes.
//

import SwiftUI
import ImpressKit
import ImpressLogging

/// Sidebar section displaying papers cited in the current manuscript.
///
/// This view:
/// - Extracts cite keys from the manuscript source
/// - Fetches paper metadata from imbib
/// - Provides context menu for PDF/notes/imbib actions
/// - Offers import to imbib for papers not found, via SciX query
/// - Hidden when imbib is not installed
struct CitedPapersSection: View {
    /// The manuscript source to extract citations from
    let source: String
    /// The manuscript title (used for suggesting new library names)
    var documentTitle: String = ""
    /// Cite key → BibTeX map from the current document. Used to extract DOIs
    /// and arXiv ids for the "import missing" flow.
    var bibliography: [String: String] = [:]

    var imbibService = ImbibIntegrationService.shared
    var bibliographyGenerator = BibliographyGenerator.shared

    /// Shared import/picker state — injected by `ContentView` which owns
    /// the sheet at `mainContent` level (so sheet presentation is isolated
    /// from this Section's body re-evals).
    @Environment(CitationPickerCoordinator.self) private var pickerCoordinator

    @AppStorage("showCitedPapersSidebar") private var showCitedPapersSidebar = true

    @State private var isExpanded = true

    var body: some View {
        if imbibService.isAvailable && showCitedPapersSidebar {
            Section(isExpanded: $isExpanded) {
                if bibliographyGenerator.citedPapers.isEmpty {
                    emptyStateView
                } else {
                    papersList
                }
            } header: {
                sectionHeader
            }
            .task(id: source) {
                await updateCitedPapers()
            }
            .onReceive(NotificationCenter.default.publisher(for: .citedPapersShouldRefresh)) { _ in
                // Force a fresh resolve — the dedup guard in
                // BibliographyGenerator would otherwise skip this call
                // because `source` hasn't changed, leaving the sidebar's
                // "N missing" badge stale after a successful import.
                Task { await updateCitedPapers(force: true) }
            }
            .accessibilityIdentifier("sidebar.citedPapers")
        }
    }

    // MARK: - Section Header

    private var sectionHeader: some View {
        HStack {
            Label("Cited Papers", systemImage: "quote.opening")

            Spacer()

            if !bibliographyGenerator.citedPapers.isEmpty {
                let unfoundCount = bibliographyGenerator.citedPapers.filter { isUnfound($0) }.count
                if unfoundCount > 0 {
                    Text("\(unfoundCount) missing")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15))
                        .clipShape(.rect(cornerRadius: 4))
                }
                Text("\(bibliographyGenerator.citedPapers.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.2))
                    .clipShape(.rect(cornerRadius: 4))
            }
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            if bibliographyGenerator.extractedCiteKeys.isEmpty {
                Text("No citations found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Add citations using @citeKey (Typst) or \\cite{key} (LaTeX)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                ProgressView()
                    .controlSize(.small)
                Text("Loading papers...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: - Papers List

    private var papersList: some View {
        ForEach(bibliographyGenerator.citedPapers) { paper in
            if isUnfound(paper) {
                UnfoundPaperRow(
                    paper: paper,
                    destinations: pickerCoordinator.destinations,
                    isLoadingDestinations: pickerCoordinator.isLoadingDestinations,
                    isImporting: pickerCoordinator.importingKeys.contains(paper.citeKey),
                    importResult: pickerCoordinator.importResults[paper.citeKey],
                    suggestedLibraryName: suggestedLibraryName,
                    destinationError: pickerCoordinator.destinationError,
                    onLoadDestinations: { await pickerCoordinator.loadDestinations() },
                    onImport: { dest in await importPaper(paper, to: dest) },
                    onImportToNewLibrary: { name in await importToNewLibrary(paper, name: name) }
                )
            } else {
                CitedPaperRow(paper: paper)
                    .tag(paper)
                    .contextMenu {
                        paperContextMenu(for: paper)
                    }
            }
        }
    }

    // MARK: - Helpers

    private func isUnfound(_ paper: CitationResult) -> Bool {
        paper.title == "(Not found in imbib)" || paper.title == "(Failed to load)"
    }

    private var suggestedLibraryName: String {
        if !documentTitle.isEmpty {
            return "References: \(documentTitle)"
        }
        return "Manuscript References"
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func paperContextMenu(for paper: CitationResult) -> some View {
        if paper.hasPDF {
            Button {
                imbibService.openPDF(citeKey: paper.citeKey)
            } label: {
                Label("Open PDF in imbib", systemImage: "doc.fill")
            }
        }

        Button {
            imbibService.openNotes(citeKey: paper.citeKey)
        } label: {
            Label("View Notes", systemImage: "note.text")
        }

        Button {
            imbibService.showPaper(citeKey: paper.citeKey)
        } label: {
            Label("Show in imbib", systemImage: "arrow.up.forward.app")
        }

        Divider()

        Button {
            imbibService.findRelatedPapers(citeKey: paper.citeKey)
        } label: {
            Label("Find Related Papers", systemImage: "link")
        }

        Divider()

        Button {
            copyBibTeX(for: paper)
        } label: {
            Label("Copy BibTeX", systemImage: "doc.on.doc")
        }

        Button {
            copyCiteKey(paper.citeKey)
        } label: {
            Label("Copy Cite Key", systemImage: "textformat")
        }
    }

    // MARK: - Actions

    private func updateCitedPapers(force: Bool = false) async {
        guard #available(macOS 13.0, *) else { return }
        await bibliographyGenerator.updateCitedPapers(from: source, force: force)
    }

    private func importPaper(
        _ paper: CitationResult,
        to destination: ImbibIntegrationService.ImportDestination
    ) async {
        await pickerCoordinator.requestResolve(
            paper: paper,
            destination: destination,
            newLibraryName: nil,
            bibliography: bibliography
        )
    }

    private func importToNewLibrary(_ paper: CitationResult, name: String) async {
        await pickerCoordinator.requestResolve(
            paper: paper,
            destination: nil,
            newLibraryName: name,
            bibliography: bibliography
        )
    }

    private func copyBibTeX(for paper: CitationResult) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paper.bibtex, forType: .string)
    }

    private func copyCiteKey(_ citeKey: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(citeKey, forType: .string)
    }
}

// MARK: - Unfound Paper Row

/// Row for a paper not found in imbib — shows import options.
struct UnfoundPaperRow: View {
    let paper: CitationResult
    let destinations: [ImbibIntegrationService.ImportDestination]
    let isLoadingDestinations: Bool
    let isImporting: Bool
    let importResult: CitationImportResult?
    let suggestedLibraryName: String
    let destinationError: String?
    let onLoadDestinations: () async -> Void
    let onImport: (ImbibIntegrationService.ImportDestination) async -> Void
    let onImportToNewLibrary: (String) async -> Void

    @State private var newLibraryName: String = ""
    @State private var showingNewLibraryField = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.caption)

                VStack(alignment: .leading, spacing: 2) {
                    Text(paper.citeKey)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)

                    if paper.authors != "Unknown" {
                        Text("\(paper.authors)\(paper.year > 0 ? " (\(paper.year))" : "")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("Not in imbib")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }

                Spacer()

                if isImporting {
                    ProgressView()
                        .controlSize(.mini)
                } else if case .success = importResult {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                } else {
                    importMenu
                }
            }

            if case .failed(let msg) = importResult {
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            if showingNewLibraryField {
                HStack(spacing: 4) {
                    TextField("Library name", text: $newLibraryName)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)

                    Button("Create") {
                        let name = newLibraryName
                        showingNewLibraryField = false
                        Task { await onImportToNewLibrary(name) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                    .disabled(newLibraryName.isEmpty)
                }
                .padding(.leading, 24)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var importMenu: some View {
        Menu {
            // Import to existing destinations
            if let error = destinationError {
                Text(error)
                Button("Retry") {
                    Task { await onLoadDestinations() }
                }
            } else if isLoadingDestinations {
                Text("Loading libraries...")
            } else if destinations.isEmpty {
                Button("Load libraries...") {
                    Task { await onLoadDestinations() }
                }
            } else {
                // Libraries section
                let libraries = destinations.filter { $0.type == .library }
                if !libraries.isEmpty {
                    Section("Libraries") {
                        ForEach(libraries) { dest in
                            Button(dest.name) {
                                Task { await onImport(dest) }
                            }
                        }
                    }
                }

                // Collections section
                let collections = destinations.filter { $0.type == .collection }
                if !collections.isEmpty {
                    Section("Collections") {
                        ForEach(collections) { dest in
                            Button(dest.displayName) {
                                Task { await onImport(dest) }
                            }
                        }
                    }
                }

                Divider()
            }

            // New library option
            Button {
                newLibraryName = suggestedLibraryName
                showingNewLibraryField = true
            } label: {
                Label("New Library...", systemImage: "plus.rectangle.on.folder")
            }
        } label: {
            Image(systemName: "square.and.arrow.down")
                .font(.caption)
                .help("Import to imbib via SciX")
        }
        .menuStyle(.borderlessButton)
        .frame(width: 24)
        .task {
            // Auto-load destinations when menu first appears
            if destinations.isEmpty {
                await onLoadDestinations()
            }
        }
    }
}

// MARK: - Cited Paper Row

/// Row view for a cited paper in the sidebar.
struct CitedPaperRow: View {
    let paper: CitationResult

    var body: some View {
        HStack(spacing: 8) {
            // PDF indicator
            Image(systemName: paper.hasPDF ? "doc.fill" : "doc")
                .foregroundStyle(paper.hasPDF ? Color.accentColor : Color.secondary)
                .font(.caption)

            VStack(alignment: .leading, spacing: 2) {
                // Cite key
                Text(paper.citeKey)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)

                // Title (truncated)
                Text(paper.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

// MARK: - Preview

#Preview {
    NavigationSplitView {
        List {
            CitedPapersSection(source: """
            = Introduction

            Recent work by @einstein1905special has shown...

            We also reference @hawking1974black and @penrose1965.
            """, documentTitle: "Tidal D-NPF")
        }
        .listStyle(.sidebar)
        .frame(width: 220)
    } detail: {
        Text("Editor")
    }
}
