# Agent surfaces — how-to

This is the how-to an agent copies from, and it is tested: every tool name
below resolves in both MCP projections
(`crates/impress-mcp/src/surface.rs`), and every JSON block preceded by a
`wire` HTML comment is parsed against the real types by
`crates/impress-surface-service/tests/doc_wire.rs`. When a shape changes,
that test fails until this page does. [ADR-0033](ADR-0033-agent-surfaces.md)
says why surfaces are shaped this way; where this page and the code
disagree, the code (and the schema `surface_schema` returns) is right.

## What a surface is

A surface is a stored, declarative UI document — an `impress/ui/surface@1.0.0`
record whose payload is JSON, not code — that renders in any pane through the
`surface` view kind, so it obeys every ADR-0031 pane rule (parameters,
channels, roles, undo, presets) with no special case. Its behaviour comes
from a pure Rust function pair (`plan`/`resolve`/`reduce` in `impress-surface`)
rather than from anything the spec itself computes, so the same document is
Tier-A testable headlessly, agent-authorable without a sandbox, and rendered
identically by any host that implements the mapping.

## The wire (version 1)

- **Results.** Every surface verb answers a snake_case JSON object with
  `ok`, a prose `message`, and `"wire_version": 1`. A refusal is `"ok":
  false` with a machine-readable `code` — branch on `code`, never on the
  message. Over MCP an `ok: false` answer is `isError`; the `impress` CLI
  exits 3 on it (1 when the verb could not be dispatched, 2 for a bad
  invocation); over HTTP its status follows the code.
- **Strict arguments.** Every argument an agent sends is checked: an
  unknown field — anywhere, including inside `target` or `event` — is
  refused with `invalid-argument` and a message naming it, never ignored.
  A pane is referred to one way across the suite — exactly one of `{"id":
  N}`, `{"role": "…"}`, `{"direction": "…"}`, `{"focused": true}` — and the
  retired tagged `{"ref": "id", "tile": N}` is refused naming `ref`; an
  unknown key in a `target` used to be ignored and open a new split.
- **Codes.** `invalid-argument` (400), `not-found` (404), `conflict` (409, a
  stale `expected_revision`), `invalid-spec` (422, a spec with an error),
  `store-unavailable` (503), `store-error` / `internal` (500),
  `host-unavailable` (503), `verb-failed` (502), `unknown-verb`, `no-pane`,
  `query-refused`, `effect-failed` (422); a reduce refusal carries its own
  (`unknown-widget`, `not-bindable`, `invalid-path`, `missing-state-path`,
  `state-path-conflict`, `each-not-array`, `unknown-template-root`,
  `missing-template-path`, all 422), and a layout refusal its tree code
  (`unknown-tile`, `no-pane-with-role`, …).

## Tool names

Every verb is an `#[impress_method]` on `impress-surface-service`'s trait, so
MCP, the CLI (`impress surface-show …`) and impel get all fifteen together.
The flat MCP name of each is the service's kebab name, an underscore, and the
verb's (`impress-surface-service_surface-show`). In the default **grouped**
projection (`IMPRESS_MCP_SURFACE` unset) the loop's own
seven are flat tools with full schemas:

`impress-surface-service_surface-schema`,
`impress-surface-service_surface-validate`,
`impress-surface-service_surface-create`,
`impress-surface-service_surface-update`,
`impress-surface-service_surface-show`,
`impress-surface-service_surface-render`,
`impress-surface-service_surface-wait`

