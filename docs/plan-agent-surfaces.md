# Plan — Agent surfaces (ADR-0033)

The goal: an agent in a chat can build a GUI for any Rust capability in the suite, show it
to the human in a pane, and keep working with what the human did. The layer must be clean
enough to become a standalone kit. This plan is the work breakdown; the decisions are in
[ADR-0033](ADR-0033-agent-surfaces.md); the vocabulary below is the one definition every
package implements.

Session log at the bottom (append-only).

## The vocabulary (normative)

A `SurfaceSpec` is JSON. Every node is an object with exactly one node-kind key plus the
optional common keys `id`, `label`, `help`, `when`. Paths are dotted; a string that is
exactly one `{{path}}` resolves to the JSON value at that path, mixed text stringifies.
Roots: `state`, `param`, `source`, `event`.

```jsonc
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
    "papers": { "query": { /* PaneQuery JSON */ } }
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

- **Containers:** `column: [node]`, `row: [node]`, `grid: { columns: n, items: [node] }`,
  `section: { title, collapsed?, body: node }`, `tabs: [ { title, body: node } ]`.
- **Widgets:** `text: string|{{path}}` (markdown), `table: { rows, columns, on_select? }`,
  `list: { rows, on_select? }` (rows through the host's row-style registry),
  `plot: { spec }` (a `plot-spec@1.0.0` payload), `image: { blob | url }`,
  `field: { text|number|slider|select|toggle|date: options }` with `bind: state.path`,
  `button: { label, on_click: [action] }`, `status: { level, message }`,
  `log: { lines }`, `kv: { pairs }`, `divider: {}`, `spacer: {}`.
- **Sources:** `{ "value": json }`, `{ "verb": name, "args": object }`, `{ "query": PaneQuery }`.
  Verb args may reference other sources; cycles are a validation error.
- **Actions:** `{ "set": { path, value } }`, `{ "call": { verb, args, into?: state.path } }`,
  `{ "publish": { ids?: path } }`, `{ "emit": { name, payload } }`,
  `{ "open": { query, view_kind, target? } }`, `{ "refresh": { source } }`.
- **Events (from the renderer):** `{ "widget": id, "kind": "change"|"click"|"select"|"submit",
  "value": json }`. A `field` change sets its `bind` path and then runs `on_change` if any.
- **`when`:** `{ "path": "state.x" }` (truthy) or `{ "path": ..., "equals": json }`.
- **RenderTree:** the same node shapes with every reference resolved to a value, a
  `focusable` ordering, and unknown kinds replaced by `placeholder: { kind, node }`.

Store records: `impress/ui/surface@1.0.0` (`name`, `version`, `spec`, `tags`),
`impress/ui/surface-state@1.0.0` (`surface`, `host`, `state`, `cursor`),
`impress/ui/surface-event@1.0.0` (`surface`, `host`, `seq`, `name`, `payload`, `at`).

Verbs (`impress-surface-service`): `surface_schema`, `surface_validate`, `surface_create`,
`surface_update`, `surface_get`, `surface_list`, `surface_delete`, `surface_show`,
`surface_render`, `surface_state_get`, `surface_state_set`, `surface_dispatch`,
`surface_events`, `surface_wait`, `surface_examples`.

## Work packages

Each package names its crate, its verification on Linux, and what only the Mac can prove.
`cargo test -p <crate>` per crate is the Linux gate (the workspace clippy shard cannot run
in this container; Tom's Mac and CI run `./scripts/rust-gate.sh`).

| # | Package | Depends on | Verifiable here |
|---|---------|-----------|-----------------|
| S0 | `impress-pane-query`: the algebra leaves impress-core | — | yes |
| S1 | `impress-surface`: spec, schema, validate, plan, resolve, reduce | — | yes |
| S2 | `impress-capabilities`: one inventory link + in-process call | — | yes |
| S3 | ui schemas + `schema-refs.json` for the three records | — | yes |
| S4 | `impress-surface-service`: verbs, store, runtime, Tier A | S1 S2 S3 | yes |
| S5 | cross-process liveness: `data_version` poll in the feed and in `surface_wait` | S4 | yes |
| S6 | FFI `SharedSurface` + automation routes + regenerated bindings | S4 S5 | yes (bindings match on Linux) |
| S7 | Swift `ImpressSurface` package, `surface` view kind, HTTP routes, keyboard | S6 | compiles/renders: Mac only |
| S8 | `scripts/new-capability.sh`, `docs/agent-surfaces.md`, kit-deps check | S4 | yes |
| S9 | `surface-demo-service`: the scaffold's output, the worked example, Tier A end to end | S4 S8 | yes |
| S10 | ADR, plan, capability matrix, keyboard grammar, CLAUDE.md pointers | all | yes |

### S0 — `impress-pane-query`
Move `ItemRef, Scope, Filter, RelationWalk, Direction, SortKey, PaneQuery, ParamDecl,
Bindings, KindManifest, ParamName, RecordKindId, PaneQueryError, params_in` into
`crates/impress-pane-query` (deps: serde, serde_json, uuid, thiserror, schemars optional).
`ItemId` and `EdgeType` are the two impress-core types the algebra names: the new crate
defines its own `ItemId` (a `Uuid` newtype, identical serde) and `EdgeType` (the same
enum, same serde strings), and impress-core converts at the compiler boundary. impress-core
keeps `pane_query::{compile, compile_with, CompiledQuery, SubtreeResolver, invalidation}` and
re-exports the algebra so every existing `impress_core::pane_query::X` path still resolves.
`KindManifest::builtin()` becomes `impress_core::pane_query::builtin_manifest()`; call
sites are updated mechanically. `impress-layout` depends on `impress-pane-query` only.
Verify: `cargo test -p impress-pane-query -p impress-core -p impress-layout
-p impress-layout-service -p impress-store-ffi --features native` (the last two with their
features as their CI runs them).

### S1 — `impress-surface`
The vocabulary above as Rust types with serde + schemars; `validate(&spec) -> Vec<Problem>`
(path, message); `plan`, `resolve`, `reduce` as pure functions; a `Template` resolver;
`RenderTree`. Tests: schema round-trip of every node kind; the example above validates and
renders; property test that `reduce` never loses a state key it did not set; golden
`tests/golden/signal-explorer.render.json`. No I/O, no store, no async.

### S2 — `impress-capabilities`
`crates/impress-capabilities` links every `*-service` crate once (features per service;
`full` = all, `kit` = store + layout + surface + surface-demo), exposes
`descriptors() -> impl Iterator<Item = &McpToolDescriptor>` and
`call(name, args) -> Result<Value, CallError>` (moved from impress-mcp's
`inventory_bridge`). impress-mcp and impress-cli replace their force-link lists with a
dependency on it. Verify: `cargo test -p impress-capabilities -p impress-mcp -p impress-cli`
and the MCP tool count does not change (the existing inventory test).

### S3 — schemas
`SURFACE_SCHEMA_REF`, `SURFACE_STATE_SCHEMA_REF`, `SURFACE_EVENT_SCHEMA_REF` in
`impress-core/src/schemas/ui.rs`, registered with the other two; `schema-refs.json` rows
in the same voice as the layout row; `./scripts/check-schema-refs.sh` passes.

### S4 — `impress-surface-service`
Modelled on `impress-layout-service` (store.rs, session.rs, dto.rs, service.rs, tier_a.rs,
selftest.rs). `SurfaceRuntime` owns state + source cache per (surface, host) and executes
effects through an `Executor` trait (`call_verb` via impress-capabilities, `run_query` via
the store, `publish` and `open` via layout verbs, `emit` as a store record). The verbs
listed above; `surface_show` composes `layout-service` verbs (split or take a role, set
query `item(id)`, set view kind `surface`). Tier A: every verb; the loop create → show →
dispatch(change) → render shows the new value → emit → events returns it.

### S5 — liveness
`SqliteItemStore::data_version()` (PRAGMA); the FFI feed thread polls it at 250 ms and,
on change, queries `impress/ui/*` items modified after its high-water mark and feeds them
to `QuerySubscriptions` as mutations; `surface_wait` polls the same way with the timeout.
Test: two `SqliteItemStore` handles on one file; a write through one is seen by the other's
feed within one poll.

### S6 — FFI
`SharedSurface` in `impress-store-ffi/src/surface.rs`: `open(store, host)`,
`render(surface_id, pane) -> json`, `dispatch(surface_id, pane, event_json) -> json`
(effects the host must run: `open`/`publish` return to Swift; verbs run in Rust),
`subscribe(listener)` for state changes; `surface_http(method, path, body) -> (status, json)`
so the Swift router mounts `/api/surface/*` in one line. Regenerate
`packages/ImpressRustCore/Sources/ImpressRustCore/impress_store_ffi.swift` with
`cargo rustc -p impress-store-ffi --release --features native --lib --crate-type staticlib`
then `cargo run --release -p uniffi-bindgen -- generate --library
target/release/libimpress_store_ffi.a --language swift --out-dir <tmp>` (verified 2026-09-22
to reproduce the committed file byte for byte modulo whitespace on Linux).

### S7 — Swift
`packages/ImpressSurface`: `SurfaceView(tree:)` mapping every RenderTree node to SwiftUI
(MarkdownUI for `text`, the chassis row style for `list`, imprint-core `render_plot_svg`
for `plot`, native controls for `field`), events back through `SharedSurface.dispatch`,
keyboard per the defaults in ADR-0033, `.keyboardGuarded` throughout, no `.focusable()`
around text fields. Register `ViewKindFactory(kind: .surface)` in the chassis registry;
mount `/api/surface/*` in `HTTPAutomationRouter`. Cannot compile here: written against the
regenerated bindings and the `impress-swiftui-pitfalls` skill, verified on the Mac.

### S8 — scaffold, docs, kit check
`scripts/new-capability.sh <name>` writes `crates/<name>-service` (Cargo.toml, lib.rs with
one `#[impress_service]` verb, a Tier-A test, `examples/<name>.surface.json`) and adds the
member, the workspace dependency and the `impress-capabilities` feature line.
`docs/agent-surfaces.md`: the five-verb loop with a transcript-shaped example, the
vocabulary reference, how to add a capability. `scripts/check-kit-deps.sh` runs `cargo tree`
for each kit crate and fails on `impress-core` except through the allowed path.

See [docs/agent-surfaces.md](agent-surfaces.md) for the how-to this work package produced.

### S9 — demo capability
`crates/surface-demo-service`, generated by S8's script and then filled: `series(freq, n)`
and `histogram(values, bins)` returning a `plot-spec@1.0.0` payload built with
`impress-plot`'s spec types; `examples/signal-explorer.surface.json` (the example above);
a Tier-A capability that runs the whole loop against the real inventory.

### S10 — documents
This file's log, ADR-0033, `docs/chassis-capability-matrix.md` (a `surface` row),
`docs/keyboard-grammar.md` (widget keys), and a CLAUDE.md pointer under Rust-first logic.

## Waves

1. S0, S1, S2+S3 in parallel (disjoint files; the workspace members and stub crates are
   committed first so Cargo.toml never conflicts).
2. S4, S5, S8 in parallel.
3. S6, S9 in parallel.
4. S7, S10.

## Wave 5 — surfaces reach real verbs (2026-09-23)

Decided with Tom after the Mac pass closed S0–S10. A surface rendered **in the app** can
only call the four kit crates' verbs today: the FFI links `impress-capabilities-kit`, and
the domain services cannot join it — `imbib-service` would put a second `imbib-core` in
the app (ADR-0033 D4 forbids it) and `imprint-service` depends on `impress-store-ffi`
itself (the cycle S6b split around). The same verbs are already reachable in a running
app process by a library the suite ships: `crates/impel-tools` (`ImpelTools.xcframework`)
links every `*-service` crate with their HTTP backends, and its `call_tool(name, args)`
runs the identical handler `impress-mcp` runs, reaching imbib and imprint through their
own automation routers (and refusing, named, when that app is not running). D4's
"through the app's own automation router" is therefore one callback away.

| WP | Deliverable | Files | Proof |
|---|---|---|---|
| **V1** | Host verb bridge. `impress-surface-service`: a `VerbHost` the executor and the service consult after the inventory (`call_verb` and `surface_validate`); `impress-store-ffi`: `SharedVerbHost` callback interface + `SharedStore::set_verb_host`, read lazily so a host installed after a surface was opened still serves it; Swift: `ImpelToolsFFI` exported as a product of CounselEngine, impress links it and installs an `ImpelToolsVerbHost` on its store at launch, configured with the sibling-app ports | `crates/impress-surface-service/src/{runtime,service,lib}.rs`, `crates/impress-store-ffi/src/{surface,lib}.rs`, `apps/impel/Packages/CounselEngine/Package.swift`, `apps/impress/{project.yml,macOS/Services/ImpressVerbHost.swift,…}` | Rust tests with a fake host (render through the host; validate accepts a host verb; inventory wins on a shared name; a host error is a source error, not a panic); FFI test with a Rust-implemented callback; binding regenerated at the end of the wave (declarations gained: the protocol + one method, none lost) |
| **V2** | `delete-layout`: the one verb the stack lacked — a saved layout could be overwritten but never removed. Refuses the live row and presets (`reset-preset` is theirs); FFI method and HTTP route mirroring `save_layout`; CLAUDE.md's UniFFI bullet corrected (imprint commits ONE binding) | `crates/impress-layout-service/src/{service,tier_a}.rs`, `crates/impress-store-ffi/src/layout.rs`, the layout route table, `CLAUDE.md`, `docs/chassis-capability-matrix.md` | Tier-A capability: save → listed → delete → gone → delete again refused with a message; FFI test |
| **V3** | Second worked example, on the user's own data: `paper-triage` — a `query` source over the `publication` kind, a table, star / flag / tag actions on `triage-service_*` (kit verbs, in-process everywhere) and an emitted `triaged` event; returned by `surface_examples` beside the signal explorer | `crates/impress-surface/{src/example.rs,examples/paper-triage.surface.json,tests/golden/…}`, `crates/impress-surface-service/src/{service,tier_a}.rs`, `docs/agent-surfaces.md` | golden; a dev-only loop test that seeds `imbib/bibliography-entry` rows in an in-memory store, renders, dispatches a star click and sees the row starred on re-render |
| **V4** | Mac hand-off, round 2: link + verb host live (a source naming `imbib-library-service_list-libraries` lists the libraries with imbib running and names the missing app without), `delete-layout` over HTTP, L7's Swift half (⌃⌘1–9), Enter/Escape editing watched, `list` growth | `docs/next-steps-agent-surfaces-mac.md` | the Mac agent's log entries |

Rules: V1–V3 run in parallel in one checkout on disjoint files; agents do not commit and do
not regenerate the Swift binding (both FFI changes land in one regeneration at the end);
the vocabulary and the three schema refs do not change (a gap V3 hits is logged, not
patched); `impress-store-ffi` must still not reach a domain core (`check-kit-deps.sh`).

## Session log

- 2026-09-22 — ADR-0033 written; plan opened; workspace stubs committed. Facts that shaped
  it: `McpToolDescriptor::iter()` + handler is an in-process dispatcher already (impress-mcp
  wraps it in `inventory_bridge::call_inventory_tool`); the app binary links only the layout
  service, and impress-mcp and impress-cli keep separate force-link lists; the FFI
  invalidation feed hears only its own process (no `data_version` poll anywhere), so a CLI
  `apply_layout` is invisible to the running app today; `impress-store-ffi` builds on Linux
  and `uniffi-bindgen` reproduces the committed Swift binding here, so the FFI package can be
  finished without the Mac; `plot-spec@1.0.0` and imprint-core's `render_plot_svg` are the
  plot path; `packages/ImpressChassis` exists with no dependencies and is the landing spot for
  the host when it leaves PublicationManagerCore.
- 2026-09-22 (later) — **S0–S10 implemented on this branch**, Rust half verified on
  Linux, Swift half written and awaiting the Mac. Wave order as planned; every package
  by a Sonnet agent, reviewed, verified and committed by path here. State per package:
  * S0 `impress-pane-query`, S1 `impress-surface` (67 tests, golden + property), S2/S3
    `impress-capabilities` + the three schema refs, S4 `impress-surface-service` (15 Tier-A
    capabilities + the loop against the real demo verbs), S5 the `data_version` poll (two
    handles on one file; an FFI test sees a second connection's row within one poll), S6
    `SharedSurface` + `/api/surface/*` + a regenerated binding (17 declarations gained, none
    lost; S5's `setExternalPollMs` had been missing from the binding and is now in), S8 the
    scaffold (proven by generating and testing a throwaway crate), S9 `surface-demo-service`
    (18 tests; `plot` round-trips through imprint-core's `FfiPlotSpec`), S10 the documents.
    `check-kit-deps.sh` passes with an empty allow-list: no kit crate reaches impress-core.
  * **S6b, not in the plan:** impress-store-ffi cannot depend on impress-capabilities —
    bridges → imprint-service → app-client → imbib-service-http → impress-store-ffi is a
    package cycle Cargo rejects even with the feature off. The kit list is now its own crate,
    `impress-capabilities-kit`, which the FFI links (calling `force_link()` from both
    SharedStore constructors; a bare `use` retains nothing) and which impress-capabilities
    re-exports. Each crate is named in one list again. The `full` tool count is 428 (the
    413 in S2's brief was stale), unchanged by the split.
  * **S7 written, Mac-verify pending.** `packages/ImpressSurface` (RenderTree Codable,
    `SurfaceView` mapping every kind, `SurfaceHooks` so the package stays kit-grade: markdown,
    plot and list rows are supplied by the host), `LayoutSurfacePaneView` in PMC (one
    `SharedSurface` per pane, listener bridge like the layout one, three-point trace under
    category `surface`), the `surface` factory in `ViewKindRegistry`, `/api/surface/*`
    mounted in `HTTPAutomationRouter`. Swift is not installed here; nothing of S7 has
    compiled. Known follow-ups the author flagged: dispatch `effects` (open/publish owed to
    the host) are decoded but not acted on beyond forwarding a raw `select` to
    `context.select`; `list` rows use a plain List, not the row-style registry; the two-layer
    focus model (highlight vs. real focus) is a design, not a verified behaviour.
  * The S1 golden's `plot` value is a synthetic `{"bars": [...]}`; the real demo verb emits
    imprint-core's `series` shape, which is what `PlotAutomationHandler.decodeSpec` reads, so
    the "plot shape gap" S7 reported is a fixture artefact. Worth aligning the golden to the
    real shape when S1 is next touched.
  * Not verifiable here: `cargo test -p impress-mcp` / `-p impress-cli` (the ort-sys build
    script downloads ONNX and the proxy blocks it — pre-existing, not from this branch); the
    workspace clippy shards (`./scripts/rust-gate.sh clippy auto` on the Mac is the gate).
  **Mac pass, in order:** `./scripts/rust-gate.sh fmt && ./scripts/rust-gate.sh clippy auto`;
  `cargo test -p impress-mcp -p impress-cli`; rebuild the store xcframework
  (`./scripts/build-xcframeworks.sh --fast impress-store-ffi`; the committed binding already
  matches); build PMC + ImpressSurface; `defaults write com.impress.impress
  impress.layoutTree.enabled -bool YES`, launch impress; from a chat or the CLI:
  `impress-surface-service_surface-examples` → `surface-create` → `surface-show` with
  `{"split": {...}}` and watch the pane appear (this is D6 end to end: a second process's
  write reaching the window); j/k, Enter, Escape per the grammar; a slider change is ONE
  `change` on release; `curl localhost:23125/api/surface` and `/api/surface/<id>/render`;
  `curl 'localhost:23125/api/logs?category=surface'` shows render → dispatch → display.

### 2026-09-22 — Mac pass (steps 1–3)

* **Step 1 green.** `rust-gate.sh fmt`, `rust-gate.sh clippy auto`, `cargo test -p
  impress-mcp -p impress-cli` (47 + 6 passing; the ort-sys/ONNX download Linux could not
  do is fine here), `check-uniffi-bindings.sh` (7 bindings match), `check-schema-refs.sh`
  (376 call sites, 79 refs), `check-kit-deps.sh` (impress-surface does not reach
  impress-core).
* **Not ours:** `inventory_smoke::grouped_surface_via_stdio` (an `#[ignore]`d test, so it
  is not in the gate) asserts the grouped MCP surface is under 60 tools and finds 85. Run
  from a worktree at `main` it finds 82 — the drift is main's, not this branch's; the
  branch's fifteen surface verbs and two demo verbs account for the 3. Noted and moved on
  per the hand-off's rule.
* **Step 2 green.** `build-xcframeworks.sh --fast impress-store-ffi` rebuilt the archive,
  header and modulemap; the committed `impress_store_ffi.swift` was byte-identical
  afterwards, exactly as the hand-off predicted.
* **Step 3, first real compile of S7.** `packages/ImpressSurface` built and its 7 tests
  passed with no changes — but the app did not build, and the cause was in the BINDING,
  not in Swift: `SharedSurface::surface_http`'s doc line said ``Route one `/api/surface/*`
  request``, uniffi-bindgen copies docs verbatim into a Swift `/** … */` block, and Swift
  block comments NEST. The `/*` inside `surface/*` opened a nested comment that the
  block's own `*/` closed only back to level one, so the last 13,000 lines of the binding
  — `uniffiEnsureInitialized` included — were one comment. The compiler reported
  "Unterminated '/*' comment" at the END of the file, 13,000 lines from the cause. Fixed
  at the Rust source (`…` for `*`), with a note above it, and regenerated: 3 lines
  changed, no declaration gained or lost. `xcodebuild -scheme impress` then succeeded,
  compiling `LayoutSurfacePaneView` and all of `ImpressSurface` for the first time.

### 2026-09-22 — Mac pass (step 4: the loop against the running app)

Driven from `impress-mcp` as the second process, because the CLI cannot start (see
"blocked" below). Everything below is `surface_*` over MCP against the same store the
running impress app has open.

* **D6 works, after two fixes.** `surface_create` + `surface_show` wrote tile 5 and the
  window kept rendering four leaves. Two independent staleness bugs, both now fixed and
  covered by `an_external_tree_write_tells_the_host_the_tree_changed`:
  1. the FFI feed raises `layout_changed` only when THIS handle's version counter moves,
     and an external write cannot move it — the verb ran in the other process. The
     external `data_version` poll now bumps it when the row it saw is the layout row.
  2. `impress-layout-service` caches a `LayoutSession` per (app, device) and only reads
     the row when it has none, so the reload was answered from this process's session.
     The feed calls the new `DefaultLayoutService::forget_session` first.
  After both: `layout changed elsewhere → version 1` → `layout display: version 1, 8
  tiles, focus 8, 6 leaves`, with no HTTP call to the app.
* **The verbs were not in the app's inventory.** The plot read "template path
  '{{source.hist.plot}}' did not resolve to a value" in the window while the same surface
  rendered its series from `impress-mcp`. `impress-capabilities-kit::force_link()` was an
  empty body: calling it retains the kit and nothing else, so the linker dropped the four
  service rlibs and their `inventory::submit!`s. It now takes each service constructor's
  address. Isolated with a two-node probe surface whose only source is
  `surface-demo-service_series` — placeholder in the app, data everywhere else.
* **`/api/surface/*` answered 404 on 23125.** S7 mounted them in imbib's router (23120),
  and impress — the app that renders surfaces — has the small router. They now live in
  `SharedAutomationRoutes` beside the layout routes, over a `SurfaceAutomationHost` the
  chassis registers when the kernel store opens; imbib's prefix checks call the same
  bridge. Rust still owns the route table.
* **Verified live in the window** (screenshots taken): the three-column preset plus a
  surface pane showing the heading, both sliders, the histogram (a real line over bin
  centres, from `surface-demo-service_histogram`), the table header and the "Use these
  bins" button. `GET /api/surface`, `GET /api/surface/<id>/render` and `POST
  .../dispatch` all answer on 23125 with the same shapes the verbs return.

**Blocked, and reported rather than decided (an "ask first" call):** `impress-cli` panics
at startup — clap: "command name `remove-tag` is duplicated" — so no CLI verb runs at
all. The branch's S2 switch to `impress-capabilities = { features = ["full"] }` links
imbib-service and impress-store-service together, and both declare `remove_tag`/`add_tag`
`#[impress_method]`s, which the macro projects as UNPREFIXED CLI subcommands. Main's CLI
linked a narrower set, so this is new on the branch. Fixing it means choosing a CLI
naming rule (prefix on collision, prefix always, or narrow the feature set), which is
vocabulary — see the question raised on the PR.

**Step 4, verified live in the window** (each watched in `?category=surface` as it
happened):

1. ✅ D6: `surface_create` + `surface_show` from impress-mcp grow a pane in the running
   window, no HTTP to the app. (Needed the two liveness fixes above.)
2. ✅ j/k move the widget focus ring (Frequency → Bins, visible as the focus ring).
3. ✅ One `change` per slider DRAG, on release — the applied-dispatch count went 2 → 3
   across a full drag, not one per pixel.
4. ✅ The histogram renders: a real line over bin centres from
   `surface-demo-service_histogram`, through `renderPlotSvg`. (Needed the force_link fix.)
5. ✅ `GET /api/surface`, `GET /api/surface/<id>/render`, `POST .../dispatch` on 23125,
   same shapes as the verbs. (Needed the shared-routes move.)
6. ✅ The agent-reads-the-human direction: `surface_wait --after-seq 0` blocked, the
   button was clicked in the window, and the wait returned
   `bins-chosen {"bins": 40}` at seq 1.
7. ◐ Selecting a table row dispatches `select` on `n0.3` and the publish effect runs
   ("dispatched; 1 effect(s)"), and the channel now gains a `publication` key (needed the
   kind-vocabulary fix). What is NOT yet shown is a second pane reacting: the detail
   pane's `item` is bound to the SURFACE id by `surface_show`, so it renders the surface
   row rather than the published paper. Whether `surface_show` should leave a neighbouring
   detail pane's binding alone is a design question, not a mapping bug — flagged, not
   fixed.

Also fixed while verifying: a `query` source's rows arrived as store ENVELOPES, so a
table whose columns name `title`/`year` drew empty rows; `run_query` now lifts each
payload to the top of its row, which is the shape the S1 golden already documents.

Not yet done from step 5: 5.1 (dispatch effects owed to the host) is partly proven —
`publish` runs and reaches the channel — but `open` is untested; 5.2 (list rows through
the row registry), 5.3 (golden alignment) and 5.4 (capability-matrix cell) remain.

### 2026-09-23 — the CLI collision rule, decided: prefix on collision

Tom chose (a). `CliSubcommand` now also carries `qualified_name` (the MCP spelling), and
`impress_service_core::cli::effective_names` exposes a subcommand under its flat method
name unless another linked service declares the same method — then EVERY party to the
collision is spelled `<service>_<method>`, and the bare name is exposed by nobody, so no
verb can be shadowed. Nothing that was unique changes spelling; the choice is per binary.
Pinned by `cli::collision_tests` (run with `--features cli`, which `impress-cli` turns on
for the workspace). `impress-cli` starts again: `impress surface-examples` prints the
signal explorer, and the sixteen `surface-*` verbs are listed. The colliding pairs on
`full` today: `add-tag`, `remove-tag`, `set-flag`, `set-starred` (imbib-tags-service vs
triage-service).

### 2026-09-23 — step 5 done: 5.1 (`open` and `publish` act), 5.2, 5.3, 5.4

* **5.1, two more fixes.** (i) An effect on a FRESH handle — the HTTP bridge opens one
  per request — found no pane: `Executor::pane_showing` recovers it from the layout.
  (ii) `open` then reported ok and drew nothing: `SharedLayout` and the surface executor
  each had a PRIVATE session registry, and the same SQLite connection makes
  `data_version` silent, so neither liveness path fired. `SharedStore` now owns one
  `SessionRegistry` for everything opened on it, sessions bump a write generation, and
  the layout feed watches it. Live: `POST …/dispatch {"kind":"click"}` on an `open`
  button grew the window 8 → 9 tiles at once; a table row's `publish` bound the detail
  pane's `item` to the paper.
* **5.2.** `list` rows go through `RecordViewerRegistry` (`SurfaceRecordListRows`): a
  `query` source's rows carry `schema`, `LayoutPaneRowMapper` maps them, the plain line
  stays for anything else; a list never mixes. Two Mac findings on the way: a `List`
  inside the column's ScrollView had no height (now a 240 pt floor, like the table's
  120), and it scrolls internally rather than growing — acceptable first pass, noted.
* **5.3.** Golden re-blessed with the real `series`/`plot-spec` shapes; the Swift golden
  test now decodes the real plot. **5.4.** Matrix row flipped.
* The CLI rule (a) landed first; `impress surface-*` runs from the shell again.
* **Closed the open items (2026-09-23).** Enter on the highlighted "Use these bins"
  fired exactly one `click` event; Escape on the focused Bins slider dropped real focus
  back to the highlight (captured before/after). `SurfaceRecordListRows` is a stack now,
  not a `List`: it takes the height its rows need and the surface scrolls as one
  document; single-row selection publishes the id. Still main's, not this branch's: the
  `grouped_surface_via_stdio` drift (82 tools on main against `< 60`).
