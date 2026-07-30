# ADR-0022: Collection Kernel and impress Groundwork

**Status:** Accepted
**Date:** 2026-07-27
**Depends on:** ADR-0001 (unified items), ADR-0018 (thin-twin chassis), ADR-0021 (record-kind descriptors)

## Context

After the GUI-unification campaign (ADR-0021), all five apps run one
descriptor-driven chassis over the unified store, and `impress-mcp` fuses the
`#[impress_service]` crates into a single MCP server. The eventual goal is a
sixth app, **impress**, that shows *everything* in the store: its collections
and subcollections can host any and all record types, it includes all viewers
and renderers, and it switches the right pane based on the selected record's
kind. An expert user could live in impress alone.

We are deliberately **not** building the impress app yet — impart, impel,
implore, and implement (and their renderers/workflows) come first. This ADR
records the groundwork that makes impress cheap later, and pays for itself
now.

What blocks impress today:

1. **Collections are four parallel, schema-specific implementations.**
   `imbib/collection` (payload `parent_id`, `Contains` membership),
   `manuscript-collection` (payload `parent_collection_ref`, lowercase-string
   matched), `figure-collection`, and `mail-folder` (IMAP mirror, `HasParent`)
   diverge in field names, membership mechanics, and available operations.
   Rename is schema-guarded, reparent/reorder happen Swift-side via raw
   `updateField`. A mixed-kind collection is impossible by construction.
2. **Sidebar folder logic is N near-copies** in `ImbibSidebarViewModel` —
   each record kind re-implements the folder pattern (capabilities, menus,
   rename, delete, reparent, reorder, drops).
3. **Viewer routing is switch-based.** `SectionContentView` dispatches on
   per-kind route enums; detail panes are not registry-resolved; there is no
   heterogeneous list-row type, so no surface can show mixed kinds.
4. **The MCP surface lags the GUI surface.** Collection and triage verbs the
   GUIs perform have no Rust service twin, so agents cannot perform them.

## Decisions

### D1 — One generic collection kernel in Rust

New schema **`collection@1.0.0`**: payload `kind_scope` (a record-kind string
such as `"publication"`, `"manuscript"`, …, or `"any"`), payload `parent_id`
(the canonical tree field — never `item.parent`, which is the owning library;
see the c902a22f postmortem invariant), `sort_order`, `is_smart` (semantics
deferred; no predicate language yet). Membership is uniformly a `Contains`
edge. A **`CollectionOps`** service trait (`#[impress_service]`) owns the
whole verb set — `tree`, `create`, `rename`, `reparent` (cycle check in Rust,
not Swift), `reorder`, `delete`, `add_members`, `remove_members`,
`member_counts` — so FFI, CLI, and MCP tools fall out of the macro. Today's
per-kind hierarchies are `kind_scope: "<kind>"`; the impress mixed collection
is the same code with `kind_scope: "any"`.

### D2 — Unify the API first, migrate data second

`CollectionOps` initially **fronts the existing schemas**
(`imbib/collection`, `manuscript-collection`, `figure-collection`) through
one interface — no data migration, immediate deletion of divergent code
paths. Schema convergence (rewriting rows to `collection@1.0.0`) is a
separate, feature-flagged work package with shadow-write and rollback, run
only after the unified API has been the sole code path for a while.

**Mail exception:** IMAP folders stay `mail-folder` — they mirror server
structure and belong to mail's sync protocol (ADR-0021 sync-exclusion
rationale). User-organized *message collections* are ordinary generic
collections; the sidebar shows both (Folders vs. Collections).

### D3 — One sidebar folder pattern

`RecordKindDescriptor` gains a **`CollectionCapability`** (can-organize,
drag UTType, root-section binding). The per-kind folder blocks in
`ImbibSidebarViewModel` collapse into a single capability-driven
implementation over `CollectionOps`. Strangler refactor, one kind at a time,
gated by the capability matrix and per-kind parity tests; imbib stays
pixel-identical.

### D4 — Registry-resolved viewers

A **`RecordViewerRegistry`** maps `RecordKindID` → detail-pane and list-row
factories. Factories live in the registry, **not** the descriptor —
descriptors stay `Sendable` data (ADR-0021 D3 discipline). `SectionContentView`
resolves panes from the registry instead of switching on per-kind route
enums. Companion types: **`KindTaggedRow`** (id + kind + `MailStyleItem`
conformance) and **`AnyRecordListWrapper`**, which renders a heterogeneous
row list and swaps the detail pane per selection — the impress interaction,
built now.

