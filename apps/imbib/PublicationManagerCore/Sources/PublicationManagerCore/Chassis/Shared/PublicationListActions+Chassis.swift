#if os(macOS)
// Chassis file — macOS-only, like the list wrapper it was moved out of.
//
//  PublicationListActions+Chassis.swift
//  PublicationManagerCore
//
//  The verbs behind a publication list's row menu — ONE builder for every
//  macOS publication list host (plan wave 6, W4).
//
//  Moved out of `UnifiedPublicationListWrapper.buildListActions()` so the
//  layout tree's `list` pane runs the same store sequences as the legacy
//  list instead of a second set that drifts. Every closure is the one the
//  wrapper built; what it did to the WRAPPER's own state — drop deleted rows
//  from its data source, advance its selection, open its inline tag input,
//  show its drop preview — is now a hook on `PublicationListActionsHost`, and
//  each host fills the hooks with its own state.
//

import SwiftUI
import OSLog

private let logger = Logger(subsystem: "com.imbib.app", category: "publicationlist")

/// What a publication list host supplies to `PublicationListActions.chassis`.
@MainActor
struct PublicationListActionsHost {
    /// The scope the list shows. Decides the delete/dismiss/save sequences
    /// (`PublicationListMutations`) and whether the Inbox-only verbs exist.
    var source: PublicationSource
    /// False for read-only scopes: no delete, cut, paste, or collection edits.
    var canEdit: Bool
    var libraryViewModel: LibraryViewModel
    var libraryManager: LibraryManager
    /// The rows on screen — the star and e-ink "any off → all on" rules read them.
    var rows: () -> [PublicationRowData]
    /// Before a delete: the host drops `ids` from its own rows and selection.
    var willDelete: (Set<UUID>) -> Void
    /// The row to select once `ids` leave the list, from the host's visual
    /// order (`PublicationListOrder.nextSelection`). Called BEFORE the
    /// mutation, as the wrapper always did.
    var nextSelection: (Set<UUID>) -> UUID?
    /// Select `id` (nil clears the selection).
    var select: (UUID?) -> Void
    /// "Add Tag" — the host's own way to ask for a tag.
    var beginTagInput: (Set<UUID>) -> Void
    /// Show `id`'s PDF.
    var openPDF: (UUID) -> Void
    var onListDrop: (([NSItemProvider], DropTarget) -> Void)?
    var onDownloadPDFs: ((Set<UUID>) -> Void)?
    var onRefresh: (() async -> Void)?
}

extension PublicationListActions {

    /// The actions bag every macOS publication list shows.
    static func chassis(_ host: PublicationListActionsHost) -> PublicationListActions {
        let a = PublicationListActions()
        let source = host.source
        if host.canEdit {
            a.onDelete = { ids in
                // Remove from local state FIRST to prevent rendering deleted objects
                host.willDelete(ids)

                // Stage 5d SPLIT: the sequence below moved verbatim to
                // `PublicationListMutations.delete`. iOS's copy called
                // `deletePublications` unconditionally from every scope, so
                // "Delete" destroyed the paper there and soft-deleted it here.
                var isDismissedScope = false
                if case .dismissed = source { isDismissedScope = true }
                PublicationListMutations.delete(
                    ids: ids,
                    source: source,
                    permanently: isDismissedScope,
                    // Lazy: deleting OUT of Dismissed must not create it.
                    dismissedLibraryID: { host.libraryManager.getOrCreateDismissedLibrary().id }
                )
            }
            a.onCut = { ids in
                await host.libraryViewModel.cutToClipboard(ids)
            }
            a.onPaste = {
                try? await host.libraryViewModel.pasteFromClipboard()
            }
            a.onRemoveFromAllCollections = { ids in
                // Stage 5d SPLIT: the body lives in
                // `PublicationListMutations.removeFromAllCollections`. The
                // store's `removeFromCollection` posts a `.structural` event,
                // so the list refresh is the subscription's — not this closure's.
                PublicationListMutations.removeFromAllCollections(ids: ids)
            }
            a.onFileDrop = { _, _ in
                // TODO: implement file drop with Rust store (FileDropHandler needs UUID-based API)
            }
        }
        a.onToggleRead = { id in
            let store = RustStoreAdapter.shared
            let pub = store.getPublication(id: id)
            store.setRead(ids: [id], read: !(pub?.isRead ?? false))
        }
        a.onCopy = { ids in
            await host.libraryViewModel.copyToClipboard(ids)
        }
        a.onAddToLibrary = { ids, targetLibraryID in
            // Multi-library membership via Contains edges — no duplicate item created.
            RustStoreAdapter.shared.libraryAddMembers(libraryId: targetLibraryID, publicationIds: Array(ids))
        }
        a.onAddToScixLibrary = { ids, scixLibraryID in
            RustStoreAdapter.shared.addToScixLibrary(publicationIds: Array(ids), scixLibraryId: scixLibraryID)
        }
        a.onAddToCollection = { ids, collectionID in
            RustStoreAdapter.shared.addToCollection(publicationIds: Array(ids), collectionId: collectionID)
        }
        a.onOpenPDF = { id in
            host.openPDF(id)
        }
        a.onListDrop = host.onListDrop
        a.onDownloadPDFs = host.onDownloadPDFs
        if source.isInboxScope {
            a.onSaveToLibrary = { ids, targetLibraryID in
                saveToLibrary(ids: ids, targetLibraryID: targetLibraryID, host: host)
            }
            a.onMuteAuthor = { authorName in
                muteAuthor(authorName)
            }
            a.onMutePaper = { id in
                mutePaper(id)
            }
        }
        a.onDismiss = { ids in
            dismissFromInbox(ids: ids, host: host)
        }
        a.onToggleStar = { ids in
            guard !ids.isEmpty else { return }
            // Determine the action: if ANY are unstarred, star ALL; otherwise unstar ALL
            let anyUnstarred = host.rows().filter { ids.contains($0.id) }.contains { !$0.isStarred }
            RustStoreAdapter.shared.setStarred(ids: Array(ids), starred: anyUnstarred)
        }
        // ADR-025: the mirror verb exists only while a device in individual
        // mode is configured. Read at build time (inside the host's body) so
        // the observable model re-evaluates the actions bag when the mode flips.
        if EInkMirrorModel.shared.showsIndividualControls {
            a.onToggleEink = { ids in
                toggleEink(ids, rows: host.rows())
            }
        }
        a.onSetFlag = { ids, color in
            guard !ids.isEmpty else { return }
            RustStoreAdapter.shared.setFlag(ids: Array(ids), color: color.rawValue)
        }
        a.onClearFlag = { ids in
            guard !ids.isEmpty else { return }
            RustStoreAdapter.shared.setFlag(ids: Array(ids), color: nil)
        }
        a.onAddTag = { ids in
            host.beginTagInput(ids)
        }
        a.onRemoveTag = { _, _ in
            // TODO: implement tag removal by tagID with Rust store
            // The Rust store uses tag paths, not tag UUIDs. Need to look up the tag path from tagID.
        }
        a.onGlobalSearch = {
            ImbibSearchAction.localFind(source: .toolbarButton).post()
        }
        a.onRefresh = host.onRefresh
        return a
    }

