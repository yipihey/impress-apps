//
//  SidebarTreeNode.swift
//  ImpressSidebar
//
//  Protocol for unified tree node representation in hierarchical sidebars.
//

import SwiftUI

// MARK: - Sidebar Tree Node Protocol

/// Protocol for items that can be displayed in a hierarchical sidebar tree.
///
/// All sidebar tree sections (libraries, collections, exploration, etc.) conform
/// to this protocol, enabling a single GenericTreeRow to render them all consistently.
///
/// **Why this exists:**
/// Instead of 5+ different row components with duplicated tree logic, one GenericTreeRow
/// handles everything. The complexity shifts to "what happens on drop" rather than
/// "how to render a tree."
@MainActor
public protocol SidebarTreeNode: Identifiable where ID == UUID {
    /// Unique identifier for this node
    var id: UUID { get }

    /// Display name shown in the sidebar
    var displayName: String { get }

    /// SF Symbol name for the icon
    var iconName: String { get }

    /// Optional count to display in a badge (nil = no badge)
    var displayCount: Int? { get }

    /// Depth in the tree hierarchy (0 = root level)
    var treeDepth: Int { get }

    /// Whether this node has children
    var hasTreeChildren: Bool { get }

    /// ID of the parent node (nil for root-level nodes)
    var parentID: UUID? { get }

    /// IDs of direct child nodes
    var childIDs: [UUID] { get }

    /// IDs of all ancestor nodes (from root to parent)
    var ancestorIDs: [UUID] { get }

    /// Optional color for the icon (nil = uses default .secondary)
    var iconColor: Color? { get }
}

// MARK: - Default Implementations

public extension SidebarTreeNode {
    /// Default: no count badge
    var displayCount: Int? { nil }

    /// Default: no parent
    var parentID: UUID? { nil }

    /// Default: no children
    var childIDs: [UUID] { [] }

    /// Default: no ancestors
    var ancestorIDs: [UUID] { [] }

    /// Default: has children if childIDs is non-empty
    var hasTreeChildren: Bool { !childIDs.isEmpty }

    /// Default: no custom icon color (uses .secondary)
    var iconColor: Color? { nil }
}

// MARK: - Tree Node Capabilities

/// Capabilities that a tree node can have.
///
/// Use these to configure what actions are available for a node type.
/// GenericTreeRow checks these flags to conditionally enable functionality.
public struct TreeNodeCapabilities: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Node can be dragged (reordering, moving to different parent)
    public static let draggable = TreeNodeCapabilities(rawValue: 1 << 0)

    /// Node can accept drops (publications, files, other nodes)
    public static let droppable = TreeNodeCapabilities(rawValue: 1 << 1)

    /// Node name can be edited inline
    public static let renamable = TreeNodeCapabilities(rawValue: 1 << 2)

    /// Node can be deleted
    public static let deletable = TreeNodeCapabilities(rawValue: 1 << 3)

    /// Node supports multi-selection (Option+click, Shift+click)
    public static let multiSelectable = TreeNodeCapabilities(rawValue: 1 << 4)

    // MARK: - Presets

    /// Library collections: full editing capabilities
    public static let libraryCollection: TreeNodeCapabilities = [
        .draggable, .droppable, .renamable, .deletable
    ]

    /// Exploration collections: can delete and multi-select, but not drag/drop/rename
    public static let explorationCollection: TreeNodeCapabilities = [
        .deletable, .multiSelectable
    ]

    /// Smart collections: can edit rules and delete, but not drag/drop
    public static let smartCollection: TreeNodeCapabilities = [
        .renamable, .deletable
    ]

    /// Read-only nodes (e.g., system items)
    public static let readOnly: TreeNodeCapabilities = []
}

// MARK: - Flattened Tree Node

/// A wrapper that adds sibling information needed for tree line rendering.
///
/// When flattening a tree for ForEach, we lose information about whether
/// a node is the last child of its parent. This wrapper preserves that info.
public struct FlattenedTreeNode<Node: SidebarTreeNode>: Identifiable {
    public let id: UUID
    public let node: Node

    /// Whether this node is the last child among its siblings at its level
    public let isLastChild: Bool

    /// For each ancestor level, whether that ancestor has siblings below it.
    /// Used to determine whether to draw │ or blank at each indentation level.
    public let ancestorHasSiblingsBelow: [Bool]

    public init(
        node: Node,
        isLastChild: Bool,
        ancestorHasSiblingsBelow: [Bool]
    ) {
        self.id = node.id
        self.node = node
        self.isLastChild = isLastChild
        self.ancestorHasSiblingsBelow = ancestorHasSiblingsBelow
    }
}
