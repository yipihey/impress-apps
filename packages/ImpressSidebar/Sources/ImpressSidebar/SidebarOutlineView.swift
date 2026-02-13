//
//  SidebarOutlineView.swift
//  ImpressSidebar
//
//  NSViewRepresentable wrapping NSOutlineView for native macOS tree sidebars.
//  Provides native blue insertion lines, proper reorder/reparent hit-testing,
//  and auto-expand on hover — reusable across imbib, imprint, and impart.
//

#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - NSOutlineView Subclass

/// Minimal NSOutlineView subclass for sidebar trees.
final class SidebarNSOutlineView: NSOutlineView {
}

// MARK: - SidebarOutlineView

/// A SwiftUI wrapper around NSOutlineView for hierarchical sidebar trees.
///
/// Provides native macOS drag-drop with blue insertion lines, auto-expand on
/// hover, context menus, and bidirectional expansion/selection sync with SwiftUI.
///
/// **Usage:**
/// ```swift
/// SidebarOutlineView(
///     selectedNodeID: $viewModel.selectedFolderID,
///     expansionState: viewModel.expansionState,
///     configuration: SidebarOutlineConfiguration(
///         rootNodes: viewModel.rootFolders.asFolderAdapters(),
///         childrenOf: { $0.folder.sortedChildren.asFolderAdapters() },
///         pasteboardType: .init(rawValue: UTType.imprintFolderID.identifier),
///         onReorder: { siblings, parent in ... },
///         onReparent: { node, newParent in ... }
///     ),
///     dataVersion: viewModel.dataVersion
/// )
/// ```
public struct SidebarOutlineView<Node: SidebarTreeNode>: NSViewRepresentable {

    // MARK: - Bindings

    /// The currently selected node ID (bidirectional sync).
    @Binding public var selectedNodeID: UUID?

    /// Expansion state (bidirectional sync with TreeExpansionState).
    public var expansionState: TreeExpansionState

    /// Configuration providing data and callbacks.
    public var configuration: SidebarOutlineConfiguration<Node>

    /// Bump this counter to trigger a data reload.
    public var dataVersion: Int

    /// Set to a node ID to begin inline editing. Reset to nil when done.
    @Binding public var editingNodeID: UUID?

    // MARK: - Init

    public init(
        selectedNodeID: Binding<UUID?>,
        expansionState: TreeExpansionState,
        configuration: SidebarOutlineConfiguration<Node>,
        dataVersion: Int,
        editingNodeID: Binding<UUID?> = .constant(nil)
    ) {
        self._selectedNodeID = selectedNodeID
        self.expansionState = expansionState
        self.configuration = configuration
        self.dataVersion = dataVersion
        self._editingNodeID = editingNodeID
    }

    // MARK: - NSViewRepresentable

    public func makeNSView(context: Context) -> NSView {
        // Wrap in a plain NSView container so that NavigationSplitView's sidebar
        // doesn't detect a top-level NSScrollView and nest it inside its own
        // scroll management (which intercepts drag-drop and right-click events).
        let container = NSView()

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let outlineView = SidebarNSOutlineView()
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.rowSizeStyle = .default
        outlineView.floatsGroupRows = false
        outlineView.indentationPerLevel = 0 // We handle indentation via tree lines
        outlineView.autoresizesOutlineColumn = true

        let column = NSTableColumn(identifier: .init("main"))
        column.isEditable = false
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        outlineView.dataSource = context.coordinator
        outlineView.delegate = context.coordinator

        // Register for drag-drop
        let pasteboardType = configuration.pasteboardType
        var dragTypes: [NSPasteboard.PasteboardType] = [pasteboardType, .fileURL, .URL]
        dragTypes.append(contentsOf: configuration.additionalDragTypes)
        outlineView.registerForDraggedTypes(dragTypes)
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: false)

        // Context menu via NSMenu delegate (more reliable than menu(for:) override
        // which can be intercepted by parent views in the responder chain)
        let contextMenu = NSMenu()
        contextMenu.delegate = context.coordinator
        outlineView.menu = contextMenu

