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
    /// `.presenting([.manuscript, .publication])` is this HOST's capability
    /// statement. It was `[.manuscript]` alone from C1 until I2, and the
    /// missing half was never imprint's: the `.imprint` preset permits
    /// `.citedInManuscripts`, whose rows are PUBLICATIONS, macOS imprint
    /// renders those through `UnifiedPublicationListWrapper`, and there was no
    /// PUBLIC iOS publication surface in the chassis to render them with — the
    /// C1 finding, deferred as "(b)".
    ///
    /// I2 built both halves in PMC (`IOSPublicationListPane` +
    /// `IOSPublicationDetailPane`), so the deferral is paid: imprint-iOS now
    /// declares the kind and the section arrives with no further edit. The
    /// section was NEVER suppressed by name here — C1 replaced a hardcoded
    /// `section != .citedInManuscripts` with this capability set precisely so
    /// that gaining the surface would be a one-word change, and it was.
    ///
    /// What imprint-iOS still does NOT gain: a publication list of its own
    /// making. It shows the papers ITS manuscripts cite, read-only, through the
    /// chassis pane. Every other publication-bound section (`.inbox`,
    /// `.libraries`, …) is absent because the imprint PRESET does not permit
    /// it, which is the correct layer for "imprint is not a bibliography
    /// manager".
    static var configuration: AppShellConfiguration {
        .imprint.presenting([.manuscript, .publication])
    }

    static var descriptor: RecordKindDescriptor { ManuscriptRecordKind.descriptor }

    // MARK: Scope translation

    /// `RecordSidebarScope` (chassis vocabulary) → `ManuscriptStoreScope`
    /// (imprint's list surface). `nil` = this shell has no MANUSCRIPT list for
    /// that node; see `publicationSource(for:)` for the other half.
    static func storeScope(for scope: RecordSidebarScope?) -> ManuscriptStoreScope? {
        switch scope {
        case .all: return .all
        case .status(_, let status): return .status(status)
        case .folder(_, let id): return .folder(id)
        case .flagged(_, let color): return .flagged(color)
        // `.host` is the chassis's seam for rows only the HOST can name
        // (imbib's libraries, saved searches, search forms — see
        // `RecordSidebarScope.host`). ADR-0023 W3 gave imprint its first one:
        // a watched manuscript folder, whose key space is the CHASSIS's
        // (`WatchedFolderRoute`, whose `keyPrefix` is public exactly so a host
        // can recognise keys it did not build).
        case .host(_, let key):
            guard case .folder(let folderID)? = WatchedFolderRoute(key: key) else { return nil }
            // The folder's manuscripts ARE its provenance tag — W2's answer,
            // reused rather than re-decided.
            return WatchedManuscriptFolders.storeScope(forFolder: folderID)
        case .section, nil: return nil
        }
    }

    /// The publication half (I2). `.citedInManuscripts` is the only section the
    /// imprint preset binds to `.publication`, and the chassis conversion names
    /// it — no section literal here either.
    static func publicationSource(for scope: RecordSidebarScope?) -> PublicationSource? {
        guard let scope, scope.kind == .publication else { return nil }
        return PublicationSource(routeScope: scope)
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
                // `RecordSidebarScope.host`). imprint's one host row is a
                // watched folder, and its badge is DELIBERATELY not computed
                // here: `WatchedFolderRowState.badgeCount` already decides
                // whether this folder can honestly claim a total (it is nil for
                // any degraded state — D6's whole point), and `sidebarNodes`
                // carries that decision through verbatim. Recomputing it from
                // the tag would put a number on a row that has just declared it
                // cannot count, which is the "Spotlight blind spots read as
                // data loss" risk arriving through the back door.
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
                // `.citedInManuscripts` used to be the one section that had to
                // go, and it went declaratively rather than by name. Since I2
                // it STAYS, declaratively and for the same reason: the host's
                // capability set gained `.publication` because the chassis
                // gained the pane. Nothing in this closure changed to let it
                // in, which is the property the capability set exists to have.
                true
            },
            sectionContent: { section, kind in
                // ADR-0023 W3 — the ONE thing imprint's sidebar resolves for
                // itself. Everything else in this file answers "where does the
                // data come from"; this answers "and there are also these rows",
                // which is what `RecordSidebarSectionContent` exists for.
                //
                // `runningCoordinator` (not `coordinator`) on purpose: rendering
                // a section must never be the thing that starts a watcher.
                guard section == .manuscripts, kind == descriptor.id,
                    let rows = WatchedManuscriptFolders.runningCoordinator?.rows, !rows.isEmpty
                else { return nil }
                // `additionalNodes`, not `nodes`: All / the declared statuses /
                // the user's folders are the DESCRIPTOR's and must stay derived.
                return RecordSidebarSectionContent(
                    additionalNodes: rows.sidebarNodes(kind: descriptor.id))
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