### D5 — MCP surface = chassis capability surface

Every GUI verb gets a Rust service twin: `CollectionOps` (D1), a generic
**`TriageOps`** (star/flag/tag/dismiss/archive/status over any item),
generic query/get with store-browse MCP resources, and render/export tools.
The capability matrix gains an **MCP column**; a parity test asserts every
capability marked automatable has a registered tool. Only service-backed ops
are exposed (the Rust-first rule).

### D6 — Grouped global search is the first mixed-kind surface

`items_fts` already indexes every kind. A `search_all(query)` service
returns kind-bucketed results; the chassis search surface renders
`KindTaggedRow`s. Ships user value now and proves `AnyRecordListWrapper` +
registry viewer switching before impress exists.

### D7 — Renderer seams, not extraction

impress must link all renderers (Typst, PDF, MarkdownUI, figure CAS
artifacts, mail WebKit, transcripts); siblings want few. Keep the PMC
monolith (ADR-0021 extraction trigger unchanged) but put heavy renderers
behind injected `PreviewProvider` protocols and keep recording per-PR binary
sizes, so the future impress target is a link-list decision, not a refactor.

### D8 — Cross-kind relations groundwork

A `related_items(id)` service walks edges (`Contains`, `InResponseTo`,
`ProducedBy`, `Cites`) and one generic **Related** info-pane section renders
it for every kind — papers cited by a manuscript, messages that produced a
task, figures embedded in a draft.

### D9 — impress is proven, not shipped

Define the `impress` `AppShellConfiguration` preset (all kinds, every
section, all surfaces) with parity tests, plus a store-level
integration test doing a mixed-kind collection round-trip through
`CollectionOps` with `kind_scope: "any"`. No app target until the sibling
apps and their renderers mature. When ready, the app is a ~120-line
`ImpressChassisRoot` against seams tested for months.

*Implemented (G8, 2026-07-27) with one change: `visibleSections` is the
EXPLICIT set of every section, not `nil`. `nil` ("no restriction") was retired
suite-wide when imbib went publications-only — opting in by omission is the
mechanism that rode the Manuscripts section into imbib, and the shell that
wants everything is exactly the shell that must still say so, section by
section. The parity test then fails when the section enum grows, until someone
decides.*

## Work packages

| WP | Content | Gate |
|----|---------|------|
| G0 | `collection@1.0.0` schema + `CollectionOps` over existing schemas + FFI | cargo green; Tier-A `store.collections` |
| G1 | MCP/CLI exposure of CollectionOps + TriageOps; matrix MCP column + parity test | inventory smoke + tool tests |
| G2 | `CollectionCapability` + single sidebar folder pattern (strangler) | pixel regression, matrix, 5-app builds |
| G3 | `RecordViewerRegistry`, registry-resolved routing, `KindTaggedRow`, `AnyRecordListWrapper` | zero-diff parity for existing kinds |
| G4 | Grouped global search: service + MCP tool + chassis surface | Tier-B search capability; ⌘⇧F |
| G5 | `related_items` service + generic Related section | Tier-A capability + matrix rows |
| G6 | Query/get + store-browse MCP resources; render/export tools | MCP parity test extended |
| G7 | Collection data migration to `collection@1.0.0` (flagged, shadow-write, rollback drill) | count parity per kind; imbib tree regression |
| G8 | `impress` preset + mixed-kind round-trip test; re-run the "add a kind" litmus incl. collection + MCP path | litmus: zero chassis edits |

G0/G1 are additive Rust and can run alongside sibling-app development.
G2/G3 touch the chassis and are coordinated with that work. G7 is
deliberately last.

## Risks

- **G2 touches the fragile sidebar VM** — strangler order, per-kind parity
  tests, never a big-bang rewrite.
- **G7 rewrites the imbib tree users live in** — flag, shadow-write,
  deterministic IDs (idempotent re-runs), rollback drill.
- **Descriptor bloat** — factories stay in the registry; descriptors stay data.
- **MCP creep** — only service-backed ops; the matrix column keeps the
  surface deliberate.
- **Smart collections** — `is_smart` is schema'd but inert; the predicate
  language is a separate future ADR.

## Status (2026-07-27)

**All nine work packages landed.** G0–G6 shipped in wave 1 (2026-07-27,
`25a7f714`); G7 (collection data migration, flagged) and G8 (`impress` preset,
mixed-kind gate test, litmus re-run) landed the same day.

