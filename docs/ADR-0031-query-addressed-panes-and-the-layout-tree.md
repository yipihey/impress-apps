# ADR-0031: Query-Addressed Panes and the Layout Tree

**Status:** Accepted (design conversation 2026-09-21; implementation in progress)
**Date:** 2026-09-21
**Authors:** Claude (Fable 5.1 session), decided with Tom
**Depends on:** ADR-0001 (Unified Item Architecture), ADR-0006 (Retention Tiers), ADR-0018 (Thin-Twin Chassis), ADR-0019 (Legible Workspace), ADR-0021 (Record-kind descriptors), ADR-0022 (Collection kernel, `RecordViewerRegistry`), ADR-0030 (Manuscript projects, figures as store rows)
**Input:** `docs/gui-layout-survey.md`
**Scope:** `crates/impress-core/src/pane_query.rs` (new), `crates/impress-layout/` (new), `crates/impress-layout-service/` (new), `crates/impress-core/src/schemas/ui.rs` (new, per ADR-0019 D1), `crates/impress-store-ffi` (new exports), `apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Chassis/Layout/` (new Swift host), and eventually every `SectionContentView` route

---

## Context

The chassis is one fixed three-column split. The only layout the user can shape is
`PaneLayoutState`: three pane toggles, a detail tab, two appearance fields, saved under a
name and recalled with ⌃⌘1–9. Every other decision about *where a thing appears* is code
in `SectionContentView`, per kind, per platform, and the number of sections, row kinds,
detail tabs and modes now grows faster than that code can be kept stable.

`docs/gui-layout-survey.md` read forty layout systems against six axes. The ones that fit
impress's own principles are the ones where the layout is a plain value, content is
bound to slots by identity or by query rather than by pointer, every gesture is a named
command, and the layout record lives in the same store as the data (Emacs, Rerun,
Obsidian, egui_tiles, VS Code's command surface). No macOS docking framework exists; the
model will be ours, in Rust, with Swift rendering it.

This ADR records the decisions taken in the design conversation that followed the survey.

## Decisions

### D1 — A pane is a query, rendered by a view kind, with parameters filled by channels

A **pane** is the unit of the layout. Its specification is data:

```
PaneSpec {
  query:      PaneQuery,            // what the pane shows (D2)
  view_kind:  ViewKindId,           // how it is rendered ("outline", "list", "info", "pdf", "source", "plot", …)
  view_state: Json,                 // opaque, owned by the view kind (scroll, expanded nodes, colormap…)
  params:     [ParamBinding],       // the query's parameters and where each value comes from (D3)
  channel:    ChannelId,            // the channel this pane PUBLISHES its selection on (D3)
  role:       Option<Role>,         // "navigator" | "list" | "detail" | … — what universal chords act on (D5)
  session:    Option<SessionId>,    // for session-bearing view kinds (D6)
}
```

There is no sidebar type, no list type and no detail type. The sidebar is a pane whose
query returns navigable queries (collections, libraries, folders, sections) rendered with
the `outline` view kind. The publication list is a pane over a kind-scoped query with the
`list` view kind. The detail pane is a pane over `item(id = $selected)` with the `info`
view kind. Sidebar → list → detail is a chain of three panes on one channel, shipped as a
preset, not built in.

**Anything queryable can become a pane.** Every sidebar node can be dragged out as a
pane; every pane can be saved back as a sidebar node. The agent verb that creates a pane
is the verb that creates a collection.

### D2 — The query is a small closed algebra, not a language

`PaneQuery` is the only content addressing mechanism and it is deliberately limited:

```
PaneQuery {
  kinds:     [RecordKindId],                     // empty = any
  scope:     Scope,                              // All | Collection(id) | CollectionSubtree(id) | Library(id) | Mailbox(id) | Item(id)
  filters:   [Filter],                           // Flag(color?) | Starred | Unread | Status(s) | Tag(path) | DateRange(field, from, to)
  text:      Option<String>,                     // FTS term over items_fts
  relation:  Option<RelationWalk>,               // { edge: Cites | CitedBy | Contains | ProducedBy | InResponseTo, from: ParamRef | ItemId }
  sort:      [SortKey],
  limit:     Option<u32>,
}
```

Any position that names an item may instead name a **parameter** (`$name`), which is
filled at resolution time (D3). The algebra compiles to `impress_core::query::ItemQuery`
in one place, in Rust, from the descriptor manifest, so schema refs are spelled once
(the ADR-0022 schema-ref invariant becomes a compile-time property of the algebra).

**What the algebra cannot express is materialized first.** Explorations, SciX search
results, smart searches and any join or aggregation become items or collections in the
store, and the pane queries those. This is the Rerun stance: nothing is shown that is
not in the store. Growing the algebra requires an ADR amendment; the discipline is the
design.

### D3 — Parameters and channels

A query's **parameters** are named, typed blanks (`item: publication`,
`manuscript: manuscript`, `colormap: colormap`, `data: dataset`). A pane may have any
number of them, because visualization composes several selections into one object.

