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
