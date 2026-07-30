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
   *(Superseded outright by F3, 2026-07-30: the enumerated reason is gone and the
   verdict is READY. The flag still ships OFF as a DEFAULT — it is a deliberate,
   human-invoked data migration, not something an app turns on at launch — but
   there is no longer a code reason not to turn it on. See the F3 verdict and
   the flip procedure at the end of this document.)*

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

*Superseded by the F2 re-run below (2026-07-30). Kept because it is the audit
the F2 work was scoped against, and because the per-site table it established is
what the re-run walks.*

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
*Those four landed in F2 (2026-07-30). The re-run below found the estimate
optimistic: "bounded list of four" was true of imbib-core's publication-collection
exports and not of the flip.*

## F2 — the four exports, and the flip-readiness re-run (2026-07-30)

F1 converted the big read. F2 was scoped to the remainder the F1 note named —
`list_collections_for_publication`, `rename_collection`, `create_collection`,
`get_publication_detail` — and all four now resolve the `collections.unified`
marker. The re-run that followed is the part worth reading: it found the gate is
wider than those four, in places the previous audit did not look.

### What the kernel gained

Four additions, all in `impress-core/src/collection_ops.rs`. **No FFI record or
signature changed** — every addition is either a new Rust-only function or a
method on an existing type, and `create_in` keeps its exact arity for
`impress-store-ffi::collection_create_in`.

The xcframework was rebuilt anyway, because the Swift gates must exercise the
Rust that actually shipped. The regenerated `imbib_core.swift` does differ, and
the diff is worth knowing about: UniFFI propagates Rust `///` docs into the
generated Swift **and folds them into its per-method contract checksum**, so
three checksums moved (`create_collection`, `list_collections_for_publication`,
`rename_collection`) purely because their doc comments grew. Not a signature
change — but it does mean the committed bindings file changes whenever an
exported method's doc comment does, and the `.swift` and the binary must be
regenerated together or the runtime contract check fails.

| addition | why it exists |
|---|---|
| `collections_containing(store, binding, member) -> Vec<CollectionRow>` | the reverse-membership read — the inverse of `list_members`. Answers BOTH mechanics: `Contains` bindings run the reverse-edge predicate, envelope bindings (figure folders) report the member's own `item.parent` when that parent is a bound collection, so a caller need not know which its binding uses |
| `collections_containing_ids(...) -> Vec<String>` | the same query, id-only, sharing one private `containing_items` helper. Not a second copy: the difference is `include_references`, and it is load-bearing (below) |
| `create_in_with_payload(..., extra: &[(&str, Value)])` | one insert that writes the kernel's structural shape PLUS payload the kernel does not interpret. `create_in` is this with `&[]` |
| `ResolvedBinding::matches(&Item)` / `::scope_predicates()` | the public halves of the kernel's internal `is_bound` / `scope_predicates`, for a caller that owns a schema GUARD (rather than a query) and must not fork `resolve()` |

### Per export: mechanism, and why

**1. `list_collections_for_publication` — option (b), a new kernel verb.**
Option (a) (marker-resolving the schema literal in place) would have been
correct and two lines shorter. It was rejected because the identical predicate
is needed *twice more on this tree*: `get_publication_detail` runs it for the
same binding, and `get_manuscript_detail` runs it for `MANUSCRIPT_COLLECTION`.
Marker-resolving each site is how three copies of a predicate get three
different sort orders. One verb, parameterized by binding, is also what makes
the manuscript and figure fixes a delegation rather than a design.
Return shape unchanged — imbib's own `CollectionRow`, via a new
`kernel_collection_row` reshaper; `publication_count` is the kernel row's
`member_count`, which F1 already established is the same number (outgoing
`Contains` edges).

**2. `rename_collection` — the guard, not the write.**
`item.schema == "imbib/collection"` became `binding.matches(&item)` against the
resolved binding. The write stays on `SqliteItemStore::update_with_undo`. The
guard is also why this export failed LOUDLY (`NotFound`) where the reads failed
silently: it runs before the write.

