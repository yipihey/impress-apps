# The layout + surface kit: what it is, and what leaving would take

**Decided by:** ADR-0033 D7 ("the standalone cut is decided now and executed last").
**Executed by:** plan-wave-6-tree-and-kit.md, W6.
**Enforced by:** `scripts/check-kit-deps.sh`, `scripts/check-kit-standalone.sh`, and
(the Swift half) `scripts/check-kit-packages.sh`, all run by `.github/workflows/kit.yml`.

The kit is the layer that shows a layout tree of panes and agent-authored surfaces
without knowing what a publication, a manuscript or a message is. It lives in this
repository today. It is built so that it *could* leave as its own package, and this
file states what "could" means precisely enough for a script to check it.

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
| `impress-layout` | pure | The layout tree as pure values: panes, containers, channels, the D8 verbs, patches and undo rings. |
| `impress-surface` | pure | Surfaces as pure values: spec, JSON schema, plan / resolve / reduce, `RenderTree`. |
| `surface-demo-service` | pure | The D8 demo capability, the scaffold's output and the worked example. A member of `impress-capabilities-kit`. |
| `impress-store-service` | store | Store-generic verbs (the collection kernel, triage), with no app dependency. **Added in W6:** `impress-layout-service` calls its `store_instance()` to share the one store connection, and `impress-capabilities-kit` links it. |
| `impress-layout-service` | store | The layout verbs over a store-backed live layout (`impress/ui/layout@1.0.0` rows), plus the Tier-B catalogue. |
| `impress-surface-service` | store | The surface verbs, surface records and the runtime that executes a surface's effects. |
| `impress-capabilities-kit` | store | The kit's slice of the linked `#[impress_service]` inventory (the four service crates above), so the FFI can link it without a package cycle. |
| `impress-ai` | store | Provenance-first AI conversations and the provider registry, which the FFI binds (`ai.rs`, `ai_registry.rs`, ADR-0029). **Added in W6:** it reaches only `impress-core` (sqlite) once its `executor` feature (the impel task executors, and its one path to `impel-core`) is off, which it is for every kit consumer. |
| `impress-store-ffi` | store | The UniFFI bindings the Swift side links (`ImpressRustCore`'s xcframework): store, layout, surface, and the AI conversation and registry bindings. |
<!-- kit-crates:end -->

`impress-capabilities` (the whole suite's inventory) is **not** in the kit. It links
every app's services, and it reaches the kit only through its `kit` feature, which
depends on `impress-capabilities-kit`.

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
impress-core's *domain modules*. The pane-query algebra was the one domain-shaped thing
the pure crates needed, and S0 moved it out. The store is different: the service crates
persist their state as impress-core items, and the store is a concrete
`SqliteItemStore`, not a trait the kit could own and a host could implement. D7 allows
the reach "until the store trait itself is generic". `cargo tree` cannot tell a store
import from a domain import, because both are the same crate. So the checks pin what they
can: which crates may reach impress-core at all (store tier only), and with which features.
Keeping the service crates' `use impress_core::…` lines to the store is a review rule,
not something a script checks.

## The Swift packages

The kit is also three Swift packages. The Swift half of W6 builds and polices them;
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

## What leaving would mean, mechanically

1. Copy the crates in the table plus `impress-core` into a new repository, keeping the
   `crates/<name>` layout (impress-core's tests `include_str!` an impress-layout golden
   by relative path).
2. Give it a root `Cargo.toml` whose `[workspace.dependencies]` is this repository's
   table, with path entries for crates that were not copied removed. Bring
   `rust-toolchain.toml`, `.cargo/config.toml` and `Cargo.lock` along.
3. Drop the dev-dependencies that point back here (today:
   `surface-demo-service` → `imprint-core`, used by one test,
   `tests/plot_shape.rs`, which proves the demo's plot payload deserializes as imprint's
   `FfiPlotSpec`). That test stays behind or becomes a fixture.
4. Copy the three Swift packages. `ImpressRustCore` points at the FFI's xcframework by
   relative path, which moves with it.
5. Afterwards this repository depends on the kit rather than containing it: the apps'
   `ChassisRootView` registers their view kinds into `ViewKindRegistry`, and
   `impress-capabilities` depends on the kit's inventory crate.

Steps 1–3 are exactly what `scripts/check-kit-standalone.sh` does in a scratch directory
on every CI run, so "can leave" is a command. Until the store trait is generic,
impress-core goes along and is the kit's one vendored dependency.

## How each check enforces it

| Check | What it proves | How it fails |
|---|---|---|
| `scripts/check-kit-deps.sh` | For every crate in the table, `cargo tree -e normal` reaches no workspace crate outside the kit, except `impress-core` from a store-tier crate with only the features above. A reach into a domain core (`imbib-*`, `imprint-*`, `implore-*`, `impart-*`, `impel-*`) is reported as the ask-first case. `--self-test` feeds the classifier known-bad trees, so the failure path is tested too. | `FAIL: <crate> reaches <dep>`, followed by the `cargo tree -i` path. Exit 1. |
| `scripts/check-kit-standalone.sh` | The kit plus `impress-core` compiles (`cargo check`, all targets it can) in a scratch workspace that contains nothing else from this repository. A dependency missing from the table shows up here even if the first check was never updated. | A normal (non-dev) path dependency on an uncopied crate is named before cargo runs. Otherwise the cargo error. Exit 1. |
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

