# Next steps after the pipeline, GUI and self-reflective waves (2026-09-27)

Main at `f7af1c37` includes W3, G7c and W4. The older full workspace result (4,264 passed at
`f5a29bb8`) does not verify this combined main. A fresh isolated
`cargo test --workspace --features native -- --test-threads=1` passed there: **4,291 passed,
0 failed, 23 ignored**, including doctests (220 result groups). The initial parallel run hit the
known impel-tools global-backend race; the full serial rerun passed. Logs are
`/tmp/impress-open-packages-workspace-test.log` and
`/tmp/impress-open-packages-workspace-serial.log`. Detail for each package
is in the session logs of the three plans: `docs/plan-verb-pipeline-and-transport.md`,
`docs/plan-auto-gui-and-self-docs.md` and `docs/plan-self-reflective-layer.md`.

## Merged

| Plan | Packages |
|---|---|
| Pipeline and transport (ADR-0034) | P0 loopback/CORS, P1 descriptor, P2 pipeline, P3a aliases, P3b rename pass, P3c semantic-search feature, P4 jobs, P5a generic `/api/verb`, P6 Python, B1 test binaries, B3 dependency graph, B4 hakari, B5 build budget |
| GUI and docs (ADR-0035) | G0 census, G1 macro hygiene, G3 examples and reference pages (first slice), G4 generator and catalogue, G6 coverage line, G7a tracing, G7b profiler, G7c trace export and budgets ([PR #118](https://github.com/yipihey/impress-apps/pull/118), merge `8d102646`) |
| Self-reflective layer (ADR-0036) | E1–E3 effects, E2b spy fix, L1 call record, L2 history verbs, S1 scenarios, S2/S2b catalogue conversion (9 of 25 Tier B entries), W1 workflows, W2 planner, W3 retention migration ([PR #121](https://github.com/yipihey/impress-apps/pull/121), merge `35ea75fa`), W4 proposed workflows ([PR #119](https://github.com/yipihey/impress-apps/pull/119), merge `f7af1c37`), R1 settings, R2a/R2b keymap |

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

S3 is implemented on `claude/reflective-s3-record` (`s3-record`), based on main `197cdfed`.
It adds scenario recording from one caller's trace or time window, bounded replay metadata,
output-ID captures and native surface auditing. Final isolated Rust tests passed 434 tests
(0 failed, 3 ignored), following the broader 579-test run. Two hosted native proofs passed:
direct triage records four calls with an ID capture; surface triage records three parent steps
and reports their three children as omitted. Both stored/fetched/edited/replayed the scenario
and checked paper state and live logs. The owned host PID 12083 exited. Evidence:
`/tmp/impress-s3-proof-run-final.log` and
`/tmp/impress-s3-proof-6f13b826-efab-4b6e-8e7b-78aa17735877/output/host-12083/`.
The final archive cohort covers ImbibCore, ImbibVerbsFfi and ImpressStoreFfi's three arm64
slices plus macOS ImpelTools. Full workspace verification above predates S3; the next batch
needs a new main run. Ordinary publication-list actions remain outside audit, and native
effects delegated through the Swift ImpelTools callback still lose parent identity/trace.

## Next packages

- **G5**: `strict_args` by default on every service (D-G1 approved). Needs Tier B on five apps.
- **P5b**: package `implore-verbs-ffi` as an xcframework and wire it into implore. Add per-app FFI targets for imprint and impart (imbib's is in W3 / #121). Move impress-mcp, impress-cli, impel-tools and impress-ai-tools onto `impress-app-transport`. Then delete the four `*-service-http` crates, `impress-app-client` and the mirrored Swift route arms (D-P7).
- **P7**: schema refs as generated constants (D-P9), plus `[workspace.lints]`.
- **P8**: runtime providers (registry, `provider@1.0.0`, reference provider).
- **R3**: imprint's settings and chords through the registries.
- **G3 remainder**: about 170 verbs still lack an `#[impress_example]`, and about 900 arguments lack `///` docs.
- **Scenario interpreter gaps** (S2b): a store-predicate step, a best-effort step, and an escape for surface `{{state…}}` templates. The remaining 16 Tier B entries are blocked on these.
- **Swift gap from R1**: the generated Retention pane is macOS-only; iOS shows a placeholder.

## Known issues to watch

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