*A correction to the audit's undo premise.* The brief assumed this export's
op-log undo was feeding imbib's ⌘Z and had to be preserved. It is not: the
`UndoInfo` is discarded at the call site in `store_api.rs`, and
`RustStoreAdapter.renameCollection` registers no undo either — **this rename
ships with no ⌘Z entry at all.** The write still stays put, for the smaller and
truer reason: `update_with_undo` writes the operation-log rows
`recent_undo_groups` (the history panel) and `undo_operation` read, and
delegating would silently change what the history shows for a rename. That is a
behaviour change, so it is a decision for its own pass, not a side effect of a
marker fix.

*And a correction to "iOS inline rename".* Right about the platform, wrong about
the affordance — macOS converged on `CollectionStoreAdapter.rename` in C2 and
never touches this export. The two surviving live callers are both iOS modal
sheets: `ImbibSidebarBindings.swift:579` (the shared record-sidebar
`renameFolder` closure) and `IOSSidebarHost.swift:805` (`CollectionRenameSheet`).
Live, so deprecating it was rejected.

**3. `create_collection` — the write delegated, the undo untouched.**
The write is now `create_in_with_payload`, so there is exactly one piece of code
in the suite that knows what a collection row looks like. `is_smart` /
`smart_query` ride along as `extra` — they are imbib's, not the kernel's (which
still has no predicate language) — written in the SAME insert, so a create stays
one operation in the op log.

