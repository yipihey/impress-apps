//
//  ManuscriptLibraryView.swift
//
//  Phase 1 of the unified-store pivot
//  (/Users/tabel/.claude/plans/one-store-the-store-melodic-wreath.md):
//  a read-only library window driven by ManuscriptStoreAdapter. Three
//  panes — sidebar / list / preview — wired through the @Observable
//  dataVersion so any mutation triggers a fresh fetch.
//
//  Phase 3 adds collection curation (rename, drag-drop reparent, smart
//  filters); phase 4a wires Spotlight + HTTP API into the library list.
//

import SwiftUI

/// The library window's top-level view. Singleton scene — opened from
/// `WindowGroup("manuscript-library")` in `imprintApp.swift`.
struct ManuscriptLibraryView: View {

    /// Drives the list query + preview. `@Bindable` rather than `@State`
    /// so we observe the adapter's `dataVersion` directly.
    @Bindable private var adapter = ManuscriptStoreAdapter.shared

    /// Sidebar section currently selected. Phase 1 only supports the
    /// "All Manuscripts" pseudo-section; phase 3 adds real workspaces +
    /// collections.
    @State private var selectedSection: LibrarySidebarSection = .allManuscripts

    /// ID of the manuscript shown in the preview pane. Nil when nothing
    /// is selected (e.g. on first open, or after the selected manuscript
    /// is deleted from another window).
    @State private var selectedManuscriptID: UUID?

    var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            manuscriptList
        } detail: {
            preview
        }
        .navigationTitle("imprint — Manuscripts")
        .frame(minWidth: 900, minHeight: 500)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selectedSection) {
            Section("Library") {
                Label("All Manuscripts", systemImage: "books.vertical")
                    .tag(LibrarySidebarSection.allManuscripts)
                Label("Recents", systemImage: "clock")
                    .tag(LibrarySidebarSection.recents)
                    .disabled(true)
                    .help("Phase 3 wires recents from RecentDocumentsSnapshotMaintainer.")
            }
            Section("Status") {
                ForEach(StatusFilter.allCases, id: \.self) { filter in
                    Label(filter.displayName, systemImage: filter.iconName)
                        .tag(LibrarySidebarSection.status(filter))
                        .disabled(true)
                        .help("Phase 3 enables smart-filter selection.")
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
    }

    // MARK: - Middle list

    private var manuscriptList: some View {
        // Re-fetched whenever the adapter's dataVersion changes. Avoids
        // an explicit subscription / snapshot maintainer for phase 1.
        let manuscripts = adapter.listManuscripts(limit: 500)
        return Group {
            if manuscripts.isEmpty {
                emptyListPlaceholder
            } else {
                List(selection: $selectedManuscriptID) {
                    ForEach(manuscripts) { m in
                        ManuscriptRow(manuscript: m)
                            .tag(m.id)
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationSplitViewColumnWidth(min: 280, ideal: 340)
        .id(adapter.dataVersion)  // force list rebuild on any mutation
    }

    private var emptyListPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No manuscripts yet")
                .font(.title3)
            Text("Phase 2 wires Finder open → import. For now, manuscripts created via the adapter API show up here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .padding(40)
    }

    // MARK: - Preview pane

    @ViewBuilder
    private var preview: some View {
        if let id = selectedManuscriptID,
           let manuscript = adapter.manuscript(id: id) {
            ManuscriptPreview(manuscript: manuscript)
        } else {
            VStack {
                Text("Select a manuscript")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Sidebar section model

enum LibrarySidebarSection: Hashable {
    case allManuscripts
    case recents
    case status(StatusFilter)
}

enum StatusFilter: String, CaseIterable, Hashable {
    case draft
    case internalReview
    case submitted
    case inRevision
    case published
    case archived

    var displayName: String {
        switch self {
        case .draft: return "Drafts"
        case .internalReview: return "In Review"
        case .submitted: return "Submitted"
        case .inRevision: return "In Revision"
        case .published: return "Published"
        case .archived: return "Archived"
        }
    }

    var iconName: String {
        switch self {
        case .draft: return "pencil"
        case .internalReview: return "eye"
        case .submitted: return "paperplane"
        case .inRevision: return "arrow.triangle.2.circlepath"
        case .published: return "checkmark.seal"
        case .archived: return "archivebox"
        }
    }
}

// MARK: - List row

private struct ManuscriptRow: View {
    let manuscript: ManuscriptModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(manuscript.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                formatBadge
            }
            if !manuscript.authors.isEmpty {
                Text(manuscript.authors.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 8) {
                Text(manuscript.status.capitalized)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let modified = manuscript.bodyModifiedAt {
                    Text("·").foregroundStyle(.tertiary)
                    Text(modified, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var formatBadge: some View {
        Text(manuscript.format.rawValue.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(formatColor.opacity(0.18))
            )
            .foregroundStyle(formatColor)
    }

    private var formatColor: Color {
        switch manuscript.format {
        case .typst: return .blue
        case .latex: return .orange
        }
    }
}

// MARK: - Preview pane content

private struct ManuscriptPreview: View {
    let manuscript: ManuscriptModel

    /// First 512 chars of the body, as specified by the plan. Reads from
    /// the SQLite payload — no FS hit.
    private var bodyPreview: String {
        String(manuscript.body.prefix(512))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(manuscript.title)
                        .font(.title2.bold())
                    if !manuscript.authors.isEmpty {
                        Text(manuscript.authors.joined(separator: ", "))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        Text(manuscript.format.rawValue.uppercased())
                            .font(.caption2.bold())
                        Text(manuscript.status.capitalized)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let modified = manuscript.bodyModifiedAt {
                            Text("· modified \(modified, style: .relative) ago")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                Divider()
                Text("Body preview")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text(bodyPreview)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                if manuscript.body.count > 512 {
                    Text("… (\(manuscript.body.count - 512) more characters)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 20)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
