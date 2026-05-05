//
//  ProjectSidebarView.swift
//  imprint
//
//  Sidebar for the project browser showing the folder tree hierarchy.
//  Uses SidebarOutlineView (NSOutlineView wrapper) for native macOS drag-drop
//  with blue insertion lines, auto-expand on hover, and context menus.
//
//  Features:
//  - Folder expand/collapse via NSOutlineView disclosure triangles
//  - Drag folders to reorder siblings (native blue insertion line)
//  - Drag folders onto other folders to reparent (highlight feedback)
//  - Auto-expand folders after 0.5s hover during drag
//  - Section headers are draggable to reorder
//  - Context menu: New Subfolder, Rename, Share..., Delete
//  - Drop .imprint files onto folders to add document references
//

#if os(macOS)
import SwiftUI
import AppKit
import ImprintCore
import ImpressSidebar
import UniformTypeIdentifiers

struct ProjectSidebarView: View {
    @Bindable var viewModel: ProjectSidebarViewModel

    /// Observable — updated in place by `RecentDocumentsSnapshotMaintainer`.
    /// Never nil; it's a singleton on the main actor.
    var recentSnapshot: RecentDocumentsSnapshot = .shared

    var body: some View {
        VStack(spacing: 0) {
            ForEach(viewModel.sectionOrder, id: \.self) { section in
                sectionView(for: section)
            }
        }
        .onAppear {
            viewModel.loadWorkspace()
        }
    }

    // MARK: - Section Routing

    @ViewBuilder
    private func sectionView(for section: ImprintSidebarSection) -> some View {
        switch section {
        case .workspace:
            workspaceSection
        case .recentDocuments:
            recentDocumentsSection
        }
    }

    // MARK: - Workspace Section

    @ViewBuilder
    private var workspaceSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            DraggableSectionHeader(
                section: ImprintSidebarSection.workspace,
                title: viewModel.workspace?.name,
                dragValue: SectionDragItem(type: .workspace),
                dropUTTypes: [.imprintSidebarSectionID],
                isDropTarget: viewModel.sectionDropTarget == .workspace,
                onDrop: { providers in
                    viewModel.handleSectionDrop(providers: providers, targetSection: .workspace)
                },
                onDropTargetChanged: { targeted in
                    viewModel.sectionDropTarget = targeted ? .workspace : nil
                }
            ) {
                Button {
                    viewModel.createFolder()
                } label: {
                    Image(systemName: "plus")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("New Folder")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            if viewModel.rootFolders.isEmpty {
                Text("No folders yet")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
            } else {
                SidebarOutlineView(
                    selectedNodeID: $viewModel.selectedFolderID,
                    expansionState: viewModel.expansionState,
                    configuration: viewModel.outlineConfiguration,
                    dataVersion: viewModel.dataVersion,
                    editingNodeID: $viewModel.editingFolderID
                )
            }
        }
    }

    // MARK: - Recent Documents Section

    @ViewBuilder
    private var recentDocumentsSection: some View {
        // Data source: the `RecentDocumentsSnapshot` singleton, which is
        // kept live by `RecentDocumentsSnapshotMaintainer` subscribing to
        // the shared store's event stream. Agents editing a manuscript
        // via HTTP show up here just like user-driven edits. Fall back
        // to the system recent-documents list when the shared store
        // has no data yet (pre-first-edit state).
        let storedDocs = recentSnapshot.documents
        let systemRecents = NSDocumentController.shared.recentDocumentURLs
        VStack(alignment: .leading, spacing: 0) {
            DraggableSectionHeader(
                section: ImprintSidebarSection.recentDocuments,
                dragValue: SectionDragItem(type: .recentDocuments),
                dropUTTypes: [.imprintSidebarSectionID],
                isDropTarget: viewModel.sectionDropTarget == .recentDocuments,
                onDrop: { providers in
                    viewModel.handleSectionDrop(providers: providers, targetSection: .recentDocuments)
                },
                onDropTargetChanged: { targeted in
                    viewModel.sectionDropTarget = targeted ? .recentDocuments : nil
                }
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            if !storedDocs.isEmpty {
                ForEach(storedDocs.prefix(15)) { entry in
                    RecentStoredDocumentRow(entry: entry)
                }
            } else if !systemRecents.isEmpty {
                ForEach(systemRecents.prefix(10), id: \.absoluteString) { url in
                    Button {
                        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: url.pathExtension == "tex" ? "function" : "doc.text")
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                            Text(url.deletingPathExtension().lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 12)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Text("No recent documents")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
            }
        }
    }

    // MARK: - Sharing

    private func shareFolder(_ folder: CDFolder) {
        Task {
            do {
                let (_, share) = try await ImprintCloudKitSharingService.shared.shareFolder(folder)
                await MainActor.run {
                    presentCloudKitShare(share)
                }
            } catch {
                NSLog("[ProjectSidebar] Failed to share folder: %@", error.localizedDescription)
            }
        }
    }

    private func presentCloudKitShare(_ share: Any) {
        guard let sharingService = NSSharingService(named: .cloudSharing) else { return }
        sharingService.perform(withItems: [share])
    }
}

// MARK: - Recent stored document row

/// One row in the "recent documents" sidebar section backed by a
/// `RecentDocumentEntry` from the shared store. Posts
/// `.openDocumentByID` so the app can locate the owning window or
/// reopen the file.
private struct RecentStoredDocumentRow: View {
    let entry: RecentDocumentEntry

    var body: some View {
        Button {
            NotificationCenter.default.post(
                name: .openDocumentByID,
                object: nil,
                userInfo: ["documentID": entry.id.uuidString]
            )
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if entry.sectionCount > 1 {
                        Text("\(entry.sectionCount) sections · \(entry.totalWordCount) words")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .padding(.horizontal, 12)
        }
        .buttonStyle(.plain)
        .help("Open \(entry.title)")
    }
}

extension Notification.Name {
    /// Posted when the user clicks a stored-recent-document row.
    /// userInfo: `documentID` (String UUID).
    static let openDocumentByID = Notification.Name("imprint.openDocumentByID")
}

// MARK: - Preview

#Preview {
    ProjectSidebarView(
        viewModel: ProjectSidebarViewModel()
    )
    .frame(width: 250, height: 400)
}
#endif