*The undo question, resolved by observation.* imbib's creation undo is **not**
op-log based and never was: this export returns a `CollectionRow`, not an
`UndoInfo`. `RustStoreAdapter.createCollection` registers a Swift closure with
`UndoCoordinator` under the Edit-menu string **"Create Collection"**, whose
inverse is `deleteItem(id:)` — schema-agnostic, so it inverts a post-flip row
exactly as it inverts a legacy one. `StoreKernelUndoAction.createCollection` =
**"New Folder"** is imprint's string for its own hand-rolled kernel create
(`StoreKernelScope.swift` says so in as many words: *"imbib's sidebar has never
registered a create inverse; imprint has"*). C2 recorded these as a divergence
to converge; the honest resolution is that they are **two hosts' labels, not two
labels for one action**, and F2 moves only the WRITE — so no Edit-menu text
changes, and C2's decision to leave creation unconverged stands intact.

*One deliberate pre-flip shape change.* The row now always carries
`sort_order: 0` where the legacy writer omitted the key. Every reader already
defaulted a missing `sort_order` to 0 (`item_to_collection_row`,
`collection_ops::row_of`) and the migration writes `0` for exactly these rows,
so this makes a freshly created collection identical to its own migrated form on
BOTH sides of the marker instead of only one. The single observable nuance:
`ORDER BY json_extract(payload,'$.sort_order')` sorts SQL `NULL` before `0`, so
in a tree whose siblings have been hand-reordered a brand-new collection now
lands at the first explicit position instead of ahead of it. In an
never-reordered tree (all ties) the order is unchanged.

**4. `get_publication_detail` — the same verb, id projection.**
`collections_containing_ids`. The id projection is not a convenience: the detail
pane opens on every selection change, and the row projection would load every
containing collection's `Contains` edges — thousands of rows for a large
collection — to compute a `member_count` this caller discards. The blind query
it replaces used `include_references: false`; so does this.

### What each fix actually unblocked

Re-counted per export, production sites only (protocol declarations, mocks and
seed/UI-test fixtures excluded):

| export | live production consumers | what a flip would have done |
|---|---|---|
| `list_collections_for_publication` | 2 — `PublicationListMutations.swift:255` (`removeFromAllCollections`), `FirstSyncMerge.swift:129` (**raw `ImbibStore`, bypasses `RustStoreAdapter` entirely**) | "Remove from all collections" becomes a no-op; first-sync merge silently drops every membership it was supposed to reconcile |
| `rename_collection` | 2 — `ImbibSidebarBindings.swift:579`, `IOSSidebarHost.swift:805` (both iOS sheets) | rename throws `NotFound` on iOS |
| `create_collection` | 12 — macOS sidebar ×2, `CollectionViewModel`, `ExplorationService`, `DefaultLibrarySetManager`, `AutomationService`, the HTTP router, iOS ×4, seeding ×2 | **the two-writers case**: every new collection lands under a `schema_ref` the kernel-first sidebar cannot see, so it is created and immediately invisible |
| `get_publication_detail` (`.collections`) | 1 — `EverythingExporter.swift:116`, the `X-Imbib-Collections` MIME header re-read by `EverythingImporter.swift:408-410` | export/import round-trip silently loses collection membership |

Two of the audit's original claims did not survive contact with the tree.
`get_publication_detail`'s `.collections` has exactly **one** real reader — the
detail pane never reads it, `AutomationService.toPaperResultFromDetail` has zero
callers, and `HTTPAutomationRouter.swift:3495`'s live path hardcodes
`collectionIDs: []`. So "detail pane, exporters" was one exporter, and the
damage was archive fidelity, not a visible pane. `FirstSyncMerge` reaching the
raw `ImbibStore` is the more interesting find: it means F1's adapter-level
reroute would not have covered it even if this export had been a tree read.

### Proofs

| proof | where |
|---|---|
| reverse-membership read is byte-identical across the flip — rows, order, per-row member counts, and the id projection | `impress-core/tests/collection_container_axis.rs` `collections_containing_is_invariant_across_the_unified_flip` |
| the same verb answers envelope membership (figure folders), and an unfiled member is in no folder | same file, `collections_containing_answers_envelope_membership_too` |
| **write shape**: create pre-flip → migrate, vs create post-flip — identical row AND identical canonical payload (`name`, `kind_scope`, `sort_order`, `is_smart`), with the one intended difference (rollback provenance) named and pinned to `RollbackReport.native_generic_untouched` | same file, `a_created_collection_is_indistinguishable_from_a_migrated_one` |
| all four exports end-to-end through the shipping API across a real migration on a second WAL handle | `imbib-core/tests/collection_migration_legacy_readers.rs` `the_f2_exports_stay_correct_across_the_flip` |
| write shape through the shipping export, not the kernel function | same file, `create_collection_writes_a_row_a_migration_would_have_produced` |
| the residue still goes blind — asserted on purpose, so the day one is fixed this file is where the assertion flips | same file, `migration_blinds_the_remaining_legacy_readers` |
| Swift: the two reverse-membership projections cannot disagree with each other or with the kernel tree, on imbib's real write path | `CollectionKernelReadParityTests.testReverseMembershipReadsAgreeWithEachOtherAndWithTheKernel` |

`collection_migration_legacy_readers.rs` changed character: it was uniformly "the
legacy readers go blind, and that is why the flag is off". It is now two halves —
a **stays-correct** half for F2's four, and a **still-blind** half for the
residue, with `delete_library_undoable`'s incomplete undo snapshot asserted
explicitly rather than described.

### Three things F2 also closed, because they were inside the four

- **`conversion::collection_to_item`** — export 3's write helper lives in a
  different file, so a `store_api`-only fix would have left the legacy writer
  in place. It now has no production caller at all (tests only) and says so in
  its doc comment.
- **`ImbibImpressStore.listCollections(libraryId:)` — DELETED.** Zero callers,
  and the one door in the suite that bypassed F1's kernel-first reroute by
  reading the raw export. The previous audit filed it under "✅ benign
  (declarations and a test double)"; it was neither. A gateway that is the NEW
  door should not carry a pre-F1 copy of the old one.
- **`RustStoreAdapter`'s kernel-handle open is no longer silent.** Both
  `try? SharedStore.open(...)` sites route through one `openKernelStore(at:)`
  that logs the failure. Today a missing kernel handle only means "slower to
  notice"; post-flip the fallback path returns EMPTY rather than stale, so
  "no kernel handle" and "this library has no collections" would be
  indistinguishable in the UI *and* in the logs.
- **`get_manuscript_detail`** — one line, the same verb with
  `MANUSCRIPT_COLLECTION`. Taken in-lane precisely because it is the payoff of
  choosing a binding-parameterized verb over three marker-resolved queries.

## Flip-readiness verdict, re-run on the F2 tree (2026-07-30)

*Superseded by the F3 verdict below (2026-07-30). Kept because it is the audit
F3 was scoped against, and its residue table is what the final verdict walks.*

**NOT READY. The flag stays OFF.** F2 closed the four exports it was scoped to
and two more besides — but the re-run found the gate is **wider than the four**,
in three places the previous audit did not reach: a Swift *migration runner*, the
*Rust agent surface*, and the *legacy writers*.

#### imbib-core exports

| export | post-flip | verdict |
|---|---|---|
| `list_collections_for_publication` | ✅ correct | **FIXED (F2)** |
| `rename_collection` | ✅ correct | **FIXED (F2)** |
| `create_collection` | ✅ correct, write-shape proven | **FIXED (F2)** |
| `get_publication_detail` (`.collections`) | ✅ correct | **FIXED (F2)** |
| `get_manuscript_detail` (`.collections`) | ✅ correct | **FIXED (F2, in-lane)** |
| `list_collections(library_id)` | EMPTY | **RESIDUE** — every *Swift* consumer is safe (F1 kernel-first; F2 deleted the last bypass), but the export itself is still blind and `imbib-service` reads it |
| `delete_library_undoable` | `child_collection_ids` comes back EMPTY | **BLOCKING — silent data loss.** Delete orphans the collections via `ON DELETE SET NULL`; undo restores the library and never re-parents them. Asserted in `migration_blinds_the_remaining_legacy_readers` |
| `list_manuscript_collections` | EMPTY | **BLOCKING in imprint** — live through the shared chassis `journalChildren`. Dead in imbib (publications-only) |
| `create_manuscript_collection` | writes a legacy-schema row | **BLOCKING (writer)** — the two-writers case, for manuscripts. Check supersession by `CollectionStoreAdapter` first: fix-vs-delete, not fix |
| `count_collections` | 0 | RESIDUE (cosmetic — `/api/status`) |
| `add_to_collection`, `remove_from_collection`, `delete_collection` | schema-agnostic | ✅ benign |

#### Outside imbib-core — where the previous audit did not look

| site | post-flip |
|---|---|
| `ManuscriptMigrationRunner.swift:400-406` | **WORST FAILURE MODE.** The empty read is interpreted as "not migrated yet" and triggers a full Core Data re-migration, **duplicating every folder**. Fires for any user with a legacy `ImprintProjects.sqlite` |
| `imbib-service/src/library_service.rs:647` | the MCP / CLI / impel **agent surface** reads collections blind. F1 protected Swift only — agents would see an empty library |
| `FigureStoreReader.swift:161` `createFolder` (+ blind reads `:92-98`, `:155`) | implore keeps WRITING `figure-collection` rows after the flip, and reads none |
| `ImploreStoreAdapter.swift:330` `fetchFolders` | implore's folder surface empties (already recorded as implore's own work) |

