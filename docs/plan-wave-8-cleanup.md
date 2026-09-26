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
