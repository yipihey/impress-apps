//
//  FolderTreeRow.swift
//  impart
//
//  A tree row for mail folders using ImpressSidebar's GenericTreeRow
//  with domain-specific context menu and drop handling.
//

import SwiftUI
import MessageManagerCore
import ImpressSidebar
import UniformTypeIdentifiers

// MARK: - Folder Tree Row

/// A tree row for mail folders that wraps GenericTreeRow with impart-specific behavior.
struct FolderTreeRow: View {

    // MARK: - Properties

    let flattenedNode: FlattenedTreeNode<FolderNodeAdapter>
    let allFolders: [CDFolder]
    @Binding var isExpanded: Bool

    var onRename: (CDFolder) -> Void
    var onEdit: ((CDFolder) -> Void)?
    var onDelete: (CDFolder) -> Void
    var onCreateSubfolder: (CDFolder) -> Void
    var onDropMessages: ([UUID], CDFolder) async -> Void
    var onMoveFolder: ((CDFolder, CDFolder?) -> Void)?

    var isEditing: Bool = false
    var onRenameComplete: ((String) -> Void)?

    // MARK: - State

    @State private var isDropTargeted = false

    // MARK: - Convenience

    private var folder: CDFolder { flattenedNode.node.underlyingFolder }

    // MARK: - Body

    var body: some View {
        if folder.managedObjectContext == nil {
            EmptyView()
        } else {
            GenericTreeRow(
                flattenedNode: flattenedNode,
                capabilities: folder.isSystemFolder ? .readOnly : [.renamable, .deletable, .droppable, .draggable],
                isExpanded: $isExpanded,
                isEditing: isEditing,
                isDropTargeted: isDropTargeted,
                onRenameComplete: onRenameComplete
            )
            .tag(folder.id)
            .contextMenu { contextMenuContent }
            .onDrop(
                of: folder.isVirtualFolder ? [] : [.impartMessageID, .impartMessageIDs, .impartFolderID],
                isTargeted: $isDropTargeted
            ) { providers in
                handleDrop(providers: providers)
            }
            .itemProvider {
                guard !folder.isSystemFolder else { return nil }
                let provider = NSItemProvider()
                provider.registerDataRepresentation(forTypeIdentifier: UTType.impartFolderID.identifier, visibility: .all) { completion in
                    let data = folder.id.uuidString.data(using: .utf8)
                    completion(data, nil)
                    return nil
                }
                return provider
            }
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var contextMenuContent: some View {
        if !folder.isSystemFolder {
            Button("Rename") {
                onRename(folder)
            }

            if folder.isVirtualFolder, let onEdit = onEdit {
                Button("Edit") {
                    onEdit(folder)
                }
            }

            Divider()
        }

        if !folder.isVirtualFolder && !folder.isSystemFolder {
            Button {
                onCreateSubfolder(folder)
            } label: {
                Label("New Subfolder", systemImage: "folder.badge.plus")
            }

            Divider()
        }

        if !folder.isSystemFolder {
            Button("Delete", role: .destructive) {
                onDelete(folder)
            }
        }
    }

    // MARK: - Drop Handling

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        // Handle folder drops (for nesting)
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.impartFolderID.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.impartFolderID.identifier, options: nil) { data, _ in
                    guard let data = data as? Data,
                          let idString = String(data: data, encoding: .utf8),
                          let draggedID = UUID(uuidString: idString) else { return }

                    if draggedID == folder.id { return }
                    if folder.ancestors.contains(where: { $0.id == draggedID }) { return }

                    if let draggedFolder = allFolders.first(where: { $0.id == draggedID }) {
                        Task { @MainActor in
                            onMoveFolder?(draggedFolder, folder)
                        }
                    }
                }
                return true
            }
        }

        // Handle message drops
        var messageIDs: [UUID] = []
        let group = DispatchGroup()

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.impartMessageID.identifier) ||
                                         provider.hasItemConformingToTypeIdentifier(UTType.impartMessageIDs.identifier) {
            group.enter()
            let typeId = provider.hasItemConformingToTypeIdentifier(UTType.impartMessageIDs.identifier)
                ? UTType.impartMessageIDs.identifier
                : UTType.impartMessageID.identifier

            provider.loadDataRepresentation(forTypeIdentifier: typeId) { data, error in
                defer { group.leave() }
                guard let data = data else { return }

                if let uuidStrings = try? JSONDecoder().decode([String].self, from: data) {
                    for idString in uuidStrings {
                        if let uuid = UUID(uuidString: idString) {
                            messageIDs.append(uuid)
                        }
                    }
                } else if let uuid = try? JSONDecoder().decode(UUID.self, from: data) {
                    messageIDs.append(uuid)
                } else if let idString = String(data: data, encoding: .utf8),
                          let uuid = UUID(uuidString: idString) {
                    messageIDs.append(uuid)
                }
            }
        }

        group.notify(queue: .main) {
            if !messageIDs.isEmpty {
                Task {
                    await onDropMessages(messageIDs, folder)
                }
            }
        }

        return !providers.isEmpty
    }
}

// MARK: - Preview

#Preview("Folder Tree") {
    List {
        Text("Preview requires Core Data context")
    }
    .frame(width: 250)
}