and the other eight are actions of the `impress` domain tool —
`{"action": "surface.surface-get", "args": {…}}` (`describe: true` returns an
action's schema): `impress.surface.surface-get`, `impress.surface.surface-list`,
`impress.surface.surface-delete`, `impress.surface.surface-state-get`,
`impress.surface.surface-state-set`, `impress.surface.surface-dispatch`,
`impress.surface.surface-events`, `impress.surface.surface-examples`. With
`IMPRESS_MCP_SURFACE=flat` every verb is its own flat tool
(`impress-surface-service_surface-get`, `impress-surface-service_surface-list`,
`impress-surface-service_surface-delete`,
`impress-surface-service_surface-state-get`,
`impress-surface-service_surface-state-set`,
`impress-surface-service_surface-dispatch`,
`impress-surface-service_surface-events`,
`impress-surface-service_surface-examples`).

## The loop

1. **`surface_schema`** — the spec's JSON Schema (a real one: a validator can
   check a spec against it; every node kind, source and action is a `oneOf`
   branch), a worked example, and `rules`: the template language, widget
   ids, problem paths and params in prose.
2. **Author** the spec — no tool call, just JSON. Start from
   `surface_examples` if you like.
3. **`surface_validate`** `{spec}` — every problem, by JSON pointer and
   severity. `ok` is false (`invalid-spec`) when any problem is an `error`.
4. **`surface_create`** `{spec, name?, tags?}` — validates exactly as step 3
   does and refuses a spec with an error, listing every problem; a spec with
   warnings is stored and the warnings come back in `problems`.
5. **`surface_show`** `{id, target, app_id, device?}` — puts the surface in a
   pane of `app_id`'s window: `target` is exactly one of the suite's pane
   references — `{"id": N}`, `{"role": "detail"}`, `{"direction": "right"}`,
   `{"focused": true}` — or `{"split": {"direction": "horizontal"|"vertical"}}`
   (a new pane beside the focused one; `horizontal` is side by side,
   `vertical` stacked). It composes ordinary `layout-service` verbs — a
   surface pane is an ordinary pane whose query names a surface — and gives
   the pane one parameter per param the surface declares (see **Params**).
6. **`surface_wait`** `{id, after_seq?, timeout_ms}` — long-polls the event
   ring past `after_seq` (at most 55 s). It returns when the person does
   something that emits, or on timeout with `timed_out: true`.
7. **React**: `surface_update` `{id, spec, expected_revision}` to change what
   the person sees (validated like create; pass the `revision` you last read,
   and a write someone else made since is refused with `conflict`), or call a
   domain verb with what they chose. An open pane shows an update on its next
   render. Then `surface_wait` again from `next_seq`.

### A full round, transcript-shaped

**1. Schema.** `surface_schema {}` answers `{"ok": true, "schema": {…},
"example": {…}, "rules": {"templates", "widget_ids", "problems", "params"},
"wire_version": 1}`.

**2. Author** — the signal explorer (`crates/impress-surface/examples/signal-explorer.surface.json`):

<!-- wire: spec -->
```json
{
  "surface": "1.0",
  "name": "Signal explorer",
  "params": [ { "name": "selected", "kind": "imbib/bibliography-entry", "required": false } ],
  "state": { "freq": 1.0, "bins": 20 },
  "sources": {
    "series": { "verb": "surface-demo-service_series",
                "args": { "freq": "{{state.freq}}", "n": 512 } },
    "hist":   { "verb": "surface-demo-service_histogram",
                "args": { "values": "{{source.series.values}}", "bins": "{{state.bins}}" } },
    "papers": { "query": { "kinds": ["publication"], "sort": [ { "field": "modified", "descending": true } ], "limit": 20 } }
  },
  "root": { "column": [
    { "text": "# Signal explorer" },
    { "row": [
      { "id": "freq-slider", "field": { "slider": { "min": 0.5, "max": 8, "step": 0.5 } },
        "label": "Frequency", "bind": "state.freq" },
      { "id": "bins-slider", "field": { "slider": { "min": 4, "max": 64, "step": 1 } },
        "label": "Bins", "bind": "state.bins" }
    ]},
    { "plot": { "spec": "{{source.hist.plot}}" } },
    { "id": "papers-table",
      "table": { "rows": "{{source.papers}}", "columns": ["title", "year"],
                 "on_select": [ { "publish": {} } ] } },
    { "id": "use-bins-btn",
      "button": { "label": "Use these bins",
                  "on_click": [ { "emit": { "name": "bins-chosen",
                                            "payload": { "bins": "{{state.bins}}" } } } ] } }
  ]}
}
```