| WP | Landed | Where it lives |
|----|--------|----------------|
| G0 | 2026-07-27 | `impress-core/src/collection_ops.rs` (+ `schemas/collection.rs`), FFI in `impress-store-ffi` / `imbib-core` |
| G1 | 2026-07-27 | `impress-store-service` (collection + triage services) → MCP/CLI/impel tools; matrix "MCP surface" section |
| G2 | 2026-07-27 | capability-driven folder block in `ImbibSidebarViewModel` over `CollectionStoreAdapter`; `CollectionCapability`; `RecordDragSession` |
| G3 | 2026-07-27 | `RecordViewerRegistry`, `KindTaggedRow`, `AnyRecordListWrapper` |
| G4 | 2026-07-27 | `search_all` + `StoreSearchSurface` (chassis-BUILTIN surface, every preset) |
| G5 | 2026-07-27 | `related_ops.rs` + `RelatedItemsSection` |
| G6 | 2026-07-27 | `store-query-service` get/list + `impress://store/{schemas,collections}` resources |
| G7 | 2026-07-27 | collection migration to `collection@1.0.0` — **feature-flagged, default OFF** |
| G8 | 2026-07-27 | `AppShellConfiguration.impress` + `testImpress*` parity tests; `impress_gate_mixed_kind_collection_round_trip`; litmus re-run in ADR-0021 |

### Two deliberate scope changes

1. **imbib was purified to publications only** (user direction, 2026-07-27),
   which **supersedes the imbib-facing parts of D3**. D3 assumed one sidebar
   folder pattern serving every kind *in imbib*; imbib now surfaces an
   EXPLICIT publications-only `visibleSections` (manuscripts → imprint,
   figures → implore, mail → impart, tasks/runs → impel), so the generic
   folder block is exercised by the sibling apps rather than by imbib. The
   pattern itself landed as designed and none of the chassis code was deleted —
   only imbib's surfacing of it. `nil` visibleSections is retired suite-wide as
   a consequence: opting in by omission is what rode the Manuscripts section
   into imbib in the first place. One casualty: the Submissions inbox lost its
   home (see the register below).

2. **The migration flag ships OFF.** G7's shadow-write and rollback drill are
   green, but the Swift legacy-caller audit G7 surfaced is not finished —
   `ImbibSidebarViewModel.migratedFolderBindings` still names which kinds route
   through the kernel adapter, and publication collections stay on the legacy
   path. Flipping the flag before every Swift caller reads through
   `CollectionOps` would give two writers to one tree. Turning it on is its
   own change, with its own gate: count parity per kind plus the imbib tree
   regression named in the G7 row.
   *(Superseded in part by C2 below: publication collections' WRITES now run on
   the kernel, and the audit is finished. The flag still ships OFF, for a
   smaller and now fully enumerated reason.)*

## C2 — the collection kernel completed (2026-07-30)

### The five axes, and where each landed

The wave-3 routing survey found five reasons publication collections could not
join the generic folder path. Four were real and are now expressible; one was
not real.

