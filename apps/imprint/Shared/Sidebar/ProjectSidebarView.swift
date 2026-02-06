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
import ImpressSidebar
import UniformTypeIdentifiers

struct ProjectSidebarView: View {
    @Bindable var viewModel: ProjectSidebarViewModel

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

            Text("No recent documents")
                .foregroundStyle(.secondary)
                .font(.callout)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
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

// MARK: - Preview

#Preview {
    ProjectSidebarView(
        viewModel: ProjectSidebarViewModel()
    )
    .frame(width: 250, height: 400)
}
#endif
