//
//  PublicationListMutations.swift
//  PublicationManagerCore
//
//  Stage 5d (SPLIT rule) — the COMPOSITE triage verbs, once.
//
//  ## What was duplicated, and what it cost
//
//  Delete, dismiss and save are not single store calls. Each is a sequence with
//  invariants attached, and each host wrote its own sequence. The macOS one is
//  the complete one; iOS's dropped steps, and every dropped step is a documented
//  invariant of this app:
//
//  1. **`handleDelete` destroyed data.** iOS called
//     `deletePublications(ids:)` unconditionally, from every scope. macOS
//     soft-deletes: everything except the Dismissed library itself MOVES to
//     Dismissed, which is what `docs/chassis-capability-matrix.md`'s publication
//     row promises ("soft-delete → Dismissed, Undo"). Deleting a paper from a
//     library on iPhone was unrecoverable and looked exactly like the Mac's
//     recoverable one.
//  2. **iOS triage let dismissed papers back into the inbox.** Neither
//     `handleDismiss` nor `handleSaveToLibrary` called
//     `InboxManager.trackDismissal`. That is the app's first Critical Invariant
//     — "Dismissed papers must never re-enter the inbox" (apps/imbib/CLAUDE.md),
//     enforced on the Rust side by `filter_dismissed` and on the Swift side by
//     this exact call. Dismiss a paper on iOS, let a feed refresh, and it came
//     straight back.
//  3. **iOS left the feed's `Contains` edge behind.** macOS delinks the paper
//     from the smart-search collection so the feed empties immediately; iOS only
//     moved the paper, so a triaged row stayed in the smart search's membership
//     and reappeared on the next reload of that scope.
//  4. **iOS mutated one row at a time.** No `beginBatchMutation` /
//     `endBatchMutation`, so a multi-select delete emitted one store event per
//     paper and the list rebuilt once per row.
//
//  The bodies below are macOS's, moved. macOS's own behaviour is unchanged; iOS
//  gains all four.
//
//  ## What is deliberately NOT here
//
//  `setFlag` / `clearFlag` / `toggleRead` / `addToLibrary` / `addToCollection`
//  are single `RustStoreAdapter` calls, already identical on both platforms.
//  Wrapping a one-line call to an already-shared adapter in a second name adds
//  a hop and removes no duplication — there was never a second implementation
//  of those. What was worth sharing is the COMPOSITES, where the duplication was
//  in the sequence, not the call.
//
//  Selection advance is also not here. It reads the visual order and writes the
//  host's bindings (see `PublicationListOrder.nextSelection`), and the two hosts
//  answer it differently on purpose: macOS advances to the next paper because it
//  has a detail pane beside the list; iOS clears the selection because on a
//  phone the split view is a stack and writing a selection PUSHES the detail
//  view over the list the user is triaging in.
//

import Foundation
import OSLog
import ImpressLogging

/// The composite store sequences behind the publication list's triage verbs.
///
/// Every member takes the scope as a value and resolves what it needs from it,
/// so the timing of each store read matches the call site it was moved from
/// (these run inside deferred triage closures, after a 200 ms flash animation).
@MainActor
public enum PublicationListMutations {

    // MARK: - Delete (soft, except out of Dismissed)

    /// Delete `ids` from `source`.
    ///
    /// `permanently` is the ONE decision the caller owns, because the two hosts
    /// identify "the trash" differently: macOS matches `if case .dismissed`,
    /// iOS routes its Dismissed screen through `.library(dismissedLibraryID)`
    /// and compares ids. Everything after that decision is the same sequence.
    ///
    /// `dismissedLibraryID` is a closure so that deleting OUT of Dismissed does
    /// not call `getOrCreateDismissedLibrary()` — resolving it eagerly would
    /// create the library as a side effect of emptying it.
    public static func delete(
        ids: Set<UUID>,
        source: PublicationSource,
        permanently: Bool,
        dismissedLibraryID: () -> UUID
    ) {
        let store = RustStoreAdapter.shared

        if permanently {
            // Dismissed library = Trash: permanently delete
            store.deletePublications(ids: Array(ids))
            return
        }

        // Everything else: move to Dismissed (like macOS Trash)
        let dismissedID = dismissedLibraryID()
        store.beginBatchMutation()

        // Track dismissal for inbox/smart-search papers
        if source.isInboxScope {
            let ssID = source.smartSearchID
            for id in ids {
                InboxManager.shared.trackDismissal(id)
                InboxManager.shared.cleanupDismissedCopies(of: id, ssCollectionID: ssID)
            }
        }

        // SciX libraries: also remove the Contains edge
        if case .scixLibrary(let scixID) = source {
            store.removeFromScixLibrary(publicationIds: Array(ids), scixLibraryId: scixID)
        }

        // Collections: also remove the Contains edge
        if case .collection(let collID) = source {
            store.removeFromCollection(publicationIds: Array(ids), collectionId: collID)
        }

        // Smart searches: remove from collection
        if let ssID = source.smartSearchID {
            store.removeFromCollection(publicationIds: Array(ids), collectionId: ssID)
        }

        store.movePublications(ids: Array(ids), toLibraryId: dismissedID)
        store.endBatchMutation()
    }

    // MARK: - Dismiss

