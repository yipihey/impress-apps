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
| `manuscriptFolder` | ✅ Rename/Subfolder/Delete | ✅ (needs `makeIfNecessary: true` + ancestor expand in `beginEditingNode`) | ✅ (⌫ + menu) | ✅ reorder+reparent | ✅ manuscripts, folders | ✅ | G2 (ADR-0022): served by the generic capability-driven folder block over `CollectionStoreAdapter` → Rust `collection_ops` (manuscript binding: payload `parent_collection_ref` + Contains membership); cycle check now Rust-side |
| `figureFolder` | ✅ Rename/Subfolder/Delete | ✅ | ✅ (⌫ + menu; delete unfiles children via FK `ON DELETE SET NULL`, undo re-files) | ✅ reorder+reparent | ✅ figures, folders | ✅ | G2 (ADR-0022): same generic block, figure binding (ENVELOPE parent + envelope membership); reparent gained Undo it never had |
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
| custom surfaces | — | — | generate, analyze (registered app-side via `withCustomSurfaces`); canvas = figure open window | chat, research, development (registered app-side via `withCustomSurfaces` in ImpartChassisRoot) | dashboard, escalations, suggestions, counsel (registered app-side via `withCustomSurfaces` in ImpelChassisRoot; escalations keeps its 1-9/j/k keys INSIDE the surface, keyboardGuarded) | — none app-registered; the chassis-builtin store-search surface arrives anyway (`StoreSearchSurfaceTests` enumerates impress too). App-owned surfaces can only be registered by an app target, and there is none |
| default window | chassis | chassis | chassis | classic ContentView — chassis is a SECONDARY "Mail (Unified)" window; flips via UserDefaults `impart.useChassisWindow` (compose/reply not chassis-wired yet — the one sanctioned deviation from replace-outright) | classic ContentView — chassis is a SECONDARY "impel (Unified)" window; flips via UserDefaults `impel.useChassisWindow` (escalation resolution / counsel not chassis-wired yet — same sanctioned deviation as impart) | ➖ no app target ships this preset (ADR-0022 D9). When it does: a ~120-line `ImpressChassisRoot`, and a signing decision first — impress permits `.search`, so `TabContentView`'s ADS/SciX keychain read WOULD run in it, and those items are ACL'd to imbib's code signature (imbib CLAUDE.md invariant). Either impress ships with imbib's keychain access group or that read moves behind a reachability check |

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
| `Chassis/RecordKind/RecordScopeKey+MacScopes.swift` | macOS | SPLIT out: the four list scopes live inside gated list wrappers |
| `Chassis/RecordKind/KindTaggedRow.swift` | ✅ both | row type + the one generic `init(kind:item:)` |
| `Chassis/RecordKind/KindTaggedRow+RowData.swift` | macOS | SPLIT out: names the gated per-kind row structs |
| `Chassis/AppShellConfiguration.swift` | ✅ both | presets are the app's declarative identity |
| `Chassis/CustomSurface.swift` | ✅ both | registry is data; only `builtin` (StoreSearchSurface, AppKit) is gated inside |
| `Chassis/Shared/SchemaRefKindLookup.swift` | ✅ both | tolerant schema-ref → kind lookup |
| `Chassis/Shared/RecordTriage.swift` | ✅ both | action bag + swipe/menu builders (plain SwiftUI) |
| `Chassis/Shared/RecordTriageNewTagPrompt.swift` | both, gated body | SPLIT out: the NSAlert prompt; iOS omits the affordance rather than showing a dead button |
| `Files/SidebarSectionOrderStore.swift`, `SharedViews/DetailTab.swift` | ✅ both | never gated |

Enforcement is automated, not conventional: `ChassisCrossPlatformContractTests`
asserts (a) descriptors, presets, schema-ref lookup and `KindTaggedRow`
resolve, (b) the manuscript kind still declares the reserved lifecycle iOS
reads, and (c) **the contract files do not start with `#if os(macOS)`** — the
guard against a future chassis file copying the historical header verbatim.
The imprint-iOS build (`-scheme imprint-iOS -destination
'generic/platform=iOS Simulator'`) is the compile-level gate.

**Rule when a macOS-only symbol lands in a contract file: SPLIT the file**
(data here, AppKit companion gated) — never re-gate the contract.

### iOS shell surface (`Chassis/Shared/RecordSidebar/`, 2026-07-29)

macOS renders its sidebar with `ImbibSidebarViewModel` + `SidebarOutlineView`
(NSOutlineView). iOS cannot use either, so the SHAPE of a sidebar was lifted
out of the renderer into data that both platforms could in principle share and
that iOS actually does:

