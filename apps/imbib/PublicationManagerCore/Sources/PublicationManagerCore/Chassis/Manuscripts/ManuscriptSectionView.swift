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

public struct ManuscriptSectionView: View {

    let scope: ManuscriptListScope
    @State private var selectedID: UUID?
    // Manuscripts default to the Source tab (thin-twin: launching imprint
    // lands you in the editor). Persisted separately from the publication tab.
    @State private var selectedTab: DetailTab = .source

    public init(scope: ManuscriptListScope) {
        self.scope = scope
    }

    public var body: some View {
        ImpressSplitView(listMinWidth: 220, listIdealWidth: 320, detailMinWidth: 320) {
            ManuscriptListWrapper(
                scope: scope,
                selectedID: $selectedID,
                actions: makeActions()
            )
        } detail: {
            detailPane
                .ignoresSafeArea(.container, edges: .top)
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let id = selectedID {
            // NO `.id(id)` — ManuscriptDetailPane resolves its editor session
            // from the registry on `.onChange(of: manuscriptID)`, so the
            // editor/undo/compile survive selection switches (GUI-meld Phase 3).
            // topInset: 40 clears the toolbar band this pane reclaims below via
            // `.ignoresSafeArea(.top)` — without it the tab picker sits in the
            // titlebar drag region and can't be clicked.
            ManuscriptDetailPane(manuscriptID: id, selectedTab: $selectedTab, topInset: 40)
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

    private func makeActions() -> ManuscriptListActions {
        var a = ManuscriptListActions()
        a.onNewManuscript = {
            let format = scope.folderID != nil ? "typst" : "typst"
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
            for id in ids { RustStoreAdapter.shared.deleteItem(id: id) }
            if let sel = selectedID, ids.contains(sel) { selectedID = nil }
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
        a.onSetFlag = { ids, color in
            RustStoreAdapter.shared.setFlag(ids: Array(ids), color: color?.rawValue)
        }
        a.onOpenInImprint = { id in
            openInImprint(manuscriptID: id)
        }
        return a
    }

    private func openInImprint(manuscriptID: UUID) {
        // Shared-store handoff: imprint opens the same manuscript by UUID.
        ManuscriptImprintHandoff.open(manuscriptID: manuscriptID)
    }
}
#endif