**3. Validate.** `surface_validate {"spec": …}`:

<!-- wire: result SurfaceValidateResult -->
```json
{ "ok": true, "message": "0 error(s), 0 warning(s)", "problems": [], "wire_version": 1 }
```

A spec whose button calls a verb that does not exist, and whose table forgot
its columns, comes back:

<!-- wire: result SurfaceValidateResult -->
```json
{ "ok": false, "code": "invalid-spec", "message": "2 error(s), 0 warning(s)",
  "problems": [
    { "path": "/root/column/3", "message": "`table`: missing field `columns`", "severity": "error" },
    { "path": "/root/column/4/button/on_click/0/call/verb",
      "message": "no such verb: surface-demo-service_frobnicate", "severity": "error" }
  ],
  "wire_version": 1 }
```

`path` is a JSON pointer into the spec as written (`""` is the spec itself).
A node's problem points at the node; an argument's at the argument
(`/sources/hist/args/bins`). An `error` is refused by create and update; a
`warning` — an unknown widget kind (it renders as a placeholder), a widget
with no `id`, a `{{stat.x}}` kept as text, an argument a lenient verb would
ignore — is stored.

**4. Create.** `surface_create {"spec": …, "name": "Signal explorer"}`:

<!-- wire: result SurfaceResult -->
```json
{ "ok": true, "message": "surface 'Signal explorer' (3fae1c9e-5b0e-4b8a-9d51-1c1f3d6a2b70)",
  "id": "3fae1c9e-5b0e-4b8a-9d51-1c1f3d6a2b70", "name": "Signal explorer", "revision": 1,
  "spec": { "surface": "1.0", "name": "Signal explorer", "root": { "spacer": {} } },
  "tags": [], "created": "2026-09-25T18:04:01+00:00", "modified": "2026-09-25T18:04:01+00:00",
  "wire_version": 1 }
```

**5. Show.** The arguments:

<!-- wire: args impress-surface-service_surface-show -->
```json
{ "id": "3fae1c9e-5b0e-4b8a-9d51-1c1f3d6a2b70",
  "target": { "split": { "direction": "horizontal" } },
  "app_id": "impress" }
```

and the answer:

<!-- wire: result SurfaceShowResult -->
```json
{ "ok": true, "message": "surface shown in impress's tile 12", "tile": 12, "focused": true,
  "affected_panes": [12], "app_id": "impress", "device": "Toms-MacBook", "wire_version": 1 }
```

The person now sees a title, two sliders, a histogram, a paper table and a
button.

**6. Wait.**

<!-- wire: args impress-surface-service_surface-wait -->
```json
{ "id": "3fae1c9e-5b0e-4b8a-9d51-1c1f3d6a2b70", "after_seq": 0, "timeout_ms": 30000 }
```

The person drags Bins to 40 (a `change`: it sets `state.bins`, and nothing
else runs) and clicks "Use these bins" (its `on_click` emits):

<!-- wire: result SurfaceWaitResult -->
```json
{ "ok": true, "message": "1 event(s)",
  "events": [
    { "surface": "3fae1c9e-5b0e-4b8a-9d51-1c1f3d6a2b70", "host": "Toms-MacBook", "seq": 1,
      "name": "bins-chosen", "payload": { "bins": 40 }, "at": "2026-09-25T18:04:11+00:00",
      "actor": "human" }
  ],
  "next_seq": 1, "timed_out": false, "gap": false, "wire_version": 1 }
```

`actor` is `human` for the person's click and `agent` for a dispatch over
MCP or HTTP, so a wait loop tells the person's action from its own. `gap` is
true when the ring (the last 200 events) was pruned past your cursor.

