#if os(macOS)
// Chassis file — macOS-only in GUI-meld Phase 1 (iOS keeps IOSContentView).
//
//  TabContentView.swift
//  imbib
//
//  Root view using NavigationSplitView with an NSOutlineView-based sidebar.
//  All sidebar state is managed by ImbibSidebarViewModel.
//

import SwiftUI
import ImpressFTUI
import ImpressKit
import ImpressSidebar
import ImpressStoreKit
import OSLog

/// Root view using NavigationSplitView with an NSOutlineView sidebar.
/// Each sidebar row maps to an `ImbibTab`, and the content area shows
/// the corresponding publication list + detail.
public struct TabContentView: View {

    public init() {}


    // MARK: - State

    /// The sidebar's view model. Its column and its lifecycle — configure,
    /// store events, navigation notifications, the confirmations its menus
    /// raise — are `ImbibSidebarColumn` + `ImbibSidebarLifecycle`, shared with
    /// the layout tree's `outline` pane so the two hosts are one sidebar.
    @State private var viewModel = ImbibSidebarViewModel()

    /// NavigationSplitView column state, driven by the declarative layout
    /// (PaneLayoutStore.current.sidebarVisible ↔ ⌃⌘S / saved layouts /
    /// HTTP /api/layout). Two-way: the split view's own toolbar toggle and
    /// drag-collapse mirror back into the store.
    @State private var columnVisibility: NavigationSplitViewVisibility =
        PaneLayoutStore.shared.current.sidebarVisible ? .all : .detailOnly

    /// Whether the selected route renders the Manuscripts section (whose
    /// editor pane toggles then join the top-left toolbar cluster).
    private var manuscriptsRouteActive: Bool {
        if case .record(let route) = viewModel.selectedTab, route.kind == .manuscript {
            return true
        }
        return false
    }

    // MARK: - Body

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            #if os(macOS)
            ImbibSidebarColumn(viewModel: viewModel)
            #else
            Text("iOS sidebar not yet migrated")
                .navigationTitle("imbib")
            #endif
        } detail: {
            // SectionContentView reads viewModel.selectedTab directly via
            // @Observable, so it re-evaluates when the tab changes — independent
            // of whether NavigationSplitView re-evaluates this closure.
            SectionContentView(viewModel: viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        #if os(macOS)
        // Pane show/hide cluster. Declared on the NavigationSplitView root —
        // toolbar items declared inside the detail column's route views never
        // reach the window toolbar — and placed `.navigation` so the whole
        // cluster sits at the TOP LEFT beside the system's sidebar toggle:
        // sidebar / list / editor-pane toggles read as one group.
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                let visible = PaneLayoutStore.shared.current.listPaneVisible
                Button {
                    PaneLayoutStore.shared.current.listPaneVisible.toggle()
                } label: {
                    Image(systemName: visible
                        ? "list.bullet.rectangle.fill" : "list.bullet.rectangle")
                }
                .help(visible ? "Hide the list (⌥⌘0)" : "Show the list (⌥⌘0)")
                // The manuscript editor's own pane toggles (outline/comments/
                // inspector/preview), only while a manuscripts route is up —
                // they act on the editor via shared @AppStorage keys.
                if manuscriptsRouteActive {
                    ManuscriptEditorPaneToggles()
                }
            }
        }
        #endif
        .onChange(of: PaneLayoutStore.shared.current.sidebarVisible) { _, visible in
            let target: NavigationSplitViewVisibility = visible ? .all : .detailOnly
            if columnVisibility != target { columnVisibility = target }
        }
        .onChange(of: columnVisibility) { _, visibility in
            let visible = visibility != .detailOnly
            if PaneLayoutStore.shared.current.sidebarVisible != visible {
                PaneLayoutStore.shared.current.sidebarVisible = visible
            }
        }
        .modifier(ImbibSidebarLifecycle(viewModel: viewModel))
    }

}

#endif
