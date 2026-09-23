# Agent surfaces — how-to

## What a surface is

A surface is a stored, declarative UI document — an `impress/ui/surface@1.0.0`
record whose payload is JSON, not code — that renders in any pane through the
`surface` view kind, so it obeys every ADR-0031 pane rule (parameters,
channels, roles, undo, presets) with no special case. Its behaviour comes
from a pure Rust function pair (`plan`/`resolve`/`reduce` in `impress-surface`)
rather than from anything the spec itself computes, so the same document is
Tier-A testable headlessly, agent-authorable without a sandbox, and rendered
identically by any host that implements the mapping. See
[ADR-0033](ADR-0033-agent-surfaces.md) for why it is shaped this way; this
document is the how-to.

## The five-verb loop

An agent builds and drives a surface with five MCP calls plus a reaction step
that closes the loop. This is the same loop `docs/plan-agent-surfaces.md`
calls "the prototyping loop is five verbs and one scaffold" (ADR-0033 D8).

1. **`impress-surface-service_surface-schema`** — no arguments. Returns the
   `SurfaceSpec` JSON Schema plus a worked example, so an agent authoring in a
   chat never has to read Rust source to learn the vocabulary.
2. **Author** the spec against the vocabulary below — no tool call, just JSON.
3. **`impress-surface-service_surface-validate`** — checks the spec and names
   every problem by path (`{"path": "root.column[2].plot", "message": "..."}`),
   so a malformed spec is a list of fixes, not a stack trace.
4. **`impress-surface-service_surface-create`** — stores the spec as an
   `impress/ui/surface@1.0.0` row and returns its id.
5. **`impress-surface-service_surface-show`** — puts the surface in a pane.
   `target` says which pane, with the same precedence a layout-service
   `PaneRefDto` uses: a tile id (`{"id": 7}`), a role (`{"role": "detail"}`),
   or `{"split": {"direction": "vertical"}}` to open a new pane beside the
   focused one. Under the hood this composes ordinary `layout-service` verbs
   — split (or take the named role), set the pane's query to `item(id)` of
   the surface, set its view kind to `surface` — so a surface pane is not a
   special case of the layout tree, just an ordinary pane whose query happens
   to name a surface.
6. **`impress-surface-service_surface-wait`** — long-polls
   `impress/ui/surface-event@1.0.0` for this surface/host past a cursor, up
   to a timeout. It returns when the human does something, or on timeout with
   nothing new.
7. **React**: read what came back and either
   **`impress-surface-service_surface-update`** the spec/state (change what
   the human sees) or call a domain verb directly with what the human chose
   (act on it). Then `surface_wait` again — the loop is
   create → show → wait → update or act → wait.

### A full round, transcript-shaped

This is the signal-explorer example from `docs/plan-agent-surfaces.md`,
run start to finish. Tool names and JSON shapes for `surface-schema` and
`surface-validate` responses are illustrative (they render exactly what S1
computes, which is normative; the JSON here is not); the spec JSON itself,
the store records and the verb list are the normative parts, copied from the
plan.

**1. Schema.**

```
→ impress-surface-service_surface-schema {}
← { "schema": { "...": "the SurfaceSpec JSON Schema" },
    "example": { "...": "a worked example, e.g. the one below" } }
```

**2. Author** (this is the spec verbatim from `docs/plan-agent-surfaces.md`):

```json
{
  "surface": "1.0",
  "name": "Signal explorer",
  "params": [ { "name": "selected", "kind": "imbib/bibliography-entry", "required": false } ],
  "state":  { "freq": 1.0, "bins": 20 },
  "sources": {
    "series": { "verb": "surface-demo-service_series",
                "args": { "freq": "{{state.freq}}", "n": 512 } },
    "hist":   { "verb": "surface-demo-service_histogram",
                "args": { "values": "{{source.series.values}}", "bins": "{{state.bins}}" } },
    "papers": { "query": { "...": "PaneQuery JSON" } }
  },
  "root": { "column": [
    { "text": "# Signal explorer" },
    { "row": [
      { "field": { "slider": { "min": 0.5, "max": 8, "step": 0.5 } },
        "label": "Frequency", "bind": "state.freq" },
      { "field": { "slider": { "min": 4, "max": 64, "step": 1 } },
        "label": "Bins", "bind": "state.bins" }
    ]},
    { "plot": { "spec": "{{source.hist.plot}}" } },
    { "table": { "rows": "{{source.papers}}", "columns": ["title", "year"],
                 "on_select": [ { "publish": {} } ] } },
    { "button": { "label": "Use these bins",
                  "on_click": [ { "emit": { "name": "bins-chosen",
                                            "payload": { "bins": "{{state.bins}}" } } } ] } }
  ]}
}
```

