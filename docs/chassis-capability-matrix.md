# Chassis Capability Matrix

The enumerable checklist behind "Consistency Creates Capability": every sidebar
node kind and list-row kind × every interaction it should support. A cell is
one of ✅ (works — with the proving mechanism), ➖ (not applicable by design),
or ❌ (missing — a bug or planned work). **Definition of done for any new node
or row kind: its row here is filled in, and ❌ cells have an issue or a plan.**

How to verify a cell: prefer a selftest capability (`cargo run -p
imprint-selftest -- --tier a|b`), else a console log assertion
(`/api/logs?category=sidebar|manuscripts` on imbib :23120 / imprint :23121),
else a manual step listed in the cell's footnote.

Sources of truth: `ImbibSidebarViewModel` (`capabilities(of:)`,
`buildContextMenu`, `canAcceptDrop`, `handleReorder/Reparent/Rename/DeleteKey`,
`handleExternalDrop`) and the list wrappers (`UnifiedPublicationListWrapper`,
`ManuscriptListWrapper`).

## Sidebar node kinds

| Node kind | Context menu | Rename | Delete | Drag | Drop target | Counts | Notes |
|---|---|---|---|---|---|---|---|
| `section(.inbox)` | ✅ Add Feed / New Collection | ➖ | ➖ | ✅ reorder | ✅ pubs, expl. search→feed | ✅ | |
| `section(.libraries)` | ✅ New Library | ➖ | ➖ | ✅ reorder | ➖ | ➖ | |
| `section(.manuscripts)` | ✅ New Folder | ➖ | ➖ | ✅ reorder | ✅ folder→root | ➖ | added 2026-07 |
| `section(.figures)` | ✅ New Folder | ➖ | ➖ | ✅ reorder | ✅ folder→root | ➖ | Stage 2-B; visibility is a pragmatic appID gate (`shouldShowSection` returns `shellConfiguration.appID == "implore"`) so imbib (visibleSections = nil) never shows it |
| `section(.mail)` | ❌ none (no folder CRUD — IMAP owns folder lifecycle; Stage-2-A2 follow-up) | ➖ | ➖ | ✅ reorder | ➖ | ➖ | Stage 2-A; visibility is the same pragmatic appID gate as Figures (`shouldShowSection` returns `shellConfiguration.appID == "impart"`) so imbib (visibleSections = nil) never shows it |
| `section(.agents)` | ❌ none (no task creation — the kernel schedules tasks; commands stay on impel's HTTP path) | ➖ | ➖ | ✅ reorder | ➖ | ➖ | Stage 2-C; visibility is the same pragmatic appID gate as Figures/Mail (`shouldShowSection` returns `shellConfiguration.appID == "impel"`) so imbib (visibleSections = nil) never shows it |
| `section(.search)` | ✅ Show Hidden Forms | ➖ | ➖ | ✅ reorder | ➖ | ➖ | imbib only |
| `section(.flagged)` | ➖ | ➖ | ➖ | ✅ reorder | ➖ | ✅ | counts = pubs (imbib) / manuscripts (imprint) |
| `library` | ✅ full | ✅ | ✅ confirm | ✅ | ✅ pubs, collections | ✅ | |
| `libraryCollection` | ✅ Rename/Subcoll/Delete | ✅ | ✅ (no confirm, single) | ✅ | ✅ pubs, reparent | ✅ | parent_id regression fixed 2026-07 |
| `manuscriptFolder` | ✅ Rename/Subfolder/Delete | ✅ (needs `makeIfNecessary: true` + ancestor expand in `beginEditingNode`) | ✅ (⌫ + menu) | ✅ reorder+reparent | ✅ manuscripts, folders | ✅ | added 2026-07 |
| `figureFolder` | ✅ Rename/Subfolder/Delete | ✅ | ✅ (⌫ + menu; children reparented to root first) | ✅ reorder+reparent | ✅ figures, folders | ✅ | Stage 2-B; nests via envelope `parent` (NOT payload parent_collection_ref); reparent/moves via SharedStore.setParent (FigureStoreReader), rename via generic updateField "name", reorder via updateIntField sort_order |
| `figuresAll` | ❌ none | ➖ | ➖ | ➖ | ➖ | ✅ total | fixed row |
| `figuresUnfiled` | ❌ none | ➖ | ➖ | ➖ | ✅ figures (clears folder) | ✅ | fixed row |
| `mailAllInboxes` | ❌ none | ➖ | ➖ | ➖ | ➖ | ✅ sum of inbox-role folder counts (`countItems` per folder) | Stage 2-A fixed row; capabilities `.readOnly` |
| `mailAccount` | ❌ none | ➖ IMAP-owned | ➖ IMAP-owned | ❌ no reorder in v1 | ➖ | ➖ | Stage 2-A; selecting lists the account's inbox-role folder (v1 simplification); folders are tree children (role order inbox/drafts/sent/archive/trash/spam, then customs) |
| `mailFolder` | ❌ none | ➖ IMAP-owned | ➖ IMAP-owned | ❌ no reorder in v1 | ❌ no drop — moving mail = IMAP move, not store setParent (Stage-2-A2) | ✅ `countItems` parentId | Stage 2-A; capabilities `.readOnly` |
| `agentTasksAll` | ❌ none | ➖ kernel-owned | ➖ kernel-owned | ➖ | ➖ | ✅ `countItems` task@1.0.0 total | Stage 2-C fixed row; capabilities `.readOnly`; per-state smart children (queued/running/waiting_review/completed/failed/cancelled) as tree children, shown only when non-empty |
| `agentTaskState` | ❌ none | ➖ | ➖ | ➖ | ➖ | ✅ `countItems` payloadEq state | Stage 2-C; smart child of Tasks; capabilities `.readOnly` |
| `agentRunsAll` | ❌ none | ➖ runs are immutable provenance | ➖ | ➖ | ➖ | ✅ `countItems` agent-run@1.0.0 total | Stage 2-C fixed row; capabilities `.readOnly` |
| `dismissed` (imprint) | ❌ none | ➖ | ➖ | ➖ | ➖ | ✅ | lists status=dismissed manuscripts; restore/delete from rows |
| `customSurface` (WP-X0) | ➖ by design | ➖ | ➖ | ➖ | ➖ | ➖ | app-owned whole-pane view; rendered full-pane (no split/toolbar). Design note: implemented as top-level sidebar NODES + `ImbibTab.customSurface`/`ImbibContentRoute.customSurface`, NOT as `SidebarSectionType` cases — the section enum's String rawValue backs persisted order state and widening it would ripple every section switch. |
| `inboxFeed` / `libraryFeed` | ✅ | ✅ | ✅ | ➖ | ➖ | ✅ | |
| `inboxCollection` | ✅ | ✅ | ✅ | ➖ | ✅ pubs | ✅ | |
| `searchForm` | ✅ Hide | ➖ | ➖ | ✅ reorder | ➖ | ➖ | |
| `flagColor` | ❌ none | ➖ | ➖ | ✅ reorder | ➖ | ✅ | |
| `scixLibrary` | ✅ full | ➖ (Edit sheet) | ✅ confirm | ✅ reorder | ✅ pubs | ✅ | |
| `explorationSearch` | ✅ Delete | ➖ | ✅ | ✅ (→Inbox = feed) | ➖ | ✅ | |
| `explorationCollection` | ✅ Delete | ➖ | ✅ | ✅ | ➖ | ✅ | |
| `journalAll` / `journalByStatus` | ❌ none | ➖ | ➖ | ➖ | ➖ | ❌ deferred (async counts) | fixed rows |
| `journalSubmissions` | ❌ none | ➖ | ➖ | ➖ | ➖ | ➖ | hidden in imprint |
| `manuscript` (deep-link node) | ❌ none | ➖ | ➖ | ➖ | ➖ | ➖ | search results |
| `allArtifacts` / `artifactType` | ❌ none | ➖ | ➖ | ➖ | ✅ files/URLs | ✅ | |

## List row kinds

| Row kind | Select→detail | Multi-select | Context menu | Drag | Keyboard | Delete flow |
|---|---|---|---|---|---|---|
| Publication (`MailStylePublicationRow`) | ✅ `.id(source.viewID)` | ✅ Set + combined BibTeX | ✅ full (flag/tag/collections/…) | ✅ multi, cross-app ref | ✅ j/k + guarded | soft-delete → Dismissed, Undo |
| Manuscript (`ManuscriptListWrapper`) | ✅ `.id(scope)` only (no pane `.id` — rebuilding the NSTextView made selection sluggish) | ✅ Set, primary drives detail | ✅ Open/Duplicate/Star/Archive/Flag/Tags/Folder/Delete | ✅ multi → folders (pasteboard + `ManuscriptDragSession` fallback) | ✅ j/k/n/s guarded | confirm alert → hard delete + Undo, session discarded; swipe = archive (status) / delete |
| Artifact | ✅ | ❌ | partial | ❌ | ✅ | ✅ |
| Figure (`FigureListWrapper`) | ✅ `.id(scope)` | ✅ Set, primary drives detail | ✅ Open in Canvas/Star/Flag/Tags/Folder/Delete (shared TriageMenu) | ✅ multi → folders/Unfiled (pasteboard `com.impress.figure-id` + `FigureDragSession` fallback) | ✅ j/k/s/o// via TriageKeyGrammar (n, d ignored — no create/dismiss capability) | confirm alert → hard delete + Undo (no session to discard) |
| Message (`MessageListWrapper`) | ✅ `.id(scope)`; rows collapse to newest-per-thread with "(n)" badge (no expand/collapse chevrons in v1 — badge + thread view in the detail pane's Info tab) | ✅ Set, primary drives detail | ✅ Star/Flag/Tags only (shared TriageMenu; no dismiss/archive/delete — IMAP-owned) | ❌ no drag in v1 — moving mail = IMAP move, not store setParent (Stage-2-A2) | ✅ j/k/s/o// via TriageKeyGrammar (n ignored — compose stays in the classic window; d ignored — no dismissal capability) | ❌ none — mail deletion goes through IMAP flows, never the store (deletion `.none`; Stage-2-A2) |
| Task (`AgentRecordListWrapper`, scope tasks/tasksByState) | ✅ `.id(scope)`; header = humanized kernel state, badge = assigned_to, envelope unread dot kept | ✅ Set, primary drives detail | ✅ Star/Flag/Tags only (shared TriageMenu; no dismiss/archive/delete — state moves ONLY through TaskStoreApi.transition, kernel-owned) | ➖ no drag — tasks have no folder tree | ✅ j/k/s/o// via TriageKeyGrammar (n ignored — the kernel schedules tasks; d ignored — no dismissal capability) | ➖ none — kernel-owned lifecycle (deletion `.none`) |
| AgentRun (`AgentRecordListWrapper`, scope runs) | ✅ `.id(scope)`; header = agent_id, title = result_summary first line ?? model, badge = "N tok · Ss" | ✅ Set, primary drives detail | ✅ Star/Flag/Tags only (shared TriageMenu) | ➖ no drag | ✅ j/k/s/o// via TriageKeyGrammar (n, d ignored — runs are immutable provenance) | ➖ none — immutable provenance records |

## Detail tabs by item kind (`DetailTab.available(for:)`)

| Kind | Tabs |
|---|---|
| publication (editable) | Info, PDF, Notes, BibTeX |
| publication (read-only) | Info, PDF, BibTeX |
| manuscript typst/latex | Info, Source, Preview (compiled PDF) |
| manuscript markdown | Info, Source, Preview (MarkdownUI, live) |
| manuscript plaintext | Info, Source |
| figure with data_hash | Info, View (pdf tab relabeled; NSImage renders PNG/JPEG/PDF, other formats show an "open in canvas" hint) |
| figure without data_hash | Info |
| message | Info (headers + thread membership, tap to switch), Source (raw plain-text body, monospaced), View (pdf tab relabeled: body typeset at ~680pt measure — plain text only, NO WebKit in PMC; HTML mail stays in impart's classic window) — all always available |
| task | Info (state/assignee/description/dates + latest-run provenance), Source (description/prompt text, monospaced), View (pdf tab relabeled: LATEST run's result_summary rendered with MarkdownUI; honest empty state before any run) — all always available |
| agent-run | Info (agent/model/prompt-hash, tokens, duration, dates), Source (raw result_summary, monospaced), View (pdf tab relabeled: result_summary rendered with MarkdownUI) — all always available |

## Record-kind descriptor contract (Stage 1 regression oracle)

Frozen from current behavior 2026-07-26 — the descriptor retrofit must
reproduce every cell exactly. This table becomes the DoD surface for
`RecordKindDescriptor` (see ADR-0021): a new kind adds a row here.

| Kind | schemaRefs | Tabs (availability) | Star | Flag | Tag | Dismiss semantics | Archive | Delete semantics | Create | Open behavior |
|---|---|---|---|---|---|---|---|---|---|---|
| publication | imbib/bibliography-entry | info, pdf, notes (editable only), bibtex | ✅ | ✅ | ✅ | library-move → Dismissed library (never re-enters inbox) | ➖ | soft (move to Dismissed); hard only from Dismissed | import/search | detail pane; handoff n/a |
| manuscript | manuscript | info, source, pdf-as-Preview (hidden for plaintext) | ✅ | ✅ | ✅ | status=dismissed (restore→draft) | status=archived | confirm alert → hard delete + undo, session discarded first | n (format menu: typst/latex/markdown/plaintext) | imprint: window "manuscript-editor"; imbib: app handoff imprint:// |
| artifact | artifact schemas | info (+type-specific) | ❌ | partial | ✅ | ➖ | ➖ | ✅ | detail pane |
| figure | figure | info, pdf-as-View (hidden without data_hash; presence encoded via RecordTabContext.previewKind = compiledPDF/none) | ✅ | ✅ | ✅ | ➖ (no status field today) | ➖ | confirm alert → hard delete + undo | ➖ (canvas/generators create) | window "canvas" (value = figure id string) |
| message | email-message, chat-message | info, source, pdf-as-View (all always available) | ✅ | ✅ | ✅ | ➖ (no status field; `.statusChange` would be wrong — lifecycle is IMAP-owned; archive-to-folder is a Stage-2-A2 follow-up) | ➖ | ➖ `.none` — deletion goes through impart's IMAP flows, never the store | ➖ compose stays in impart's classic window (v1) | detail pane |
| task | task@1.0.0 (VERSIONED — impel-core TaskStoreApi) | info, source (description/prompt), pdf-as-View (latest run's result_summary via MarkdownUI; all always available) | ✅ | ✅ | ✅ | ➖ `.none` — task state moves ONLY through `TaskStoreApi.transition` (kernel-owned, ADR-0015 D1; a `.statusChange` dismissal would bypass the kernel; `statuses` declared empty because the lifecycle lives in payload `state`, not the chassis `status` machinery) | ➖ | ➖ `.none` — kernel-owned | ➖ scheduled by impel-taskd/counsel, never `n` | detail pane |
| agent-run | agent-run@1.0.0 | info, source (raw result_summary), pdf-as-View (MarkdownUI; all always available) | ✅ | ✅ | ✅ | ➖ immutable provenance record (ADR-0005 §5) | ➖ | ➖ `.none` | ➖ recorded by the kernel | detail pane |

Frozen shell-preset truth table (AppShellConfiguration v2 parity target):

| Derived value | imbib | imprint | implore (Stage 2-B) | impart (Stage 2-A) | impel (Stage 2-C) |
|---|---|---|---|---|---|
| showsSubmissionsInbox | true | false | false | false | false |
| flagsShowManuscripts | false | true | false | false | false |
| opensManuscriptsInProcess | false | true | false (n/a) | false (n/a) | false (n/a) |
| dismissedShowsManuscripts | false | true | false (n/a) | false (n/a) | false (n/a) |
| visibleSections | all | manuscripts, citedInManuscripts, flagged, dismissed | figures only (Flagged deliberately skipped in v1 — needs a `.flagged: .figure` binding + routing) | mail only (Flagged deliberately skipped in v1 — needs a `.flagged: .message` binding + routing) | agents only (Flagged deliberately skipped in v1 — needs a `.flagged: .task` binding + routing) |
| defaultSection / defaultDetailTab | inbox / info | manuscripts / source | figures / info | mail / info | agents / info (lands on the Tasks leaf) |
| custom surfaces | — | — | generate, analyze (registered app-side via `withCustomSurfaces`); canvas = figure open window | chat, research, development (registered app-side via `withCustomSurfaces` in ImpartChassisRoot) | dashboard, escalations, suggestions, counsel (registered app-side via `withCustomSurfaces` in ImpelChassisRoot; escalations keeps its 1-9/j/k keys INSIDE the surface, keyboardGuarded) |
| default window | chassis | chassis | chassis | classic ContentView — chassis is a SECONDARY "Mail (Unified)" window; flips via UserDefaults `impart.useChassisWindow` (compose/reply not chassis-wired yet — the one sanctioned deviation from replace-outright) | classic ContentView — chassis is a SECONDARY "impel (Unified)" window; flips via UserDefaults `impel.useChassisWindow` (escalation resolution / counsel not chassis-wired yet — same sanctioned deviation as impart) |

## Known gaps (tracked)

- **Mail (Stage 2-A) IMAP-owned gaps — Stage-2-A2 follow-ups:** no message
  drag (move = IMAP move), no folder CRUD (IMAP owns folder lifecycle), no
  compose from the chassis ("compose stays in classic window"), no
  delete/dismiss (descriptor `.none`/`.none`; `d` returns `.ignored`), no
  mark-read on select (read-state syncs over IMAP, not the store), and no
  thread expand/collapse in the list (badge + detail-pane thread view only).
  Also: IMAP-driven store writes land through impart's OWN SharedStore handle
  (MessageManagerCore), so the chassis list only refreshes on in-process
  StoreEvents (star/flag/tag) or scope change/relaunch.

- **Agents (Stage 2-C) kernel-owned gaps — by design, kill criterion NOT
  triggered (the section landed entirely on existing seams: descriptors +
  the node/tab/route case-addition pattern; no structural chassis change):**
  no task creation from the chassis (`n` ignored; impel-taskd/counsel
  schedule tasks), no dismiss/archive/delete (descriptors `.none`/`.none`;
  `TaskStoreApi.transition` is the sole legal state mutation and stays on
  impel's HTTP command path), no state transitions from rows, no drag (no
  folder tree), and runs are immutable provenance. Kernel-driven store
  writes (transitions, new runs) land through impel's OWN SharedStore
  handle, so the chassis list only refreshes on in-process StoreEvents
  (star/flag/tag) or scope change/relaunch — same documented v1 limit as
  mail. Task↔run linkage is typed edges (`ProducedBy`) resolved via
  `getItemReferences`, not parentId.

- `flagColor` nodes have no context menu (e.g. "Clear all red flags").
- Journal fixed rows have no counts (needs async count snapshot).
- Artifact rows: no multi-select, no drag.
- Manuscript folder bulk delete has no batch mutation wrapper (N sequential
  deletes; fine at current scale).
- Tree-sitter grammar for Markdown highlighting not vendored yet
  (`ImpressSyntaxHighlight` renders md/txt unhighlighted).
- **Publication KEY parity resolved (Stage 3, 2026-07-27):** default s=star,
  d=dismiss (save→`*`), via KeyboardShortcutsStore defaults — remappable,
  user overrides preserved. Swipe/menu STYLING remains publication-specific:
- **Publication list NOT yet on the shared triage swipe/menu builders (deliberate).**
  `UnifiedPublicationListWrapper`/`MailStylePublicationRow`/`PublicationListView`
  keep their own keys (remappable via `KeyboardShortcutsStore`, `s`=save in
  inbox flows), swipes (Save/Star/Read leading), and menu (icons, TagInput
  overlay). Mechanically adopting `TriageKeyGrammar`/`TriageSwipe`/`TriageMenu`
  would change imbib behavior/appearance, violating the Stage-1 zero-diff
  rule. Convergence happens with the Stage-2 keyboard-parity switch, where
  `s`→star / `d`→dismiss for publications is a sanctioned behavior change.
  New record kinds (message/figure/agent) MUST use the shared builders.
- Tier B has no manuscript-CRUD capability: `POST /api/documents/create` in
  `ImprintHTTPRouter` is a non-persisting stub (pre-chassis leftover) and
  `impress-app-client`'s `ImprintClient` has no create method. Fix the route
  to call `ManuscriptStoreAdapter.createManuscript` (accepting `format`), add
  the typed client method, then an `app.manuscript_crud` Tier-B capability
  (create → appears in list → three-point trace via `/api/logs/stream`).
  Tier A coverage exists today (`store.manuscript_formats` + imbib-core
  `manuscript_unification` tests).