**7. React.** The agent reads `bins-chosen` and acts on it — e.g. calls
`surface-demo-service_histogram` with `bins: 40` for a report — or changes
what the person sees with `surface_update`, then waits from `next_seq`.

### A second worked example: paper triage

`crates/impress-surface/examples/paper-triage.surface.json` is the other shape
of surface: a `query` source over the person's own unread papers
(`publication`), a table, and buttons that act on whichever rows are selected
through kit verbs the whole suite already has — `triage-service_set-starred`,
`triage-service_set-flag` (`color: "red"`), `triage-service_add-tag` (`tag:
"to-read"`) — each taking one id of any record kind.

A table's `select` event carries an array of ids (the uniform shape every
widget's event has); the table's `on_select` stores it with `{"set": {"path":
"state.selected", "value": "{{event.value}}"}}`. A button's `call` names
`each: "state.selected"` and reads `{{item}}` in its `args`, so `reduce` runs
that one call once per selected id — a fan-out declaration, not a loop the
spec computes with (ADR-0033 D3). The click then `refresh`es the `papers`
source and `emit`s one `triaged` event per id, which `surface_wait` returns.
A spec that only ever wants the first selected id reads
`{{state.selected.0}}`: a numeric segment indexes an array.

## Params

A surface declares `params` (`{"name", "kind", "required"}`); `{{param.x}}`
and a query source's `{"ref": "param", "name": "x"}` read them. They are
bound per render and per dispatch, by one rule:

1. When the call passes `params` — `surface_render`/`surface_dispatch`'s
   `params` argument, `{"x": "<record id>"}` — those are the whole binding,
   and a name the spec does not declare is refused.
2. Else, when a pane shows the surface, each declared name takes that
   pane's binding of the same name. `surface_show` gives the pane one
   parameter per declared param, of the param's kind (a schema ref such as
   `imbib/bibliography-entry` is its pane-query kind, `publication`), that
   follows the window's default channel — so a paper selected in another
   pane on that channel is the surface's `param`. Re-point one with
   `layout-service_bind-param` (`{"source": "fixed", "item": "<id>"}`, or
   `{"source": "channel", "channel": {"number": 2}}`). The pane's own `item`
   binding names the surface itself and is never a param.
3. Else it is unbound: `{{param.x}}` is a placeholder, and a query source
   whose param is `required` is refused (its error is in `source_errors`),
   never run as "no filter".

A render or dispatch answers the params it used in `params`.

## `host`: which instance

A surface's working state and event ring are kept per `(surface, host)`.
`host` defaults to this device's id — the instance every pane on this device
uses (they share one state row and one runtime) — so leave it out to drive
what the person sees. Pass a `host` only for a private instance no pane shows
(a headless test, a dry run). The layout verbs call the same value `device`.

## Vocabulary reference

Every node is a JSON object with exactly one node-kind key plus the optional
common keys `id`, `label`, `help`, `when`, and — on a `field` — `bind`,
`on_change`, `on_submit`. Any other key is an error at its path. Give every
`field`, `button`, `table` and `list` an `id`: events name widgets by id, and
an unnamed node gets a positional one (`n0.2.1`: the root's third child's
second child) that changes when the spec does.

**Templates.** A string may hold references written `{{root.path}}`. The
roots are `state`, `param`, `source`, `event` (inside an action) and `item`
(inside an action with `each`). A path is dotted names; a number indexes an
array (`{{state.selected.0}}`). A string that is exactly one reference
becomes that JSON value (`"{{state.bins}}"` is the number `20`); mixed text
stringifies each reference. Anything else between double braces is text —
LaTeX and Typst are safe (`$\\frac{{a}}{b}$` renders as written) — and a
dotted one with an unknown root (`{{stat.bins}}`) is a validation warning,
since it is more likely a typo. There are no operators, conditionals or
loops.

### Containers