**3. Validate.**

```
→ impress-surface-service_surface-validate { "spec": { "...": "the JSON above" } }
← { "problems": [] }
```

An invalid spec (say, `on_click` pointing at a verb that does not exist)
comes back as `{"problems": [{"path": "root.column[4].button.on_click[0].call.verb",
"message": "no such verb: surface-demo-service_frobnicate"}]}` — one entry per
error, named by path, never a bare parse failure.

**4. Create.**

```
→ impress-surface-service_surface-create { "name": "Signal explorer", "spec": { "...": "the JSON above" } }
← { "id": "3fae1c9e-...", "name": "Signal explorer", "version": 1 }
```

This writes the `impress/ui/surface@1.0.0` row (`name`, `version`, `spec`,
`tags`).

**5. Show.**

```
→ impress-surface-service_surface-show { "id": "3fae1c9e-...", "target": { "split": { "direction": "vertical" } } }
← { "pane": 12, "focused": true, "affected_panes": [12] }
```

The human now sees the surface: a title, two sliders, a histogram plot, a
paper table and a button.

**6. Wait.**

```
→ impress-surface-service_surface-wait { "id": "3fae1c9e-...", "after": 0, "timeout_ms": 30000 }
```

The human drags the Bins slider to 40 and clicks "Use these bins". The field
change sets `state.bins` (no `on_change` here, so nothing further runs on the
change itself); the click runs its `on_click`, which emits a named event.
`surface_wait` then returns:

```json
{ "events": [
    { "surface": "3fae1c9e-...", "seq": 41, "name": "bins-chosen",
      "payload": { "bins": 40 }, "at": "2026-09-22T18:04:11Z" }
  ],
  "cursor": 41 }
```

**7. React.** The agent reads `bins-chosen`, decides the human is happy with
the binning, and acts on it directly — e.g. it calls the same
`surface-demo-service_histogram` verb the surface's `hist` source calls, with
`bins: 40`, to fold the choice into a report it is writing — rather than
mutating the surface further. Had it wanted to change what the human sees
instead (add a caption, disable the button, swap in a different plot), it
would call `impress-surface-service_surface-update` with a patched spec and
loop back to `surface_wait`.

### A second worked example: paper triage

The signal explorer above is synthetic data driving a slider and a plot.
`example_paper_triage` (`crates/impress-surface/examples/paper-triage.surface.json`,
wave 5 V3) is the other shape of surface: a `query` source over the user's
own data — unread papers, `publication` / `imbib/bibliography-entry` — a
table, and a row of buttons that act on whichever row is selected through
kit verbs the whole suite already has. It exists so an agent's first surface
over a domain the user actually works in looks like this, not like a demo.

