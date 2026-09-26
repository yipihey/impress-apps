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
