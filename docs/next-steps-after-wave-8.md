# Next steps after the pipeline, GUI and self-reflective waves (2026-09-27)

Main at f5a29bb8 has every package below merged except those under "Open". The full workspace suite
passes there (`cargo test --workspace --features native`: 4264 passed, 0 failed). Detail for each package
is in the session logs of the three plans: `docs/plan-verb-pipeline-and-transport.md`,
`docs/plan-auto-gui-and-self-docs.md` and `docs/plan-self-reflective-layer.md`.

## Merged

| Plan | Packages |
|---|---|
| Pipeline and transport (ADR-0034) | P0 loopback/CORS, P1 descriptor, P2 pipeline, P3a aliases, P3b rename pass, P3c semantic-search feature, P4 jobs, P5a generic `/api/verb`, P6 Python, B1 test binaries, B3 dependency graph, B4 hakari, B5 build budget |
| GUI and docs (ADR-0035) | G0 census, G1 macro hygiene, G3 examples and reference pages (first slice), G4 generator and catalogue, G6 coverage line, G7a tracing, G7b profiler |
| Self-reflective layer (ADR-0036) | E1–E3 effects, E2b spy fix, L1 call record, L2 history verbs, S1 scenarios, S2/S2b catalogue conversion (9 of 25 Tier B entries), W1 workflows, W2 planner, R1 settings, R2a/R2b keymap |

## Open (work in progress when the session ended)

PR #121 (W3) is verified and ready for the orchestrator's merge check. Draft PRs #118 (G7c)
and #119 (W4) have local review fixes and complete gates; they must merge main again after W3,
rerun the integration gates, push through the hook, and be marked ready before merging.

- **W3 / #121**: `claude/reflective-w3-retention`, `.claude/worktrees/w3-retention`. All requested gates and both pre-push platforms passed. The isolated live proof retained all papers before 90s, removed stale only after the guard, and `why` named the workflow. Store/imbib core/imbib verb frameworks rebuilt with full iOS slices. Includes the imbib-owned FFI prerequisite of P5b and fixes to affected-ID call history and scratch isolation. The explicit exploration-library argument still lacks automatic discovery from legacy UserDefaults.
- **G7c / #118**: trace export and Tier A budgets, branch `claude/gui-g7c-export`, worktree `g7c-export`. Local clean commit `8d3491e2` fixes concurrent trace rows, folded-stack counting and budget precision. All requested gates passed; 466 touched-crate tests plus final core rerun passed. Not pushed or marked ready yet.
- **W4 / #119**: `history-service_propose-workflows`, branch `claude/reflective-w4-propose`, worktree `w4-propose`. Local clean commit `f5bd54c5` excludes privacy-reduced calls and inconsistent argument shapes, and bounds repeat arithmetic. All requested gates and touched-crate/capabilities tests passed. Not pushed or marked ready yet.

Each branch has a session-log entry or commit message saying what remains.

## Not started

- **S3**: generate a scenario from a recorded session. Needs a live isolated app.
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
- **Launcher**: `~/MyApplications/impress.app` may still point at a proof build (`impress-p2-proof.noindex`). To fix it, run `ln -sfn ~/Library/Developer/Xcode/DerivedData/impress-suite/Build/Products/Debug/impress.app ~/MyApplications/impress.app`.
- **Merging**: subagents may not run `gh pr merge` (the permission check blocks them). The orchestrator merges after verifying.

## How to run the next session

- One worktree per package: `git worktree add .claude/worktrees/<pkg> -b claude/<branch> origin/main`, then `git branch --unset-upstream`.
- Use cheaper models for implementation, with small packages. Large ones were abandoned without a start.
- A worktree needs its xcframeworks copied from the main checkout (`cp -c -R`), and the store one rebuilt with `IMPRESS_SKIP_X86=1`. Never use `--fast`, because the iOS slice is needed.
- Per PR, run the quick gates. Run the full workspace suite once on main after a batch.
- Concurrent worktrees need separate Cargo target directories; sharing a target across differing branches caused a rustdoc dependency-load failure. Use the root cache serially, or a worktree's ignored `target-<pkg>-gates` directory.
- imbib now honors `-httpAutomationPort` even with its legacy settings record. Use `--ui-testing` for its PID-owned file-backed workspace; this also isolates shared settings and notification payloads. Give proof builds a distinct bundle ID to isolate standard UserDefaults too.
- Regenerate the verb tables from the tests' `dump` output (`cargo test -p impress-capabilities --test {census,descriptor,effects} -- --nocapture --test-threads=1 dump`); never edit them by hand.
