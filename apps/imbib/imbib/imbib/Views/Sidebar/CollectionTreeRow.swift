//
//  CollectionTreeRow.swift
//  imbib
//
//  Created by Claude on 2026-01-29.
//

import SwiftUI
import PublicationManagerCore
import UniformTypeIdentifiers

// MARK: - Collection Tree Row

/// A tree row for library collections with hierarchical display.
///
/// Displays a flat row with indentation, disclosure triangle for items with children,
/// and supports drag-drop for nesting collections.
struct CollectionTreeRow: View {

    // MARK: - Properties

    let collection: CDCollection
    let allCollections: [CDCollection]
    @Binding var selection: SidebarSection?
    @Binding var expandedCollections: Set<UUID>

    var onRename: (CDCollection) -> Void
    var onEdit: ((CDCollection) -> Void)?
    var onDelete: (CDCollection) -> Void
    var onCreateSubcollection: (CDCollection) -> Void
    var onDropPublications: ([UUID], CDCollection) async -> Void
    var onMoveCollection: ((CDCollection, CDCollection?) -> Void)?

    /// Whether this collection is currently being renamed
    var isEditing: Bool = false

    /// Callback for when renaming is complete
    var onRenameComplete: ((String) -> Void)?

    // MARK: - State

    @State private var isDropTargeted = false
    @State private var editingName: String = ""

    // MARK: - Computed Properties

    private var depth: Int { Int(collection.depth) }
    private var hasChildren: Bool { collection.hasChildren }
    private var isExpanded: Bool { expandedCollections.contains(collection.id) }

    // MARK: - Body

    var body: some View {
        // Guard against deleted Core Data objects
        if collection.managedObjectContext == nil {
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
                            expandedCollections.remove(collection.id)
                        } else {
                            expandedCollections.insert(collection.id)
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

            // Folder icon (gear variant for smart collections)
            Image(systemName: collection.isSmartCollection ? "folder.badge.gearshape" : "folder")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .padding(.leading, 2)

            // Collection name (editable when renaming)
            if isEditing {
                TextField("Collection Name", text: $editingName)
                    .textFieldStyle(.plain)
                    .padding(.leading, 4)
                    .onSubmit {
                        onRenameComplete?(editingName)
                    }
                    .onAppear {
                        editingName = collection.name
                    }
            } else {
                Text(collection.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 4)
            }

            Spacer()

            // Count badge
            let count = collection.matchingPublicationCount
            if count > 0 {
                Text("\(count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(Capsule())
            }
        }
        .contentShape(Rectangle())
        .listRowBackground(
            isDropTargeted
                ? Color.accentColor.opacity(0.2)
                : nil
        )
        .tag(SidebarSection.collection(collection))
        .contextMenu {
            Button("Rename") {
                onRename(collection)
            }

            if collection.isSmartCollection, let onEdit = onEdit {
                Button("Edit") {
                    onEdit(collection)
                }
            }

            Divider()

            if !collection.isSmartCollection {
                Button {
                    onCreateSubcollection(collection)
                } label: {
                    Label("New Subcollection", systemImage: "folder.badge.plus")
                }

                Divider()
            }

            Button("Delete", role: .destructive) {
                onDelete(collection)
            }
        }
        // Drop target for publications and collections (static collections only)
        .onDrop(
            of: collection.isSmartCollection ? [] : [.publicationID, .collectionID],
            isTargeted: $isDropTargeted
        ) { providers in
            handleDrop(providers: providers)
        }
        // Draggable for collection nesting
        .itemProvider {
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: UTType.collectionID.identifier, visibility: .all) { completion in
                let data = collection.id.uuidString.data(using: .utf8)
                completion(data, nil)
                return nil
            }
            return provider
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
        // Handle collection drops (for nesting)
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.collectionID.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.collectionID.identifier, options: nil) { data, _ in
                    guard let data = data as? Data,
                          let idString = String(data: data, encoding: .utf8),
                          let draggedID = UUID(uuidString: idString) else { return }

                    // Don't allow dropping a collection onto itself or its descendants
                    if draggedID == collection.id { return }
                    if collection.ancestors.contains(where: { $0.id == draggedID }) { return }

                    // Find the dragged collection and move it
                    if let draggedCollection = allCollections.first(where: { $0.id == draggedID }) {
                        Task { @MainActor in
                            onMoveCollection?(draggedCollection, collection)
                        }
                    }
                }
                return true
            }
        }

        // Handle publication drops
        var publicationIDs: [UUID] = []
        let group = DispatchGroup()

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.publicationID.identifier) {
            group.enter()
            // Use loadDataRepresentation instead of loadItem - matches working SidebarView implementation
            provider.loadDataRepresentation(forTypeIdentifier: UTType.publicationID.identifier) { data, error in
                defer { group.leave() }
                guard let data = data else { return }

                // Try to decode as JSON array of UUIDs first (multi-selection drag from old format)
                if let uuidStrings = try? JSONDecoder().decode([String].self, from: data) {
                    for idString in uuidStrings {
                        if let uuid = UUID(uuidString: idString) {
                            publicationIDs.append(uuid)
                        }
                    }
                }
                // Fallback: try single UUID via JSONDecoder (CodableRepresentation format)
                else if let uuid = try? JSONDecoder().decode(UUID.self, from: data) {
                    publicationIDs.append(uuid)
                }
                // Final fallback: try plain UUID string (legacy string format)
                else if let idString = String(data: data, encoding: .utf8),
                        let uuid = UUID(uuidString: idString) {
                    publicationIDs.append(uuid)
                }
            }
        }

        group.notify(queue: .main) {
            if !publicationIDs.isEmpty {
                Task {
                    await onDropPublications(publicationIDs, collection)
                }
            }
        }

        return !providers.isEmpty
    }

    // MARK: - Helpers

    /// Check if this collection is the last child of its parent
    private var isLastChild: Bool {
        guard let parentID = collection.parentCollection?.id else {
            // Root level - check if it's the last root
            let rootCollections = allCollections.filter { $0.parentCollection == nil }
            return rootCollections.last?.id == collection.id
        }

        // Find siblings (children of the same parent)
        let siblings = allCollections.filter { $0.parentCollection?.id == parentID }
        return siblings.last?.id == collection.id
    }

    /// Check if an ancestor at the given depth level has siblings after it
    private func hasAncestorSiblingBelow(at level: Int) -> Bool {
        // Walk up the tree to the ancestor at the specified level
        var current: CDCollection? = collection
        var currentLevel = depth

        while currentLevel > level, let c = current {
            current = c.parentCollection
            currentLevel -= 1
        }

        // Check if this ancestor has siblings below it
        guard let ancestor = current else { return false }

        guard let parentID = ancestor.parentCollection?.id else {
            let rootCollections = allCollections.filter { $0.parentCollection == nil }
            return rootCollections.last?.id != ancestor.id
        }

        let siblings = allCollections.filter { $0.parentCollection?.id == parentID }
        return siblings.last?.id != ancestor.id
    }
}

// MARK: - Preview

#Preview("Collection Tree") {
    List {
        Text("Preview requires Core Data context")
    }
    .frame(width: 250)
}
