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
| `section(.manuscripts)` | ✅ New Folder | ➖ | ➖ | ✅ reorder | ✅ folder→root | ➖ | added 2026-07. **imprint-only surface since the 2026-07-27 publications-only purification** — imbib's `visibleSections` no longer contains `.manuscripts`. The chassis code (ManuscriptSectionView, folder block, CollectionStoreAdapter manuscript binding) is UNCHANGED: imprint runs on it |
| `section(.figures)` | ✅ New Folder | ➖ | ➖ | ✅ reorder | ✅ folder→root | ➖ | Stage 2-B; **implore-only surface** — excluded by every other preset's `visibleSections` (imbib's became explicit 2026-07-27). The pragmatic appID gate stays as belt-and-braces for any shell that leaves `visibleSections` nil — since ADR-0022 G8 it is an owner SET, `{implore, impress}` (`AppShellConfiguration.facetOwnerAppIDs`), not an `appID ==` test: with equality the impress preset could permit the section and the sidebar would still drop it |
| `section(.mail)` | ❌ none (no folder CRUD — IMAP owns folder lifecycle; Stage-2-A2 follow-up) | ➖ | ➖ | ✅ reorder | ➖ | ➖ | Stage 2-A; **impart-only surface** — same double gate as Figures (`visibleSections` everywhere else + `shouldShowSection` owner set `{impart, impress}`) |
| `section(.agents)` | ❌ none (no task creation — the kernel schedules tasks; commands stay on impel's HTTP path) | ➖ | ➖ | ✅ reorder | ➖ | ➖ | Stage 2-C; **impel-only surface** — same double gate as Figures/Mail (`visibleSections` everywhere else + `shouldShowSection` owner set `{impel, impress}`) |
| `section(.search)` | ✅ Show Hidden Forms | ➖ | ➖ | ✅ reorder | ➖ | ➖ | imbib only |
| `section(.flagged)` | ➖ | ➖ | ➖ | ✅ reorder | ➖ | ✅ | counts = pubs (imbib) / manuscripts (imprint) |
| `library` | ✅ full | ✅ | ✅ confirm | ✅ | ✅ pubs, collections | ✅ | |
| `libraryCollection` | ✅ Rename/Subcoll/Delete | ✅ | ✅ (no confirm, single) | ✅ | ✅ pubs, reparent | ✅ | parent_id regression fixed 2026-07 |
| `recordFolder(binding: manuscript)` | ✅ Rename/Subfolder/Delete | ✅ (needs `makeIfNecessary: true` + ancestor expand in `beginEditingNode`) | ✅ (⌫ + menu) | ✅ reorder+reparent | ✅ manuscripts, folders | ✅ | G2 (ADR-0022): served by the generic capability-driven folder block over `CollectionStoreAdapter` → Rust `collection_ops` (manuscript binding: payload `parent_collection_ref` + Contains membership); cycle check now Rust-side. **Stage 3: `manuscriptFolder` and `figureFolder` collapsed into ONE node case `recordFolder(bindingID:folderID:)`** — the node carries its kernel BINDING and all eight sites that handle it are total over `CollectionCapability` (`migratedFolderBindings` retired) |
| `recordFolder(binding: figure)` | ✅ Rename/Subfolder/Delete | ✅ | ✅ (⌫ + menu; delete unfiles children via FK `ON DELETE SET NULL`, undo re-files) | ✅ reorder+reparent | ✅ figures, folders | ✅ | G2 (ADR-0022): same generic block, figure binding (ENVELOPE parent + envelope membership); reparent gained Undo it never had. Same single node case as the row above |
| `figuresAll` | ❌ none | ➖ | ➖ | ➖ | ➖ | ✅ total | fixed row |
| `figuresUnfiled` | ❌ none | ➖ | ➖ | ➖ | ✅ figures (clears folder) | ✅ | fixed row |
| `mailAllInboxes` | ❌ none | ➖ | ➖ | ➖ | ➖ | ✅ sum of inbox-role folder counts (`countItems` per folder) | Stage 2-A fixed row; capabilities `.readOnly` |
| `mailAccount` | ❌ none | ➖ IMAP-owned | ➖ IMAP-owned | ❌ no reorder in v1 | ➖ | ➖ | Stage 2-A; selecting lists the account's inbox-role folder (v1 simplification); folders are tree children (role order inbox/drafts/sent/archive/trash/spam, then customs) |
| `mailFolder` | ❌ none | ➖ IMAP-owned | ➖ IMAP-owned | ❌ no reorder in v1 | ❌ no drop — moving mail = IMAP move, not store setParent (Stage-2-A2) | ✅ `countItems` parentId | Stage 2-A; capabilities `.readOnly` |
| `agentTasksAll` | ❌ none | ➖ kernel-owned | ➖ kernel-owned | ➖ | ➖ | ✅ `countItems` task@1.0.0 total | Stage 2-C fixed row; capabilities `.readOnly`; per-state smart children (queued/running/waiting_review/completed/failed/cancelled) as tree children, shown only when non-empty |
| `agentTaskState` | ❌ none | ➖ | ➖ | ➖ | ➖ | ✅ `countItems` payloadEq state | Stage 2-C; smart child of Tasks; capabilities `.readOnly` |
| `agentRunsAll` | ❌ none | ➖ runs are immutable provenance | ➖ | ➖ | ➖ | ✅ `countItems` agent-run@1.0.0 total | Stage 2-C fixed row; capabilities `.readOnly` |
| `dismissed` (imprint) | ❌ none | ➖ | ➖ | ➖ | ➖ | ✅ | lists status=dismissed manuscripts; restore/delete from rows. The section is bound per shell: imprint = manuscripts, **imbib = publications** (the Dismissed library, where the publication dismiss gesture lands) — which is why `.dismissed` stayed in imbib's explicit `visibleSections` |
| `customSurface` (WP-X0) | ➖ by design | ➖ | ➖ | ➖ | ➖ | ➖ | app-owned whole-pane view; rendered full-pane (no split/toolbar). Design note: implemented as top-level sidebar NODES + `ImbibTab.customSurface`/`ImbibContentRoute.customSurface`, NOT as `SidebarSectionType` cases — the section enum's String rawValue backs persisted order state and widening it would ripple every section switch. |
| `mailFolder` vs `recordFolder` | — | — | — | — | — | — | **Not converged, deliberately:** `mail-folder` rows are IMAP-owned mailboxes with no kernel collection binding (the message descriptor declares no `collection`), so they keep their own read-only node case. Converging them would mean claiming folder VERBS the store must never perform on mail (Stage-2-A2) |
| `customSurface("store-search")` (G4) | ➖ | ➖ | ➖ | ➖ | ➖ | ➖ | CHASSIS-builtin (only builtin surface tier so far; every preset, appended after app surfaces); select → full-pane grouped mixed-kind search over `search_all` FTS; Return/double-click opens kinds with real routes (publication, manuscript), metadata footer otherwise; ⌘⇧F routes here in implore/impel only (imbib/imprint keep their bindings; impart's ⌘⇧F = Forward Message, node is click/menu-only) |
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
| Manuscript (`ManuscriptListWrapper`) | ✅ `.id(scope)` only (no pane `.id` — rebuilding the NSTextView made selection sluggish) | ✅ Set, primary drives detail | ✅ Open/Duplicate/Star/Archive/Flag/Tags/Folder/Delete | ✅ multi → folders (pasteboard + `RecordDragSession.manuscript` fallback) | ✅ j/k/n/s guarded | confirm alert → hard delete + Undo, session discarded; swipe = archive (status) / delete |
| Artifact | ✅ | ❌ | partial | ❌ | ✅ | ✅ |
| Figure (`FigureListWrapper`) | ✅ `.id(scope)` | ✅ Set, primary drives detail | ✅ Open in Canvas/Star/Flag/Tags/Folder/Delete (shared TriageMenu) | ✅ multi → folders/Unfiled (pasteboard `com.impress.figure-id` + `RecordDragSession.figure` fallback) | ✅ j/k/s/o// via TriageKeyGrammar (n, d ignored — no create/dismiss capability) | confirm alert → hard delete + Undo (no session to discard) |
| Message (`MessageListWrapper`) | ✅ `.id(scope)`; rows collapse to newest-per-thread with "(n)" badge (no expand/collapse chevrons in v1 — badge + thread view in the detail pane's Info tab) | ✅ Set, primary drives detail | ✅ Star/Flag/Tags only (shared TriageMenu; no dismiss/archive/delete — IMAP-owned) | ❌ no drag in v1 — moving mail = IMAP move, not store setParent (Stage-2-A2) | ✅ j/k/s/o// via TriageKeyGrammar (n ignored — compose stays in the classic window; d ignored — no dismissal capability) | ❌ none — mail deletion goes through IMAP flows, never the store (deletion `.none`; Stage-2-A2) |
| Task (`AgentRecordListWrapper`, scope tasks/tasksByState) | ✅ `.id(scope)`; header = humanized kernel state, badge = assigned_to, envelope unread dot kept | ✅ Set, primary drives detail | ✅ Star/Flag/Tags only (shared TriageMenu; no dismiss/archive/delete — state moves ONLY through TaskStoreApi.transition, kernel-owned) | ➖ no drag — tasks have no folder tree | ✅ j/k/s/o// via TriageKeyGrammar (n ignored — the kernel schedules tasks; d ignored — no dismissal capability) | ➖ none — kernel-owned lifecycle (deletion `.none`) |
| AgentRun (`AgentRecordListWrapper`, scope runs) | ✅ `.id(scope)`; header = agent_id, title = result_summary first line ?? model, badge = "N tok · Ss" | ✅ Set, primary drives detail | ✅ Star/Flag/Tags only (shared TriageMenu) | ➖ no drag | ✅ j/k/s/o// via TriageKeyGrammar (n, d ignored — runs are immutable provenance) | ➖ none — immutable provenance records |
| Mixed-kind (`AnyRecordListWrapper` over `KindTaggedRow`, ADR-0022 D4) | ➖ host-owned: the wrapper hands back the primary row (first selected in DISPLAY order) and its `kind`; the host swaps the pane | ✅ Set | ➖ none in v1 | ➖ none | ➖ none in v1 | ➖ none — rows are display projections, not owners |

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

**Related section (ADR-0022 D8 / WP G5).** `RelatedItemsSection(itemID:)` is
one generic Info-tab section over `SharedStore.relatedItems(id:limit:)`: typed
edges in both directions, grouped by edge type (first-appearance order),
each row = direction arrow + kind icon + title. Kind comes from
`BuiltinRecordKinds.registry.kind(forStoreSchemaRef:)` (version-tolerant,
base-name equality — the shared lookup grouped search uses too); an unclaimed
schema shows the unknown symbol rather than a wrong kind. Loaded off-main via
the `RelatedItemsReader` actor, three-point trace under category `related`.

| Surface | Related section |
|---|---|
| figure Info (`FigureDetailPane`) | ✅ after the metadata grid |
| message Info (`MessageDetailPane`) | ✅ after the thread list (edges only — the thread list is `thread_id` equality, not an edge) |
| task / agent-run Info (`AgentRecordDetailPane`) | ✅ before the triage footer |
| manuscript detail (`ManuscriptDetailView`) | ✅ last section in the stack |
| publication Info (`InfoTab`) | ➖ deferred — the fragile detail-pane/toolbar surface (imbib CLAUDE.md); adopt with the next InfoTab pass |

Empty = the section renders NOTHING (no header, no divider). Rows are inert
in v1: opening one needs the registry open-behavior work (descriptor
`defaultOpenBehavior` + per-shell overrides + a host that can switch section
AND selection), tracked as a G5 follow-up in the code (`// G5-followup`).

## Record-kind descriptor contract (Stage 1 regression oracle)

Frozen from current behavior 2026-07-26 — the descriptor retrofit must
reproduce every cell exactly. This table becomes the DoD surface for
`RecordKindDescriptor` (see ADR-0021): a new kind adds a row here.

**Adding a kind — the full current path** is walked end to end in ADR-0021,
"Litmus re-run: adding an `audio-recording` kind" (re-run 2026-07-27 for
ADR-0022 WP G8), with each step marked AUTOMATIC or HAND-WRITTEN: schema →
row struct → descriptor (+ `CollectionCapability`) → thin wrapper →
viewer-registry factory → section wiring → preset lines (incl. `impress`) →
mixed-kind surfaces and the MCP tool surface, which cost ZERO new code
because every tool in the section below is store-generic.

| Kind | schemaRefs | Tabs (availability) | Star | Flag | Tag | Dismiss semantics | Archive | Delete semantics | Create | Open behavior |
|---|---|---|---|---|---|---|---|---|---|---|
| publication | imbib/bibliography-entry | info, pdf, notes (editable only), bibtex | ✅ | ✅ | ✅ | library-move → Dismissed library (never re-enters inbox) | ➖ | soft (move to Dismissed); hard only from Dismissed | import/search | detail pane; handoff n/a |
| manuscript | manuscript | info, source, pdf-as-Preview (hidden for plaintext) | ✅ | ✅ | ✅ | status=dismissed (restore→draft) | status=archived | confirm alert → hard delete + undo, session discarded first | n (format menu: typst/latex/markdown/plaintext) | imprint: window "manuscript-editor"; imbib: app handoff imprint:// |
| artifact | artifact schemas | info (+type-specific) | ❌ | partial | ✅ | ➖ | ➖ | ✅ | detail pane |
| figure | figure | info, pdf-as-View (hidden without data_hash; presence encoded via RecordTabContext.previewKind = compiledPDF/none) | ✅ | ✅ | ✅ | ➖ (no status field today) | ➖ | confirm alert → hard delete + undo | ➖ (canvas/generators create) | window "canvas" (value = figure id string) |
| message | email-message, chat-message | info, source, pdf-as-View (all always available) | ✅ | ✅ | ✅ | ➖ (no status field; `.statusChange` would be wrong — lifecycle is IMAP-owned; archive-to-folder is a Stage-2-A2 follow-up) | ➖ | ➖ `.none` — deletion goes through impart's IMAP flows, never the store | ➖ compose stays in impart's classic window (v1) | detail pane |
| task | task@1.0.0 (VERSIONED — impel-core TaskStoreApi) | info, source (description/prompt), pdf-as-View (latest run's result_summary via MarkdownUI; all always available) | ✅ | ✅ | ✅ | ➖ `.none` — task state moves ONLY through `TaskStoreApi.transition` (kernel-owned, ADR-0015 D1; a `.statusChange` dismissal would bypass the kernel; `statuses` declared empty because the lifecycle lives in payload `state`, not the chassis `status` machinery) | ➖ | ➖ `.none` — kernel-owned | ➖ scheduled by impel-taskd/counsel, never `n` | detail pane |
| agent-run | agent-run@1.0.0 | info, source (raw result_summary), pdf-as-View (MarkdownUI; all always available) | ✅ | ✅ | ✅ | ➖ immutable provenance record (ADR-0005 §5) | ➖ | ➖ `.none` | ➖ recorded by the kernel | detail pane |

Frozen shell-preset truth table (AppShellConfiguration v2 parity target).
**`impress` ships no app target** — the column is the ADR-0022 D9 preset that
exists to be parity-tested (`AppShellConfigurationParityTests`, the
`testImpress*` cases), so the seams the future app stands on cannot rot
unnoticed:

| Derived value | imbib | imprint | implore (Stage 2-B) | impart (Stage 2-A) | impel (Stage 2-C) | impress (D9 — NOT SHIPPED) |
|---|---|---|---|---|---|---|
| showsSubmissionsInbox | true (auxiliaryRoute retained, but UNREACHABLE since the publications-only purification — it hung off the Manuscripts section; see Known gaps) | false | false | false | false | **true — its designated future home.** The route and `SubmissionsInboxView` were kept for exactly this |
| flagsShowManuscripts | false | true | false | false | false | false — `.flagged` binds `.publication`. A single `RecordKindID` cannot say "flagged records of every kind"; mixed-kind Flagged over `AnyRecordListWrapper` is a follow-up, not a preset edit |
| opensManuscriptsInProcess | false | true | false (n/a) | false (n/a) | false (n/a) | false — `openOverrides` is EMPTY (impress embeds every viewer, so every kind uses its descriptor default). The manuscript default is `.appHandoff`, correct today because there is no impress target to open anything; it becomes `.detailPane` when impress ships |
| dismissedShowsManuscripts | false | true | false (n/a) | false (n/a) | false (n/a) | false — `.dismissed` binds `.publication`, same reasoning as Flagged |
| visibleSections | **EXPLICIT, publications only (2026-07-27):** inbox, libraries, sharedWithMe, scixLibraries, search, exploration, flagged, citedInManuscripts, artifacts, reviewQueue, dismissed. NOT manuscripts / figures / mail / agents — those are imprint's / implore's / impart's / impel's facets. `citedInManuscripts` stays: its children are "All Cited Papers" (publications), imbib's half of the imprint bridge. `dismissed` stays: it is `.publication`-bound here. Was `nil` ("everything"), which opted imbib into every section the chassis grows; purity is the policy now (ADR-0022 D9) and a new section must opt IN | manuscripts, citedInManuscripts, flagged, dismissed | figures only (Flagged deliberately skipped in v1 — needs a `.flagged: .figure` binding + routing) | mail only (Flagged deliberately skipped in v1 — needs a `.flagged: .message` binding + routing) | agents only (Flagged deliberately skipped in v1 — needs a `.flagged: .task` binding + routing) | **EVERY section, EXPLICITLY** (inbox, libraries, sharedWithMe, scixLibraries, search, exploration, flagged, citedInManuscripts, artifacts, manuscripts, figures, mail, agents, reviewQueue, dismissed = `Set(SidebarSectionType.allCases)`). `nil` would have been shorter and is exactly the mechanism that rode Manuscripts into imbib, so the unifying shell opts in by NAME; `testImpressPermitsEverySection` fails when the enum grows, until someone decides. `sectionBindings` names a kind for every section except `.reviewQueue` (its rows are `review-request@1.0.0`, which has no descriptor — binding it to a kind it does not list would be a lie). `agent-run` is the one registry kind that is not a binding VALUE: runs share the Agents section with tasks by design |
| defaultSection / defaultDetailTab | inbox / info | manuscripts / source | figures / info | mail / info | agents / info (lands on the Tasks leaf) | inbox / info |
| custom surfaces | — | — | generate, analyze (registered app-side via `withCustomSurfaces`); canvas = figure open window | chat, **category**, research, development (registered app-side via `withCustomSurfaces` in ImpartChassisRoot). `category` landed with the Stage-4c flip: it was the one classic view mode (⌘3) the chassis could not reach | dashboard, **threads**, **roster**, escalations, suggestions, counsel (registered app-side via `withCustomSurfaces` in ImpelChassisRoot; escalations keeps its 1-9/j/k keys INSIDE the surface, suggestions its ⏎/⎋ + j/k, both keyboardGuarded). `threads` and `roster` landed with the Stage-4c flip: the Agents SECTION reads the same `task@1.0.0` rows but renders them as tasks (losing impel's temperature / claimedBy) and has no surface for `ImpelClient.state.agents` / `.personas` at all | — none app-registered; the chassis-builtin store-search surface arrives anyway (`StoreSearchSurfaceTests` enumerates impress too). App-owned surfaces can only be registered by an app target, and there is none |
| default window | chassis | chassis | chassis | **chassis (Stage 4c, 2026-07-30).** `impart.useChassisWindow`, the classic three-column `ContentView`, `EmailListView`, `ImpartSidebarView`/`FolderTreeRow` and the "Mail (Unified)" secondary window are DELETED (1719 lines). The flag is not kept as a kill switch because it could only restore a strictly poorer window: the classic mail lists were permanently EMPTY on macOS — `InboxViewModel.loadMessages()` has no macOS caller (only `IOSContentView` assigns `selectedMailbox`), `accounts` is `private(set)` and assigned nowhere, `loadFolders(for:)` has no caller at all — and its detail pane was unreachable (it read `AppState.selectedMessageIds` while the list wrote `InboxViewModel.selectedMessageIds`). Compose, reply/forward, mark-read-on-select and check-mail moved to `MailChassisHost` over the new `RecordHostVerbs` seam; `ComposeView` and the whole Settings scene were EXTRACTED from the deleted file first | **chassis (Stage 4c, 2026-07-30).** `impel.useChassisWindow`, the classic `ContentView` and the "impel (Unified)" secondary window are DELETED (320 lines). Flag not kept, same reasoning: every surface the classic dashboard rendered is registered here over the same views. Closed first: suggestion ⏎/⎋ keys, the threads list and agent/persona roster (as surfaces), ⌘/ keyboard help (now a menu command), `wireUndo`, the two toolbar status indicators, and `impel://navigate/...` (which set a `DashboardTab` only the classic window observed) | ➖ no app target ships this preset (ADR-0022 D9). When it does: a ~120-line `ImpressChassisRoot`, and a signing decision first — impress permits `.search`, so `TabContentView`'s ADS/SciX keychain read WOULD run in it, and those items are ACL'd to imbib's code signature (imbib CLAUDE.md invariant). Either impress ships with imbib's keychain access group or that read moves behind a reachability check |

### Platform reach of the contract (iOS foundation pass, 2026-07-29)

The declarative half of the chassis is CROSS-PLATFORM. It was gated
`#if os(macOS)` with the comment "macOS-only in GUI-meld Phase 1 (iOS keeps
IOSContentView)", which was historical, not technical: none of these files
imports AppKit, and PMC already declares `.iOS(.v26)` and is linked by
imprint-iOS. The gate's real cost was that iOS had to RE-ENCODE the contract —
imprint's iOS adapter carried its own `"dismissed"` / `"draft"` literals
instead of reading `ManuscriptRecordKind.descriptor.triage`.

| File | Reach | Note |
|---|---|---|
| `Chassis/RecordKind/RecordKindDescriptor.swift` | ✅ both | pure data + closures; SwiftUI only |
| `Chassis/RecordKind/BuiltinRecordKinds.swift` | ✅ both | the single declaration of every kind's status lifecycle |
| `Chassis/RecordKind/RecordScopeKey.swift` | ✅ both | protocol + `UUID.deterministic` + `PublicationSource` conformance |
| `Chassis/RecordKind/RecordScopeKey+ListScopes.swift` | ✅ both | Stage 2a: renamed from `+MacScopes`. The four list-scope ENUMS moved here OUT of their gated wrappers — a scope is a Foundation value (UUID / FlagColor / status), only the wrapper is AppKit-adjacent |
| `Chassis/RecordKind/KindTaggedRow.swift` | ✅ both | row type + the one generic `init(kind:item:)` |
| `Chassis/RecordKind/KindTaggedRow+RowData.swift` | ✅ both | Stage 2a: the per-kind row structs it names went cross-platform, so the initializers followed |
| `Chassis/AppShellConfiguration.swift` | ✅ both | presets are the app's declarative identity |
| `Chassis/CustomSurface.swift` | ✅ both | registry is data; only `builtin` (StoreSearchSurface, AppKit) is gated inside |
| `Chassis/Shared/SchemaRefKindLookup.swift` | ✅ both | tolerant schema-ref → kind lookup |
| `Chassis/Shared/RecordTriage.swift` | ✅ both | action bag + swipe/menu builders (plain SwiftUI) |
| `Chassis/Shared/RecordTriageNewTagPrompt.swift` | both, gated body | SPLIT out: the NSAlert prompt; iOS omits the affordance rather than showing a dead button |
| `Files/SidebarSectionOrderStore.swift`, `SharedViews/DetailTab.swift` | ✅ both | never gated |

**Stage 2a (2026-07-29) — 26 more files un-gated, no AppKit removed from any of
them.** The `#if os(macOS)` on each was the GUI-meld Phase 1 header copied
verbatim; none of these files imported AppKit, and the two that named a
genuinely macOS-only symbol were SPLIT (the two `macOS` rows below), never
re-gated. `MarkdownPreviewTab*` landed in the same wave from the markdown
split and is listed here so the reach table stays complete.

| File | Reach | Note |
|---|---|---|
| `Chassis/RecordKind/RecordViewerRegistry.swift` | ✅ both | the registry, `RecordViewerFactory` and `RecordSectionContext`. iOS previously had no registry TYPE at all, so a kind's viewer could not be named there. `builtin` is now the `CustomSurfaceRegistry.builtin` shape: an `#if` island that resolves to the gated factory list on macOS and an EMPTY registry on iOS |
| `Chassis/RecordKind/RecordViewerRegistry+Builtin.swift` | macOS | SPLIT out: the four builtin factories, each constructing an AppKit-adjacent section view (`FigureSectionView` / `MessageSectionView` / `AgentSectionView`) |
| `Chassis/RecordKind/AnyRecordListWrapper.swift` | ✅ both | the mixed-kind list over `KindTaggedRow` — plain SwiftUI `List` |
| `Chassis/TabSidebar/TabSidebarTypes.swift` | ✅ both | 345 lines of route enums (`ImbibTab`, `ImbibContentRoute`, journal/figure/mail/agent routes) + notification names. The chassis's ROUTE vocabulary, which iOS had to re-encode as literals |
| `Chassis/TabSidebar/FocusedPane.swift` | ✅ both | the focus twin of the never-gated `DetailTab` |
| `Chassis/Manuscripts/FocusedManuscript.swift` | ✅ both | a `FocusedValueKey` — pure SwiftUI focus plumbing |
| `Chassis/Shared/FindCoordinator.swift` | ✅ both | ⌘F / ⌘⇧F `Commands`, the `listFilterFocusAction` focused value, and the store-search notification names. `Commands` is SwiftUI, not AppKit. ISLAND: `ImpressStoreSearchCommands` contributes nothing on iOS — the surface it opens (`StoreSearchSurface`) is the one AppKit-linking builtin, so the chord would open nothing (the `RecordTriageNewTagPrompt` "omit the affordance" rule) |
| `Chassis/Manuscripts/ManuscriptRowData.swift` | ✅ both | display-ready row snapshot (Foundation + ImpressFTUI/ImpressMailStyle value types) |
| `Chassis/Messages/MessageRowData.swift` | ✅ both | as above, mail |
| `Chassis/Figures/FigureRowData.swift` | ✅ both | as above, figures |
| `Chassis/Agents/AgentRowData.swift` | ✅ both | as above, tasks + agent runs |
| `Chassis/Messages/MailStoreReader.swift` | ✅ both | read-only `SharedStore` reader. **While gated, iOS could not read mail from the shared store at all** |
| `Chassis/Figures/FigureStoreReader.swift` | ✅ both | same, figures |
| `Chassis/Agents/AgentStoreReader.swift` | ✅ both | same, tasks + runs |
| `Chassis/Services/JournalEventBridge.swift` | ✅ both | Darwin → NotificationCenter bridging (a Foundation/CF capability). Now also the home of `.manuscriptDidChange`, moved off the bottom of the still-gated `ManuscriptDetailView.swift`: the view is AppKit-adjacent, the NAME is contract data |
| `Chassis/Shared/RelatedItemsSection.swift` | ✅ both | the ONE generic Related section — model, off-main reader actor, plain-SwiftUI view |
| `Chassis/Detail/Tabs/CitedInManuscriptsSection.swift` | ✅ both | plain SwiftUI over store rows |
| `Chassis/Detail/JournalManuscriptsListView.swift` | ✅ both | plain SwiftUI list + `NavigationStack`. ISLAND: the push DESTINATION is `ManuscriptDetailView` (AppKit-adjacent), so iOS renders the rows without the link rather than offering a dead one |
| `Chassis/Detail/SubmissionsInboxView.swift` | ✅ both | plain SwiftUI; owns `.submissionsDidChange` |
| `Chassis/Manuscripts/ManuscriptVersionsSection.swift` | ✅ both | plain SwiftUI over the revision list |
| `Chassis/Manuscripts/ManuscriptHistorySection.swift` | ✅ both | plain SwiftUI over the manuscript activity feed |
| `Chassis/SciX/SciXLibraryListView.swift` | ✅ both | plain SwiftUI header chrome |
| `Chassis/SciX/SciXLibraryInfoSheet.swift` | ✅ both | plain SwiftUI sheet; the platform differences it already had were `#if` islands inside |
| `Chassis/SciX/SciXEditLibrarySheet.swift` | ✅ both | as above |
| `Manuscript/Editor/ManuscriptEditorSession.swift` | ✅ both | the editor lifecycle seam: buffer, cursor, debounced compare-and-set save, external-conflict resolution, and `ManuscriptSessionRegistry` (LRU + cross-process Darwin refresh). No split was needed — the audit expected one AppKit reference and found only `NSRange`, which is Foundation. **imprint-iOS's `IOSManuscriptEditorHost` re-implements this state machine (format detection, debounce, preview-kind logic) and can now adopt it; that adoption is Stage 2b, deliberately not done here** |
| `Chassis/Manuscripts/MarkdownPreviewTab.swift` | ✅ both | the markdown preview renderer |
| `Chassis/Manuscripts/MarkdownPreviewTab+Session.swift` | macOS | SPLIT out: the `ManuscriptEditorSession` entry point, which reads `session.source` inside its own body so the `@Observable` dependency stays scoped to the preview |

Files the audit reached for and Stage 2a left **gated**, with the reason:

| File | Why it stays gated |
|---|---|
| `Chassis/Manuscripts/ManuscriptDetailPane.swift` | audit said "plain SwiftUI"; it is not. Its `content` switch names six macOS-only views — `ManuscriptDetailView`, `ManuscriptSourceTab`, `MarkdownPreviewTab(session:)`, `ManuscriptLaTeXImprintPrompt`, `ManuscriptPDFPreview`, `ManuscriptInverseSync`. Un-gating would leave a shell whose every branch is an island, which is a re-gate wearing a different hat |
| `Chassis/Detail/DetailView.swift` | genuinely AppKit-adjacent (stays). A dead `#if os(iOS) .navigationTitle` branch inside it — unreachable, since the whole file is `#if os(macOS)` — was deleted in passing |

Enforcement is automated, not conventional: `ChassisCrossPlatformContractTests`
asserts (a) descriptors, presets, schema-ref lookup and `KindTaggedRow`
resolve, (b) the manuscript kind still declares the reserved lifecycle iOS
reads, and (c) **the contract files do not start with `#if os(macOS)`** — the
guard against a future chassis file copying the historical header verbatim.
Both iOS builds (`-scheme imprint-iOS` and `-scheme imbib-iOS`, `-destination
'generic/platform=iOS Simulator'`) are the compile-level gate — after Stage 2a
they compile 26 more chassis files each.

**Rule when a macOS-only symbol lands in a contract file: SPLIT the file**
(data here, AppKit companion gated) — never re-gate the contract.

### iOS shell surface (`Chassis/Shared/RecordSidebar/`, 2026-07-29)

macOS renders its sidebar with `ImbibSidebarViewModel` + `SidebarOutlineView`
(NSOutlineView). iOS cannot use either, so the SHAPE of a sidebar was lifted
out of the renderer into data that both platforms could in principle share and
that iOS actually does:

| File | Reach | Role |
|---|---|---|
| `RecordSidebar/RecordSidebarModel.swift` | ✅ both | `RecordFolder`, `RecordSidebarScope` (+ `RecordScopeKey`), `RecordSidebarNode`, `RecordSidebarSectionModel`, `RecordSidebarSectionRole`, `RecordStatusPresentation` (a resolver over the descriptors since 2026-07-29, not a table) |
| `Shared/ChassisEmptyState.swift` | ✅ both | the chassis's empty/unavailable states as data + one `ContentUnavailableView` renderer |
| `RecordSidebar/RecordSidebarBuilder.swift` | ✅ both | `AppShellConfiguration` × `RecordKindDescriptor` × `RecordSidebarDataSource` → `[RecordSidebarSectionModel]`; `AppShellConfiguration.effectiveRecordKind(for:)` |
| `RecordSidebar/RecordCollectionActions.swift` | ✅ both | organise verbs as an action bag + `RecordFolderMenu.moveTo` / `.organize` (SwiftUI menus, usable on macOS too) |
| `RecordSidebar/RecordTriageListRow.swift` | ✅ both | `.recordTriageRow(...)` — one modifier attaching `TriageSwipe` + `TriageMenu` to a list row |
| `RecordSidebar/RecordSidebarView.swift` | iOS | the renderer (List + sections + folder tree + name sheet) + `RecordSidebarHostChrome` (2026-07-30) |

Rules the builder applies, all read from declarations rather than written per
app:

| Question | Answered by |
|---|---|
| which sections | `visibleSections` ∩ `passesFacetGate` ∩ **`canPresent(kind)`** ∩ host content gate (`RecordSidebarDataSource.sectionIsAvailable`) — four orthogonal gates, all must pass |
| which kinds this HOST can render | `AppShellConfiguration.presentableKinds`, set by the host with `presenting(_:)` at its root (nil = every registered kind, which is what every PRESET says). This is a per-BUILD capability, not app identity: macOS imprint renders publications for `.citedInManuscripts`, imprint-iOS has no publication surface, and both run `.imprint`. It replaced a literal `section != .citedInManuscripts` in app code (2026-07-29). It does NOT subsume `passesFacetGate` (suite policy keyed on appID, fires even for kinds the shell registers) or the content gate ("is there anything in it right now") |
| which kind a section serves | `sectionBindings[section]`, falling back to the canonical table = `AppShellConfiguration.impress.sectionBindings` |
| section behaviour | `SidebarSectionType.role` — declared beside `displayName`/`icon`, so a new section is ONE edit. `RecordSidebarSectionRole.role(for:)` forwards to it (it used to be a 15-arm switch in the chassis) |
| flag row colour + label | `FlagColor.displayColor` / `.displayName` (ImpressFTUI) — the ONE cross-platform mapping. The node carries `RecordSidebarNode.flagColor` and each renderer asks it for the colour: macOS `ImbibSidebarNode.iconColor`, iOS `RecordSidebarView.nodeIcon` (which both iOS shells now go through — imbib-iOS's own `flaggedSectionContent` was deleted with `IOSSidebarView` on 2026-07-30), imprint-iOS list dots. A per-view switch here is the bug, not the fix (2026-07-29: the iOS sidebar shipped with no mapping at all and every flag rendered in the default tint) |
| status smart-children | `descriptor.triage.statuses` — `[StatusSpec]` since 2026-07-29, so each status carries its own `label` + `systemImage` + `isTerminal` + `hiddenByDefault`. Rows minus the `hiddenByDefault` ones (the dismissed status sets it: it owns the Dismissed section). Presentation used to live in a private table in `RecordStatusPresentation` and, for four of them, a third time as macOS literals |
| status row label + icon | the `StatusSpec` itself. `RecordStatusPresentation` is now a RESOLVER over the shipped descriptors (with a title-cased/`circle` fallback for an undeclared value), read by iOS sidebar rows, the iOS status badge and macOS's `journalChildren` alike |
| kernel-owned lifecycles (impel tasks) | `descriptor.lifecycle` (`RecordLifecycleSpec`: payload field + `[StatusSpec]` + `isKernelOwned`). SEPARATE from `triage.statuses` on purpose — `statuses` is "values the generic status writer may set", and `TaskStoreApi.transition` is the sole legal mutation for a task state (ADR-0015 D1). Retired `AgentStoreReader.stateIcon`'s six-arm switch + its parallel `taskStates` array |
| record kind icon | `descriptor.symbolName`. Retired `RecordKindIconography.symbolName(for:)`'s seven-arm switch — the ONE per-kind chassis edit the ADR-0021 litmus still admitted to |
| "All …" row title | `descriptor.pluralDisplayName` (was `displayName + "s"`) |
| folder tree + organise verbs | `descriptor.collection` / `CollectionCapability.canOrganize` |
| folder row glyph + menu titles | `CollectionCapability.folderSymbolName` / `.containerNoun` → `newContainerTitle` / `newSubContainerTitle` / `deleteContainerTitle`. Replaced a hardcoded `"folder"` in the builder and three inline `NSMenuItem` titles in `ImbibSidebarViewModel` |
| empty / unavailable states | `ChassisEmptyState` — one table, copy preserved verbatim from the six inline `ContentUnavailableView`s in `SectionContentView` |
| section order + collapse | `SidebarSectionOrderStore` / `SidebarCollapsedStateStore` (the same persisted stores macOS uses) |
| rows a section's ROLE cannot express | `RecordSidebarDataSource.sectionContent` → `RecordSidebarSectionContent` (2026-07-30, Stage 5a). The four roles cover sections whose rows are a slice of ONE kind; imbib's are not (Search = 9 search forms, SciX = one row per remote shelf, Inbox = Recent + feeds + collections, Libraries = a tree of LIBRARIES each owning its own collections). The host answers "which rows"; the preset still owns which sections, their order, titles, icons and gates |
| a row only the HOST can name | `RecordSidebarScope.host(kind, key:)` (2026-07-30). The five chassis scopes are statuses / folders / flags / whole sections; a library, a saved search, a remote shelf and a search form are none of those, and enumerating imbib's taxonomy in the chassis would be the ADR-0022 mistake. Hosts build keys through ONE typed route enum (`ImbibSidebarRoute`) so the round trip (row → selection → content route → row) is single-sourced |
| a section header that is a DESTINATION | `RecordSidebarSectionContent.headerScope` → `RecordSidebarSectionModel.headerScope` (2026-07-30). macOS has always mapped the Inbox *section node* to `.inbox`; imbib-iOS's Flagged header selects any flag. Modelling it as a synthetic first row would add a row neither shell shows |
| organise verbs on a host-resolved tree | `RecordSidebarSectionContent.canOrganizeFolders` (overrides the descriptor gate) + `.offersRootFolderCreation` (split out: imbib's collections are rooted PER LIBRARY, so "new folder at the section root" has no answer, but the tree is still organisable). `RecordSidebarView.rebuild()` reads `dataSource.folders` for such sections too — gating that on the descriptor alone left imbib's organise menu permanently empty |
| per-row verbs that are not folder verbs | `RecordSidebarHostChrome` (2026-07-30): `nodeAccessory` / `nodeMenu` / `nodeSwipeActions` / `sectionAccessory` / `onMoveNodes`, all defaulted nil. imbib needs Delete Library, Open on SciX, Refresh, Hide a search form, Edit/Delete a saved search, and a per-library `+`. None is a capability of a record kind |
| default landing selection | regular width only (2026-07-30). In COMPACT width a `NavigationSplitView` is a stack: writing a selection PUSHES and the sidebar the user launched into disappears. Caught on the first iPhone run of the second adopter; it affected imprint-iOS identically |

Adopters: imprint-iOS (`IOSManuscriptSidebarBindings.swift` — data source,
collection actions, triage actions, `RecordSidebarScope` →
`ManuscriptStoreScope`) and, since 2026-07-30 (Stage 5a), imbib-iOS
(`ImbibSidebarBindings.swift` — rows, route vocabulary, collection actions,
`RecordSidebarScope` ⇄ `SidebarSection` **both ways**, because imbib navigates
by notification too; `IOSSidebarHost.swift` — sheets, toolbar, chrome).
`IOSSidebarView.swift` (1,357 lines, 15-arm hand-written section switch, read
no preset, rendered `.sharedWithMe`/`.artifacts`/`.reviewQueue`/`.dismissed` as
`EmptyView()`) and its stub are DELETED.

What the second adopter changed in the shared surface is the six rows added to
the table above; what it changed in imbib is that the sidebar now honours the
preset, Dismissed papers are reachable on iOS for the first time, flag rows
have counts, and nested subcollection creation works instead of logging
`iOS: … not yet supported by RustStoreAdapter — creating at root`.

Host capability gaps declared rather than hidden: `.reviewQueue`
(`sectionIsAvailable → false` — unbound section, so `presentableKinds` cannot
speak for it, and this build has no review pane) and `.artifacts`
(`presenting([.publication])`).

Regression oracles: `RecordSidebarBuilderTests` (15 tests, `swift test` —
same builder + different presets ⇒ different sidebars),
`imprint-iOSUITests/LibraryShellUITests` (5 tests, booted simulator — sidebar
tree, search, long-press menu, trailing swipe says Dismiss/Archive, dismissed
manuscript visible ONLY in the Dismissed scope) and
`imbib-iOSUITests/IOSSidebarUITests` (2 tests, booted simulator — the section
list IS the `.imbib` preset with each absent section absent for a *different*
declared reason, and a collection selection produces a SCOPED list).

### Settings surface (`Chassis/Settings/`, Stage 6 phase 1, 2026-07-29)

Settings were the last big surface authored per app AND per platform: ~7.9k
lines across the suite (imbib 3,998 macOS + 3,185 iOS; imprint 1,367; implore
226; impel 156; impart ~330) with no shared frame at all. imprint-iOS shipped
NO settings — an original user report — and the reason was structural, not
technical: "which panes does imprint have, in what order" existed only as the
body of a macOS `TabView`, so a platform that could not run that `TabView`
could not even NAME a pane.

Phase 1 is the registry + both renderers + the imprint migration. The other
apps are phase 2 and are deliberately untouched.

| File | Reach | Role |
|---|---|---|
| `Chassis/Settings/SettingsSectionDescriptor.swift` | ✅ both | `SettingsSectionID` (string-backed, additive), `SettingsSectionDescriptor` (id, title, SF Symbol, subtitle, availability, order — Sendable DATA, no closures), `SettingsPlatform`, `SettingsRequirement`, `SettingsSectionAvailability`, `SettingsHostCapabilities` |
| `Chassis/Settings/SettingsSectionRegistry.swift` | ✅ both | `SettingsSectionFactory` (the `@MainActor @Sendable → AnyView` builder), the registry (`register` / `subscript` / `composing` / `unresolvedSections`), the environment key, the two BUILTIN panes, and `SettingsForm` (the one `#if` island — macOS tabs want `.padding()`, iOS pushed screens must not have it) |
| `Chassis/Settings/AppSettingsConfiguration.swift` | ✅ both | the per-app ordered section list. A SIBLING of `AppShellConfiguration.swift`, not part of it: different consumers (two renderers vs. the whole sidebar), and `Chassis/Settings/` stays a clean folder move for the deferred `ImpressSettings` extraction (ADR-0021 D5) |
| `Chassis/Settings/MacSettingsSceneContent.swift` | macOS | the tabbed renderer (`TabView` + `.tabItem`), sized to imprint's shipped Settings-window metrics |
| `Chassis/Settings/IOSSettingsScreen.swift` | iOS | the grouped-list renderer (`NavigationStack` + `List` of `NavigationLink`s), iOS idiom rather than a ported `TabView` |

**No gated `+Builtin.swift` split was needed, and that is a finding rather than
an omission.** Both builtin panes are plain SwiftUI over packages PMC already
links on both platforms (ImpressTheme, ImpressSpotlight), so nothing
AppKit-adjacent reached the builtin tier — unlike
`RecordViewerRegistry+Builtin.swift`, whose factories construct AppKit-adjacent
section views. Where a settings section IS platform-bound, the mechanism is the
descriptor's `availability`: data, readable and testable from either platform,
rather than an `#if` that would make the section unnameable again.

Availability is answered by declaration, never by an `#if` at the call site:

| Question | Answered by |
|---|---|
| which panes exist, in what order | `AppSettingsConfiguration.<app>.sections` (sorted by `descriptor.order`; a test pins declaration order == sort order) |
| which panes this platform shows | `SettingsSectionAvailability.platforms` ∩ (`requirements` ⊆ host capabilities) |
| why a pane is macOS-only | `SettingsRequirement` — `.httpAutomation` (no `com.apple.security.network.server` on iOS), `.localToolchain` (TeX / latexmk / impress-toolbox / git), `.siblingAppDiscovery` (NSWorkspace app probing), `.spotlightIndex` (a host-installed CoreSpotlight coordinator). An empty requirement set with `platforms: [.macOS]` means "the implementation lives in the app's macOS target", which is a different and weaker claim — stated as such |
| what a pane looks like | `SettingsSectionRegistry[id]` → the factory. Chassis builtins first, app registrations layered over (last wins), so an app REPLACES a builtin rather than the chassis growing a flag |
| tab / row accessibility identifier | `SettingsSectionID.accessibilityIdentifier` = `settings.tabs.<id>`. FROZEN — imprint's `SettingsPage` and UI tests address panes by it, and an iOS row carries the same identifier as its macOS tab |

**imprint migration — the 13-tab mapping (macOS visually equivalent: same
tabs, same order, same controls).** "Chassis builtin" = the chassis ships the
pane; "imprint-registered" = descriptor in the preset, factory in imprint code,
pane file untouched.

| # | Old macOS tab | New section id | Where the CONTENT lives now | iOS |
|---|---|---|---|---|
| 1 | Appearance | `appearance` | **chassis builtin** — `AppearanceSettingsPane` over `ImpressTheme.AppearanceSettingsSection`; imprint's hand-rolled `AppearanceSettingsView` deleted | ✅ |
| 2 | General | `general` | imprint-registered, pane MOVED to `Shared/Settings/ImprintSettingsPanes.swift` | ✅ |
| 3 | Editor | `editor` | imprint-registered, pane MOVED to `Shared/Settings/` | ✅ |
| 4 | AI | `ai` | imprint-registered, stays in `macOS/Views/SettingsView.swift` (`AIAssistantService`) | — |
| 5 | AI Tasks | `aiTasks` | imprint-registered, `macOS/Views/AITasksSettingsView.swift` UNTOUCHED | — |
| 6 | Citations | `imbib` | imprint-registered, `macOS/Views/ImbibSettingsView.swift` UNTOUCHED. Id is `imbib`, label is "Citations" — both shipped, both frozen | — |
| 7 | LaTeX | `latex` | imprint-registered, `macOS/Views/LaTeXSettingsView.swift` UNTOUCHED | — |
| 8 | Documents | `documents` | imprint-registered, pane MOVED to `Shared/Settings/` | ✅ |
| 9 | Export | `export` | imprint-registered, stays in `macOS/Views/SettingsView.swift` (`TemplateService`) | — |
| 10 | Account | `account` | imprint-registered, pane MOVED to `Shared/Settings/` | ✅ |
| 11 | Automation | `automation` | imprint-registered, stays macOS (drives `ImprintHTTPServer`, MCP config, NSPasteboard) | — |
| 12 | Git | `git` | imprint-registered, factory WRAPS `ImpressGit.GitSettingsSection` without editing it (PMC does not depend on ImpressGit) | — |
| 13 | Spotlight | `spotlight` | **chassis builtin** — `Form { SpotlightSettingsSection() }`, the wrapper every adopter was writing | — |

Not in the preset: **keyboard shortcuts.** imprint surfaces them as a separate
⌘/ window (`ShortcutsHelpView`), not a Settings tab, and macOS must stay
visually equivalent — so adding a 14th tab would be a redesign. `PMC/Settings/
KeyboardShortcutsSettings.swift` is data with no view of its own; when a
keyboard pane is wanted, it registers a descriptor whose factory wraps the
existing view rather than editing it.

iOS entry point: a gear (`toolbar.settings`) on the SIDEBAR column of
`IOSManuscriptLibraryView` — the sidebar, not the list, because that is the
column iOS lands on when the split view collapses on iPhone. It presents
`IOSSettingsScreen(configuration: .imprint)` at the navigation ROOT (the
`citationInspection` rule: a sheet raised from a column is dismissed by that
column's own navigation). The screen shows the five capability-free panes and a
footer stating how many more are Mac-only and why — a count read from the
declaration, so it cannot go stale.

Persistence: EVERY `@AppStorage` key is unchanged, including across the target
boundary the four portable panes crossed. `appearanceMode` in particular is now
written by the chassis builtin as an `ImpressTheme.AppearanceMode`, whose
`String` rawValues are exactly the `system`/`light`/`dark` tags imprint's picker
wrote — and iOS now APPLIES it (`ImprintIOSApp.preferredColorScheme`), which it
never did, so the Appearance row is not a dead control.

Regression oracles: `SettingsSurfaceContractTests` (15 tests, `swift test` —
the frozen 13-tab inventory, the accessibility identifiers, ordering,
availability filtering driven from either platform, registry composition
semantics, and the "declarative half must not get re-gated" structural guard),
`ImprintSettingsPersistenceTests` (5 tests, `swift test` — the frozen
`@AppStorage` key inventory by source scan; a renamed key silently resets every
user's preference and reads as "settings were lost"), and
`imprint-iOSUITests/SettingsScreenUITests` (4 tests, booted simulator — the
gear opens the sheet, the five declared sections render and the gated four do
not, the builtin appearance pane resolves, and a toggle survives `terminate()`
+ `launch()`).

### Settings surface — phase 2 (imbib, implore, impel, impart, 2026-07-30)

Phase 2 put the remaining four apps on the registry. All five apps' settings
surfaces are now declarations; **every macOS surface is visually equivalent to
what it shipped** (same panes, order, titles, symbols, tooltips, window metrics,
accessibility identifiers) and every `@AppStorage` key is byte-identical.

**Three additive chassis changes, each forced by an adopter phase 1 had not
seen:**

| Addition | Forced by | Why the alternative was worse |
|---|---|---|
| `SettingsSectionGroup` + `descriptor.group` (optional, nil default) | imbib's macOS Settings scene is a `NavigationSplitView` source list of **16 panes under 6 headers**, not a `TabView` | A `TabView` has no grouping to declare, so phase 1 had no reason to model it. Without the field the declaration cannot describe imbib's shipped surface at all |
| `Chassis/Settings/MacSettingsSidebarSceneContent.swift` — a THIRD renderer (grouped source list + detail) | same | 16 tabs is not visual equivalence, it is a redesign. A `style:` flag on `MacSettingsSceneContent` would be one file with two disjoint bodies, and would put imbib layout changes inside the file imprint's Settings window renders from |
| Frozen-identifier and fixed-size parameters (`containerIdentifier`, `doneIdentifier`, `maxWidth`/`maxHeight`, `MacSettingsSceneContent.fixed`) | imbib ships `settings.tabView` + `settings.doneButton`; implore/impel/impart ship `.frame(width:height:)` | imprint-iOS had no prior settings and imprint's window is resizable, so phase 1's hardcoded values were right for imprint and wrong for four apps that shipped earlier. Defaults are imprint's, so imprint is untouched |

`IOSSettingsScreen` also learned to honour `group` (one headerless band when a
preset declares none ⇒ phase 1 output unchanged). Group ORDER is never declared —
it is the order of each group's first member, so a group cannot sort against its
own contents. The one failure mode of that derivation (non-contiguous members ⇒ a
duplicated header) is pinned per platform by
`testEveryGroupedPresetKeepsItsGroupsContiguousOnEveryPlatform`, which caught it
for real while imbib's preset was being written.

**imbib — 16 macOS panes + 7 iOS-shaped sections, one preset.** macOS renders
through the sidebar renderer, iOS through the grouped list.

| Group | Panes (macOS order) | iOS |
|---|---|---|
| General | general, appearance, viewing | appearance, viewing (+ `smartSearch`, iOS-only) |
| Content | flagsAndTags, notes, pdf, sources, enrichment, searchAI | notes, pdf, sources, enrichment (+ `pdfStorage`, iOS-only) |
| Inbox & Feeds | inbox, recommendations | both |
| Sync & Backup | sync, eink | sync (+ `backup`, iOS-only) |
| Import & Export | importExport | ✅ |
| System | shortcuts, advanced | both (+ `automation`, iOS-only) |
| Developer / Help & Support / About (iOS only) | — | console, help, about |

- **Shared (chassis builtin):** none. imbib is the app that shows a builtin is
  only shareable where it is the SAME pane — its Appearance pane is a 530-line
  theme editor over `ThemeSettingsStore` (named themes, accent colours, font
  scale), not the builtin's three-way `appearanceMode` picker, so imbib
  **registers over** the `appearance` builtin on both platforms. That is the
  documented `register` replacement semantics used for the reason they exist.
  `testImbibPanesDoNotDeclareTheBuiltinAppearanceKey` stops the two owners of the
  light/dark choice from forking.
- **Shared across imbib's own platforms:** `enrichment` only —
  `PMC/Settings/ImbibPortableSettingsSections.swift`. macOS's `EnrichmentSettingsTab`
  and iOS's `IOSEnrichmentSettingsView` were the same four lines around the same
  `EnrichmentSettingsView`, differing by one `.padding(.horizontal)`, now read
  from `SettingsSectionContext.presentation`. Both deleted.
- **Keyboard pane WRAPPED, not edited:** `KeyboardShortcutsSettingsTab` (macOS) /
  `IOSKeyboardShortcutsSettingsView` (iOS) are named by factories.
  `PMC/Settings/KeyboardShortcutsSettings.swift` is untouched.
- **iOS entry point untouched.** `IOSSettingsView` keeps its type name, so
  `IOSContentView`'s gear and ⌘, still present it with no edit to that file
  (which the sidebar work is rewriting concurrently).
- **iOS row structure changed on purpose in one place:** Exploration and "Reset to
  First Run" were two rows; they are now one `advanced` pane, which is how macOS
  has always had them.

**The expected 3.1k-line duplication kill did not exist, and that is the main
finding of phase 2.** imbib's macOS and iOS settings are not one surface written
twice — they are two designs for two input models. `AppearanceSettingsTab` (530)
vs `IOSAppearanceSettingsView` (304); macOS `SourcesSettingsTab` is a
`DisclosureGroup` list with `SecureField`s and hover help, iOS's is a pushed
`List`; macOS `InboxSettingsTab` edits mute rules inline, iOS raises a sheet.
Collapsing those pairs is a rewrite, not a reframe — and since macOS must stay
visually equivalent, the surviving pane would have to be macOS's: `NSOpenPanel`,
`NSColorPanel` and hover tooltips on a phone. **What phase 2 actually removed is
the duplication that was STRUCTURAL** — two unreadable hand-written lists of which
panes exist, in what order, under what headings (four parallel `switch`es on
macOS, 23 rows on iOS). Those lists had already drifted in BOTH directions and
silently: iOS had grown PDF Storage, a top-level Backup row and a standalone
Automation pane; macOS had grown Flags & Tags, E-Ink and Search & AI; neither
knew. Those differences now survive as `availability` with stated reasons.

**implore / impel / impart** — small, and each teaches one thing:

| App | Tabs | Became shared | Stayed app-registered |
|---|---|---|---|
| implore | 5 | `spotlight` → **chassis builtin** (its tab body was `Form { SpotlightSettingsSection() }` verbatim) | general, rendering, colormaps, keyboard |
| impel | 3 | **nothing** | general, ai, counsel |
| impart | 6 | `spotlight` → **chassis builtin** (same verbatim wrapper) | accounts, ai, general, keyboard, automation |

- **impel adopts no builtin, deliberately.** It has no Appearance or Spotlight
  tab; growing an app's settings surface is a product change, not a reframe. What
  it gains is that the absence is now visible in data.
- **Two shared-component clones left in place on purpose, and recorded:** impart's
  `GeneralSettingsView` appearance `Picker` duplicates
  `ImpressTheme.AppearanceSettingsSection` over the same `appearanceMode` key
  (it is one of two pickers inside General, so promoting it would move a control
  between tabs), and impart's `AutomationSettingsView` duplicates
  `ImpressAutomation.AutomationSettingsSection` but drops `logRequests` (swapping
  it in would ADD a control). Both are phase-3 alignments; the reframe's value is
  that they are stated next to the declaration.
- **`impart-iOS` is NOT migrated, and cannot be:** that target does not link
  PublicationManagerCore (absent from `apps/impart/project.yml`), so no chassis
  renderer can run there. Its `IOSAppearanceSettingsView` is a second clone of the
  shared appearance section over the same key;
  `testImpartIOSStillReadsTheSameAppearanceKeyAsMacOS` keeps the preference from
  forking until the target links the package.
- Two ids that look like duplicates are not: `keyboard` (implore, impart —
  shipped `settings.tabs.keyboard`) and `shortcuts` (imbib — shipped
  `settings.tabs.shortcuts`, even though its Swift case was `keyboardShortcuts`).
  Unifying them would silently rename one app's identifier. Same for
  `account` (imprint, iCloud) vs `accounts` (impart, email).

Regression oracles added: `SettingsSurfacePhase2ContractTests` (19 tests — frozen
inventories for all four apps, imbib's six sidebar bands and its 18 iOS sections,
tooltips, identifiers against `AccessibilityID.Settings.Tabs`, group contiguity
per platform, and a SOURCE SCAN asserting every declared pane has a factory and
every factory a declared pane, since the factories live in app targets PMC's test
bundle cannot link); `Phase2SettingsPersistenceTests` (8 tests — frozen
`@AppStorage` inventories per app: imbib macOS 6, imbib iOS 5, implore 5, impel 9,
impart 4 — and for implore and impart this is the ONLY place such a test can live,
implore having no unit-test target and impart no UI-test target); two new cases in
`imbib-iOSUITests/IOSSmokeUITests` (booted simulator — the declared sections
render and the four macOS-gated ones do not, and a `helixModeEnabled` toggle
survives `terminate()` + `launch()`). `SettingsSurfaceContractTests.testRenderersStayPlatformGated`
gained the third renderer.

Phase 3 candidates, all recorded above rather than done: link
PublicationManagerCore into `impart-iOS`; align impart's two hand-rolled clones;
give impel an `automation` pane (its `ImpelHTTPServer` reads
`httpAutomationEnabled`/`httpAutomationPort` that **no impel pane writes** — the
server is unconfigurable from the GUI); reconcile impel's `counselModel`, which has
two conflicting `@AppStorage` defaults in two files.

### Publication detail pane (`Chassis/Detail/`, Stage 5b, 2026-07-30)

The third iOS-duplication pass, after the sidebar (wave 3) and Settings (phase
2). imbib-iOS had five bespoke detail views — `IOSDetailView` (246),
`IOSInfoTab` (705), `IOSPDFTab` (462), `IOSBibTeXTab` (126), `IOSNotesTab` (76)
— against the chassis's `DetailView` + `InfoTab`/`PDFTab`/`NotesTab`/`BibTeXTab`.
**Only one of the five was one surface written twice**, and the per-tab verdicts
matter more than the line count, so they are recorded per tab:

| Tab | Verdict | What moved cross-platform | What stayed two, and why |
|---|---|---|---|
| **BibTeX** | **ONE SURFACE — collapsed outright.** `IOSBibTeXTab` DELETED; `BibTeXTab.swift` un-gated and used by both | the whole tab (same state machine, same `BibTeXEditor`, same `exportBibTeX` load, same save-by-reparse) | one parameter, `confirmsUnsavedDiscard`: iOS asks before discarding an edit, macOS's Cancel discards silently and is frozen |
| **Notes** | **SPLIT — two editors, one document.** | `PublicationNotesDocument` (the `note` field's YAML-front-matter + freeform format) and `PublicationNotesWriter` (500 ms debounce + the "selection moved on" guard both had a copy of) | macOS shows the inline annotation fields plus a hybrid markdown/preview area in a resizable panel BESIDE the PDF; iOS is one full-screen editor with Scribble and optional Helix. A phone has no room for the panel, and macOS's `HelixNotesTextEditor` is an `NSViewRepresentable` |
| **Info** | **SPLIT — same sections, different affordances.** | `PublicationIdentifierLink` (the four identifier URL templates), `PublicationFlagAndTagsSection` (a shared VIEW — collapsed fully), `PublicationExploration` (kinds, availability, labels, help text, one runner), `AttachmentManager.existingURL` | macOS: `FlowLayout` + `Link` + hover help + copy context menu, drag-and-drop attachments with a duplicate-hash alert, the in-app PDF browser, `CommentSectionView`, `CitedInManuscriptsSection`, a PDF-Sources section. iOS: horizontal scrolls, a per-attachment `Menu`, QuickLook, a share sheet. Collapsing these means `NSOpenPanel`/`NSWorkspace`/tooltips on a phone — the same finding Settings phase 2 recorded |
| **PDF** | **TWO DESIGNS — three duplications killed inside them.** | `PublicationPDFSwitcher` (the multi-PDF picker, near-identical), `PublicationPDFAvailability` (local / cloud-only / missing / remote / none), and iOS adopting `PDFURLResolverV2` + `AttachmentManager.resolveURL` | macOS owns E-Ink send, Handoff reading activity, corrupt-PDF recovery, space/j/k keyboard paging, auto-download policy from `PDFSettings`, and the browser WINDOW. iOS owns fullscreen-with-hidden-tab-bar, iCloud materialisation states, a determinate download progress bar with Cancel, and the browser SHEET. `PDFViewerWithControls` was already shared and still is |
| **Shell** (`DetailView`) | **TWO DESIGNS — one shared lifecycle.** | `publicationDetailLifecycle` (auto-mark-as-read after a 1 s dwell, the Recent-view dwell, and the live `ImbibImpressStore.events` refresh) | macOS is a `switch` inside the frozen `HSplitView` whose tab picker lives in the WINDOW toolbar; iOS is a `TabView` with a tab bar, a navigation bar and a More menu. Both have read WHICH tabs from `descriptor.availableTabs(for:)` since wave 2 |

**Six bugs the duplication was hiding, all fixed by the collapse** (each is now
a test in `PublicationDetailSharedSurfaceTests`):

1. **iOS notes showed the user their own YAML front matter as prose.** macOS has
   always parsed `note` as front matter + freeform; iOS read the field RAW into a
   plain editor and wrote the buffer back. Any iPhone user with quick annotations
   saw `--- / First Author: … / ---` above their notes, and deleting those
   confusing lines destroyed the annotations.
2. **iOS BibTeX edits to the cite key, the entry type or a DELETED field did
   nothing.** iOS looped `updateField` over the parsed entry's fields, which
   cannot express any of the three; macOS re-imports the entry.
3. **macOS's detail pane stopped live-refreshing after the first paper.** Its
   store-event subscription was a bare `.task {}` reading `publicationID` off
   the captured `self`, so it observed the id from the first body evaluation
   forever. The shared lifecycle keys the task on the id.
4. **iOS ignored `eprint`-only papers.** A paper whose arXiv id arrived in
   `eprint` rather than `arxiv_id` offered no PDF download on iPhone; macOS's
   PDF tab has always accepted it.
5. **iOS resolved PDFs with two hardcoded rules** (arXiv id, then the bare DOI
   resolver) while `PDFURLResolverV2` — cross-platform since it was written —
   honours the user's PDF settings, OpenAlex OA locations, the publisher
   registry, landing-page scraping and bibcode/eprint, and reports a browser
   fallback. iOS now calls it.
6. **The same paper listed its tags in a different ORDER on each platform**
   (macOS sorted by path, iOS used store order) and iOS showed leaf names where
   macOS showed full paths. One shared section now, with macOS's rendering.

Two more asymmetries closed in passing: iOS's More menu hardcoded three of the
four identifier URLs and had no PubMed row (it reads the shared declaration
now), and iOS's `resolveFileURL` / `pdfFileExists` were the same twelve
hand-rolled lines twice, each checking two of the four candidate paths
`AttachmentManager.resolveURL` knows.

| File | Reach | Role |
|---|---|---|
| `Chassis/Detail/Shared/PublicationIdentifierLink.swift` | ✅ both | the four identifier schemes: label, menu title, hover help, URL template. Was written out three times |
| `Chassis/Detail/Shared/PublicationFlagAndTagsSection.swift` | ✅ both | the ONE Flag & Tags section. Tap-to-filter arrives as a closure, because activating the filter bar is the LIST pane's capability (iOS passes nil — no filter bar to activate) |
| `Chassis/Detail/Shared/PublicationExploration.swift` | ✅ both | `PublicationExplorationKind` (5 cases; `.wosRelated` is DOI-gated and iOS-only by preset), the availability vocabulary that drives labels/help/enablement, and `PublicationExplorationRunner` — one `running` value in place of macOS's four and iOS's five `isExploringX` booleans, and one copy of the `ExplorationService` setup macOS had four of |
| `Chassis/Detail/Shared/PublicationNotesDocument.swift` | ✅ both | the `note` field's format + `PublicationNotesWriter` (debounced, publication-scoped). Also read by `InfoTab`'s author-annotation chips, so three readers of one field cannot disagree |
| `Chassis/Detail/Shared/PublicationPDFSwitcher.swift` | ✅ both | the multi-PDF picker; renders nothing below two PDFs, so the `count > 1` test lives once. `.menuStyle(.borderlessButton)` is an `#if` island inside |
| `Chassis/Detail/Shared/PublicationPDFAvailability.swift` | ✅ both | "where is this paper's PDF" as one value + `AttachmentManager.existingURL` (the existence-checked companion to `resolveURL`, which answers with a candidate path even on a miss — the subtlety that made the iOS copies look necessary) |
| `Chassis/Detail/Shared/PublicationDetailLifecycle.swift` | ✅ both | the three things every detail SHELL does. The read-state WRITE is injected: macOS routes through `LibraryViewModel` (whose `store` is a swappable protocol), iOS through `RustStoreAdapter` |
| `Chassis/Detail/Tabs/BibTeXTab.swift` | ✅ both | un-gated and made `public`; `init?(publicationID:)` is the id-only entry point iOS's pane uses |
| `Chassis/Detail/DetailView.swift`, `Tabs/InfoTab.swift`, `Tabs/NotesTab.swift`, `Tabs/PDFTab.swift` | macOS | the chromes. Genuinely AppKit-adjacent (NSPasteboard, NSSavePanel, NSWorkspace, `PDFBrowserWindowController`, `HelixNotesTextEditor` as an `NSViewRepresentable`) and each owns a piece of the fragile toolbar/HSplitView surface |

**What was NOT collapsed, deliberately.** The **Record Info** section is the
same data on both platforms and two different row SELECTIONS in two different
layouts — macOS a `Grid` with Added/Modified and a Citations row, iOS stacked
rows with `Date Added`/`Date Modified`-if-different plus a References row.
Unifying the selection would either add a row to the frozen macOS pane or drop
one from iOS, so it is a product decision, not a reframe; the shared-`Grid`
version is a follow-up. `CitedInManuscriptsSection` (already cross-platform) is
still not in the iOS Info tab — adding a section to iOS is a product change, and
this pass was about removing duplication, not growing surfaces. And the
`RelatedItemsSection` deferral for publication Info (see Known gaps) stands: it
needs the same dedicated pass.

Regression oracles: `PublicationDetailSharedSurfaceTests` (17 tests, `swift test`
— the identifier templates in shipped order, empty-identifier suppression, the
exploration availability/label/help rules including the un-loaded pane, the
DOI gate on WoS, the notes round trip that PRESERVES annotations when only the
freeform half is edited, the four PDF-availability classifications, `eprint`-only
fetchability, plus structural guards both ways: the seven shared files must not
be `#if os(macOS)`, the four chromes must stay so); the eight new rows in
`ChassisCrossPlatformContractTests.crossPlatformContractFiles`; and
`imbib-iOSUITests/IOSDetailTabsUITests` (booted simulator — select a seeded
paper, walk all four tabs, and reach the console).

### Console (`ImpressLogging`, Stage 5b, 2026-07-30)

`ConsoleView` is the console every impress app is supposed to share (root
CLAUDE.md, "Shared UI Patterns"). It compiled on iOS, but Copy and Export were
`#if os(macOS)` BODIES — dead controls — and it opened at `minWidth: 600`. So
imbib-iOS shipped `IOSConsoleView`: 310 lines with its own filter chips, its own
row view, its own export, a hardcoded `"imbib-log-…"` filename, and **no
Performance tab**, which made the `PerfMetrics` surface macOS-only.

| File | Reach | Role |
|---|---|---|
| `ImpressLogging/ConsoleView.swift` | ✅ both | filters, search, level toggles, the entry list, the empty state, export TEXT, copy text, the parameterized export filename, and both modes (Logs + Performance) |
| `ImpressLogging/ConsoleScreen.swift` | iOS | the presentation renderer: `NavigationStack` + inline title + Done. macOS puts `ConsoleView` in a `Window` (⌘⇧C) |

Two `#if` islands inside `ConsoleView`, for the reason `SettingsForm` has one: a
dense pointer toolbar (four toggles + a search field + three icon buttons) does
not fit an iPhone, and neither does a row of fixed-width columns. iOS keeps the
chip row + search bar + overflow menu and the two-line row it shipped; macOS is
byte-identical. Export on iOS writes the same text to a temp file and hands it
to a share sheet; Copy uses `UIPasteboard`. iOS's list has no `selection:`
binding — outside edit mode there can be no selection, so "Copy Selected" would
be a dead control (the `RecordTriageNewTagPrompt` rule); per-row copy is the
long-press menu and Copy All is in the overflow menu.

**imbib-iOS keeps the TYPE NAME `IOSConsoleView`** — now six lines wrapping
`ConsoleScreen(appName: "imbib")` — so `IOSSettingsView`'s `console` section
factory needed no edit, the same courtesy the settings migration paid
`IOSContentView`. Every app that links ImpressLogging now has an iOS console,
and it has the Performance tab.

## MCP surface

ADR-0022 D5: every GUI verb gets a Rust service twin, and **only
service-backed ops are exposed**. Added as a section rather than a column
because the cells above are per-node/per-row and these tools are
schema-agnostic — one tool automates the same cell across every kind.

Registered by `crates/impress-store-service` (`#[impress_service]` →
MCP tool + CLI subcommand + impel agent tool, all generated), force-linked
into `crates/impress-mcp/src/main.rs`. Never withheld by the reachability
gate: these open the shared sqlite store directly and answer with every app
closed, so no new "always available" mechanism was needed — their namespaces
simply are not in `reachability::APP_GATED`.

The CLI half of that codegen is hosted by `crates/impress-cli` (binary:
`impress`), the store-generic sibling of `imbib` and `imprint`. It takes a
global `--store-path` (or `IMPRESS_STORE_PATH`) and, unlike the long-lived MCP
server, **refuses to run** when that store cannot be opened rather than falling
back to an empty in-memory one — a one-shot command that answers `total: 0`
from a store it never reached is worse than no answer.

| Tool | Automates |
|---|---|
| `collection-service_tree` | sidebar tree read for `libraryCollection` / `manuscriptFolder` / `figureFolder` (Counts column's companion read) |
| `collection-service_create` | "New Collection / Subcollection / Folder" context-menu items |
| `collection-service_rename` | Rename column, all collection node kinds |
| `collection-service_reparent` | Drop target column: collection→collection reparent (cycle check is Rust's, not the sidebar VM's) |
| `collection-service_reorder` | Drag column: sibling reorder |
| `collection-service_delete` | Delete column, all collection node kinds |
| `collection-service_add-members` | Drop target column: pubs/manuscripts/figures → collection |
| `collection-service_remove-members` | unfile (e.g. `figuresUnfiled` drop) |
| `collection-service_member-counts` | Counts column |
| `triage-service_set-starred` | Star column of the record-kind descriptor contract, every kind |
| `triage-service_set-flag` | Flag column, every kind |
| `triage-service_add-tag` | Tag column, every kind |
| `triage-service_remove-tag` | Tag column, every kind |
| `triage-service_set-status` | Dismiss/Archive columns **for status-change kinds only** (manuscripts). Publications use the library-move dismissal and are NOT reachable this way; impel tasks move only through the kernel's `transition` |
| `store-query-service_search-all` | ⌘⇧F grouped global search (WP G4, D6) — one FTS query over every kind, per-kind capped, `schema_ref` on every hit |
| `store-query-service_related-items` | the generic Related info-pane section (WP G5, D8) — edges walked both directions across all edge types |
| `store-query-service_get-item` | select→detail read, every kind (WP G6): the universal envelope (title/status/flag/star/tags/envelope parent/ISO-8601 stamps) plus the payload as a JSON string, capped at 32 KiB with `truncated` + `note` when a `body_content` blows past it |
| `store-query-service_list-items` | list-row population for any kind (WP G6): a page of envelopes, `modified` desc with an id tiebreak so paging is a partition, `total` alongside. Empty `schema_ref` walks EVERY kind. Withholds nothing — a browse that hid dismissed rows would make its own `total` a lie |
| `docs-import-service_import-directory` | bulk "New Manuscript" + "file into folder", from a directory of markdown on disk. Ids are UUIDv5 over `"<collection>/<relative path>"`, so the run is **repeatable**: re-import updates bodies and titles in place, never duplicates, never double-files. Sets `format: "markdown"` explicitly; title from the first `# ` heading, filename stem otherwise. `dry_run` writes nothing and reports the counts the real run will produce |
| `docs-import-service_prune-empty-manuscripts` | Delete column for placeholder shells — manuscripts with a title and no body. Reports by default; deletes only under `apply`, and never touches a manuscript whose body has content (the emptiness test is the interlock). `collection` scopes the scan; `max_body_chars` widens "empty" to "near-empty" |

`binding` selects the hierarchy: `imbib` \| `manuscript` \| `figure` \|
`generic` (the mixed-kind `collection@1.0.0` schema). Verb names and argument
order mirror `impress_store_ffi::SharedStore::collection_*` so Swift, the CLI
and agents share one vocabulary.

**Schema convergence (WP G7)** adds three more tools —
`collection-service_migration-status`, `collection-service_migrate`
(`dry_run` first) and `collection-service_rollback` — which automate no matrix
cell at all. They are the deliberate, human-invoked entry points to the flagged
data migration that rewrites `imbib/collection` / `manuscript-collection` /
`figure-collection` rows onto `collection@1.0.0`, keeping every id, every
`Contains` edge and every envelope parent, and stashing each row's original
schema and payload verbatim so `rollback` is byte-faithful. The flag
(`collections.unified` in `store_metadata`) is **off by default and stays off**
until imbib-core's remaining legacy collection readers — `list_collections`,
`list_manuscript_collections`, `list_collections_for_publication`,
`rename_collection`, `delete_library_undoable`, plus
`FigureStoreReader.fetchFolders` — are moved onto the kernel FFI: they query
the legacy `schema_ref` literals directly and would go empty (or throw) the
moment it is flipped. `crates/impress-core/src/collection_migration.rs` carries
the full contract; the kernel reads correctly on both sides of the flip.

### Resources (WP G6)

Tools answer a question the agent knew to ask; resources answer the one it
cannot ask yet — *what is in this store?* Served over the MCP resources
protocol beside `impress://guide` (`crates/impress-mcp/src/server.rs`), from
data assembled in `crates/impress-store-service/src/browse.rs`. Live reads
over the same `impress.sqlite` the tools mutate, `--store-path` honoured
(`main.rs` hands that path to `impress_store_service::set_store_path` before
the first dispatch; the resources use the same lazily-opened handle).

| Resource | Payload |
|---|---|
| `impress://store/schemas` | `{store_path, total_items, schemas[], note}`; each schema row is `{schema_ref, name?, version?, inherits?, registered, item_count, fields[]}`. Every registered `impress-core` schema **and** every kind the store actually holds — unregistered ones (`imbib/collection`, an app's private kind) are listed with `registered: false` rather than hidden, because omitting them would misstate what `list_items` can browse. Populous kinds first, `schema_ref` tiebreak |
| `impress://store/collections` | `{store_path, bindings[], note}`; one entry per binding (`imbib`, `manuscript`, `figure`, `generic`) with `{binding, schema_ref, collection_count, collections[], error?}` and each node `{id, name, parent_id, sort_order, kind_scope?, member_count}`. Flat per binding — rebuild the tree from `parent_id` (null = root), never the envelope parent. One unreadable binding sets its own `error` and leaves the other three answering |

These are deliberately **not** tools. A `list_schemas` tool duplicating a
resource is the two-definitions-of-one-capability drift the Rust-first rule
exists to prevent; D5's "only service-backed ops are exposed" governs the verb
surface, and both resources are backed by plain functions in the same crate as
the services, tested against a temp store.

### Render / export — partially unblocked (WP G6 investigation 2026-07-27; Typst compile wired + imbib contract fixed same day)

D5 lists render/export tools. Typst compile now works headlessly and the imbib
compile contract is fixed; **the document-level stubs below are still stubs**
(Phase-3 cutover), and the rows record the gap so it stops being rediscovered.

| Capability | MCP tool | Status | Evidence |
|---|---|---|---|
| compile manuscript → PDF (Typst) | `imprint-manuscript-service_compile-typst` | ✅ works headlessly | `crates/imprint-service/src/handlers.rs` `compile_typst_dispatch` (under the new `typst-render` feature) writes `<source>` + the `CompileOptions` preamble into `~/Library/Caches/impress/imprint/compile/<hash>/main.typ`, compiles it with `imprint_core::render_project::compile_typst_project_to_pdf`, and returns `pdf_path` + `page_count` + warnings (never bytes). `impress-mcp` enables the feature in its dependency (`crates/impress-mcp/Cargo.toml`). Proven by `handlers::tests::typst_render::compile_typst_writes_a_well_formed_pdf_at_pdf_path` (well-formed `%PDF` at `pdf_path`) and `…::compile_typst_broken_source_returns_diagnostics_not_a_panic`. With imprint RUNNING the compile still goes to its live engine, and `imprint-service-http` now parks the returned bytes through `handlers::park_pdf_bytes` so both paths answer with a path, not a megabyte of JSON array |
| compile manuscript → PDF (via imbib) | `imbib-manuscripts-service_compile-manuscript` | ⚠️ app-gated by design; contract fixed | `crates/imbib-service/src/manuscripts_service.rs` still refuses with `NOT_RUNNING` when imbib is closed — that is the design (the running app must see the compile), not a defect. The two defects G6 found are fixed: the Swift route (`HTTPAutomationRouter.compileManuscript`) now sends `"ok": true/false` alongside `"status"`, plus `pageCount`, `messages` and `pdfPath`; and the Rust `CompileResult` decodes through a tolerant wire type (`ok` OR `status`, camelCase paths, `errors`/`warnings` folded into `messages`), so either side alone suffices — `compile_result_wire_tests` in the same file. `pdf_path` is real: imbib writes the PDF to `<app-group>/manuscripts/<id>/compile/manuscript.pdf` (`ManuscriptFiguresDirectory.compiledPDFURL`), which `render_pdf_page` can open |
| export document (typst/latex/text) | `imprint-manuscript-service_export-document` | ❌ blocked on imprint-service stub | `crates/imprint-service/src/handlers.rs:371` `Err(ServiceError::Internal("export_document not implemented in Rust (Phase 3 cutover)"))`; HTTP path `crates/imprint-service-http/src/lib.rs:55` |
| list documents | `imprint-manuscript-service_list-documents` | ❌ blocked on imprint-service stub | `crates/imprint-service/src/handlers.rs:359` `"list_documents not implemented in Rust (Phase 3 cutover)"`. Worse than an error: `DefaultImprintManuscriptService` swallows it to stderr (`manuscript_service.rs:176`) and answers `[]`, which is indistinguishable from "you have no documents" |
| get document | `imprint-manuscript-service_get-document` | ❌ blocked on imprint-service stub | `crates/imprint-service/src/handlers.rs:365` |
| fetch compiled PDF | `imprint-app-service_get-pdf` | ⚠️ app-gated, and the wire contract disagrees | Withheld while imprint is closed (`reachability.rs` `APP_GATED`). With imprint up, `crates/impress-app-client/src/imprint/app.rs:200` decodes a JSON `CompiledPdf` but the app returns raw `application/pdf` bytes → `decode_envelope` (`crates/impress-app-client/src/transport.rs:27`) fails |
| compile LaTeX → PDF | `imprint-manuscript-service_compile-latex` | ⚠️ real Rust, not built in | `crates/imprint-service/src/handlers.rs:173` calls `imprint_core::latex::compile_latex_tectonic` — but only under `--features tectonic-render`, which `impress-mcp` does not enable; the default build returns the "not enabled" DTO (`handlers.rs:197`). It also returns `pdf_len`, not bytes or a path |
| render a PDF page to an image | `render_pdf_page` | ✅ works | `crates/impress-mcp/src/server.rs` `handle_render_pdf_page` (hand-written; a property of the transport, not an app). It is now feedable headlessly: `compile-typst` returns a `pdf_path`, verified end-to-end against the shipped binary (compile → path → PNG page) |
| export BibTeX | `imbib-library-service_export-bibtex`, `_export-all-bibtex` | ✅ works headlessly | `crates/imbib-service/src/library_service.rs:1003` — straight against the shared store |

**The engine was never the problem.** `imprint-core` already had a real
headless Typst compiler with passing tests that assert `%PDF` bytes
(`crates/imprint-core/src/render_project.rs`, `compile_typst_project_to_pdf`),
behind `#[cfg(feature = "typst-render")]`. G6 listed four missing wiring steps;
(i)–(iii) are now done — the `typst-render` passthrough feature on
`imprint-service`, a real `compile_typst_dispatch`, and a `pdf_path`
`render_pdf_page` can consume. **(iv) is not**: adding
`imprint-manuscript-service` and `imbib-manuscripts-service` to
`reachability::APP_GATED` (or splitting their app-dependent methods out) so
`_list-documents` stops answering `[]` while imprint is closed is still open,
and is deliberately NOT a blanket gate — `compile-typst` is app-independent
now and must stay reachable with imprint closed, so that work has to split the
namespace, not gate it.

**Feature cost.** `typst-render` is OFF by default on `imprint-service` and
enabled explicitly by `impress-mcp` (`crates/impress-mcp/Cargo.toml`), because
linking Typst takes the release binary from 46,990,144 to 98,709,072 bytes
(45 → 94 MiB, +110%). The MCP server is the one consumer that wants a headless
compile; `imprint-service-http`, `imprint-selftest` and the app FFI would
otherwise pay that for nothing. The compile tests are gated behind the same
feature, so a default `cargo test -p imprint-service` never pays for a font
scan either.

Parity tests: `crates/impress-mcp/tests/mcp_surface_parity.rs` asserts every
tool name above is enumerable and that this file documents each one;
`tests/inventory_smoke.rs` (`--ignored`) proves the shipped binary lists the
tools and both resources. Resource listing is additionally unit-tested
in-process in `crates/impress-mcp/src/server.rs::resource_tests`.

## Known gaps (tracked)

- **Ten `UTType(exportedAs:)` identifiers in shared code are declared per app,
  not in `apps/chassis-utis.yml`** (`com.impress.paper-reference`,
  `citation-key`, `conversation-ref`, `document-reference`, `figure-reference`,
  `research-artifact-reference`, `veusz-plot-reference`, `com.imbib.bibtex`,
  `com.imbib.bundle`, `com.impress.bibtex-entry`). Their call sites are in
  PMC/ImpressKit — code every app compiles — so each is only safe while every
  app that reaches its call site declares it; that property is unaudited.
  `ChassisUTIDeclarationTests.appDeclaredExceptions` pins the list (a NEW
  exported type cannot join it silently) and names the follow-up: audit
  reachability per linking app, then graduate each identifier into the shared
  template or move its call site out of shared code.

- **iOS shell — things that are still literals and should be declarations.**
  (a), (c) and (d) below were CLOSED on 2026-07-29 — kept with their outcome
  rather than deleted, because the shape of each fix is the precedent for the
  next one:
  (a) ~~`TriageCapabilities.statuses` is `[String]`~~ — **closed.** It is
  `[StatusSpec]` (raw + label + symbol + `isTerminal` + `hiddenByDefault`);
  `RecordStatusPresentation` became a resolver over the descriptors and macOS's
  four sidebar literals now read the same specs. `RecordKindStatusSpecTests`
  freezes the presentation both platforms shipped.
  (b) `AppShellConfiguration` declares no per-section ICON beyond
  `SidebarSectionType.icon`, and the "All <Kind>s" node borrows the section's
  icon. (Its TITLE is now `descriptor.pluralDisplayName`; the icon is not.)
  (c) ~~`ManuscriptStoreAdapter` has no `listTags()`~~ — **closed.**
  `listTags()` derives the distinct paths from the manuscript items' own `tags`
  and imprint-iOS's `availableTagPaths` reads it, so the Tags submenu is
  populated. NOTE the derivation: there is no tag-listing verb in the
  `SharedStore` FFI (only `add_tag`/`remove_tag`), so this is a scan, not an
  index — a `distinct_tags(schema_ref)` service verb would be strictly better.
  (d) ~~imprint-iOS suppresses `.citedInManuscripts` with an app-side `!=` on a
  section name~~ — **closed.** The host declares
  `presenting([.manuscript])` and the builder drops every section bound to a
  kind the host cannot render. See the `canPresent` row in the rules table for
  how it relates to the appID facet gate (it complements it).
  (e) There is no iOS drag-to-folder: moving a record is the
  "Move to Folder ▸" menu (`RecordFolderMenu.moveTo`), and folder reparenting
  is "Move Folder ▸"; the kind's `dragUTTypeIdentifier` is unused on iOS.

- **macOS shows four of the manuscript kind's seven statuses; iOS shows six.**
  `ImbibSidebarViewModel.journalChildren` surfaces Drafts / Submitted /
  Published / Archive and has never shown Internal Review or In Revision;
  `RecordSidebarBuilder` shows every status that is not `hiddenByDefault`.
  Since 2026-07-29 both read their LABELS and ICONS from the same `StatusSpec`s,
  so they cannot disagree about what a status looks like — but they still
  disagree about which ones appear, and macOS's set is a literal list of four
  `JournalManuscriptStatus` cases. Closing it is a product decision (add two
  rows to macOS, or mark those two `hiddenByDefault` and remove two from iOS),
  not a refactor; `hiddenByDefault` is the seam it would use.

- **`JournalManuscriptStatus.displayName` / `.systemImage` is a second status
  vocabulary.** It is singular and badge-shaped ("Draft", "Archived", `eye`,
  `xmark.bin`) where `StatusSpec.label` is navigational ("Drafts", "Archive",
  `person.2`, `xmark.circle`), and macOS's `ManuscriptDetailView` badge and
  `JournalManuscriptsListView` read it. Folding it into the descriptor would
  change macOS pixels, so it was left alone; if a `StatusSpec` ever needs a
  second, singular label, this is the caller that wants it. `isActive` HAS been
  folded in (it derives from `StatusSpec.isTerminal`).

- **Mail (Stage 2-A) IMAP-owned gaps — two CLOSED by Stage 4c, the rest still
  IMAP-owned by design:** no message drag (move = IMAP move), no folder CRUD
  (IMAP owns folder lifecycle), no delete/dismiss (descriptor `.none`/`.none`;
  `d` returns `.ignored`), and no thread expand/collapse in the list (badge +
  detail-pane thread view only). Also: IMAP-driven store writes land through
  impart's OWN SharedStore handle (MessageManagerCore), so the chassis list only
  refreshes on in-process StoreEvents (star/flag/tag) or scope change/relaunch.

  **CLOSED 2026-07-30 (Stage 4c), because both blocked making the chassis
  impart's only window:**
  - *compose* — was "compose stays in classic window". `MessageRecordKind`
    now declares one `CreationAffordance("New Message")` and the HOST performs
    it: `RecordHostVerbs.onCreate`, registered by `MailChassisHost`. The chassis
    contributes the affordances it owns (`n` in the list, the empty-state button)
    and still knows nothing about drafts or SMTP. ⌘N / File ▸ New Message /
    `impart://compose` all route to the same handler. Reply and Forward came
    along with the Core Data lookup and are now REACHABLE for the first time
    (their only previous home, `MessageDetailView`, could never appear).
  - *mark-read on select* — was "read-state syncs over IMAP, not the store".
    Restated correctly: the store's `SharedItemRow.isRead` is a MIRROR of
    impart's Core Data (written by `MailStoreMirror`), so the chassis is a
    replica and must not write it. It now reports selection through
    `RecordHostVerbs.onSelect` (`RecordSelection`, carrying the payload
    `message_id` as `externalID` — the store item id is a UUIDv5 and is NOT
    `CDMessage.id`), and impart marks read through `MessageTriageService.markRead`
    plus a mirror `setMessagesRead`. The write is guarded on the resolved
    message's own read flag: mark-read mirrors back as a store mutation →
    `StoreEvents` → list reload, so an unguarded write would let selection pump
    the list. Note the guard is on the WRITE, not the notification — filtering
    unread-only in the chassis would leave the host's reply target stale.

- **`RecordHostVerbs` / `ChassisNavigation` (Stage 4c) — two ADDITIVE seams,
  flagged here because they are chassis edits made for an app's benefit:**
  `RecordHostVerbs` (`Chassis/Shared/RecordHostVerbs.swift`) is a per-kind
  environment registry of the two verbs a host owns and the chassis cannot
  perform — `onCreate` (the app's answer to a declared `CreationAffordance`) and
  `onSelect` (the app's chance to react to a record being displayed). The
  alternative was for impart to register a REPLACEMENT section view in
  `RecordViewerRegistry`, i.e. to copy `MessageSectionView`'s pane-layout body
  into an app target — re-introducing exactly the per-app chassis clones Stage 4b
  deleted. Deliberately only two verbs: delete/move/reply have their own declared
  capability or none, and smuggling them through a host bag would route around
  the descriptors. `ChassisNavigation` generalises the `.openStoreSearch` shape
  (notification → `viewModel.navigateToTab`) to `.chassisNavigateToSurface`
  (object = a registered surface id) and `.chassisNavigateToDefaultSection`,
  because an app whose default window IS the chassis has to drive it from its own
  menu commands (impart's ⌘1-5) and URL scheme (impel's `impel://navigate/…`),
  and neither can reach `viewModel` nor should learn `ImbibTab`. Both default to
  EMPTY/no-op, so every shell that does not opt in behaves exactly as before.

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

- **Registry-resolved viewers (WP G3, ADR-0022 D4) — partial by design:**
  every kind's section view resolves through `RecordViewerRegistry` EXCEPT
  publications (their path owns the fragile HSplitView + toolbar cluster) and
  manuscripts (their section view owns the editor session, which must stay
  host-owned). `RecordViewerRegistryTests` asserts that absence, so registering
  either is a conscious edit. `AnyRecordListWrapper` has no consumer yet —
  grouped global search (G4/D6) is the first, and triage grammar
  (TriageKeyGrammar, swipe/context builders, drag) lands with it.

- **Navigation enums are ADDITIVE (Stage 3, 2026-07-30) — the ADR-0021 litmus
  step 6 wart is CLOSED for routes.** `ImbibJournalRoute`, `FigureRoute`,
  `MailRoute` and `AgentRoute` (18 cases, each enum's own doc comment calling
  itself "the mirror of" the previous one) plus their four `ImbibContentRoute`
  wrapper cases, twelve `ImbibTab` cases and four `SectionContentView`
  dispatchers collapsed into ONE `RecordRoute` = `RecordKindID` +
  `RecordSidebarScope`, dispatched by ONE sink
  (`SectionContentView.recordSection`). Adding a record kind now costs a
  viewer-registry factory line, a `RecordRouteScope` conformance next to the
  kind's own list scope, and its sidebar node-building lines — no case in any
  chassis route enum. `RecordRouteTests` pins both the round trip (kind+scope
  in → the kind's parallel list scope out) and the ABSENCE of the collapsed
  declarations. STILL NOT additive: `SidebarSectionType` (its String rawValue
  backs persisted order/collapse state) and the per-kind sidebar node cases
  that BUILD rows from per-kind readers (`figuresAll`, `mailAccount`, …) — a
  kind's rows come from its own store reader, so those lines are per-kind code,
  not a chassis switch. Two subsets the chassis scope vocabulary has no word
  for ride `RecordSidebarScope.host` (its declared escape hatch) with the key
  spelled once next to the kind's scope: implore's "Unfiled"
  (`FigureListScope.unfiledRouteScope`) and impart's mail ACCOUNTS
  (`MessageListScope.accountRouteScope`). Promoting either to a first-class
  case is a follow-up, not a requirement.

- **Related section (WP G5, ADR-0022 D8) — additive, two deferrals:**
  adopted in the figure / message / task / agent-run Info tabs and the
  manuscript detail stack (table above). NOT in the publication `InfoTab`:
  that pane owns the fragile detail/toolbar layout imbib's CLAUDE.md warns
  about, so it waits for a dedicated pass. Row tap does nothing in v1 —
  navigation needs the registry open-behavior work, and a tap that silently
  did nothing would be worse than an inert row. No refresh-on-mutation
  either: the section loads on appear and on id change (edges change far less
  often than the record does).

- `flagColor` nodes have no context menu (e.g. "Clear all red flags").
- Journal fixed rows have no counts (needs async count snapshot).
- Artifact rows: no multi-select, no drag.
- Manuscript folder bulk delete has no batch mutation wrapper (N sequential
  deletes; fine at current scale).
- **G2 strangler remainders (ADR-0022 D3) — delegation DROPPED (2026-07-27):**
  `CollectionStoreAdapter` no longer calls `RustStoreAdapter` for any verb.
  `rename`, `reorder`, `delete` and Contains-edge `addMembers` run on the
  kernel, and undo is kernel-backed end-to-end: each verb registers its
  documented inverse from what the kernel returns
  (`SharedCollectionMutation.prior` for rename/reorder/reparent,
  `SharedDeletedCollection` + `collectionRestore` for delete, the ids
  membership ACTUALLY changed for add/remove) instead of re-reading the store
  to guess one. Undo action names are unchanged, so the Edit menu reads
  identically ("Edit name", "Edit sort_order", "Delete", "Add to Collection",
  "Move Folder" — asserted by `CollectionStoreAdapterTests`); `removeMembers`
  gained an undo it never had. `create` takes the kernel's new `sort_order`
  argument, so the figure append-to-end second `collectionReorder` is gone.
  Still open: the `migratedFolderBindings`
  gate in `ImbibSidebarViewModel` still names which kinds route through the
  adapter; publication collections stay on the legacy path until G7. Known
  wart, NOT introduced here: `UndoCoordinator.registerUndoClosure`
  re-registers the opposite half from inside a `Task { @MainActor }`, i.e.
  after the manager finished undoing, so a closure-based redo lands on the
  undo stack rather than the redo stack — shared by every closure undo in the
  app (delete papers, tag ops, reparent).
  **Remainder #5 CLOSED (2026-07-27):** the two identical drag-session
  singletons merged into one `RecordDragSession`
  (`Chassis/RecordKind/RecordDragSession.swift`), one instance per
  `CollectionBindingID` (sessions stay per-binding so a manuscript drag can
  never satisfy a figure-folder drop). `ManuscriptDragSession` /
  `FigureDragSession` are deleted; the list wrappers call
  `RecordDragSession.manuscript` / `.figure`, and
  `ImbibSidebarViewModel.dragSession(for:)` is now a registry lookup instead
  of a switch.
- **Submissions inbox is unreachable in imbib after publications-only
  purification** — it lived under the Manuscripts section, which imbib no
  longer surfaces. Its DESIGNATED home is now the `impress` preset
  (`auxiliaryRoutes: [.submissionsInbox]`, asserted by
  `testImpressPresetMatchesFrozenTruthTable`), which ships no app target yet —
  so the route is spoken for but still not reachable by a user. Adopting it in
  imprint before impress exists remains an option. The `auxiliaryRoute` and the
  `SubmissionsInboxView` feature are intentionally retained, not deleted.
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

## Schema refs (store `schema_ref`)

**Source of truth: [`schema-refs.json`](../schema-refs.json) at the repo root.**
Enforced by `scripts/check-schema-refs.sh` (every call site, Rust *and* Swift),
`crates/*/tests/schema_ref_manifest.rs` (registry parity, both directions,
per crate), and `SchemaRefManifestParityTests` (record-kind descriptors).

The impress store matches `items.schema_ref` by **exact equality**
(`crates/impress-core/src/sql_query.rs`). There is no version tolerance, no
namespace fallback, no fuzzy match. A reader that spells a ref differently from
its writer returns **zero rows, forever, silently** — no error, no log line.
That is indistinguishable from "the user has no data yet", which is why this
class of bug survives both code review and CI, and why it has shipped five
times:

| Where | Written | Read | Effect |
|---|---|---|---|
| iOS citation picker | `imbib/bibliography-entry` | `bibliography-entry` | empty library, 100% of the time |
| `/api/manuscripts` | — | `manuscript-section` items | reported `count: 0` while the UI listed manuscripts |
| imprint sections | `manuscript-section` | `manuscript-section@1.0.0` | outline, `/api/manuscripts/{id}/sections`, cross-document search structurally empty |
| citation usage | `citation-usage` | `citation-usage@1.0.0` (×4, imprint + imbib) | "papers cited in my manuscripts" always empty |
| impel enrichment | `imbib/bibliography-entry` | `bibliography-entry@1.0.0` | enrichment spawn rule never fired — no task ever spawned. Fixed 2026-07-29; the trigger now reads the canonical ref and `enrichment_trigger_matches_the_ref_imbib_actually_writes` seeds through imbib's real writer so it cannot drift back |

**There is no naming convention to infer.** Bare (`manuscript`), namespaced
(`imbib/library`, `core/operation`) and versioned (`task@1.0.0`) spellings all
exist and are all correct *for their kind*. Do not regularise a ref by
pattern-matching on its neighbours — that is precisely the reasoning that
produced `manuscript-section@1.0.0`. **Copy the spelling from
`schema-refs.json`, never from a sibling call site.**

`knownDivergences` in the manifest records the splits that are real and
unfixed (three live spellings of `task`, the dead `impress/operation`
registration, the enrichment trigger, `ArtifactRecordKind`'s unwritten
`artifact` ref). It is a **ratchet**: it may shrink as splits are fixed, never
grow. Adding an entry requires editing a file called `knownDivergences` and
tripping the budget assertion — the point is that making a new mismatch legal
should be conspicuous.