        scrollView.documentView = outlineView
        context.coordinator.outlineView = outlineView

        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Initial load
        context.coordinator.rebuildData(
            rootNodes: configuration.rootNodes,
            childrenOf: configuration.childrenOf
        )
        outlineView.reloadData()
        context.coordinator.restoreExpansionState()
        context.coordinator.restoreSelection()

        return container
    }

    public func updateNSView(_ container: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.configuration = configuration
        coordinator.expansionState = expansionState
        coordinator.selectionBinding = $selectedNodeID
        coordinator.editingNodeIDBinding = $editingNodeID

        guard let outlineView = coordinator.outlineView else { return }

        // Only rebuild + reload when data actually changed
        if coordinator.lastDataVersion != dataVersion {
            coordinator.lastDataVersion = dataVersion

            coordinator.rebuildData(
                rootNodes: configuration.rootNodes,
                childrenOf: configuration.childrenOf
            )

            // Update drag types in case pasteboard type changed
            var dragTypes: [NSPasteboard.PasteboardType] = [configuration.pasteboardType, .fileURL, .URL]
            dragTypes.append(contentsOf: configuration.additionalDragTypes)
            outlineView.registerForDraggedTypes(dragTypes)

            coordinator.isUpdatingProgrammatically = true
            outlineView.reloadData()
            coordinator.restoreExpansionState()
            coordinator.restoreSelection()
            coordinator.isUpdatingProgrammatically = false
        }

        // Always sync selection (it can change independently of data)
        if coordinator.selectedNodeID != selectedNodeID {
            coordinator.selectedNodeID = selectedNodeID
            coordinator.isUpdatingProgrammatically = true
            coordinator.restoreSelection()
            coordinator.isUpdatingProgrammatically = false
        }

        // Trigger inline editing when editingNodeID is set
        if let editingID = editingNodeID, coordinator.lastEditingNodeID != editingID {
            coordinator.lastEditingNodeID = editingID
            // Delay to ensure the cell is visible after any reload
            DispatchQueue.main.async {
                coordinator.beginEditingNode(editingID)
            }
        } else if editingNodeID == nil {
            coordinator.lastEditingNodeID = nil
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(
            configuration: configuration,
            expansionState: expansionState,
            selectedNodeID: selectedNodeID,
            selectionBinding: $selectedNodeID,
            editingNodeIDBinding: $editingNodeID
        )
    }

    // MARK: - Coordinator

    @MainActor
    public final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate, NSMenuDelegate {

        // MARK: - State

        var configuration: SidebarOutlineConfiguration<Node>
        var expansionState: TreeExpansionState
        var selectedNodeID: UUID?
        var selectionBinding: Binding<UUID?>
        var editingNodeIDBinding: Binding<UUID?>

        weak var outlineView: SidebarNSOutlineView?

        /// UUID → Node lookup for fast access from NSOutlineView callbacks.
        var nodeLookup: [UUID: Node] = [:]

        /// UUID → NodeWrapper cache for stable NSObject identity.
        var wrapperCache: [UUID: SidebarOutlineNodeWrapper] = [:]

        /// Root-level node IDs in order.
        var rootIDs: [UUID] = []

        /// Parent → ordered child IDs.
        var childIDMap: [UUID: [UUID]] = [:]

        /// Node → flattened tree info for cell rendering.
        var flattenedInfo: [UUID: (isLastChild: Bool, ancestorHasSiblingsBelow: [Bool])] = [:]

        /// Guard flag to prevent infinite selection/expansion update loops.
        var isUpdatingProgrammatically = false

        /// Last data version seen, to avoid unnecessary reloads.
        var lastDataVersion: Int = -1

        /// Last editing node ID, to trigger editing only once.
        var lastEditingNodeID: UUID?

        /// Timer for auto-expand on drag hover.
        var autoExpandTimer: Timer?
        var autoExpandTargetID: UUID?

        // MARK: - Init

        init(
            configuration: SidebarOutlineConfiguration<Node>,
            expansionState: TreeExpansionState,
            selectedNodeID: UUID?,
            selectionBinding: Binding<UUID?>,
            editingNodeIDBinding: Binding<UUID?>
        ) {
            self.configuration = configuration
            self.expansionState = expansionState
            self.selectedNodeID = selectedNodeID
            self.selectionBinding = selectionBinding
            self.editingNodeIDBinding = editingNodeIDBinding
            super.init()
        }

        // MARK: - Data Rebuild

        /// Rebuild the internal lookup tables from the configuration's root nodes.
        func rebuildData(
            rootNodes: [Node],
            childrenOf: (Node) -> [Node]
        ) {
            nodeLookup.removeAll()
            rootIDs.removeAll()
            childIDMap.removeAll()
            flattenedInfo.removeAll()

            // Keep wrappers for IDs that still exist; prune stale ones after rebuild
            var usedIDs = Set<UUID>()

            func registerNode(_ node: Node, isLastChild: Bool, ancestorHasSiblingsBelow: [Bool]) {
                let id = node.id
                usedIDs.insert(id)
                nodeLookup[id] = node
                flattenedInfo[id] = (isLastChild: isLastChild, ancestorHasSiblingsBelow: ancestorHasSiblingsBelow)

                if wrapperCache[id] == nil {
                    wrapperCache[id] = SidebarOutlineNodeWrapper(id: id)
                }

                let children = childrenOf(node)
                if !children.isEmpty {
                    childIDMap[id] = children.map { $0.id }
                    for (index, child) in children.enumerated() {
                        let isLast = index == children.count - 1
                        var childAncestors = ancestorHasSiblingsBelow
                        childAncestors.append(!isLast)
                        registerNode(child, isLastChild: isLast, ancestorHasSiblingsBelow: childAncestors)
                    }
                }
            }

            for (index, root) in rootNodes.enumerated() {
                rootIDs.append(root.id)
                let isLast = index == rootNodes.count - 1
                registerNode(root, isLastChild: isLast, ancestorHasSiblingsBelow: [])
            }

            // Prune stale wrappers
            let staleIDs = Set(wrapperCache.keys).subtracting(usedIDs)
            for id in staleIDs {
                wrapperCache.removeValue(forKey: id)
            }
        }

        // MARK: - Wrapper Helpers

        func wrapper(for id: UUID) -> SidebarOutlineNodeWrapper? {
            wrapperCache[id]
        }

        func node(for item: Any?) -> Node? {
            guard let wrapper = item as? SidebarOutlineNodeWrapper else { return nil }
            return nodeLookup[wrapper.id]
        }

        func nodeID(for item: Any?) -> UUID? {
            (item as? SidebarOutlineNodeWrapper)?.id
        }

        // MARK: - Expansion State Sync

        func restoreExpansionState() {
            guard let outlineView = outlineView else { return }
            for id in expansionState.expandedIDs {
                if let wrapper = wrapperCache[id] {
                    outlineView.expandItem(wrapper)
                }
            }
            // Collapse items expanded in outline but not in state
            for (id, wrapper) in wrapperCache {
                if outlineView.isItemExpanded(wrapper) && !expansionState.isExpanded(id) {
                    outlineView.collapseItem(wrapper)
                }
            }
        }

        func restoreSelection() {
            guard let outlineView = outlineView else { return }
            if let selectedID = selectedNodeID, let wrapper = wrapperCache[selectedID] {
                let row = outlineView.row(forItem: wrapper)
                if row >= 0 {
                    outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    return
                }
            }
            outlineView.deselectAll(nil)
        }

        // MARK: - NSOutlineViewDataSource

        public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            if item == nil {
                return rootIDs.count
            }
            guard let id = nodeID(for: item) else { return 0 }
            return childIDMap[id]?.count ?? 0
        }

        public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            if item == nil {
                let id = rootIDs[index]
                guard let wrapper = wrapperCache[id] else {
                    fatalError("SidebarOutlineView: missing wrapper for root node \(id)")
                }
                return wrapper
            }
            guard let parentID = nodeID(for: item),
                  let childIDs = childIDMap[parentID] else {
                fatalError("SidebarOutlineView: child requested for unknown parent")
            }
            let childID = childIDs[index]
            guard let wrapper = wrapperCache[childID] else {
                fatalError("SidebarOutlineView: missing wrapper for child node \(childID)")
            }
            return wrapper
        }

        public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let id = nodeID(for: item) else { return false }
            return (childIDMap[id]?.isEmpty == false)
        }

        // MARK: - NSOutlineViewDelegate

        public func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
            // Always return false so NSOutlineView shows left-side disclosure
            // triangles for all expandable items (consistent chevron placement).
            // We handle section header styling ourselves in viewFor.
            return false
        }

        public func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            guard let node = node(for: item) else { return true }
            // Custom selectability override takes precedence
            if let shouldSelect = configuration.shouldSelectItem {
                return shouldSelect(node)
            }
            if configuration.isGroupItem?(node) == true { return false }
            return true
        }

        public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = node(for: item),
                  let id = nodeID(for: item),
                  let info = flattenedInfo[id] else { return nil }

            let isGroup = configuration.isGroupItem?(node) ?? false

            if isGroup {
                let cellID = NSUserInterfaceItemIdentifier("SidebarOutlineGroupCell")
                let cell: SidebarOutlineCellView
                if let reused = outlineView.makeView(withIdentifier: cellID, owner: nil) as? SidebarOutlineCellView {
                    cell = reused
                } else {
                    cell = SidebarOutlineCellView(frame: .zero)
                    cell.identifier = cellID
                }
                let sectionMenu = configuration.sectionMenu?(node)
                cell.configureAsGroup(displayName: node.displayName, menu: sectionMenu)
                return cell
            }

            let cellID = NSUserInterfaceItemIdentifier("SidebarOutlineCell")
            let cell: SidebarOutlineCellView
            if let reused = outlineView.makeView(withIdentifier: cellID, owner: nil) as? SidebarOutlineCellView {
                cell = reused
            } else {
                cell = SidebarOutlineCellView(frame: .zero)
                cell.identifier = cellID
            }

            // Convert SwiftUI Color to NSColor for icon
            let iconNSColor: NSColor?
            if let color = node.iconColor {
                iconNSColor = NSColor(color)
            } else {
                iconNSColor = nil
            }

            cell.configure(
                displayName: node.displayName,
                iconName: node.iconName,
                iconColor: iconNSColor,
                displayCount: node.displayCount,
                starCount: node.starCount,
                treeDepth: node.treeDepth,
                isLastChild: info.isLastChild,
                ancestorHasSiblingsBelow: info.ancestorHasSiblingsBelow,
                isExpandable: childIDMap[id]?.isEmpty == false
            )

            return cell
        }

        public func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isUpdatingProgrammatically else { return }
            guard let outlineView = outlineView else { return }
            let row = outlineView.selectedRow
            if row >= 0, let wrapper = outlineView.item(atRow: row) as? SidebarOutlineNodeWrapper {
                selectedNodeID = wrapper.id
                selectionBinding.wrappedValue = wrapper.id
            } else {
                selectedNodeID = nil
                selectionBinding.wrappedValue = nil
            }
        }

        public func outlineViewItemDidExpand(_ notification: Notification) {
            guard !isUpdatingProgrammatically else { return }
            if let wrapper = notification.userInfo?["NSObject"] as? SidebarOutlineNodeWrapper {
                expansionState.expand(wrapper.id)
            }
        }

        public func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !isUpdatingProgrammatically else { return }
            if let wrapper = notification.userInfo?["NSObject"] as? SidebarOutlineNodeWrapper {
                expansionState.collapse(wrapper.id)
            }
        }

        // MARK: - Drag Source

        public func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let node = node(for: item) else { return nil }
            let capabilities = configuration.capabilitiesOf(node)
            guard capabilities.contains(.draggable) else { return nil }

            let pbItem = NSPasteboardItem()
            let data = node.id.uuidString.data(using: .utf8) ?? Data()
            pbItem.setData(data, forType: configuration.pasteboardType)
            return pbItem
        }

        // MARK: - Drop Validation

        public func outlineView(
            _ outlineView: NSOutlineView,
            validateDrop info: NSDraggingInfo,
            proposedItem item: Any?,
            proposedChildIndex index: Int
        ) -> NSDragOperation {
            let pasteboard = info.draggingPasteboard

            // External drops (files, URLs, or additional registered types like publication IDs)
            if configuration.onExternalDrop != nil {
                let hasExternalType = pasteboard.types?.contains(.fileURL) == true
                    || pasteboard.types?.contains(.URL) == true
                    || configuration.additionalDragTypes.contains(where: { pasteboard.types?.contains($0) == true })
                if hasExternalType {
                    return .copy
                }
            }

            // Internal node drag
            guard pasteboard.types?.contains(configuration.pasteboardType) == true else {
                return []
            }

            // Read dragged node ID
            guard let data = pasteboard.data(forType: configuration.pasteboardType),
                  let uuidString = String(data: data, encoding: .utf8),
                  let draggedID = UUID(uuidString: uuidString),
                  let draggedNode = nodeLookup[draggedID] else {
                return []
            }

            if index == NSOutlineViewDropOnItemIndex {
                // Drop ON an item = reparent
                let targetNode = node(for: item)
                let targetID = nodeID(for: item)

                // Can't drop on self
                if targetID == draggedID { cancelAutoExpand(); return [] }

                // Can't drop onto a descendant
                if let targetNode = targetNode {
                    if targetNode.ancestorIDs.contains(draggedID) { cancelAutoExpand(); return [] }
                }

                // Check custom canAcceptDrop
                if let canAccept = configuration.canAcceptDrop {
                    if !canAccept(draggedNode, targetNode) { cancelAutoExpand(); return [] }
                }

                // Auto-expand collapsed expandable items on hover
                if let targetID = targetID,
                   childIDMap[targetID]?.isEmpty == false {
                    scheduleAutoExpand(for: targetID)
                }

                return .move
            } else {
                // Drop at a specific index = reorder (native insertion line)
                cancelAutoExpand()

                let targetNode = node(for: item)

                // Check custom canAcceptDrop for the parent
                if let canAccept = configuration.canAcceptDrop {
                    if !canAccept(draggedNode, targetNode) { return [] }
                }

                return .move
            }
        }

        // MARK: - Drop Acceptance

        public func outlineView(
            _ outlineView: NSOutlineView,
            acceptDrop info: NSDraggingInfo,
            item: Any?,
            childIndex index: Int
        ) -> Bool {
            let pasteboard = info.draggingPasteboard

            // Handle external drops (files, URLs, or additional registered types)
            if let onExternalDrop = configuration.onExternalDrop {
                let hasExternalType = pasteboard.types?.contains(.fileURL) == true
                    || pasteboard.types?.contains(.URL) == true
                    || configuration.additionalDragTypes.contains(where: { pasteboard.types?.contains($0) == true })
                if hasExternalType {
                    let targetNode = node(for: item)
                    return onExternalDrop(pasteboard, targetNode)
                }
            }

            // Handle internal node drag
            guard let data = pasteboard.data(forType: configuration.pasteboardType),
                  let uuidString = String(data: data, encoding: .utf8),
                  let draggedID = UUID(uuidString: uuidString),
                  let draggedNode = nodeLookup[draggedID] else {
                return false
            }

            if index == NSOutlineViewDropOnItemIndex {
                // Reparent: drop ON item
                let targetNode = node(for: item)
                configuration.onReparent?(draggedNode, targetNode)
                return true
            } else {
                // Reorder: drop at specific index
                let parentNode = node(for: item)
                let parentID = nodeID(for: item)

                // Get current children of the target parent
                let siblingIDs: [UUID]
                if let parentID = parentID {
                    siblingIDs = childIDMap[parentID] ?? []
                } else {
                    siblingIDs = rootIDs
                }

                // Build reordered sibling array
                var siblings = siblingIDs.compactMap { nodeLookup[$0] }

                // Remove dragged node from siblings if present
                guard let sourceIdx = siblings.firstIndex(where: { $0.id == draggedID }) else {
                    // Dragged from a different parent → reparent + insert at position
                    configuration.onReparent?(draggedNode, parentNode)
                    return true
                }

                siblings.remove(at: sourceIdx)
                let insertIdx = index > sourceIdx ? index - 1 : index
                let clampedIdx = max(0, min(insertIdx, siblings.count))
                siblings.insert(draggedNode, at: clampedIdx)

                configuration.onReorder?(siblings, parentNode)
                return true
            }
        }

        // MARK: - Auto-Expand on Hover

        public func outlineView(
            _ outlineView: NSOutlineView,
            draggingSession session: NSDraggingSession,
            willBeginAt screenPoint: NSPoint,
            forItems draggedItems: [Any]
        ) {
            // Session started — no action needed
        }

        public func outlineView(
            _ outlineView: NSOutlineView,
            draggingSession session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            cancelAutoExpand()
        }

        /// Called during drop validation — we use it for auto-expand timing.
        func scheduleAutoExpand(for id: UUID) {
            guard autoExpandTargetID != id else { return }
            cancelAutoExpand()
            autoExpandTargetID = id
            autoExpandTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self = self,
                          let outlineView = self.outlineView,
                          let wrapper = self.wrapperCache[id],
                          !outlineView.isItemExpanded(wrapper) else { return }
                    outlineView.expandItem(wrapper)
                    self.expansionState.expand(id)
                }
            }
        }

        func cancelAutoExpand() {
            autoExpandTimer?.invalidate()
            autoExpandTimer = nil
            autoExpandTargetID = nil
        }

        // MARK: - Context Menu (NSMenuDelegate)

        public func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let outlineView = outlineView else { return }
            let row = outlineView.clickedRow
            guard row >= 0,
                  let wrapper = outlineView.item(atRow: row) as? SidebarOutlineNodeWrapper,
                  let node = nodeLookup[wrapper.id] else { return }

            // Select the row on right-click (unless it's a group item)
            let isGroup = configuration.isGroupItem?(node) ?? false
            if !isGroup {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }

            // Populate from the configuration's context menu builder
            guard let sourceMenu = configuration.contextMenu?(node) else { return }
            for item in sourceMenu.items {
                sourceMenu.removeItem(item)
                menu.addItem(item)
            }
        }

        // MARK: - Inline Editing

        /// Begin inline editing for the node with the given ID.
        public func beginEditingNode(_ id: UUID) {
            guard let outlineView = outlineView,
                  let wrapper = wrapperCache[id] else { return }
            let row = outlineView.row(forItem: wrapper)
            guard row >= 0,
                  let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarOutlineCellView else { return }
            cell.beginEditing(delegate: self)
        }

        // MARK: - NSTextFieldDelegate (Inline Rename)

        public func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
            guard let textField = control as? NSTextField else { return true }
            let newName = textField.stringValue

            // Find which node this belongs to
            guard let outlineView = outlineView else { return true }
            for row in 0..<outlineView.numberOfRows {
                if let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarOutlineCellView,
                   cell.textField === textField,
                   let wrapper = outlineView.item(atRow: row) as? SidebarOutlineNodeWrapper,
                   let node = nodeLookup[wrapper.id] {
                    cell.endEditing()
                    editingNodeIDBinding.wrappedValue = nil
                    lastEditingNodeID = nil
                    configuration.onRename?(node, newName)
                    break
                }
            }
            return true
        }
    }
}
#endif
