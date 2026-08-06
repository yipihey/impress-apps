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
| `appGroup` (X3, 2026-07-31) | ➖ | ➖ | ➖ | ❌ never — group order is `SiblingApp.descriptors`', not a user preference | ❌ refuses every drop, including a section from another group (logged once per pair, not silently) | ➖ | **COMPOSED shells only (macOS impress).** One sibling app's whole sidebar as a collapsible tier above the section headers. `isAppGroup` is a NEW flag, separate from `isGroup`: the two tiers coexist and render differently, and folding them together would demote section headers to ordinary rows and lose `sectionMenu`. Not selectable (`shouldSelectItem` → false), `imbibTab` nil, `capabilities` `.readOnly`. Rendered by `SidebarOutlineCellView.configureAsAppGroup` — an ADDITIVE method reached only via `SidebarOutlineConfiguration.isAppGroupItem`, which is **nil** in all five single-preset shells, so their cells are produced by exactly the code that produced them before. Collapse persists under `SidebarCompositionKey.group(<app>)` |
| `section(...)` INSIDE an `appGroup` | ✅ unchanged (`sectionMenu` still consulted) | ➖ | ➖ | ✅ reorder **within its own group only** | ✅ its own group header | ✅ per-group | X3. Same node kind, same cell path, same menu — the group travels on the node (`appGroup: SidebarNodeGroup?`) and decides three things the flat tree never had to ask: which PRESET binds this section's kind, which id NAMESPACE it lives in (`.flagColor(.red)` occurs in several groups and `ImbibSidebarNodeID` is deterministic — ungrouped ids would collide in `SidebarOutlineView`'s UUID-keyed caches), and which `SidebarCompositionKey.section(<app>, <section>)` persists its collapse. `treeDepth` gains exactly one level for the whole subtree, applied once in `children(of:)` — the ten hand-assigned `treeDepth` sites are untouched |
| `section(.inbox)` | ✅ Add Feed / New Collection | ➖ | ➖ | ✅ reorder | ✅ pubs, expl. search→feed | ✅ | |
| `section(.libraries)` | ✅ New Library | ➖ | ➖ | ✅ reorder | ➖ | ➖ | |
| `section(.manuscripts)` | ✅ New Folder | ➖ | ➖ | ✅ reorder | ✅ folder→root | ➖ | added 2026-07. **imprint-only surface since the 2026-07-27 publications-only purification** — imbib's `visibleSections` no longer contains `.manuscripts`. The chassis code (ManuscriptSectionView, folder block, CollectionStoreAdapter manuscript binding) is UNCHANGED: imprint runs on it |
| `section(.figures)` | ✅ New Folder | ➖ | ➖ | ✅ reorder | ✅ folder→root | ➖ | Stage 2-B; **implore-only surface** — excluded by every other preset's `visibleSections` (imbib's became explicit 2026-07-27). The pragmatic appID gate stays as belt-and-braces for any shell that leaves `visibleSections` nil — since ADR-0022 G8 it is an owner SET, `{implore, impress}` (`AppShellConfiguration.facetOwnerAppIDs`), not an `appID ==` test: with equality the impress preset could permit the section and the sidebar would still drop it |
| `section(.mail)` | ❌ none (no folder CRUD — IMAP owns folder lifecycle; Stage-2-A2 follow-up) | ➖ | ➖ | ✅ reorder | ➖ | ➖ | Stage 2-A; **impart-only surface** — same double gate as Figures (`visibleSections` everywhere else + `shouldShowSection` owner set `{impart, impress}`) |
| `section(.agents)` | ❌ none (no task creation — the kernel schedules tasks; commands stay on impel's HTTP path) | ➖ | ➖ | ✅ reorder | ➖ | ➖ | Stage 2-C; **impel-only surface** — same double gate as Figures/Mail (`visibleSections` everywhere else + `shouldShowSection` owner set `{impel, impress}`) |
| `section(.search)` | ✅ Show Hidden Forms | ➖ | ➖ | ✅ reorder | ➖ | ➖ | imbib only |
| `section(.flagged)` | ➖ | ➖ | ➖ | ✅ reorder | ➖ | ✅ | counts = pubs (imbib) / manuscripts (imprint) |
| `section(.tags)` (2026-08-01) | ➖ no create verb — a tag path comes into existence by TAGGING a record (the shared `TriageMenu`), never by a sidebar affordance, so "New Tag…" would mint a vocabulary entry nothing carries | ➖ | ➖ | ✅ reorder | ➖ | ➖ the header carries no badge (its rows do) | The browse half of *"every artifact should be flaggable and taggable"*. Chassis role `RecordSidebarSectionRole.tags`, declared by the section (`SidebarSectionType.role`) exactly like `.flagged` — the two are siblings: both browse a MARK the user put on a record rather than a property the record has. The only structural difference is that flags are a closed set the chassis knows and tags are an open one the store reports, which is why this role needs a `RecordSidebarDataSource.tags` call and `.flagged` does not. **All six presets opt in, each binding its OWN kind** (`sectionBindings[.tags]`: imbib/impress → `.publication`, imprint → `.manuscript`, implore → `.figure`, impart → `.message`, impel → `.task`) — an empty binding map falls back to the canonical impress table, where `.tags` is `.publication`, so a silent inherit would have put paper tags in implore's sidebar. Rows are gated on the kind's declared `triage.canTag`, the SAME declaration the `TriageMenu` reads to offer the Tags submenu, so a kind cannot be taggable in the menu and unbrowsable in the sidebar. macOS additionally applies the content gate every section here has (`shouldShowSection` → `!listTags().isEmpty`), and the gate reads the WHOLE vocabulary rather than the filtered one — a section that vanished on the first non-matching keystroke would take the filter field's subject off screen mid-sentence. **A FILTERED Tags section survives its own emptiness** for the same reason (`RecordSidebarBuilder`'s `keepEmpty`), which is the one place the sidebar's negative-space contract is deliberately suspended: everywhere else "no rows" means "this shell cannot serve this", but "nothing matches what you typed" is exactly what a filter field exists to say. **`SidebarSectionOrderStore.defaultOrder` is load-bearing, not decoration**: `orderedVisibleSections` FILTERS by it, so a section missing from that array renders on NEITHER platform however many presets opt in — which is what `.tags` did between its first commit and the filter pass, on both. The persistence store back-fills sections added after a user's order was saved, so an existing install gains the row at the end |
| `library` | ✅ full | ✅ | ✅ confirm | ✅ | ✅ pubs, collections | ✅ | |
| `libraryCollection` | ✅ Rename/Subcoll/Delete | ✅ | ✅ (no confirm, single) | ✅ | ✅ pubs, reparent | ✅ | parent_id regression fixed 2026-07. **C2 (ADR-0022, 2026-07-30): the VERBS converged onto the generic folder path.** `folderNode(_:)` resolves `.libraryCollection`, so rename / reorder / reparent / delete / membership / menu all run through `CollectionStoreAdapter` on the publication binding — `buildCollectionContextMenu` is DELETED and the labels are the capability's (`containerNoun: "Collection"`, `deleteTitleOverride: "Delete"`). Cross-library reparent is now ONE atomic kernel `reparent_in` carrying the owning library as the CONTAINER (it was two hand-ordered Swift writes) and gained a complete "Move Folder" Undo; the smart guard reads the kernel row's `is_smart`. The node CASE deliberately stays `.libraryCollection`: it maps to `.collection(id)`, a `PublicationSource` feeding the publication-only multi-select union, where `.recordFolder` maps to `.record(.folder(...))` — converging the ROUTE is `UnifiedPublicationListWrapper`'s remit. NOT converged: creation (kernel's create undo says "New Folder", imbib's says "Create Collection" — relabelling a live Edit-menu entry is a UX decision) and the node READS (still `store.listCollections`, which is the G7 flip blocker) |
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
| `watchedFolder` — **macOS** (ADR-0023 W2, 2026-07-31; W5 2026-08-01) | ✅ Refresh / **Review N PDF Matches…** (W5 — omitted entirely when the folder has nothing to review, the same rule Refresh and Choose Again… follow; opens `WatchedAttachmentOffersView` as a `.sheet(item:)` on `ImbibSidebarViewModel.attachmentReviewRequest`, the shape `scixLibraryToShowInfo` already uses, so no new presentation mechanism) / Choose Again… / Reveal in Finder / Stop Watching, plus the state's `explanation` as a disabled row (the outline row has no subtitle, and D6 requires the state to be VISIBLE, not to be in a particular slot). Refresh and Choose Again… are emitted only when `offersRefresh` / `offersReauthorization` say so — omit a dead affordance, never show one | ➖ the display name is the provenance tag's leaf and therefore the identity of "papers this folder produced"; renaming in place would orphan every tag already written | ➖ ⌫ on a row that owns imported papers reads as "delete the papers". The verb is **Stop Watching**, in the menu, where its consequence can be named (papers and their tags are KEPT) | ➖ not a container to reorder into | ➖ D4 is one-way: the watcher never writes user files, so a drop can mean nothing | ✅ **conditionally** — `displayCount: row.badgeCount`, never `discoveredCount` | **macOS wiring is a NODE CASE** (`ImbibSidebarNodeType.watchedFolder(folderID:tagPath:)`), which is the decision W1 left to W2. `customSurface` was rejected: `CustomSurface.swift`'s header fixes a surface as top-level, childless, countless and menuless, and this row needs children's four opposites. Cost is the declared one — four exhaustive switches gain an arm (`imbibTab`, `publicationSource`, `currentLibraryID`, `capabilities`), all compiler-enforced. Rows sit under **Libraries** (D2: a folder is a feed, and imbib's feeds sit beside the libraries they feed); "Add Watched Folder…" is in the Libraries section menu next to "New Library", via `NSOpenPanel(canChooseDirectories:)`. Select → `PublicationSource.tag("watched/<name>")` |
| `watchedFolder` — **iOS** (ADR-0023 W2, 2026-07-31) | ➖ v1: no row menu (the add/remove verbs are in the sidebar's `+` menu) | ➖ same reason as macOS | ➖ same reason as macOS | ➖ | ➖ | ✅ **conditionally** — and in practice NO badge, because iOS declares no live engine so a completed walk lands in `scanOnDemand`, whose `countIsTrustworthy` is false | **iOS needed no enum to grow**: rows ride W1's seam — `ImbibSidebarBindings.sectionContent(.libraries)` appends `rows.sidebarNodes(kind: .publication)`, and `WatchedFolderRoute(key:)` is resolved BEFORE `ImbibSidebarRoute` in `section(for:)` (which would return nil for a key it did not build and drop the selection silently). "Add Watched Folder…" is `.fileImporter(allowedContentTypes: [.folder])` in the sidebar's `+` menu. **W2 corrected the state**: a completed walk on a platform with no live engine is `scanOnDemand`, not `fallback` — `fallback` claims FSEvents, which iOS does not have, and the difference is load-bearing because only one of the two suppresses the badge |
| `watchedFolder` PDF attachments — **macOS** (ADR-0023 W5, 2026-08-01) | ✅ the review verb above; each offer row also carries **Reveal** and one **Attach** button per candidate | ➖ a PDF's name is the user's, and it is also the strongest matching signal — renaming it in imbib would be renaming a file the watcher promised never to write | ➖ nothing is deleted; an attached PDF that VANISHES keeps its `imbib/linked-file` row and is flagged (D4), never detached | ➖ | ➖ D4 is one-way | ➖ the offer count rides the folder row's existing badge; a second badge for "files awaiting review" would compete with the one that means "new papers" | **No new node case and no new tab.** W5 hangs entirely off W2's `watchedFolder` row: a context-menu verb, a sheet, and a `WatchedAttachmentOffer` value. The unit is declared, not coded — `FileDiscoveryCapability.attachmentTypes` on the publication kind (`.pdf`, UTI read from `UTType.pdf`), giving a third `FileIngestUnit`, `.attachment`. The role marker is **derived** (`ingestUnit(forFileName:)`), never stored: `watched-file@1.0.0` is unchanged, so W2's rows read correctly with no migration. **iOS: none, and that is the honest v1** — imbib-iOS's watched-folder rows have no row menu at all (W2's decision, the row above), so the review verb has nowhere to hang; the MATCHING runs on both platforms, only the review affordance is macOS-only. |
| `watchedFileFolder` — **macOS** (ADR-0023 W4, 2026-07-31) | ✅ Refresh / Choose Again… / Reveal in Finder / Stop Watching + the state's `explanation` as a disabled row — the SAME builder shape as `watchedFolder`, with the (folder, kindScope) pair carried in `representedObject` as a `WatchedFileFolderToken` because the coordinator is looked up BY kind and a bare folder id would have to guess which of the process's coordinators owns it | ➖ same reason as `watchedFolder` | ➖ the verb is **Stop Watching**; it removes the folder row and its `watched-file` rows and touches nothing on disk (D4). Nothing was produced from those files, so nothing is stranded | ➖ not a container to reorder into | ➖ D4 is one-way, and for a FILE-unit kind there is no record to drop onto a folder — only files the user puts there | ✅ **conditionally** — `displayCount: row.badgeCount`, never `discoveredCount`; the D6 invariant is kind-agnostic | **No new tab or content-route case.** The node case is new (`ImbibSidebarNodeType.watchedFileFolder(folderID:kindScope:)`, with its OWN id space — `tabToNodeID` is keyed by node id and the two watched row kinds open different surfaces) but it resolves to `ImbibTab.record(RecordRoute)` over W1's `.host(kind, key: "watched-folder.<uuid>")` scope, which Stage 3 already made the one destination every kind's rows resolve to. Rendering is a PREFIX arm in the kind's `RecordViewerFactory` (`RecordViewerRegistry+Builtin.watchedFilesPane`) → `WatchedFilesPane`; without it the host scope, which `FigureListScope`/`MessageListScope` correctly decline to parse, falls through to the factory's `EmptyView()` — a selectable row that opens nothing. Rows sit LAST in the **Mail** (impart, `.mbox`/`.eml`) and **Figures** (implore, `.vsz`) sections, so adding one never reshuffles rows a user has learned the position of; "Watch Folder for .mbox / .eml Files…" is appended to the section menu from the declared table `ImbibSidebarViewModel.watchedFileSections` (W3 added `.manuscript: .manuscripts` there, which is the whole join for imprint's rows). Select → the files, NOT records: nothing is minted (`WatchedFolderImportHooks.recordingOnly`), which is W4's decision and not a stub |
| `watchedFileFolder` — **imprint macOS** (ADR-0023 W3, 2026-07-31) | ✅ the SAME builder as every other file-unit watched folder (`buildWatchedFileFolderContextMenu`), reached through the shared `WatchedFileFolderToken` | ➖ the display name is the provenance tag's leaf, and the tag is the folder's list scope — renaming would orphan every tag already written | ➖ the verb is **Stop Watching**; the external manuscripts it produced are KEPT, tags and all (un-watching is not a retraction, D4) | ➖ not a container to reorder into | ➖ D4 is one-way; and a manuscript dropped onto a watched folder would mean "write this into the user's directory", which is precisely the write-back the ADR forbids | ✅ **conditionally** — `row.badgeCount`, never `discoveredCount` | **No new node case: W4's `watchedFileFolder` serves imprint unchanged.** The one-line join is `ImbibSidebarViewModel.watchedFileSections[.manuscript] = .manuscripts`, which also puts "Watch Folder for .typ / .tex / .md / .txt Files…" in the Manuscripts section menu beside New Folder. Rows sit LAST in **Manuscripts**, after the user's folders. Select → NOT the generic `WatchedFilesPane`: `.manuscript` has no `RecordViewerFactory` (the editor session must stay host-owned, and `RecordViewerRegistryTests` pins manuscripts as unregistered), so `SectionContentView.recordSection` resolves the host key through `ManuscriptListScope(routeScope:)` → **`.tag("watched/<name>")`**, i.e. the manuscripts the folder produced. That is W2's answer reused; for imprint the file-unit fan-out DOES mint a record, so listing files instead of records would be the weaker of the two |
| `watchedFileFolder` — **imprint iOS** (ADR-0023 W3, 2026-07-31) | ➖ v1: no row menu | ➖ same reason as macOS | ➖ same reason as macOS | ➖ | ➖ | ✅ **conditionally** — and in practice NO badge: iOS declares no live engine, so a completed walk lands in `scanOnDemand` and `countIsTrustworthy` is false | **A new chassis seam, `RecordSidebarSectionContent.additionalNodes`** — rows a host CONTRIBUTES, appended after the role-derived ones. `nodes` (W1/W2's seam) REPLACES, which is right for imbib's Libraries and wrong here: All + the six declared statuses + the folder tree all come from `ManuscriptRecordKind.descriptor`, so supplying `nodes` would have put a third copy of the status list inside a host. `ImprintSidebarBindings.storeScope(for:)` resolves the `.host` key through `WatchedFolderRoute` BEFORE anything else (imprint had no `.host` rows at all until W3) → `ManuscriptStoreScope.tag`. Adding a folder is not yet offered on iOS (no `fileImporter` entry point); recorded as W3 debt |
| `external manuscript` detail — **imprint iOS** (ADR-0023 W3/D4, 2026-07-31) | ➖ | ➖ the title is the file's name until the user changes it | ➖ the row is never deleted, even when the file vanishes (D4) — it is flagged `watched/removed-from-source` | ➖ | ➖ | ➖ | **`IOSExternalManuscriptPane`, not the editor.** A manuscript carrying `external_source` takes NO editor session (`WatchedManuscriptGuard.allowsEditorSession`), so there is no debounced save that can land on a file somebody else is editing. The pane is a reader plus D4's two affordances: **Open in Another App** (the explicit handoff) and **Import a Copy** (an ordinary manuscript, `import_source`, no claim on the file). Editing a watched file inside imprint's editor is the recorded deferral — `ManuscriptEditorSession.saveCAS` writes the STORE and has no file seam, and giving it one is ADR-0023's first listed risk |
| `watchedFolder` — chassis (ADR-0023 W1, superseded row, kept for the W1 record) | — | — | — | — | — | — | W1 shipped the row VALUE and the `.host(kind, key: "watched-folder.<uuid>")` scope with zero chassis edits; W2 wired both platforms to it. `WatchedFolderRowState` still computes `statusLine` / `explanation` / `systemImage` / `badgeCount`, and both hosts render them verbatim — neither recomputes a badge, which is the one line that keeps "an unindexed volume renders as 0 files" out || `inboxCollection` | ✅ | ✅ | ✅ | ➖ | ✅ pubs | ✅ | C2: DECLARED as the `inbox` tier on the publication `CollectionCapability` (`allowsRename: true, allowsSubcontainers: true`) but NOT yet routed — its nodes are still built from `store.listCollections(inboxLib.id)`, so moving the writes alone would give one tree two writers. Converts with its reads |
| `searchForm` | ✅ Hide | ➖ | ➖ | ✅ reorder | ➖ | ➖ | |
| `flagColor` | ❌ none | ➖ | ➖ | ✅ reorder | ➖ | ✅ | |
| `tag` (2026-08-01) | ❌ none — **planned, and blocked on a Rust verb.** Rename/Delete on a tag row are vocabulary-wide rewrites across every kind that carries the path (and its descendants), not an edit to the row; the honest menu needs `rename_tag_path` / `delete_tag_path` in `impress-core` first. A menu that renamed only what this shell can see would silently fork the vocabulary | ➖ same reason | ➖ same reason | ➖ tag rows are alphabetical; there is no user order to persist (unlike `flagColor`, whose row order IS a preference) | ❌ **planned** — dropping records onto a tag row should APPLY that tag, which would make the section symmetric with `libraryCollection` and with the `TriageMenu` apply half that already exists. Not wired: `handlePublicationDrop` has no `.tag` arm, and `capabilities(of:)` therefore withholds `.droppable` in an EXPLICIT arm rather than by falling through `default` | ❌ deferred on macOS (a badge per row is one count query per row, over a vocabulary that is 23,916 paths in imbib alone); ✅ **conditionally** on iOS — `RecordSidebarBuilder.tagNodes` asks `dataSource.count(.tag(kind, path))`, which every host currently defaults to nil | One row of the tag TREE, carrying its FULL slash-separated path; the LABEL is the leaf, because the row's ancestors are its parent rows and repeating the path would restate the tree in text. **Matching is DESCENDANT-INCLUSIVE** — `.tag(kind, "reading")` selects records tagged `reading` AND `reading/queue` — and the rule lives in exactly ONE place, `TagPathMatch`, whose subtlety is that the boundary is the SEPARATOR: `reading` matches `reading/queue` and must never match `reading-list`. Exact match was rejected because it makes the tree decorative: every interior row would read as empty while its children showed rows. That is also why interior paths are MATERIALISED even when nothing carries them exactly (`reading/queue` alone yields a `reading` parent) — the parent selects a real, non-empty set. **Tag filtering is an envelope POST-filter, never a query argument and never a new FFI verb** (`FigureListWrapper`, `MailStoreReader`, `AgentRecordListWrapper`, the manuscript and publication lists all call `TagPathMatch`): tags live on the item envelope, not the payload, which is the shape `.flagged` already uses. macOS is `ImbibSidebarNodeType.tag(path:)` built one LEVEL at a time (`tagChildren(under:)`) so a vocabulary of thousands is never walked whole on a rebuild, resolving to `PublicationSource.tag(path)` — the same scope a watched folder's row lands on (ADR-0023 W2), one destination with two doors. iOS is `RecordSidebarScope.tag`, tree-built by `RecordSidebarBuilder.tagNodes`. **Agent rows bind `.task` only**: an `agent-run` is immutable provenance with no user mark to browse back. **Every host that switches on a list scope owes the `.tag` case**, and the compiler is the only thing that says so — imprint-iOS, impart-iOS and impress-iOS each broke on exhaustiveness after the chassis grew the case, because PMC's own build compiles none of them. One arm was worse than a compile error: `ManuscriptStoreAdapter`'s filter was `model.tags.contains(path)`, i.e. EXACT, invisible while the only constructor was a watched folder's leaf tag (ADR-0023 W3) and wrong the moment a tree could select a parent. It calls `TagPathMatch` now |
| `tag` — the FILTER field (2026-08-01) | ➖ | ➖ | ➖ | ➖ | ➖ | ✅ the surviving-path count, shown in the field | imbib alone has **23,916** tag definitions, so the tree is unusable without one. Both platforms use the shared `ImpressFTUI.FilterInput` in a new always-on shape — `showsHelp: false` (its `?` documents the publication query language, which this field does not implement) and `autoFocus: false` (a field that is part of a surface must not take the keyboard every time that surface draws) — never a hand-rolled `TextField`. **macOS puts it at the FOOT of the sidebar**, where this platform's navigators keep theirs (Xcode's is in exactly that spot) and where an `NSOutlineView` row does not have to become a text field; **iOS puts it inside the `.tags` section as its first row**, `.selectionDisabled()` so reaching for the keyboard does not push the detail column over the sidebar. The filter narrows the **vocabulary**, not the built rows (`TagPathFilter`) — which is what keeps the parents of a matching leaf on screen, since every builder derives its interior rows from the paths it is handed, and what makes a query matching an interior segment keep that subtree. Matching is substring + case-insensitive over the whole path, deliberately UNLIKE `TagPathMatch`, whose separator boundary answers "does this record belong in the selected scope" where a false positive shows the wrong papers. macOS additionally REVEALS matches (`expansionState.expandAll` over the surviving paths' ancestors) up to `tagRevealLimit` = 200 — above that the count in the field is the honest report that the narrowing is still too broad to open. **RUNTIME-verified on iOS** by `ImpressTagsUITests` (4 tests, simulator): the section renders as a tree with its interior row materialised, an interior row lists BOTH descendants' papers, the filter keeps the parent of a match and drops the rest, and the section survives a non-matching keystroke with its field. macOS's foot filter is NOT yet runtime-verified — XCUITest on this machine cannot start a macOS runner (`Authentication canceled. System authentication is running.`) |
| `tag` — the VOCABULARY (2026-08-01) | ➖ | ➖ | ➖ | ➖ | ➖ | ➖ | A tag has TWO halves in the imbib store and only one of them is browsable. `add_tag` writes the ENVELOPE fact (`item_tags`); `list_tags` returns `imbib/tag-definition` ROWS, written only by `create_tag`. Applying a tag through the shared `TriageMenu` wrote the first and not the second, so **a tag the user had just put on a paper was invisible to every reader of the vocabulary** — the sidebar's tree, the tag manager, the pickers — while showing on the paper's own row, which is why it survived. `RustStoreAdapter.addTag` now ensures the definition (`ensureTagDefinition`, idempotent through imbib-core's own definitions cache); `EnrichmentCoordinator` had been pairing the two calls by hand, which is the tell that the pairing belonged below the call sites. Found by `ImpressTagsUITests`: `item_tags` held `reading/queue` and the Tags section was empty. The RIGHT home is `ImbibStore::add_tag` in imbib-core, so the MCP and CLI writers get it too — recorded as the follow-up. The sibling kinds have no such split: their vocabulary IS what their rows carry (`RecordTagVocabulary` over `tagPathsInUse`) |
| `scixLibrary` | ✅ full | ➖ (Edit sheet) | ✅ confirm | ✅ reorder | ✅ pubs | ✅ | |
| `explorationSearch` | ✅ Delete | ➖ | ✅ | ✅ (→Inbox = feed) | ➖ | ✅ | |
| `explorationCollection` | ✅ Delete | ➖ | ✅ | ✅ | ➖ | ✅ | C2: DECLARED as the `exploration` tier (`allowsRename: false, allowsSubcontainers: false`) — the "Delete only" in this row, in code and pinned by `testPublicationTiersMatchTheFrozenMatrixRows`. Not routed: same two-writers reason as `inboxCollection`, plus the `ExplorationService.currentExplorationCollectionID` selection side effect, which is app state and stays app-side |
| `journalAll` / `journalByStatus` | ❌ none | ➖ | ➖ | ➖ | ➖ | ❌ deferred (async counts) | fixed rows |
| `journalSubmissions` | ❌ none | ➖ | ➖ | ➖ | ➖ | ➖ | hidden in imprint |
| `manuscript` (deep-link node) | ❌ none | ➖ | ➖ | ➖ | ➖ | ➖ | search results |
| `allArtifacts` / `artifactType` | ❌ none | ➖ | ➖ | ➖ | ✅ files/URLs | ✅ | |

## List row kinds

| Row kind | Select→detail | Multi-select | Context menu | Drag | Keyboard | Delete flow |
|---|---|---|---|---|---|---|
| Publication (`MailStylePublicationRow`) | ✅ `.id(source.viewID)` | ✅ Set + combined BibTeX | ✅ full (flag/tag/collections/…) | ✅ multi, cross-app ref | ✅ j/k + guarded | soft-delete → Dismissed, Undo — **on both platforms as of Stage 5d**; iOS's list had its own `handleDelete` calling `deletePublications` unconditionally, from every scope |
| Manuscript (`ManuscriptListWrapper`) | ✅ `.id(scope)` only (no pane `.id` — rebuilding the NSTextView made selection sluggish) | ✅ Set, primary drives detail | ✅ Open/Duplicate/Rename…/Star/Archive/Flag/Tags/Folder/Delete — Rename (2026-08-05) is an alert-with-TextField over `RecordTriageActions.onRename` → payload `title` write (`updateField`, undo via op log; kernel hosts get prior-title capture), so the op history renders it as "Renamed" | ✅ multi → folders (pasteboard + `RecordDragSession.manuscript` fallback) | ✅ j/k/n/s guarded | confirm alert → hard delete + Undo, session discarded; swipe = archive (status) / delete |
| Manuscript — **impress-iOS** (`IOSImpressListColumn.loadManuscripts`) | ➖ host column, not the wrapper | ➖ | ➖ inherits the shared `TriageMenu` | ➖ | ➖ | **Every host that switches on `ManuscriptListScope` owes ALL FIVE cases.** ADR-0023 W3 added `.tag(String)` and updated PMC's wrapper and imprint's adapter but not this column, and impress-iOS is the only lane that compiles it — so `Switch must be exhaustive` was the FIRST signal, two commits later (fixed 2026-08-01). `.tag` must be a POST-filter on `tagDisplays`, never a `queryManuscripts` argument: tags live on the item envelope, so a query parameter would need an FFI verb whose only caller is this one row kind |
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
**`impress` SHIPS an app target since 2026-07-30** (ADR-0022 D9). The column was
written when it did not, as a preset kept honest by parity tests
(`AppShellConfigurationParityTests`, the `testImpress*` cases) so the seams the
future app would stand on could not rot unnoticed. They did not: the macOS shell
consumes the preset UNCHANGED. Cells that said "when it does" are updated in
place; the parity tests still freeze every value:

| Derived value | imbib | imprint | implore (Stage 2-B) | impart (Stage 2-A) | impel (Stage 2-C) | impress (D9 — NOT SHIPPED) |
|---|---|---|---|---|---|---|
| showsSubmissionsInbox | true (auxiliaryRoute retained, but UNREACHABLE since the publications-only purification — it hung off the Manuscripts section; see Known gaps) | false | false | false | false | **true — and the home is no longer future.** The route and `SubmissionsInboxView` were kept for exactly this; the macOS shell permits `.submissionsInbox` and renders it, so the inbox that lost its home in the publications-only purification is structurally reachable again — it hangs off the Manuscripts section node builder (`ImbibSidebarViewModel`, gated on exactly this route), which impress permits. Not RUNTIME-verified: no macOS app is launched from this workflow |
| flagsShowManuscripts | false | true | false | false | false | false in the PRESET — `.flagged` binds `.publication`, because a single `RecordKindID` cannot say "flagged records of every kind". **Answered a different way on iOS by I3**: impress-iOS renders a `SidebarComposition`, so it has one Flagged section PER APP GROUP, each bound by that app's own preset (imbib → `.publication`, imprint → `.manuscript`). Flagged manuscripts are reachable there without a mixed-kind list existing. A single mixed-kind Flagged over `AnyRecordListWrapper` remains the follow-up for the macOS flat sidebar |
| opensManuscriptsInProcess | false | true | false (n/a) | false (n/a) | false (n/a) | false — `openOverrides` is EMPTY (impress embeds every viewer, so every kind uses its descriptor default). The manuscript default is `.appHandoff`. It was expected to become `.detailPane` when impress shipped; it did NOT, and the reason is worth keeping: the shipped shell renders manuscripts through `ManuscriptSectionView` on macOS, which owns the editor SESSION, and hands off on iOS where there is no session host at all. Flipping the override is a product decision about who owns the editing surface, not a consequence of the target existing |
| dismissedShowsManuscripts | false | true | false (n/a) | false (n/a) | false (n/a) | false in the PRESET — `.dismissed` binds `.publication`, same reasoning as Flagged, and answered the same way by I3's composition on iOS: the imprint group's Dismissed binds `.manuscript` and uses that kind's STATUS-CHANGE dismissal, while the imbib group's uses the publication kind's library move |
| visibleSections | **EXPLICIT, publications only (2026-07-27):** inbox, libraries, sharedWithMe, scixLibraries, search, exploration, flagged, **tags** (2026-08-01), citedInManuscripts, artifacts, reviewQueue, dismissed. NOT manuscripts / figures / mail / agents — those are imprint's / implore's / impart's / impel's facets. `citedInManuscripts` stays: its children are "All Cited Papers" (publications), imbib's half of the imprint bridge. `dismissed` stays: it is `.publication`-bound here. Was `nil` ("everything"), which opted imbib into every section the chassis grows; purity is the policy now (ADR-0022 D9) and a new section must opt IN | manuscripts, citedInManuscripts, flagged, **tags**, dismissed | figures + **tags** (Flagged deliberately skipped in v1 — needs a `.flagged: .figure` binding + routing; Tags is NOT skipped, because `.tags` needs no per-kind routing beyond the binding — `TagPathMatch` post-filters the envelope) | mail + **tags** (Flagged deliberately skipped in v1 — needs a `.flagged: .message` binding + routing) | agents + **tags** (Flagged deliberately skipped in v1 — needs a `.flagged: .task` binding + routing) | **EVERY section, EXPLICITLY** (inbox, libraries, sharedWithMe, scixLibraries, search, exploration, flagged, **tags**, citedInManuscripts, artifacts, manuscripts, figures, mail, agents, reviewQueue, dismissed = `Set(SidebarSectionType.allCases)`). `nil` would have been shorter and is exactly the mechanism that rode Manuscripts into imbib, so the unifying shell opts in by NAME; `testImpressPermitsEverySection` fails when the enum grows, until someone decides. `sectionBindings` names a kind for every section except `.reviewQueue` (its rows are `review-request@1.0.0`, which has no descriptor — binding it to a kind it does not list would be a lie). `agent-run` is the one registry kind that is not a binding VALUE: runs share the Agents section with tasks by design |
| defaultSection / defaultDetailTab | inbox / info | manuscripts / source | figures / info | mail / info | agents / info (lands on the Tasks leaf) | inbox / info |
| custom surfaces | — | — | generate, analyze (registered app-side via `withCustomSurfaces`); canvas = figure open window | chat, **category**, research, development (registered app-side via `withCustomSurfaces` in ImpartChassisRoot). `category` landed with the Stage-4c flip: it was the one classic view mode (⌘3) the chassis could not reach | dashboard, **threads**, **roster**, escalations, suggestions, counsel (registered app-side via `withCustomSurfaces` in ImpelChassisRoot; escalations keeps its 1-9/j/k keys INSIDE the surface, suggestions its ⏎/⎋ + j/k, both keyboardGuarded). `threads` and `roster` landed with the Stage-4c flip: the Agents SECTION reads the same `task@1.0.0` rows but renders them as tasks (losing impel's temperature / claimedBy) and has no surface for `ImpelClient.state.agents` / `.personas` at all | — none app-registered, and now that an app target EXISTS that is a positive result rather than a vacancy: `ImpressChassisRoot` deliberately calls no `withCustomSurfaces`. The chassis-builtin store-search surface arrives anyway (`CustomSurfaceRegistry.builtin`; `StoreSearchSurfaceTests` enumerates impress), and registering a copy of it app-side would REPLACE the builtin with an identical view. ⌘⇧F is bound by `ImpressStoreSearchCommands` in the menu tree, which is the only part an app owes. **iOS: none, and the builtin is empty there** — `StoreSearchSurface` is the one AppKit-linking builtin, so grouped search, impress's showcase, is macOS-only until a UIKit-clean version exists |
| default window | chassis | chassis | chassis | **chassis (Stage 4c, 2026-07-30).** `impart.useChassisWindow`, the classic three-column `ContentView`, `EmailListView`, `ImpartSidebarView`/`FolderTreeRow` and the "Mail (Unified)" secondary window are DELETED (1719 lines). The flag is not kept as a kill switch because it could only restore a strictly poorer window: the classic mail lists were permanently EMPTY on macOS — `InboxViewModel.loadMessages()` has no macOS caller (only `IOSContentView` assigns `selectedMailbox`), `accounts` is `private(set)` and assigned nowhere, `loadFolders(for:)` has no caller at all — and its detail pane was unreachable (it read `AppState.selectedMessageIds` while the list wrote `InboxViewModel.selectedMessageIds`). Compose, reply/forward, mark-read-on-select and check-mail moved to `MailChassisHost` over the new `RecordHostVerbs` seam; `ComposeView` and the whole Settings scene were EXTRACTED from the deleted file first | **chassis (Stage 4c, 2026-07-30).** `impel.useChassisWindow`, the classic `ContentView` and the "impel (Unified)" secondary window are DELETED (320 lines). Flag not kept, same reasoning: every surface the classic dashboard rendered is registered here over the same views. Closed first: suggestion ⏎/⎋ keys, the threads list and agent/persona roster (as surfaces), ⌘/ keyboard help (now a menu command), `wireUndo`, the two toolbar status indicators, and `impel://navigate/...` (which set a `DashboardTab` only the classic window observed) | **chassis (ADR-0022 D9, 2026-07-30).** `ImpressChassisRoot` is 79 lines, 14 of them code — `ChassisRootView(configuration: .impress)` plus `.withAppearance()`. The ~120-line estimate predates `ChassisRootView` (Stage 4b), which took the rest. The signing decision this cell demanded was made: the ADS/SciX read now sits behind `CredentialManager.itemsAreReadableWithoutPrompting` (a bundle-identity reachability check), NOT a shared keychain access group — a group would need imbib re-signed and every already-stored item migrated into it. impress still permits and renders `.search`; it just does not read credentials it provably cannot open |

### impress — the sidebar is a COMPOSITION of the other five (I3, 2026-07-31, iOS)

The user's report: *"It's quite hit and miss with impress. Libraries and
collections and the Inbox is for imbib. Imprint has its own collections for
manuscripts. Impart has its own for messages and all have flagged pubs,
manuscripts or messages. So it is ok for us to collate each of their sidebars
into collapsible sections of the impress sidebar rather than attempt this flat
but incomplete collection impress surfaces now."*

The flat `.impress` preset is a UNION of sections, and a union loses WHOSE
section each one is. The sharpest consequence is the last clause:
`sectionBindings` maps a section to ONE `RecordKindID`, so a union has exactly
one `.flagged` entry, it was `.publication`, and **flagged manuscripts had no
row in impress at all** — on any platform, in any container. That is what "hit
and miss" looks like from outside.

**`SidebarComposition`** (`Chassis/Shared/RecordSidebar/SidebarComposition.swift`)
is the fix, and its whole content is that each app's `AppShellConfiguration`
ALREADY IS its sidebar definition:

| piece | where it comes from |
|---|---|
| which apps, in what order | `SiblingApp.descriptors`, filtered of `impress` — imbib, imprint, implore, impel, impart |
| each group's title + glyph | `SiblingAppDescriptor.displayName` / **`.systemImage`** (new column on the one table) |
| each group's sections, order, kinds, roles, folders, flag bindings | that app's SHIPPING preset, passed to the same `RecordSidebarBuilder.sections` the app itself runs |
| host narrowing | `SidebarAppGroup.configuration(inHost:)` — the host's `presentableKinds`, applied once per group |
| content gating | unchanged: `RecordSidebarDataSource.sectionIsAvailable`, inside every group |

`RecordSidebarBuilder.groups(composition:host:order:dataSource:)` is nine lines
and contains no section name, no record kind and no app id. Adding a section to
`.imprint` makes it appear in impress's imprint group with no edit anywhere.

Four decisions worth keeping:

* **Duplication across groups is the design.** `.citedInManuscripts` is declared
  by BOTH `.imbib` and `.imprint`, so it renders twice, with the same scope —
  two doors onto one destination. `.dismissed` renders twice too, bound to
  different kinds AND different dismissal semantics (publications move library;
  manuscripts change status). The user asked for each app's sidebar verbatim.
* **Empty groups are KEPT, sections are still DROPPED.** A group whose every
  section gates away still renders its header: a group is an app's presence in
  impress, not a claim about its data. Within a group, a section that resolves
  to no rows keeps the existing drop behaviour, which is the host saying "I
  cannot serve this".
* **Rows are namespaced by group** — `sidebar.group.<app>`,
  `sidebar.section.<app>.<section>`, `sidebar.node.<app>.<scopeKey>`. Not
  cosmetic: two rows genuinely share a scope, and a duplicate `ForEach` id is
  undefined behaviour. The five sibling apps do NOT compose and their
  identifiers are unchanged.
* **Two collapsible levels, one persisted key space.** `SidebarCompositionKey`
  (`group:<app>` / `section:<app>:<section>`) in its own UserDefaults key, so
  collapsing imbib's Flagged never touches imprint's, and an impress collapse
  never lands in imbib's own sidebar. Default empty = everything expanded.
  Disclosure headers publish their state as an accessibility VALUE
  (`expanded`/`collapsed`), which VoiceOver should announce and which is the
  only read of open/closed that does not depend on scroll position.

macOS impress still runs the FLAT preset — see Known gaps for the four
structural reasons and the ordered follow-up.

**A chassis gap I3 could not close, recorded rather than papered over.**
Tapping a `List` SECTION header to collapse it — an affordance
`RecordSidebarView` has offered since ADR-0021 — does not take effect from a
synthesized tap on iOS 26. The event reaches the button (XCUITest logs
"Synthesize event" against `sidebar.section.…`) and the rows stay. It behaves
the same in the FLAT sidebar and in the composed one, and **no suite in this
repo covers it** — imbib-iOS, imprint-iOS and impart-iOS all locate section
headers and none asserts that tapping one collapses the section. So it is not
composition-specific and I3 did not introduce it. impress's GROUP headers do
collapse correctly (`testCollapsingAGroupHidesItsSectionsAndExpandingRestoresThem`
proves it, by rows and by the header's published `accessibilityValue`), which is
the level the user asked for — "collate each of their sidebars into collapsible
sections". Per-section collapse inside a group is keyed and persisted
(`SidebarCompositionKey.section`) and will work the moment the header tap does.
Whether the tap is broken for a real finger or only for a synthesized one is the
open question, and answering it needs a device pass.

**Three findings the I3 lanes surfaced, none caused by them.**

1. **iOS UI lanes are DEVICE-SPECIFIC, and the device is not in the scheme.**
   `imprint-iOSUITests` and `impart-iOSUITests` pin `.landscapeLeft` because
   their three-column split view hides the sidebar in iPad portrait — so they
   are iPad suites. Run them on an iPhone and they fail on HEIGHT, not on
   contract: impart's "four seeded mailboxes should be visible" finds two,
   because a lazy `List` in a 402-point landscape iPhone column only
   instantiates what fits. Both pass on `iPad Pro 11-inch (M5)` and fail on
   `iPhone 17e` **from the same commit**. imbib-iOSUITests and
   impress-iOSUITests pin `.portrait` and are iPhone suites (impress moved in
   I2 for exactly this reason — landscape cost the height its eight-section
   sidebar needed, and I3's composed sidebar is taller still). A destination is
   part of what makes these lanes green; pick it per app.
2. **`imprint-iOSUITests.LibraryShellUITests
   .testSidebarShowsSectionsAndTheCollectionTree` fails at HEAD** — "sidebar is
   missing “Papers”", the seeded manuscript COLLECTION row. Reproduced on a
   freshly ERASED iPad Pro 11-inch (M5) from commit 6a18f174 with no working-tree
   changes at all, so it is not I3's and not container contamination. Every
   other assertion in that test passes, including the Manuscripts header and the
   descriptor's status rows; only the collection tree is missing. Worth a look
   at imprint's seed or `ManuscriptStoreAdapter`'s collection read — the sidebar
   half is shared with imbib, whose collection rows do render.
3. **A simulator's app-group container is shared by every app in the group**,
   and both `ImpressIOSUITestSeed` and impart's seed write `impress.sqlite` in
   it. Run impress-iOS's seeded lane before impart-iOS's on ONE simulator and
   impart's seed declines to write (its idempotence probe sees impress's mail
   account), so its suite looks for four mailboxes it never wrote. Give each
   app's iOS UI lane its own simulator, or erase the group container between
   lanes; `scripts/run-ui-tests-isolated.sh` already runs one app at a time.

### impress — what each platform renders, and what is DECLARED absent

Shipped 2026-07-30 (ADR-0022 D9); **iOS reach widened by I2 the same day.** The
preset permits every section on both platforms; what differs is
`presentableKinds`, the HOST capability axis. macOS leaves it nil (present
everything); impress-iOS declares
`presenting([.message, .figure, .task, .publication, .manuscript])`, and
`RecordSidebarBuilder` drops every section bound to a kind outside that set —
with **no section-name literal in the KIND gate**, which is the property the
axis exists to buy.

I2 added the last two kinds by building what D9 said was missing, in the
CHASSIS: `IOSPublicationDetailPane` (lifted out of the imbib app target,
`Chassis/Detail/IOS/`), `IOSPublicationListPane` (new,
`Chassis/Shared/`) and `IOSManuscriptReadOnlyPane` (new,
`Chassis/Manuscripts/`). Five sections moved from "declared absent" to
rendered: Inbox, Libraries, Manuscripts, Flagged, Dismissed — plus Cited in
Manuscripts. A second gate now carries the remainder: four publication-bound
sections whose KIND is presentable but whose ROWS this host has no source for
(`ImpressSidebarBindings.contentGatedSections`).

| kind | macOS | iOS | route |
|---|---|---|---|
| `publication` | ✅ nine sections (inbox, libraries, sharedWithMe, scixLibraries, search, exploration, flagged, citedInManuscripts, dismissed) | ✅ **five sections (I2)** — inbox, libraries, flagged, citedInManuscripts, dismissed | macOS: the publication list path (`UnifiedPublicationListWrapper` + the `PublicationSource` union) — a DELIBERATE exception to registry routing, per ADR-0022 C2 axis 5. iOS: `IOSPublicationListPane` (`RecordListHost` over `PublicationListCore`, rows by `MailStylePublicationRow`) + `IOSPublicationDetailPane`, both PUBLIC in PMC since I2. The other four sections are gated on CONTENT, not kind: `.search` (imbib's online-search forms; and `StoreSearchSurface` is AppKit-only), `.exploration` (its collections are written by imbib's `ExplorationService`), `.scixLibraries` (ADS credentials), `.sharedWithMe` (imbib's sharing sync) |
| `manuscript` | ✅ Manuscripts + Submissions | ✅ **Manuscripts, READ-ONLY (I2)** | macOS: `ManuscriptSectionView`, also a deliberate exception — it owns the editor SESSION (imbib CLAUDE.md invariant) and a registry factory has nowhere to put one. iOS: `RecordListHost` over `ManuscriptRowData` + **`IOSManuscriptReadOnlyPane`** (info header, read-only source, markdown preview, "Open in imprint" for compiled formats). `ManuscriptDetailPane` is STILL macOS-only and was not un-gated: five of the six views it composes are AppKit-shaped and it hosts the editor session. The read-only pane is a twin, not a port |
| `artifact` | ✅ Artifacts | ❌ **declared absent** | `ArtifactDetailView` is macOS-only and is a genuine per-artifact-type switch, not a platform bridge |
| `figure` | ✅ Figures | ✅ Figures | registry-resolved on macOS (`FigureSectionView`); on iOS `RecordListHost` + **`FigureDetailPane`, which was un-gated from `#if os(macOS)` for this shell** — its only AppKit call was `NSImage(data:)` |
| `message` | ✅ Mail | ✅ Mail | registry-resolved on macOS (`MessageSectionView`); on iOS `RecordListHost` + `MessageDetailPane`, both already cross-platform (proven by impart-iOS) |
| `task` | ✅ Agents | ✅ Agents | registry-resolved on macOS (`AgentSectionView`); on iOS `RecordListHost` + **`AgentRecordDetailPane`, likewise un-gated** — its only AppKit call was `Color(NSColor.textBackgroundColor)`, for which `ImpressTheme` has shipped `Color.platformTextBackground` since ADR-023 |
| `agent-run` | ✅ shares the Agents section with tasks | ❌ **declared absent** — a CHASSIS limit, not an app one | `sectionBindings` maps a section to ONE kind, so `.agents` binds `.task` and every derived node is a task node; there is no derived route to `.all(.agentRun)`. A host CAN supply its own nodes, but host nodes REPLACE the derived ones, so surfacing Runs on iOS means re-spelling the task rows and the descriptor's statuses app-side — forking a declaration in order to add a sibling to it. Same shape as the mixed-kind Flagged/Dismissed gap below |
| `review-request` | ➖ one opaque row (`.reviewQueue` is UNBOUND in the preset — no descriptor) | ❌ suppressed by the host CONTENT gate (`sectionIsAvailable`) | The honest instrument differs by platform on purpose: an unbound section has no kind to be incapable of, so `presentableKinds` cannot express it and the content gate must |

Two further absences on iOS that are not about kinds:

* **Grouped mixed-kind search — impress's showcase — does not exist on iOS.**
  `StoreSearchSurface` is the one AppKit-linking chassis builtin, so
  `CustomSurfaceRegistry.builtin` is EMPTY there and `ImpressStoreSearchCommands`
  omits the affordance rather than shipping a dead ⌘⇧F. macOS gets it with zero
  app registration.
* **Mail FOLDERS do not appear in the impress-iOS sidebar.** `message` declares
  no `CollectionCapability` (IMAP owns mailbox lifecycle), so the derived
  section is "All Messages" alone. impart-iOS shows the account/mailbox tree by
  supplying HOST nodes — which impress could do, at the cost of re-deriving in
  app code what the descriptor already says. Left underived, and named here
  instead.

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
| `ImpressChassis/Manuscripts/FocusedManuscript.swift` | ✅ both | a `FocusedValueKey` — pure SwiftUI focus plumbing. **Lifted out of PMC into `packages/ImpressChassis` by C5** (ADR-0021 D5); PMC re-exports the module, so the import that reaches it is unchanged |
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
| `Chassis/Manuscripts/ManuscriptDetailPane.swift` | audit said "plain SwiftUI"; it is not. Its `content` switch names six macOS-only views — `ManuscriptDetailView`, `ManuscriptSourceTab`, `MarkdownPreviewTab(session:)`, `ManuscriptLaTeXImprintPrompt`, `ManuscriptPDFPreview`, `ManuscriptInverseSync`. Un-gating would leave a shell whose every branch is an island, which is a re-gate wearing a different hat. **STILL macOS-only after I2, and this row is why.** I2 wanted an iOS manuscript pane and wrote a TWIN (`IOSManuscriptReadOnlyPane`) rather than un-gating this one: the twin hosts no session, so it needs none of the six |
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

### The chassis lives in two packages now (C5, 2026-07-30)

ADR-0021 D5's package extraction ran, was measured first, and moved five files.
`packages/ImpressChassis` used to be an eleven-line façade
(`@_exported import PublicationManagerCore`); it is now a real target with no
dependencies at all, and PMC depends on it and re-exports it. **Every existing
`import PublicationManagerCore` still resolves every symbol** — that
re-export is the compatibility invariant, and it is why this landed with zero
diffs in any app target.

| Where a chassis file lives | What that means |
|---|---|
| `packages/ImpressChassis/Sources/ImpressChassis/…` | it names NOTHING outside `Chassis/` — pure contract data, Foundation or SwiftUI only. Five files: the settings descriptor + preset, `RecordListHostModel`, `ChassisNavigation`, `FocusedManuscript` |
| `apps/imbib/PublicationManagerCore/…/Chassis/…` | everything else — 92 files, and the reason is measured, not aesthetic (see below) |

**Why so few, and why that is the finding.** `Chassis/` is 97 files / 32.3k
LOC, but its transitive closure inside PMC is **348 of 545 files (64% of PMC,
117k LOC)**: the chassis sits on TOP of imbib's domain, not underneath it. 64
of the 97 chassis files name at least one non-chassis PMC symbol — 137 distinct
symbols over 771 references — and the single heaviest is `RustStoreAdapter`
(115 references across 24 chassis files), imbib's own store facade. The full
boundary table, classified into seams / injection points / hard entanglements
with counts, is in ADR-0021 D5.

The lint follows the code: `scripts/check-chassis-deps.sh` now polices BOTH
manifests, with an empty allowlist for ImpressChassis and an explicit check
that it never depends back on PMC. `ChassisCrossPlatformContractTests` and the
settings/list-host suites resolve a `Chassis/…` path through
`ChassisSourceRoots`, which tries PMC and falls back to the package — so the
structural assertions above kept their subjects and gained one more:
`testTheLiftedContractFilesLiveInTheChassisPackage`.

**Build time did not improve, and that was the point of measuring.** PMC clean
`swift build` 66.7 s → 68.3–74.5 s (three samples); imbib macOS clean
`xcodebuild` 75.9 s → 70.6 s. The extra module boundary costs about as much as
the five files saved. ADR-0021 D5's third extraction trigger — "build time or
binary size measurably hurts" — is still not met.

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
| `ImpressChassis/Settings/SettingsSectionDescriptor.swift` | ✅ both | **lifted into `packages/ImpressChassis` by C5.** `SettingsSectionID` (string-backed, additive), `SettingsSectionDescriptor` (id, title, SF Symbol, subtitle, availability, order — Sendable DATA, no closures), `SettingsPlatform`, `SettingsRequirement`, `SettingsSectionAvailability`, `SettingsHostCapabilities` |
| `Chassis/Settings/SettingsSectionRegistry.swift` | ✅ both | `SettingsSectionFactory` (the `@MainActor @Sendable → AnyView` builder), the registry (`register` / `subscript` / `composing` / `unresolvedSections`), the environment key, the two BUILTIN panes, and `SettingsForm` (the one `#if` island — macOS tabs want `.padding()`, iOS pushed screens must not have it) |
| `ImpressChassis/Settings/AppSettingsConfiguration.swift` | ✅ both | **lifted into `packages/ImpressChassis` by C5** — the folder-move claim this row used to make in the future tense, made good. The per-app ordered section list; a SIBLING of `AppShellConfiguration.swift`, not part of it (different consumers: two renderers vs. the whole sidebar). Note what did NOT come with it: `SettingsSectionRegistry.swift`, which reads `AppearanceMode` from PMC's theme layer. Descriptor and preset are data; the registry builds views over app types, and that is the seam the package boundary now makes physical |
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
- **`impart-iOS` was NOT migrated and could not be — CLOSED by Stage 5c
  (2026-07-30).** Phase 2's reason was true and specific: the target did not link
  PublicationManagerCore, so no chassis renderer could run there, and its
  `IOSAppearanceSettingsView` was a second clone of the shared appearance section.
  Stage 5c added the package, so `.accounts` and `.general` are now `.everywhere`
  and impart-iOS renders `IOSSettingsScreen` — two rows plus the derived footer
  ("4 more settings are available on the Mac — they need a local HTTP server or a
  Spotlight index"). The other four stay `.macOSOnly()`: `.ai` is a provider/key
  surface iOS does not run, `.keyboard` is a hardware-keyboard reference, and
  `.automation`/`.spotlight` carry requirements iOS never grants. The iOS panes are
  registered app-side in `impart-iOS/Views/IOSImpartSettingsFactories.swift`
  (`ImpartIOSSettingsSections.registry`, builtins + two). The appearance clone
  survives on BOTH platforms for the reason above (one of two controls inside
  General), and `testImpartIOSSettingsReadTheSameKeysAsMacOS` now pins the iOS
  pane's key SET as a subset of the Mac's rather than pinning the absence.
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

Phase 3 candidates, all recorded above rather than done (the first is DONE — Stage
5c linked PublicationManagerCore into `impart-iOS`): align impart's two hand-rolled clones;
give impel an `automation` pane (its `ImpelHTTPServer` reads
`httpAutomationEnabled`/`httpAutomationPort` that **no impel pane writes** — the
server is unconfigurable from the GUI); reconcile impel's `counselModel`, which has
two conflicting `@AppStorage` defaults in two files.

### iOS publication + manuscript reach (I2, 2026-07-30)

The user's report was "it recognizes very few types — none of the ones we have
multiple entries, like publications and manuscripts". Two gaps, both CHASSIS
gaps rather than impress gaps, and both closed as public surfaces every iOS host
consumes.

| surface | file | macOS | iOS | note |
|---|---|---|---|---|
| publication detail pane | `Chassis/Detail/IOS/IOSPublicationDetailPane.swift` | ➖ (macOS twin is `Chassis/Detail/DetailView.swift`) | ✅ **public** | LIFTED verbatim out of `imbib-iOS/Views/IOSDetailView.swift`. Its CONTENT was already shared (Stage 5b's `Chassis/Detail/Shared/`); only the chrome was app-private, and chrome in an app target is a reach limit for the whole suite |
| publication Info / PDF / Notes tabs | `Chassis/Detail/IOS/IOSInfoTab.swift`, `IOSPDFTab.swift`, `IOSNotesTab.swift` | ➖ | ✅ **public** | lifted with the pane, plus their three private dependencies (`IOSNoPDFView`, `IOSPDFBrowserView`, `IOSNotesEditorView`) |
| publication LIST | `Chassis/Shared/IOSPublicationListPane.swift` | ➖ (macOS twin is `UnifiedPublicationListWrapper`) | ✅ **public** | NEW, not lifted. `RecordListHost` + `PublicationRowData` + `MailStylePublicationRow`, with scope→rows delegated to the cross-platform `PublicationListCore`. imbib's `IOSUnifiedPublicationListWrapper` was surveyed and rejected: 791 lines of which ~4/5 are imbib's LIBRARY-MANAGEMENT verbs (inbox/feed triage, BibTeX sheet, sort/unread controls, multi-select, attachment drop, smart-search pull), every one of which needs a library to write into |
| manuscript detail pane (read-only) | `Chassis/Manuscripts/IOSManuscriptReadOnlyPane.swift` | ➖ (macOS twin is `ManuscriptDetailPane`, an EDITOR host) | ✅ **public** | NEW. Info (descriptor-labelled status, authors, dates, `ManuscriptHistorySection`), read-only source, markdown preview. NO session, NO editing, NO `ImprintCore` — it reads `RustStoreAdapter.getManuscriptDetail`, PMC's own FFI |
| imprint handoff | `Manuscript/ManuscriptImprintHandoff.swift` | ✅ | ✅ **un-gated (I2)** | was `#if os(macOS)` for one `NSWorkspace.open`; now `UIApplication.open` on iOS with a `canOpenURL` availability check. Same shape as the two panes D9 un-gated for one AppKit call each |

**What the read-only manuscript pane does NOT render, stated rather than
mocked:** a compiled preview. Typst and LaTeX need the editor session and the
in-process renderer; the pane carries neither, so those formats get an "Open in
imprint" affordance instead of a spinner that never resolves. Markdown renders
free (`MarkdownSourcePreview`, no compile step). A body stored as a
`blob:sha256:…` ref renders its "too large, open in imprint" state rather than
the literal ref.

**A URL-grammar disagreement the handoff surfaced and did not fix:**
`ManuscriptImprintHandoff` emits `imprint://open?manuscript=<uuid>`, while
`ImpressURL.openDocument(id:)` builds `imprint://open/document/<uuid>`. imprint's
own handler — on both platforms — parses the QUERY form, so the handoff uses it;
changing the line would break a working handoff to fix a docs inconsistency.
Recorded here as the open item.

**One crash the lift found, in a view that had been "the same view on both
platforms" since Stage 5b.** `BibTeXTab` read
`@Environment(LibraryViewModel.self)` NON-optionally, and SwiftUI traps on a
missing `@Observable` environment value — so the one fully-collapsed detail tab
killed any host that had not injected imbib's view model. impress-iOS found it
by selecting the BibTeX tab and landing on the home screen. The view model is
used for exactly one thing (writing an edited entry back, which needs a library
to import into), so the read is now optional and the tab degrades to
view-plus-Copy where a host cannot save. The Copy button also moved OUT of the
`canEdit` gate, because reading a paper's BibTeX is not a library-management
verb.

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

### Publication list (`Chassis/Shared/`, Stage 5d, 2026-07-30)

The suite's highest-traffic surface, and the last iOS list on its own model.
macOS's `UnifiedPublicationListWrapper` was 1,682 code lines; imbib-iOS's
`IOSUnifiedPublicationListWrapper` 710, plus a 159-line `…Stub.swift` that had
been excluded from the build — and therefore a THIRD copy of the scope enum and
a third publication `List` — since the real wrapper was revived on 2026-07-20.

**The list itself was never the duplication.** `SharedViews/PublicationListView`
(2,021 cross-platform lines) has been the one host for rows, the sort menu, the
swipes, the toolbar and `.refreshable` all along; both wrappers call it. What was
written twice is the MODEL around it — which scope means which rows, what order
the user is looking at, where selection goes when rows leave, and what a triage
verb actually does to the store. Four of those five had a defect in the iOS copy,
so this is a SPLIT that also closes bugs rather than a tidy-up.

| Half | Verdict | What moved cross-platform | What stayed two, and why |
|---|---|---|---|
| Scope derivations | **ONE SURFACE — collapsed outright.** | `PublicationScope`: `listViewID`, `isInboxScope`, `isFeedScope`, `smartSearchID`, and the two owning-library policies | Nothing. The iOS `Source` enum survives as the SIDEBAR ROUTE (it carries a display name `PublicationSource` cannot express) but derives nothing — it maps to a `PublicationSource` and asks |
| Visual order + selection advance | **ONE SURFACE — collapsed outright.** | `PublicationListOrder.visualOrder` / `primaryComparison` / `nextSelection`, macOS's implementations moved without edits | Nothing |
| Triage verbs | **SPLIT — one sequence, two selection policies.** | `PublicationListMutations`: the COMPOSITES (delete, dismiss, dismissFromFeed, save, saveFromFeed, trackInboxDismissals, removeFromAllCollections) | The selection policy. macOS ADVANCES to the next paper; iOS CLEARS, because on a phone the split view is a stack and writing a selection pushes the detail pane over the list being triaged in (matrix line ~271, the rule that has now bitten twice) |
| Reload / scope→rows / network refresh | **SPLIT — iOS adopts, macOS names its price.** | `PublicationListCore`: `PaginatedDataSource` ownership, `reload`, `applySort`, pagination, the store-event subscription, the smart-search + SciX refresh | macOS keeps its own `refreshPublicationsList`: around the same reload it runs store-version dedup, the Apple-Mail unread snapshot, `LocalFilter` + debounced FTS, and two change-detected caches. iOS has none of them and every one is observable behaviour on the frozen pane. The REMOTE half is now shared even though macOS still holds no core: `PublicationListCore.pullSmartSearch` is a static and the macOS chrome calls it directly — the one part of the core the gated wrapper consumes |
| Empty-state + title copy | **TWO DESIGNS — kept, with reasons.** | Nothing | Different product copy per platform (macOS "No new papers in your inbox."; iOS "Add feeds to start discovering papers."), and iOS guards an empty smart-search query where macOS renders `No Results for ""`. Unifying words changes the frozen pane — a product decision. Same rule as `InfoTab.macExplorationKinds` |
| macOS list chrome | **TWO DESIGNS.** | Nothing | Vim keys, the flag/tag/filter input overlays, drag-and-drop + preview sheet, the import toast. Stays `#if os(macOS)` and is asserted so |

**Five defects the duplication was hiding, each now a test** (a sixth, the blank
BibTeX sheet, is below — it was hiding behind the absence of a test, not behind
the duplication).

1. **iOS's Delete destroyed data.** `handleDelete` called
   `deletePublications(ids:)` unconditionally, from every scope, while the same
   word on the Mac moved the paper to a recoverable Dismissed library — the
   "soft-delete → Dismissed, Undo" this document promises for the publication
   row. Now `PublicationListMutations.delete`, with `permanently` the one
   decision the host owns (macOS matches `if case .dismissed`; iOS routes its
   Dismissed screen through `.libraryByID` and compares ids).
2. **iOS triage let dismissed papers back into the inbox.** Neither
   `handleDismiss` nor `handleSaveToLibrary` called
   `InboxManager.trackDismissal` — imbib's FIRST critical invariant. Dismiss a
   paper on iPhone, let a feed refresh, and it came back.
3. **The "deterministic" `.flagged` id table was two tables.** iOS's
   `flaggedID(for:)` carried the comment *"matches the macOS wrapper's mapping so
   saved selection state survives platform transitions"* and mapped
   red/amber/blue/gray to `F1A99ED0-000{1,2,3,4}-…`; `PublicationSource.viewID`
   maps them into `00000000-…-%012x` by a different colour index and has no
   `amber` branch at all. `listViewID` keys `ListViewStateStore`, so the two
   platforms had been reading and writing DIFFERENT saved sort/unread/selection
   state for every flagged scope for as long as both files existed. Nothing
   failed loudly; the comment was simply false.
4. **The iOS sort menu was inert.** iOS held `currentSortOrder`, handed it to
   `PublicationListView` (which renders the menu), and had no
   `onChange` — it loaded once at the store's default `created DESC` and never
   re-queried, and `PublicationListView` sorts client-side only for
   `.recommended`. Every other entry ticked and the list did not move. Meanwhile
   iOS's `computeVisualOrder()` sorted a copy nobody rendered, and
   `handleSaveToLibrary` discarded the result outright (`_ =
   computeVisualOrder()`).
5. **Multi-row triage landed inside the block it was triaging.** iOS's
   `computeNextSelection` walked down from `ids.first` — an unordered `Set`'s
   first element. macOS walks down from the LAST selected row in visual order.
   iOS's client-side comparator was also not a strict weak ordering for
   `.starred` (`lhs.isStarred && !rhs.isStarred` reports "equal" for two starred
   papers and for two unstarred ones).

| File | Reach | Role |
|---|---|---|
| `Chassis/Shared/PublicationScope.swift` | ✅ both | scope → persisted list key, inbox/feed classification, smart-search id, the two owning-library policies. Derivations only — ADR-0018 D3, no new cases |
| `Chassis/Shared/PublicationListOrder.swift` | ✅ both | the visual order (SQL-sorted passthrough; total order for `.recommended`) and the selection-advance rule |
| `Chassis/Shared/PublicationListMutations.swift` | ✅ both | the composite triage sequences with their invariant steps (dismissal tracking, feed delinking, batching, soft delete) |
| `Chassis/Shared/PublicationListCore.swift` | iOS (macOS pending for the reload, price stated in its header; macOS calls `pullSmartSearch`) | `@Observable` scope→rows: paginated read, sort→`ORDER BY`, store-event subscription, smart-search + SciX network refresh |
| `Chassis/Shared/UnifiedPublicationListWrapper.swift` | macOS | the chrome: vim keys, input overlays, drag-and-drop, import toast, the unread-snapshot + FTS filter pipeline |
| `imbib-iOS/Views/IOSUnifiedPublicationListWrapper.swift` | iOS | the chrome: navigation title, Select/Done + per-scope refresh + SciX glyph toolbar, bottom bar, library picker, share / open-in-browser, the BibTeX sheet |

**What was NOT collapsed, deliberately.** The empty-state and title strings (see
the verdict table). `handleOpenInBrowser` / `handleShare` / `handleDownloadPDF`,
which are iOS-only affordances with no macOS counterpart to converge with — the
chassis's `BrowserURLProviderRegistry` answers "the one best URL for this paper",
not "the URL for this destination", so there is nothing to read. Single-call
verbs (`setFlag`, `clearFlag`, `toggleRead`, `addToLibrary`, `addToCollection`):
they are already one line into the shared `RustStoreAdapter` and were never
implemented twice — wrapping them would add a hop and remove no duplication.
macOS's `onRemoveFromAllCollections` — **wired 2026-07-30.** It was an empty
`// TODO` closure that silently did nothing when the user picked the menu item;
it now calls `PublicationListMutations.removeFromAllCollections`, so the verb
finally runs on both platforms. Like `onAddToCollection` it does not refresh:
`removeFromCollection` posts `.structural` and the wrapper's subscription owns
the reload, so a manual refresh would double-refresh (which is exactly what
`lastRefreshedStoreVersion` exists to suppress). And **the tracked triage-builder exception below
stands** — this pass did not touch `MailStylePublicationRow`'s swipes, keys or
menu styling.

Net: 901 code lines deleted across five files, 470 added as one shared
implementation. Two whole files went with it — the excluded-from-build
`IOSUnifiedPublicationListWrapperStub.swift` (159) and, with the BibTeX collapse
below, `IOSBibTeXEditorView.swift` (237).

**`IOSBibTeXEditorSheet` — the third BibTeX surface (verdict: full collapse).**
Stage 5b collapsed `IOSBibTeXTab` into `BibTeXTab` and missed this one, which the
publication list presents from its row context menu; imbib-iOS therefore still
had two BibTeX editors. 163 code lines → 32, all of them sheet chrome
(`NavigationStack`, "BibTeX" title, one Done button). Every difference it carried
was a defect: it looped `updateField` over `entry.fields` — **the exact bug Stage
5b fixed in the tab**, which cannot express a renamed cite key, a changed entry
type or a deleted field, so those edits showed a saved sheet and changed nothing;
its 35-line hand-rolled brace counter and `^@\w+\s*\{` regex were a FOURTH BibTeX
grammar and the strictest (it rejected `@string`/`@preamble`), while
`BibTeXEditor` has had real-time `BibTeXValidator` checking with a line-numbered
validation bar all along; and its read mode was plain monospaced `Text` with no
highlighting, line numbers or error markers. `confirmsUnsavedDiscard` (the one
thing the iOS copies did better) already defaults to `true` on
`BibTeXTab.init?(publicationID:)`, so the confirmation survives. Edit / Copy /
Cancel / Save moved out of the navigation bar into the tab's own inline bar
rather than being duplicated into it — the only visible change.

**And the sheet was presenting nothing at all.** Writing the UI test for it
turned up a sixth defect, independent of the collapse and older than it: the
wrapper held `showBibTeXEditor: Bool` beside `publicationForBibTeXSheet: UUID?`,
presented with `.sheet(isPresented:)` and an `if let` inside the content builder.
`handleViewEditBibTeX` writes both in the same runloop turn, and SwiftUI
evaluated the builder while the id was still nil — so "View/Edit BibTeX" opened a
**blank sheet**, with no navigation bar and no content in the accessibility tree.
Now one `@State` (`bibTeXTarget`) and `.sheet(item:)`, which derives presentation
FROM the id so there is no order to get wrong. The same shape is worth checking
anywhere `.sheet(isPresented:)` sits beside a separately-written payload — this is
the `@State`-capture rule (root CLAUDE.md) in its presentation form.

That sweep ran on 2026-07-30 across `PublicationManagerCore` and the five macOS
targets: 38 `.sheet(isPresented:)` sites. Two more instances of the exact shape
were found and converted — `ArXivCategoryBrowser`'s follow sheet
(`selectedCategory` + `showingFollowSheet` → one `followTarget`) and
`RemarkableDocumentBrowserView`'s import sheet (`selectedDocument` +
`showImportSheet` → one `importTarget`); in both, the row action wrote payload and
flag in the same runloop turn. Three sites KEEP an `isPresented` whose boolean is
a *derived* binding over the payload (`SectionContentView`'s feed settings,
`EInkSettingsView`'s device config, and the drop-preview sheet, which
additionally has a three-deep library fallback so a nil payload cannot blank it):
presentation already follows the payload there, so there is no order to get
wrong, and `.sheet(item:)` would delete the drop preview's fallbacks. The rest
carry no payload at all and are correct as they stand. **One site is flagged
rather than fixed:** impart's `MailChassisHost` compose sheet takes an OPTIONAL
draft where nil legitimately means "blank new message" (⌘N, and `handleCompose`
with no selected account), so `.sheet(item:)` would delete the blank-compose
path. If reply/forward ever loses its quoted body, that is where to look — but
the fix is not this modifier.

Note the
test that catches it must anchor on `app.navigationBars["BibTeX"]`:
`app.staticTexts["BibTeX"]` is a false positive, because the app publishes a
zero-size keyboard-shortcut element with exactly that label, and it let the empty
sheet pass.

**macOS smart-search refresh now actually refreshes (a sanctioned behaviour
change, 2026-07-30).** The wrapper's `.smartSearch` case was
`// TODO: implement smart search refresh with Rust store` followed by
`try? await Task.sleep(for: .milliseconds(100))` — Refresh on a feed slept,
re-read the store and fetched NOTHING, so a macOS smart-search section could only
ever show what a background service had already landed, while iOS had implemented
the real thing all along. The sequence (group feeds →
`GroupFeedRefreshService.refreshGroupFeedByID`, everything else →
`SmartSearchProviderCache` + `SmartSearchProvider.refresh()`) now lives in
`PublicationListCore.pullSmartSearch` and both hosts call it. This is a
deliberate change to the frozen pane: macOS smart-search and group-feed sections
issue a real network fetch on demand (group feeds will now stagger per-author
searches), and a failed fetch replaces the list with the retry
`ContentUnavailableView` instead of silently succeeding. The static returns
`Error?` rather than `String?` because each host PRESENTS the failure its own way
— macOS stores an `Error` for its retry view, iOS wants a string for its alert.

Regression oracles: `PublicationListSharedSurfaceTests` (15 tests, `swift test` —
the frozen `.flagged` scope keys and the amber fallback, virtual-scope key
distinctness, SQL-sorted passthrough for all eight non-recommended orders,
`.recommended` totality under a full score tie, selection advancing below a
multi-row block across 50 shuffles of the `Set`, the end-of-list fallback, plus
structural guards: the triage verbs still carry their invariant steps, the macOS
chrome no longer re-implements them, and the core owns no strings and no
selection); the four new rows in
`ChassisCrossPlatformContractTests.crossPlatformContractFiles` and the new gated
row for the macOS wrapper; and `imbib-iOSUITests/IOSPublicationListUITests`
(booted simulator — selection updates the detail pane, pull-to-refresh, and the
BibTeX sheet opening the shared editor).

### The shared iOS list host (`RecordListHost`, C1, 2026-07-30)

Stage 5c REPORTED the gap ("there is no shared iOS LIST host — three apps each
write their own"), and Stage 5d NARROWED it and rejected the imbib-shaped
version: imbib-iOS does not hand-write a list at all, so a host generalized from
imbib would be generalized from a file imbib would not use. C1 built the version
generalized from the two hosts that were actually asking — the `listColumn`
middle of imprint-iOS's `IOSManuscriptLibraryView` and impart-iOS's
`IOSMessageListColumn` — and left imbib-iOS on `PublicationListView` +
`PublicationListCore` untouched.

| Half | Verdict | What moved cross-platform | What stayed per app, and why |
|---|---|---|---|
| The `List` + rows | **ONE SURFACE.** | `List(selection:)`, `ForEach`, `.tag`, `.listStyle(.plain)`, and the `.recordTriageRow(...)` wiring (triage capabilities + row state + tag paths + extra menu items) | The ROW ITSELF is a builder. imprint draws a flag dot + title + status badge + authors + format; impart draws `MailStyleRow` over `MessageRowData` (already shared with macOS). Collapsing them would change one app's pixels — a product decision |
| The search field | **SPLIT — one field, two meanings.** | `.searchable(text:isPresented:placement:prompt:)` in a `navigationBarDrawer`, plus the ⌘F toolbar button (same glyph, same `toolbar.find` identifier, same shortcut) that is a hardware keyboard's only route to it | WHAT A QUERY MATCHES. imprint asks the STORE (`searchManuscripts` + the adapter's scope intersection + the dismissed rule); impart filters the loaded page over subject/from/preview, the three fields macOS's filter bar matches. The host takes a `Binding<String>` and never reads it |
| The three-state branch | **ONE SURFACE — `RecordListPhase`.** | "spinner / empty state / rows", with the rule that `isLoading` only wins when there is nothing on screen | Nothing. imprint had no loading state at all, so this existed once and a half |
| Empty state | **ONE RENDERER, per-app copy.** | `ChassisEmptyState.view(actions:)` — the state's own renderer, now with a recovery-affordance slot | The WORDS, as a `ChassisEmptyState` value built by the app, and whether there is a button: imprint offers New Manuscript, impart offers nothing because it registers no `onCreate` verb (the `RecordTriageNewTagPrompt` rule — omit the affordance, never show a dead one) |
| Reload triggers | **ONE SET, opt-in.** | `.refreshable`, `.task(id: scopeToken)`, `.onChange(of: dataVersion)` | WHICH of them an app wants. impart's column owns its read and takes all three; imprint keeps its triggers at the split-view root because the same `refresh()` feeds the SIDEBAR counts, and takes only pull-to-refresh (which its list did not have before) |
| Selection | **NEITHER — the host writes none.** | Nothing | No landing selection, no advance after triage: in compact width a `NavigationSplitView` is a stack, so writing a selection pushes the detail pane over the list being worked in (the rule at ~line 271, now confirmed for the third time). Keeping a selection VALID when rows leave is the app's reload — impart clears, imprint keeps the open manuscript |
| Row identifiers | **ONE CONVENTION.** | `RecordListRowIdentity.identifier(prefix:id:)` | The prefix (`manuscriptRow.` / `messageRow.`). Both UI suites match these BY PREFIX, and the strings previously lived only as literals in two view files and two test files |

| File | Reach | Role |
|---|---|---|
| `ImpressChassis/RecordKind/RecordListHostModel.swift` | ✅ both | the DATA half: `RecordListPhase.resolve` and the row-identifier convention. **Lifted into `packages/ImpressChassis` by C5** — the data/view split became a package boundary, with the renderer below staying in PMC |
| `Chassis/RecordKind/RecordListHostView.swift` | iOS | the renderer. Gated because `navigationBarTitleDisplayMode` and `.topBarTrailing` are iOS-only — the same data/view split as `RecordSidebarModel` / `RecordSidebarView` |
| `Chassis/Shared/ChassisEmptyState.swift` | ✅ both | ADDITIVE: `view(actions:)`, the same state with a recovery button under it |

**Why `.searchable` and not `ImpressFTUI.FilterInput`.** `FilterInput` is the
macOS list's inline filter BAR — 12 pt monospaced, a `FILTER` mode indicator, `?`
syntax help, ESC-to-clear — designed to be overlaid on a pointer-driven list.
The iOS idiom is the navigation-bar search field: it is what both adopters ship,
what `app.searchFields` in both UI suites drives, and what gives keyboard
dismissal and Cancel for free. Adopting `FilterInput` here would have replaced a
native control with a desktop one in two apps at once.

**Why this is not `AnyRecordListWrapper`.** The Stage 5d note named
`AnyRecordListWrapper`'s iOS half as the target; building it out was the wrong
move on inspection. That wrapper is the MIXED-kind list: rows are
`KindTaggedRow`s rendered through `RecordViewerRegistry` factories, with per-kind
sections, double-click and Return-to-open. The registry is EMPTY on iOS by
construction, so every row would fall back to `MailStyleRow` — which is already
what impart renders, and which for imprint would mean replacing its manuscript
row (flag dot, status badge, format) with mail chrome. That is a product change,
not a de-duplication. `AnyRecordListWrapper` still has no consumer; sharing this
host's chrome with it (grouped sections over a mixed list) is the follow-up.

Net: **imprint-iOS −22 code lines** (446 → 424 in `IOSManuscriptLibraryView`, and
the deleted part is the whole `manuscriptList` + the searchable/⌘F block + the
empty-state VIEW), **impart-iOS −24** (95 → 71, a quarter of the file), against
**235 shared code lines** added (15 model + 220 renderer). The line arithmetic is
not the point and is honestly reported as such: two adopters is where a shared
host breaks even, and the third (a figures or tasks list on iOS) costs a call
site instead of a file.

**imbib-iOS was deliberately NOT rewired.** Its list is `PublicationListView`
(2,021 cross-platform lines) over `PublicationListCore`, it just stabilized in
Stage 5d, and it needs a sort menu, a multi-select edit mode, a bottom bar and
pagination that this host has no opinion about. Convergence is a follow-up:
`RecordListHost` could host `PublicationListView`'s ROWS if the sort menu and
selection mode became parameters, and that is the shape to check next time
someone reaches for a fourth iOS list.

### Throughline on iOS (C1, 2026-07-30) — an original user-reported gap

`ThroughlineCoordinator` and `ThroughlineModel` were de-gated in wave 2 and have
been compiled into `imprint-iOS` ever since; only the VIEW stayed behind, in a
macOS-target directory. So the engine shipped on iPad with no way to look at it.

`apps/imprint/macOS/Views/ThroughlinePaneView.swift` → **`apps/imprint/Shared/Views/ThroughlinePaneView.swift`**
(both targets glob `Shared`, so this is a move plus `xcodegen generate`, not a
port). Nothing in the body was AppKit-adjacent. Three `#if` islands, no second
copy:

| Island | Why |
|---|---|
| `throughlineMenuChrome(width:)` | `BorderlessButtonMenuStyle` is macOS-only, and iOS's menu-from-a-glyph is already borderless. The fixed widths are pointer hit targets |
| `throughlinePaneWidth()` | `minWidth: 260, idealWidth: 340, maxWidth: 480` is the macOS inspector COLUMN's sizing; on iOS the pane is a sheet and takes its size from the detent |
| `throughlineLongPressLegend(state:help:)` | THE adaptation. `.help(_:)` compiles on iOS but only reaches VoiceOver, and the badge legend is where this pane keeps its meaning — so on iOS every badge answers a LONG PRESS with the same sentence. The `CitationPaperSheet` / `onCiteKeyLongPress` substitute for hover, applied to the one affordance that depended on it |

**Entry point: a toolbar button raising a sheet** (`toolbar.throughlineButton` →
`NavigationStack { ThroughlinePaneView } .presentationDetents([.medium, .large])`),
not a third `EditorPane` case. The throughline is an INSPECTOR — macOS mounts it
beside the source, not instead of it — and a third pane case would have to fight
two things that are already load bearing: the two-state Source↔Preview swipe
(`paneSwipe` derives its destination from the drag direction) and the persisted
`imprint.editor.compactPane` choice, which strands a user in a hidden pane for a
plain-text document.

**Sidecar hydrate was needed, and is now in `IOSManuscriptEditorHost`.** A
store-backed manuscript has no `.imprint` file bundle, so `document.throughlineSource`
was always nil on iOS and the pane would have opened on "No throughline yet" for
a document that has one. `loadFromStore()` now reads
`ImprintStoreAdapter.loadThroughline(documentID:)` — the same call the macOS side
panel's `PanelManuscriptBridge` makes. Persistence is unchanged: the pane's own
mutations go through `ThroughlineCoordinator`, whose debounced mirror already
worked on iOS.

Scope shipped: READ + anchor/mark parity with macOS — badges and their derived
states, the Story/Edit toggle with the raw Typst editor, the anchor menu
(`setAnchor` baselines the ledger), the coverage footer's "mark as supporting",
sync-proposal Accept/Discard, Remove Throughline, and the create affordance.
Adapted, not dropped: hover help (long press). Not present on iOS because the
seam itself is macOS-only: `ManuscriptSidePanel` registration — the iOS host has
a sheet instead. Section navigation IS wired: macOS jumps by character offset,
iOS resolves the chip's section key against the source's headings (the same
`ThroughlineText.sectionKey` slug the anchors use) and pulses `goToLine`.

### Cited papers on iOS (C1, 2026-07-30)

**(a) SHIPPED — imbib-iOS's Info tab renders `CitedInManuscriptsSection`.** The
wave-4 report called this "one line"; it was one line plus an access modifier —
the view was cross-platform but INTERNAL, so the only module that could name it
was PMC itself. It is `public` now (init included, snapshot injectable) and sits
in the same position as macOS's: after Flag & Tags, before the abstract, with its
own trailing `Divider()` and its own "render nothing when this paper is uncited"
rule.

One structural quirk found while wiring it, recorded rather than papered over:
the section's `.task(id:)` sits INSIDE its non-empty branch, and `EmptyView` runs
no lifecycle modifiers — so the section cannot bootstrap its own first load, on
either platform. Something already on screen has to warm
`CitedInManuscriptsSnapshot` (macOS: the sidebar's Cited in Manuscripts row;
iOS: `IOSInfoTab`'s own load task, which now does). The fix inside the section
would put a zero-size view in a `VStack(spacing: 20)` and add 20 pt of blank
space to every uncited paper's Info tab on both platforms, so it stays a
follow-up.

**(b) NOT SHIPPED — imprint-iOS keeps `presenting([.manuscript])`, and here is
the concrete gap.** Widening to `[.manuscript, .publication]` needs a publication
LIST and a publication DETAIL on imprint-iOS. The list half is now cheap: rows
are `PublicationRowData`, the scope is `PublicationSource.citedInManuscripts`,
the model is `PublicationListCore`, and the chrome is the new `RecordListHost` —
perhaps 40 lines. **The detail half is the blocker, and it is a shared-surface
gap, not an effort estimate:** there is no public, environment-free, read-only
publication detail in the chassis. `DetailView` and `InfoTab` are `#if
os(macOS)`, internal, and require `LibraryViewModel` + `LibraryManager` in the
environment; imbib-iOS's `IOSInfoTab` is app-target code in another project.
What IS public and reusable is the Stage-5b `Chassis/Detail/Shared/` set
(identifier links, Flag & Tags, exploration, notes document, PDF availability)
plus `BibTeXTab` — enough to ASSEMBLE a third publication Info surface in
imprint-iOS, which is exactly the outcome Stage 5b's verdict table says not to
produce without a pass dedicated to it. Shipping (b) would also mean a
two-kind selection route in imprint-iOS's split view (its detail column is
`IOSManuscriptEditorHost(manuscriptID:)` today). Recorded as: **the next
publication-detail pass should extract an iOS-capable read-only Info pane;
imprint-iOS's suppressed section is its first consumer, and the sidebar section
stays declaratively absent until then** (`SeededLibraryShellUITests` still
asserts that absence for the declared reason).

**The lane a cross-app fixture actually lives in (found while verifying (a)).**
`CitationUsageReader` has no `--ui-testing` in-memory redirect — it always opens
the on-disk workspace — and the records are written by imprint, which imbib links
no writer for. So the fixture has to be planted by the OTHER app:
`ImprintIOSApp.seedUITestDataIfNeeded` now writes one through imprint's own
`upsertCitationUsage`, and takes the SEED flag alone (impart's shape) so it can
reach the on-disk lane at all. One more thing that only shows up on a device:
**an unsigned simulator build has no app-group entitlement, so `SharedWorkspace`
falls back to a PER-APP `tmp/com.impress.suite-dev/workspace/impress.sqlite`** —
i.e. under `CODE_SIGNING_ALLOWED=NO` the suite does not share a store at all, and
the "one app group, one database" claim this document makes (verified with a
SIGNED build) is a signed-build property. `imbib-iOSUITests`'s new
`test_infoTab_showsCitedInManuscripts_whenImprintCitesThePaper` therefore reads
the real store and SKIPS when the fixture is absent, rather than pretending an
unsigned CI run can see imprint's rows.

Regression oracles for C1: `RecordListHostTests` (7 tests, `swift test` — the
three-state rule in both directions, the identifier convention, the model half
un-gated, the renderer iOS-gated, and both adopters free of a hand-written
`List` / `.searchable` / `.recordTriageRow`); one new row in
`ChassisCrossPlatformContractTests.crossPlatformContractFiles`;
`imprint-iOSUITests/ThroughlinePaneUITests` (booted simulator — the toolbar
entry point, the seeded throughline hydrated out of the store, both derived
badges, the Story/Edit toggle, and the long-press legend); and the extended
`ImprintIOSApp` seed, which now writes a throughline, a `citation-usage` record
through imprint's own writer, the folder tree and a dismissed manuscript.

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
(`collections.unified` in `store_metadata`) is **off by default** — it is a
deliberate, human-invoked data migration, not something an app turns on at
launch.

It used to be off *because it was unsafe*: imbib-core's legacy collection
readers (`list_collections`, `list_manuscript_collections`,
`list_collections_for_publication`, `rename_collection`,
`delete_library_undoable`, `count_collections`) plus
`FigureStoreReader.fetchFolders` and `ImploreStoreAdapter.fetchFolders` queried
the legacy `schema_ref` literals directly and would have gone empty (or thrown)
the moment it flipped. **ADR-0022 F1/F2/F3 closed all of them** — every export
and every Swift reader now resolves the marker, the two surviving legacy WRITERS
(`create_manuscript_collection`, `FigureStoreReader.createFolder`) were deleted
as dead, and imprint's `ManuscriptMigrationRunner` emptiness probe reads the
kernel instead of the literal that would have triggered a folder-duplicating
re-migration. The flip verdict is **READY** (ADR-0022 § F3), and the ordered
procedure lives there. `crates/impress-core/src/collection_migration.rs` carries
the full contract; the kernel reads correctly on both sides of the flip.

### Smart search (Stage 7 item 8, 2026-07-30)

`crates/impress-smart-search` + `impress-smart-search-service` — the Cmd+S
overlay's brain, ported out of the `ImpressSmartSearch` Swift package (2,408
lines). Ten tools under `smart-search-service_`. Pure functions over strings:
no store, no network, no app, so like the store-generic namespaces above they
are absent from `reachability::APP_GATED` and answer with every app closed.
CLI host is `impress` (the same store-generic binary), because these verbs
belong to no single app.

These automate no matrix cell — they are not GUI verbs. They exist because the
logic *was* unreachable: it decided what every Cmd+S keystroke did, and an
agent asking "what would imbib do with this pasted citation?" had no way to
find out. Now `classify-search-input` answers exactly that.

| Tool | What it exposes |
|---|---|
| `smart-search-service_classify-search-input` | the 5-way router: bare identifier / ADS fielded query / pasted citation blocks / URL / free text, with the overlay's own label string |
| `smart-search-service_normalize-ads-query` | the 6 repair rules (shorthand expansion, value quoting, boolean case, `First Last` → `Last, F`), plus the per-rule change log the UI shows |
| `smart-search-service_rewrite-free-text-query` | the no-model fallback: year/decade/"last N years"/"since YYYY", `refereed`, `by <Author>`, `abs:(…)` residue. Takes `this_year` explicitly |
| `smart-search-service_build-ads-query` | the stage that runs on a model's structured output, including the hallucination filters |
| `smart-search-service_clean-ads-query` | repair of a model's free-form query string |
| `smart-search-service_split-reference-blocks` | bibliography paste → blocks (`\bibitem`, numbered markers, blank-line) |
| `smart-search-service_extract-page-identifiers` | DOI/arXiv/bibcode/PMID + `<title>` out of HTML. The **fetch stays Swift** — this is the half after the bytes arrive |
| `smart-search-service_validate-parsed-reference` | drops identifiers a model invented; a hallucinated DOI resolves to the wrong paper silently |
| `smart-search-service_free-text-extraction-prompt` | the on-device prompt, verbatim — so it can be read and A/B'd instead of guessed at |
| `smart-search-service_reference-parse-prompt` | likewise for citation parsing |

**Three of the five original components keep a Swift half** (the on-device
`FoundationModels` session, the cloud runner call, and `URLSession`). That is a
platform split, not an unfinished port: see
[docs/smart-search-swift-rust-split.md](smart-search-swift-rust-split.md) for
where the line is drawn and why, and for the Foundation-vs-Rust behavioral
differences the golden corpus surfaced (`URL.path` percent-decoding, U+200B
whitespace, `capitalized` word boundaries, `JSONSerialization`'s BOM stripping).

Behavior is pinned by 2,628 golden cases in
`crates/impress-smart-search/test_fixtures/golden/`, captured from the Swift
implementations before their bodies were replaced and asserted from both sides
— `tests/golden_parity.rs` and
`PublicationManagerCoreTests/Golden/SmartSearchParityTests.swift`, the latter
through the real FFI. There is no regeneration path, deliberately.

### Archive and publisher parsers (Stage 7 item 9, 2026-07-30)

`crates/imbib-core/src/{mbox,publishers}` + `src/pdf/{title_quality,artifact_meta}`
+ `src/text/abstract_parser` + `impress-parsers-service` — 2,835 lines of Swift
parsers ported out of `PMC/{Mbox,Publishers,RichText,Artifacts,DragDrop}/`. Six
tools under `parsers-service_`. Pure functions over strings and bytes: no store,
no app, **no network**, so like the store-generic namespaces they are absent from
`reachability::APP_GATED` and answer with every app closed. CLI host is `impress`.

These automate no matrix cell — they are not GUI verbs. They exist because the
logic was unreachable: it decided whether a paper's PDF could be downloaded and
what an imported archive contained, and an agent had no way to ask.

| Tool | What it exposes |
|---|---|
| `parsers-service_parse-mbox` | an mbox archive → messages with `X-Imbib-*` metadata, decoded bodies and an attachment manifest. Attachment BYTES are withheld (names/types/sizes only) because a library export carries whole PDFs; `max_messages` caps and `truncated` says so |
| `parsers-service_decode-mime-header` | RFC 2047 encoded-words, charset-honouring |
| `parsers-service_decode-quoted-printable` | charset-aware quoted-printable, Latin-1 fallback rather than an empty string |
| `parsers-service_resolve-publisher-pdf` | which publisher owns a DOI, whether its PDF URL is predictable, the constructed URL, and a prose recommendation |
| `parsers-service_list-publisher-rules` | the whole 16-rule table, so an agent can see *why* a DOI resolves as it does |
| `parsers-service_extract-landing-page-pdf` | the PDF link out of landing-page markup, naming which strategy ran. **Does not fetch** — that half is Swift |

Behaviour is pinned by **437 golden cases** in
`crates/imbib-core/test_fixtures/golden/`, captured from the Swift
implementations before their bodies became shims and asserted from both sides —
`tests/stage7_{parser,pdf,abstract}_parity.rs` and
`PublicationManagerCoreTests/Golden/Stage7ParityTests.swift`, the latter through
the real FFI. There is no regeneration path, deliberately.

**Three components keep a Swift half**, and that is a platform split rather than
an unfinished port: the `URLSession` landing-page fetch, `PDFDocument`'s info
dictionary (pdfium *can* read it — `FPDF_GetMetaText` — nobody has written the
binding), and `UTType.conforms(to:)` / Vision OCR. See
[docs/parser-batch-swift-rust-split.md](parser-batch-swift-rust-split.md) for
where each line falls, the four Foundation-vs-Rust behavioural differences the
corpus surfaced (Latin-1 quoted-printable, `Character`-as-grapheme-cluster,
`DateFormatter` ignoring an inconsistent weekday, `URLComponents.path`
re-encoding), and the duplication retired.

**The bug that made this worth doing:** `MIMEDecoder.quotedPrintableDecode` built
one Latin-1 scalar per `=XX` octet, and `MIMEEncoder` writes every body as
quoted-printable over UTF-8 — so **an imbib mbox export followed by an imbib mbox
import corrupted every non-ASCII character in every abstract** (`Müller` →
`MÃ¼ller`). The only quoted-printable test in the suite used `=3D`. Fixed, with a
round-trip regression test (`Stage7ParityTests.mboxRoundTripPreservesUnicode`).

#### Known gaps recorded by this wave

| Gap | Where | Why it is not fixed here |
|---|---|---|
| **Abstracts render unpreprocessed.** `MathJaxAbstractView` interpolates the RAW abstract into its WKWebView (`RichText/MathJaxView.swift`), so an arXiv abstract's `\\Omega_m` shows visible backslashes and an ADS `<mml:math>` abstract renders as markup — even though `AbstractParser` fixes both and always has. Reached from `InfoTab` (macOS) and `IOSInfoTab` (iOS) | `RichText/MathJaxView.swift` | one line, but it changes what the detail pane renders, which is a product decision with its own before/after — not a side effect of a port wave. `RichText/MathJaxView.swift` was also outside the wave's file boundary |
| **`MathTextParser` is a live Swift duplicate** of `AbstractParser`'s segment splitter, with two deliberate differences (`AbstractParser` trims display-math latex and rejects inline math containing a blank line; `MathTextParser` does neither and rejects any newline). Reached via `RichTextView` → `NotesTab`, `IOSHelpView` | `RichText/RichTextTheme.swift` | same boundary; converging them changes note rendering |
| **A `freezesSource` facet on `StatusSpec`** would make CounselEngine's `autoSnapshotStatuses` a derivation instead of a literal. The set is not expressible from existing facets: `isTerminal` = {published, archived, dismissed}, which wrongly includes `dismissed` and wrongly excludes `submitted` | `Chassis/RecordKind/RecordKindDescriptor.swift` + `BuiltinRecordKinds.swift` | `Chassis/**` was outside the wave's boundary. Interlocked meanwhile by `JournalStatusPolicyParityTests` (item 10) |
| **`bestAuthors` splits on `,` only**, so `"Smith, John; Doe, Jane"` becomes three names — and the comma-separated form is mangled identically | `imbib-core/src/pdf/title_quality.rs` | the real fix is the shared author parser in `impress-bibtex`, which changes every PDF import and needs its own corpus |
| **`impart-core::mbox` escapes `From ` on write but never unescapes on read**, and `parse_mbox_message` drops every `X-*` header — so impart's conversation round trip is asymmetric | `crates/impart-core/src/mbox.rs` | impart was not this wave's boundary. Found during the twin survey |
| **`ImpartRustCore` is still a placeholder** — 146 lines of hand-written stub structs and a `threadMessages` that returns one thread per message. impart's CLAUDE.md claim that MIME and threading "live in Rust" describes intent, not shipped code | `apps/impart/ImpartRustCore/` | wave 5 found this; still true |

#### Deleted as dead code

`PMC/Search/SmartQueryTranslator.swift` (444 L) and its
`SmartQueryTranslatorTests.swift` (293 L, 37 test cases). Verified independently
before deletion: the entire reference footprint was 2 self-references, 37 test
references and 2 doc mentions — **zero production consumers** in any `.swift`,
`.rs`, `.pbxproj`, `Package.swift` or manifest. Its original consumers
(`NLSearchService`, `NLSearchFormView`, `NLSearchOverlayView`) were deleted in
`30419c30`; its function is served by the Rust-backed
`FreeTextQueryRewriter.degenerateRewrite` fallback. It declared no extension,
conformance or typealias.

Also deleted: `PMC/Publishers/Resources/publisher-rules.json` — a stale 12-rule
subset of the live 16-rule table that shipped in **every app bundle** and was
**never loaded** (`setCustomRulesPath` had no callers), plus its
`Package.swift` `.copy(...)` entry.

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

## Cross-app plumbing (hardening C3, 2026-07-30)

### The store mirror is one kernel now (`packages/ImpressStoreKit`)

Three apps keep their OWN source of truth and MIRROR it into the shared item
store so the others can see it — impart (Core Data is the truth), implore (the
JSON figure library is), impel (impel-taskd's rows are). Each had grown the same
plumbing independently, and the row mapping — the only genuinely app-specific
part — was the smallest piece of it.

`ImpressStoreKit/StoreMirrorKernel.swift` now owns the generic half. It lives in
`packages/ImpressStoreKit` because that is the one place all three can link:
none of them depends on PMC, and the package was already the home of
`StoreEvent`/`MutationKind` (the event bus the old plans mentioned) plus
`ListSnapshot` and `BackgroundOperationQueue` — the mirror kernel is the same
layer, not a new one.

| Piece | What it replaces | Who uses it |
|---|---|---|
| `StoreMirrorUpsert` | impart's `MailItemUpsert` (now a typealias to it), implore's inline FFI row construction | impart, implore |
| `StoreMirrorOp` + `StoreMirrorWriteGate` | impart's `PendingStoreOp` / `dispatch` / `buffer` / `flushPendingOps` / `apply` — the startup embargo, the ordered drain, the ≤500-row batching | impart today; available to implore/impel |
| `StoreMirrorBackend` | nothing — the NEW seam. Four verbs (`upsertBatch`, `upsertOne`, `setRead`, `setParent`) | impart, implore |
| `LazyStoreHandle` | three hand-rolled lazy lock-guarded opens | all three |
| `StoreMirrorPayload` | impart's `encodeJSON`, implore's two inline `JSONSerialization` blocks | impart, implore |
| `StoreMutationSignal` | `didMutate()` — bump a version, fan out a typed `StoreEvent` | impart, implore |

**`StoreMirrorBackend` is a protocol on purpose, and the reason is testability
plus a build fact.** `ImpressRustCore`'s XCFramework is a local build artefact
(gitignored — `crates/impress-store-ffi/frameworks/` is 171 MB of `cargo`
output), which is exactly why all three adapters guard their FFI use with
`#if canImport(ImpressRustCore)`. If the kernel named `SharedStore`,
ImpressStoreKit would inherit that requirement and the kernel's own tests would
stop running without a Rust build. Keeping the store behind four verbs means
`StoreMirrorKernelTests` exercises the embargo, the ordering guarantee, the batch
split and the failure policy against an in-memory fake — **logic that had ZERO
tests in its previous home**, because reaching it needed a real UniFFI handle and
a real 90-second wall clock. The price is a ~12-line mechanical conformance next
to each app's own guarded FFI import (impart's and implore's; impel writes
nothing and needs none). Collapsing those two would take a shim target that
depends on both packages, which is the right move the moment a third writer
appears.

**Three latent defects the extraction surfaced**, all of them consequences of the
same logic existing three times:

1. **impel's store handle retried a failed open forever.** `ImpelStoreAdapter.handle()`
   cached success but had no `openAttempted` flag, so with no database on disk
   every `fetchThreads` / `fetchAgentRuns` paid a full open-and-throw, for the
   life of the process. `LazyStoreHandle` attempts once and remembers.
2. **`encodeJSON` could trap the process.**
   `JSONSerialization.data(withJSONObject:)` raises an **NSException**, not a
   Swift error, for an object graph containing a non-JSON value (a `Date`, a
   `URL`) — `try?` does not catch it. Every hand-rolled copy had the same latent
   crash. `StoreMirrorPayload` pre-checks with `isValidJSONObject`.
3. **implore's payloads were not key-sorted.** impart's were. Since a mirror
   re-upserts the same logical row whenever its source changes, unsorted output
   made byte-identical payloads look different and churned `modified` on every
   sync. Both now sort.

**Behaviour deliberately NOT changed:** implore's and impel's writes still land
IMMEDIATELY. They do not go through the startup embargo, which they arguably
should — CLAUDE.md's 90-second invariant is not impart-specific — but adopting
the gate would defer a user's figure save for up to 90 s after launch, and that
is a product decision, not a refactor. The gate is now sitting there for them.
Also unchanged: `encodeJSON`'s two failure policies are distinct on purpose —
`encodeJSON` returns `"{}"`, `encodeJSONIfValid` returns `nil`, and implore's
figure/dataset writes use the latter so a bad payload SKIPS the write rather than
replacing a figure's metadata with silence.

Regression oracles: `StoreMirrorKernelTests` (26 tests in ImpressStoreKit),
plus the three packages' own suites unchanged — MessageManagerCore 25, ImpelCore
9, ImploreCore (no adapter tests; implore's real coverage is UI tests, so its
oracle is the macOS build).

### One authoritative port table — the implore/impel collision, resolved

`SiblingApp.descriptors` in `packages/ImpressKit/Sources/ImpressKit/SiblingApp.swift`
is THE port table, and the rule is now explicit in its doc comment: **servers
align TO the table; the table does not move to match a server.** The reasoning is
that siblings dial `SiblingApp.<app>.httpPort`, so whatever the table says is
what the rest of the suite believes, and a server binding anything else is simply
unreachable.

Four separate disagreements with it existed, and every one was a live bug:

| Site | Was | Now |
|---|---|---|
| `apps/implore/.../HTTPAutomationServer.swift` + `ImploreHTTPRouter.swift` | bound **23124** — impel's port | `SiblingApp.implore.httpPort` (23123) |
| `ImpressCommandPalette.AppEndpoint` | a second port table with impel and implore **transposed** | derived from `SiblingApp.descriptors` |
| `MessageManagerCore.ArtifactResolver` | dialled **23121** for imbib and **23123** for imprint | descriptor lookups (23120 / 23121) |
| `ImpelCore.ImpelClient.defaultPort` | **23123** — implore's port | `SiblingApp.impel.httpPort` (23124) |

implore's and impel's servers both binding 23124 meant whichever app launched
first won the socket and the loser's automation API silently never came up. The
palette asked each of the two for the other's commands. `ArtifactResolver` asked
imprint for `/api/publications/…` and implore for `/api/documents/…` — both 404
forever, which reads exactly like "the artifact doesn't exist".

Every binding site and every cross-app dial in the five apps is now a lookup
rather than a literal (imbib's server was already the precedent), including
`ImpelHTTPServer`, `ImpartHTTPRouter`, `ImprintHTTPServer`, the four
`UserDefaults.register` defaults, the two Settings `@AppStorage` defaults, and
imprint's `InlineCompletionService` imbib dial. The Rust side follows:
`crates/implore-service-http`'s `DEFAULT_BASE_URL` is 23123. `CLAUDE.md` /
`AGENTS.md` carry the full five-row table with an explicit note that it is a
TRANSCRIPTION and is wrong if it disagrees with the Swift.

> **USER-FACING: implore's automation port moved, 23124 → 23123.** Anyone with
> saved automations, scripts, browser-extension config or MCP wiring pointing at
> `localhost:23124` for implore must repoint to 23123. 23124 is impel. Users who
> ran implore and impel together were already only getting one of them.

Regression oracles: `SiblingApp` port uniqueness and accessor-vs-table agreement
in `ImpressKitTests` (29 tests), and the new
`testAppEndpointsAreDerivedFromSiblingAppTable` in `ImpressCommandPaletteTests`,
which asserts the palette's presets are DERIVED from the table rather than merely
equal to it.

**Judgment call: `ImpressCommandPalette` gained an `ImpressKit` dependency.** The
package was declared `dependencies: []` — zero-dependency by design — and the
alternative was to keep two correct literals with a cross-reference comment and a
parity test against a fixture. The edge is better, for four reasons. (1)
ImpressKit is itself a LEAF package with no package dependencies of its own, so
the edge adds no transitive weight. (2) Every app that would host the palette
already links ImpressKit, so it adds nothing at link time either. (3) A parity
test can only REPORT drift after it happens; deriving from one table makes drift
unrepresentable — and this exact drift had already shipped, transposed, with a
test that froze the wrong values. (4) The palette's entire job is dialling the
sibling apps, so the sibling-app table is its domain model, not foreign weight; a
client of the suite that refuses to know the suite's address book is not
decoupled, it is uninformed. Cost of being wrong is near zero today: no target
links `ImpressCommandPalette` at all — it is written but not yet activated.

## Known gaps (tracked)

- **~~The suite has no shared keychain access group, so only imbib can read the
  ADS/SciX credentials.~~** — **DECIDED 2026-07-30, NOT IMPLEMENTED, and that is
  the decision.** The gap is real and stays open on purpose; what follows is the
  record of why, written here because a deliberate non-implementation with no
  written reason is indistinguishable from an oversight.

  **The hazard.** `com.imbib.credentials.ads.apiKey` and its siblings are ACL'd
  to imbib's code signature. When a differently-signed process reads them, macOS
  raises a SecurityAgent password prompt, and the synchronous
  `SecItemCopyMatching` behind `KeychainSwift` blocks the CALLER's
  cooperative-pool thread until the user answers. That is not a slow read, it is
  a hang: impart's `/api/logs` (a `@MainActor` route) froze on exactly this. Six
  apps now link the chassis and five of them are signed differently from imbib,
  so any chassis code path that touches an imbib-owned keychain item is one
  adopter away from reproducing it.

  **What shipped: a reachability check.**
  `CredentialManager.itemsAreReadableWithoutPrompting` — `Bundle.main
  .bundleIdentifier == SiblingApp.imbib.bundleID`. A bundle-identity comparison,
  no keychain query, so it cannot itself prompt or block. It is deliberately a
  REACHABILITY fact and not a policy: `AppShellConfiguration.permits(.search)`
  still says which shells surface external search, and impress still permits it.
  impress renders the Search section; it just does not attempt a read it
  provably cannot complete.

  **What the check covers — one call site, and that is the whole point.**
  `TabContentView`'s boot task, the only place CHASSIS code (shipped into all six
  apps) reads imbib-owned credentials, gates on `permits(.search) &&
  itemsAreReadableWithoutPrompting`. The other ~9 `CredentialManager.shared`
  readers in the tree — `SciXLibraryService`, `SciXSyncManager`,
  `InboxCoordinator`, `EnrichmentSettingsView`, `ADSSetupStepView`,
  `OnboardingSheet`, both `imbibApp`s, `IOSSidebarHost` — are NOT gated and must
  not be: every one of them is imbib-app-target code that only ever runs inside
  the imbib process, where the answer is trivially true. **The rule for new
  code:** a credential read added to `Chassis/` or to any `packages/Impress*`
  needs the gate; one added under `apps/imbib/imbib/` does not. If that ever
  stops being the boundary, the gate has to move with it.

  **What a shared access group would entail, if this is ever revisited.** It was
  rejected on cost, not taste, and the cost is four things, in order:

  1. **Re-sign imbib** with a `keychain-access-groups` entitlement (e.g.
     `$(AppIdentifierPrefix)com.impress.suite`). No app in the suite declares one
     today — the sharing mechanism is App Groups
     (`QG3MEYVHMS.com.impress.suite`), which covers the store and the workspace
     and does not cover the keychain.
  2. **Migrate every already-stored item.** An item written without an access
     group is not retroactively a member of one. Each existing item must be read
     under the old ACL and re-added under the group, by the imbib process, once,
     idempotently — and the read half of that migration is the very operation
     that prompts if it is attempted from anywhere else.
  3. **Set `KeychainSwift.accessGroup`** in `CredentialManager` (today an
     explicit `nil`, commented "use the app's default keychain (works in
     sandbox)"), and decide what happens for a user who upgrades one app but not
     the others — the migration is imbib's, so the siblings see nothing until
     imbib has run.
  4. **Re-sign the other five apps** with the same group, which makes every
     sibling's provisioning profile depend on one shared identifier.

  Steps 1 and 4 are release-engineering changes to six shipping apps; step 2 is
  a one-shot data migration with a "user cancelled the prompt" failure mode. The
  reachability check is four lines. The trade was made on that ratio, and the
  consequence, stated plainly, is that **credential ENTRY stays in imbib** —
  which is where the user set them — and the other five shells surface search UI
  backed by whatever needs no key.

  Pinned by `AppShellConfigurationParityTests
  .testTheKeychainReachabilityGateNamesImbibsBundleIdentity`. See ADR-0022 D9
  finding 6.

- **~~The composed (per-app-group) sidebar is iOS-ONLY; macOS impress still runs
  the flat preset.~~** — **CLOSED 2026-07-31 (X3).** macOS impress renders the
  same `SidebarComposition` through the `NSOutlineView`. All five recorded
  follow-up steps were taken; what each one actually cost is worth keeping,
  because four of the five turned out to have a single structural answer.

  **(1) Testability first, and it was the whole unlock.** The decisive
  objection — "no test constructs `ImbibSidebarViewModel`" — was half wrong at
  HEAD (`SidebarExplorationMenuTests` builds one with `MockPublicationStore`,
  which the injectable `init(store:)` already allowed) and half exactly right:
  nothing could seed or observe the half that PERSISTS, because section order
  and collapse state were read from `UserDefaults.standard` in stored-property
  initialisers — before any test could intervene — and written through
  process-wide singletons. `SidebarPersistenceScope` is the `StoreKernelScope`
  shape applied one layer up: a struct of load/save closures, a `.userDefaults`
  value that is byte-for-byte the singletons the code used before, and an
  `.inMemory()` value backed by a scratch box. With it, `MacComposedSidebarTests`
  (30 tests) builds the view model headlessly and walks the tree through the two
  entry points the `NSOutlineView` coordinator uses
  (`outlineConfiguration.rootNodes` + `children(of:)`), so nothing is asserted
  through a back door. That file is the launch this workflow cannot perform.

  **(2) macOS section-collapse persistence — fixed for ALL SIX shells.**
  `handleExpansionChange` had no callers because `SidebarOutlineView` offered
  nowhere to call it from. It now takes the NODE (a grouped section's id is
  namespaced, so it cannot be matched against `ImbibSidebarNodeID.section(_:)`)
  and is wired to a new `SidebarOutlineConfiguration.onExpansionChanged`, fired
  from `outlineViewItemDidExpand`/`DidCollapse` behind the existing
  `isUpdatingProgrammatically` guard so a reload never writes state back as if
  the user had done it. Flat shells keep the `sidebarCollapsedSections` key
  space; composed shells write `SidebarCompositionKey` into
  `sidebarCompositionCollapsed`. This was a pre-existing bug in every shell, not
  something the composition introduced.

  **(3) The group row style is ADDITIVE, and unreachable in the five siblings.**
  `SidebarOutlineCellView.configureAsGroup` and `configure` are byte-unmodified;
  a new `configureAsAppGroup(displayName:systemImage:menu:)` sits beside them,
  reached only when `SidebarOutlineConfiguration.isAppGroupItem` says so — and
  the view model passes that closure as **nil**, not as a closure returning
  false, whenever `sidebarComposition == nil`. So for imbib, imprint, implore,
  impel and impart the new branch in `viewFor` is not merely false-valued, it is
  unreachable, and `testSinglePresetShellsSupplyNoAppGroupPredicateAtAll` pins
  that. Section headers keep their own tier and therefore keep `sectionMenu` —
  the alternative the original note feared (demoting headers to ordinary rows)
  was never taken.

  **(4) `treeDepth` at ten hand-assigned sites: none of them changed.** Grouping
  is applied at exactly ONE place, `children(of:)`, which — whenever the parent
  carries a group — tags each child with that group, re-keys its id into the
  group's namespace and adds one to its `treeDepth`. Since each node is produced
  exactly once by its parent's `children(of:)` call, one uniform rule corrects
  the whole subtree. The id re-keying is not cosmetic: `ImbibSidebarNodeID` is
  deterministic, so imbib's red flag and imprint's red flag would otherwise BE
  the same UUID inside `SidebarOutlineView`'s UUID-keyed wrapper cache, child
  map and flattening info — one row silently standing in for another.

  **(5) Section drag-reorder keeps working; cross-group is refused loudly.**
  `canAcceptDrop` gained one arm before the existing `(.section, _) -> false`
  rule: a section may drop on its OWN group header. Without it, section reorder
  would have died at the first gesture with no error (`handleReorder` treats
  `parent == nil` as "section reorder", and a grouped section's parent is never
  nil). A cross-group drop is refused AND logged once per distinct pair —
  `canAcceptDrop` runs on every mouse-move, and a refusal that fills the console
  is a refusal nobody reads. `handleReparent` carries the write-side half of the
  same guard. The section ORDER stays one suite-wide `SidebarSectionType` list;
  a per-group reorder re-sequences only the slots that group already occupied
  (`ImbibSidebarViewModel.merging`), so the four groups the user was not looking
  at do not move.

  **What the impress macOS window now constructs.** `ImpressChassisRoot` passes
  `sidebarComposition: .impress` to `ChassisRootView`, whose parameter defaults
  to nil — so a sibling cannot acquire a group tier by omission, and there is no
  `appID ==` test anywhere (ADR-0022 D9). The preset is UNCHANGED and still
  pinned by the parity suites: what impress may RENDER and what its sidebar
  SHOWS are two questions now, and two values.
  `ImpressShellTests.testMacRootRunsTheUnmodifiedImpressPreset` was replaced by
  `testMacRootRunsTheImpressPresetAndTheComposedSidebar`, which keeps every
  assertion the old one made and adds the composition.

  **The user-facing payoff, same as iOS.** impress-macOS now has a Flagged
  section per group, each bound by its own app's preset — imbib's to
  `.publication`, imprint's to `.manuscript`. The routing is done on the NODE
  (`SidebarNodeGroup.retargetedTab`), which produces the tab that already
  carries its kind (`.record(.flagged(kind, colour))`), so `SectionContentView`
  is completely unmodified: it never has to ask the window's flat preset what
  Flagged means. `.publication` deliberately falls through unchanged, so the
  imbib group behaves exactly as flat imbib does.

  **Still open, recorded rather than papered over.** Per-group flag COUNTS are
  computed for `.publication` and `.manuscript` only (the two kinds with a
  flag-only read verb); any other kind's Flagged rows render without a badge,
  which is the shipped behaviour for every kind that has never had one. And no
  macOS app was launched in this workflow, so the group row's PIXELS are
  unverified — the 30 headless tests assert the tree, the ids, the depths, the
  persistence and the drop guards, not the drawing.

  The original entry follows.

  impress-iOS's sidebar is now a `SidebarComposition` — five collapsible groups,
  one per sibling app, each built by running `RecordSidebarBuilder` against that
  app's own `AppShellConfiguration`. macOS impress still passes the flat
  `.impress` preset to `TabContentView`/`ImbibSidebarViewModel`, so it keeps ONE
  Flagged section bound to `.publication` and cannot show flagged manuscripts —
  the exact limitation iOS just lost.

  **This was scoped deliberately, not overlooked.** The macOS build SITE is
  cheap (`ImbibSidebarViewModel.buildSectionNodes`, ~18 lines, plus one
  `children(of:)` arm and one `ImbibSidebarNodeType` case; `rebuildTabMap`,
  `findNode`, `SidebarOutlineView.rebuildData` and `TreeFlattener` all recurse
  and need nothing). Four things around it are not:

  1. **The group ROW STYLE lives in the shared package.** `isGroup` drives one
     hardcoded appearance in `ImpressSidebar/SidebarOutlineCellView.swift`
     (`configureAsGroup`, no depth parameter, tree lines cleared, uppercased, no
     icon or count) and `shouldSelectItem` makes group rows unselectable. A
     second tier means either editing that file — which is on the rendering path
     of ALL SIX shells, against the requirement that the five siblings' frozen
     pixel surfaces stay untouched — or demoting section headers to ordinary
     rows, which loses the section-header context menu (`sectionMenu` is only
     consulted on the group path).
  2. **`treeDepth` is assigned BY HAND at ten builder sites** in
     `ImbibSidebarViewModel`. Indentation is drawn from it, not by AppKit
     (`indentationPerLevel = 0`), so a new level above the sections shifts
     nothing automatically.
  3. **Section drag-reorder would break silently.** `handleReorder` treats
     `parent == nil` as "root = section reorder", and `canAcceptDrop` refuses
     `(.section, _)` outright — so with groups the gesture dies before the
     handler, with no error.
  4. **macOS section-collapse persistence is already half-broken.**
     `handleExpansionChange(nodeID:expanded:)` has NO CALLERS: collapse state is
     loaded at launch and never saved. Group collapse would therefore ship
     non-persistent, failing the design requirement, unless that pre-existing
     bug is fixed first.

  And the decisive one: **no test constructs `ImbibSidebarViewModel`.** The
  macOS sidebar view model is the largest file in the repo (3487 lines) and is
  covered only indirectly, so a change there is verifiable by launching the app
  — which this workflow does not do. iOS's half is `RecordSidebarBuilder` +
  `RecordSidebarView`, both unit-tested in `swift test`
  (`SidebarCompositionTests`, 14 tests) and screenshot-verified on a simulator.

  **The follow-up, in order:** (a) give `SidebarCollapsedStateStore` a caller on
  macOS so section collapse persists at all; (b) add a second group tier to
  `ImpressSidebar` behind a flag the five siblings do not set, with the parity
  suites as the oracle; (c) wrap `buildSectionNodes` in
  `SidebarComposition.impress` for the impress shell only; (d) two `canAcceptDrop`
  / `handleReorder` arms and a decision about cross-group section moves;
  (e) expand the default leaf's group in `selectDefaultSectionLeaf`
  (`restoreSelection` deselects when an ancestor is collapsed —
  `beginEditingNode`'s ancestor-expansion is the precedent).

- **~~Ten `UTType(exportedAs:)` identifiers in shared code are declared per app,
  not in `apps/chassis-utis.yml`~~** — **CLOSED 2026-07-30.** Nine graduated;
  one (`com.impress.bibtex-entry`) stays per app, deliberately. The original
  entry: the ten were `com.impress.paper-reference`, `citation-key`,
  `conversation-ref`, `document-reference`, `figure-reference`,
  `research-artifact-reference`, `veusz-plot-reference`, `com.imbib.bibtex`,
  `com.imbib.bundle`, `com.impress.bibtex-entry`. Their call sites are in
  PMC/ImpressKit — code every app compiles — so each was only safe while every
  app that reaches its call site declared it, and that property was unaudited.

  **Audit result: the premise was wrong for four of the ten.**
  `veusz-plot-reference` and `research-artifact-reference` were exported by NO
  app — four apps merely *imported* the first, which does not satisfy
  `UTType(exportedAs:)`, and nothing declared the second — and
  `com.imbib.bibtex` / `com.imbib.bundle` appeared in no `project.yml` and no
  `Info.plist` anywhere. They were not "declared per app"; they were
  UNDECLARED, and safe only because nothing reaches them. Two more were actively
  faulty: imprint reaches `paper-reference` (shared
  `MailStylePublicationRow.swift:411`, through the `.citedInManuscripts`
  publication list its `AppShellConfiguration` makes visible) and
  `figure-reference` (shared `SourceEditorView.swift:81`, through
  `ManuscriptDetailPane` and `FocusModeView`), but exported NEITHER — imbib
  exported the first, and implore, the one app that never reaches it, exported
  the second. The other four (`document-reference`, `conversation-ref`,
  `citation-key`, `bibtex-entry`) are reached by ZERO apps: the `Transferable`
  conformances in `ImpressKit/DataModels` are never used in a transfer
  position, and `isBibTeX` / `isImbibBundle` / `UTType.from(extension:)` have no
  callers at all.

  **What landed.** Nine identifiers moved into `apps/chassis-utis.yml` (12 → 21
  entries) and the per-app `UTExportedTypeDeclarations` /
  `UTImportedTypeDeclarations` entries they replaced were deleted from all five
  `project.yml`s — including every `UTImportedTypeDeclarations` entry for a
  chassis type, which was never doing anything (ADR-0022 settled that: exported,
  not imported, in every host). All eight template-bearing targets now export
  all 21, verified from the BUILT bundles: `imprint.app` exports
  `com.impress.paper-reference` and `com.impress.figure-reference` where it
  previously only imported them, and no target lost an exported identifier.
  `appDeclaredExceptions` is down to one entry and carries the per-identifier
  reachability evidence in a doc comment, so the list cannot silently grow back.

  **The rule this establishes: graduate drag payloads, keep documents.**
  `com.impress.bibtex-entry` is the sole survivor because it is the only one of
  the ten carrying app-specific LaunchServices metadata — imbib declares it with
  `public.filename-extension: [bib]`. Hoisting that would change what
  `UTType(filenameExtension: "bib")` resolves to in the four other apps, and
  shared code reads exactly that at `DragDropCoordinator.swift:86`. Nothing in
  any app reaches `UTType.impressBibTeXEntry`, so there is no fault to buy that
  risk with; if it ever acquires a real call site, move the call site out of
  ImpressKit rather than hoisting the `.bib` claim.

  Two smaller gaps the audit surfaced, NOT closed by it:
  (a) four imbib targets link PMC WITHOUT `templates: [ChassisUTIs]` —
  `imbib-ShareExtension`, `imbib-iOS-ShareExtension`, `imbib-FileProvider`,
  `imbib-iOS-FileProvider`. They declare no exported types at all, so any
  chassis `UTType(exportedAs:)` they touch would fault; none does today. Noted
  in the `chassis-utis.yml` header.
  (b) `ImpressArtifact` (`packages/ImpressKit/.../DataModels/ImpressArtifact.swift`)
  has zero references outside its own declaration, and it is the sole consumer of
  `ImpressDocumentRef` / `ImpressResearchArtifactRef` / `ImpressVeuszPlotRef`.
  That is *why* six of the ten were unreachable: the cross-app artifact drag
  story is declared but not wired.

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

- **impart-iOS on the chassis (Stage 5c, 2026-07-30) — the last iOS target with
  zero chassis reach, and an HONEST READ-ONLY v1.** `impart-iOS/Views/IOSContentView.swift`
  (380 lines of `TabView`) is DELETED; the root is `IOSMailHostView` — PMC's
  `RecordSidebarView` + `IOSMessageListColumn` + PMC's `MessageDetailPane` — over
  `AppShellConfiguration.impart.presenting([.message])` and
  `ImpartSidebarBindings` (89 code lines). What the deleted shell contained,
  verbatim: `Text("No accounts configured")` under `// TODO: Populate with
  accounts and mailboxes`; `Text("Message content will appear here")` under
  `// TODO: Fetch and display message content`; bottom-bar buttons whose bodies
  were `// Archive`, `// Delete`, `// Reply`, `// Forward`; a Send button reading
  `// TODO: Send message`; an Accounts `+` reading `// Add account`.

  **What runs on iOS, surveyed before any code:** reads work (the app-group
  `impress.sqlite` — VERIFIED: a signed simulator build opens
  `AppGroup/…/workspace/impress.sqlite`, the same file imbib-iOS and imprint use);
  bodies are the payload `body` field as PLAIN TEXT (impart's mirror writes
  `CDMessage.content.textBody`), not CAS, so remote content is blocked by
  construction — nothing in this target renders HTML or loads a URL, and PMC is
  denied WebKit by `scripts/check-chassis-deps.sh`. Star/flag/tag write through the
  same `RecordTriageActions.storeBacked` ops macOS uses. **Read state is NOT
  written** and **no `RecordHostVerbs` are registered**: both verbs macOS supplies
  are verbs iOS cannot perform — `isRead` is mirrored FROM Core Data (a store-only
  write would be reverted by the Mac's next mirror pass), and there is no SMTP
  path anywhere (`RustMailProvider.send` is `// Pretend to send`, `fetchMessages`
  returns `[]`, `ImpartRustCore` is a placeholder package with no Rust). So the
  chassis omits the `n` key and the empty-state create button rather than
  offering dead ones, and impart-iOS's refresh gesture re-READS the store instead
  of pretending to fetch. There is no IMAP sync and no scheduler on EITHER
  platform.

  **Three ADDITIVE chassis extractions, each because iOS needed an answer that
  existed only inside a macOS-gated file:**
  - `MailStoreReader.messages(in:)` — `MessageListWrapper.reload()`'s body. "Which
    messages does All Inboxes / an account / a folder / a flag colour contain",
    thread-collapsed, is not a rendering question; both list hosts call it now.
  - `Chassis/Messages/MailSidebarSnapshot.swift` — the mail sidebar TREE (All
    Inboxes, accounts, folders in role order with the role's glyph and a count).
    It lived in `ImbibSidebarViewModel.mailChildren()` and needed
    `MailStoreReader`'s INTERNAL payload decoders, so an app-target iOS sidebar
    could not have reproduced it even by copying. macOS's `mailChildren()` now
    maps this snapshot.
  - `MessageDetailPane` DE-GATED. It was `#if os(macOS)` from the GUI-meld Phase 1
    header plus an `import AppKit` nothing used; the body is plain SwiftUI over
    cross-platform types. impart-iOS renders THE pane, not a clone — the Stage-5b
    lesson from imbib's publication detail, applied before the second copy exists.

  **Flagged mail is still absent on both platforms** (`.impart` does not permit
  `.flagged`, and it would need a `.flagged: .message` binding + routing). Mail
  folders carry `isFolder: false`, so the shared organise grammar stays off a
  server mailbox. The Chat/Category/Research/Development custom surfaces are NOT
  registered on iOS: they read an `InboxViewModel` whose `accounts` is assigned
  nowhere in MessageManagerCore, so they are empty on macOS too.

  Regression oracle: `impart-iOSUITests` (impart's FIRST UI-test target) — sidebar
  sections + seeded mail tree, list rows + thread badge, the shared detail pane,
  and the availability-filtered settings screen, on a booted simulator with a
  `--uitesting-seed` fixture (`impart-iOS/Support/ImpartIOSUITestSeed.swift`) that
  writes through `ImpartStoreAdapter`'s own row builders so a seeded row is shaped
  exactly like a mirrored one.

  **Reported gap — there is no shared iOS LIST host.** Every macOS list wrapper is
  `#if os(macOS)`, so imprint-iOS, imbib-iOS and now impart-iOS each write their
  own `List`. Three is where "each app writes its own" stops being a coincidence.
  The parts that matter are shared (rows, row chrome, triage grammar, scope→rows);
  what is duplicated is the `List` + search field + reload triggers.

  **NARROWED, and the `RecordListHost` idea REJECTED, by Stage 5d
  (2026-07-30).** Investigating it from imbib found the framing wrong. imbib-iOS
  does not hand-write a `List` at all — its host is
  `SharedViews/PublicationListView.swift`, 2021 cross-platform lines with the
  rows, the sort menu, the swipes, the toolbar and `.refreshable` already in it.
  What imbib-iOS duplicated was the MODEL: scope→rows, the sort, the reload
  triggers and the triage sequences, now `Chassis/Shared/PublicationListCore` +
  `PublicationScope` + `PublicationListOrder` + `PublicationListMutations` (see
  the Stage 5d section). So a `RecordListHost` generalized from imbib would be
  generalized from a file imbib would not use, and the two apps that WOULD use it
  (`IOSMessageListColumn`, 177 lines; the `listColumn` middle of
  `IOSManuscriptLibraryView`) are not the ones asking. **The honest shared iOS
  list host for record kinds is the iOS half of `AnyRecordListWrapper`** — which
  still has no consumer on either platform, so building its iOS twin now would
  be a second surface with zero callers. Recorded as still-open, with the target
  named: give `AnyRecordListWrapper` its first consumer, then de-gate it.

  **CLOSED by C1 (2026-07-30) — and the named target turned out to be the wrong
  one.** The host is `RecordListHost` (`Chassis/RecordKind/RecordListHostView`
  + its cross-platform `…Model` half), adopted by imprint-iOS and impart-iOS;
  imbib-iOS stays on `PublicationListView` deliberately. Building
  `AnyRecordListWrapper`'s iOS twin instead would have meant rendering every row
  as a `MailStyleRow` (its `RecordViewerRegistry` is empty on iOS by
  construction), i.e. replacing imprint's manuscript row with mail chrome — a
  product change wearing a de-duplication hat. See "The shared iOS list host"
  above for what each app parameterizes and for the imbib convergence follow-up.

  **FIVE pre-existing breaks were in the way, all found by being the first person
  to build and run impart's targets** (there is NO `impart-*.yml` CI workflow —
  impart is the one app with no Swift CI at all, which is why none of these had
  surfaced). Four are fixed; the fifth is macOS and out of Stage 5c's scope:
  1. `MessageManagerCore` did not COMPILE for iOS, though `impart-iOS` had listed
     it as a dependency for months: `DirectoryArtifact` used the macOS-only
     `.withSecurityScope` bookmark options unconditionally, and
     `ArchiveExporter`/`ArchiveImporter` shell out to `/usr/bin/zip`/`unzip`
     through `Process`. Now `#if` islands plus `ArchivePlatformError` (throwing
     beats returning an un-extracted URL that fails later as a missing manifest).
  2. The project-wide `PRODUCT_NAME: impart` made `impart-iOS`, its share
     extension and `impart-iOSTests` all emit `impart.swiftmodule` into one
     products directory — four "Multiple commands produce …" errors before any
     compile. Fixed with `PRODUCT_MODULE_NAME` overrides (`impart-Widgets` and
     `impartTests` already carried the same override on macOS).
  3. `impart-ShareExtension`'s generated Info.plist had **no `NSExtension`
     dictionary**, so `simctl install` failed the WHOLE app with "Failed to create
     app extension placeholder". The keys had to go in `project.yml`'s
     `info.properties` — an `info:` block means XcodeGen GENERATES that plist, so
     hand edits to the file are overwritten, which is presumably how it was lost.
  4. `impart-iOSTests` had no `TEST_HOST` override, so `xcodebuild test` failed
     with "Could not find test host" (same cause as 2 — the product is
     `impart.app/impart`, not `impart-iOS.app/impart-iOS`).
  5. **NOT FIXED — impart macOS traps on launch.** `ImpartApp.chassisRoot` applies
     `.environment(appState)` BEFORE `.modifier(MailChassisHost())`, so the
     modifier is an ANCESTOR of the injection and its `@Environment(AppState.self)`
     is unresolved: `MailChassisHost.body`'s first line reads it and hits
     "Fatal error: No Observable object of type AppState found". `xcodebuild build`
     is green (this is a runtime trap), and `impartTests` cannot run because it
     hosts the app. Introduced with `MailChassisHost` in Stage 4c and invisible
     because impart has no CI and macOS apps are not launched during these passes.
     The fix is one line — move `.environment(appState)` after the modifier — in
     `apps/impart/macOS/ImpartApp.swift`, which Stage 5c was scoped out of.

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
  **CLOSED by C2 (2026-07-30):** publication collections no longer "stay on the
  legacy path". `folderNode(_:)` resolves `.libraryCollection`, and the kernel
  grew the three axes that were missing — an optional owning-CONTAINER
  (`container_field`, giving `list_tree_in` / `create_in` / `reparent_in` and
  `CollectionRow.container_id`), a payload-sourced per-row `is_smart`, and a
  capability-side `CollectionTier` table. The fourth surveyed axis,
  "library-ensuring membership", was a PHANTOM: `ImbibStore::add_to_collection`
  is `AddReference(Contains)` and nothing else, and the claim came from a Swift
  call-site comment. The fifth (`PublicationSource` multi-select unions) stays
  app-side, as judged. Reduced remainder: creation (undo action name), the node
  READS, and the inbox/exploration tiers — all three enumerated in ADR-0022's
  C2 section. Known
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
unfixed. It is a **ratchet**: it may shrink as splits are fixed, never grow.
Adding an entry requires editing a file called `knownDivergences` and tripping
the budget assertion — the point is that making a new mismatch legal should be
conspicuous.

**It is now empty, and the budget is 0** (WP C4). The three entries it held —
three live spellings of `task`, three of `agent-run`, and the dead
`impress/operation` registration — were the ones deliberately deferred because
resolving them touches live scheduling and rows in user databases. What C4 did:

- **`task@1.0.0` / `agent-run@1.0.0` won.** They are what
  `sqlite_store.ready_tasks` selects (the only spelling with a live queue behind
  it, so nothing scheduled today stopped being scheduled) and what the kernel,
  the descriptors, the sidebar counts and `ImpelStoreAdapter` already used.
  `impel/task` / `impel/agent-run` are deleted; the bare forms are unregistered;
  the two schema definitions of each kind collapsed into one, in
  `impress-core/src/schemas/task.rs`, with the union of both writers' fields.
- **The bug this closed was live in two directions.** impel's Swift
  `SharedTaskBridge` wrote `impel/task`, so the mirrored counsel history was
  invisible to the scheduler *and* to impel's own window
  (`ImpelStoreAdapter.fetchThreads` queries `task@1.0.0`) *and* to imbib's
  Agents section. Meanwhile no registry held the id the kernel wrote, so
  `SchemaRegistry::validate` was a no-op for every task impel ever created.
- **Existing rows** are converged by `impress_core::task_schema_migration` —
  flagged OFF in `store_metadata` (`tasks.canonical-spelling`), dry-run first,
  reversible from a changed-id ledger, payloads and timestamps untouched. Same
  gating shape as G7's `collections.unified`.
- **`ready_tasks` gained a `task_kind` clause** so the convergence cannot turn
  impel's mirror rows into work the impress scheduler acquires and then fails.
  See its doc comment; the burst analysis is in the migration module's.

`impress/operation` is gone: `crates/impress-core/src/schemas/operation.rs`
registered an id nothing has ever written or read. `core/operation` — what
`sqlite_store` actually writes — stays canonical.
