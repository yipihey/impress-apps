//
//  GenericTreeRow.swift
//  ImpressSidebar
//
//  A single unified row component for all hierarchical sidebar trees.
//

import SwiftUI

// MARK: - Generic Tree Row

/// A unified tree row view that works with any SidebarTreeNode conforming type.
///
/// This single component replaces multiple specialized row types (CollectionTreeRow,
/// ExplorationTreeRow, etc.) with one configurable component. Behavior is controlled
/// by `TreeNodeCapabilities` rather than by creating different view types.
///
/// **Features:**
/// - Tree lines (└ ├ │) via TreeLineView
/// - Disclosure triangle for nodes with children
/// - Icon + name + optional count badge
/// - Drop target highlighting (when `.droppable`)
/// - Inline editing (when `.renamable`)
/// - Multi-selection highlighting (when `.multiSelectable`)
public struct GenericTreeRow<Node: SidebarTreeNode>: View {

    // MARK: - Properties

    /// The flattened node with sibling information
    public let flattenedNode: FlattenedTreeNode<Node>

    /// Capabilities for this node type
    public let capabilities: TreeNodeCapabilities

    /// Whether this node is expanded (has disclosure state)
    @Binding public var isExpanded: Bool

    /// Whether this node is currently being edited inline
    public var isEditing: Bool = false

    /// Whether this node is selected in multi-selection mode
    public var isMultiSelected: Bool = false

    /// Whether this node is a drop target
    public var isDropTargeted: Bool = false

    // MARK: - Callbacks

    /// Called when the disclosure triangle is toggled
    public var onToggleExpanded: (() -> Void)?

    /// Called when inline editing completes (with new name)
    public var onRenameComplete: ((String) -> Void)?

    // MARK: - Private State

    @State private var editingName: String = ""
    @FocusState private var isTextFieldFocused: Bool

    // MARK: - Convenience Computed Properties

    private var node: Node { flattenedNode.node }
    private var depth: Int { node.treeDepth }
    private var hasChildren: Bool { node.hasTreeChildren }

    // MARK: - Initializer

    public init(
        flattenedNode: FlattenedTreeNode<Node>,
        capabilities: TreeNodeCapabilities,
        isExpanded: Binding<Bool>,
        isEditing: Bool = false,
        isMultiSelected: Bool = false,
        isDropTargeted: Bool = false,
        onToggleExpanded: (() -> Void)? = nil,
        onRenameComplete: ((String) -> Void)? = nil
    ) {
        self.flattenedNode = flattenedNode
        self.capabilities = capabilities
        self._isExpanded = isExpanded
        self.isEditing = isEditing
        self.isMultiSelected = isMultiSelected
        self.isDropTargeted = isDropTargeted
        self.onToggleExpanded = onToggleExpanded
        self.onRenameComplete = onRenameComplete
    }

    // MARK: - Body

    public var body: some View {
        HStack(spacing: 0) {
            // Tree lines for indentation
            treeIndentation

            // Disclosure triangle (if has children)
            disclosureTriangle

            // Icon
            nodeIcon

            // Name (editable or static)
            nodeName

            Spacer()

            // Count badge
            if let count = node.displayCount, count > 0 {
                CountBadge(count: count)
            }
        }
        .contentShape(Rectangle())
        .listRowBackground(rowBackground)
    }

    // MARK: - Tree Indentation

    @ViewBuilder
    private var treeIndentation: some View {
        if depth > 0 {
            ForEach(0..<depth, id: \.self) { level in
                treeLineView(at: level)
            }
        }
    }

    @ViewBuilder
    private func treeLineView(at level: Int) -> some View {
        if level == depth - 1 {
            // Final level: use the flattened node's isLastChild
            TreeLineView(
                level: level,
                depth: depth,
                isLastChild: flattenedNode.isLastChild,
                hasAncestorSiblingBelow: false  // Not used at final level
            )
        } else {
            // Parent levels: check if ancestor at this level has siblings below
            let hasSiblingsBelow = level < flattenedNode.ancestorHasSiblingsBelow.count
                ? flattenedNode.ancestorHasSiblingsBelow[level]
                : false
            TreeLineView(
                level: level,
                depth: depth,
                isLastChild: false,  // Not used at non-final levels
                hasAncestorSiblingBelow: hasSiblingsBelow
            )
        }
    }

    // MARK: - Disclosure Triangle

