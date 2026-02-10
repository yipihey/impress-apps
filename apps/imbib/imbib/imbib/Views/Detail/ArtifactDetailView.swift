//
//  ArtifactDetailView.swift
//  imbib
//
//  Detail pane for a research artifact.
//

import SwiftUI
import PublicationManagerCore
import ImpressFTUI

/// Detail view for a single research artifact.
struct ArtifactDetailView: View {

    let artifactID: UUID

    @State private var artifact: ResearchArtifact?
    @State private var isEditing = false
    @State private var editedNotes = ""

    private var store: RustStoreAdapter { RustStoreAdapter.shared }

    var body: some View {
        Group {
            if let artifact {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        headerSection(artifact)
                        infoSection(artifact)
                        if artifact.fileName != nil {
                            fileSection(artifact)
                        }
                        notesSection(artifact)
                        if !artifact.tags.isEmpty {
                            tagsSection(artifact)
                        }
                    }
                    .padding()
                    .padding(.top, 40)
                }
            } else {
                ContentUnavailableView(
                    "Artifact Not Found",
                    systemImage: "archivebox",
                    description: Text("This artifact may have been deleted.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: artifactID) {
            loadArtifact()
        }
        .onChange(of: store.dataVersion) { _, _ in
            loadArtifact()
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func headerSection(_ artifact: ResearchArtifact) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: artifact.schema.iconName)
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text(artifact.schema.displayName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()

                // Star toggle
                Button {
                    store.setArtifactStarred(ids: [artifact.id], starred: !artifact.isStarred)
                } label: {
                    Image(systemName: artifact.isStarred ? "star.fill" : "star")
                        .foregroundStyle(artifact.isStarred ? .yellow : .secondary)
                }
                .buttonStyle(.plain)

                // Read toggle
                Button {
                    store.setArtifactRead(ids: [artifact.id], read: !artifact.isRead)
                } label: {
                    Image(systemName: artifact.isRead ? "envelope.open" : "envelope.badge")
                        .foregroundStyle(artifact.isRead ? Color.secondary : Color.blue)
                }
                .buttonStyle(.plain)
            }

            Text(artifact.title)
                .font(.title2.bold())
                .textSelection(.enabled)

            if let author = artifact.originalAuthor, !author.isEmpty {
                Text(author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let url = artifact.sourceURL, !url.isEmpty, let link = URL(string: url) {
                Link(url, destination: link)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    @ViewBuilder
    private func infoSection(_ artifact: ResearchArtifact) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Details")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Type")
                        .foregroundStyle(.secondary)
                    Text(artifact.schema.displayName)
                }
                GridRow {
                    Text("Captured")
                        .foregroundStyle(.secondary)
                    Text(artifact.created, style: .date)
                }
                if let context = artifact.captureContext, !context.isEmpty {
                    GridRow {
                        Text("Context")
                            .foregroundStyle(.secondary)
                        Text(context)
                    }
                }
                if let event = artifact.eventName, !event.isEmpty {
                    GridRow {
                        Text("Event")
                            .foregroundStyle(.secondary)
                        Text(event)
                    }
                }
            }
            .font(.subheadline)
        }
    }

    @ViewBuilder
    private func fileSection(_ artifact: ResearchArtifact) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("File")
                .font(.headline)

            if let fileName = artifact.fileName {
                HStack(spacing: 8) {
                    Image(systemName: "doc.fill")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fileName)
                            .lineLimit(1)
                        if let size = artifact.fileSize {
                            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()

                    #if os(macOS)
                    Button("Reveal in Finder") {
                        revealFile(artifact)
                    }
                    .controlSize(.small)
                    #endif
                }
                .padding(8)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    @ViewBuilder
    private func notesSection(_ artifact: ResearchArtifact) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Notes")
                    .font(.headline)
                Spacer()
                Button(isEditing ? "Done" : "Edit") {
                    if isEditing {
                        saveNotes()
                    } else {
                        editedNotes = artifact.notes ?? ""
                        isEditing = true
                    }
                }
                .controlSize(.small)
            }

            if isEditing {
                TextEditor(text: $editedNotes)
                    .font(.body)
                    .frame(minHeight: 100)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.secondary.opacity(0.2))
                    )
            } else {
                let notesText = artifact.notes ?? ""
                if notesText.isEmpty {
                    Text("No notes")
                        .foregroundStyle(.tertiary)
                        .italic()
                } else {
                    Text(notesText)
                        .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private func tagsSection(_ artifact: ResearchArtifact) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tags")
                .font(.headline)

            FlowLayout(spacing: 4) {
                ForEach(artifact.tags) { tag in
                    Text(tag.leaf)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary)
                        .clipShape(Capsule())
                }
            }
        }
    }

    // MARK: - Actions

    private func loadArtifact() {
        artifact = store.getArtifact(id: artifactID)
    }

    private func saveNotes() {
        store.updateArtifact(
            id: artifactID,
            title: nil,
            sourceURL: nil,
            notes: editedNotes.isEmpty ? nil : editedNotes
        )
        isEditing = false
        loadArtifact()
    }

    #if os(macOS)
    private func revealFile(_ artifact: ResearchArtifact) {
        guard let url = ArtifactImportHandler.shared.fileURL(for: artifact) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    #endif
}

// MARK: - Flow Layout (reusable)

private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, offset) in result.offsets.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + offset.x, y: bounds.minY + offset.y),
                proposal: .unspecified
            )
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, offsets: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var offsets: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            offsets.append(CGPoint(x: currentX, y: currentY))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
        }

        return (CGSize(width: maxWidth, height: currentY + lineHeight), offsets)
    }
}
