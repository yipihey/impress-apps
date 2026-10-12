# L8 leaf 4b: the sidebar is a surface

Plan wave 6 W3 made the navigator pane the app's sidebar by hosting the
chassis sidebar (`ImbibSidebarColumn` over `ImbibSidebarViewModel`) inside
the `outline` pane and asking Rust what a selected row does
(`outline_target`, `outline_verbs`). The rows, the counts, the context
menu, rename, delete, drag and drop stayed the view model's: 4,500 lines of
Swift that no agent can read and no other frontend can draw.

koine's outline wave (koine `docs/plan-koine-outline.md`) gave the
vocabulary a `tree` with every sidebar cell. This wave makes the imbib
sidebar that tree: the rows are a Rust verb, selecting a row is a Rust
verb, renaming, deleting, moving and creating are Rust verbs, and the
navigator pane draws a surface. The legacy sidebar stays behind a setting
until the surface is proven on a Mac.

| Question | Decision |
|---|---|
| where the rows come from | SB-D1 `layout-service_outline-rows` |
| what a row is called | SB-D2 node keys |
| what selecting does | SB-D3 `layout-service_outline-select` |
| rename, delete, move, create | SB-D4 the `outline-*` verbs forward to the collection kernel |
| the spec | SB-D5 `outline_surface_spec` |
| the pane | SB-D6 the `outline` view kind hosts the surface, behind a setting |
| what is not in this wave | SB-D7 |

## Decisions

### SB-D1. The rows are a kit verb over the store

`layout-service_outline-rows {app_id, bindings}` answers the sidebar's rows
for `app_id` as a flat list the `tree` node nests: each row `{id, parent,
label, count, node, legacy, kind}`. The sections are `outline_sections
(app_id)` in `IMBIB_SECTIONS` order followed by the deferred ones; the
children are read from the store the layout service already holds
(`Arc<dyn AttributedStore>` + the kind manifest, H-D1): libraries are the
`library` kind's items, collections the `collection` kind's items nested
by payload `parent_id` under their envelope parent (the library), sorted by
`sort_order` then `name`; feeds (`imbib/smart-search`) are read by schema
ref and are legacy rows; flags are the four colours after "Any Flag";
artifacts are "All Artifacts" plus one row per artifact schema ref with a
count; search forms are the static list; Recent, Dismissed and Cited in
Manuscripts are single rows.

**A row's count is the count of the query the row selects.** For every
row whose `outline_target` is a query, `count` is `store.count` of that
query compiled through the manifest, so the badge is the list's row count
by construction (W3 proved 153 = 153 by hand; here it cannot differ). A
legacy row has no count, except an artifact-type row, counted by its ref.
`bindings` are the ids only the host knows (`dismissed_library`,
`exploration_library`; the inbox library is the one with `is_inbox`), the
same map `outline_row_verbs_json` takes.

The verb declares its reads (the library, collection, publication, smart
search and artifact refs), so the surface runtime re-runs the source when
a write names one of them (RS-S2): a paper filed into a collection moves
the badge without a refresh.

This verb lives in koine's `impress-layout-service` because it must run
in every app's own process: a surface in imbib can call only the kit
crates' verbs the FFI links (`ImpressVerbHost.swift`'s header), and the
layout service is the kit crate that already owns the outline's targets.

### SB-D2. Node keys

A row's id is its `OutlineNode` written as one string — `section:inbox`,
`library:<uuid>`, `collection:<uuid>`, `smart-search:<section>:<uuid>`,
`search-form:<form>`, `recent`, `artifact-type:<type>`,
`record:<kind>:<scope>…`, `feed-form`, … — `node_key(&OutlineNode)` and
`parse_node_key(&str)` round-trip every variant. A key is what the tree
sends in every event, what `state.open` holds, and what an agent passes to
the verbs below, so an agent can say "select `section:inbox`" without
building a node object.

### SB-D3. Selecting is a verb that applies the outline's verbs as one step

`layout-service_outline-select {app_id, device, key, bindings, initial}`
parses the key, reads the live layout's `list` and `detail` role panes,
computes `outline_target` + `outline_verbs` (the W3 functions, unchanged)
and applies them with `apply_verbs_as` — all or none, one undo entry,
which the Swift router could not do (its header says so). It answers the
`LayoutVerbResult` plus `target`. A legacy row sets the scoped legacy pane
exactly as W3 does; an inert row applies nothing and says why.

### SB-D4. The row verbs forward to the collection kernel

`layout-service_outline-rename {app_id, key, name}`, `outline-delete
{app_id, keys}`, `outline-move {app_id, keys, to, index}` and
`outline-create {app_id, parent_key, name}` resolve the keys and forward
to `collection-service_{rename,delete,reparent,create}` by name through the
pipeline (`impress_service_core::call`), with the binding the app's
publication collections use (`imbib` for imbib and impress). The one
decision the forwarder makes: a drop ON a library row is a move to the
root of that library (`new_parent_id: null`), which is what the legacy
`handleReparent` does. A library, section, flag or form row refuses each
of these with a message naming the legacy sidebar as where that still
happens. The pure half (`outline_action(node, …) -> ForwardCall | Refusal`)
is tested in koine; the forwarding end-to-end is tested where the kernel
is linked (`impress-capabilities/tests`).

### SB-D5. The spec

