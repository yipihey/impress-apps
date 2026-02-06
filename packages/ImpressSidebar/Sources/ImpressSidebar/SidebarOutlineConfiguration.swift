//
//  SidebarOutlineConfiguration.swift
//  ImpressSidebar
//
//  Configuration struct for SidebarOutlineView, providing callbacks for
//  data, capabilities, drag-drop, selection, rename, and context menus.
//

#if os(macOS)
import AppKit

/// Configuration for a `SidebarOutlineView`, providing all callbacks needed
/// to bridge between NSOutlineView and the app's data model.
///
/// This is a struct of closures rather than a protocol, keeping the generic
/// type parameter (`Node`) at the call site while NSOutlineView's data source
/// works through UUID-keyed lookups internally.
@MainActor
public struct SidebarOutlineConfiguration<Node: SidebarTreeNode> {

    /// The root-level nodes to display.
    public var rootNodes: [Node]

    /// Returns the children of a given node.
    public var childrenOf: (Node) -> [Node]

    /// Returns the capabilities for a given node.
    public var capabilitiesOf: (Node) -> TreeNodeCapabilities

    /// The pasteboard type used for drag-drop of node IDs.
    public var pasteboardType: NSPasteboard.PasteboardType

    /// Called when nodes are reordered among siblings.
    /// Parameters: reordered sibling array, optional parent node (nil = root).
    public var onReorder: (([Node], Node?) -> Void)?

    /// Called when a node is reparented.
    /// Parameters: moved node, new parent (nil = root).
    public var onReparent: ((Node, Node?) -> Void)?

    /// Called when external files are dropped onto a node.
    /// Parameters: pasteboard, target node (nil = root). Returns whether drop was handled.
    public var onExternalDrop: ((NSPasteboard, Node?) -> Bool)?

    /// Called when selection changes.
    public var onSelect: ((UUID?) -> Void)?

    /// Called when a node is renamed.
    public var onRename: ((Node, String) -> Void)?

    /// Returns a context menu for a node, or nil for no menu.
    public var contextMenu: ((Node) -> NSMenu?)?

    /// Returns whether a dragged node can be dropped onto a target.
    /// Parameters: dragged node, target parent (nil = root).
    public var canAcceptDrop: ((Node, Node?) -> Bool)?

    public init(
        rootNodes: [Node],
        childrenOf: @escaping (Node) -> [Node],
        capabilitiesOf: @escaping (Node) -> TreeNodeCapabilities = { _ in .libraryCollection },
        pasteboardType: NSPasteboard.PasteboardType,
        onReorder: (([Node], Node?) -> Void)? = nil,
        onReparent: ((Node, Node?) -> Void)? = nil,
        onExternalDrop: ((NSPasteboard, Node?) -> Bool)? = nil,
        onSelect: ((UUID?) -> Void)? = nil,
        onRename: ((Node, String) -> Void)? = nil,
        contextMenu: ((Node) -> NSMenu?)? = nil,
        canAcceptDrop: ((Node, Node?) -> Bool)? = nil
    ) {
        self.rootNodes = rootNodes
        self.childrenOf = childrenOf
        self.capabilitiesOf = capabilitiesOf
        self.pasteboardType = pasteboardType
        self.onReorder = onReorder
        self.onReparent = onReparent
        self.onExternalDrop = onExternalDrop
        self.onSelect = onSelect
        self.onRename = onRename
        self.contextMenu = contextMenu
        self.canAcceptDrop = canAcceptDrop
    }
}
#endif
