# The layout + surface kit: what it is, and what leaving would take

**Decided by:** ADR-0033 D7 ("the standalone cut is decided now and executed last").
**Executed by:** plan-wave-6-tree-and-kit.md, W6.
**Enforced by:** `scripts/check-kit-deps.sh`, `scripts/check-kit-standalone.sh`, and
(the Swift half) `scripts/check-kit-packages.sh`, all run by `.github/workflows/kit.yml`.

The kit is the layer that shows a layout tree of panes and agent-authored surfaces
without knowing what a publication, a manuscript or a message is. The pure crates
live in [koine](https://github.com/yipihey/koine). This repository depends on that
git revision and keeps the store tier, which opens `SqliteItemStore`. This file
is still the list both checks read.

## The crate set

This table is read by both Rust scripts: the crate names between the `kit-crates`
markers are the kit, and the second column is the tier. Edit the table and the checks
change with it. They do not keep a second list.

- **pure**: may not reach any workspace crate outside the kit, and in particular not
  `impress-core`.
- **store**: may also reach `impress-core`, only with store features (see below).

<!-- kit-crates:begin -->
| Crate | Tier | Role |
|---|---|---|
| `impress-service-core` | pure | Runtime types for `#[impress_service]`: the inventory entries that become MCP tools, CLI subcommands and impel tools. |
| `impress-service-macros` | pure | The `#[impress_service]` / `#[impress_method]` proc macros that generate those entries from one trait. |
| `impress-pane-query` | pure | The ADR-0031 D2 pane-query algebra (`PaneQuery`, scopes, filters, sorts), moved out of impress-core by S0. |
| `impress-item` | pure | The item protocol below `impress-core` (K1b): `Item`, `ItemQuery`, `OperationSpec`, the `ItemStore` / `AttributedStore` traits, and the schema-ref constants. Depends on `impress-pane-query` for the edge-type conversion. `impress-core` keeps `SqliteItemStore` and re-exports this crate. |
| `impress-pane-query-compile` | pure | The pane-query compiler (`compile`, `compile_with`, `CompiledQuery`, `SubtreeResolver`) and the incremental-invalidation module, over `impress-pane-query` and `impress-item` alone (docs/plan-koine-host.md H-D2). A crate of its own because `impress-item` depends on `impress-pane-query`, so the algebra crate cannot depend back on the item protocol the compiler targets. Takes the `KindManifest` as a parameter; `impress-core` keeps `builtin_manifest()` and re-exports the compiler, so `impress_core::pane_query::compile` and `::invalidation::QuerySubscriptions` still resolve. Tested on koine's memory store. |
| `impress-schema-ref-codegen` | pure | Build-time reader of `schema-refs.json` (`IMPRESS_SCHEMA_REFS`, else the snapshot two directories up). Emits the Rust constants and the UniFFI enum text. No dependency on `impress-core`; the generated `as_core` match is source text that only `impress-store-ffi` compiles. |
| `impress-layout` | pure | The layout tree as pure values: panes, containers, channels, the D8 verbs, patches and undo rings. |
| `impress-surface` | pure | Surfaces as pure values: spec, JSON schema, plan / resolve / reduce, `RenderTree`. |
| `impress-verb-surface` | pure | `verb_surface(&VerbDescriptor) -> SurfaceSpec` and `catalogue()`: the generated form, Run button, review step and result view for every linked verb (ADR-0035 D2, plan-auto-gui-and-self-docs.md G4). Depends on `impress-service-core` (the descriptor) and `impress-surface` (the vocabulary) alone. |
| `koine` | pure | The public name of the grammar, the style sheet every frontend applies, the shared gesture (`koine::gesture`) a click or a key is, the focus cursor and key vocabulary every frontend shares (`koine::cursor`), and the frame decisions a grip, tab, edge or divider makes (`koine::frame`). `layout_verb` is the layout verb that gesture already determines. Shared slot names, one value kind per frontend, `set`/`reset` that refuse an unknown slot (`docs/plan-koine-style.md`). The style document (`koine::style_file`) is bytes; this crate does not open the file. Re-exports `impress-layout`, `impress-pane-query` and `impress-surface` always, and `impress-service-core` / `impress-verb-surface` under the default `verbs` feature, which a browser build turns off. |
| `koine-style-file` | pure | The native writer for `<workspace>/settings/koine-style.json`. Locks the path with `impress-fs-lock` and defaults to the suite group container. Depends on `koine` for the document. A host with no filesystem does not link it. |
| `koine-tui` | pure | A text performance of `RenderTree`. Line templates and indent come from the tui sheet. j/k/Enter become events; `reduce` still decides what they mean. The pane frame (grip, border, tabs) and h/j/k/l become the same `koine::gesture`, and `layout_verb` / `verb_for_pointer` / `verb_for_drag` are that gesture as a layout verb. The style command reads the file through `koine-style-file`. |
| `koine-store-conformance` | pure | The store conformance suite (koine docs/plan-koine-store.md D6): the semantics of the `impress-item` port as eighty named cases, instantiated per backend by one macro. `impress-core` runs it against `SqliteItemStore` as a dev-dependency (`tests/store_conformance.rs`), the oracle the cases were written from; koine runs it against its memory and directory backends. |
| `koine-store` | pure | The store port by name (koine docs/plan-koine-store.md D7) and, in `process`, the process-wide registry over it: the installed store with its fallback flag and lazy opener, the call-scoped `pipeline::invoke_on` store (for the concrete types `accept_override_of` knows), and the subtree resolver. `impress-layout-service` and `impress-surface-service` read it instead of `impress_store_service::store_instance`; `impress-store-service` keeps it answering its one `SqliteItemStore` (K3a). Reaches `impress-item`, `impress-service-core`, `impress-pane-query-compile` and the two koine backends. |
| `koine-store-memory` | pure | The in-memory backend of the store port. Tier A of the layout and surface catalogues runs on it, and the layout/surface tests that need only the port. |
| `impress-fs-lock` | pure | The advisory `flock` for the suite's device-local files, lifted out of `impress-ai` (ADR-0036 D-R8, plan-self-reflective-layer R1) so `impress-settings` can lock its files without a store-tier dependency. No dependencies. |
| `impress-settings` | pure | The settings registry as data (key, type, default, scope, legacy keys, doc), its per-scope files under `<workspace>/settings/`, and the generated settings pane per section (ADR-0036 D5). Reaches `impress-fs-lock` and `impress-surface` only. |
| `surface-demo-service` | pure | The D8 demo capability, the scaffold's output and the worked example. A member of `impress-capabilities`. |
| `impress-keymap` | pure | R2: the one registry of app chords (`Chord`, `Binding`, `keymap_json`, the coverage test), declared as data with no store or inventory dependency. In the kit because `impress-store-ffi` links it to export `keymap_json`. |
| `impress-scenario` | pure | S1's scenario spec and interpreter (`Scenario`, `Caller`, `run`, `validate`, `{{…}}` templating): reaches only `impress-surface` (templating) and `impress-service-core` (the shared `CapabilityResult`/`Tier` report shape) — no store, no IO, confirmed by `cargo tree -p impress-scenario` before this row was added. S2 kept it out of the kit so `impress-layout-service`/`impress-surface-service` could not reach it without an ask-first manifest change (ADR-0033 D7); Tom approved the join 2026-09-27 (docs/plan-self-reflective-layer.md S2b) so those two crates' Tier B catalogues can run their non-dynamic entries as stored `impress/scenario@1.0.0` documents through the one interpreter, like `imprint-selftest` already does. |
| `impress-store-service` | store | Store-generic verbs (the collection kernel, triage, the settings registry's `settings-service`), with no app dependency. **Added in W6:** `impress-layout-service` called its `store_instance()` to share the one store connection; since K3a it asks koine's `process` registry instead, and this crate keeps the two answering one store (`register_process_ports`, `publish`). `impress-capabilities` links it, and its `tests/surface_over_suite_store.rs` drives the surface service over the settings and triage verbs. |
| `impress-workflow` | pure | W1/W2 (plan-self-reflective-layer.md § Workflows): the workflow spec, validator, pure planner (`plan`) and pure trigger engine (`trigger::tick`). Reaches `impress-surface` only. |
| `impress-workflow-service` | store | W1/W2: the workflow verbs (`validate`/`create`/`get`/`list`/`dry-run`/`enable`/`disable`) and `WorkflowEngine` (W2's planner wired to a store — the `store`/`job`/`call` signal scans, the daemon-vs-app lease, running a fired workflow's steps through the pipeline). **Added in W2** so `impress-store-ffi` can export `workflow_tick()` — the app-side host runs the identical engine `impel-taskd`'s fourth spawn rule does. |
| `impress-layout-service` | pure | **In koine since K3b** (docs/plan-koine-host.md H-D3; `crates/impress-layout-service` there, a git dependency here). The layout verbs over a store-backed live layout (`impress/ui/layout@1.0.0` rows), plus the Tier-B catalogue. The runtime holds `Arc<dyn AttributedStore>`, an `Arc<KindManifest>` and an `Arc<dyn SubtreeResolver>` it was constructed with (H-D1; `with_subtree_resolver`, `RootOnly` by default): it asks the store only what the port answers, so a bespoke host passes its own store, manifest and resolver. The no-argument constructor the `#[impress_service]` inventory calls reads the process's own from koine's registries (`koine_store::process::{acquire_or_stand_in, subtree_resolver}`, `impress_pane_query::process_manifest::current`), which the host fills in — `impress_store_service::register_process_ports()` does it for the suite, and `CollectionSubtrees` (the resolver over `collection_ops`) lives in `impress-store-service`. Its `impress/ui/*` schema refs are `impress_item::schema::refs` constants, `actor_kind_of` is a local copy, and the loopback token is `impress_service_core::loopback_token`. It depends on no `impress-core` and no `impress-store-service`, not even in dev: Tier A and its tests run on `koine-store-memory`, and the two-writers cases on two `koine-store-dir` handles over one root (`DirStore` is `shared`; its `change_token` is the clock file); `tier_a::set_store_factory` still swaps the backend, which `impress-capabilities/tests/effects.rs` uses to run the catalogue over `SqliteItemStore`. |
| `impress-surface-service` | pure | **In koine since K3b.** The surface verbs, surface records and the runtime that executes a surface's effects. Same reach as `impress-layout-service`: `Arc<dyn AttributedStore>` and a `KindManifest` passed at construction (H-D1), the process store and manifest from koine's registries in the no-argument constructor, the `/api/surface/*` route table in `http::route` (H-D3) so the Swift FFI and a headless host call one table. No `impress-core`, no `impress-store-service`, no `impress-settings`. The two Tier A cases that needed the suite's store service (the generated settings pane and the paper-triage loop over `triage-service`) and the two tests that need imbib (a `verb` source re-running on a write to its declared read) or this repository's `docs/agent-surfaces.md` (`doc_wire`) run from `crates/impress-capabilities/tests/` (`surface_over_suite_store.rs`, `surface_verb_source_invalidation.rs`, `surface_doc_wire.rs`). |
| `impress-capabilities` | store | The one linked inventory, with only its `kit` feature selected and default features disabled (P5). |
| `impress-ai` | store | Provenance-first AI conversations and the provider registry, which the FFI binds (`ai.rs`, `ai_registry.rs`, ADR-0029). **Added in W6:** it reaches only `impress-core` (sqlite) once its `executor` feature (the impel task executors, and its one path to `impel-core`) is off, which it is for every kit consumer. |
| `impress-store-ffi` | store | The UniFFI bindings the Swift side links (`ImpressRustCore`'s xcframework): store, layout, surface, and the AI conversation and registry bindings. |
| `impress-workspace-hack` | pure | Dependency glue, no code: the cargo-hakari crate every workspace member depends on so every lane resolves one third-party feature set (plan-verb-pipeline-and-transport § Build cost, B4). In the table because every kit crate reaches it; it reaches no workspace crate. The standalone check copies it as the **stub** hakari prescribes for a crate that leaves (its generated section emptied), because the real one names the whole suite's dependencies. |
<!-- kit-crates:end -->

### Built, not linked

These koine crates are not linked by any crate in this repository, so
`check-kit-deps.sh` does not see them, and they live outside the
`kit-crates` block above on purpose: the browser pair is built by `dx` and
served as files (`GET /ui/*`, `scripts/build-koine-web.sh`), and the store
backends are what a bespoke app or a headless host opens instead of
`SqliteItemStore`.

| Crate | Tier | Role |
|---|---|---|
| `koine-dioxus` | pure | The Dioxus performance of `RenderTree` (koine `docs/plan-koine-web.md` D1–D3): one mapping to HTML, performed as the DOM in a browser, as a string on the server (`render_html`, the conformance suite's point of comparison) and as a native window. Elements are chosen by kind, every one carries its node id, the DOM tab order is the focus order, and the web sheet lands as CSS custom properties `koine.css` reads. No fetch, no store, no decision. |
| `koine-web` | host | The page (D6–D8): a router over `/surface/:id`, `/layout` and `/style`, the same-origin transport to the surface and layout routes, the wait loop, the keys through `koine::cursor`, the loopback token from the page's meta tag or a pasted value, and the layout page's pane frames through `koine::frame`. Served by every app at `GET /ui/*` (`KoineWebRoutes`); built by `scripts/build-koine-web.sh`. |
| `koine-store-memory` | pure | The in-memory store backend and `eval`, the one pure evaluation of predicates, sorts and paging for every scanning backend. Not linked here; the Apple apps keep `SqliteItemStore`. |
| `koine-store-dir` | pure | The directory store backend: one JSON file per item under `items/<schema ref>/`, blobs beside them, a journal for atomic batches, a writer lock from `impress-fs-lock`, rsync-able. Not linked here. |
| `koine-store` | pure | The port by name and a backend from a URL (`memory:`, `dir:<path>`; `sqlite:` is impress-core's to register). Not linked here. |


The inventory crate has both kit and app features. The checks select this
feature set for the standalone cut; full clients retain their app features.

<!-- kit-feature-selection:begin -->
- `impress-capabilities`: `kit` (no default features)
<!-- kit-feature-selection:end -->

## The one allowed reach: `impress-core`'s store

Every store-tier crate may depend on `impress-core`, which is not in the kit, and on
nothing else outside it. The features it may turn on are:

<!-- kit-store-features:begin -->
`sqlite` (required), `schema`, `collab`
<!-- kit-store-features:end -->

- `sqlite` is the store itself: `SqliteItemStore`, the item and schema tables, and the
  `impress/ui/*` rows the layout and surface services persist.
- `schema` derives `JsonSchema` on the kernel DTOs that cross an `#[impress_method]`
  boundary. It is a derive, not a module.
- `collab` is the Automerge document cache, which hangs off the store.
  `impress-store-service` and the FFI enable it.

**Why this reach is still here.** D7's rule is that no kit crate depends on
impress-core's *domain modules*. The pane-query algebra moved out in S0, and the
item protocol (`Item`, `ItemQuery`, `OperationSpec`, `AttributedStore`) moved to
`impress-item` in K1b. What remains is `SqliteItemStore` and the store-tier helpers around it. The layout and
surface runtimes no longer name it (they hold `Arc<dyn AttributedStore>`, H-D1), but the
process-store seam (`impress_store_service::store_instance`), the collection kernel,
the call context, the loopback token and the Tier A/B catalogues still reach
`impress-core`, so the dependency stays. `cargo tree` cannot
tell that import from a domain import, because both are the same crate. The checks
pin what they can: which crates may reach impress-core at all (store tier only),
and with which features. Keeping those imports to the store is a review rule,
not something a script checks.

## The Swift packages

The kit is also four Swift packages. The Swift half of W6 builds and polices them;
they are listed here so the manifest describes the whole kit:

- **ImpressRustCore**: the Swift face of `impress-store-ffi` (its xcframework plus
  the generated `impress_store_ffi.swift`).
- **ImpressLayout**: the layout host that moved out of PublicationManagerCore in W6:
  `LayoutModel`, `LayoutController`, `LayoutTreeView`, `PaneSessionRegistry`,
  `ViewKindRegistry` (with only the placeholder, surface and console factories built
  in; `console` is ImpressLogging's `ConsoleView`, already a kit-grade dependency),
  `LayoutTreeRuntime` (the process's live windows), `LayoutSurfacePaneView` and
  `LayoutConsolePaneView`.
- **ImpressSurface**: the `RenderTree` → SwiftUI renderer, with no logic of its own.
- **ImpressSurfaceSession**: the session that opens one generated surface
  (`SurfacePaneModel`, the invalidation feed, and the one `Sendable`
  conformance of `SharedSurface` / `SharedSurfaceChange`). Both platforms
  link it. ImpressLayout re-exports it; iOS links it directly because
  ImpressLayout is the macOS window.

Their allowed dependencies (ImpressKeyboard, ImpressTheme, ImpressLogging and each
other, nothing else) are pinned by `scripts/check-kit-packages.sh`.

## Building on the kit (Swift)

What a host writes, and what the kit already does for it. `apps/kit-demo` is the
smallest host: a scratch store, no view kinds of its own, a tree of placeholders plus
one surface pane.

- **`LayoutTreeHost(appID:services:)`** is the window's content. `LayoutHostServices`
  hands in the store (`openStore`, awaited off the first render) and two hooks.
  `didOpen` fires whenever a controller becomes this process's current tree: when it
  opens, when its window becomes key, and when the window that was current closes.
  `didClose` fires when a window goes away. While another tree is still open, the
  current one's `didOpen` follows at once, so a host may keep ONE "current tree"
  slot (PublicationManagerCore's `LayoutAutomation.shared.host`). Every window gets
  its own `LayoutController`; `LayoutTreeRuntime.shared.controller` is the key
  window's, which is what menu commands act on.
- **View kinds.** `ViewKindRegistry.builtin.register(ViewKindFactory(kind:make:))`
  once, before the first pane renders. The vocabulary is Rust's
  (`impress_layout::ViewKindId::KNOWN`, exported as `layoutVocabularyJson()` and
  read as `LayoutVocabulary.current`): a host registers only kinds from it, pins its
  registrations to it in a test, and a verb naming any other kind is refused
  `unknown-view-kind`. A stored kind nobody registered renders as the
  placeholder, which keeps the spec. A factory that owns an editor declares
  `isSessionBearing: true` and keeps its session in a `PaneSessionRegistry`. The kit
  releases a session when a verb removes its pane and flushes every registry when the
  app terminates, and ⌘Z in that pane goes to the editor's own undo manager.
- **`PaneContext`** is what a factory gets: the tile, the resolved pane, the spec, the
  controller. A pane that shows query results re-runs them when
  `context.refreshToken` moves. That token moves only when Rust names this pane (a
  verb, an invalidation, a reload). `controller.refreshToken` moves when any pane
  went stale, and watching it reloads every pane for every other pane's change.
  `context.loadRows()` throws; `context.error` is this pane's own error, never another
  pane's and never a verb refusal (that is `controller.lastRefusal`). A list pane
  reads `context.loadPage()`: one page (`LayoutController.pageSize`, or the query's
  own limit when smaller) with the query's `total` and `truncated`, and says
  "showing N of M" when the page is not the whole result. Selection is
  `context.select(ids)`: a verb, not view state. Several verbs that are one gesture
  (an outline click) go through `controller.applyAll(_:label:)`: all or none, one
  undo step.
- **Verbs are strict.** `SharedLayout.apply` parses a verb against its schema; a
  misspelt field is refused `invalid-argument` naming it. A pane reference is
  written one way, exactly one of `{"id": N}`, `{"role": "…"}`,
  `{"direction": "…"}`, `{"focused": true}` (`LayoutPaneRef.json`). ⌃⌘S is the
  `set-collapsed` verb (`controller.toggleRole`), which restores the pane's own
  share.
- **Keys.** The window root is the one `.focusable()` in the tree (pitfalls rule 5).
  A pane never adds its own. It registers
  `controller.setKeyHandler(for:owner:)` for the root's j / k / ⏎ / ⎋ instead, which
  is how the surface pane walks its widgets. ⌘Z / ⇧⌘Z reach the tree from the Edit
  menu through a responder the kit installs per window (ADR-0031 D7); a host mounts
  no command for it.
- **`SurfaceHooks`** is how a surface's `text`, `plot` and `list` widgets get suite
  machinery the kit may not depend on. `.plain` is the kit's default;
  PublicationManagerCore re-registers `surface` with `LayoutSurfaceHooks.chassis`.
- **One `SharedSurface` per process** is where review SK-K1 points, and wave 7's
  surface-coherence package owns it. Today each surface pane opens its own handle on
  the controller's store.

## What leaving meant, mechanically

The pure crates are https://github.com/yipihey/koine, pinned by `rev` in this
repository's `[workspace.dependencies]`. The store-tier crates stay here: they
open `SqliteItemStore`. `scripts/check-kit-standalone.sh` checks that pin.

1. Copy the pure crates in the table into a new repository, keeping the
   `crates/<name>` layout. The store-tier crates stay here: they open
   `SqliteItemStore`. That copy is the koine repository.
2. Give it a root `Cargo.toml` whose `[workspace.dependencies]` is this repository's
   table, with path entries for crates that were not copied removed. Bring
   `rust-toolchain.toml`, `.cargo/config.toml` and `Cargo.lock` along.
3. Drop the dev-dependencies that point back here (today:
   `surface-demo-service` → `imprint-core`, used by one test,
   `tests/plot_shape.rs`, which proves the demo's plot payload deserializes as imprint's
   `FfiPlotSpec`). That test stays behind or becomes a fixture.
4. Take `impress-workspace-hack` along as a stub: its `Cargo.toml` with the section
   between `### BEGIN HAKARI SECTION` and `### END HAKARI SECTION` emptied, which is
   what `cargo hakari disable` writes. The generated section lists the whole suite's
   dependencies; the new repository runs `cargo hakari generate` for its own.
5. Copy the four Swift packages. `ImpressRustCore` points at the FFI's xcframework by
   relative path, which moves with it.
6. Afterwards this repository depends on the kit rather than containing it: the apps'
   `ChassisRootView` registers their view kinds into `ViewKindRegistry`, and
   `impress-capabilities` depends on the kit's inventory crate.

Steps 1–4, for the pure crates, are what `scripts/check-kit-standalone.sh` does
in a scratch directory on every CI run, so "can leave" is a command. Layout
and surface persistence speak `AttributedStore` (`docs/plan-koine-separation.md`,
K1). The item, query and operation types live in `impress-item` (K1b). The
store-tier crates still construct `SqliteItemStore` and stay in this
repository; the scratch workspace does not copy them or `impress-core`.

## How each check enforces it

| Check | What it proves | How it fails |
|---|---|---|
| `scripts/check-kit-deps.sh` | For every crate in the table, `cargo tree -e normal` reaches no workspace crate outside the kit, except `impress-core` from a store-tier crate with only the features above. A reach into a domain core (`imbib-*`, `imprint-*`, `implore-*`, `impart-*`, `impel-*`) is reported as the ask-first case. `--self-test` feeds the classifier known-bad trees, so the failure path is tested too. | `FAIL: <crate> reaches <dep>`, followed by the `cargo tree -i` path. Exit 1. |
| `scripts/check-kit-standalone.sh` | The pure crates compile (`cargo check`, all targets it can) in a scratch workspace that contains nothing else from this repository, and does not contain `impress-core`. A dependency missing from the table shows up here even if the first check was never updated. | A normal (non-dev) path dependency on an uncopied crate is named before cargo runs. Otherwise the cargo error. Exit 1. |
| `scripts/check-kit-packages.sh` (Swift half) | The Swift packages depend on nothing outside their allowlist. | `DISALLOWED … dependency`. Exit 1. |

## Open findings

A crate listed here breaks D7 today. Both scripts read this block. Each one prints a
`KNOWN VIOLATION` line for the listed reach instead of failing, and **fails** if the
reach changes in any way: if it grows, or if it disappears (then the entry is stale and
has to go). `--strict` makes both scripts treat a listed finding as a failure.

<!-- kit-open-findings:begin -->
<!-- kit-open-findings:end -->

**Resolved in W6 (decided by Tom, 2026-09-24): `impress-store-ffi` no longer reaches a
domain core.** It reached `impel-core` (→ `impress-domain`) through `impress-ai`, whose
only use of it was `impress_ai::executor`, the impel `TaskExecutor` impls the FFI never
calls. That module and the `impel-core` dependency are now behind `impress-ai`'s opt-in
`executor` feature, which only `impel-taskd`, the executors' one user, turns on.
`impress-ai` itself joins the kit's store tier (above). The edge had existed since
73d36cd9 (2026-08-06); `docs/plan-agent-surfaces.md`'s wave-5 rule that the FFI "must
still not reach a domain core" was written before any check covered the FFI, and is now
enforced by `check-kit-deps.sh` in strict mode.

