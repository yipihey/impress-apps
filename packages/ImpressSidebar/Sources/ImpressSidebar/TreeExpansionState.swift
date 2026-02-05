//
//  TreeExpansionState.swift
//  ImpressSidebar
//
//  Observable state manager for tree expansion in hierarchical sidebars.
//

import SwiftUI

/// Manages expansion state for hierarchical tree displays.
///
/// Tracks which nodes are expanded and provides methods for common operations
/// like expanding ancestors and collapsing subtrees.
@MainActor @Observable
public final class TreeExpansionState {
    /// Set of expanded node IDs
    public var expandedIDs: Set<UUID> = []

    public init() {}

    public init(initiallyExpanded: Set<UUID>) {
        self.expandedIDs = initiallyExpanded
    }

    /// Check if a node is expanded
    public func isExpanded(_ id: UUID) -> Bool {
        expandedIDs.contains(id)
    }

    /// Toggle expansion for a node
    public func toggle(_ id: UUID) {
        if expandedIDs.contains(id) {
            expandedIDs.remove(id)
        } else {
            expandedIDs.insert(id)
        }
    }

    /// Expand a node
    public func expand(_ id: UUID) {
        expandedIDs.insert(id)
    }

    /// Collapse a node
    public func collapse(_ id: UUID) {
        expandedIDs.remove(id)
    }

    /// Expand all nodes in a set (useful for expanding ancestors)
    public func expandAll(_ ids: Set<UUID>) {
        expandedIDs.formUnion(ids)
    }

    /// Collapse all nodes
    public func collapseAll() {
        expandedIDs.removeAll()
    }

    /// Expand ancestors to make a node visible.
    /// Pass the ancestor IDs of the target node.
    public func expandAncestors(_ ancestorIDs: [UUID]) {
        for id in ancestorIDs {
            expandedIDs.insert(id)
        }
    }

    /// Creates a Binding for a specific node's expansion state
    public func binding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { self.isExpanded(id) },
            set: { isExpanded in
                if isExpanded {
                    self.expand(id)
                } else {
                    self.collapse(id)
                }
            }
        )
    }
}
