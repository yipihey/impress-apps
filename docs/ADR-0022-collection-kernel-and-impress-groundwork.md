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

Define the `impress` `AppShellConfiguration` preset (all kinds,
`visibleSections: nil`, all surfaces) with parity tests, plus a store-level
integration test doing a mixed-kind collection round-trip through
`CollectionOps` with `kind_scope: "any"`. No app target until the sibling
apps and their renderers mature. When ready, the app is a ~120-line
`ImpressChassisRoot` against seams tested for months.

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
