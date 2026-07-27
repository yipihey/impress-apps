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
            let layout = PaneLayoutStore.shared.current
            if layout.listPaneVisible && layout.detailPaneVisible {
                ImpressSplitView(
                    listMinWidth: 220,
                    listIdealFraction: 1.0 / 3.0,
                    detailMinWidth: 320
                ) {
                    listPane
                } detail: {
                    detailPane
                        .ignoresSafeArea(.container, edges: .top)
                }
            } else if layout.detailPaneVisible {
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
        .alert(
            pendingDeleteIDs.count == 1
                ? "Delete Manuscript?" : "Delete \(pendingDeleteIDs.count) Manuscripts?",
            isPresented: $showDeleteConfirmation
        ) {
            Button("Delete", role: .destructive) {
                // Capture before the state resets (capture-before-Task rule).
                let ids = pendingDeleteIDs
                pendingDeleteIDs = []
                performDelete(ids)
            }
            Button("Cancel", role: .cancel) { pendingDeleteIDs = [] }
        } message: {
            Text("The manuscript and its body are removed from the library. "
                + "You can recover it immediately with Edit → Undo.")
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

    /// Compose the shared store-backed triage defaults (ADR-0021) with the
    /// verbs only this host can supply: creation (folder scoping + undo +
    /// select), duplication, open behavior, delete (confirmation + session
    /// discard), and remove-from-folder.
    private func makeActions() -> RecordTriageActions {
        var a = RecordTriageActions.storeBacked(descriptor: ManuscriptRecordKind.descriptor)
        a.onCreate = { affordance in
            let format = affordance.formatValue ?? DocumentFormat.typst.rawValue
            if let row = RustStoreAdapter.shared.createManuscript(
                title: "Untitled Manuscript", format: format
            ) {
                if let folder = scope.folderID,
                   let mID = UUID(uuidString: row.id) {
                    RustStoreAdapter.shared.addToCollection(
                        publicationIds: [mID], collectionId: folder
                    )
                }
                if let mID = UUID(uuidString: row.id) {
                    RustStoreAdapter.shared.registerCreationUndo(
                        itemID: mID, actionName: "New Manuscript",
                        onUndoRemoved: { if selectedID == mID { selectedID = nil } })
                }
                selectedID = UUID(uuidString: row.id)
            }
        }
        a.onDelete = { ids in
            pendingDeleteIDs = ids
            showDeleteConfirmation = true
        }
        a.onDuplicate = { id in
            guard let detail = RustStoreAdapter.shared.getManuscriptDetail(id: id) else { return }
            if let row = RustStoreAdapter.shared.createManuscript(
                title: "\(detail.title) copy",
                format: detail.format.isEmpty ? "typst" : detail.format,
                body: detail.bodyContent,
                authors: detail.authors
            ) {
                if let mID = UUID(uuidString: row.id) {
                    RustStoreAdapter.shared.registerCreationUndo(
                        itemID: mID, actionName: "Duplicate Manuscript",
                        onUndoRemoved: { if selectedID == mID { selectedID = nil } })
                }
                selectedID = UUID(uuidString: row.id)
            }
        }
        a.onOpen = { id in
            if case .window(let windowID) = shellConfiguration.openBehavior(for: .manuscript) {
                // In-process editor window (imprint's `manuscript-editor`
                // WindowGroup) — no imprint:// URL roundtrip needed.
                openWindow(id: windowID, value: id)
            } else {
                openInImprint(manuscriptID: id)
            }
        }
        a.onRemoveFromScope = { ids in
            guard let folder = scope.folderID else { return }
            RustStoreAdapter.shared.removeFromCollection(
                publicationIds: Array(ids), collectionId: folder)
        }
        return a
    }

    private func openInImprint(manuscriptID: UUID) {
        // Shared-store handoff: imprint opens the same manuscript by UUID.
        ManuscriptImprintHandoff.open(manuscriptID: manuscriptID)
    }

    /// Confirmed delete: drop the live editor session FIRST (so its debounced
    /// CAS save can't resurrect the body post-delete), then delete undoably.
    private func performDelete(_ ids: Set<UUID>) {
        Logger.library.infoCapture(
            "delete manuscripts: \(ids.map(\.uuidString).joined(separator: ","))",
            category: "manuscripts")
        for id in ids {
            ManuscriptSessionRegistry.shared.discard(id: id)
            RustStoreAdapter.shared.deleteItem(id: id)
        }
        if let live = session?.manuscriptID, ids.contains(live) { session = nil }
        if let sel = selectedID, ids.contains(sel) { selectedID = nil }
    }
}
#endif
