//
//  PublicationScope.swift
//  PublicationManagerCore
//
//  Stage 5d (SPLIT rule) — the derivations both publication list hosts compute
//  from a `PublicationSource`, in one place.
//
//  ## What was duplicated, and what it cost
//
//  `UnifiedPublicationListWrapper` (macOS) computed `listID`, `isInboxView`,
//  `isFeedView`, `smartSearchLibraryID` and `currentLibraryID` from its
//  `PublicationSource`. `IOSUnifiedPublicationListWrapper` computed the same
//  five things from its OWN `Source` enum — including a hand-written UUID table
//  for `.flagged` scopes, carrying this comment:
//
//      /// Deterministic id for `.flagged` rows — matches the macOS wrapper's
//      /// mapping so saved selection state survives platform transitions.
//
//  **It did not match.** iOS mapped red/amber/blue/gray to
//  `F1A99ED0-000{1,2,3,4}-4000-8000-…`; `PublicationSource.viewID` maps them
//  into `00000000-0000-0000-0000-%012x` by a different colour index (and has no
//  `amber` branch at all — amber takes the UTF-8-sum fallback). Since
//  `listID` keys `ListViewStateStore` (`"flagged_<uuid>"`, holding the scope's
//  saved sort order, ascending flag, unread filter and last selection), the two
//  platforms have been reading and writing DIFFERENT saved state for every
//  flagged scope for as long as both files existed. Nothing failed loudly; the
//  claim in the comment was simply false. A second copy of a "deterministic"
//  id table is a promise no test was keeping.
//
//  Both hosts now read these off the scope. iOS's `Source` enum survives — it
//  carries a display name for `.library` that `PublicationSource` cannot
//  express, which is the whole reason it exists — but it no longer derives ids;
//  it maps to a `PublicationSource` and asks.
//
//  ## What is deliberately NOT one member
//
//  `owningLibraryID` and `libraryIDOrDefaultLibrary` are two policies, not one
//  function with a bug. For a cross-library virtual scope (flagged, recent,
//  cited-in-manuscripts, a SciX library) iOS wants *nil* — there is no library
//  that owns these papers, and iOS uses the answer for attachment paths.
//  macOS wants the default library, because behaviours keyed off it (new-paper
//  landing, drop targets, FTS scoping) need somewhere to put a paper. Merging
//  them would silently change one platform. Both are here, named for what they
//  promise, so a call site picks a policy instead of re-deriving one.
//
//  ADR-0018 D3: this file only adds DERIVATIONS to `PublicationSource`. It adds
//  no cases and admits no non-publication scope — the shared list half consumes
//  the enum, it never widens it.
//

import Foundation

extension PublicationSource {

    // MARK: - Persisted list-state key

    /// The `ListViewStateStore` key for this scope.
    ///
    /// `ListViewID` is narrower than `PublicationSource` (it has no
    /// unread/starred/tag/inbox/dismissed/cited/recent/combined case), so the
    /// scopes it cannot name fall back to `.library(viewID)` — a stable,
    /// scope-specific UUID that no real library can collide with.
    public var listViewID: ListViewID {
        switch self {
        case .library(let id):
            return .library(id)
        case .smartSearch(let id):
            return .smartSearch(id)
        case .collection(let id):
            return .collection(id)
        case .flagged:
            return .flagged(viewID)
        case .scixLibrary(let id):
            return .scixLibrary(id)
        case .unread:
            return .library(viewID)
        case .starred:
            return .library(viewID)
        case .tag:
            return .library(viewID)
        case .inbox(let id):
            return .library(id)
        case .dismissed:
            return .library(viewID)
        case .citedInManuscripts:
            return .library(viewID)
        case .recent:
            return .library(viewID)
        case .combined:
            return .library(viewID)
        }
    }

    // MARK: - Triage classification

    /// The Inbox library, or a smart search whose results feed the inbox.
    ///
    /// Drives `disableUnreadFilter` / `isInInbox` / the save-target resolution
    /// in both hosts.
    @MainActor
    public var isInboxScope: Bool {
        switch self {
        case .inbox:
            return true
        case .smartSearch(let id):
            return RustStoreAdapter.shared.getSmartSearch(id: id)?.feedsToInbox ?? false
        case .library, .collection, .flagged, .scixLibrary, .unread, .starred, .tag, .dismissed,
             .citedInManuscripts, .recent, .combined:
            return false
        }
    }

    /// Any auto-refreshing feed (the inbox, or an auto-refreshing smart search).
    ///
    /// Feed scopes triage destructively: saving or dismissing REMOVES the paper
    /// from the feed and records the dismissal so it cannot come back.
    @MainActor
    public var isFeedScope: Bool {
        if isInboxScope { return true }
        if case .smartSearch(let id) = self {
            return RustStoreAdapter.shared.getSmartSearch(id: id)?.autoRefreshEnabled ?? false
        }
        return false
    }

    /// The smart-search id when this scope IS a smart search.
    ///
    /// Smart-search membership is a `Contains` edge on a collection whose id is
    /// the smart search's, so triage has to delink there as well as move the
    /// paper — this is the id it delinks from.
    public var smartSearchID: UUID? {
        if case .smartSearch(let id) = self { return id }
        return nil
    }

    // MARK: - Owning library (two policies, deliberately)

    /// The library that actually owns these papers, or nil when no single
    /// library does.
    ///
    /// STRICT policy — used where a wrong answer is worse than no answer, e.g.
    /// resolving an attachment path. Cross-library virtual scopes and remote
    /// SciX libraries return nil.
    @MainActor
    public var owningLibraryID: UUID? {
        switch self {
        case .library(let id), .inbox(let id):
            return id
        case .smartSearch(let id):
            return RustStoreAdapter.shared.getSmartSearch(id: id)?.libraryID
        case .collection(let id):
            let store = RustStoreAdapter.shared
            for lib in store.listLibraries() {
                if store.listCollections(libraryId: lib.id).contains(where: { $0.id == id }) {
                    return lib.id
                }
            }
            return nil
        case .scixLibrary:
            return nil  // SciX libraries are remote
        case .flagged, .unread, .starred, .tag, .dismissed, .citedInManuscripts, .recent,
             .combined:
            return nil  // cross-library virtual scope
        }
    }

    /// The library to act *in* for this scope, falling back to the default
    /// library when the scope does not name one.
    ///
    /// FALLBACK policy — used where the caller must have somewhere to put a
    /// paper (drop targets, new-paper landing, FTS library scoping) and "no
    /// library" is not an answer it can act on.
    @MainActor
    public var libraryIDOrDefaultLibrary: UUID? {
        switch self {
        case .library(let id): return id
        case .inbox(let id): return id
        case .scixLibrary(let id): return id
        case .smartSearch(let id):
            return RustStoreAdapter.shared.getSmartSearch(id: id)?.libraryID
                ?? RustStoreAdapter.shared.getDefaultLibrary()?.id
        case .collection, .flagged, .unread, .starred, .tag, .dismissed, .citedInManuscripts,
             .recent:
            return RustStoreAdapter.shared.getDefaultLibrary()?.id
        case .combined:
            // Multi-source: no single "current" library — fall back to default
            // for behaviors keyed off it (e.g., new-paper landing).
            return RustStoreAdapter.shared.getDefaultLibrary()?.id
        }
    }
}