    @ViewBuilder
    private var disclosureTriangle: some View {
        if hasChildren {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                    onToggleExpanded?()
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
    }

    // MARK: - Node Icon

    @ViewBuilder
    private var nodeIcon: some View {
        Image(systemName: node.iconName)
            .font(.system(size: 12))
            .foregroundStyle(node.iconColor ?? .secondary)
            .frame(width: 16)
            .padding(.leading, 2)
    }

    // MARK: - Node Name

    @ViewBuilder
    private var nodeName: some View {
        if isEditing && capabilities.contains(.renamable) {
            TextField("Name", text: $editingName)
                .textFieldStyle(.plain)
                .padding(.leading, 4)
                .focused($isTextFieldFocused)
                .onSubmit {
                    onRenameComplete?(editingName)
                }
                #if os(macOS)
                .onExitCommand {
                    // Cancel on Escape - restore original name
                    onRenameComplete?(node.displayName)
                }
                #endif
                .task {
                    // Initialize name and focus immediately when editing starts
                    editingName = node.displayName
                    // Small delay to ensure TextField is in view hierarchy
                    try? await Task.sleep(for: .milliseconds(50))
                    isTextFieldFocused = true
                    // Select all text for easy replacement (macOS only)
                    #if os(macOS)
                    DispatchQueue.main.async {
                        if let window = NSApp.keyWindow,
                           let fieldEditor = window.fieldEditor(false, for: nil) as? NSTextView {
                            fieldEditor.selectAll(nil)
                        }
                    }
                    #endif
                }
        } else {
            Text(node.displayName)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, 4)
        }
    }

    // MARK: - Row Background

    @ViewBuilder
    private var rowBackground: some View {
        if isDropTargeted {
            Color.accentColor.opacity(0.2)
        } else if isMultiSelected && capabilities.contains(.multiSelectable) {
            Color.accentColor.opacity(0.2)
        } else {
            Color.clear
        }
    }
}

// MARK: - Preview

#Preview("Generic Tree Row") {
    struct PreviewNode: SidebarTreeNode {
        let id: UUID
        let displayName: String
        let iconName: String
        let displayCount: Int?
        let treeDepth: Int
        let hasTreeChildren: Bool
        let parentID: UUID?
        let childIDs: [UUID]
        let ancestorIDs: [UUID]
    }

    struct PreviewContainer: View {
        @State private var isExpanded1 = true
        @State private var isExpanded2 = false
        @State private var isExpanded3 = false

        var body: some View {
            List {
                let node1 = PreviewNode(
                    id: UUID(),
                    displayName: "Research Papers",
                    iconName: "folder",
                    displayCount: 42,
                    treeDepth: 0,
                    hasTreeChildren: true,
                    parentID: nil,
                    childIDs: [],
                    ancestorIDs: []
                )
                GenericTreeRow(
                    flattenedNode: FlattenedTreeNode(
                        node: node1,
                        isLastChild: false,
                        ancestorHasSiblingsBelow: []
                    ),
                    capabilities: .libraryCollection,
                    isExpanded: $isExpanded1
                )

                let node2 = PreviewNode(
                    id: UUID(),
                    displayName: "Machine Learning",
                    iconName: "folder",
                    displayCount: 15,
                    treeDepth: 1,
                    hasTreeChildren: true,
                    parentID: node1.id,
                    childIDs: [],
                    ancestorIDs: [node1.id]
                )
                GenericTreeRow(
                    flattenedNode: FlattenedTreeNode(
                        node: node2,
                        isLastChild: false,
                        ancestorHasSiblingsBelow: [true]
                    ),
                    capabilities: .libraryCollection,
                    isExpanded: $isExpanded2
                )

                let node3 = PreviewNode(
                    id: UUID(),
                    displayName: "Physics",
                    iconName: "folder",
                    displayCount: 8,
                    treeDepth: 1,
                    hasTreeChildren: false,
                    parentID: node1.id,
                    childIDs: [],
                    ancestorIDs: [node1.id]
                )
                GenericTreeRow(
                    flattenedNode: FlattenedTreeNode(
                        node: node3,
                        isLastChild: true,
                        ancestorHasSiblingsBelow: [false]
                    ),
                    capabilities: .libraryCollection,
                    isExpanded: $isExpanded3
                )
            }
            .listStyle(.sidebar)
            .frame(width: 250, height: 200)
        }
    }

    return PreviewContainer()
}
