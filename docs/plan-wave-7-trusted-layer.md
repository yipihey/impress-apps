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
- 2026-09-25 — **T4 (host correctness).** Branch `claude/wave7-t4-host`. Swift only, in PMC; no
  Rust, kit or menu files touched.
  - **PH-H2 closed.** The retention cleanup ran from the sidebar lifecycle that the outline pane
    applies, so every chassis app ran it on every mount. It is now scheduled once per process from
    `InboxCoordinator.start`, which only imbib calls, behind the 90 s gate, inside
    `performAutomatic("retention")`, and logged under `retention`. Live: impress and imprint on
    23171–23173 logged 0 retention lines 104 s after launch, after two splits and two Tier B runs
    each. imbib on 23174 (scratch store) logged `scheduled, runs in 90 s` at launch and
    `run 1 (launch) done` 93 s later, once.
  - **Closed:** PH-H5, PH-M4, PH-M6, PH-M8, PH-M9, PH-M10, PH-L1, PH-L2, PH-L3, PH-L4, PH-L6,
    PH-L7. The outline follows a list someone else retargeted. It asks Rust's forward mapping
    which candidate row leaves the list alone, so no new FFI was needed. Live in impress, an agent's
    narrowed query deselected the sidebar and restoring it made the sidebar follow to Inbox. In
    imprint (scratch store), `info` rendered a manuscript. An external
    `prune-empty-manuscripts --apply` discarded the session with no flush, abandoned the source
    pane's editor, and the pane then said "Manuscript Not Found". An agent's `set-pane
    view_state {tab: source}` switched the info pane's tab.
  - **Narrowed:** PH-M1 (the GUI opens the right feed form; `OutlineNode::FeedForm` still carries
    no ids, and that half is `outline.rs`'s), PH-M2 (a click is all-or-nothing with a rollback,
    but still 2–3 undo entries until Rust applies the verbs as one step), PH-L5 (an undated
    surface row still shows a date, because `MailStyleItem.date` is not optional), and PH-L8 (the
    host half; the kit's `savedLayouts()` is T3's).
  - Tier B: impress 13/13 and imprint 13/13, twice each on scratch stores. One earlier imprint
    run failed `layout.outline_collection_row` once and I did not capture why; the echo fix
    followed, and no later run failed.

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
  - *Rebased on #67 (T2)*; the only conflicts were `lib.rs` (both registries now come from
    `*_sessions_for(installed)`) and this log. Re-checked on the rebased build: (a) again (all five
    writes kept, idle write 5 → 6), (b) with the CLI writing three other scopes 15 times plus a
    saved/deleted layout (window stayed at version 7, 0 reloads, ⌘Z kept), Tier B 13/13, clippy
    `rest`, ImpressLayout 52/0, PMC 2133/0. A second impress started right after the first did not
    open its window's tree (409) without activation, so the final (b) used CLI writers.
  - *Outside "Owns", on purpose:* `impress-core` gained `apply_operation_if_clock`,
    `logical_clock_of` and `GuardedWrite` (T2 can use the same primitive for surface rows), and
    `impress-store-ffi/src/lib.rs` gained `layout_sessions_for` (expect a merge with T2).
