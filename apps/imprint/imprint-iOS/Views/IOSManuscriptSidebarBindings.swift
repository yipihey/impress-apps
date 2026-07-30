//
//  IOSManuscriptSidebarBindings.swift
//  imprint-iOS
//
//  The ENTIRE app-specific surface of imprint's iOS sidebar/library.
//
//  Everything about the sidebar's shape — which sections exist, which record
//  kind each serves, which status smart-children appear, whether folders are
//  organisable — is declared in `AppShellConfiguration.imprint` and
//  `ManuscriptRecordKind.descriptor` and rendered by PMC's
//  `RecordSidebarBuilder` / `RecordSidebarView`. This file only says WHERE
//  the data comes from (imprint's `ManuscriptStoreAdapter`) and translates
//  the chassis's `RecordSidebarScope` into imprint's `ManuscriptStoreScope`.
//
//  A second app adopts the same sidebar by writing its own version of this
//  file — ~150 lines of closures — and passing its own preset. No fork of the
//  view, no second truth table.
//
//  Every mutating call takes `SceneUndoManager.shared.manager`, so library
//  operations land on the responder chain's undo stack: the editor's Undo
//  button and shake-to-undo both reach a dismiss, a folder move, a rename.
//

import Foundation
import PublicationManagerCore

// MARK: - Counts snapshot

/// One manuscript read per store version, shared by every badge.
///
/// The sidebar asks for a dozen counts (All + each declared status + each
/// flag colour) on every rebuild. Answering each with its own predicate query
/// would be a dozen FFI round-trips per keystroke-driven refresh; the
/// snapshot answers all of them from one `allManuscripts` read and is
/// invalidated by `dataVersion`, the same signal the views observe.
@MainActor
final class ManuscriptSidebarCounts {
    private var version: Int = -1
    private var models: [ManuscriptModel] = []

    func models(_ adapter: ManuscriptStoreAdapter) -> [ManuscriptModel] {
        if version != adapter.dataVersion {
            models = adapter.allManuscripts(limit: 0)
            version = adapter.dataVersion
        }
        return models
    }
}

// MARK: - Bindings

@MainActor
enum ImprintSidebarBindings {

    /// imprint's declarative identity. The sidebar is whatever this says.
    ///
    /// `.presenting([.manuscript])` is this HOST's capability statement: the
    /// iOS build has one record surface, the manuscript list. The `.imprint`
    /// preset also permits `.citedInManuscripts`, whose rows are PUBLICATIONS
    /// — macOS imprint renders those through `UnifiedPublicationListWrapper`,
    /// and this target has no publication list at all.
    ///
    /// That section used to be suppressed by `section != .citedInManuscripts`
    /// in the content gate below: honest, but a hardcoded section NAME in app
    /// code, which says what to hide and not why. Naming the KIND says why, and
    /// covers every publication-bound section this shell might be handed in
    /// future without another line here.
    static var configuration: AppShellConfiguration {
        .imprint.presenting([.manuscript])
    }

    static var descriptor: RecordKindDescriptor { ManuscriptRecordKind.descriptor }

    // MARK: Scope translation

    /// `RecordSidebarScope` (chassis vocabulary) → `ManuscriptStoreScope`
    /// (imprint's list surface). `nil` = this shell has no list for that node.
    static func storeScope(for scope: RecordSidebarScope?) -> ManuscriptStoreScope? {
        switch scope {
        case .all: return .all
        case .status(_, let status): return .status(status)
        case .folder(_, let id): return .folder(id)
        case .flagged(_, let color): return .flagged(color)
        // `.host` is the chassis's seam for rows only the HOST can name
        // (imbib's libraries, saved searches, search forms — see
        // `RecordSidebarScope.host`). imprint resolves every one of its rows
        // from the declarations, so it never emits one and has no list for it.
        case .section, .host, nil: return nil
        }
    }

    // MARK: Data source