    /// Dismiss `ids` — move to Dismissed, never delete.
    ///
    /// The context-menu / row-action form: unbatched, and it records the
    /// dismissal for every paper regardless of scope, because a paper dismissed
    /// from anywhere must not be re-ingested by a feed later.
    public static func dismiss(
        ids: Set<UUID>,
        source: PublicationSource,
        dismissedLibraryID: UUID
    ) {
        // Track dismissal to prevent reappearance in feeds
        for id in ids {
            InboxManager.shared.trackDismissal(id)
        }

        // Remove Contains edges from smart search collection (immediate feed cleanup)
        if let ssID = source.smartSearchID {
            RustStoreAdapter.shared.removeFromCollection(publicationIds: Array(ids), collectionId: ssID)
        }

        // Move to dismissed library (triggers .storeDidMutate → refresh)
        RustStoreAdapter.shared.movePublications(ids: Array(ids), toLibraryId: dismissedLibraryID)
    }

    /// Dismiss `ids` from a keyboard/swipe triage pass.
    ///
    /// Batched, and it additionally cleans up duplicate copies the feed may have
    /// created (`cleanupDismissedCopies`) — but only for feed scopes, where such
    /// copies exist. Kept distinct from `dismiss(ids:source:dismissedLibraryID:)`
    /// rather than merged behind a flag: the two differ in batching AND in
    /// cleanup, and both call sites are hot triage paths whose store traffic is
    /// deliberate.
    public static func dismissFromFeed(
        ids: Set<UUID>,
        source: PublicationSource,
        dismissedLibraryID: UUID
    ) {
        let store = RustStoreAdapter.shared
        let ssID = source.smartSearchID
        store.beginBatchMutation()
        if source.isFeedScope {
            for id in ids {
                InboxManager.shared.trackDismissal(id)
                InboxManager.shared.cleanupDismissedCopies(of: id, ssCollectionID: ssID)
            }
        }
        store.movePublications(ids: Array(ids), toLibraryId: dismissedLibraryID)
        if let ssID {
            store.removeFromCollection(publicationIds: Array(ids), collectionId: ssID)
        }
        store.endBatchMutation()
    }

    // MARK: - Save

    /// Record that `ids` were triaged out of an inbox scope.
    ///
    /// Separate from `save` because it must run BEFORE the host advances its
    /// selection, and the selection advance is the host's (it writes bindings).
    /// A no-op outside inbox scopes: saving out of a plain library is not a
    /// dismissal and must not suppress the paper in feeds.
    public static func trackInboxDismissals(ids: Set<UUID>, source: PublicationSource) {
        guard source.isInboxScope else { return }
        for id in ids {
            InboxManager.shared.trackDismissal(id)
        }
    }

    /// Save `ids` into `targetLibraryID`: delink from the feed, then move.
    ///
    /// "Save" here is the destructive feed form — the paper LEAVES the source.
    /// The non-destructive form ("also appears in") is
    /// `RustStoreAdapter.libraryAddMembers`, a single call, and is not wrapped.
    public static func save(
        ids: Set<UUID>,
        to targetLibraryID: UUID,
        source: PublicationSource
    ) {
        let store = RustStoreAdapter.shared

        // Remove Contains edges from smart search collection (immediate feed cleanup)
        if let ssID = source.smartSearchID {
            store.removeFromCollection(publicationIds: Array(ids), collectionId: ssID)
        }

        // Move publications to the target library (triggers .storeDidMutate → refresh)
        store.movePublications(ids: Array(ids), toLibraryId: targetLibraryID)
    }

    /// Save `ids` from a keyboard/swipe triage pass into `targetLibraryID`.
    ///
    /// The batched feed form, matching `dismissFromFeed`.
    public static func saveFromFeed(
        ids: Set<UUID>,
        to targetLibraryID: UUID,
        source: PublicationSource
    ) {
        let store = RustStoreAdapter.shared
        let ssID = source.smartSearchID
        store.beginBatchMutation()
        for id in ids {
            InboxManager.shared.trackDismissal(id)
            InboxManager.shared.cleanupDismissedCopies(of: id, ssCollectionID: ssID)
        }
        store.movePublications(ids: Array(ids), toLibraryId: targetLibraryID)
        if let ssID {
            store.removeFromCollection(publicationIds: Array(ids), collectionId: ssID)
        }
        store.endBatchMutation()
    }

    // MARK: - Collection membership

    /// Remove every collection membership edge for each of `ids`.
    ///
    /// The publications themselves are untouched — only `Contains` edges go.
    ///
    /// This body comes from iOS, not macOS: macOS's `onRemoveFromAllCollections`
    /// is still `// TODO: implement removeFromAllCollections with Rust store`,
    /// an empty closure that silently does nothing when the user picks the menu
    /// item. Adopting this here is a one-line change to that closure and a
    /// deliberate BEHAVIOUR change to the frozen macOS pane, so it is left for
    /// the wave that is allowed to make one.
    @discardableResult
    public static func removeFromAllCollections(ids: Set<UUID>) -> Int {
        let store = RustStoreAdapter.shared
        var totalRemovals = 0
        for pubID in ids {
            let colls = store.listCollections(forPublication: pubID)
            Logger.library.infoCapture(
                "removeFromAllCollections: pub \(pubID) is in \(colls.count) collection(s)",
                category: "collections")
            for coll in colls {
                store.removeFromCollection(publicationIds: [pubID], collectionId: coll.id)
                totalRemovals += 1
            }
        }
        Logger.library.infoCapture(
            "removeFromAllCollections: removed \(totalRemovals) membership edge(s) across "
                + "\(ids.count) pub(s)",
            category: "collections")
        return totalRemovals
    }
}
