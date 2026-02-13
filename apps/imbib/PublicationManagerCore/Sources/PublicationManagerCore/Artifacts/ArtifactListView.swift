//
//  ArtifactListView.swift
//  PublicationManagerCore
//
//  List view for research artifacts, using MailStyle rows.
//

import SwiftUI
import UniformTypeIdentifiers
import ImpressFTUI
import ImpressMailStyle

/// Row display model for a research artifact in a list.
nonisolated public struct ArtifactRowData: Identifiable, Hashable, Sendable, MailStyleItem {
    public let id: UUID
    public let schema: ArtifactType
    public let title: String
    public let sourceURL: String?
    public let notes: String?
    public let originalAuthor: String?
    public let fileName: String?
    public let isRead: Bool
    public let isStarred: Bool
    public let created: Date
    public let tagDisplays: [TagDisplayData]

    public init(from artifact: ResearchArtifact) {
        self.id = artifact.id
        self.schema = artifact.schema
        self.title = artifact.title
        self.sourceURL = artifact.sourceURL
        self.notes = artifact.notes
        self.originalAuthor = artifact.originalAuthor
        self.fileName = artifact.fileName
        self.isRead = artifact.isRead
        self.isStarred = artifact.isStarred
        self.created = artifact.created
        self.tagDisplays = artifact.tags
    }

    // MARK: - MailStyleItem

    public var headerText: String {
        var parts: [String] = []
        if let author = originalAuthor, !author.isEmpty {
            parts.append(author)
        }
        parts.append(schema.displayName)
        return parts.joined(separator: " · ")
    }

    public var titleText: String { title }

    public var date: Date { created }

    public var previewText: String? { notes }

    public var subtitleText: String? {
        if let url = sourceURL, !url.isEmpty {
            return url
        }
        return fileName
    }

    public var trailingBadgeText: String? { nil }

    public var hasAttachment: Bool { fileName != nil }

    public var hasSecondaryAttachment: Bool { false }
}

/// List view showing research artifacts with MailStyle rows.
public struct ArtifactListView: View {

    let typeFilter: ArtifactType?
    @Binding var selectedArtifactID: UUID?

    @State private var artifacts: [ArtifactRowData] = []
    @State private var searchText = ""
    @State private var isDropTargeted = false

    private var store: RustStoreAdapter { RustStoreAdapter.shared }

    public init(typeFilter: ArtifactType?, selectedArtifactID: Binding<UUID?>) {
        self.typeFilter = typeFilter
        self._selectedArtifactID = selectedArtifactID
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search artifacts...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            if artifacts.isEmpty {
                ContentUnavailableView(
                    "No Artifacts",
                    systemImage: "archivebox",
                    description: Text("Capture artifacts with \(Image(systemName: "command"))⇧Space")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedArtifactID) {
                    ForEach(filteredArtifacts) { row in
                        ArtifactRow(data: row)
                            .tag(row.id)
                    }
                }
                .listStyle(.plain)
            }
        }
        .task {
            loadArtifacts()
        }
        .onChange(of: store.dataVersion) { _, _ in
            loadArtifacts()
        }
        .onChange(of: searchText) { _, _ in
            loadArtifacts()
        }
        .dropDestination(for: URL.self) { urls, _ in
            handleFileDrop(urls)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .background(Color.accentColor.opacity(0.05))
                    .allowsHitTesting(false)
            }
        }
    }

    private var filteredArtifacts: [ArtifactRowData] {
        artifacts
    }

    private func handleFileDrop(_ urls: [URL]) {
        Task { @MainActor in
            for url in urls {
                if url.isFileURL {
                    _ = await ArtifactImportHandler.shared.importFile(
                        at: url,
                        type: typeFilter
                    )
                } else {
                    _ = await ArtifactImportHandler.shared.importURL(url, tags: [])
                }
            }
        }
    }

    private func loadArtifacts() {
        if searchText.isEmpty {
            let raw = store.listArtifacts(type: typeFilter)
            artifacts = raw.map { ArtifactRowData(from: $0) }
        } else {
            let raw = store.searchArtifacts(query: searchText, type: typeFilter)
            artifacts = raw.map { ArtifactRowData(from: $0) }
        }
    }
}

/// A single artifact row using MailStyleRow.
private struct ArtifactRow: View {
    let data: ArtifactRowData

    @Environment(\.mailStyleColors) private var colors

    var body: some View {
        MailStyleRow(item: data, configuration: .init()) {
            // Type icon as trailing header
            Image(systemName: data.schema.iconName)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
