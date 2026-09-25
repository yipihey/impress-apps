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

    /// The host window's pane model: imbib's own window injects its layout
    /// model (⌃⌘S / ⌥⌘0 / ⌘0, saved layouts, `/api/layout`). Inside the layout
    /// tree nobody does, and this view keeps its own (`ownPanes`).
    @Environment(\.hostWindowPanes) private var hostPanes

    /// Panes this view owns when no host gave it any.
    @State private var ownPanes = OwnWindowPanes()

    private var panes: any HostWindowPanes { hostPanes ?? ownPanes }

    /// NavigationSplitView column state, driven by `panes.sidebarVisible`.
    /// Two-way: the split view's own toolbar toggle and drag-collapse mirror
    /// back into it. Starts shown; `onAppear` takes the host's value.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

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
                .environment(\.hostWindowPanes, panes)
        }
        #if os(macOS)
        // Pane show/hide cluster. Declared on the NavigationSplitView root —
        // toolbar items declared inside the detail column's route views never
        // reach the window toolbar — and placed `.navigation` so the whole
        // cluster sits at the TOP LEFT beside the system's sidebar toggle:
        // sidebar / list / editor-pane toggles read as one group.
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                let panes = panes
                let visible = panes.listPaneVisible
                Button {
                    panes.listPaneVisible.toggle()
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
        .onAppear {
            let target: NavigationSplitViewVisibility = panes.sidebarVisible ? .all : .detailOnly
            if columnVisibility != target { columnVisibility = target }
        }
        .onChange(of: panes.sidebarVisible) { _, visible in
            let target: NavigationSplitViewVisibility = visible ? .all : .detailOnly
            if columnVisibility != target { columnVisibility = target }
        }
        .onChange(of: columnVisibility) { _, visibility in
            let visible = visibility != .detailOnly
            if panes.sidebarVisible != visible {
                panes.sidebarVisible = visible
            }
        }
        .modifier(ImbibSidebarLifecycle(viewModel: viewModel))
        // Go ▸ Back / Forward read this window's history (enabled state) and
        // name it in their post.
        .focusedSceneValue(\.imbibNavigationHistory, viewModel.navigationHistory)
    }

}

#endif