- 2026-09-25 — **T3 (Kit behaviour)**, branch `claude/wave7-t3-kit`. Swift only, no Rust or
  binding change.
  - **A verb redraws the panes Rust names (PH-H1 = SK-K6).** Each tile has its own refresh
    token in its own observable slot, and a pane host resolves on that token alone. A verb
    that leaves the tree unchanged redraws nothing. That covers an undo on an empty ring,
    which Rust answers `ok` with every pane named (`from_layout(None)`; T1 may want to
    return none). Live on impress (port 23161, throwaway pane): focus 0, 0; resize 0;
    set-query 1. PMC's `LayoutRowsPaneView` still watches the global compatibility token:
    the same set-query re-ran the list pane's query too (`pane 2 display: 85 rows`). T4
    closes that with `.onChange(of: context.refreshToken)` at `ChassisViewKinds.swift:274`.
  - **Errors are scoped (SK-K7, PH-M3):** `lastRefusal`, `paneError(for:)`, `treeError`;
    `PaneContext.loadRows() throws`. PMC's `loadFailed` read is right now because `lastError`
    is the outcome of the last call, but T4 should switch it to `context.error`.
  - **A tree that does not decode is not adopted (SK-K8).** Split children keep their
    identity by tile id (SK-K11). The divider uses a pointer style (SK-K25).
  - **Several windows (SK-K10 + PH-H3):** `LayoutTreeRuntime` registers each controller by
    identity, and the key window's is current. `didClose` is always followed by the
    survivor's `didOpen`, so PMC's unconditional `host = nil` is repaired without touching
    PMC. Not done: h/l from `ChassisRootView`'s notification bridge still applies once per
    open root (PMC's; route to the root's own controller). Detached tree windows still do
    not render (RL-L5, ask-first).
  - **⌘Z through Edit ▸ Undo (SK-K13):** `LayoutWindowResponder` sits directly before the
    NSWindow in each tree window's chain. A text first responder or a session-bearing pane
    goes to the first responder's own undo manager (a SwiftUI text field keeps its own, not
    the window's). Otherwise the chord goes to the exploration ring, and to the window's
    manager when the ring is empty. There are no ⌥⌘Z menu items: apps own their menus.
  - **Surfaces:** fields send on blur, on Return (change then submit), and before any other
    widget's action (SK-K3). A select or date field never sends unasked (SK-K12). There is no
    `.focusable()` in `SurfaceView`, and keys come through the root (SK-K14). The subscription
    is task-lifetime (SK-K18, AC-F17). A malformed node degrades alone (SK-K17). Failed
    effects are decoded, logged and shown (SK-K16). There is one request line and one result
    line per event, and identical re-renders are not adopted (SK-K15, narrowed: the FFI render
    still runs until the feed can tell a write's author). Sessions of closed panes are
    released, and all are flushed at termination (SK-K23). Seam tests run on a real in-memory
    `SharedLayout` (SK-K20). The docs were corrected (SK-K21), and there is one JSON value type
    (SK-K22).
  - **Found live:** another session's pre-fix impress (port 23125) shares impress's layout
    row and rendered my throwaway surface pane. It sent `change` for the null select and the
    date (SK-K12, before) the moment it drew them; my build sent none. The first
    `build-impress-app.sh` run installed my build over `~/Applications/impress.app` for about
    four minutes, until another session's build replaced it. Set `IMPRESS_SKIP_INSTALL=1`
    for any worktree build.
  - **Proof:** `apps/kit-demo --prove` drives real keys, clicks and menu items in-process,
    with no assistive-access grant, and all 14 claims pass. osascript has no assistive
    access here, so impress's own UI (typing, ⌘N, the menu) was not driven from outside.
    Tier B on 23161: 13/13, 0 skipped.
  - **Merged with T2 (#67):** the surface pane awaits T2's async `render`/`dispatch` and keeps
    T2's in-order dispatch chain and generation tickets, plus T3's resubscribe, per-event trace,
    effects decoding and "an identical tree is not adopted". SK-K15 stays narrowed: T2's
    revisions are on the spec row (`expected_revision`), but neither the dispatch reply nor the
    feed's `surfaces_changed(ids)` carries one, so the pane still cannot tell its own write's
    echo from an agent's. The echo render now runs off the main actor, so it no longer blocks.
- 2026-09-25 — **T5 (honest results)**, branch `claude/wave7-t5-honest`.
  - **Codes (RL-L11 + AC-F19, closed).** `impress_service_core::Refusal` is `{code, message}`;
    every layout and surface result envelope has `code` beside `message` when `ok` is false,
    over MCP, the CLI, the FFI and HTTP. Domain codes are the refusing type's serde tags
    (`LayoutError::code()`, pinned to the tag by a test; `ReduceError::code()`); the generic set
    is `invalid-argument` 400, `not-found` 404, `conflict` 409, `store-unavailable` 503,
    `store-error` 500, `host-unavailable` 503, `verb-failed` 502, `effect-failed` 422,
    `internal` 500, and every domain code 422 (`undo-conflict` 409) — one table,
    `refusal::http_status`, exported to Swift as `refusal_http_status`. Surface effects add
    `unknown-verb`, `no-pane`, `query-refused`; the FFI's resize-share `not-in-a-split`; the
    layout service `preset-not-deletable`, `preset-without-tree`; imbib `not-a-comment`.
    `SharedLayoutError.Layout` and `SharedSurfaceError.Surface` carry `code`. A refused verb's
    message names the verb and its target; detach of a whole window and move of the only
    window's root have their own variants. The surface HTTP routes no longer infer status from
    message text, and a store read error is never reported as "no surface".
  - **Dispatch (RS-S12 = AC-F11, closed).** `ok` only when the event was reduced AND every effect
    succeeded. A reduced event with a failed effect is `ok: false`, `code: "effect-failed"`,
    `effects_failed`, a message naming each failure, the tree, and each effect's `{kind, ok,
    code, message}`; HTTP 422 with that body. `source_errors` is on the dispatch result too.
    Written on `SurfaceDispatchResult` and in `docs/agent-surfaces.md`.
  - **CLI (AC-F12, closed).** `impress` exits 3 on `ok: false`, 1 when the verb could not be
    dispatched, 2 for a bad invocation; in `--help`. Merged with #73's main.rs cleanly.
  - **Tier B (RL-L18, closed).** A skip has `pass: false`; the report serializes `ok` (every
    capability ran and passed) and `all_skipped()`; the summary starts `SKIPPED:` with the URL.
  - **Actor (SK-K5 = AC-F5 = RS-S17, closed).** `SharedSurface.dispatch(…, actor:)`; the pane
    passes `human`, HTTP dispatches as `agent`, MCP verbs stay `agent` (no `actor` argument was
    added to them: an agent cannot claim to be the person). The actor reaches the state write,
    the event row (`SurfaceEventDto.actor`, from the row's `author_kind`, no schema change) and
    the layout verbs `publish`/`open` run.
  - **Fallback store (AC-F20, narrowed).** Layout and surface writes refuse `store-unavailable`
    when the store service handed out its in-memory stand-in (`is_fallback_store(&handle)`, a
    pointer compare, so no race with the global flag). Reads still proceed without saying so.
  - **Logging (RL-L6 = RS-S11 = AC-F18, closed).** `install_log_sink(sink, level)` with the
    `SharedLogSink` callback forwards `log` records of targets `layout` and `surface`;
    ImpressLayout's `RustLogBridge` appends them to ImpressLogging, installed by the first tree
    host and by imbib's surface bridge. Lines: every applied/refused verb (actor, verb, target,
    revision), cold start, external writes and deletes the feed picks up, every read the feed used
    to swallow, a subscription rebuild that could not read the tree, each failed source, each
    effect outcome, each dispatch, verb-host refusals, HTTP refusals.
  - **Also closed:** RL-L21 (snapshot is a `Result`; static manifests log and debug-assert;
    channel > 8 refused), SK-K24 (layout routes: code + status from Rust, 500 with reason for a
    failed snapshot, `version` from the same snapshot, `savedLayouts()` throws, PaneContext
    decode failures logged), PH-L8 (the kit half: `savedLayouts`, the tree route). PMC
    `LayoutRowsPaneView` watches `context.refreshToken` and shows `context.error` (the PMC halves
    of PH-H1 and PH-M3). `DELETE /api/comments/{id}` goes through imbib-core's
    `delete_comment_undoable`, which refuses any non-comment (422 `not-a-comment`) and a missing
    id (404), nothing deleted (#62's finding).
  - **Bindings.** ImpressStoreFfi gained `installLogSink`, `refusalHttpStatus`, `SharedLogSink`,
    `dispatch(…, actor:)`, `code:` on the two error cases; ImbibCore gained
    `deleteCommentUndoable(id:)`; nothing lost. After #63's toolchain move, the copied
    imprint-core, scix, implore, impel-tools and helix frameworks had to be rebuilt in the
    worktree (duplicate `_rust_eh_personality` against the rebuilt imbib-core).
  - **Live** (impress from this branch on 23191, `IMPRESS_DEVICE_ID=w7-t5-proof`, own
    DerivedData; imbib on 23192 over its `--ui-testing` scratch store with the port given as a
    launch argument). HTTP `close` of tile 4242 → 422 `unknown-tile`, prose naming the verb; op
    `delete-layout` of a missing name → 404 `not-found`; MCP `layout-service_close` → `code:
    "unknown-tile"`, `isError: true`; CLI `close` → the same JSON and exit 3. HTTP dispatch on a
    throwaway surface whose `publish` had no pane → 422 `effect-failed`, `effects_failed: 1`,
    emit ok / publish `no-pane`, tree present; its event `actor: agent`. `/api/logs?category=
    layout` carried Rust's `agent close {…} refused [unknown-tile]` and the cold start;
    `?category=surface` carried `publish effect failed [no-pane]` and `agent dispatch applied,
    but not ok [effect-failed]`. Tier B on 23191 13/13, `ok: true`, exit 0 (twice); against
    23199 12 skipped, `pass: false`, `ok: false`, exit 3. imbib: `DELETE /api/comments/<a
    library>` → 422 `not-a-comment`, the library still listed; an unknown id → 404; a real
    comment → 200. The human click: kit-demo's `--prove` sends a real in-process click to a
    surface button (osascript has no assistive access here); its event is `actor: human` and
    Rust's `human dispatch ok` line is in the Console — 16/16 claims. Throwaways removed (surface,
    the `w7-t5-proof` live row via `SqliteItemStore::delete`); launchers restored.
  - **Found.** (1) Three of T3's kit-demo claims (typing, and Undo from the Edit menu) failed three
    runs in a row on this branch AND on main (`h`/`l` of "hello" were taken as pane chords), then
    passed on a later run: they depend on nothing else on the desktop taking key focus. (2) The
    first Tier B command of the session ran without the base-URL override and drove the app on
    23125 (another session's build); its restore ran and left no saved layout behind. (3) Rust
    does not log `save_layout`/`apply_layout`/`delete_layout`/preset refusals (they do not go
    through the verb path); Swift logs them. (4) `/api/status` of impress reports the table
    port, not the bound one (the implore half of that was #73's).
  - **Gates.** `rust-gate.sh fmt`, `clippy auto` (imprint + rest), `cargo test` for
    impress-service-core, -layout, -layout-service, -surface, -surface-service, -store-service,
    -store-ffi, -cli, imbib-core (the new test); `check-uniffi-bindings` (7 match),
    `check-schema-refs`, `check-kit-deps --strict`, `check-kit-packages`, `check-chassis-deps`;
    ImpressLayout `swift test` 76/0; ImpressAutomation 14 XCTest + 63 swift-testing, 0 failures;
    PublicationManagerCore 2152 XCTest / 0 failures (2 skipped) + 112 swift-testing.