    /// Toggle the reMarkable mirror mark: if ANY of `ids` is unmirrored,
    /// mirror ALL; otherwise unmirror ALL (the star rule). The adapter logs the
    /// outcome and fans out `.itemsMutated(kind: .einkMirror)` for the rows
    /// that changed, which is what refreshes the row marker.
    static func toggleEink(_ ids: Set<UUID>, rows: [PublicationRowData]) {
        guard !ids.isEmpty, EInkMirrorModel.shared.showsIndividualControls else { return }

        let anyUnmirrored = rows.filter { ids.contains($0.id) }.contains { $0.einkState == nil }
        if anyUnmirrored {
            RustStoreAdapter.shared.einkMark(ids: Array(ids))
        } else {
            RustStoreAdapter.shared.einkUnmark(ids: Array(ids))
        }
    }

    // MARK: - Save / dismiss (Inbox triage from the menu)

    /// Save publications to a target library (adds to target AND removes from
    /// the source). Advances the selection past them for rapid triage.
    private static func saveToLibrary(
        ids: Set<UUID>, targetLibraryID: UUID, host: PublicationListActionsHost
    ) {
        // The next row is read from the visual order BEFORE anything moves.
        let nextID = host.nextSelection(ids)

        // Track dismissal for inbox papers to prevent reappearance in feeds.
        // Stage 5d SPLIT: `PublicationListMutations.trackInboxDismissals`. It is
        // a separate verb from `save` because it has to run BEFORE the selection
        // advance below, and the advance writes the host's selection.
        PublicationListMutations.trackInboxDismissals(ids: ids, source: host.source)

        // Advance selection BEFORE mutation
        host.select(nextID)

        // Delink from the feed, then move. Stage 5d SPLIT:
        // `PublicationListMutations.save`.
        PublicationListMutations.save(ids: ids, to: targetLibraryID, source: host.source)
    }

    /// Dismiss publications (context menu) — moves to the Dismissed library,
    /// never deletes.
    private static func dismissFromInbox(ids: Set<UUID>, host: PublicationListActionsHost) {
        // Compute and advance selection BEFORE mutation
        host.select(host.nextSelection(ids))

        // Track the dismissal, delink from the feed, move to Dismissed.
        // Stage 5d SPLIT: `PublicationListMutations.dismiss` — iOS's copy of this
        // sequence skipped the tracking, so a paper dismissed on a phone came
        // back on the next feed refresh.
        let dismissedLibrary = host.libraryManager.getOrCreateDismissedLibrary()
        PublicationListMutations.dismiss(
            ids: ids, source: host.source, dismissedLibraryID: dismissedLibrary.id)
    }

    // MARK: - Mute

    /// Mute an author
    private static func muteAuthor(_ authorName: String) {
        _ = RustStoreAdapter.shared.createMutedItem(muteType: "author", value: authorName)
        logger.info("Muted author: \(authorName)")
    }

    /// Mute a paper (by DOI, arXiv ID, bibcode, or cite key)
    private static func mutePaper(_ publicationID: UUID) {
        let store = RustStoreAdapter.shared
        guard let pub = store.getPublication(id: publicationID) else { return }

        let doi = pub.doi?.isEmpty == false ? pub.doi : nil
        let arxivId = pub.arxivID?.isEmpty == false ? pub.arxivID : nil
        let bibcode = pub.bibcode?.isEmpty == false ? pub.bibcode : nil
        let citeKey: String? = pub.citeKey.isEmpty ? nil : pub.citeKey

        guard doi != nil || arxivId != nil || bibcode != nil || citeKey != nil else {
            logger.warning("Cannot mute paper - no identifiers available")
            return
        }

        _ = store.dismissPaper(doi: doi, arxivId: arxivId, bibcode: bibcode, citeKey: citeKey)
        logger.info("Muted paper: DOI=\(doi ?? "nil"), arXiv=\(arxivId ?? "nil"), bibcode=\(bibcode ?? "nil"), citeKey=\(citeKey ?? "nil")")
    }
}
#endif
