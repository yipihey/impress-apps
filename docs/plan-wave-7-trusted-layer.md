# Plan: wave 7 — the trusted layer

**Status:** planned 2026-09-25, after wave 6 (W0–W6, PRs #46–#57) and its follow-ups (#58–#62).
**Input:** [review-2026-09-25-gui-layer.md](review-2026-09-25-gui-layer.md) — a five-slice read-only
review of the layout tree and agent surfaces, every high finding independently verified. Finding ids
below (`RL-L1`, `RS-S2`, …) are that document's.
**Goal (Tom):** "The layer should become a trusted and enabling library driving much of agent-human
interactions in the future."

## What "trusted" means here

A library an agent and a person can both build on without reading its source:

1. **Nothing is lost.** Two writers (the GUI and an agent over MCP, two windows, two apps on one
   store) never silently overwrite each other; a stale cache is detected, not written back.
2. **Nothing lies.** Every refusal says what and why, in a machine-readable code as well as prose;
   `ok` means the thing happened; a skip is not a pass; the actor recorded is the one who acted.
3. **Nothing blocks the person.** No verb, HTTP round trip or store scan runs on the main actor; a
   gesture redraws only what it changed.
4. **Inputs are checked.** A typo is an error, not a silent default; a spec is validated when it is
   stored, not when it first fails to render.
5. **The contract is written down once.** Rust owns every vocabulary (view kinds, view-state keys,
   wire shapes); the docs an agent copies from are generated from or tested against the code.
6. **You can see what happened.** The Rust half logs through a facade that reaches `/api/logs`,
   with the same categories the Swift half uses.

## Decisions (Tom, 2026-09-25)

All four contract groups the review raised are approved, each to land with its callers updated in
the same PR:

- **Honest results & errors** — machine-readable error codes on every refusal; dispatch reports
  per-effect outcome; CLI exits non-zero on `ok:false`; Tier B distinguishes skipped from passed;
  human actions attributed to the human.
- **Strict agent inputs** — unknown fields in verb arguments are rejected; `surface_create`/`update`
  validate; `surface_schema` machine-checkable; the list row cap explicit and reported; `view_kind`
  checked against the vocabulary.
- **Complete & versioned wire** — HTTP `/api/surface` mirrors the verbs; one wire convention with a
  version field; revisions on layout and surface rows (optimistic concurrency); surface params
  bound; app id not hard-coded.
- **Rust owns the view-kind list** — `notes`, `bibtex`, `surface` (and the legacy `view_state`
  keys) defined once in `impress-layout`, with a test that Swift's list equals Rust's.

Still ask first: anything beyond these (new record kinds or schema refs, removing a verb, changing
what a preset contains, deleting user data).

## Work packages

Waves run in order; packages inside a wave own disjoint files and run in parallel. Every package:
one branch, one PR, pushed through the pre-push hook, the workspace gate, live proof on a running
app (on its own port — see Rules), a dated session-log entry here, and the review ids it closes.

| WP | Wave | Owns | Closes |
|---|---|---|---|
| **T1 Layout coherence** | A | `crates/impress-layout`, `crates/impress-layout-service` (session, store, service internals — not the DTOs' public shape), `crates/impress-store-ffi/src/layout.rs`, `ui_feed.rs` | RL-L1 (revision + compare-and-swap; two services on one store never lose a write), RL-L2 (the feed reacts only to this scope's live row; named layouts signal the layouts list, not the tree), RL-L4 (undo rings: no out-of-order whole-value replay), RL-L7, RL-L8, RL-L9, RL-L10 (one session registry per store per process), RL-L14, RL-L15, RL-L17 (an undecodable live row is quarantined and a fresh preset loaded, loudly), RL-L19 + SK-K19 (role resolution one rule), RL-L5 |
| **T2 Surface coherence** | A | `crates/impress-surface`, `crates/impress-surface-service` (runtime, store, executor), `crates/impress-store-ffi/src/surface.rs` | RS-S1 = SK-K1 = AC-F1 (one surface registry per store; a runtime reloads when its row moved), RS-S2 = AC-F16 (query/verb sources re-run on the invalidations that name them), AC-F2 + RS-S23 (event cursor and `seq` race-free), RS-S14, RS-S15, RS-S25, AC-F22 (surface revision), and the FFI half of SK-K2/AC-F10: `render`/`dispatch`/`surface_http` become callable off the main actor (async or explicitly background) |
| **T3 Kit behaviour** | A | `packages/ImpressLayout`, `packages/ImpressSurface` (views, controller internals), `apps/kit-demo` | PH-H1 = SK-K6 (a verb redraws only the panes Rust says it affected), SK-K3, SK-K12, SK-K11, SK-K13, SK-K14, SK-K15, SK-K17, SK-K18, AC-F17, SK-K10 + PH-H3 (several windows per process), SK-K25, SK-K7 + PH-M3 (per-pane errors), SK-K8, SK-K23, SK-K16, SK-K20 (seam tests on a real in-memory SharedLayout), SK-K21, SK-K22 |
| **T4 Host correctness** | A | `apps/imbib/PublicationManagerCore/.../Chassis/Layout/`, `ChassisRootView`, `ImbibSidebarHost` | PH-H2 (the outline pane never runs imbib's retention cleanup on mount), PH-H5, PH-M1, PH-M2, PH-M4, PH-M6, PH-M8, PH-M9, PH-M10, PH-L1…PH-L8 |
| **T5 Honest results** | B | the DTOs and HTTP/CLI edges of both services, the FFI's result types, `crates/impress-cli`, Tier B, the Swift decoders | RL-L11 + AC-F19 (error codes), RS-S12 = AC-F11, AC-F12, RL-L18, SK-K5 = AC-F5 = RS-S17 (actor), AC-F20, RL-L21, SK-K24, PH-L8, and RL-L6 = RS-S11 = AC-F18 (Rust logging through a facade bridged into ImpressLogging, same categories) |
| **T6 The written contract** | C | agent-facing shapes and docs: DTO strictness, HTTP mirror, wire versioning, schema, view-kind ownership, `docs/agent-surfaces.md` | AC-F3 + RL-L3, RS-S6 = AC-F7, AC-F8 + RS-S24, AC-F9 + RS-S13, AC-F13, AC-F14, RS-S10, RS-S7, RS-S8, RS-S9, AC-F24, AC-F21, RL-L12, RL-L20, RS-S3 = AC-F15, RS-S4 = AC-F6, PH-H4 + SK-K9 (row cap explicit), SK-K4 (one publish), PH-M7 (Rust owns view kinds), RS-S20, AC-F23 + RS-S18 + AC-F4 (docs), RS-S22 + AC-F25, RS-S19, RL-L13, RL-L16, RL-L22, RL-L23, RL-L24, RS-S21 |

Order: T1 ∥ T2 ∥ T3 ∥ T4, then T5, then T6. T5 and T6 change shapes every other package reads, so
they go after the behaviour is right. The main-actor half of SK-K2/AC-F10 (Swift awaiting the
off-main FFI) lands in T3 if T2 merged first, else in T5.

## Rules for every package

- **Rust decides, Swift maps**; a behaviour change comes with a Rust test that fails without it.
- **Regenerate bindings in the same commit** as any `#[uniffi::export]` change
  (`IMPRESS_SKIP_X86=1 crates/impress-store-ffi/build-xcframework.sh`, swiftformat off PATH).
- **Live proof on an isolated port.** Several agents run apps at once: launch your build with its
  own automation port (a launch argument, never a saved preference; #60 used 23135) and its own
  `IMPRESS_DERIVED`; never quit or relaunch an app you did not start; restore every launcher
  `build-impress-app.sh` repoints. Never mutate the user's library beyond throwaways you create
  and remove; Edit ▸ Undo in a window can reach state you did not make.
- **Gates:** `./scripts/rust-gate.sh fmt`, `clippy auto`, `cargo test` for touched crates,
  `./scripts/check-uniffi-bindings.sh`, `./scripts/check-schema-refs.sh`,
  `CARGO_TARGET_DIR=$PWD/target ./scripts/check-kit-deps.sh --strict`, `./scripts/check-kit-packages.sh`,
  `./scripts/check-chassis-deps.sh`, ImpressLayout and PublicationManagerCore `swift test` (full),
  and Tier B green on the apps you touched. The pre-push hook is never skipped.
- **Say what closed.** The PR lists the review ids it closes, and any it only narrows, with why.

## Session log (append-only)

- 2026-09-25 — Planned from the review. Tom approved all four contract groups. One review finding
  was rejected on verification (RS-S5: the out-of-process verb refusal holds, see the review).
- 2026-09-25 — **T2 (surface coherence)**, branch `claude/wave7-t2-surface`. A surface runtime
  is now a cache of the store: every call re-reads the surface row and the state row and reloads
  whichever moved (content compare, so there is no stamp to race), under a per-instance async
  lock; `SharedStore` owns one surface registry that every `SharedSurface` (panes, the HTTP
  bridge, which now keeps one handle) shares, and the process's own store's registry is
  `SessionRegistry::shared()` — RS-S1 = SK-K1 = AC-F1. Query sources re-run when a store write
  names a kind they read, in-process or by the feed's own `data_version` poll; verb sources do
  not, because nothing declares what a verb reads — RS-S2 = AC-F16. Event rows live under an id
  derived from `(surface, host, seq)`, so the primary key refuses a second writer's copy and it
  takes the next number: `seq` is unique and gap-free across connections; the cursor is the last
  row read, `gap` reports pruning, wait is capped at 55 s — AC-F2 + RS-S23. Filtered reads with
  the rare-kind hint, one state write per dispatch only when it changed — RS-S14. A failing source
  backs off 5 s per argument set (a new verb host clears it) — RS-S15. A remembered pane is
  re-checked against the layout, update keeps the row name, the publish-kind rule is in the
  vocabulary — RS-S25. Surface rows carry `revision`; `surface_update` takes
  `expected_revision` (`?expected_revision=` → 409 over HTTP) — AC-F22, narrowed: the check and
  write are serialised in-process, across processes one store read apart (the store has no
  conditional write). `render`/`dispatch`/`surface_http` are async UniFFI exports running on the
  FFI's runtime; call sites (pane, automation route + bridge, kit-demo) updated, no sync names
  kept — the FFI half of SK-K2/AC-F10. **Live** (impress from this branch, port 23151,
  `IMPRESS_DEVICE_ID=w7-t2-proof`, own DerivedData): a surface created and shown from
  `impress-cli`, updated from `impress-cli` with `expected_revision 1` → the pane re-rendered
  0.3 s later showing the new spec, a second stale update refused `conflict:`; a note artifact
  written by `impress-cli` reached the pane's query source ≈0.5 s later; a click whose `call`
  ran a 4 s verb took 4.1 s while a main-actor layout route answered in 2–20 ms and all 765
  main-thread samples sat in the event loop. Tier B 13/13 on 23151; surface self-test 15/15 (no
  live tier). Throwaways (surface, note, pane) removed; the live layout row for device
  `w7-t2-proof` remains (no verb deletes a live row). **Found:** a hard delete in another process
  still reaches no feed (RL-L7's cursor, T1's); `layout::tests::a_verb_from_another_object…`
  timed out once under a parallel `cargo test` and passed on rerun (T1's file).
- 2026-09-25 — **T1 Layout coherence** (`claude/wave7-t1-layout`). **Closed:** RL-L1, RL-L2, RL-L4,
  RL-L5, RL-L7, RL-L8, RL-L9, RL-L10, RL-L17, RL-L19 + SK-K19. **Narrowed:** RL-L14, RL-L15 (below).
  - *Revisions (RL-L1).* The live row's `logical_clock` is its revision: every operation and insert
    already stamps it, including writes from older builds, so nobody has to opt in. A session keeps
    it; `SessionRegistry::with` checks it (one indexed lookup) and reloads when the row moved,
    dropping the rings and saying so in the verb's message; every save is compare-and-swap through
    the new `SqliteItemStore::apply_operation_if_clock` (one `BEGIN IMMEDIATE` transaction). A save
    that loses the race writes nothing and the verb is applied once more on the reloaded tree.
    Revisions are not on the wire yet (no `revision` in results, no `expected_revision`): that is
    an additive step for T6's versioned wire.
  - *Whose change (RL-L2, RL-L9).* The feed moves the tree only for this scope's live row
    (`is_live`, app, device) at a revision the host has not been given; a named layout or preset of
    this app calls the new `SharedLayoutListener.layouts_changed`; other apps' rows are ignored, and
    nothing forgets sessions any more. A verb records the revision it produced under the lock the
    feed compares under; a verb whose patch is empty writes nothing and bumps nothing.
  - *Undo (RL-L4, RL-L8).* Selection patches hold only the `(channel, kind)` entries they changed;
    ring steps restore pane and window fields one by one and refuse (`UndoConflict`, entry dropped)
    when a field they would restore moved since, or when a role would be held twice. Allocators never
    roll back; rings of panes nothing can bring back are pruned after every step. A seeded property
    interleaves verbs with undo/redo across every ring (fails under blind replay).
  - *Key window and roles (RL-L5, RL-L19, SK-K19).* `Layout.current` (serialized only once a
    layout has had two windows, so the golden is unchanged); `pane_with_role` resolves in it, as
    `PaneRef::Role` and `set-role` already did; a verb that would put one role on two panes of a
    window is refused (`RoleHeldTwice`), and a split's copy just does not take the role. Swift's
    `LayoutTree.paneWithRole` is the same rule over the decoded `current`.
  - *Cursor (RL-L7).* `data_version` advances only after every read succeeded; each read reaches
    10 s behind the mark and dedupes by revision; hard deletes of layout rows are found by an id
    diff. *Registry (RL-L10).* The store `install_store` accepts uses `SessionRegistry::shared()`.
    *Quarantine (RL-L17).* An undecodable live row becomes the saved layout "Unreadable layout
    <time>" with `quarantined_reason` (declared in `schemas/ui.rs`), never deleted; a fresh preset
    loads, logged at error level.
  - *Narrowed.* RL-L14: the collection resolver is public, lazy and outside the lock, panes compile
    with no JSON round trip, saves patch the row by id with no all-rows scan; focus-only saves are
    still written (focus is what an agent reads to know what the user sees) and `finish` still
    re-reads the tree. RL-L15: the GUI reads as the human (`get_layout_as`, `compiled_pane`); the
    MCP read verbs keep their `Agent` default with no `actor` argument (an MCP shape change, T6).
    Rust log lines use the `log` facade, target `layout`, not yet bridged to `/api/logs` (T5).
  - *Tests.* impress-layout 5 new + 1 new property (`tests/undo.rs`, `verbs.rs`, `properties.rs`);
    `impress-layout-service/tests/coherence.rs` (6: two services on two connections and on one,
    the injected race, dropped rings reported, quarantine ×2); FFI: another app's write keeps the
    tree and the rings, a saved/deleted layout elsewhere signals the list only, a local verb is never
    reported back, one external write moves the version exactly once, `ui_feed` late-commit and
    delete; `tests/layout_registry.rs` (RL-L10: an inventory verb keeps the window's ⌘Z). Each new
    test was checked to fail with its fix reverted.
  - *Live (impress built from this branch, 23141, `IMPRESS_DEVICE_ID=w7-t1-proof` so the proof
    had its own live row).* (a) GUI-process verbs over `/api/layout/verb` interleaved with
    `impress` CLI writes: set-query, CLI split, close, CLI set-view-kind, focus — all five in the
    window's tree and the store, and an idle CLI write moved the window exactly one version
    (13 → 14, one "changed elsewhere"). (b) A second impress of mine (23143, device `w7-t1-other`)
    made 22 layout writes and saved/deleted a named layout while the CLI wrote impel's row: the
    first window stayed at version 50 with 0 reloads, logged "saved layouts changed elsewhere"
    twice, and its ⌘Z still restored its detail pane. implore and impel could not be used: implore
    binds its table port (23123, another agent's) and impel's server did not start in a direct
    launch. (c) Tier B 13/13, 0 skipped. Throwaway rows (four `w7-t1-*` scopes, 93 operation
    rows) removed through `SqliteItemStore::delete`; launchers restored.
  - *Gates.* `rust-gate.sh fmt`, `clippy auto` (rest shard), `check-uniffi-bindings` (7 match;
    the binding gained `layoutsChanged()`, lost nothing), `check-schema-refs`, `check-kit-deps
    --strict`, `check-kit-packages`, `check-chassis-deps`; `cargo test` for every touched crate plus
    impress-surface-service and impress-capabilities-kit; ImpressLayout `swift test` 52/0;
    PublicationManagerCore `swift test` 2133 XCTest / 0 failures (2 skipped) + 112 swift-testing.
  - *Outside "Owns", on purpose:* `impress-core` gained `apply_operation_if_clock`,
    `logical_clock_of` and `GuardedWrite` (T2 can use the same primitive for surface rows), and
    `impress-store-ffi/src/lib.rs` gained `layout_sessions_for` (expect a merge with T2).