| Kind | Keys | Meaning |
|---|---|---|
| `column` | `[node]` | Children stacked vertically. |
| `row` | `[node]` | Children side by side. |
| `grid` | `{ columns: n, items: [node] }` | Fixed column count, items flow. |
| `section` | `{ title, collapsed?, body: node }` | A titled, optionally collapsible group. |
| `tabs` | `[ { title, body: node } ]` | One child visible at a time. |

### Widgets

| Kind | Keys | Meaning | Renderer event |
|---|---|---|---|
| `text` | `string` | Markdown, templates filled. | — |
| `table` | `{ rows, columns, on_select? }` | Tabular data. | `select` (runs `on_select`) |
| `list` | `{ rows, on_select? }` | The same, non-tabular. | `select` (runs `on_select`) |
| `plot` | `{ spec }` | A `plot-spec@1.0.0` payload, never pixels. | — |
| `image` | `{ blob? , url? }` | — | — |
| `field` | `{ text\|number\|slider\|select\|toggle\|date: options }` + `bind: "state.path"` | An editable value bound to state. | `change` — sets `bind`, then runs `on_change` |
| `button` | `{ label, on_click: [action] }` | — | `click` (runs `on_click`) |
| `status` | `{ level, message }` | — | — |
| `log` | lines | — | — |
| `kv` | pairs | Key/value display. | — |
| `divider` / `spacer` | `{}` | — | — |

A renderer event is `{"widget": id, "kind": "change"|"click"|"select"|"submit",
"value": json}` — exactly those keys:

<!-- wire: event -->
```json
{ "widget": "bins-slider", "kind": "change", "value": 40 }
```

### Sources

| Shape | Meaning |
|---|---|
| `{ "value": json }` | A fixed value. |
| `{ "verb": name, "args": object }` | A verb call; `args` may reference state, params and other sources (a cycle is a validation error). Literal arguments are checked against the verb's own input schema. |
| `{ "query": PaneQuery }` | An ADR-0031 pane query, run the way a pane's query runs; its rows are flattened (a record's payload fields beside its envelope). |

A source is exactly one of the three. Sources are cached by their resolved
arguments and re-run when an argument changes, when a store write touches a
record kind a query source reads (in this process or, through the app's
250 ms poll, another one such as `impress-mcp`), or when an action
`refresh`es them. A `verb` source declares nothing it reads, so it re-runs
only on an argument change or a `refresh`. A source that failed is not asked
again with the same arguments for 5 seconds.

### Actions

| Shape | Meaning |
|---|---|
| `{ "set": { path, value } }` | Write a value at a `state.…` path. |
| `{ "call": { verb, args, into?, each? } }` | Run a verb; `into` stores its result at a `state.…` path. |
| `{ "publish": { ids? } }` | Publish a selection on the pane's channel — `ids` a `state.…` path, else the event's value. |
| `{ "emit": { name, payload, each? } }` | Emit a named event the agent reads with `surface_events`/`surface_wait`. |
| `{ "open": { query, view_kind, target? } }` | Open a query in a pane: `target` a role, else a new split. |
| `{ "refresh": { source } }` | Re-run a source now. |

An action's `args`/`payload` may reference `{{source.…}}` (the sources as the
last render left them), `{{state.…}}`, `{{param.…}}`, `{{event.…}}`, and
`{{item…}}` under `each`. A state path — `bind`, `set.path`, `publish.ids`,
`call.into` — reads and writes by one rule: a number indexes an array, an
index out of range is refused, an array is never turned into an object, and a
missing path read is refused (it is never read as `null`). `publish` puts the
ids under the kind of `{"kind": K, "ids": [...]}` when the value at `ids` is
that object, else the surface's first declared param's kind (a schema ref
as its pane-query kind), else the generic `item`. The layout takes a
selection of any kind — a channel is keyed by kind — but a pane follows only
the kind its param declares, so a spec that publishes and declares no param is
a validation warning. An `open`'s `view_kind` must be one the layout knows
(`layout_vocabulary_json`), or validation says which it does.

