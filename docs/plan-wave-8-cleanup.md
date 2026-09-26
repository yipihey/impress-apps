# Wave 8: closing what wave 7 narrowed

Wave 7 (`docs/plan-wave-7-trusted-layer.md`) closed with a short list of review findings (ids from
`docs/review-2026-09-25-gui-layer.md`) narrowed rather than fixed, plus four things found live. This wave fixes
the ones that need no product decision. The process is wave 7's (`docs/next-steps-mac-orchestrator.md`): one
worktree and branch per track, `IMPRESS_SKIP_INSTALL=1`, a per-track `IMPRESS_DERIVED`, automation port and
`IMPRESS_DEVICE_ID`, the pre-push hook never skipped, and every proof re-run by the orchestrator before merge.

## Tracks

| Track | Owns | Closes |
|---|---|---|
| **U1 Surface store** | `crates/impress-surface-service` (store, runtime sources, feed), `crates/impress-store-ffi/src/surface.rs`, the store crate's conditional write, the surface pane's own-write check | AC-F22 (the revision check atomic across processes, via the conditional write the layout live row already uses, `apply_operation_if_clock`); a hard delete in another process reaches the surface feed and re-runs the query sources that name the kind; SK-K15 (the dispatch reply and `surfaces_changed` carry the revision, so a pane skips re-rendering its own write) |
| **U2 One copy** | `crates/impress-service-core`, `crates/impress-capabilities-kit`, the report/author helpers in `crates/impress-layout-service` and `crates/impress-surface-service`, layout-service's `save/apply/delete_layout` logging | RS-S21 (`call_verb` and the self-test report types have one home); wave 7 T5 found (3) (Rust logs layout save/apply/delete and preset refusals); RL-L14's remainder (`finish` takes the tree from the verb result instead of re-reading it) |
| **U3 Host** | PublicationManagerCore Swift, impress's automation status, `apps/kit-demo` | PH-L5 (an undated surface row shows no date; the row mapping memoised; static formatters); wave 7 T5 found (4) (impress `/api/status` reports the bound port); PH-M2 re-checked now that `applyAll` exists (a click is one undo entry, or it is narrowed with the reason); kit-demo `--prove` no longer loses keys to whatever else holds focus |

## Left for a decision

- **RL-L24.** Who deleted a saved layout cannot be recorded durably: the row is hard-deleted, its operation rows
  cascade, and the sync tombstone has no author. The fix is either retire-instead-of-delete or an author on
  tombstones. Both change the store's sync semantics, so this waits for Tom.
- **RL-L14, focus-only saves.** Still written on purpose: focus is how an agent knows what the user sees.

## Session log