| # | Axis | Landed in | Rationale |
|---|---|---|---|
| 1 | **Owning container (library)** | **KERNEL** — `CollectionSchemaBinding.container_field: Option<ContainerField>`, `list_tree_in` / `create_in` / `reparent_in`, `CollectionRow.container_id`; capability half is `CollectionCapability.container` | The container is a STORE fact (the envelope `item.parent`), so the store layer must own it. Putting it in the kernel is also what makes the cross-library move ATOMIC: what was two hand-ordered Swift writes (`updateField("parent_id")` + `reparentItem`) is one `store.update` with an exact inverse. Optional because only imbib is per-container — D1's two-axis pattern (`kind_scope_field`) is the precedent: a binding that declines the axis behaves exactly as before |
| 2 | **Per-row read-only predicate** | **BOTH** — kernel reports (`smart_field` → `CollectionRow.is_smart`), capability decides (`CollectionOrganizePolicy.unlessSmart`, `allowsOrganize(isSmart:tier:)`) | The FACT is in the payload, so the kernel reads it; the POLICY ("smart ⇒ Delete only") is presentation, so it stays with the descriptor. Splitting it this way is what let the smart guard in `handlePublicationDrop` stop being a second `listCollections` scan. The kernel deliberately does not WRITE the flag — there is still no predicate language (risk register, unchanged) |
| 3 | **Library-ensuring membership** | **NOWHERE — the axis is a phantom** | `ImbibStore::add_to_collection` does NOT ensure library membership. It is thirty lines of `AddReference(Contains)` and nothing else; the claim came from a Swift call-site COMMENT ("also ensures they're in the library"), not from the code. `add_members` was therefore already faithful, and no hook was added: a seam nothing needs is a seam that rots. The stale comment is gone |
| 4 | **Tier notion** | **CAPABILITY** — `CollectionTier` table (`CollectionCapability.tiers`), `CollectionTierID` | A tier is `(binding, container)` plus presentation. The kernel already expresses the whole `(binding, container)` half via axis 1, so a kernel-side tier type would have been a second spelling of it. What actually varies between imbib's three tiers is affordances — Exploration collections cannot be renamed or nested — and those are descriptor data. The table is pinned against the frozen matrix rows by `testPublicationTiersMatchTheFrozenMatrixRows`, so it is a checklist that fails, not a comment |
| 5 | **`PublicationSource.collection(id)` multi-select unions** | **APP-SIDE — stays, as judged** | This is content ROUTING, not collection structure. `.libraryCollection` maps to `.collection(id)`, a `PublicationSource` feeding the publication-only multi-select union; `.recordFolder` maps to `.record(.folder(...))`. Converging the route means rewriting publication content routing, which is `UnifiedPublicationListWrapper`'s remit and outside `RecordRoute`'s. The wave-3 judgement was correct |

### What converged, and what did not

The publication node case **stays** `.libraryCollection` — it cannot become
`.recordFolder` without the routing rewrite in axis 5. What converged is every
VERB: `folderNode(_:)` now resolves `.libraryCollection` too, so the generic
sites serve publication collections with no arm of their own.

| Site | Converged | Note |
|---|---|---|
| `handleRename` | ✅ | Kernel `rename`. Event `(false, [id], .otherField)` and undo name "Edit name" are byte-identical to the `updateField` it replaces |
| `handleReorder` (`.library` / `.libraryCollection` parents) | ✅ | Two identical arms became one `reorderFolders`; same per-sibling write, event and "Edit sort_order" undo |
| `handleReparent` | ✅ | `reparent_in` with the container. Cycle check moved to Rust. **Gained a complete Undo** ("Move Folder"): the legacy path registered only the `updateField` half, so undoing a cross-library move left the collection in the wrong library |
| Context menu | ✅ | `buildCollectionContextMenu` DELETED; one `buildFolderContextMenu` for every binding. Labels frozen via `containerNoun: "Collection"` + `deleteTitleOverride: "Delete"` |
| Delete (menu + ⌫) | ✅ | Kernel `delete`; undo name "Delete" unchanged, and `restore` now puts back membership and child collections the old item-snapshot undo dropped |
| Smart-collection guard (drop) | ✅ | Kernel row's `is_smart` instead of a `listCollections` scan |
| Membership (drop) | ✅ | Kernel `addMembers`; same "Add to Collection" undo, and idempotent (undo cannot unfile a pre-existing member) |
| **Creation** | ❌ | Legacy `createCollection` retained. The kernel's create undo is `StoreKernelUndoAction.createCollection` = **"New Folder"**; imbib's is **"Create Collection"**. Converging would silently relabel a live Edit-menu entry. Needs a capability-declared create action name — a UX decision, not a refactor side effect |
| **Node reads** (`libraryCollectionChildren`, counts) | ❌ | Still `store.listCollections(libraryId:)`. This is the flip blocker; see below |
| **Inbox / Exploration tiers** | ❌ | Declared in the tier table, not yet routed. Their nodes are still built from `listCollections`, so moving the WRITES alone would give one tree two writers. They convert with their reads |
| `canAcceptDrop` `.libraryCollection` arms | ❌ | Deliberate. The frozen drag FEEDBACK omits the ancestor check the generic path performs; converging would refuse drags that today are allowed (and refused later, at the write). A behaviour change, so it is a decision, not a cleanup |

One guard is load-bearing and worth naming: `folderCapability(ofSection:)`
gained a third gate, `capability.container == nil`. `.inbox`, `.libraries` and
`.exploration` are all `.primary` sections bound to `.publication`, so the
moment the publication kind declared a capability those three headers would
otherwise have started hosting "New Collection", accepting collection drops as
"move to root", and reordering through `reorderFolders`. A container-scoped
kind has no section-level root — its root is the container — which is exactly
what the axis lets the code say.