Clean: `imprint-core` and `implore-core` have **zero** legacy-literal hits;
`collection_service.rs:44-48` and `impress-store-ffi:1477-80` are binding ALIAS
tables, not readers; `schemas.rs:88`, `manuscript_collection.rs:17` and
`implore.rs:52` are schema declarations. `ManuscriptStoreAdapter.swift:958`'s
fallback is safe by design.

#### The gate, in the order it should be closed (F3)

1. `ManuscriptMigrationRunner` — guard the re-migration on something other than
   an empty read. Duplicated user data is the only irreversible item here.
2. `delete_library_undoable` / `restore_library` — `list_tree_in` for the
   snapshot; restore re-parents. Silent data loss.
3. The legacy WRITERS: `create_manuscript_collection` (fix or delete),
   `FigureStoreReader.createFolder`.
4. `imbib-service/library_service.rs:647` — the agent surface.
5. `list_manuscript_collections` (imprint) and `ImploreStoreAdapter.fetchFolders`.
6. `count_collections` — cosmetic, last.

#### The flip procedure, for when the gate closes

Recorded now so ordering it later is one sentence, not a research task.

- **Mechanism:** `CollectionService` (`impress-store-service/src/collection_service.rs`)
  exposes it as MCP/CLI verbs: `migration_status` (read-only, always safe),
  `migrate(dry_run:)`, `rollback()`. The marker is `collections.unified = "1"`
  in `store_metadata`; the rewrite and the marker are set in ONE transaction.