- 2026-09-25 — **U1 (surface store)**, branch `claude/wave8-u1-surface-store`. Rust plus the regenerated
  store binding (doc comment only); no Swift source changed.
  - **AC-F22 closed.** `SqliteItemStore::apply_operations_if_clock` is the batch form of the layout live row's
    compare-and-swap: every operation lands, under one batch id, only if a guard row's `logical_clock` is the
    one the caller read, check and writes in one `BEGIN IMMEDIATE`, and a batch that fails part-way writes
    nothing. `SurfaceStore::update` reads the row, checks `expected_revision`, and writes spec, revision and
    name guarded by the row's clock; a writer that finds the clock moved re-reads and is refused `conflict`
    (or, with no `expected_revision`, bumps from the new revision, so no revision number is ever taken
    twice). The static in-process mutex is gone. The reply is the row this write left, never a later
    writer's: before, `update` re-read after writing and could hand its caller someone else's revision as
    its own `expected_revision`. Proven by two `SurfaceStore` handles on one file racing 30 rounds from the
    revision both read (one winner, one `conflict` each round) and three threads making 60 unguarded
    updates (revisions 2..61, none shared); both fail with the unconditional batch put back.
  - **Cross-process hard deletes reach the surface feed and the sources.** The feed tracks surface ids
    (`ExternalPoll::track_deletes`, RL-L7's mechanism): a surface deleted elsewhere is reported `deleted`
    and its runtimes are dropped. The kinds query sources read are too large to diff by id, so the domain
    poll keeps each watched kind's row count (one indexed count per watched kind per `data_version` move)
    and a count that moved re-runs that kind's sources. Both cursors are now taken in `subscribe`, before
    the feed thread starts. Proven by a second handle deleting a paper (the papers source re-runs, the
    next render drops the row) and then a surface (reported `deleted`); each half fails when taken out.
  - **SK-K15.** Already closed in wave 7 T5 as asked here: the dispatch reply and `SharedSurfaceChange`
    carry `revision` and `state_revision`, and the pane in `packages/ImpressLayout` skips a change with
    nothing newer. **Found:** that only works when the reply arrives first, and the feed's echo is due
    50 ms after the state write while the reply comes after effects and the re-render, so any dispatch
    slower than the debounce was still rendered twice. The handle is the pane's own, so its feed now holds
    a surface's changes while one of its dispatches runs and then drops the change that carries nothing
    newer than the reply (no source invalidated, nothing deleted); other handles are still told. Proven
    by a dispatch whose re-render waits 400 ms on a slow source: not echoed to its own pane, reported to a
    second pane with the reply's `state_revision`. No exported signature changed.
  - **Narrowed.** A delete of a watched kind in the SAME window as a foreign write of that kind is reported
    through the write, and a delete made in this process is re-reported on the next foreign write (one
    extra re-run, never a missed one). A kind is counted from the first poll after a source reads it, so a
    foreign delete in the ≤250 ms before that is missed until the next write of the kind.
  - **Found, not fixed (outside U1's files).** `ExternalPoll::baseline` leaves `reported` empty, so the
    first foreign write after a feed starts replays every row under its prefix written in the 10 s overlap
    before it (a surface created just before its pane subscribed arrives as a change). Harmless (a spurious
    render) and it affects `layout.rs`'s feed too; seeding the window at baseline would instead miss a
    write stamped before the baseline but committed after it, so it is left as is.
  - **Gates.** `rust-gate.sh fmt` clean; `rust-gate.sh clippy auto` (rest) clean after one fix
    (`type_complexity`); `cargo test -p impress-core --all-features` 652 passed; `cargo test -p
    impress-surface-service -p impress-store-ffi -p impress-surface -p impress-layout-service` 336 passed;
    `check-uniffi-bindings` 7 match; `check-schema-refs`, `check-kit-deps --strict` OK; ImpressSurface
    18/18; ImpressLayout 79/0 (it reads `SharedSurfaceChange`). **Not run:** PublicationManagerCore's
    `swift test`. The fresh worktree has no imbib-core, imprint-core, impress-helix or scix-client-ffi
    xcframework, and neither copying them from the main checkout nor building them here was permitted in
    this session. The binding differs from main only in one doc comment, so the orchestrator's PMC run
    covers it.

- 2026-09-25 — **U2 (one copy)**, branch `claude/wave8-u2-one-copy`. **RS-S21:** the inventory call
  (`find`, `call`, `call_async`, `CallError`, `descriptors`) is `impress_service_core::call`; the kit
  re-exports it, impress-capabilities re-exports the kit's, and the surface runtime's `call_verb`
  only maps `CallError` onto a refusal with the same codes and text (a test pins both, through a
  handler that errors). The kit cannot be the home: it depends on impress-surface-service. The
  self-test report types are `impress_service_core::report`, re-exported as each crate's `report`;
  a test pins the bytes. `Ephemerality`, `actor_from` and the author rule are
  `impress_layout_service::authorship`, not service-core, which is on the kit's pure tier and may
  not reach impress-core's types; each store keeps a one-line `author_for` naming its service, so
  authors are unchanged. impress-capabilities held no copy. **T5 found (3):** T6b's `persisted`
  had already logged save/apply/delete_layout and the preset verbs; two refusals still returned
  unlogged (save_preset with `from_live: false`, a `commit` of an unmaterializable kind) and now go
  through it. `tests/logging.rs` captures the `log` facade and pins all six lines, level and actor
  (fails with the fix reverted). **RL-L14:** a service built `with_tree_in_results` (only the FFI's)
  serializes the tree it left into `LayoutVerbResult::tree_json` under the lock the verb holds —
  per-verb path, batch, save/apply layout, apply_preset, undo/redo. The field is `serde(skip)` and
  `schemars(skip)`, so the wire is unchanged. `SharedLayout::verb` takes it and re-reads only for
  `delete_layout`, which leaves no tree. Focus-only saves are unchanged.
  - *Narrowed.* imprint-selftest keeps its own report: it has no `ok` field, so sharing would change
    its `run-selftest` answer. The FFI's public signature is unchanged, so no regeneration.
  - *Gates.* `rust-gate.sh fmt` ok; `rust-gate.sh clippy auto` ([rest]) ok; `cargo test -p
    impress-service-core -p impress-capabilities-kit -p impress-capabilities -p
    impress-layout-service -p impress-surface-service -p impress-store-ffi -p impress-cli` 270
    passed, 0 failed; `check-kit-deps --strict`, `check-schema-refs`, `check-chassis-deps`,
    `check-uniffi-bindings` (7 match) ok. `check-kit-standalone` fails, as it does on main at
    9ff3eeb1: `impress-surface-service/tests/doc_wire.rs` `include_str!`s
    `docs/agent-surfaces.md`, which the scratch workspace does not copy. That is left to whoever
    owns that test or the script.

- 2026-09-25 — **U3 Host** (`claude/wave8-u3-host`). Swift only: PMC, `packages/ImpressAutomation`,
  impress's app target, `apps/kit-demo`. No Rust, `ImpressSurface` or `ImpressRustCore` touched.
  - **PH-L5 closed.** A surface row with no `modified` or `created` (or none that parses) shows no
    date instead of today: `KindTaggedRow.isDated` is false and the row renders with the mail-style
    date column off (`mailStyleConfiguration`, which the registry's default row factory now passes).
    `MailStyleItem.date` stays non-optional: eleven conformers (PMC, its tests, impart) and impress-iOS read
    it. A row with only `created` keeps that date, as before. The mapping is written only from
    `onAppear`/`onChange`, never in `body`; the formatters were already static.
  - **impress `/api/status` reports the bound port.** `d5a84f00` had already moved it from the
    table default to the `httpAutomationPort` setting; it now reports the local port the request
    arrived on (`HTTPRequest.localPort`, stamped by `HTTPServer`, falling back to its new
    `boundPort`), so a setting read later cannot disagree with the socket. Live: my build, launched
    with `-httpAutomationPort 23241 -ApplePersistenceIgnoreState YES` and
    `IMPRESS_DEVICE_ID=w8-u3-proof`, answered `"port": 23241, "serverPort": 23241` on
    `/api/status` and `/status`; quit by pid afterwards. `~/Applications/impress.app` untouched
    (13:14 mtime). The launch leaves a live layout row for device `w8-u3-proof` (no verb deletes one).
  - **PH-M2 re-checked.** `applyAll` is one step and one undo entry: the outline already used it
    (`d5a84f00`). The one PMC click that still applied verbs one by one was a list row's Open PDF
    (select on the list, set-pane on the info pane, focus), two undo entries on two panes' rings. It
    is one `applyAll` now, tab first so the step lands on the info pane's ring where focus ends; a
    test shows one version, one ⌘Z taking back both selection and tab, and a refused select
    applying none of it. **Narrowed:** a surface's clicks do not pass through PMC — `publish` and
    `open` are effects Rust's surface runtime applies one by one (`impress-surface-service`
    `run_effect`), so a spec with `[publish, open]` is still two undo entries (U1's crate). A list
    row click (`PaneContext.select` in ImpressLayout) is focus + select as two verbs, but focus
    records nothing, so it is already one undo entry.
  - **kit-demo `--prove`.** Reproduced the loss: with a second KitDemo launched 5 s into the run,
    the unfixed harness typed "eo" and failed 4 claims. The harness now makes its window key in the
    active app with the field's editor first before every key, both Undo/Redo pairs and both
    clicks, taking focus back if it must, and fails the claim naming the frontmost app if it
    cannot. Keys still go through `window.sendEvent`. Runs: plain 19/19 twice; thief at 5 s 19/19
    twice; thief at 8.5 s 19/19 (each run logged "window is not key … taking it back" and "key
    again after 1 attempt").
  - **Gates.** PMC `swift test`: 2159 XCTest, 0 failures (2 skipped) + 112 swift-testing;
    ImpressAutomation 17 XCTest + 63 swift-testing, 0 failures; ImpressLayout 79 XCTest, 0
    failures; impress `build-for-testing` with `IMPRESS_SKIP_INSTALL=1` and its own DerivedData
    succeeded (`ImpressShellTests` is compiled, not run, as in CI: its host is the GUI app).
    Frameworks were APFS clones of the main checkout's, whose bindings match this commit's byte for
    byte.

- 2026-09-25 — **U4 (one click, one step)**, branch `claude/wave8-u4-one-click` off
  `claude/wave8-integrate`. Rust only (`impress-surface-service`) plus a paragraph in
  `docs/agent-surfaces.md`; no exported signature changed.
  - **PH-M2, surface half, closed.** `SurfaceRuntime::dispatch` used to send each `publish`
    and `open` to the `Executor` separately, so `[publish, open]` was a `select` and then a
    `set_pane`/`split`: two writes of the layout row, two undo entries, and a refused `open`
    left the `publish` applied. Now the runtime compiles both effects into layout verbs and
    gathers a run of consecutive ones into one gesture, which the Executor's one layout method,
    `apply_layout(pane, verbs, actor)`, applies with `apply_verbs_as`: one write, one undo
    entry on the ring `UndoStacks::apply_all` picks (the first recorded verb's, so a gesture
    that starts with `publish` lands on the surface pane's ring, where focus is), all or none.
    A one-verb gesture goes through `apply_verb_as`, so a lone effect is logged and recorded
    exactly as before.
  - **Design, and why.** Of the two options the plan named, compiling effects to verbs is
    the less invasive. A collect-then-flush mode on the executor would put per-dispatch state
    in an object shared by every dispatch in the process (`DefaultExecutor` is cloned into
    the FFI, HTTP and each pane), and would still need the verbs built somewhere. Compiling
    keeps the executor stateless: the trait loses `publish` and `open` and gains
    `apply_layout`; the gathering lives in `dispatch`, next to the ordering it has to respect.
    The verbs are the ones the layout verbs already build: `publish` is `Select` on the
    surface's tile; `open` with a target role is `SetQuery` + `SetViewKind` on that role
    (resolved when the gesture applies, keeping the pane's role, channel, params and session,
    which is what the old read-then-`set_pane` kept); `open` with none is `Split` of the
    focused pane with the new spec. `surface_show` still uses `show_in_pane`, unchanged.
  - **Mixed sequences.** Effects run in `reduce`'s order. A `call` or an `emit` ends the
    run: the gesture so far is applied first, then the call or emit runs, and the layout
    effects after it are a new gesture. So `[publish, open]` is one step; `[publish, call,
    open]` and `[publish, emit, open]` are two, with the call or emit between them, the order
    they had when every effect was its own step. Nothing in a dispatch reads a `call`'s result
    from a later effect (`reduce` resolved every effect's arguments up front; `into` only
    reaches state and the next render), but a verb may read or change the layout, and an
    agent woken by an `emit` reads it, so neither may run ahead of a layout change the click
    made before it. `refresh` only drops a cached source and does not end a run.
  - **Outcomes.** Still one per effect, in order, with the same success messages. A member
    refused before the layout sees it (no pane, a query that does not parse, an id that is not
    one) reports its own refusal as before; every other member of that gesture, before or
    after it, reports `not applied: the '<kind>' in the same gesture was refused: …` with the
    same code. A gesture the layout refuses reports the layout's refusal on every member,
    with "(one gesture: none of it applied)" appended when there is more than one. Either way
    nothing is written.
  - **Tests.** `tests/gesture.rs` (a service whose executor's layout sessions are the ones the
    test reads and undoes on): `[publish, open]` is one write of the layout row, focus stays
    on the surface, one undo on its pane restores selection and detail pane, and a second undo
    changes nothing; an `open` of a role no pane holds leaves the layout and channels exactly
    as they were and both effects report the refusal; an invalid id in a second `publish`
    keeps the first `open` from applying; an `emit` between them makes two writes. The first
    three fail against the old runtime (2 writes; the publish landed; the open landed). The
    layout row's `revision` is a clock, not a counter, so "one revision" is counted as layout
    row writes on the store's mutation feed.
  - **Narrowed.** An `open` with no target splits and moves focus to the new pane, while a
    gesture that starts with `publish` is recorded on the surface pane's ring; so after
    `[publish, open]` with a split, ⌘Z with focus on the new pane finds nothing on that pane's
    ring (⌘Z back in the surface pane takes the whole click back). Before, the split was on
    the arrangement ring and the select on the surface's, so it was never one ⌘Z either.
    Which ring a gesture belongs on is `UndoStacks::apply_all`'s rule, shared with PMC's
    clicks, and not changed here. Pane lookups for a gesture's members happen before any of
    it applies, so an `open` that replaces the surface's own pane followed by a `publish`
    publishes from that tile rather than refusing `no-pane` as it used to.
  - **Gates.** `rust-gate.sh fmt` clean; `rust-gate.sh clippy auto` ([rest]) clean; `cargo test
    -p impress-surface-service -p impress-store-ffi -p impress-layout-service -p
    impress-surface -p impress-cli` 346 passed, 0 failed (includes `coherence.rs` and
    `doc_wire.rs`); `check-kit-deps --strict`, `check-schema-refs` OK; `check-uniffi-bindings`
    7 match. ImpressSurface `swift test` 18/18; ImpressLayout 79 XCTest, 0 failures, after
    `IMPRESS_SKIP_X86=1 IMPRESS_SKIP_IOS=1 crates/impress-store-ffi/build-xcframework.sh`
    (swiftformat not on PATH) built the store framework it links; the regenerated binding
    is byte-identical to the committed one. **Not run:** PublicationManagerCore's `swift
    test`, which needs xcframeworks this worktree does not have.
