# Next steps after the pipeline, GUI and self-reflective waves (2026-09-27)

**Superseded by [the wave-9 handoff](next-steps-after-wave-9.md).**

The last code merge on main, `9d7ee7a4`, includes W3, G7c, W4, S3, G5, the audit-flush barrier (#125),
the P5b native transport slice (#126), and P7 construction checks (#127).
The next full main workspace run is due after the P7/P8 merge batch. The preceding isolated
`cargo test --workspace --features native` passed at `e7cf88a4`: **4,341 passed, 0 failed,
23 ignored**, including doctests (217 result groups). Evidence is
`/tmp/impress-after-p5b-main-workspace.log`; the first line records its owned
workspace. The preceding main run at `7d28f88c` passed 4,330 tests in
`/tmp/impress-post-audit-main-workspace.log`. The pre-G5 run at `10ee5acd` passed
4,324 tests in `/tmp/impress-s3-main-workspace.log`. The earlier `f7af1c37` batch
passed 4,291 tests, with 23 ignored, in `/tmp/impress-open-packages-workspace-serial.log`.
Its initial parallel run hit the known impel-tools global-backend race; the serial rerun passed.
Detail for each package is in the session logs of `docs/plan-verb-pipeline-and-transport.md`,
`docs/plan-auto-gui-and-self-docs.md` and `docs/plan-self-reflective-layer.md`.

## Merged

| Plan | Packages |
|---|---|
| Pipeline and transport (ADR-0034) | P0 loopback/CORS, P1 descriptor, P2 pipeline, P3a aliases, P3b rename pass, P3c semantic-search feature, P4 jobs, P5a generic `/api/verb`, P5b native transport ([PR #126](https://github.com/yipihey/impress-apps/pull/126), merge `e7cf88a4`; richer REST retirement remains), P6 Python, P7 construction checks ([PR #127](https://github.com/yipihey/impress-apps/pull/127), merge `9d7ee7a4`), B1 test binaries, B3 dependency graph, B4 hakari, B5 build budget |
| GUI and docs (ADR-0035) | G0 census, G1 macro hygiene, G3 examples and reference pages (first slice), G4 generator and catalogue, G5 strict default ([PR #124](https://github.com/yipihey/impress-apps/pull/124), merge `85cf0520`), G6 coverage line, G7a tracing, G7b profiler, G7c trace export and budgets ([PR #118](https://github.com/yipihey/impress-apps/pull/118), merge `8d102646`) |
| Self-reflective layer (ADR-0036) | E1–E3 effects, E2b spy fix, L1 call record, L2 history verbs, S1 scenarios, S2/S2b catalogue conversion (9 of 25 Tier B entries), S3 session recording ([PR #123](https://github.com/yipihey/impress-apps/pull/123), merge `10ee5acd`), W1 workflows, W2 planner, W3 retention migration ([PR #121](https://github.com/yipihey/impress-apps/pull/121), merge `35ea75fa`), W4 proposed workflows ([PR #119](https://github.com/yipihey/impress-apps/pull/119), merge `f7af1c37`), R1 settings, R2a/R2b keymap |

## Completed package verification

W3, G7c and W4 each passed their requested local quick gates, full store and imbib-verbs
xcframework rebuilds for macOS arm64, iOS device arm64 and iOS simulator arm64, and the
unmodified pre-push macOS/iOS builds before merge. Their package results are separate from the
successful combined workspace run on main.

- **W3 / #121**: The isolated live proof retained all papers before 90 seconds, removed the stale paper after the guard, kept the starred and fresh papers, and had `history-service_why` name the workflow run. W3 includes the imbib-owned FFI prerequisite of P5b and affected-ID call history. The automatic workflow still cannot discover the exploration-library ID held only in legacy UserDefaults; callers can supply `exploration_library_id` explicitly.
- **G7c / #118**: Trace export and Tier A budgets passed the final serial touched-crate run: 475 passed, 0 failed, 4 ignored. The triage fixture now uses a per-call scratch-store override.
- **W4 / #119**: `history-service_propose-workflows` passed the final combined touched-crate/capabilities run: 487 passed, 0 failed, 3 ignored, with explicit scratch store and workspace paths. The store-service test helper now restores its process-wide environment override.

Earlier Rust test runs lacked explicit process-wide store and workspace overrides, so their
isolation is unverified. The observed failure established that a store singleton was already
initialized; it did not establish a store path or data change. No real store was inspected for
this handoff. W4's final Rust run and W3's live proof were explicitly isolated; G7c's final
475-test run did not have explicit process-wide overrides. The fresh isolated main run checks
their combined Rust behavior.

## S3 verification

S3 merged in [PR #123](https://github.com/yipihey/impress-apps/pull/123) as `10ee5acd`,
after all requested local gates and the unmodified pre-push hook passed. GitHub Linux checks
passed; hosted macOS jobs were still queued at merge, as were earlier main jobs.
It adds scenario recording from one caller's trace or time window, bounded replay metadata,
output-ID captures and native surface auditing. Final isolated Rust tests passed 434 tests
(0 failed, 3 ignored), following the broader 579-test run. Two hosted native proofs passed:
direct triage records four calls with an ID capture; surface triage records three parent steps
and reports their three children as omitted. Both stored/fetched/edited/replayed the scenario
and checked paper state and live logs. The owned host PID 12083 exited. Evidence:
`/tmp/impress-s3-proof-run-final.log` and
`/tmp/impress-s3-proof-6f13b826-efab-4b6e-8e7b-78aa17735877/output/host-12083/`.
The final archive cohort covers ImbibCore, ImbibVerbsFfi and ImpressStoreFfi's three arm64
slices plus macOS ImpelTools. The full workspace verification above includes S3. Ordinary publication-list actions remain outside audit, and native
effects delegated through the Swift ImpelTools callback still lose parent identity/trace.

## Next packages

- **G5 (merged #124, `85cf0520`)**: `g5-strict` / `claude/gui-g5-strict`, based on
  `10ee5acd`. All 476 descriptors are strict. All requested quick gates and the normal pre-push
  macOS/iOS builds passed. Isolated macro/core/capabilities tests passed 136 (3 ignored); the
  deterministic layout-fixture fix passed 98 layout tests. All five native proofs passed their
  valid call, unknown-key refusal, stored Tier B scenario and surface catalogue; the four chassis
  apps also passed all 14 layout entries, with no skips. All five owned hosts exited. Evidence is
  `/tmp/impress-g5-proof-summary.json` and the dated G5 entry in the GUI plan. The archive cohort
  was fully rebuilt for every supported arm64 slice. Test-only legacy storage/index paths and
  background startup were isolated without changing production paths or schemas. No build
  artifacts are committed. Domain dispatch remains P5b. Fresh main ancestry was verified before normal merge; GitHub jobs were still queued.
  The initial post-G5 full run failed at
  `impress-workflow-service::runner::tests::a_proposed_workflow_never_runs_through_the_engine`
  (zero proposals instead of one); focused reruns passed. PR #125 replaced heuristic audit
  flushing with a FIFO writer acknowledgement and explicit timeout/disconnection errors.
  It also waits for the final job event before checking its cursor. The original failure
  was not conclusively attributed to either race; the fresh full main run above is green.
- **P5b native transport (merged [PR #126](https://github.com/yipihey/impress-apps/pull/126), `e7cf88a4`)**: `p5b-transport` /
  `claude/pipeline-p5b-transport`, based on main `7d28f88c`. Native domain
  dispatch, exact GUI store binding, the shared transport in Rust clients,
  and one feature-gated inventory are implemented. The four `*-service-http`
  crates and `impress-app-client` are deleted (7,942 lines of obsolete code).
  Thirty-four equivalent Swift registrations are retired. The richer retained
  contracts and their callers are recorded in `docs/p5b-retained-http-endpoints.md`;
  this is not a claim that the plan's estimated 160 arms have all been removed.
  Completing that retirement needs the caller/contract decision already requested
  from Tom, including capabilities not representable by existing verb arguments.
  All twelve full arm64 archive builds passed with platform SQLite. Rust
  implementation symbols are now private to each native image; otherwise dyld
  paired one image's refusal writer with another image's reader and returned
  HTTP 200 for a failed call. Each native FFI installs its own audit sink on
  the exact GUI database. The prelaunch checker checks both invariants.
  All five native transport proofs passed, including persisted app-owned writes,
  real imprint compilation/exports, implore RG operations, and exact trace,
  parent-call and caller audit readback for the four domain apps. All five
  strict-argument proofs passed: five stored scenarios, 15 surface catalogue
  cases and 56 chassis layout cases, with zero skips. Proof evidence is in
  `/tmp/impress-p5b-final-strict-summary.json` and the dated pipeline plan log.
  Final tests across 27 touched crates, including capabilities, passed 3,052
  with 19 ignored in 82 groups; log `/tmp/impress-p5b-final-touched-tests.log`,
  scratch `/tmp/impress-cargo-tests.TlWc60/workspace`. Both clippy shards and all
  requested quick gates passed. The normal pre-push hook passed, including both
  macOS and arm64 iOS simulator builds. Fresh main ancestry was verified before
  merge; GitHub jobs were still queued. Richer REST retirement remains the separate
  contract decision.
  No user's running app, launcher or real store was used.
- **P7 (merged [PR #127](https://github.com/yipihey/impress-apps/pull/127), `9d7ee7a4`)**:
  worktree `p7-construction`, branch `claude/pipeline-p7-construction`, based on
  `e7cf88a4`. One manifest reader generates 85 typed Rust constants, lower-kit
  metadata and the additive Swift enum. The schema lint reports zero Rust
  literals and 120 retained Swift literal sites. All 86 workspace crates inherit
  the lints; the macro rejects missing documentation/safety/version declarations;
  strict kit standalone checks include the dependency classifier. Sidebar policies
  are exhaustive, and catalogue credit requires an exact passing capability ID.
  Eighteen previously unsupported catalogue claims now have focused checks;
  headless refusal contracts are identified as such, and the 300-exception ceiling
  is unchanged.
  The isolated native workspace suite passed **4,351 tests, 0 failures, 23 ignored**
  in 218 groups (`/tmp/impress-p7-workspace-native.log`, scratch
  `/tmp/impress-cargo-tests.8xMfF8/workspace`). Nine Swift schema/sidebar tests passed,
  including writes, queries and counts through the rebuilt native bridge. Both
  clippy shards, all requested quick gates, all twelve full supported arm64
  framework builds, and the normal pre-push macOS/iOS builds passed. Verb tables
  were regenerated from semantic-search-enabled dumps; their data stayed unchanged.
  Evidence: `/tmp/impress-p7-native-schema-swift.log`,
  `/tmp/impress-p7-final-cohort-<crate>.log`, `/tmp/impress-p7-push-final.log`.
  **Representation accepted by Tom on 2026-09-28:** private `Cow<'static, str>`.
  Canonical constants borrow static strings; `FromStr` rejects unknown names.
  Explicit persistence and Swift wire decoding preserve opaque historical/newer-writer
  names without interning/leaking them. No new schema names or verb arguments were
  introduced. The hosted impart repair passed macOS and iOS simulator install smoke
  in run `36460078624`; all eight PR checks were green. Fresh main ancestry passed
  before the normal merge. The next full main workspace run belongs to the P7/P8 batch.
- **P8 (ready [PR #129](https://github.com/yipihey/impress-apps/pull/129); final hosted check pending)**: worktree `p8-providers`, branch
  `claude/pipeline-p8-providers`, contains main `9d7ee7a4`. Owned provider
  descriptors, persisted registration/trust, private rotated credentials, bounded
  loopback transport, all runtime readers and the Python reference provider are
  implemented. Final isolated touched-crate/capabilities tests: **1,424 passed,
  0 failed, 6 ignored**, 58 groups, `/tmp/impress-p8-verified-touched-tests-green.log`.
  Both clippy shards and all quick gates pass; all twelve full supported arm64
  framework builds pass. Real Python Tier B and the isolated native Person-form,
  CLI, catalogue-liveness and named source-refusal proof pass. Evidence:
  `/private/tmp/impress-p8-proof-9y64dfo5/output/host-60903/proof.json`.
  `scripts/test-runtime-provider-native.py` reproduces the proof on an owned build.
  Normal pre-push passed on macOS and iOS. Seven hosted checks pass; the impart
  macOS/iOS build is still running. Merge and the full native workspace batch
  on main are still required. See the pipeline plan's dated P8 entry for fixes/logs.
- **R3 (ready [PR #130](https://github.com/yipihey/impress-apps/pull/130); hosted checks pending)**: `r3-imprint` / `claude/reflective-r3-imprint`
  has 13 portable preferences, five automation settings, and 60 menu/layout
  bindings through the registries. The reviewed P8 branch is integrated locally;
  merge P8 on main first. All required quick gates, 315 Rust tests, six keymap
  Swift tests, eight settings tests, and 33 PMC contract tests pass. All twelve
  native framework builds and the imprint iOS build pass. The isolated mounted
  settings-pane/CLI/listener proof passed; evidence:
  `/private/tmp/impress-r3-proof-kkc8spwk/output/host-56007/proof.json`.
  The pre-push interlock stage now isolates its app bundles, ports, stores and
  device IDs without dropping any suite. The normal push passed all three
  isolated interlock suites and both imbib platform builds; ten Python hook/runner
  fixtures passed. Hosted checks and merge remain. See the reflective plan's dated R3 log for scope and reproduction.
- **G3 remainder (started on `g3-remainder` / `claude/gui-g3-remainder`)**: the current default inventory has 476 verbs; 355 lack an `#[impress_example]` (249 headless, 106 external), and 936 argument descriptions are missing. The earlier ~170 count covered a headless subset. Small service batches and explicit Tier B/shared scratch-fixture support are in progress; no G3 completion claim or PR yet.
- **Scenario interpreter gaps** (S2b): a store-predicate step, a best-effort step, and an escape for surface `{{state…}}` templates. The remaining 16 Tier B entries are blocked on these.
- **Swift gap from R1**: the generated Retention pane is macOS-only; iOS shows a placeholder.

## Known issues to watch

- **Older release workflows**: the P7 CI audit found that implore-release names the missing `apps/implore/build-rust.sh`; imprint/implore release lanes also lack their full older sibling framework graph. P7 repairs the new verbs framework omissions, not that older release setup.

- **Flaky under load**: tests that time a wall clock or share process-global state. Examples are impress-store-ffi `surface::…a_paper_written_anywhere…`, `layout::…a_mutation_wakes_only…`, impress-core `collab::large_body_commit_stays_fast`, impel-tools `store_generic_tools_are_available_without_app_backends` and impress-store-ffi `workflow` tick tests. All pass alone.
- **`cargo hakari verify`** reports `flate2` and `cc` feature-set notes caused by the deliberate exclusions. CI uses `generate --diff`, which passes.
- **Launcher**: `~/MyApplications/impress.app` may still point at a proof build (`impress-p2-proof.noindex`). Leave it unchanged: Tom's current instruction forbids touching his launchers or running apps.
- **Merging**: subagents may not run `gh pr merge` (the permission check blocks them). The orchestrator merges after verifying.

## How to run the next session

- One worktree per package: `git worktree add .claude/worktrees/<pkg> -b claude/<branch> origin/main`, then `git branch --unset-upstream`.
- Use cheaper models for implementation, with small packages. Large ones were abandoned without a start.
- A worktree needs its xcframeworks copied from the main checkout (`cp -c -R`), including
  app-side `apps/{imprint,implore,impel}/Frameworks` and `packages/ImpressScixCore/frameworks`,
  as well as `crates/*/frameworks`. Rebuild the store one with `IMPRESS_SKIP_X86=1` and
  swiftformat off PATH. Never use `--fast`, because the iOS slice is needed.
  A shared Rust descriptor or audit-layout change also requires rebuilding every co-linked archive
  that embeds that crate. S3 found an old ImbibCore beside new store/verb archives under the same
  crate hash: the app linked but native triage dispatch returned 404. Rebuild ImbibCore,
  ImbibVerbsFfi, ImpressStoreFfi and the macOS ImpelTools inventory together for those changes;
  unchanged generated Swift bindings alone do not prove the embedded Rust copies agree.
- P5b native archives must use platform SQLite via `scripts/native-sqlite.sh`.
  All native wrapper packages and app projects also hide Rust implementation
  symbols; keep both settings. Run `scripts/check-native-sqlite.py <owned.app>`
  before a live proof (both proof runners do so). The check rejects bundled
  SQLite and exported Rust internals. ImpartRustCore remains a placeholder:
  its core build keeps generated bindings beside the archive, not in that
  unconfigured Swift target. Use the real Homebrew `xcodegen` entry point for
  app generation; a symlink copied into a scratch PATH loses its settings resources.
- Per PR, run the quick gates and touched-crate/capabilities tests. Later batches need a new full workspace run on main.
- Concurrent worktrees need separate Cargo target directories; sharing a target across differing branches caused a rustdoc dependency-load failure. Use the root cache serially, or a worktree's ignored `target-<pkg>-gates` directory.
- Run Rust tests with a fresh scratch workspace and process-local environment, before any test can initialize a store singleton:

  ```bash
  impress_test_root=$(mktemp -d /tmp/impress-cargo-tests.XXXXXX)
  mkdir -p "$impress_test_root/workspace"
  (
    export IMPRESS_STORE_PATH="$impress_test_root/workspace/impress.sqlite"
    export IMBIB_STORE_PATH="$IMPRESS_STORE_PATH"
    export IMPRESS_WORKSPACE="$impress_test_root/workspace"
    export IMPRESS_DEVICE_ID="test-$$"
    export IMPRINT_COMPILE_CACHE_DIR="$impress_test_root/compile-cache"
    cargo test --workspace --features native
  )
  ```

  Keep the scratch directory and test log until the result is reviewed; use a fresh directory for every run. The successful main run used `/tmp/impress-cargo-test-isolated.sh` with these overrides, scratch `/tmp/impress-cargo-tests.8X6GhB/workspace`, and log `/tmp/impress-open-packages-workspace-serial.log`.
- imbib now honors `-httpAutomationPort` even with its legacy settings record. Use `--ui-testing` for its PID-owned file-backed workspace; this also isolates shared settings and notification payloads. Give proof builds a distinct bundle ID to isolate standard UserDefaults too.
- Regenerate the verb tables from the tests' `dump` output with optional semantic-search rows
  enabled; never edit them by hand. Run under the scratch environment above:

  ```bash
  for impress_dump in census descriptor effects; do
    cargo test -p impress-capabilities --features semantic-search --test "$impress_dump" -- --nocapture --test-threads=1 dump
  done
  ```

  The separate `docs/verbs/` reference pages use the default-feature inventory, matching
  `scripts/check-verb-docs.sh`: generate those with `cargo run -p impress-capabilities --bin gen-verb-docs`.