`impress_layout_service::outline_surface_spec(app_id, bindings) ->
SurfaceSpec`: one `tree` (id `outline`) over a `verb` source `rows`
(SB-D1), `parent_field: "parent"`, `label_field: "label"`, `count_field:
"count"`, `bind: state.open` seeded with every section key so the
sidebar opens as the legacy one does, `on_select` → `outline-select` with
`{{event.value.0}}`, `on_rename`/`on_delete`/`on_move` → the SB-D4 verbs,
`actions` New Collection and Delete, every call followed by a `refresh` of
`rows`. `app_id` and `bindings` are literals in the spec, so the surface
needs no params. `koine::surface::example_collection_sidebar` stays the
generic worked example; this is the chassis' own.

### SB-D6. The outline pane hosts it, behind a setting

A new setting, `impress.outline.surface` (bool, device scope, default
false, section `impress.layout`). When it is on, `LayoutOutlinePaneView`
installs the surface for the window's app (`SharedLayout`-side installer
`install_outline_surface`, tag-keyed like `install_section_surface`, so
one row per app per store, refreshed when the spec changes) and hosts it
exactly as `LayoutSurfacePaneView` hosts any surface: a `SurfacePaneModel`
with the pane's tile, the root's keys forwarded, every event dispatched to
Rust. When it is off, nothing changes. The legacy host stays until the
surface's rows are Mac-verified in the capability matrix, which is when
the default flips.

### SB-D7. Not in this wave

Recorded here so the gaps are chosen, not forgotten:

- **Following the list** (PH-H5): an agent's `set-query` does not move the
  tree's selection. The surface's rows are re-read, not reconciled.
- **The launch selection**: the preset's list query stands at launch; no
  row is routed on the user's behalf.
- **Library rename and delete, New Library, Add Feed, Export, Import**: the
  legacy context menu's library entries. The kernel has no library verb;
  these stay with the legacy sidebar and refuse in the surface with a
  message.
- **Drops from outside the tree** (a paper dragged from the list onto a
  collection): the host's, not the tree's (koine `docs/outline.md` § 1).
- **Unread and starred badges** on feeds and libraries: a feed is a legacy
  row with no count; a library's count is its papers, not its stars.
- **Tags, Shared With Me, SciX libraries, the review queue**: the four
  deferred sections show as section rows with no children, as `MATERIALIZE_
  FIRST` says.
- **Icons and the tag filter field**: the tree draws labels and counts.

## Work packages

| # | Package | Where |
|---|---|---|
| K1 | node keys (SB-D2) in `outline.rs`; `outline_rows.rs` (SB-D1) | koine `impress-layout-service` |
| K2 | the five verbs (SB-D3, SB-D4): `outline_actions.rs` + `service.rs` | koine `impress-layout-service`, after K1's signatures |
| K3 | `outline_surface.rs` (SB-D5), the setting (SB-D6), docs | koine `impress-layout-service`, `impress-settings`, `docs/` |
| K4 | gate, Tier A capability, koine main, rev bump | orchestrator |
| A1 | FFI: `install_outline_surface`, `outline_surface_spec_json`; bindings | impress-apps `impress-store-ffi` |
| A2 | `LayoutOutlinePaneView` branch → `LayoutOutlineSurfaceView` | impress-apps PMC |
| A3 | Tier A over SQLite: rows, select, rename through the kernel | impress-apps `impress-capabilities/tests` |
| A4 | matrix § The outline sidebar, this plan's Status, `plan-layout-tree.md` log | impress-apps docs |

## Status

Built 2026-10-12; **not Mac-verified**. The default stays off.

**Landed**

- K1-K3 in koine main `9b052e0f` (`impress-layout-service`, `impress-settings`):
  node keys, `outline-rows`, the five verbs, `outline_surface_spec`, and the
  `impress.outline.surface` setting. Deviations the koine agents made from the
  text above:
  - `section_keys` omits `dismissed`.
  - "All Artifacts" is `record:artifact:all`.
  - Artifact-type keys carry the full schema ref.
  - The Exploration section row needs `exploration` bound (the host passes it
    with `exploration_library`).
  - `on_select` has no refresh (selecting writes the layout, not the rows).
  - `OutlineSelectResult` is the flat `LayoutVerbResult` plus `target` and
    `applied`.
- impress-apps A1-A4: A1 the FFI (`install_outline_surface`,
  `outline_surface_spec_json`, the Swift binding regenerated) and A3 the Tier A
  tests in `impress-capabilities/tests` (the Rust half; see the commit that
  carries them); A2
  `Chassis/Layout/LayoutOutlineSurfaceView.swift` and the
  `LayoutOutlinePaneView` branch on `@ImpressSetting("impress.outline.surface")`
  (Swift written without a toolchain on the authoring checkout, uncompiled);
  A4 the matrix
  subsection "The sidebar as a surface" in `chassis-capability-matrix.md` (its
  cells say "built", none is ✅) and the log line in `plan-layout-tree.md`.

**Pending: the Mac proof**, steps in the matrix subsection. Until each "built"
cell has a live log line the default stays off and the legacy sidebar stays.

**Open items** are SB-D7's list, unchanged: following the list, the launch
selection, library rename / delete / New Library / Add Feed / Export / Import,
drops from outside the tree, unread and starred badges, the four deferred
sections' children, icons and the tag filter field.