Each parameter is bound in one of two ways:

```
ParamBinding { name, kind, source: Channel(ChannelId) | Fixed(ItemId) | Default }
```

A **channel** is a numbered group (a fixed small set, `1..=8`, plus the reserved
`follow` meaning "the window's default channel"). A channel carries **one current value
per kind**: when a pane on channel 2 publishes a manuscript selection, only parameters
of kind `manuscript` bound to channel 2 change; a `publication` parameter on the same
channel is untouched. Closing the publishing pane leaves the channel's last value in
place. `Fixed` pins a parameter to one item; `Default` uses the view kind's default
(a plot without a colormap pane still renders).

Parameters are optional unless the view kind declares them required. An unfilled
required parameter renders the view kind's empty state ("nothing selected"), never an
error. This is also how a layout degrades when a source pane is absent.

Channels carry ephemeral coordination only. Anything worth keeping is **committed** to
a store item by an explicit operation (D7).

### D4 — The layout is a tree of containers over panes, stored as a value

```
Layout {
  windows: [Window { id, root: TileId, focused: Option<TileId>, geometry: DeviceScoped }],
  tiles:   Map<TileId, Tile>,      // arena; Tile = Pane(PaneSpec) | Container(Container)
}
Container = Tabs { children, active } | Linear { dir: Horizontal | Vertical, children, shares } | Grid { children, columns }
```

This is the egui_tiles shape. One tree per window, several windows per layout; a detached
PDF is a second window with one pane. There is no floating layer inside a window: macOS
windows do that job. The tree is normalized after every mutation (empty containers
pruned, single-child containers collapsed, nested same-direction linears joined,
tabs-in-tabs flattened). The tree outlives its content: a pane whose view kind the
platform cannot render becomes a placeholder that keeps its spec.

The layout value is serde-serializable and is the payload of an `impress/ui/layout`
item per ADR-0019 D1, with scope per ADR-0019 D2: the logical tree is portable-durable,
per-window geometry is device-scoped, focus and selection are ephemeral.

### D5 — Roles, not slots, are what universal chords act on

No pane kind is privileged. A pane may carry a **role** (`navigator`, `list`, `detail`,
`preview`, `console`), and the universal chords act on whichever pane holds the role:
⌃⌘S toggles the pane with role `navigator`, ⌘0 the one with role `detail`, ⌥⌘0 the one
with role `list`. Presets assign roles; users can move them. `PaneFocusCycler` and the
h / l grammar walk the leaves of the tree in order; the focused leaf is a value in the
layout (`Window.focused`), so it is legible to agents and tests.

### D6 — Session-bearing view kinds keep their sessions outside the tree

The editor, compose, and the plot canvas own state that must survive re-layout: an
`NSTextView` and its undo stack, an in-flight compile, an unsaved draft. Such view kinds
declare themselves **session-bearing**; the pane spec carries a `SessionId`; the session
lives in a registry outside the view tree (the `ManuscriptSessionRegistry` pattern,
generalized); and **no layout mutation ever tears a session down**. ADR-0018 D4's
invariant ("the manuscript detail pane must never acquire `.id(manuscriptID)`") is
restated here as a property of every session-bearing pane. Closing the pane releases the
session through the registry's LRU, not through view identity.

### D7 — Exploration is ephemeral, commit is durable, undo has three stacks

Every hole-binding change, selection, resize and arrangement gesture emits an operation
at `Ephemeral` retention, coalesced on release (ADR-0019 D6), and is compacted by the
watermark snapshot (ADR-0006). **Commit** — materializing the current bindings into a
figure, a collection, or a saved layout — emits one `Durable` operation, attributed, with
intent. Undo never crosses a commit; reverting a commit is the ordinary item-level
`inverse_of` operation.

There are three undo stacks, and ⌘Z is routed by the focused leaf:

