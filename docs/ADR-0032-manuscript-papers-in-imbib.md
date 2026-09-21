# ADR-0032 — A manuscript's papers live in imbib, not in a panel inside imprint

- **Status**: accepted, implemented 2026-09-12
- **Supersedes**: the Papers side panel added to imprint's Source-tab inspector on
  2026-09-11 (`ManuscriptPapersPanel`, `ManuscriptReadingListModel`,
  `ReferencePDFWindow` — all deleted here)
- **Related**: ADR-0018 (thin-twin chassis), ADR-0022 (collection kernel),
  ADR-0030 (manuscript projects)

## Context

imprint grew a Papers panel so an author could see the manuscript's references
while writing: a list of what it cites plus what had been collected for it, with
Info / PDF / Notes / BibTeX below the selection, a PDF download when one was
missing, a full-screen PDF on the second display, and ⌘F search across the whole
imbib catalog.

Every one of those is something imbib already does, better, in its own list and
detail pane. The panel was a second implementation of imbib inside imprint:
its own row model with its own ordering, its own inspector tabs, its own PDF
acquisition path over imbib's HTTP API, its own catalog search, its own reveal
link and its own full-screen PDF window — about 1,200 lines whose only reason to
exist was that it lived in the wrong process. Two implementations of one
capability drift; the question is only when someone notices.

It also split the author's mental model in two. Curating a collection in imbib
and choosing references for a manuscript are the same act on the same rows, but
the panel made them two different surfaces with two different vocabularies.

## Decision

**A manuscript's papers are an imbib collection, and imbib shows it.**

1. **One scope.** The manuscript's papers collection (an ordinary imbib
   collection carrying `manuscript_ref` in its payload — unchanged from the
   panel's design) holds *both* what the author collected and what the
   manuscript cites. `impress_core::manuscript_reading_list::sync_reading_collection`
   folds the cited papers in; it is idempotent and additive, so a paper the
   author deliberately removed only returns if the text still cites it.
   Cite keys imbib has no paper for cannot be shown as papers, so the sync
   *reports* them (`missing_cite_keys`) and the window names them in a sheet.

2. **One surface.** `ManuscriptPapersWindow` is an imbib window — imbib's list
   (`UnifiedPublicationListWrapper`) and imbib's detail pane (`DetailView`), no
   sidebar — scoped to that collection, with a scope toggle to the whole catalog
   so a paper can *join* the manuscript without leaving the window. Rows, the
   context menu, the filter field, sorting, triage keys, PDF acquisition and the
   full-screen PDF are imbib's, unmodified. The window adds exactly two things
   the library does not have: **Cite** (⏎, ⌘⏎ to hand the keyboard back to
   imprint) and **Keep for this manuscript**.

3. **One insertion path.** `ManuscriptCitationInserter` (in PMC) is a registry
   of live manuscript editors. `SourceEditorView` registers while it is mounted;
   anything outside the editor — imbib's window over HTTP, imprint's menu item,
   an `imprint://insert/citation/…` URL, an agent — asks it to write at the
   caret in the document's own syntax and gets told whether it landed. It
   replaced two half-built channels that both reported success while doing
   nothing: `POST /api/documents/{id}/insert-citation` posted a notification
   with no observer, and `ImpressURL.insertCitation` built a URL imprint never
   handled. "imprint has no open editor for that manuscript" is now a real,
   distinguishable answer (HTTP 409).

4. **imprint keeps the writing surfaces only.** The editor keeps the inline
   citation palette (⌘S / typing `@`) and the cite-key hover preview — those are
   text affordances, not a library. "Papers" (⌥⌘R, the Papers button in the editor's footer bar,
   `ManuscriptPapersCommand`) syncs the collection from the **live buffer** —
   the only place unsaved citations exist — and opens imbib's window on it.

## Consequences

- One list, one ordering, one inspector, one PDF path. imbib's improvements
  reach the manuscript workflow for free; imprint cannot drift from them.
- A paper cited from the catalog joins the manuscript's collection as a side
  effect of citing it, so the window's scope stays the manuscript's paper set
  without a separate bookkeeping step.
- The window is a second process away from the editor. That is the cost: citing
  needs imbib running (the URL launches it) and imprint holding the manuscript
  open (else a 409 that says so). In exchange, the same window is reachable by
  an agent (`imbib-app-service_open-manuscript-papers`) and by URL.
- Recency ordering: the panel ordered rows "recently viewed first" from
  `last_activity_at`, and **imbib's list already offers exactly that order** —
  `LibrarySortOrder.recentActivity` ("Recently Used", sort key `last_activity`),
  in every scope, pushed down to SQL with a deterministic secondary sort so
  paging cannot reshuffle it. (An earlier draft of this ADR claimed the sort
  was missing; it was not, and
  `recency_sort_orders_a_collection_and_a_library` in imbib-core now pins the
  behaviour for a collection as well as a library.) The papers window opens on
  it (`UnifiedPublicationListWrapper.initialSortOrder`) and the author's own
  choice for that collection wins afterwards, because the list restores its
  saved sort per `source.listViewID`. Viewing a paper in the window feeds the
  stamp like anywhere else — `DetailView` applies
  `publicationDetailLifecycle`, whose dwell-gated `recordRecentView` is the
  only writer of `last_activity_at` besides a hand-add. Checking this found one
  scope where the sort menu was decorative: a `.combined` multi-library
  selection (what the window's "All papers" becomes with more than one library)
  merged its children and sorted by date-added whatever was asked. Fixed with a
  total comparator; the merged cache is now keyed by sort.
- `ReferencePDFWindow` is gone; imbib's own full-screen PDF (`P` in the detail
  pane, second display aware) does the job it was cloning.

## Verification

Rust: `sync_reading_collection` unit tests (folds + idempotent, keeps
hand-collected rows, makes a collection for a manuscript that cites nothing) and
a `project-sync-reading-collection` verb test. Swift:
`ManuscriptPapersSeamTests` (citation text per format, the registry's
outcomes — inserted / no editor / refused / nothing to insert, recency, the
palette hook, the cite-key scan, and imprint's URL parsed by imbib's own
parser). Live, 2026-09-12: `POST /api/manuscripts/<id>/papers-window` opened the
window on a new collection holding the one cited paper imbib had and reported
`ZZNoSuchKey2020` as missing; `POST /api/documents/<id>/insert-citation` wrote
`@KussMarsh2021 @YavetzLiHui2022` at the caret and answered `inserted: true`;
the same call for a manuscript with no editor answered 409 with the reason.