    static func dataSource(
        adapter: ManuscriptStoreAdapter,
        counts: ManuscriptSidebarCounts
    ) -> RecordSidebarDataSource {
        RecordSidebarDataSource(
            folders: { kind in
                // Folders exist only for kinds that declare a collection
                // binding; imprint's store speaks the manuscript one.
                guard kind == descriptor.id else { return [] }
                return adapter.listCollections().map {
                    RecordFolder(
                        id: $0.id, name: $0.name,
                        parentID: $0.parentID, sortOrder: $0.sortOrder)
                }
            },
            folderCounts: { kind, ids in
                guard kind == descriptor.id else { return ids.map { _ in 0 } }
                return adapter.collectionMemberCounts(collectionIDs: ids)
            },
            count: { scope in
                let models = counts.models(adapter)
                let dismissed = ManuscriptStoreAdapter.dismissedStatus
                switch scope {
                case .all:
                    return models.filter { $0.status != dismissed }.count
                case .status(_, let status):
                    return models.filter { $0.status == status }.count
                case .flagged(_, let color):
                    return models.filter {
                        $0.status != dismissed && $0.flagColor != nil
                            && (color == nil || $0.flagColor == color)
                    }.count
                // `.host` = a row only the host can name (see
                // `RecordSidebarScope.host`). imprint declares none, and a
                // badge for a row that does not exist is nil, like `.folder`
                // (whose counts come from `folderCounts` above).
                case .folder, .section, .host:
                    return nil
                }
            },
            sectionIsAvailable: { _ in
                // The CONTENT gate — "is there anything in it right now" —
                // which imprint-iOS does not need: every section this shell
                // shows is manuscript-scoped and must exist before it has
                // content (Dismissed is the destination of the dismiss
                // gesture, so hiding it while empty would strand the verb).
                //
                // The section that DOES have to go is `.citedInManuscripts`,
                // and it is gone declaratively: `configuration` above says
                // this host presents `.manuscript` only, so the builder drops
                // every publication-bound section. This closure no longer
                // names a section, which is the point.
                true
            })
    }

    // MARK: Collection actions (ADR-0022 kernel, all undo-registering)

    static func collectionActions(
        adapter: ManuscriptStoreAdapter,
        undoManager: UndoManager?
    ) -> RecordCollectionActions {
        RecordCollectionActions(
            // The DESCRIPTOR decides whether the organise verbs exist at all.
            canOrganize: descriptor.collection?.canOrganize ?? false,
            createFolder: { name, parentID in
                try? adapter.createCollection(
                    name: name, parentID: parentID, undoManager: undoManager)
            },
            renameFolder: { id, name in
                _ = adapter.renameCollection(id: id, to: name, undoManager: undoManager)
            },
            reparentFolder: { id, newParentID in
                _ = adapter.reparentCollection(
                    id: id, newParentID: newParentID, undoManager: undoManager)
            },
            deleteFolder: { id in
                _ = adapter.deleteCollection(id: id, undoManager: undoManager)
            },
            addRecords: { ids, folderID in
                _ = adapter.addToCollection(
                    manuscriptIDs: Array(ids), collectionID: folderID,
                    undoManager: undoManager)
            },
            removeRecords: { ids, folderID in
                _ = adapter.removeFromCollection(
                    manuscriptIDs: Array(ids), collectionID: folderID,
                    undoManager: undoManager)
            })
    }

    // MARK: Triage actions

    /// The store-backed half of the shared triage grammar.
    ///
    /// This used to be nine hand-written closures onto imprint's adapter,
    /// because `RecordTriageActions.storeBacked` wrote through imbib's
    /// `RustStoreAdapter` and took no `UndoManager`. Stage 4b gave it both seams:
    /// the `undoManager:` overload registers closure-based undo (the
    /// `SharedStore` FFI has no operation log to derive one from), and `kernel:`
    /// points it at imprint's OWN store handle so no second store facade is
    /// booted in-process.
    ///
    /// `onDelete` is deliberately left to the HOST: deletion is
    /// `.confirmHard` for manuscripts, and the confirmation + editor-session
    /// teardown are the host's business (RecordTriage.swift header).
    static func triageActions(
        adapter: ManuscriptStoreAdapter,
        undoManager: UndoManager?
    ) -> RecordTriageActions {
        RecordTriageActions.storeBacked(
            descriptor: descriptor,
            undoManager: undoManager,
            kernel: adapter.triageKernel,
            // The tag paths already in use on manuscripts, through the adapter's
            // `dataVersion`-keyed memo rather than the kernel's raw walk — this
            // is read on every context-menu render pass. (It was once `{ [] }`,
            // an empty provider that hid the Tags submenu entirely, so `t` and
            // the long-press menu could star or flag on iOS but never file a
            // manuscript under an existing tag.)
            availableTagPaths: { adapter.listTags() })
    }
}