- **Dry run:** yes — `migrate(dry_run: true)` writes nothing (not the rows, not
  the flag) and reports the exact counts the real run will report.
- **Idempotent:** a second run rewrites zero rows and says so
  (`skipped_already_generic`).
- **Reversal:** `rollback()` restores every migrated row's original
  `schema_ref` and payload byte-for-byte from the provenance the migration
  froze, and clears the marker. It is a **rewind, not a merge**: edits made to a
  migrated row after the migration are discarded with it. Collections created
  after the flip carry no provenance, are left strictly alone, and are counted
  separately (`native_generic_untouched`) — proved in
  `a_created_collection_is_indistinguishable_from_a_migrated_one`.
- **Order:** `migration_status` → `migrate(dry_run: true)` → compare counts →
  `migrate(dry_run: false)`.

## F3 — the residue, closed at the export (2026-07-30)

F1 converted the big Swift READ. F2 converted four exports. F3 closes the rest,
and it took one strategic decision to make the list short: **fix the EXPORT, not
the consumer.**

`imbib-core` depends on `impress-core`, so `store_api.rs` can delegate straight
to `collection_ops`. F1's reroute lived in `RustStoreAdapter`, which is why the
F2 re-run kept finding new blind consumers *behind* it — the `imbib-service`
agent surface, F1's own legacy fallback, `FirstSyncMerge`'s raw handle. Making
`list_collections` itself marker-aware converts all of them at once, including
the ones nobody has written yet, and it makes F1's fallback a genuine fallback
rather than a trapdoor back into blindness.

### What changed, per residue item

| # | residue item (F2 verdict) | mechanism |
|---|---|---|
| 1 | `ManuscriptMigrationRunner.swift:400` — post-flip re-migration | the emptiness probe is `ManuscriptStoreAdapter.listCollections()` (→ `collectionKernel.tree` → `list_tree(MANUSCRIPT_COLLECTION)`), not `queryBySchema("manuscript-collection")`. Semantics unchanged: still scoped to manuscript folders, still gated on the legacy Core Data store having workspaces |
| 2 | `delete_library_undoable` — silent data loss | the child-collection snapshot is `list_tree_in(IMBIB_COLLECTION, library)`. `restore_library`'s `SetParent` re-attach was already correct — only the WALK was blind |
| 3a | `create_manuscript_collection` (legacy writer) | **DELETED**, export + Swift wrapper. Zero live callers: every manuscript folder in the suite is created by `CollectionStoreAdapter.create(.manuscript, …)`. Delete-in-favour-of, as the F2 verdict's "fix-vs-delete" note allowed |
| 3b | `FigureStoreReader.createFolder` (legacy writer) | **DELETED.** Zero callers since G2 — `ImbibSidebarViewModel.createFolder(bindingID:)` routes every non-publication binding through `CollectionStoreAdapter.create`, whose `newFolderSortOrder` already reproduces this function's `sort_order = folderCount` and whose event is the same `postMutation(structural: true)` |
| 3c | `FigureStoreReader.fetchFolders` (+ its payload decode) | `CollectionStoreAdapter.shared.tree(.figure)`. Return type is now `CollectionKernelRow`, which carries `name` / `sortOrder` / tree `parentID` as typed fields, so `FigureCollectionPayload` and `folderPayload` are gone with the query that needed them |
| 4 | `imbib-service/library_service.rs:647` — the agent surface | **no edit.** It delegates to `ImbibStore::list_collections`, so fixing the export fixed it. This is the payoff of the export-level strategy, stated as a diff of zero lines |
| 5a | `list_manuscript_collections` (live in imprint) | `list_tree(MANUSCRIPT_COLLECTION)` reshaped. Two shape notes below |
| 5b | `ImploreStoreAdapter.fetchFolders` | `store.collectionTree(binding: .figure)`, returning `SharedCollectionRow`. Zero callers today, kept rather than deleted: it is ImploreCore's published read API and the app's folder surface grows into it |
| 6 | `count_collections` (cosmetic, `/api/status`) | `collection_ops::resolve` + `ResolvedBinding::scope_predicates()` on the caller's own `ItemQuery`. Still a `COUNT(*)` — `//api/status` has no use for per-row member counts — and `scope_predicates` exists for exactly this shape of caller |

