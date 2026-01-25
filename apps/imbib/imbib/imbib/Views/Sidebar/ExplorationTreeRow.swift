//
//  ExplorationTreeRow.swift
//  imbib
//
//  Created by Claude on 2026-01-15.
//

import SwiftUI
import PublicationManagerCore

// MARK: - Exploration Tree Row

/// A tree row for exploration collections (Cites, Refs, Similar, Co-Reads).
///
/// Displays a flat row with indentation and a disclosure triangle for items with children.
/// Works within a List with proper selection support.
struct ExplorationTreeRow: View {

    // MARK: - Properties

    let collection: CDCollection
    let allCollections: [CDCollection]
    @Binding var selection: SidebarSection?
    @Binding var expandedCollections: Set<UUID>
    @Binding var multiSelection: Set<UUID>
    @Binding var lastSelectedID: UUID?

    var onDelete: (CDCollection) -> Void
    var onDeleteMultiple: () -> Void

    // MARK: - Computed Properties

    private var depth: Int { Int(collection.depth) }
    private var hasChildren: Bool { collection.hasChildren }
    private var isExpanded: Bool { expandedCollections.contains(collection.id) }
    private var isMultiSelected: Bool { multiSelection.contains(collection.id) }

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

            // Type-specific icon
            Image(systemName: explorationIcon)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .padding(.leading, 2)

            // Collection name
            Text(collection.name)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, 4)

            Spacer()

            // Count badge
            if collection.matchingPublicationCount > 0 {
                Text("\(collection.matchingPublicationCount)")
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
            isMultiSelected
                ? Color.accentColor.opacity(0.2)
                : nil
        )
        // Option+click: Toggle selection
        .gesture(
            TapGesture()
                .modifiers(.option)
                .onEnded { _ in
                    if multiSelection.contains(collection.id) {
                        multiSelection.remove(collection.id)
                    } else {
                        multiSelection.insert(collection.id)
                    }
                    lastSelectedID = collection.id
                }
        )
        // Shift+click: Range selection
        .simultaneousGesture(
            TapGesture()
                .modifiers(.shift)
                .onEnded { _ in
                    handleShiftClick()
                }
        )
        // Normal click: Navigate
        .onTapGesture {
            multiSelection.removeAll()
            multiSelection.insert(collection.id)
            lastSelectedID = collection.id
            selection = .collection(collection)
        }
        .tag(SidebarSection.collection(collection))
        .contextMenu {
            if multiSelection.count > 1 && multiSelection.contains(collection.id) {
                Button("Delete \(multiSelection.count) Items", role: .destructive) {
                    onDeleteMultiple()
                }
            } else {
                Button("Delete", role: .destructive) {
                    onDelete(collection)
                }
            }
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

    // MARK: - Selection Handling

    /// Handle Shift+click for range selection
    private func handleShiftClick() {
        guard let lastID = lastSelectedID,
              let lastIndex = allCollections.firstIndex(where: { $0.id == lastID }),
              let currentIndex = allCollections.firstIndex(where: { $0.id == collection.id }) else {
            // No previous selection, just select this one
            multiSelection.insert(collection.id)
            lastSelectedID = collection.id
            return
        }

        // Select range from last to current
        let range = min(lastIndex, currentIndex)...max(lastIndex, currentIndex)
        for i in range {
            multiSelection.insert(allCollections[i].id)
        }
    }

    // MARK: - Helpers

    private var explorationIcon: String {
        if collection.name.hasPrefix("Refs:") { return "arrow.down.doc" }
        if collection.name.hasPrefix("Cites:") { return "arrow.up.doc" }
        if collection.name.hasPrefix("Similar:") { return "doc.on.doc" }
        if collection.name.hasPrefix("Co-Reads:") { return "person.2.fill" }
        if collection.name.hasPrefix("Search:") { return "magnifyingglass" }
        return "doc.text.magnifyingglass"
    }

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

#Preview("Exploration Tree") {
    List {
        Text("Preview requires Core Data context")
    }
    .frame(width: 250)
}
