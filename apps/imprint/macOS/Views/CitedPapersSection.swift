//
//  CitedPapersSection.swift
//  imprint
//
//  Sidebar section showing papers cited in the current manuscript.
//  Auto-updates when manuscript content changes.
//

import SwiftUI

/// Sidebar section displaying papers cited in the current manuscript.
///
/// This view:
/// - Extracts cite keys from the manuscript source
/// - Fetches paper metadata from imbib
/// - Provides context menu for PDF/notes/imbib actions
/// - Hidden when imbib is not installed
struct CitedPapersSection: View {
    /// The manuscript source to extract citations from
    let source: String

    @ObservedObject private var imbibService = ImbibIntegrationService.shared
    @StateObject private var bibliographyGenerator = BibliographyGenerator.shared

    @AppStorage("showCitedPapersSidebar") private var showCitedPapersSidebar = true

    @State private var isExpanded = true
    @State private var selectedPaper: CitationResult?

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
            .accessibilityIdentifier("sidebar.citedPapers")
        }
    }

    // MARK: - Section Header

    private var sectionHeader: some View {
        HStack {
            Label("Cited Papers", systemImage: "quote.opening")

            Spacer()

            if !bibliographyGenerator.citedPapers.isEmpty {
                Text("\(bibliographyGenerator.citedPapers.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.2))
                    .cornerRadius(4)
            }
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            if bibliographyGenerator.extractedCiteKeys.isEmpty {
                Text("No citations found")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Add citations using @citeKey (Typst) or \\cite{key} (LaTeX)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                ProgressView()
                    .controlSize(.small)
                Text("Loading papers...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: - Papers List

    private var papersList: some View {
        ForEach(bibliographyGenerator.citedPapers) { paper in
            CitedPaperRow(paper: paper)
                .tag(paper)
                .contextMenu {
                    paperContextMenu(for: paper)
                }
        }
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

    private func updateCitedPapers() async {
        guard #available(macOS 13.0, *) else { return }
        await bibliographyGenerator.updateCitedPapers(from: source)
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

// MARK: - Cited Paper Row

/// Row view for a cited paper in the sidebar.
struct CitedPaperRow: View {
    let paper: CitationResult

    var body: some View {
        HStack(spacing: 8) {
            // PDF indicator
            Image(systemName: paper.hasPDF ? "doc.fill" : "doc")
                .foregroundColor(paper.hasPDF ? .accentColor : .secondary)
                .font(.caption)

            VStack(alignment: .leading, spacing: 2) {
                // Cite key
                Text(paper.citeKey)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)

                // Title (truncated)
                if paper.title != "(Not found in imbib)" && paper.title != "(Failed to load)" {
                    Text(paper.title)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                } else {
                    Text(paper.title)
                        .font(.caption2)
                        .foregroundColor(.orange)
                        .lineLimit(1)
                }
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
            """)
        }
        .listStyle(.sidebar)
        .frame(width: 220)
    } detail: {
        Text("Editor")
    }
}
