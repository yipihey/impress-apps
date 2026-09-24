#if os(macOS)
// Chassis file — macOS-only, like the manuscript list it was moved out of.
//
//  ManuscriptRowChrome.swift
//  PublicationManagerCore
//
//  Everything a manuscript ROW carries besides its look — the context menu,
//  the drag payload, the Rename… and Delete confirmations, and the verbs
//  behind them — in ONE place (plan wave 6, W4).
//
//  Moved verbatim out of `ManuscriptListWrapper` (rowMenu, the drag
//  provider, the rename alert) and `ManuscriptSectionView` (makeActions, the
//  delete confirmation, performDelete), so the layout tree's `list` pane
//  shows a manuscript row exactly as the Manuscripts section does. What each
//  of those touched of its host's own state — the selection, the live editor
//  session — is a closure the host supplies.
//

import SwiftUI
import AppKit
import OSLog
import UniformTypeIdentifiers

private let logger = Logger(subsystem: "com.imbib.app", category: "manuscripts")

// MARK: - Drag

/// A manuscript drag: JSON `[uuid-string]` under `UTType.manuscriptID`, the
/// payload the sidebar's folder rows accept.
@MainActor
enum ManuscriptDragPayload {
    static func provider(ids dragged: [UUID]) -> NSItemProvider {
        // Record for the sidebar's synchronous drop read (see RecordDragSession).
        RecordDragSession.manuscript.begin(ids: dragged)
        let ids = dragged.map(\.uuidString)
        logger.info("drag started: \(ids.count) manuscript(s)")
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.manuscriptID.identifier,
            visibility: .all
        ) { completion in
            let jsonData = try? JSONEncoder().encode(ids)
            completion(jsonData, nil)
            return nil
        }
        return provider
    }
}

// MARK: - Menu

/// A manuscript row's context menu.
struct ManuscriptRowMenu: View {
    let rowID: UUID
    let triage: TriageRowState
    let rowTagPaths: Set<String>
    /// The selection when the clicked row is in it, else the row.
    let targets: Set<UUID>
    /// Whether the list is one folder's — "Remove from Folder" only then.
    let isFolderScoped: Bool
    let actions: RecordTriageActions
    /// Rename… — the host raises its rename alert for this row.
    let onRename: () -> Void

    @Environment(\.appShellConfiguration) private var shellConfiguration

    var body: some View {
        Button(shellConfiguration.openBehavior(for: .manuscript) != .appHandoff
            ? "Open in New Window" : "Open in imprint") {
            actions.onOpen(rowID)
        }
        Button("Duplicate") { actions.onDuplicate(rowID) }
        Button("Rename…") { onRename() }
        Divider()
        // The shared triage segment: star/dismiss-or-restore/archive, Flag
        // and Tags submenus, Delete… last (ADR-0021 grammar).
        TriageMenu.items(
            triage: ManuscriptRecordKind.descriptor.triage,
            row: triage,
            rowTagPaths: rowTagPaths,
            targets: targets,
            actions: actions)
        if isFolderScoped {
            Divider()
            Button(targets.count > 1
                ? "Remove \(targets.count) from Folder" : "Remove from Folder") {
                actions.onRemoveFromScope(targets)
            }
        }
    }
}

extension ManuscriptRowData {
    /// The triage grammar's view of this row.
    var triageRowState: TriageRowState {
        TriageRowState(
            isStarred: isStarredState,
            isDismissed: status == .dismissed,
            isArchived: status == .archived)
    }
}

// MARK: - Rename

/// The row a Rename… alert is editing.
struct ManuscriptRenameRequest: Identifiable {
    let id: UUID
    let title: String
}