### Flip-readiness verdict for `collections.unified` (G7)

**NOT READY. The flag stays OFF. Do not flip it without an explicit order.**

Re-counted on today's tree. The original gate named "44 Swift `list_collections`
call sites + FigureStoreReader decoding migrated folders as figures". Both
numbers have moved, and the second item is closed.

**Blocking is decided by the RUST reader, not the Swift site.** A Swift caller
is blind precisely when it reaches an imbib-core export that queries a legacy
`schema_ref` literal. There are nine such exports and three benign ones:

| imbib-core export | Post-flip behaviour | Verdict |
|---|---|---|
| `list_collections(library_id)` | returns EMPTY (`schema_ref = "imbib/collection"`) | **BLOCKING** — the big one; ~30 Swift sites reach it |
| `list_collections_for_publication` | EMPTY | **BLOCKING** — `FirstSyncMerge`, `PublicationListMutations` |
| `rename_collection` | `NotFound` (schema guard precedes the write) | **BLOCKING** — iOS inline rename |
| `create_collection` | writes an `imbib/collection` row the kernel cannot see | **BLOCKING** — the two-writers case |
| `get_publication_detail` | `.collections` EMPTY | **BLOCKING** — detail pane, exporters |
| `delete_library_undoable` | orphans the library's collections | **BLOCKING** |
| `count_collections` | 0 | **BLOCKING** (cosmetic) |
| `list_manuscript_collections` | EMPTY | **BLOCKING in imbib only** — `manuscriptFolderNodes`. imprint is SAFE: `ManuscriptStoreAdapter.listCollections()` already reads `collectionKernel.tree`. And imbib no longer surfaces the Manuscripts section, so this site is dead code there |
| `get_manuscript_detail` | collections EMPTY | **BLOCKING** (imprint detail) |
| `add_to_collection` / `remove_from_collection` | schema-agnostic (`Contains` edges) | ✅ benign |
| `delete_collection` | schema-agnostic (`store.delete(uuid)`) | ✅ benign |

Per-site Swift audit, grouped by the export reached:

