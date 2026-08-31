//
//  SidebarOutlineSelectionReloadTests.swift
//  ImpressSidebar
//
//  Regression coverage for the coordinator's selection-restore path.
//
//  A data reload must not collapse a multi-row selection. Hosts bump
//  `dataVersion` on every store event (imbib does it from `ImbibImpressStore`
//  events), so ANY background mutation — enrichment, inbox refresh, marking a
//  paper read — runs `updateNSView`'s reload branch while the user is still
//  holding a Cmd-click selection. Before the fix, `restoreSelection()` only
//  ever re-selected `selectedNodeID`, silently dropping the rest.
//
//  These tests drive a real NSOutlineView: AppKit invokes
//  `outlineViewSelectionDidChange` synchronously from `selectRowIndexes`, with
//  no window and no run loop, so the genuine selection path is exercised
//  rather than a mock.
//

#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import ImpressSidebar

@MainActor
@Suite("Sidebar selection across data reloads")
struct SidebarOutlineSelectionReloadTests {

    // MARK: - Harness

    /// Wires a `Coordinator` to a real `SidebarNSOutlineView` the same way
    /// `makeNSView` does, and replays `updateNSView`'s reload branch verbatim.
    @MainActor
    final class Harness {
        let outlineView = SidebarNSOutlineView()
        private(set) var coordinator: SidebarOutlineView<TestNode>.Coordinator!

        /// Mirrors the host's single-selection binding.
        var boundSelectedNodeID: UUID?
        /// Every `onMultipleSelectionChanged` payload, in call order.
        var multiSelectionCallbacks: [[UUID]] = []

        init(roots: [TestNode]) {
            var configuration = SidebarOutlineConfiguration<TestNode>(
                rootNodes: roots,
                childrenOf: { $0.children },
                pasteboardType: .init(rawValue: "com.impress.test.sidebar.node")
            )
            configuration.onMultipleSelectionChanged = { [weak self] nodes in
                self?.multiSelectionCallbacks.append(nodes.map(\.id))
            }

            let binding = Binding<UUID?>(
                get: { [weak self] in self?.boundSelectedNodeID },
                set: { [weak self] in self?.boundSelectedNodeID = $0 }
            )

            coordinator = SidebarOutlineView<TestNode>.Coordinator(
                configuration: configuration,
                expansionState: TreeExpansionState(),
                selectedNodeID: nil,
                selectionBinding: binding,
                editingNodeIDBinding: .constant(nil)
            )

            outlineView.allowsMultipleSelection = true
            let column = NSTableColumn(identifier: .init("main"))
            outlineView.addTableColumn(column)
            outlineView.outlineTableColumn = column
            outlineView.dataSource = coordinator
            outlineView.delegate = coordinator
            coordinator.outlineView = outlineView

            coordinator.rebuildData(rootNodes: roots, childrenOf: configuration.childrenOf)
            outlineView.reloadData()
        }

        /// Row index of a node, or nil when it is not currently in the tree.
        func row(of node: TestNode) -> Int? {
            guard let wrapper = coordinator.wrapperCache[node.id] else { return nil }
            let row = outlineView.row(forItem: wrapper)
            return row >= 0 ? row : nil
        }

        var selectedRows: [Int] { Array(outlineView.selectedRowIndexes) }

        var selectedIDs: [UUID] {
            outlineView.selectedRowIndexes.compactMap {
                (outlineView.item(atRow: $0) as? SidebarOutlineNodeWrapper)?.id
            }
        }

        /// Select rows the way a user's click / Cmd-click does. AppKit fires
        /// `outlineViewSelectionDidChange` synchronously, so the coordinator
        /// records the set through its real delegate callback.
        func userSelects(_ nodes: [TestNode]) {
            let rows = nodes.compactMap { row(of: $0) }
            outlineView.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
        }

        /// Replays `updateNSView`'s `dataVersion`-changed branch.
        func simulateDataReload(roots: [TestNode]? = nil) {
            let newRoots = roots ?? coordinator.configuration.rootNodes
            if roots != nil { coordinator.configuration.rootNodes = newRoots }
            coordinator.rebuildData(
                rootNodes: newRoots,
                childrenOf: coordinator.configuration.childrenOf
            )
            coordinator.isUpdatingProgrammatically = true
            outlineView.reloadData()
            coordinator.restoreExpansionState()
            coordinator.restoreSelection(preservingMultiple: true)
            coordinator.isUpdatingProgrammatically = false
        }

        /// Let the coordinator's deferred host notifications run. They hop one
        /// main-actor turn to stay out of the SwiftUI update pass.
        func drainDeferredNotifications() async {
            for _ in 0..<10 { await Task.yield() }
        }

        /// Replays `updateNSView`'s binding-sync branch (single selection).
        func simulateBindingSelectionSync(to id: UUID?) {
            coordinator.selectedNodeID = id
            coordinator.isUpdatingProgrammatically = true
            coordinator.restoreSelection()
            coordinator.isUpdatingProgrammatically = false
        }
    }

    private static func node(_ name: String) -> TestNode {
        TestNode(id: UUID(), displayName: name, treeDepth: 0)
    }

    // MARK: - The regression

    @Test("A data reload preserves a multi-row selection")
    func reloadPreservesMultiSelection() {
        let (a, b, c, d) = (Self.node("A"), Self.node("B"), Self.node("C"), Self.node("D"))
        let harness = Harness(roots: [a, b, c, d])

        harness.userSelects([a, c])
        #expect(harness.selectedRows == [0, 2])
        #expect(harness.coordinator.selectedNodeIDs == [a.id, c.id])

        // A background store mutation bumps dataVersion mid-gesture.
        harness.simulateDataReload()

        #expect(harness.selectedRows == [0, 2])
        #expect(harness.selectedIDs == [a.id, c.id])
    }

