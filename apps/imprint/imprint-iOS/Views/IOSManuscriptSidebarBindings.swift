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
    static var configuration: AppShellConfiguration { .imprint }

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
        case .section, nil: return nil
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
                case .folder, .section:
                    return nil
                }
            },
            sectionIsAvailable: { section in
                // The CONTENT gate, on top of the preset (macOS applies the
                // same intersection in `shouldShowSection`).
                //
                // `.citedInManuscripts` is permitted by the imprint preset but
                // lists PUBLICATIONS — imprint-iOS has no publication list
                // surface, so surfacing it would give the user a row that
                // opens nothing. Suppressed here rather than removed from the
                // preset, which macOS relies on.
                section != .citedInManuscripts
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

    /// The store-backed half of the shared triage grammar, on imprint's
    /// adapter instead of imbib's `RustStoreAdapter` (which
    /// `RecordTriageActions.storeBacked` uses) — same verbs, same descriptor,
    /// plus the injected `UndoManager` every mutation registers against.
    ///
    /// `onDelete` is deliberately left to the HOST: deletion is
    /// `.confirmHard` for manuscripts, and the confirmation + editor-session
    /// teardown are the host's business (RecordTriage.swift header).
    static func triageActions(
        adapter: ManuscriptStoreAdapter,
        undoManager: UndoManager?
    ) -> RecordTriageActions {
        var actions = RecordTriageActions()
        actions.onToggleStar = { ids, starred in
            adapter.setStarred(ids: Array(ids), starred: starred, undoManager: undoManager)
        }
        actions.onSetFlag = { ids, color in
            adapter.setFlag(
                ids: Array(ids), color: color?.rawValue, undoManager: undoManager)
        }
        actions.onAddTag = { ids, path in
            adapter.addTag(ids: Array(ids), tagPath: path, undoManager: undoManager)
        }
        actions.onRemoveTag = { ids, path in
            adapter.removeTag(ids: Array(ids), tagPath: path, undoManager: undoManager)
        }
        actions.onDismiss = { ids in
            _ = adapter.dismiss(ids: Array(ids), undoManager: undoManager)
        }
        actions.onRestore = { ids in
            _ = adapter.restore(ids: Array(ids), undoManager: undoManager)
        }
        actions.onArchive = { ids in
            _ = adapter.archive(ids: Array(ids), undoManager: undoManager)
        }
        // GAP (reported, not papered over): `ManuscriptStoreAdapter` has no
        // `listTags()`, so imprint-iOS can offer no existing tag paths. An
        // empty provider hides the Tags submenu instead of showing a menu
        // with nothing in it; wiring a real list is an adapter verb away.
        actions.availableTagPaths = { [] }
        return actions
    }
}