### Two shape notes worth knowing

**`list_manuscript_collections`' member count changed definition, on purpose.**
It was `count(schema = "manuscript" AND ReferencedBy(Contains, folder))`; it is
now the kernel's `member_count`, every outgoing `Contains` edge. The numbers
agree for every row this store can hold, and where they could ever diverge the
kernel's is the number imprint's own `collectionMemberCounts` already reports for
the same folder. This REMOVES a divergence rather than introducing one.

**`is_workspace` needed a fallback, and finding that out is the F3 near-miss.**
It is imprint's field, not the kernel's (`ManuscriptStoreAdapter.createCollection`
writes it as an additive follow-up on whatever schema the kernel just wrote), so
the migration files it into the `legacy` extras bag rather than dropping it — and
a migrated row therefore spells it `legacy.is_workspace` while a pre- or
post-flip-created row spells it at the payload root. A reshaper that read only the
root would have silently demoted every migrated workspace. Both spellings are
read (`manuscript_workspace_ids`, one query, not one `get` per row). **The general
rule this instances:** any app-specific payload field on a collection row moves
under `legacy` at the flip, so a reader of one must say so.

### Proofs

| proof | where |
|---|---|
| **the all-clear** — every imbib-core collection export snapshotted before and after a real migration on a store seeded through the real writers, with all three legacy kinds, nesting and members: rows, ORDER, parents, smart flags, member counts, `is_workspace`, and both reverse-membership projections | `imbib-core/tests/collection_migration_legacy_readers.rs` `every_collection_export_answers_identically_across_the_flip` |
| delete → undo round-trips a library WITH its collections, run on BOTH sides of the marker | same file, `deleting_and_undoing_a_library_keeps_its_collections` |
| **the flip drill** — `migration_status` → dry run → compare → migrate → re-migrate (idempotent) → rollback, with the export snapshot asserted invariant at every step, and the dry run asserted to write nothing (marker, rows and exports all untouched) | same file, `the_dry_run_rehearses_the_flip_and_rollback_rewinds_it` |
| the imprint re-migration probe's query answers non-empty post-flip, *and* the query it replaced answers empty — both halves, so it is a regression test rather than a tautology | same file, `the_imprint_re_migration_probe_is_marker_aware` |
| Swift: `listManuscriptCollections` agrees with the kernel tree on the real cross-adapter write path — tree parents, badges, `is_workspace` | `CollectionKernelReadParityTests.testManuscriptFolderExportAgreesWithTheKernelOnTheRealWritePath` |
| Swift: delete → undo restores a library's collections through the shipping export | same file, `testDeletingAndUndoingALibraryRestoresItsCollections` |
| Swift: `FigureStoreReader.fetchFolders` IS the adapter's tree, and keeps every field `figureFolderNodes` builds the sidebar from (name, sortOrder, tree parent, order) | `CollectionStoreAdapterTests.testFigureFolderReadsGoThroughTheKernelAndKeepEveryFieldTheSidebarUses` |

`collection_migration_legacy_readers.rs` changed character a third time. It was
"the legacy readers go blind, and that is why the flag is off" (G7), then two
halves (F2); it is now **one half**, and the file that held the blindness
assertions holds the all-clear.

### Flip-readiness verdict, re-run on the F3 tree (2026-07-30)

**READY.** Every export, every Swift reader and every writer named in the F2
residue is marker-aware or deleted. The residue table, re-walked:

