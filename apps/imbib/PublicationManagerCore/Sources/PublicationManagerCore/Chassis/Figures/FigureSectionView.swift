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
        .alert(
            pendingDeleteIDs.count == 1
                ? "Delete Figure?" : "Delete \(pendingDeleteIDs.count) Figures?",
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
            Text("The figure record is removed from the library. "
                + "You can recover it immediately with Edit → Undo.")
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

    /// Compose the shared store-backed triage defaults (ADR-0021) with the
    /// verbs only this host can supply: open behavior (canvas window),
    /// delete (confirmation), and remove-from-folder (envelope setParent).
    private func makeActions() -> RecordTriageActions {
        var a = RecordTriageActions.storeBacked(descriptor: FigureRecordKind.descriptor)
        a.onDelete = { ids in
            pendingDeleteIDs = ids
            showDeleteConfirmation = true
        }
        a.onOpen = { id in
            if case .window(let windowID) = shellConfiguration.openBehavior(for: .figure) {
                // implore's canvas WindowGroup takes the figure id STRING
                // (lowercase store form).
                openWindow(id: windowID, value: id.uuidString.lowercased())
            }
            // No app-handoff target for figures today (implore IS the app).
        }
        a.onRemoveFromScope = { ids in
            guard scope.folderID != nil else { return }
            for id in ids {
                FigureStoreReader.shared.setParent(
                    itemID: id.uuidString, parentID: nil)
            }
        }
        return a
    }

    /// Confirmed delete: hard delete with undo (figures have no editor
    /// session to discard — simpler than manuscripts by design).
    private func performDelete(_ ids: Set<UUID>) {
        Logger.library.infoCapture(
            "delete figures: \(ids.map(\.uuidString).joined(separator: ","))",
            category: "figures")
        for id in ids {
            RustStoreAdapter.shared.deleteItem(id: id)
        }
        if let sel = selectedID, ids.contains(sel) { selectedID = nil }
    }
}
#endif