| File | Reach | Role |
|---|---|---|
| `RecordSidebar/RecordSidebarModel.swift` | ✅ both | `RecordFolder`, `RecordSidebarScope` (+ `RecordScopeKey`), `RecordSidebarNode`, `RecordSidebarSectionModel`, `RecordSidebarSectionRole`, `RecordStatusPresentation` |
| `RecordSidebar/RecordSidebarBuilder.swift` | ✅ both | `AppShellConfiguration` × `RecordKindDescriptor` × `RecordSidebarDataSource` → `[RecordSidebarSectionModel]`; `AppShellConfiguration.effectiveRecordKind(for:)` |
| `RecordSidebar/RecordCollectionActions.swift` | ✅ both | organise verbs as an action bag + `RecordFolderMenu.moveTo` / `.organize` (SwiftUI menus, usable on macOS too) |
| `RecordSidebar/RecordTriageListRow.swift` | ✅ both | `.recordTriageRow(...)` — one modifier attaching `TriageSwipe` + `TriageMenu` to a list row |
| `RecordSidebar/RecordSidebarView.swift` | iOS | the renderer (List + sections + folder tree + name sheet) |

Rules the builder applies, all read from declarations rather than written per
app:

| Question | Answered by |
|---|---|
| which sections | `visibleSections` ∩ `passesFacetGate` ∩ host content gate (`RecordSidebarDataSource.sectionIsAvailable`) |
| which kind a section serves | `sectionBindings[section]`, falling back to the canonical table = `AppShellConfiguration.impress.sectionBindings` |
| section behaviour | `RecordSidebarSectionRole.role(for:)` — `.flagged` → per-`FlagColor` rows, `.dismissed` → the kind's dismissal semantics, otherwise `.primary` |
| status smart-children | `descriptor.triage.statuses`, minus the dismissed status (which owns the Dismissed section) |
| folder tree + organise verbs | `descriptor.collection` / `CollectionCapability.canOrganize` |
| section order + collapse | `SidebarSectionOrderStore` / `SidebarCollapsedStateStore` (the same persisted stores macOS uses) |

Adopters: imprint-iOS (`IOSManuscriptSidebarBindings.swift` — data source,
collection actions, triage actions, `RecordSidebarScope` →
`ManuscriptStoreScope`). imbib-iOS's hand-written `IOSSidebarView` is NOT
migrated yet; it remains the reference for iOS idiom and the obvious second
adopter.

Regression oracles: `RecordSidebarBuilderTests` (15 tests, `swift test` —
same builder + different presets ⇒ different sidebars) and
`imprint-iOSUITests/LibraryShellUITests` (5 tests, booted simulator — sidebar
tree, search, long-press menu, trailing swipe says Dismiss/Archive, dismissed
manuscript visible ONLY in the Dismissed scope).

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

- **iOS shell — things that are still literals and should be declarations:**
  (a) `TriageCapabilities.statuses` is `[String]`, so a status has no declared
  label or icon; `RecordStatusPresentation` carries a chassis-level table for
  the reserved lifecycle values and title-cases anything else. Widening
  `statuses` to `[StatusSpec]` (raw + label + symbol) is the principled fix.
  (b) `AppShellConfiguration` declares no per-section ICON beyond
  `SidebarSectionType.icon`, and the "All <Kind>s" node borrows the section's
  icon. (c) `ManuscriptStoreAdapter` has no `listTags()`, so imprint-iOS
  passes `RecordTriageActions.availableTagPaths = { [] }` and the Tags submenu
  hides itself; tag triage on iOS is unavailable until that verb exists.
  (d) imprint-iOS suppresses the preset-permitted `.citedInManuscripts`
  section through the host content gate because it has no publication list
  surface — honest, but it is an app-side `!=` on a section name.
  (e) There is no iOS drag-to-folder: moving a record is the
  "Move to Folder ▸" menu (`RecordFolderMenu.moveTo`), and folder reparenting
  is "Move Folder ▸"; the kind's `dragUTTypeIdentifier` is unused on iOS.

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

- **Registry-resolved viewers (WP G3, ADR-0022 D4) — partial by design:**
  only the `.figures` / `.mail` / `.agents` routes resolve their section view
  through `RecordViewerRegistry`. Publications keep the legacy path (it owns
  the fragile HSplitView + toolbar cluster) and manuscripts keep theirs (the
  section view owns the editor session, which must stay host-owned).
  `RecordViewerRegistryTests` asserts that absence, so registering either is
  a conscious edit. `AnyRecordListWrapper` has no consumer yet — grouped
  global search (G4/D6) is the first, and triage grammar (TriageKeyGrammar,
  swipe/context builders, drag) lands with it.

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
