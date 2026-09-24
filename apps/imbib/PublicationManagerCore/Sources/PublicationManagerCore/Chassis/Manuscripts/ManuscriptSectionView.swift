#if os(macOS)
// Chassis file — macOS-only in GUI-meld Phase 1 (iOS keeps IOSContentView).
//
//  ManuscriptSectionView.swift
//  PublicationManagerCore
//
//  Composes the Manuscripts section as the STANDARD chassis list|detail split
//  (GUI-meld plan §5), replacing the old full-bleed JournalManuscriptsListView.
//  The list is ManuscriptListWrapper; the detail is the existing
//  ManuscriptDetailView for Phase 2 (read-mostly) — the tabbed Source-editor
//  detail lands in Phase 3.

import SwiftUI
import AppKit
import ImpressFTUI
import ImpressSidebar
import OSLog

public struct ManuscriptSectionView: View {

    let scope: ManuscriptListScope
    @Environment(\.appShellConfiguration) private var shellConfiguration
    @Environment(\.openWindow) private var openWindow
    /// imbib's own window's pane model; nil inside the layout tree, where
    /// both panes show and the tree decides what is on screen.
    @Environment(\.hostWindowPanes) private var hostPanes
    @State private var selectedID: UUID?
    // Manuscripts default to the Source tab (thin-twin: launching imprint
    // lands you in the editor). Persisted separately from the publication tab.
    @State private var selectedTab: DetailTab = .source
    /// Non-empty while the delete-confirmation alert is up.
    @State private var pendingDeleteIDs: Set<UUID> = []
    @State private var showDeleteConfirmation = false
    /// The live editor session for the current selection. Owned here (not in
    /// the pane) so it can never lag behind `selectedID`.
    @State private var session: ManuscriptEditorSession?

    public init(scope: ManuscriptListScope) {
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
                    fractionStorageKey: "impress.split.manuscripts",
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
        // NOTE: the list show/hide toolbar item lives in TabContentView (the
        // NavigationSplitView root). Declared here it never reached the window
        // toolbar — nested detail-column toolbars are dropped for this route.
        .task(id: selectedID) {
            // Selection is instant; loading the editor is not. Drop the stale
            // session immediately (so no pane shows the previous manuscript),
            // then wait out a short quiet window before reading the store —
            // holding ↓ cancels each pending load, so the list "flies" and
            // only the manuscript you land on is opened.
            guard let id = selectedID else {
                session = nil
                return
            }
            if session?.manuscriptID != id { session = nil }
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled else { return }
            session = ManuscriptSessionRegistry.shared.session(for: id)
        }
        .focusedSceneValue(\.focusedManuscriptID, selectedID)
        .manuscriptDeleteConfirmation(
            pending: $pendingDeleteIDs, isPresented: $showDeleteConfirmation
        ) { ids in
            performDelete(ids)
        }
    }

    private var listPane: some View {
        ManuscriptListWrapper(
            scope: scope,
            selectedID: $selectedID,
            actions: makeActions()
        )
    }

    @ViewBuilder
    private var detailPane: some View {
        if let id = selectedID {
            // Deliberately NO `.id(id)`: the pane re-resolves its session in
            // `.onChange(of: manuscriptID, initial: true)`, and this view is
            // reached through `.id(scope)` at the section level, so the route
            // staleness the `.id(source.id)` rule guards against can't occur
            // here. Adding `.id(id)` tore down and rebuilt the whole
            // NSTextView editor on every selection, which is what made
            // clicking through the list feel sluggish.
            // topInset: 40 clears the toolbar band this pane reclaims below via
            // `.ignoresSafeArea(.top)` — without it the tab picker sits in the
            // titlebar drag region and can't be clicked.
            ManuscriptDetailPane(
                manuscriptID: id, session: session,
                selectedTab: $selectedTab, topInset: 40)
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.image")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Select a manuscript")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Actions

    /// The manuscript row verbs are `RecordTriageActions.manuscripts` —
    /// shared with the layout tree's `list` pane (plan wave 6, W4).
    private func makeActions() -> RecordTriageActions {
        .manuscripts(ManuscriptRowActionsHost(
            folderID: scope.folderID,
            shellConfiguration: shellConfiguration,
            openWindow: openWindow,
            selectedID: { selectedID },
            select: { selectedID = $0 },
            requestDelete: { ids in
                pendingDeleteIDs = ids
                showDeleteConfirmation = true
            }))
    }

    /// Confirmed delete: drop the live editor session FIRST (so its debounced
    /// CAS save can't resurrect the body post-delete), then delete undoably.
    private func performDelete(_ ids: Set<UUID>) {
        ManuscriptDeletion.perform(ids)
        if let live = session?.manuscriptID, ids.contains(live) { session = nil }
        if let sel = selectedID, ids.contains(sel) { selectedID = nil }
    }
}
#endif