`each` fans a `call`/`emit` out over an array: a literal path (never a
`{{…}}` template) whose root is `state`, `param`, `source` or `event`, which
must name an array at reduce time; an empty array runs the action zero times.

### `when`

`{ "path": "state.x" }` is truthy-gated; `{ "path": …, "equals": json }`
gates on an exact match. A node whose `when` does not hold is left out of the
render tree.

### The render tree

`surface_render` answers `{"ok", "tree", "source_errors", "revision",
"state_revision", "params", "wire_version"}`. The `tree` is
`{"root": node, "focus_order": [id…]}` — `focus_order` is the reading-order
list of field, button, table, list and tabs ids that j/k walk. A render node
is `{"id", "label"?, "help"?, "node": {"kind": …, …}}`: not the spec's shape
— the kind is a `kind` tag, every reference is resolved, and handlers are
gone (the renderer forwards raw events; `reduce` decides what they do).

<!-- wire: render -->
```json
{ "root": { "id": "n0", "node": { "kind": "column", "items": [
    { "id": "n0.0", "node": { "kind": "text", "text": "# Signal explorer" } },
    { "id": "bins-slider", "label": "Bins", "node": { "kind": "field",
      "field": { "slider": { "min": 4, "max": 64, "step": 1 } }, "bind": "state.bins", "value": 20 } },
    { "id": "n0.2", "node": { "kind": "placeholder", "unknown_kind": "sparkline",
      "reason": "this build has no 'sparkline' widget", "node": { "sparkline": { "values": [1, 2] } } } }
  ] } },
  "focus_order": ["bins-slider"] }
```

