#if os(macOS)
//
//  MacSidebarRenameTests.swift
//  PublicationManagerCoreTests
//
//  Sidebar inline rename — the funnel, plus one SwiftUI fact worth pinning so
//  the next person debugging "rename does nothing" does not spend an hour on
//  the theory I did.
//
//  The chain: the context menu's Rename item (and the four create-then-name-it
//  flows) call `beginRename(nodeID:)`, which sets `editingNodeID`;
//  `TabContentView` hands that to `SidebarOutlineView`, whose `updateNSView`
//  calls `beginEditingNode` and makes the row's NSTextField first responder.
//
//  THE TEMPTING WRONG THEORY: `TabContentView` passes the request as
//  `editingNodeID: $viewModel.editingNodeID` — a Binding PROJECTION — and
//  under `@Observable` a projection looks like it should register no
//  dependency, which would mean setting the property re-renders nothing and
//  the editor never opens. That is FALSE, and
//  `testBindingProjectionDoesRegisterAnObservationDependency` is here to keep
//  it false: SwiftUI's `Binding` caches an initial value at construction, so
//  projecting one DOES read the property and DOES register the dependency.
//  If that ever changes, this test fails and the rename chain needs a real
//  wake-up mechanism.
//
//  Where the chain CAN still fail silently is inside `beginEditingNode`
//  (no cached wrapper, a collapsed parent, a cell the reload has not
//  materialised, a first responder someone else holds). Those outcomes are
//  logged — subsystem `com.impress.sidebar`, category `rename` — because the
//  user only ever sees "my typing went into the tag filter".
//

import Observation
import SwiftUI
import XCTest

@testable import PublicationManagerCore

@MainActor
final class MacSidebarRenameTests: XCTestCase {

    private func viewModel() -> ImbibSidebarViewModel {
        ImbibSidebarViewModel(
            store: MockPublicationStore(),
            persistence: .inMemory(),
            shellConfiguration: .imprint,
            sidebarComposition: nil)
    }

    /// Every rename request goes through one funnel, so there is one place
    /// that logs it and one place to change when the mechanism moves.
    func testBeginRenameRecordsTheRequest() {
        let vm = viewModel()
        let node = UUID()
        XCTAssertNil(vm.editingNodeID)
        vm.beginRename(nodeID: node)
        XCTAssertEqual(vm.editingNodeID, node)
    }

    /// The SwiftUI semantic the whole chain depends on: projecting a Binding
    /// to an `@Observable` property registers an observation dependency (the
    /// Binding reads the value once when it is constructed). If this ever
    /// stops being true, `TabContentView` stops re-rendering on a rename
    /// request and the inline editor silently never opens.
    func testBindingProjectionDoesRegisterAnObservationDependency() {
        let vm = viewModel()
        var woke = false
        withObservationTracking {
            // Exactly what `TabContentView` does with `$viewModel.editingNodeID`.
            _ = Binding(get: { vm.editingNodeID }, set: { vm.editingNodeID = $0 })
        } onChange: {
            woke = true
        }
        vm.beginRename(nodeID: UUID())
        XCTAssertTrue(
            woke,
            "a Binding projection no longer observes its property — the sidebar will not "
                + "re-render on a rename request, so updateNSView never runs and the inline "
                + "editor never opens. beginRename must then wake the view explicitly.")
    }

    /// The bug this file exists for: context-menu items must target the
    /// sidebar that BUILT them.
    ///
    /// They used to target one global (`ContextMenuActions.shared`) whose weak
    /// view model every appearing `TabContentView` overwrote, so with two
    /// chassis windows — or after SwiftUI recreated a sidebar's view model —
    /// every menu in every other window acted on the wrong instance, or on a
    /// deallocated one. Since each action is an optional chain, the items then
    /// did NOTHING, silently: Rename opened no editor and the keystrokes went
    /// to whichever text field still had focus. Only an app restart fixed it.
    func testEachSidebarOwnsItsOwnContextMenuTarget() {
        let first = viewModel()
        let second = viewModel()

        XCTAssertTrue(
            first.contextMenuActions !== second.contextMenuActions,
            "two sidebars shared one context-menu target — the last one to appear would win")
        XCTAssertTrue(first.contextMenuActions.viewModel === first)
        XCTAssertTrue(second.contextMenuActions.viewModel === second)
    }

    /// …and the menus a sidebar actually builds carry that target, so an item
    /// can never dispatch into another window's sidebar.
    func testBuiltMenuItemsTargetTheSidebarThatBuiltThem() {
        let first = viewModel()
        let second = viewModel()

        var checkedAnItem = false
        for node in first.outlineConfiguration.rootNodes {
            guard let menu = first.outlineConfiguration.contextMenu?(node) else { continue }
            for item in menu.items where item.target != nil {
                checkedAnItem = true
                XCTAssertTrue(
                    item.target === first.contextMenuActions,
                    "menu item '\(item.title)' does not target its own sidebar")
                XCTAssertFalse(
                    item.target === second.contextMenuActions,
                    "menu item '\(item.title)' dispatches into ANOTHER sidebar")
            }
        }
        XCTAssertTrue(checkedAnItem, "no context menu produced a targeted item to check")
    }
}
#endif