    @Test("Repeated reloads keep the selection (background services fire often)")
    func repeatedReloadsPreserveSelection() {
        let (a, b, c, d) = (Self.node("A"), Self.node("B"), Self.node("C"), Self.node("D"))
        let harness = Harness(roots: [a, b, c, d])

        harness.userSelects([b, c, d])
        #expect(harness.selectedRows == [1, 2, 3])

        for _ in 0..<10 { harness.simulateDataReload() }

        #expect(harness.selectedIDs == [b.id, c.id, d.id])
    }

    @Test("Selection follows node identity when the tree is restructured")
    func reloadRemapsRowsByIdentity() {
        let (a, b, c) = (Self.node("A"), Self.node("B"), Self.node("C"))
        let harness = Harness(roots: [a, b, c])

        harness.userSelects([a, c])
        #expect(harness.selectedRows == [0, 2])

        // A new library arrives above the selection: the same nodes now live at
        // different row indices, so trusting raw indices would select the wrong
        // rows. Restoring re-resolves each ID through `wrapperCache`.
        let fresh = Self.node("Fresh")
        harness.simulateDataReload(roots: [fresh, a, b, c])

        #expect(harness.selectedRows == [1, 3])
        #expect(harness.selectedIDs == [a.id, c.id])
    }

    // MARK: - Shrinking selections

    @Test("A vanished node drops out and the host is re-notified")
    func reloadHandlesDeletedSelectedNode() async {
        let (a, b, c) = (Self.node("A"), Self.node("B"), Self.node("C"))
        let harness = Harness(roots: [a, b, c])

        // `c` is selected last, so it is the primary — the case a delete
        // usually hits.
        harness.userSelects([a, c])
        harness.multiSelectionCallbacks.removeAll()

        // `c` is deleted while both rows are selected.
        harness.simulateDataReload(roots: [a, b])

        // Only live rows stay selected — and `a` must survive even though the
        // primary is the one that vanished.
        #expect(harness.selectedIDs == [a.id])
        #expect(harness.coordinator.selectedNodeIDs == [a.id])

        // The host mirrors this set into `selectedSourcesForCombinedView`; if it
        // is not re-notified it keeps querying the deleted node. The
        // notification is deferred out of the SwiftUI update pass.
        await harness.drainDeferredNotifications()
        #expect(harness.multiSelectionCallbacks.last == [a.id])
        #expect(harness.boundSelectedNodeID == a.id)
    }

    @Test("Every selected node vanishing clears the selection")
    func reloadHandlesAllSelectedNodesDeleted() async {
        let (a, b, c) = (Self.node("A"), Self.node("B"), Self.node("C"))
        let harness = Harness(roots: [a, b, c])

        harness.userSelects([b, c])
        harness.multiSelectionCallbacks.removeAll()

        harness.simulateDataReload(roots: [a])

        #expect(harness.selectedIDs.isEmpty)
        #expect(harness.coordinator.selectedNodeIDs.isEmpty)

        await harness.drainDeferredNotifications()
        #expect(harness.multiSelectionCallbacks.last == [])
        #expect(harness.boundSelectedNodeID == nil)
    }

    // MARK: - The gate (unchanged single-selection behavior)

    @Test("An explicit binding sync still collapses to one row")
    func bindingSyncCollapsesToSingleRow() {
        let (a, b, c) = (Self.node("A"), Self.node("B"), Self.node("C"))
        let harness = Harness(roots: [a, b, c])

        harness.userSelects([a, c])
        #expect(harness.selectedRows.count == 2)

        // The host moved the single-selection binding: the old single-row
        // behavior must apply verbatim, otherwise navigation would be ignored.
        harness.simulateBindingSelectionSync(to: b.id)

        #expect(harness.selectedIDs == [b.id])
        #expect(harness.coordinator.selectedNodeIDs == [b.id])
    }

    @Test("A reload after a binding sync does not resurrect the old set")
    func reloadDoesNotResurrectStaleMultiSelection() {
        let (a, b, c) = (Self.node("A"), Self.node("B"), Self.node("C"))
        let harness = Harness(roots: [a, b, c])

        harness.userSelects([a, c])
        harness.simulateBindingSelectionSync(to: b.id)
        harness.simulateDataReload()

        #expect(harness.selectedIDs == [b.id])
    }

    @Test("A single-row selection reloads unchanged")
    func reloadPreservesSingleSelection() {
        let (a, b, c) = (Self.node("A"), Self.node("B"), Self.node("C"))
        let harness = Harness(roots: [a, b, c])

        harness.userSelects([b])
        #expect(harness.coordinator.selectedNodeID == b.id)

        harness.simulateDataReload()

        #expect(harness.selectedIDs == [b.id])
    }

    @Test("Consumers without a multi-selection callback still restore rows")
    func reloadPreservesSelectionWithoutMultiCallback() {
        // imprint uses the same shared view without `onMultipleSelectionChanged`.
        let (a, b, c) = (Self.node("A"), Self.node("B"), Self.node("C"))
        let harness = Harness(roots: [a, b, c])
        harness.coordinator.configuration.onMultipleSelectionChanged = nil

        harness.userSelects([a, c])
        harness.simulateDataReload()

        #expect(harness.selectedIDs == [a.id, c.id])
        #expect(harness.multiSelectionCallbacks.isEmpty)
    }
}
#endif
