//
//  TreeFlattener.swift
//  ImpressSidebar
//
//  Utility for flattening hierarchical trees for ForEach display.
//

import SwiftUI

// MARK: - Tree Flattener

/// Flattens hierarchical tree data into a linear array suitable for ForEach.
///
/// SwiftUI's OutlineGroup has limitations and bugs. This utility provides
/// full control over tree rendering by flattening while preserving the
/// sibling information needed for proper tree line rendering (└ ├ │).
///
/// **Usage:**
/// ```swift
/// let flattened = TreeFlattener.flatten(
///     roots: rootNodes,
///     children: { $0.childNodes },
///     isExpanded: { expansionState.isExpanded($0.id) }
/// )
/// ForEach(flattened) { item in
///     GenericTreeRow(node: item.node, ...)
/// }
/// ```
@MainActor
public enum TreeFlattener {

    /// Flattens a tree into a linear array with sibling information preserved.
    ///
    /// - Parameters:
    ///   - roots: Root-level nodes to start from
    ///   - children: Closure that returns child nodes for a given node
    ///   - isExpanded: Closure that returns whether a node is expanded
    /// - Returns: Flattened array of nodes with tree rendering metadata
    public static func flatten<Node: SidebarTreeNode>(
        roots: [Node],
        children: (Node) -> [Node],
        isExpanded: (Node) -> Bool
    ) -> [FlattenedTreeNode<Node>] {
        var result: [FlattenedTreeNode<Node>] = []

        for (index, root) in roots.enumerated() {
            let isLast = index == roots.count - 1
            flattenNode(
                root,
                isLastChild: isLast,
                ancestorHasSiblingsBelow: [],
                children: children,
                isExpanded: isExpanded,
                into: &result
            )
        }

        return result
    }

    /// Recursive helper that processes a single node and its children.
    private static func flattenNode<Node: SidebarTreeNode>(
        _ node: Node,
        isLastChild: Bool,
        ancestorHasSiblingsBelow: [Bool],
        children: (Node) -> [Node],
        isExpanded: (Node) -> Bool,
        into result: inout [FlattenedTreeNode<Node>]
    ) {
        // Add this node to the result
        let flattened = FlattenedTreeNode(
            node: node,
            isLastChild: isLastChild,
            ancestorHasSiblingsBelow: ancestorHasSiblingsBelow
        )
        result.append(flattened)

        // If expanded, add children
        if isExpanded(node) {
            let childNodes = children(node)
            for (index, child) in childNodes.enumerated() {
                let childIsLast = index == childNodes.count - 1
                // Build ancestor sibling info for children:
                // - Current node's ancestor info
                // - Plus whether current node has siblings below it (i.e., not isLastChild)
                let childAncestorInfo = ancestorHasSiblingsBelow + [!isLastChild]

                flattenNode(
                    child,
                    isLastChild: childIsLast,
                    ancestorHasSiblingsBelow: childAncestorInfo,
                    children: children,
                    isExpanded: isExpanded,
                    into: &result
                )
            }
        }
    }
}

// MARK: - Convenience Extension

public extension Array where Element: SidebarTreeNode {
    /// Flatten this array of root nodes into a linear array for ForEach.
    ///
    /// - Parameters:
    ///   - children: Closure returning child nodes for a given node
    ///   - isExpanded: Closure returning whether a node is expanded
    /// - Returns: Flattened array with tree rendering metadata
    @MainActor
    func flattened(
        children: (Element) -> [Element],
        isExpanded: (Element) -> Bool
    ) -> [FlattenedTreeNode<Element>] {
        TreeFlattener.flatten(
            roots: self,
            children: children,
            isExpanded: isExpanded
        )
    }
}