| Swift site group | Count | Status |
|---|---|---|
| `ImbibSidebarViewModel` node building — `libraryCollectionChildren`, `collectionSubchildren`, `librariesChildren`, inbox ×2, exploration ×2, `findCollectionModel`, `findLibraryIDForCollection`, `explorationHasContent` | 11 | **BLOCKING** — the imbib tree itself |
| `ImbibSidebarViewModel` verb sites — reparent ancestor walk, `buildCollectionContextMenu`, smart-drop guard | 3 | ✅ **MIGRATED by C2** (two deleted, one on the kernel) |
| `SectionContentView` ×4, `LibraryManager` ×2, `CollectionViewModel` ×2, `GlobalSearchViewModel`, `GlobalSearchPaletteView`, `FullTextSearchService`, `PublicationScope`, `DefaultLibrarySetManager` | 13 | **BLOCKING** |
| Exporters — `EverythingExporter` ×2, `MboxExporter` | 3 | **BLOCKING** (silently empty archives) |
| Automation — `AutomationService` ×2, `HTTPAutomationRouter`, `CollectionEntity` ×5, `ImbibBridge` | 9 | **BLOCKING** |
| iOS — `IOSContentView`, `ImbibSidebarBindings` ×3, `IOSUnifiedPublicationListWrapper` | 5 | **BLOCKING** (C1's territory) |
| imprint — `ManuscriptStoreAdapter.listCollections` and its iOS callers | 4 | ✅ **MIGRATED** (already on `collectionKernel.tree`) |
| Adapter/protocol/mock definitions — `RustStoreAdapter` ×2, `ImbibImpressStore`, `PublicationStoreProtocol`, `MockPublicationStore` | 5 | ✅ benign (declarations and a test double) |

**FigureStoreReader is CLOSED, and was never the hazard it was recorded as.**
A migrated figure folder's `schema_ref` becomes `collection`, which
`RecordKindRegistry.kind(forStoreSchemaRef:)` maps to nothing — base-name
equality on both sides, never `hasPrefix` (`SchemaRefKindLookup`). It cannot be
decoded as a figure. The residual issue is the ordinary one: `fetchFolders()`
queries `schema_ref = "figure-collection"` and would return empty, which is
implore's surface and belongs with implore's adapter work.

**The single fix that unblocks nearly all of it — DONE (F1, 2026-07-31).**
`list_tree_in` is a drop-in for `list_collections(library_id)`: same rows, same
`sort_order` ordering, and it filters on the ENVELOPE, which the migration
never touches — proved by
`the_container_axis_is_invariant_across_the_unified_flip`. F1 additionally put
the MEMBER COUNT on the kernel row (`CollectionRow.member_count` /
`SharedCollectionRow.memberCount` — the legacy export's `publication_count` is
the outgoing `Contains`-edge count, which the kernel now reports identically;
the invariance test pins count parity across the flip), because without it the
"drop-in" would have zeroed every sidebar badge.
`RustStoreAdapter.listCollections(libraryId:)` and
`listCollectionsBackground(libraryId:)` now read kernel-first through a
dedicated `SharedStore` handle on the same database file (WAL), converting
every consumer in the table above in one move.
`CollectionKernelReadParityTests` proves the equivalence on the REAL write
path (imbib's own `createLibrary`/`createCollection`/`importBibtex`/
`addToCollection`). Honest caveat: in-memory test stores cannot share a second
handle (two opens = two databases), so they fall back to the legacy path —
which is also the pre-flip behaviour those tests encode.

**The remaining flip gate** is the bounded list of four exports needing their
own marker-aware pass: `list_collections_for_publication`,
`rename_collection`, `create_collection`, `get_publication_detail` — plus
re-running this table's per-site audit after those land.

### Follow-up register

Work this ADR deliberately did not do, recorded so it stops being
rediscovered:

- **Render/export wiring (a WP of its own).** D5 lists render/export tools;
  they are enumerated but not usable headlessly. `imprint-core` has a real
  headless Typst compiler behind `#[cfg(feature = "typst-render")]`; what is
  missing is a passthrough feature in `imprint-service`, replacing the canned
  error in `handlers.rs`, writing bytes to disk so `render_pdf_page` has a
  path, and adding the app-dependent services to `reachability::APP_GATED` so
  `_list-documents` stops answering `[]` while imprint is closed. Evidence
  table: docs/chassis-capability-matrix.md, "Render / export — ❌ blocked".
- **A home for the Submissions inbox.** Unreachable in imbib since the
  purification; `AppShellConfiguration.impress` declares it as the designated
  future home, but impress ships no target. Adopting it in imprint is the
  interim option.
- **UTType Info.plist declarations.** `UTType(exportedAs:)` is used for
  `com.imbib.manuscript-id` and `com.impress.figure-id`
  (`MailStylePublicationRow.swift`), but no app declares them in
  `UTExportedTypeDeclarations`. Drag works because the pasteboard round-trips
  the raw identifier; the declaration is still owed, and a third kind's drag
  type should not be added without it.
  **RESOLVED 2026-07-27:** both types are now declared `UTExportedTypeDeclarations`
  (conforming to `public.data`) in the macOS `info.properties` of all five
  `project.yml` specs — exported, not imported, in every host, because the
  chassis constructs them with `UTType(exportedAs:)` and an imported
  declaration still faults ("expected to be exported … but it was imported
  instead"); the two `com.apple.runtime-issues` launch faults are gone.
- **impart compose + mark-read from the chassis.** Stage-2-A2: composing and
  read-state sync are IMAP-owned and stay in impart's classic window; the
  chassis mail list is read-only in that respect.
- **tree-sitter-markdown grammar.** Not vendored, so `ImpressSyntaxHighlight`
  renders md/txt unhighlighted.
- **Navigation enums are not additive.** The ADR-0021 litmus re-run (WP G8)
  found that adding a kind still costs cases in `SidebarSectionType`,
  `ImbibSidebarNodeType`, `ImbibContentRoute` and `ImbibTab`. Behaviour —
  tabs, triage, menus, folders, drag, search, related, MCP — is additive;
  navigation is not. A registry-driven route type would close it.
- **Mixed-kind Flagged/Dismissed.** `sectionBindings` maps a section to ONE
  `RecordKindID`, so the impress preset binds both to `.publication`. The real
  behaviour wants `AnyRecordListWrapper` over a cross-kind query — a chassis
  change, not a preset edit.
- **impress keychain access.** The impress preset permits `.search`, so
  `TabContentView`'s ADS/SciX credential read would run in it; those keychain
  items are ACL'd to imbib's code signature. Before an impress target exists,
  either it ships with imbib's keychain access group or the read moves behind
  a reachability check.