| item | F2 verdict | F3 |
|---|---|---|
| `list_collections(library_id)` | RESIDUE (export blind; `imbib-service` reads it) | ✅ kernel read |
| `delete_library_undoable` | **BLOCKING — silent data loss** | ✅ snapshot is `list_tree_in`; round trip asserted both sides |
| `list_manuscript_collections` | **BLOCKING in imprint** | ✅ kernel read, `is_workspace` preserved |
| `create_manuscript_collection` | **BLOCKING (writer)** | ✅ deleted (dead) |
| `count_collections` | RESIDUE (cosmetic) | ✅ marker-aware count |
| `ManuscriptMigrationRunner.swift:400` | **WORST FAILURE MODE** | ✅ probe reads the kernel |
| `imbib-service/library_service.rs:647` | agent surface blind | ✅ by the export fix, zero lines |
| `FigureStoreReader` `createFolder` / reads | writer + blind reads | ✅ writer deleted, read on the kernel |
| `ImploreStoreAdapter.fetchFolders` | implore's surface empties | ✅ kernel read |
| `add_to_collection`, `remove_from_collection`, `delete_collection`, `rename/create/get_*_detail/list_collections_for_publication` | benign / FIXED (F2) | unchanged |

**One narrow residual, named rather than fixed.** implore's one-time
`migrateLibraryIfNeeded` backfill (`ImploreStoreAdapter:296`) still writes
`figure-collection` rows through a bulk mirror upsert. It is watermarked in
`sync_metadata` and runs at most once per store, so rows it has already written
are converged like any other legacy row — the only exposed case is a store
flipped *before* that backfill has ever run, which takes one batch the kernel
cannot see and is recoverable with a second `migrate` (idempotent,
`skipped_already_generic`). Converging the backfill means routing a bulk upsert
through per-row kernel creates, which is implore's Stage-1 work.

### The flip procedure, for the user's real store

The user flips; nothing in this work package touched a real store or the flag.

```
# 0. Close every impress app. These commands open impress.sqlite directly.
#    --store-path (or IMPRESS_STORE_PATH) selects the store; the real one is
#    ~/Library/Group Containers/<suite group>/impress.sqlite
export IMPRESS_STORE_PATH="$HOME/Library/Group Containers/…/impress.sqlite"

impress migration-status          # 1. read-only, always safe
impress migrate --dry-run         # 2. writes NOTHING; reports the real run's counts
                                  # 3. compare: `found` per binding == migration-status' `legacy` rows
impress migrate                   # 4. the real run — rows + marker in ONE transaction
impress migration-status          # 5. legacy 0, generic == what the dry run said

impress rollback                  # if anything looks wrong. A REWIND, not a merge:
                                  # edits made to a migrated row WHILE migrated are
                                  # discarded with it. Same-session escape hatch.
```

The same three verbs are MCP tools (`impress-store-service` →
`collection-service_migration-status` / `_migrate` / `_rollback`) and impel agent
tools, generated from the one `#[impress_service]` trait.

**A real dry run, on a scratch store seeded through the real writers** (two
publication collections nested, two manuscript folders nested with two imported
manuscripts filed in one, two figure folders nested):

```json
{
  "ok": true, "dry_run": true, "was_migrated": false,
  "membership_edges_untouched": true,
  "bindings": [
    { "schema_ref": "imbib/collection",      "kind_scope": "publication",
      "found": 2, "rewritten": 2, "skipped_already_generic": 0 },
    { "schema_ref": "manuscript-collection", "kind_scope": "manuscript",
      "found": 2, "rewritten": 2, "skipped_already_generic": 0 },
    { "schema_ref": "figure-collection",     "kind_scope": "figure",
      "found": 2, "rewritten": 2, "skipped_already_generic": 0 }
  ],
  "message": "DRY RUN — nothing written. 6 legacy row(s) would be rewritten onto
              collection@1.0.0. Re-run with dry_run: false to apply."
}
```

`migration-status` was byte-identical before and after that dry run; the real run
reported the same six lines with `dry_run: false`; a second `migrate` reported
`found: 0, skipped_already_generic: 2` per binding; `rollback` restored all six
and cleared the marker; and every binding's `tree` printed the same names,
parents and member counts on both sides of the flip.

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
