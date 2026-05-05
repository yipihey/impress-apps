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

    /// Additional pasteboard types to accept as external drops (e.g., publication IDs).
    /// These are registered with NSOutlineView and routed to `onExternalDrop`.
    public var additionalDragTypes: [NSPasteboard.PasteboardType]

    /// Called when nodes are reordered among siblings.
    /// Parameters: reordered sibling array, optional parent node (nil = root).
    public var onReorder: (([Node], Node?) -> Void)?

    /// Called when a node is reparented.
    /// Parameters: moved node, new parent (nil = root).
    public var onReparent: ((Node, Node?) -> Void)?

    /// Called when external files are dropped onto a node.
    /// Parameters: pasteboard, target node (nil = root). Returns whether drop was handled.
    public var onExternalDrop: ((NSPasteboard, Node?) -> Bool)?

    /// Called when a node is renamed.
    public var onRename: ((Node, String) -> Void)?

    /// Returns a context menu for a node, or nil for no menu.
    public var contextMenu: ((Node) -> NSMenu?)?

    /// Returns a context menu for multiple selected nodes, or nil for no menu.
    /// Called when the user right-clicks with multiple items selected.
    public var contextMenuForMultiple: (([Node]) -> NSMenu?)?

    /// Called when the multi-selection changes (NSOutlineView's `selectedRowIndexes`).
    /// Fires alongside the existing single-selection binding write — pass an empty
    /// array when there is no selection. Default nil makes this opt-in; consumers
    /// that don't supply it see no change in behavior.
    public var onMultipleSelectionChanged: (([Node]) -> Void)?

    /// Called when the user presses Delete or Backspace with one or more rows
    /// selected. Receives the currently-selected nodes. Default nil leaves
    /// keypresses to the standard NSOutlineView responder chain, so consumers
    /// that don't want a delete shortcut see no change in behavior.
    public var onDeleteKeyPressed: (([Node]) -> Void)?

    /// Returns whether a dragged node can be dropped onto a target.
    /// Parameters: dragged node, target parent (nil = root).
    public var canAcceptDrop: ((Node, Node?) -> Bool)?

    /// Returns whether a node should be rendered as a group item (section header).
    /// Group items are displayed as bold uppercase text without icon, and are not selectable
    /// (unless `shouldSelectItem` returns true for them).
    public var isGroupItem: ((Node) -> Bool)?

    /// Optional override for selectability. When nil, group items are not selectable.
    /// When provided, this callback determines selectability (even for group items).
    public var shouldSelectItem: ((Node) -> Bool)?

    /// Optional callback to build a menu for section header trailing buttons.
    /// Return nil to hide the button for that section.
    public var sectionMenu: ((Node) -> NSMenu?)?

    public init(
        rootNodes: [Node],
        childrenOf: @escaping (Node) -> [Node],
        capabilitiesOf: @escaping (Node) -> TreeNodeCapabilities = { _ in .libraryCollection },
        pasteboardType: NSPasteboard.PasteboardType,
        additionalDragTypes: [NSPasteboard.PasteboardType] = [],
        onReorder: (([Node], Node?) -> Void)? = nil,
        onReparent: ((Node, Node?) -> Void)? = nil,
        onExternalDrop: ((NSPasteboard, Node?) -> Bool)? = nil,
        onRename: ((Node, String) -> Void)? = nil,
        contextMenu: ((Node) -> NSMenu?)? = nil,
        contextMenuForMultiple: (([Node]) -> NSMenu?)? = nil,
        canAcceptDrop: ((Node, Node?) -> Bool)? = nil,
        isGroupItem: ((Node) -> Bool)? = nil,
        shouldSelectItem: ((Node) -> Bool)? = nil,
        sectionMenu: ((Node) -> NSMenu?)? = nil,
        onMultipleSelectionChanged: (([Node]) -> Void)? = nil,
        onDeleteKeyPressed: (([Node]) -> Void)? = nil
    ) {
        self.rootNodes = rootNodes
        self.childrenOf = childrenOf
        self.capabilitiesOf = capabilitiesOf
        self.pasteboardType = pasteboardType
        self.additionalDragTypes = additionalDragTypes
        self.onReorder = onReorder
        self.onReparent = onReparent
        self.onExternalDrop = onExternalDrop
        self.onRename = onRename
        self.contextMenu = contextMenu
        self.contextMenuForMultiple = contextMenuForMultiple
        self.canAcceptDrop = canAcceptDrop
        self.isGroupItem = isGroupItem
        self.shouldSelectItem = shouldSelectItem
        self.sectionMenu = sectionMenu
        self.onMultipleSelectionChanged = onMultipleSelectionChanged
        self.onDeleteKeyPressed = onDeleteKeyPressed
    }
}
#endif
