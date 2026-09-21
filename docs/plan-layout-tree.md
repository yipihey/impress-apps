# Plan: the layout tree (ADR-0031)

Goal: **every impress window is a Rust-owned tree of query-addressed panes, rendered by
Swift, driven by `layout-service` verbs, persisted as `impress/ui/layout` items, with the
current three-column chassis reproduced as a preset.** Done means a user (or an agent
over MCP) can split, re-arrange, retype and re-link panes in imbib, save the layout, and
recall it on another device, with the ADR-0031 invariants held and Tier A tests covering
every verb.

Work packages are ordered by dependency. Rust packages build and test on Linux CI; the
Swift host needs a Mac.

| WP | Deliverable | Depends on | Proof |
|---|---|---|---|
| **L0** | `impress_core::pane_query`: `PaneQuery`, `Scope`, `Filter`, `RelationWalk`, `ParamRef`, `SortKey`; `compile(&PaneQuery, &Bindings, &KindManifest) -> ItemQuery`; serde + schemars | — | unit tests: every current sidebar node expressible and compiles to the same `ItemQuery` the chassis issues today; unknown kind / unbound required param are typed errors |
| **L1** | `crates/impress-layout`: `Layout`, `Tile`, `Container`, `PaneSpec`, `ParamBinding`, `ChannelState`; arena tree with normalization; reference resolution (id / role / direction); focus walk; every D8 verb as a pure function `apply(&mut Layout, Verb) -> Result<Patch, LayoutError>`; three undo rings; serde round-trip | L0 (types only) | property tests: normalization idempotent, verbs invertible via recorded patches, focus walk total; golden JSON |
| **L2** | `impress_core::schemas::ui`: `impress/ui/layout@1.0.0`, `impress/ui/preset@1.0.0` registered from `register_core_schemas`; `schema-refs.json` updated; retention/scope per ADR-0019 D2 | L1 | `./scripts/check-schema-refs.sh`; store round-trip test |
| **L3** | `crates/impress-layout-service`: `#[impress_service] LayoutService` exposing the D8 verbs over a store-backed `Layout` (load / apply / persist as ephemeral or durable ops); registered in `impress-mcp` and `impress-cli` | L1, L2 | inventory test lists every verb; Tier A capability catalogue (`impress-layout-selftest` or a `tier_a` module) runs every verb headless |
| **L4** | Incremental query results: `impress_core` event bus delivers per-query invalidation (schema prefix + predicate touch), `PaneQuery` subscriptions re-run only affected panes | L0 | test: a mutation on kind A does not re-run a pane scoped to kind B |
| **L5** | `impress-store-ffi` exports: `SharedLayout` (open, apply verb, snapshot, subscribe), `SharedPaneQuery` compile/run | L1, L3, L4 | UniFFI bindgen builds; Swift smoke on Mac |
| **L6** | Swift host: `LayoutTreeView` walking the tree (`Linear` → `NSSplitView`, `Tabs` → tab strip, `Grid`), `ViewKindRegistry` extending `RecordViewerRegistry` with `outline`, `list`, `info`, `pdf`, `notes`, `bibtex`, `editor`, `legacy`, `placeholder`; roles wired to ⌃⌘S / ⌘0 / ⌥⌘0; h / l over the tree; three undo stacks routed by focus | L5 | Mac build; UI test: split, move, retype, save, recall |
| **L7** | Presets as store records: imbib Triage / Reading / Full, imprint Writing, implore, impel, impart defaults; ⌃⌘1–9 applies; ADR-0019 D5 importer migrates `PaneLayoutState` | L3, L6 | preset parity test: default preset renders the same sections as today's `AppShellConfiguration` |
| **L8** | Migration one leaf at a time: figures, mail, agents → outline sidebar → publications → manuscripts; delete `PaneLayoutState`, `SidebarComposition`, per-app `FocusedPane` enums | L6, L7 | capability matrix rows re-proven per converted kind |

Rules for every package: the workspace gate (`cargo fmt --all --check`; `cargo clippy
--workspace --all-targets --features native -- -D warnings`) before push; `schema-refs.json`
true in the same PR as any new record kind; a Tier A capability or unit test per verb; the
three-point trace on anything persistence-touching; no new SwiftUI layout state.

Session log (append-only):

- 2026-09-21 — ADR-0031 accepted; L0 and L1 started in parallel (Opus 5 coding agents).
- 2026-09-21 — L3 landed: `crates/impress-layout-service` — the 30 D8 verbs plus
  `layout-selftest-service_run-selftest` as `#[impress_service]` methods over a
  store-backed live layout per `(app_id, device)`, registered in `impress-mcp`
  and `impress-cli`. Gesture writes are `Ephemeral` operations, commits
  `Durable`; the 32-capability Tier A catalogue runs headless as `cargo test`.
