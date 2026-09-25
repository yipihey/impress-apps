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
- 2026-09-25 — **T6b (the written contract, layout half)**, branch `claude/wave7-t6b-layout`.
  - **Strict inputs (AC-F3 + RL-L3, closed for layout).** `impress_service_core::strict` checks an
    argument object against the schema schemars already derives (the MCP `inputSchema`), through
    `$ref`s and a tagged enum's branch; `impress_service_impl! { strict_args = true }` (opt-in per
    service, so no other service changed) answers a refused argument as a result,
    `{ok: false, code: "invalid-argument", message, wire_version}`, so MCP carries it with
    `isError` and the CLI exits 3. The FFI's `apply` (and `/api/layout/verb`) parses the same way
    against `Verb`'s schema. One pane-reference spelling everywhere: exactly one of `{"id": N}`,
    `{"role"}`, `{"direction"}`, `{"focused": true}` (`PaneRefWire`, `deny_unknown_fields`); the
    tagged `{"ref": "id", "tile": N}` is retired with no transition (nothing persisted it), and
    `{}` names nothing. Persisted rows stay lenient.
  - **Vocabulary (PH-M7 + RL-L12, closed).** `ViewKindId::KNOWN` = outline, list, info, pdf,
    notes, bibtex, source, plot, console, surface, legacy, placeholder; `set-view-kind`,
    `set-pane` and a split's new pane refuse any other (`unknown-view-kind`, 422); stored trees
    still load. `impress_layout::view_state` spells `section`/`node`/`reason`/`tab` once.
    `layout_vocabulary_json()` exports kinds, session-bearing kinds, keys and the wire version;
    `ViewKindRegistryTests` (kit spellings, `LayoutViewStateKey`) and `ChassisViewKindsTests`
    (kit + chassis registrations) compare against it. A query naming an unknown record kind is
    refused at verb time on every path (`check_verb`). **Narrowed:** a `select`'s kind is not
    checked — a surface `publish` may carry an unknown kind by the surface contract (`item`),
    and refusing it broke `impress-surface-service`'s coherence test; that is T6a's contract.
  - **Wire (AC-F24, layout half closed).** Every layout result carries `wire_version: 1`
    (`impress_service_core::wire`); every `/api/layout/*` body is snake_case,
    `{ok, wire_version, …}` or `{ok: false, wire_version, code, message}`, the `status`/`error`
    pair and `affectedPanes`/`changedTiles`/`lastRefusal` gone; no tree is 409 `no-layout-tree`.
  - **Revisions (RL-L1 wire half, closed).** Verb results, `get_layout`, the FFI snapshot and
    applied verb, and the HTTP bodies carry `revision` (the live row's `logical_clock`); the 24
    verbs that move the live tree take `expected_revision` (MCP/CLI argument; a key in the verb
    object over FFI/HTTP) and refuse `conflict`, writing nothing, when it is stale — checked under
    the session lock after the registry's own reload, so the CAS retry also refuses.
  - **Rows (PH-H4 + SK-K9, closed).** `run_pane` returns `SharedPaneRows {rows, total, offset,
    limit, query_limit, truncated}`: the page is the kit's 500 or the query's own limit when
    smaller (the query's limit is honoured; it used to be replaced), the total is counted only
    when a page comes back full. The list pane shows "Showing 500 of 6,867" and a Show More
    button and logs `display: 500 of 6867 rows (truncated; 1 page(s))`.
  - **Also closed:** RL-L20 (`Verb::Split.new` optional, duplicated in `apply`; `bare_split` and
    the FFI's verb→method translation table gone — the FFI applies the `Verb` through
    `apply_verb_as`), RL-L13 (`set-collapsed {target, collapsed?}` verb, MCP/CLI too: hide/show
    decided under the lock, the pane's spec remembers `collapsed_share` so showing restores it
    exactly; `resize_share` reads its shares under the lock; Swift's sibling average deleted),
    RL-L16 (`SHIPPED_FINGERPRINTS`: FNV-1a of every shipped revision, a test that fails with the
    line to add, upgrade from any older revision, a log line when a row is left alone), RL-L15
    (decided and documented: an MCP/CLI read's cold start is the agent's; reads take no `actor`),
    AC-F20 read half (`store: "fallback"` and a FALLBACK STORE message prefix on every read),
    PH-M1 wire half (`OutlineNode::FeedForm {feed, library}`; T4's Swift route map deleted),
    PH-M2 Rust half (`apply_all` / `applyAll`: an outline click, its focus included, is one
    gesture and one undo step, all or none; the Swift rollback is gone). `save_layout`,
    `apply_layout`, `apply_preset`, `delete_layout`, `save_preset` and `reset_preset` log their
    outcome under `layout`. impress's `/api/status` reports the bound port. imbib-cli and
    imprint-cli exit 3 on `ok: false`.
  - **Skipped, no longer applied on main:** RL-L22 (store.rs "Startup" and session.rs `forget`
    were already rewritten), RL-L23 (both exhaustive `From`s and a round-trip test exist).
  - **Narrowed:** RL-L24 — `delete_layout` is logged with its actor, but the row is a hard delete,
    its operation rows cascade and the sync tombstone has no author and is pruned: a durable
    "who deleted it" needs a retire-instead-of-delete or an author on tombstones (a store
    decision). Tier B's restore now says the undo rings were reset.
  - **Bindings.** ImpressStoreFfi gained `applyAll`, `layoutVocabularyJson`, `SharedPaneRows`,
    `revision` on `SharedLayoutSnapshot`/`SharedAppliedVerb`; `runPane` returns
    `SharedPaneRows`. Nothing else lost; `check-uniffi-bindings` 7 match.
  - **Shared with T6a:** `impress-service-core` (`strict.rs`, `wire.rs`, two `lib.rs` lines),
    `impress-service-macros` (the `strict_args` key), and six `None` arguments in
    `impress-surface-service/src/runtime.rs` for `expected_revision`. Expect a merge.
  - **Live** (impress from this branch, port 23211 by launch argument,
    `IMPRESS_DEVICE_ID=w7-t6b-proof`, own DerivedData, launcher restored): `/api/status` said
    `port: 23211`; `/api/layout/tree` keys `app, focused, ok, revision, version, wire_version`;
    a verb with `{"ref": "role"}` → 400 `invalid-argument` naming `ref`; `view_kind: editor` →
    422 `unknown-view-kind`; the list pane logged `pane 2 display: 500 of 6867 rows
    (truncated; 1 page(s))` (the footer is below row 500; osascript has no assistive access
    here, so it was not scrolled to). Tier B 14/14, 0 skipped, including the new
    `layout.wire_contract` (revision moved, stale → 409, nothing written) and
    `layout.hidden_share` over `set-collapsed` (1 → 0.0001 → 1). MCP (`impress-mcp` over stdio,
    scratch store): `layout-service_close` with the retired spelling → `isError: true`,
    `invalid-argument`. CLI (scratch store): the same refusal, a typo inside `query`, a stale
    `--expected-revision` (`conflict`) and `editor` all exit 3. imbib-cli `eink-remove-device`
    and imprint-cli `project-tree` of nothing (scratch `HOME` and store) exit 3. The proof's
    live row was removed through `SqliteItemStore::delete`; Tier B removed its own.
  - **Gates.** `rust-gate.sh fmt`, `clippy auto` (imprint + rest), `cargo test` for
    impress-service-core, -service-macros, -layout, -layout-service, -store-ffi,
    -surface-service, -cli (all green); `check-uniffi-bindings`, `check-schema-refs`,
    `check-kit-deps --strict`, `check-kit-packages`, `check-chassis-deps`; ImpressLayout 79/0;
    ImpressAutomation 63/0; PublicationManagerCore 2154 XCTest / 0 failures (2 skipped) + 112
    swift-testing. After #63's toolchain move the copied imbib-core, imprint-core, scix,
    implore, impel-tools, helix and impart frameworks had to be rebuilt in the worktree.
- 2026-09-25 — **T6a (the written contract, surface half)**, branch `claude/wave7-t6a-surface`.
  - **Strict agent inputs (AC-F3, RS-S6 = AC-F7, AC-F13, AC-F14; RL-L3's surface half).** Every
    surface verb is `strict_args`: an unknown field anywhere in its arguments — `target`,
    `event`, the top level — is `ok: false`, `invalid-argument`, serde's message naming the field,
    over MCP (`isError`), the CLI (exit 3) and HTTP (400); `{"id": 7}` as a target no longer opens
    a split. A target is exactly one of tile/role/split; `from_focused: false` is refused. The spec
    is an argument read by the verb (`SpecArg`), so `validate_json` locates a structural mistake
    and a key nothing reads; problems carry `severity` (an unknown kind is a warning).
    create/update run the same check as validate — pure problems, verb existence, each verb's
    literal arguments against its own input schema — and refuse `invalid-spec` with every problem;
    warnings are stored and listed.
  - **Machine-checkable schema (AC-F8 + RS-S24).** Node and Source are hand-written `oneOf`s (one
    branch per kind with `additionalProperties: false`, the unknown-kind branch last), body types
    carry schema-only `deny_unknown_fields`, `surface` is `const "1.0"`, PaneQuery's keys are
    closed, rustdoc links are stripped, and `rules` says what a schema cannot. `jsonschema`
    validates both shipped examples and rejects ten known-bad specs.
  - **HTTP mirrors the verbs (AC-F9 + RS-S13).** Every `/api/surface` route runs the verb through
    `call_verb_on` — the macro's own args struct, plus a top-level check against the published
    schema — and answers its result unchanged; show, state get/put, wait and examples are new;
    render answers the envelope with `source_errors`. The table is in docs/agent-surfaces.md.
  - **Wire (with T6b).** Every result carries `wire_version: 1`; refusals are `{ok: false, code,
    message}`; `invalid-spec` is 422. `after_seq` is optional on events/wait.
  - **Params bound (RS-S3 = AC-F15).** Explicit `params` win; else each declared param takes the
    showing pane's binding of the same name; else unbound (a `required` one refuses the query
    rather than meaning "no filter"). `surface_show` gives the pane one param per declared param,
    following the window's channel; schema refs compile as their pane-query kind.
  - **App id (RS-S4 = AC-F6).** `surface_show` requires `app_id`; `SharedSurface.open(store, host,
    appId)` records the pane in that app; the pane lookup tries the handle's app, then every app
    with a live layout on the device. No `"impress"` default remains.
  - **Also closed:** RS-S7 (Invalid node kind with serde's message), RS-S8 (actions read sources;
    `into`, `open`, `publish.ids` checked or refused), RS-S9 (one `state_path` walker), RS-S10
    (only known-root plain-segment `{{…}}` is a reference; LaTeX is text), RS-S20 (placeholder
    keeps `node`), AC-F21 (`host` is the state instance, default the device; schema-refs.json
    fixed), SK-K4 (the pane publishes nothing itself), SK-K15 (render/dispatch carry `revision`
    and `state_revision`; the feed's `SharedSurfaceChange` carries the same, and the pane skips its
    own echo; events no longer notify), RS-S19 (impel-tools per-app probe times, a failed call
    re-probes and flips to unavailable, `tool_app` exported; `SharedVerbHostError` → Rust-worded
    `host-unavailable`), RS-S22 + AC-F25 (surface self-test has a live Tier B; unknown tiers
    refused; CLI list args take a JSON array), AC-F23 + RS-S18 + AC-F4 (the how-to rewritten from
    the DTOs, its JSON parsed against the real types by `tests/doc_wire.rs`; the loop's seven verbs
    are flat primary MCP tools and a test resolves every name the how-to uses in both projections).
  - **Narrowed:** RS-S21 — the tree walkers (validate, the verb check, the args check) and the four
    state-path walkers are one each; `runtime::call_verb` and the self-test report types are still
    copies (the other copies are in `impress-capabilities` and T6b's layout-service). RS-S8's "view
    kind registered" check landed after the merge (above).
  - **Merged with #75 (T6b), not rebased.** Adopted its shared pieces and dropped mine:
    `impress_service_core::strict` (the macro's `strict_args`; `call_verb_on` parses through
    `strict::args` against the tool's published schema), `wire::{WIRE_VERSION, wire_version}`, and
    the one pane-reference spelling — `surface_show`'s `target` is exactly one of `{"id"}`,
    `{"role"}`, `{"direction"}`, `{"focused": true}` (the layout's `PaneRefWire`) or `{"split":
    {"direction"}}`; `{"tile": N}` and the tagged `{"ref", "tile"}` are refused. One change to
    `strict::args`: a method whose schema names no properties takes no arguments, so a key there
    is refused (it read the empty schema as free-form, so `surface_list {"zzz": 1}` — and any
    zero-argument layout verb — accepted anything). `ViewKindId::KNOWN` now backs RS-S8's last
    check: an `open` of an unknown view kind is an error. **RL-L12's surface side:** the layout
    leaves a select's kind unchecked (#75); a surface publishes under an explicit `{kind, ids}`,
    else its first param's kind, else `item`, and a spec that publishes with no declared param is
    a validation warning, since no pane follows `item`. T6b's `None` for `expected_revision` is
    kept on every layout call the runtime still makes (`split`, `set_pane`, `select`).
    Outside my files, on purpose: layout Tier B's surface check reads the render envelope (or a
    bare tree) and `?after_seq=`; kit-demo, PMC's `SurfaceAutomationBridge`, impress's
    `ImpressVerbHost`.
  - **Bindings.** ImpressStoreFfi gained `SharedSurfaceChange`, `SharedVerbHostError`,
    `SharedSurface.appId()`; `open(store:host:appId:)` and `surfacesChanged(changes:)` changed; the
    verb-host callback's error type changed; nothing else lost. ImpelTools gained `toolApp(name:)`.
  - **Live** (impress on 23201, implore on 23202, both from this branch's own DerivedData,
    `IMPRESS_DEVICE_ID=w7-t6a-proof`, port by launch argument; before the merge with #75).
    `surface-show` with the then-unknown `target: {"id": 7}`: CLI exit 3, HTTP 400, MCP
    `isError`, each `invalid-argument` naming `id`. An invalid spec at
    create: CLI exit 3 and HTTP 422 `invalid-spec` with both problems, nothing stored.
    `surface-selftest --tier b` 3/3 on 23201 and on 23202 (14 routes 200 with `wire_version: 1`,
    strictness, invalid spec). Layout Tier B 13/13 on 23201. A surface with a required `paper`
    param shown in impress: before a selection the query refused ("required but unbound"); after
    selecting a paper on the list pane the render's `params.paper` was it and the query returned
    its title, and the window's pane re-rendered (0 → 1 focusable widget). A picker shown in
    implore published a distinct id: implore's channel 1 moved, impress's did not. kit-demo
    `--prove` 18/18, including a real in-process table-row click that made 1 select and 0 focus
    verbs, and the pane's "echo of its own write — not re-rendered" line. Throwaways (four
    surfaces, the two `w7-t6a-proof` live rows via `SqliteItemStore::delete`) removed; no launcher
    touched (xcodebuild direct).
  - **After the merge with #75** (same ports and device, rebuilt from the merged tree): the retired
    `target: {"ref": "id", "tile": 7}` is refused naming `ref` and `tile` — CLI exit 3, HTTP 400,
    MCP `isError` — while `{"id": 7}` reaches the verb (404, no such surface); surface Tier B 3/3
    on 23201 and 23202; layout Tier B 14/14 on 23201; the param proof and the implore publish
    reproduced; kit-demo `--prove` 18/18; throwaways removed again.
  - **Gates.** `rust-gate.sh fmt`, `clippy auto` (imprint + rest), `test auto` (imprint + rest;
    one run's imbib-core doctest could not load a `impress_smart_search` rlib a stopped build
    had truncated — cleaned and rerun green), `check-uniffi-bindings` (7 match; the regenerated
    store binding is byte-identical to the merge), `check-schema-refs`, `check-kit-deps
    --strict`, `check-kit-packages`, `check-chassis-deps`; ImpressLayout 79/0, ImpressSurface
    18/18, ImpressAutomation 14 + 63, PublicationManagerCore full (see the PR).
  - **Found.** The copied imbib-core/implore-core frameworks predated T5 and the toolchain pin
    (missing checksums, duplicate `_rust_eh_personality`); rebuilt in the worktree. impress's
    `/api/status` still reports 23125 on 23201 (T5's finding 4).