1. the **editor session** stack (the view's own undo manager, untouched);
2. the **pane exploration** stack (parameter bindings and view state of the focused pane);
3. the **arrangement** stack (split, move, close, resize across the window), on its own chord.

**The standard build records nothing that exists only to be analysed.** No exploration
summaries, no dwell times, no counts of alternatives tried. Provenance on durable
operations is sufficient. An organization edition that wants more is an additional reader
over the same log under its own retention agreement, never a change to this model.

### D8 — Every gesture is a verb on a `layout-service` trait

The closed vocabulary, each an `#[impress_method]` so MCP, CLI and impel get it together:

| group | verbs |
|---|---|
| arrangement | `split`, `move_tile`, `close`, `swap`, `resize`, `set_container_kind`, `maximize`, `restore` |
| content | `set_pane` (whole spec), `set_query`, `set_view_kind`, `bind_param`, `set_channel`, `set_role` |
| focus / selection | `focus`, `focus_direction`, `select` (publishes on the pane's channel) |
| persistence | `commit`, `save_layout`, `apply_layout`, `undo`, `redo` (each taking which stack) |
| read | `get_layout`, `get_pane`, `get_channel`, `resolve_reference` |

Every verb takes a **pane reference** that resolves in one of three ways: by tile id
(canonical; what the log and tests use), by role (what chords and agents say), or by
direction from the focused leaf (what h / l and drag gestures produce). Resolution
happens once, in Rust. The fine content verbs are implemented as patches to the pane
spec, so the log records the patch and the tree has one shape. The keyboard grammar maps
chords to these verbs as data, extending `TriageKeyGrammar` rather than replacing it.

### D9 — The rendering cut is the KDDockWidgets cut

Rust owns the tree, normalization, reference resolution, query compilation, channel
state, undo rings, and the verbs. It is exposed over UniFFI beside the store. Swift walks
the tree and hosts registry-resolved view kinds in a container that maps `Linear` to
`NSSplitView`, `Tabs` to a tab strip, `Grid` to a grid, and never holds layout state of
its own (ADR-0019 D3: the projection is derived, never authoritative). The prerequisite
Rust work is incremental query results from the event bus, so a pane re-runs only when a
mutation touches its query; without that, every mutation re-runs every pane and the
startup render-loop invariant is re-tripped at scale.

### D10 — Presets are what the apps are

An app preset is a set of named queries, a default tree, and a role assignment. imbib is
"the publication queries with the triage layout"; imprint is "the manuscript queries with
the writing layout". The five binaries remain a distribution decision, not a chassis one.
Shipped presets (Reading, Triage, Writing, Reviewing, plus each app's default) are store
records the user can edit, recalled by ⌃⌘1–9, so that the developer stops making layout
decisions for the user, which is the purpose `PaneLayoutStore`'s own header states.

### D11 — Migration is one leaf at a time

A `Legacy` view kind hosts today's `SectionContentView` routes unchanged inside the tree,
so sections convert one at a time and the app stays shippable throughout. Order:
figures, mail, agents (already registry-resolved), then the outline sidebar, then
publications and manuscripts last (the two deliberate routing exceptions of ADR-0022).
`PaneLayoutState`'s six fields become derived views of the tree; the ⌃⌘1–9 layouts
become `impress/ui/layout` items via the ADR-0019 D5 importer.

## Defaults accepted without further discussion

- **Live-query change policy:** a row that stops matching stays visible until the pane
  refreshes or focus leaves it (freeze-until-refocus).
- **Capabilities of a query pane:** derived from the intersection of result kinds plus
  whether the scope is materializable (collection membership accepts drops; text search
  does not). The capability-matrix columns become a function of the spec.
- **Degradation:** unrenderable view kinds become placeholders that keep their spec;
  narrow widths collapse `Linear` containers to `Tabs`.
- **Channels:** eight numbered plus `follow`; a pane publishes its selection as typed
  values; `Fixed` is the per-parameter form of pinning.
- **Scope of the layout value:** ADR-0019 OQ1 resolved as logical tree portable-durable,
  window geometry device-scoped, focus and selection ephemeral.

## Vocabulary (fixed)

**pane**, **view kind**, **query**, **parameter**, **channel**, **role**, **container**
(**tabs** / **linear** / **grid**), **tile**, **layout**, **preset**, **session**,
**commit**. "Hole" was considered for parameter and rejected.

## Consequences

**Positive.** Layout is a value: diffable, undoable, saved by name, synced by ADR-0019
with no new sync code, and legible to agents by construction. Schema-ref misspellings
become compile-time failures of the algebra. Testing collapses to "run this query, assert
these rows" at Tier A plus one renderer walk. Layouts port across macOS, iOS and any later
frontend because they reference queries and view kinds, not Swift views. The five apps
become presets.

**Negative / costs.** The query algebra is now the product: every feature request is
"can the algebra express it", and the answer "materialize first" must be held. Incremental
query deltas from the event bus are prerequisite engineering. Capability derivation for
query panes is new design (defaulted above, to be proven in the matrix). Users understand
"Inbox", not "a query with a parameter on channel 2", so naming, defaults and presets
carry the whole legibility burden. The fast path of "add a SwiftUI view for this" is gone
by design.

**Invariants for future work.**
1. No view may hold layout state; the tree is the only source (ADR-0019 D3).
2. A session-bearing pane's session is never torn down by a layout mutation (D6).
3. Nothing enters a pane that is not in the store; materialize first (D2).
4. Channel values are ephemeral; durable state is committed (D7).
5. The standard build records nothing that exists only to be analysed (D7).
6. Every layout gesture is a `layout-service` verb; no Swift-only layout operation (D8).

## Work packages

See `docs/plan-layout-tree.md`.