**The verbs.** All four are `#[impress_service]` verbs already linked
everywhere — the app, the CLI and MCP alike, never a second definition for
surfaces (root `CLAUDE.md`, "Agent surfaces live in Rust and in store
records"):

- `triage-service_set-starred` (`crates/impress-store-service/src/triage_service.rs`)
  — the "Star" button.
- `triage-service_set-flag` — the "Flag red" button, `color: "red"`.
- `triage-service_add-tag` — the "Tag to-read" button, `tag: "to-read"`.

`TriageService` takes an item id of ANY kind (publication, manuscript,
figure, message, task, agent run) — the same verbs a triage menu on any
other record kind would call, not something built for this surface.

**The loop an agent runs with it** is the same five-verb loop as the signal
explorer's, with a table row standing in for the slider as "the thing the
human does between waits":

1. `surface-schema` / author / `surface-validate` — as above; the spec
   itself is short enough to read in full in
   `crates/impress-surface/examples/paper-triage.surface.json`.
2. `surface-create`, then `surface-show` (a split, or a named pane role) —
   the human now sees a table of their own unread papers, newest first, and
   three buttons.
3. `surface-wait`. The human clicks a row (a `select` event on the table
   sets `state.selected`, and nothing else — there is no `on_select` verb
   call, just the plain `state.selected = event.value` this vocabulary's
   `set` action already does), then clicks "Tag to-read". The click's
   `on_click` runs three actions in order: `call` the verb with
   `{"id": "{{state.selected}}", "tag": "to-read"}`, `refresh` the `papers`
   source (so the very next render already reflects the tag), and `emit` a
   `triaged` event carrying `{"id": "{{state.selected}}", "action": "tag-to-read"}`.
   `surface-wait` returns with that `triaged` event.
4. **React.** The agent reads the `triaged` event's `id` and acts on it
   directly — e.g. queues the paper for a summarisation pass — the same
   "read what the human did, then act" shape the signal explorer's step 7
   uses, just with a triage verb instead of a plot verb on the far end.
   `surface-wait` again.

**The one vocabulary gap this surface hit.** `on_select` can only set
`state.selected` to whatever `event.value` the table's `select` event
carries — the template language walks dotted object keys only
(`crates/impress-surface/src/template.rs`: `resolve_path` matches
`Value::Object` and returns `MissingPath` for anything else, including an
array), so there is no `{{event.value.0}}` form, or any other, that would
project a multi-id selection down to one id. A one-id verb (every
`triage-service_*` method takes exactly one `id: String`) therefore only
works cleanly against a table whose `select` event already carries a single
id as `event.value`, not an array of them — `paper-triage`'s buttons take
this on faith (`{{state.selected}}` resolves to whatever `event.value` was,
unindexed) and would receive a malformed id if a host ever emitted the
"selection is an array of ids" shape ADR-0031's pane channels use elsewhere.
Nothing in this crate can distinguish those two cases without an indexing
operator the vocabulary deliberately does not have (ADR-0033 D3: "there are
no operators, conditionals or loops in a spec"); the honest fix, if a host
ever needs true multi-select through this same path, is a verb that takes a
list of ids, not a template change.

## Vocabulary reference

This is the normative vocabulary from `docs/plan-agent-surfaces.md`, copied
here as a reference table — that file is the source of truth if the two ever
disagree. Every node is a JSON object with exactly one node-kind key plus the
optional common keys `id`, `label`, `help`, `when` (see **`when`** below).
Paths are dotted; a string that is exactly one `{{path}}` resolves to the
JSON value at that path, mixed text stringifies. Path roots: `state`,
`param`, `source`, `event`.

### Containers

| Kind | Keys | Meaning |
|---|---|---|
| `column` | `[node]` | Children stacked vertically. |
| `row` | `[node]` | Children laid out horizontally. |
| `grid` | `{ columns: n, items: [node] }` | Fixed column count, items flow. |
| `section` | `{ title, collapsed?, body: node }` | A titled, optionally-collapsible group. |
| `tabs` | `[ { title, body: node } ]` | One child visible at a time. |

### Widgets

| Kind | Keys | Meaning | Renderer event kind |
|---|---|---|---|
| `text` | `string \| {{path}}` | Markdown. | — |
| `table` | `{ rows, columns, on_select? }` | Tabular data; `rows` through the host's row-style registry. | `select` (runs `on_select`) |
| `list` | `{ rows, on_select? }` | Same, non-tabular rows. | `select` (runs `on_select`) |
| `plot` | `{ spec }` | A `plot-spec@1.0.0` payload, never pixels. | — |
| `image` | `{ blob \| url }` | — | — |
| `field` | `{ text\|number\|slider\|select\|toggle\|date: options }`, `bind: state.path` | An editable value bound to state. | `change` — sets `bind`, then runs `on_change` if the field declares one |
| `button` | `{ label, on_click: [action] }` | — | `click` (runs `on_click`) |
| `status` | `{ level, message }` | — | — |
| `log` | `{ lines }` | — | — |
| `kv` | `{ pairs }` | Key/value display. | — |
| `divider` | `{}` | — | — |
| `spacer` | `{}` | — | — |

The renderer's event-kind enum is `"change" \| "click" \| "select" \| "submit"`
(`{"widget": id, "kind": ..., "value": json}`); `submit` is part of that
enum but the normative vocabulary above does not assign it to a specific
widget kind — treat it as reserved rather than inferring which widget raises
it.

### Sources

A source is one of:

| Shape | Meaning |
|---|---|
| `{ "value": json }` | A fixed value. |
| `{ "verb": name, "args": object }` | A `#[impress_service]` verb call. `args` may reference other sources by `{{source.name.field}}`; a cycle between sources is a validation error, not a runtime one. |
| `{ "query": PaneQuery }` | An ADR-0031 pane query, run the same way a pane's own query runs. |

Sources are cached by their resolved arguments and re-run only when an
argument changes, a store invalidation names the query, or an action
`refresh`es them explicitly (ADR-0033, "Defaults accepted without further
discussion").

### Actions

| Shape | Meaning |
|---|---|
| `{ "set": { path, value } }` | Write a value at a state path. |
| `{ "call": { verb, args, into?: state.path } }` | Run a verb; optionally store its result. |
| `{ "publish": { ids?: path } }` | Publish a selection on the pane's channel — how a surface's table feeds another pane, the same channel mechanism ADR-0031 gives every pane. |
| `{ "emit": { name, payload } }` | Emit a named event the agent reads back via `surface_events`/`surface_wait`. |
| `{ "open": { query, view_kind, target? } }` | Open a query in a pane — a surface can drive the layout tree, not just itself. |
| `{ "refresh": { source } }` | Re-run a source now, bypassing its cache. |

### `when`

`{ "path": "state.x" }` is truthy-gated; `{ "path": ..., "equals": json }`
gates on an exact match. Any node may carry `when`; a node whose `when` does
not hold is omitted from the `RenderTree`.

### `RenderTree`

What `surface_render` returns: the same node shapes as the spec, but with
every `{{path}}` reference resolved to its current value, a `focusable`
widget ordering computed (j/k walk this order — see "keyboard" in
ADR-0033's defaults), and any node whose kind this host does not recognise
replaced by `{"placeholder": {"kind": "...", "node": {...}}}` rather than
dropped — the same forward-compatibility rule ADR-0031 uses for an
unrenderable view kind, so a spec authored for a newer kit still renders the
rest of itself on an older host.

### Store records

| Record | Fields |
|---|---|
| `impress/ui/surface@1.0.0` | `name`, `version`, `spec`, `tags` |
| `impress/ui/surface-state@1.0.0` | `surface`, `host`, `state`, `cursor` — one row per (surface, host instance) |
| `impress/ui/surface-event@1.0.0` | `surface`, `host`, `seq`, `name`, `payload`, `at` |

### Every verb

`surface_schema`, `surface_validate`, `surface_create`, `surface_update`,
`surface_get`, `surface_list`, `surface_delete`, `surface_show`,
`surface_render`, `surface_state_get`, `surface_state_set`,
`surface_dispatch`, `surface_events`, `surface_wait`, `surface_examples` —
each an `#[impress_method]` on `impress-surface-service`'s trait, so MCP, the
CLI and impel's agent loop get all fifteen together.

## How to add a Rust capability

A surface can only compute by calling a verb (ADR-0033 D3/D4) — there are no
expressions, conditionals or loops in a spec. So making a new Rust capability
GUI-able is entirely a matter of giving it a verb; nothing in the surface
layer or in Swift changes.

```
scripts/new-capability.sh <name>
```

writes `crates/<name>-service`:

- `Cargo.toml`, matching `crates/impress-layout-service/Cargo.toml`'s shape
  (workspace `version`/`edition`/`license`/`repository`, and the minimal
  dependency set: `impress-service-core`, `impress-service-macros`, `serde`,
  `serde_json`, `schemars`, `async-trait`, `thiserror`).
- `src/lib.rs`: one `#[impress_service]` trait `<Name>Service` with one
  `#[impress_method]` verb (`echo(message: String) -> EchoResult`), a
  `Default<Name>Service` implementing it, and the `impress_service_impl!`
  wiring that registers it in the linked inventory.
- a Tier-A style test that calls the verb the way MCP/CLI/impel actually do:
  find its `McpToolDescriptor` in `impress_service_core::McpToolDescriptor::iter()`
  by tool name and run its handler with `impress_service_core::runtime::block_on`
  — not a direct call on the trait, which would not catch a macro-wiring
  mistake.
- `examples/<name>.surface.json`: a minimal surface (a text header, a text
  field bound to `state.message`, a button that `call`s the new verb with
  `into: state.reply`, and a `text` showing `{{state.reply}}`) — small enough
  to be the whole example, and already valid against the vocabulary above.
- registration: a workspace member line and a workspace dependency line in
  the root `Cargo.toml`, plus a feature and an optional dependency in
  `crates/impress-capabilities/Cargo.toml` (see the next paragraph).

**The tool name.** A verb's MCP/CLI name is `kebab(<trait name>)_<kebab(method
name)>` (`crates/impress-service-macros/src/lib.rs`, `expand_method`). For a
trait named `<Name>Service` in a crate named `<name>-service`, that is always
`<name>-service_<method>` — no separate derivation needed, which is why the
scaffold can print the tool name up front.

**Becoming callable from a surface.** Once the crate exists, it still has to
be *linked* before any process can dispatch its verb — an `#[impress_service]`
trait registers into the `inventory` crate's global collector only in a
binary that actually depends on the crate (ADR-0033 D4). Where that link
happens depends on what kind of capability it is. A **domain** capability
(suite-specific — imbib, imprint, impart, implore, impel, and the other
per-app or cross-cutting services) is registered in `crates/impress-capabilities`,
behind a feature named after the capability; the scaffold's registration step
adds that feature and an `optional = true` dependency, printing the two lines
to add by hand instead if `impress-capabilities` does not yet have
`[features]`/`[dependencies]` sections to anchor on. A **kit** capability
(store/layout/surface-shaped, part of the ADR-0033 D7 standalone cut) is
registered instead in `crates/impress-capabilities-kit`, as a plain,
non-optional, non-feature-gated dependency — that crate holds exactly the kit
service crates and nothing that reaches `impress-store-ffi`, which is why
`impress-store-ffi` can depend on it directly where it cannot depend on
`impress-capabilities` at all (see that crate's module docs for the package
cycle this avoids). Either way, once linked, `{"verb": "<name>-service_echo",
"args": {...}}` is usable in any surface's `sources` or in a `call` action,
exactly like `surface-demo-service_series` in the worked example above.

**The `kit` feature line.** `impress-capabilities` exposes feature sets, not
just individual capability features: `full` (everything, for `impress-mcp`
and `impress-cli`) and `kit` (a single dependency on `impress-capabilities-kit`
— store + layout + surface + surface-demo, the capabilities the standalone
cut ships without a second copy of an app's domain core). A capability
generated by this script registers as a domain capability by default; making
it kit-grade instead is a deliberate per-capability decision (does this
capability belong in the standalone kit, or is it suite-specific?), made by
adding it directly to `impress-capabilities-kit/Cargo.toml` in place of the
domain registration, not by editing a `kit` feature list — `impress-capabilities-kit`
has no per-capability features of its own; it force-links its whole
dependency set unconditionally.

## What only the Mac can verify

Everything up to and including `surface_render`'s `RenderTree` is provable
headlessly, on Linux, in `cargo test`. What is not: that the SwiftUI mapping
in `packages/ImpressSurface` (`SurfaceView`, per work package S7) actually
turns that tree into pixels — the `MarkdownUI` rendering of a `text` node,
`imprint-core`'s `render_plot_svg` for a `plot` node, that `.keyboardGuarded`
really does stop `j`/`k` from stealing a `field`'s typing. That needs Tom's
Mac.

To inspect a surface's *behaviour* without the GUI, call
`impress-surface-service_surface-render` (or the equivalent Tier-A helper)
and read the `RenderTree` JSON it returns — the exact node tree, with every
reference resolved and the `focusable` order computed, that the Swift
renderer would otherwise turn into a window. Driving `surface_dispatch` with
a synthetic event (`{"widget": "bins-slider", "kind": "change", "value": 40}`)
and re-rendering is how a Tier-A test proves "moving this slider updates that
plot" without ever opening the app — the same discipline
`crates/imprint-selftest` already established for imprint's other
capabilities.

## Reading what the human did

`surface_events` returns a page of a surface's `impress/ui/surface-event@1.0.0`
rows; `surface_wait(id, after, timeout)` long-polls the same rows and returns
as soon as a new one lands, or on timeout with nothing new — the primitive
the loop above calls "wait". Both are ordinary store reads: an agent
participates by reading what the human did, the same way it reads anything
else in the store, not through a special channel.

The ring is capped at the last 200 events per surface and pruned past that
(ADR-0033 D5), and both `surface-state` and `surface-event` are
Ephemeral-tier (ADR-0019 terms: device-scoped, never synced). This follows
ADR-0031's privacy decision directly: "the standard build records nothing
that exists only to be analysed" (ADR-0031 D7, "Exploration is ephemeral,
commit is durable, undo has three stacks"). A surface's events exist so
the agent driving the loop can read them back *during* the conversation that
created them, not so anyone can mine 10,000 surfaces' worth of button clicks
afterward — which is also why there is no verb that lists events across
surfaces, only per-surface, and why the ring is bounded rather than kept
forever.