A node degrades to `{"kind": "placeholder", …}` — keeping its slot, the rest
of the tree rendering normally — when its kind is unknown to this build
(`unknown_kind` and `node`, the node's own JSON), when it could not be read
(`reason` and `node`), or when a reference in it did not resolve (`reason`
naming the source that failed and why).

### Store records

| Record | Fields |
|---|---|
| `impress/ui/surface@1.0.0` | `name`, `spec`, `tags`, `revision` |
| `impress/ui/surface-state@1.0.0` | `surface`, `host`, `state` — one row per `(surface, host)` |
| `impress/ui/surface-event@1.0.0` | `surface`, `host`, `seq`, `name`, `payload`, `at` (the author is the actor) |

### Every verb

`surface_schema`, `surface_validate`, `surface_create`, `surface_update`,
`surface_get`, `surface_list`, `surface_delete`, `surface_show`,
`surface_render`, `surface_state_get`, `surface_state_set`,
`surface_dispatch`, `surface_events`, `surface_wait`, `surface_examples`.

## Results: `ok`, `code`, and who acted

**`surface_dispatch` is `ok` only when everything happened**: the event was
reduced and every effect it produced succeeded. When the event was reduced
(its state saved) but an effect failed, the answer is `ok: false`, `code:
"effect-failed"`, `effects_failed: N`, the message naming each failure, and
the re-rendered `tree` plus every effect's own `{kind, ok, code, message}` in
`effects` — over HTTP a 422 with that same body. A source that fails while
re-rendering does not fail the dispatch; it is listed in `source_errors`.

<!-- wire: result SurfaceDispatchResult -->
```json
{ "ok": false, "code": "effect-failed",
  "message": "dispatched; 2 effect(s), 1 failed — publish: no pane shows this surface yet (surface_show has not run)",
  "tree": { "root": { "id": "go", "node": { "kind": "button", "label": "Go" } }, "focus_order": ["go"] },
  "effects": [
    { "kind": "emit", "ok": true, "message": "emitted 'went' (seq 3)" },
    { "kind": "publish", "ok": false, "code": "no-pane",
      "message": "no pane shows this surface yet (surface_show has not run)" }
  ],
  "effects_failed": 1, "revision": 1, "state_revision": 42, "wire_version": 1 }
```

`revision` is the spec's and `state_revision` the state row's, as the answer
was built. A pane compares them with the feed's notifications and does not
render its own write's echo again.

## HTTP

Each app that renders surfaces serves `/api/surface` on its automation port.
Every route runs the verb of the same name, through the same argument parser
MCP and the CLI use, and answers that verb's result unchanged, with status
200 when `ok` and otherwise the status its `code` maps to. Arguments come
from the path's id, the query string and the JSON body; one the verb does not
take is a 400 naming it. `host` defaults to the app's own instance, and
`show`'s `app_id` and `device` to the app's own window.

| Method and path | Verb | Query / body |
|---|---|---|
| `GET /api/surface` | `surface_list` | — |
| `POST /api/surface` | `surface_create` | `{spec, name?, tags?}`, or the spec itself |
| `GET /api/surface/schema` | `surface_schema` | — |
| `GET /api/surface/examples` | `surface_examples` | — |
| `POST /api/surface/validate` | `surface_validate` | `{spec}`, or the spec itself |
| `GET /api/surface/<id>` | `surface_get` | — |
| `PUT /api/surface/<id>` | `surface_update` | `{spec, name?, expected_revision?}`, or the spec with `?expected_revision=` |
| `DELETE /api/surface/<id>` | `surface_delete` | — |
| `POST /api/surface/<id>/show` | `surface_show` | `{target, app_id?, device?}` |
| `GET /api/surface/<id>/render` | `surface_render` | `?host=`, `?params=<JSON object>` |
| `POST /api/surface/<id>/dispatch` | `surface_dispatch` | `{event, host?, params?}`, or the event itself |
| `GET /api/surface/<id>/state` | `surface_state_get` | `?host=` |
| `PUT /api/surface/<id>/state` | `surface_state_set` | `{state, host?}` |
| `GET /api/surface/<id>/events` | `surface_events` | `?after_seq=`, `?host=` |
| `GET /api/surface/<id>/wait` | `surface_wait` | `?after_seq=`, `?timeout_ms=`, `?host=` |

A dispatch over HTTP is the agent's; only the app's own pane dispatches as
the person.

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

**Describing the arguments.** The trait method's `///` doc is the verb's
description. An argument is described by `///` lines on it inside
`impress_service_impl!`'s `methods = [...]` (Rust allows no doc comments on a
trait method's parameters); they become the args-struct field's doc, so the
argument's JSON-schema `description` in the MCP `inputSchema`, and its flag
help in the CLI (`-h` shows the first paragraph, `--help` all of it). An
argument whose shape a flat type cannot say — a list of objects, a whole
spec — can be a `#[serde(transparent)]` newtype over `serde_json::Value` with
a hand-written `schemars::JsonSchema` (non-referenceable, so the shape shows
inline): the schema stays precise while the verb, not serde, words the
refusal. `implore-service`'s `create_figure` (`FigureSeriesArg`,
`PlotSpecArg`) is the worked example.

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
and read the `tree` it returns — the exact node tree, with every reference
resolved and the `focus_order` computed, that the Swift renderer would
otherwise turn into a window. Driving `surface_dispatch` with a synthetic
event (`{"widget": "bins-slider", "kind": "change", "value": 40}` — the
signal explorer names its widgets) and re-rendering is how a Tier-A test
proves "moving this slider updates that plot" without ever opening the app —
the same discipline `crates/imprint-selftest` already established for
imprint's other capabilities.

## Reading what the human did

`surface_events` returns a page of a surface's `impress/ui/surface-event@1.0.0`
rows; `surface_wait(id, after_seq, timeout_ms)` long-polls the same rows and
returns as soon as a new one lands, or on timeout with nothing new — the
primitive the loop above calls "wait". Both are ordinary store reads: an agent
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
