#if os(macOS)
// Chassis file — macOS-only, like the figure list it was moved out of.
//
//  FigureRowChrome.swift
//  PublicationManagerCore
//
//  Everything a figure ROW carries besides its look — the context menu, the
//  drag payload, the Delete confirmation and the verbs behind them — in ONE
//  place (plan wave 6, W4), moved verbatim out of `FigureListWrapper` (rowMenu,
//  the drag provider) and `FigureSectionView` (makeActions, the confirmation,
//  performDelete), so a figure row in the layout tree's `list` pane carries
//  the chrome it has in the Figures section. The selection stays the host's.
//

import SwiftUI
import AppKit
import OSLog
import UniformTypeIdentifiers

private let logger = Logger(subsystem: "com.imbib.app", category: "figures")

// MARK: - Drag

/// A figure drag: JSON `[uuid-string]` under `UTType.figureID`, the payload
/// the sidebar's figure folder rows accept.
@MainActor
enum FigureDragPayload {
    static func provider(ids dragged: [UUID]) -> NSItemProvider {
        // Record for the sidebar's synchronous drop read (see RecordDragSession).
        RecordDragSession.figure.begin(ids: dragged)
        let ids = dragged.map(\.uuidString)
        logger.info("drag started: \(ids.count) figure(s)")
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.figureID.identifier,
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

/// A figure row's context menu.
struct FigureRowMenu: View {
    let rowID: UUID
    let isStarred: Bool
    let rowTagPaths: Set<String>
    /// The selection when the clicked row is in it, else the row.
    let targets: Set<UUID>
    /// Whether the list is one folder's — "Remove from Folder" only then.
    let isFolderScoped: Bool
    let actions: RecordTriageActions

    var body: some View {
        Button("Open in Canvas") { actions.onOpen(rowID) }
        Divider()
        // The shared triage segment: star, Flag and Tags submenus, Delete…
        // last (ADR-0021 grammar; figures have no dismiss/archive lifecycle).
        TriageMenu.items(
            triage: FigureRecordKind.descriptor.triage,
            row: TriageRowState(isStarred: isStarred, isDismissed: false, isArchived: false),
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

// MARK: - Delete

extension View {
    /// The Delete confirmation. `pending` holds the ids while it is up.
    func figureDeleteConfirmation(
        pending: Binding<Set<UUID>>,
        isPresented: Binding<Bool>,
        perform: @escaping (Set<UUID>) -> Void
    ) -> some View {
        alert(
            pending.wrappedValue.count == 1
                ? "Delete Figure?" : "Delete \(pending.wrappedValue.count) Figures?",
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
            Text("The figure record is removed from the library. "
                + "You can recover it immediately with Edit → Undo.")
        }
    }
}

/// The confirmed delete: hard delete with undo (figures have no editor
/// session to discard — simpler than manuscripts by design). The host then
/// lets go of its own selection.
@MainActor
enum FigureDeletion {
    static func perform(_ ids: Set<UUID>) {
        Logger.library.infoCapture(
            "delete figures: \(ids.map(\.uuidString).joined(separator: ","))",
            category: "figures")
        for id in ids {
            RustStoreAdapter.shared.deleteItem(id: id)
        }
    }
}

// MARK: - Actions

/// What a figure list host supplies to `RecordTriageActions.figures`.
@MainActor
struct FigureRowActionsHost {
    /// Whether the list is one folder's.
    var isFolderScoped: Bool
    var shellConfiguration: AppShellConfiguration
    var openWindow: OpenWindowAction
    /// Delete… — the host raises its confirmation for these ids.
    var requestDelete: (Set<UUID>) -> Void
}

extension RecordTriageActions {

    /// Compose the shared store-backed triage defaults (ADR-0021) with the
    /// verbs only a figure list can supply: open behavior (canvas window),
    /// delete (confirmation), and remove-from-folder (envelope setParent).
    @MainActor
    static func figures(_ host: FigureRowActionsHost) -> RecordTriageActions {
        var a = RecordTriageActions.storeBacked(descriptor: FigureRecordKind.descriptor)
        a.onDelete = { ids in
            host.requestDelete(ids)
        }
        a.onOpen = { id in
            if case .window(let windowID) = host.shellConfiguration.openBehavior(for: .figure) {
                // implore's canvas WindowGroup takes the figure id STRING
                // (lowercase store form).
                host.openWindow(id: windowID, value: id.uuidString.lowercased())
            }
            // No app-handoff target for figures today (implore IS the app).
        }
        a.onRemoveFromScope = { ids in
            guard host.isFolderScoped else { return }
            for id in ids {
                FigureStoreReader.shared.setParent(
                    itemID: id.uuidString, parentID: nil)
            }
        }
        return a
    }
}
#endif
