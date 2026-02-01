//
//  FolderTreeRow.swift
//  impart
//
//  A tree row for mail folders with hierarchical display.
//  Ported from imbib's CollectionTreeRow for visual consistency.
//

import SwiftUI
import MessageManagerCore
import UniformTypeIdentifiers

// MARK: - Folder Tree Row

/// A tree row for mail folders with hierarchical display.
///
/// Displays a flat row with indentation, disclosure triangle for items with children,
/// and supports drag-drop for nesting folders and moving messages.
struct FolderTreeRow: View {

    // MARK: - Properties

    let folder: CDFolder
    let allFolders: [CDFolder]
    @Binding var selection: UUID?
    @Binding var expandedFolders: Set<UUID>

    var onRename: (CDFolder) -> Void
    var onEdit: ((CDFolder) -> Void)?
    var onDelete: (CDFolder) -> Void
    var onCreateSubfolder: (CDFolder) -> Void
    var onDropMessages: ([UUID], CDFolder) async -> Void
    var onMoveFolder: ((CDFolder, CDFolder?) -> Void)?

    /// Whether this folder is currently being renamed
    var isEditing: Bool = false

    /// Callback for when renaming is complete
    var onRenameComplete: ((String) -> Void)?

    // MARK: - State

    @State private var isDropTargeted = false
    @State private var editingName: String = ""

    // MARK: - Computed Properties

    private var depth: Int { Int(folder.depth) }
    private var hasChildren: Bool { folder.hasChildren }
    private var isExpanded: Bool { expandedFolders.contains(folder.id) }

    // MARK: - Body

    var body: some View {
        // Guard against deleted Core Data objects
        if folder.managedObjectContext == nil {
            EmptyView()
        } else {
            rowContent
        }
    }

    @ViewBuilder
    private var rowContent: some View {
        HStack(spacing: 0) {
            // Indentation based on depth
            if depth > 0 {
                ForEach(0..<depth, id: \.self) { level in
                    treeLineView(at: level)
                }
            }

            // Disclosure triangle (if has children)
            if hasChildren {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if isExpanded {
                            expandedFolders.remove(folder.id)
                        } else {
                            expandedFolders.insert(folder.id)
                        }
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12, height: 12)
                }
                .buttonStyle(.plain)
            } else {
                // Spacer to align with items that have disclosure triangles
                Spacer().frame(width: 12)
            }

            // Folder icon
            Image(systemName: folderIcon)
                .font(.system(size: 12))
                .foregroundStyle(iconColor)
                .frame(width: 16)
                .padding(.leading, 2)

            // Folder name (editable when renaming)
            if isEditing {
                TextField("Folder Name", text: $editingName, onCommit: {
                    onRenameComplete?(editingName)
                })
                .textFieldStyle(.plain)
                .padding(.leading, 4)
                .onAppear {
                    editingName = folder.name
                }
            } else {
                Text(folder.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 4)
            }

            Spacer()

            // Unread count badge
            if folder.unreadCount > 0 {
                Text("\(folder.unreadCount)")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor)
                    .clipShape(Capsule())
            }
        }
        .contentShape(Rectangle())
        .listRowBackground(
            isDropTargeted
                ? Color.accentColor.opacity(0.2)
                : nil
        )
        .tag(folder.id)
        .contextMenu {
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
        // Drop target for messages and folders (non-virtual folders only)
        .onDrop(
            of: folder.isVirtualFolder ? [] : [.impartMessageID, .impartMessageIDs, .impartFolderID],
            isTargeted: $isDropTargeted
        ) { providers in
            handleDrop(providers: providers)
        }
        // Draggable for folder nesting (non-system folders only)
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

    // MARK: - Icon Helpers

    private var folderIcon: String {
        if folder.isVirtualFolder {
            return "folder.badge.gearshape"
        }

        switch folder.role {
        case .inbox:
            return "tray"
        case .sent:
            return "paperplane"
        case .drafts:
            return "square.and.pencil"
        case .trash:
            return "trash"
        case .archive:
            return "archivebox"
        case .spam:
            return "exclamationmark.shield"
        case .agents:
            return "brain.head.profile"
        case .custom:
            return "folder"
        }
    }

    private var iconColor: Color {
        switch folder.role {
        case .inbox:
            return .accentColor
        case .trash, .spam:
            return .red
        case .agents:
            return .purple
        default:
            return .secondary
        }
    }

    // MARK: - Tree Line View

    @ViewBuilder
    private func treeLineView(at level: Int) -> some View {
        if level == depth - 1 {
            // Final level: draw └ or ├
            Text(isLastChild ? "└" : "├")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.quaternary)
                .frame(width: 12)
        } else {
            // Parent levels: draw │ if siblings below, else space
            if hasAncestorSiblingBelow(at: level) {
                Text("│")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.quaternary)
                    .frame(width: 12)
            } else {
                Spacer().frame(width: 12)
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

                    // Don't allow dropping a folder onto itself or its descendants
                    if draggedID == folder.id { return }
                    if folder.ancestors.contains(where: { $0.id == draggedID }) { return }

                    // Find the dragged folder and move it
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

                // Try to decode as JSON array of UUIDs first (multi-selection)
                if let uuidStrings = try? JSONDecoder().decode([String].self, from: data) {
                    for idString in uuidStrings {
                        if let uuid = UUID(uuidString: idString) {
                            messageIDs.append(uuid)
                        }
                    }
                }
                // Fallback: try single UUID
                else if let uuid = try? JSONDecoder().decode(UUID.self, from: data) {
                    messageIDs.append(uuid)
                }
                // Final fallback: plain UUID string
                else if let idString = String(data: data, encoding: .utf8),
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

    // MARK: - Helpers

    /// Check if this folder is the last child of its parent
    private var isLastChild: Bool {
        guard let parentID = folder.parentFolder?.id else {
            // Root level - check if it's the last root
            let rootFolders = allFolders.filter { $0.parentFolder == nil }
            return rootFolders.last?.id == folder.id
        }

        // Find siblings (children of the same parent)
        let siblings = allFolders.filter { $0.parentFolder?.id == parentID }
        return siblings.last?.id == folder.id
    }

    /// Check if an ancestor at the given depth level has siblings after it
    private func hasAncestorSiblingBelow(at level: Int) -> Bool {
        // Walk up the tree to the ancestor at the specified level
        var current: CDFolder? = folder
        var currentLevel = depth

        while currentLevel > level, let c = current {
            current = c.parentFolder
            currentLevel -= 1
        }

        // Check if this ancestor has siblings below it
        guard let ancestor = current else { return false }

        guard let parentID = ancestor.parentFolder?.id else {
            let rootFolders = allFolders.filter { $0.parentFolder == nil }
            return rootFolders.last?.id != ancestor.id
        }

        let siblings = allFolders.filter { $0.parentFolder?.id == parentID }
        return siblings.last?.id != ancestor.id
    }
}

// MARK: - Preview

#Preview("Folder Tree") {
    List {
        Text("Preview requires Core Data context")
    }
    .frame(width: 250)
}
