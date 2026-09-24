#if os(macOS)
// Chassis file — macOS-only in GUI-meld Phase 1 (iOS keeps IOSContentView).
//
//  FigureSectionView.swift
//  PublicationManagerCore
//
//  Composes the Figures section as the STANDARD chassis list|detail split
//  (Stage 2-B) — the ManuscriptSectionView pattern minus editor sessions
//  (figures have none; the pane reads a store snapshot directly).
//

import SwiftUI
import AppKit
import ImpressFTUI
import ImpressSidebar
import OSLog

public struct FigureSectionView: View {

    let scope: FigureListScope
    @Environment(\.appShellConfiguration) private var shellConfiguration
    @Environment(\.openWindow) private var openWindow
    /// imbib's own window's pane model; nil inside the layout tree, where
    /// both panes show and the tree decides what is on screen.
    @Environment(\.hostWindowPanes) private var hostPanes
    @State private var selectedID: UUID?
    // Figures land on the Info tab; the View tab is one click/keystroke away.
    @State private var selectedTab: DetailTab = .info
    /// Non-empty while the delete-confirmation alert is up.
    @State private var pendingDeleteIDs: Set<UUID> = []
    @State private var showDeleteConfirmation = false

    public init(scope: FigureListScope) {
        self.scope = scope
    }

    public var body: some View {
        // Declarative pane layout (mirrors SectionContentView.contentBody):
        // ⌥⌘0 hides the list, ⌘0 hides the detail; both hidden falls back to
        // the list so the route is never empty.
        Group {
            let listVisible = hostPanes?.listPaneVisible ?? true
            let detailVisible = hostPanes?.detailPaneVisible ?? true
            if listVisible && detailVisible {
                ImpressSplitView(
                    listMinWidth: 220,
                    // Quarter by default (the shared default); the user's drag
                    // wins and persists under this surface's OWN key.
                    fractionStorageKey: "impress.split.figures",
                    detailMinWidth: 320
                ) {
                    listPane
                } detail: {
                    detailPane
                        .ignoresSafeArea(.container, edges: .top)
                }
            } else if detailVisible {
                detailPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(.container, edges: .top)
            } else {
                listPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .figureDeleteConfirmation(
            pending: $pendingDeleteIDs, isPresented: $showDeleteConfirmation
        ) { ids in
            performDelete(ids)
        }
    }

    private var listPane: some View {
        FigureListWrapper(
            scope: scope,
            selectedID: $selectedID,
            actions: makeActions()
        )
    }

    @ViewBuilder
    private var detailPane: some View {
        if let id = selectedID {
            // topInset: 40 clears the toolbar band this pane reclaims via
            // `.ignoresSafeArea(.top)` (same rule as ManuscriptDetailPane).
            FigureDetailPane(figureID: id, selectedTab: $selectedTab, topInset: 40)
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Select a figure")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Actions

    /// The figure row verbs are `RecordTriageActions.figures` — shared with
    /// the layout tree's `list` pane (plan wave 6, W4).
    private func makeActions() -> RecordTriageActions {
        .figures(FigureRowActionsHost(
            isFolderScoped: scope.folderID != nil,
            shellConfiguration: shellConfiguration,
            openWindow: openWindow,
            requestDelete: { ids in
                pendingDeleteIDs = ids
                showDeleteConfirmation = true
            }))
    }

    /// Confirmed delete: hard delete with undo (figures have no editor
    /// session to discard — simpler than manuscripts by design).
    private func performDelete(_ ids: Set<UUID>) {
        FigureDeletion.perform(ids)
        if let sel = selectedID, ids.contains(sel) { selectedID = nil }
    }
}
#endif
