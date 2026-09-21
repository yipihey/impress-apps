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
| **L6** | Swift host: `LayoutTreeView` walking the tree (`Linear` → `NSSplitView`, `Tabs` → tab strip, `Grid`), `ViewKindRegistry` extending `RecordViewerRegistry` with `outline`, `list`, `info`, `pdf`, `notes`, `bibtex`, `source`, `legacy`, `placeholder`; roles wired to ⌃⌘S / ⌘0 / ⌥⌘0; h / l over the tree; three undo stacks routed by focus | L5 | Mac build; UI test: split, move, retype, save, recall |
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
- 2026-09-21 — L7 (Rust half) landed: the shipped presets are a data table
  (`crates/impress-layout-service/src/presets.rs`) and
  `impress/ui/preset@1.0.0` rows seeded under deterministic UUIDv5 ids, so
  re-seeding never duplicates and a user's edit survives. Ten presets — a
  default per app reproducing `AppShellConfiguration`'s `defaultSection` /
  `defaultDetailTab`, plus imbib Triage / Reading / Full and imprint Writing
  — each carrying its app's sections as named `PaneQuery`s, with the five
  that are not values in the algebra (sharedWithMe, SciX libraries, the
  online search forms, tags, reviewQueue) named in `MATERIALIZE_FIRST` with
  the reason. Four verbs (`list-presets`, `apply-preset`, `save-preset`,
  `reset-preset`), `apply_preset` recording a `DerivedFrom` edge from the
  live row; ⌃⌘1–9 now numbers ONE union — presets in table order, then named
  layouts. **"Hidden" is not share 0.0**: `Verb::Resize` refuses a
  non-positive weight and `normalize` rewrites one to a full column, so a
  hidden pane carries `HIDDEN_SHARE` (1e-4, sub-pixel but normal) and keeps
  its query, role and session — ⌘0 is a resize, not a split. 37 Tier A
  capabilities.
- 2026-09-21 — L6 landed (Swift host): `Chassis/Layout/{LayoutModel,
  LayoutController,ViewKindRegistry,LayoutTreeView,PaneSessionRegistry}.swift`
  — a decode-only Swift mirror of the layout wire value, a `@MainActor
  @Observable LayoutController` through which every gesture goes as a
  `LayoutVerb`, a `ViewKindRegistry` (`outline` / `list` / `info` / `legacy` /
  `placeholder` rendered; `pdf` / `notes` / `bibtex` / `source` registered as
  placeholders for L8), a recursive tree renderer with N-child splits, tab
  strip, grid, collapsed-share panes and a focus ring, and the D6 session LRU.
  Roles are wired to ⌃⌘S / ⌥⌘0 / ⌘0, h / l to `focus_direction`, and the three
  undo rings to ⌘Z / ⇧⌘Z / ⌥⌘Z / ⌥⇧⌘Z. Off in every preset.

  **UNVERIFIED ON A MAC.** It was written on Linux, where no Swift compiler
  and no UniFFI bindings exist: the generated `SharedLayout` API it codes
  against was read from L5's Rust source, not from bindings. Nothing in it has
  been compiled, let alone run. The verifier must, in this order:

  1. `IMPRESS_SKIP_X86=1 crates/impress-store-ffi/build-xcframework.sh`
     (regenerates `packages/ImpressRustCore/Sources/ImpressRustCore/impress_store_ffi.swift`,
     which today still predates L5 — `SharedLayout` is absent from it, so PMC
     does not compile until this runs);
  2. `cd apps/imbib/PublicationManagerCore && swift build && swift test`
     (the four new suites are FFI-free: golden decode, verb JSON, registry
     fallback, session LRU);
  3. `defaults write com.impress.imbib impress.layoutTree.enabled -bool YES`,
     launch imbib, and confirm the three-column preset renders, h / l moves
     the focus ring, ⌃⌘S collapses and restores the navigator, a divider drag
     emits exactly ONE `resize` verb on mouse-up, and
     `curl 'http://localhost:23120/api/logs?category=layout&limit=50'` shows
     the mutation / applied / display trace for each. Then
     `defaults delete com.impress.imbib impress.layoutTree.enabled` and
     confirm the flagged-off build is unchanged.

  Known L6 gaps, both for L7: the tab strip's ACTIVE child is derived from
  focus because D8 has no `set-active-tab` verb, and `PaneSessionRegistry`
  ships unused (no session-bearing view kind is ported yet).
- 2026-09-21 — Status at the end of the first autonomous session. L0–L5 and
  the Rust half of L7 are committed and verified headless on Linux (per-crate
  fmt / clippy / tests; `./scripts/check-schema-refs.sh`). The workspace-wide
  clippy gate could not run in the container because `ort-sys` downloads an
  ONNX binary the proxy blocks — run it on CI or a Mac. L6 is committed but
  UNCOMPILED (see the verification sequence above). The tab-strip gap is
  closed in Rust: `Layout::reveal` now activates every Tabs ancestor of the
  focused leaf, so the Swift derivation is redundant and can read `active`.
  The view kind for the editor is `source` everywhere. Not started: the Swift
  half of L7 (the ADR-0019 D5 importer of `PaneLayoutState` and wiring ⌃⌘1–9
  to `applyLayout(ordinal)`), and L8, both of which need the Mac loop first.
  Follow-ups recorded by the agents and worth a decision: `SharedLayout` holds
  its own session registry, so an in-process MCP host would not share undo
  rings (`open_shared` constructor if that ever matters); `list_presets` and
  ordinal recall seed shipped presets on read, so the caller owns the 90 s
  startup guard; `store_metadata.origin_id` should replace the hostname
  device id once exposed from impress-core.