extension View {
    /// The "Rename Manuscript" alert. `request` non-nil raises it; the new
    /// title goes to `onRename` when it is non-empty and changed.
    func manuscriptRenameAlert(
        _ request: Binding<ManuscriptRenameRequest?>,
        draft: Binding<String>,
        onRename: @escaping (UUID, String) -> Void
    ) -> some View {
        alert(
            "Rename Manuscript",
            isPresented: Binding(
                get: { request.wrappedValue != nil },
                set: { if !$0 { request.wrappedValue = nil } }
            ),
            presenting: request.wrappedValue
        ) { row in
            TextField("Title", text: draft)
            Button("Rename") {
                let title = draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty, title != row.title else { return }
                logger.info("rename manuscript \(row.id) → '\(title)'")
                onRename(row.id, title)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// The Delete confirmation. `pending` holds the ids while it is up.
    func manuscriptDeleteConfirmation(
        pending: Binding<Set<UUID>>,
        isPresented: Binding<Bool>,
        perform: @escaping (Set<UUID>) -> Void
    ) -> some View {
        alert(
            pending.wrappedValue.count == 1
                ? "Delete Manuscript?" : "Delete \(pending.wrappedValue.count) Manuscripts?",
            isPresented: isPresented
        ) {
            Button("Delete", role: .destructive) {
                // Capture before the state resets (capture-before-Task rule).
                let ids = pending.wrappedValue
                pending.wrappedValue = []
                perform(ids)
            }
            Button("Cancel", role: .cancel) { pending.wrappedValue = [] }
        } message: {
            Text("The manuscript and its body are removed from the library. "
                + "You can recover it immediately with Edit → Undo.")
        }
    }
}

// MARK: - Actions

/// What a manuscript list host supplies to `RecordTriageActions.manuscripts`.
@MainActor
struct ManuscriptRowActionsHost {
    /// The folder the list is scoped to, if it is one folder's.
    var folderID: UUID?
    var shellConfiguration: AppShellConfiguration
    var openWindow: OpenWindowAction
    var selectedID: () -> UUID?
    var select: (UUID?) -> Void
    /// Delete… — the host raises its confirmation for these ids.
    var requestDelete: (Set<UUID>) -> Void
}

extension RecordTriageActions {

    /// Compose the shared store-backed triage defaults (ADR-0021) with the
    /// verbs only a manuscript list can supply: creation (folder scoping +
    /// undo + select), duplication, open behavior, delete (confirmation +
    /// session discard), and remove-from-folder.
    @MainActor
    static func manuscripts(_ host: ManuscriptRowActionsHost) -> RecordTriageActions {
        var a = RecordTriageActions.storeBacked(descriptor: ManuscriptRecordKind.descriptor)
        a.onCreate = { affordance in
            let format = affordance.formatValue ?? DocumentFormat.typst.rawValue
            if let row = RustStoreAdapter.shared.createManuscript(
                title: "Untitled Manuscript", format: format
            ) {
                if let folder = host.folderID,
                   let mID = UUID(uuidString: row.id) {
                    RustStoreAdapter.shared.addToCollection(
                        publicationIds: [mID], collectionId: folder
                    )
                }
                if let mID = UUID(uuidString: row.id) {
                    RustStoreAdapter.shared.registerCreationUndo(
                        itemID: mID, actionName: "New Manuscript",
                        onUndoRemoved: { if host.selectedID() == mID { host.select(nil) } })
                }
                host.select(UUID(uuidString: row.id))
            }
        }
        a.onDelete = { ids in
            host.requestDelete(ids)
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
                        onUndoRemoved: { if host.selectedID() == mID { host.select(nil) } })
                }
                host.select(UUID(uuidString: row.id))
            }
        }
        a.onOpen = { id in
            if case .window(let windowID) = host.shellConfiguration.openBehavior(for: .manuscript) {
                // In-process editor window (imprint's `manuscript-editor`
                // WindowGroup) — no imprint:// URL roundtrip needed.
                host.openWindow(id: windowID, value: id)
            } else {
                // Shared-store handoff: imprint opens the same manuscript by UUID.
                ManuscriptImprintHandoff.open(manuscriptID: id)
            }
        }
        a.onRemoveFromScope = { ids in
            guard let folder = host.folderID else { return }
            RustStoreAdapter.shared.removeFromCollection(
                publicationIds: Array(ids), collectionId: folder)
        }
        return a
    }
}

/// The confirmed delete: drop each live editor session FIRST (so its debounced
/// CAS save can't resurrect the body post-delete), then delete undoably. The
/// host then lets go of its own references (selection, session).
@MainActor
enum ManuscriptDeletion {
    static func perform(_ ids: Set<UUID>) {
        Logger.library.infoCapture(
            "delete manuscripts: \(ids.map(\.uuidString).joined(separator: ","))",
            category: "manuscripts")
        for id in ids {
            ManuscriptSessionRegistry.shared.discard(id: id)
            // A layout-tree `source` pane's editor holds the session too, and
            // its own undo history for the manuscript: both go first.
            SourcePaneSession.abandonEverywhere(manuscriptID: id)
            RustStoreAdapter.shared.deleteItem(id: id)
        }
    }
}
#endif
