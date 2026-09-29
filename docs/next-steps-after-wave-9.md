# Pipeline, GUI and reflective-layer handoff (2026-09-28)

This succeeds [the wave-8 handoff](next-steps-after-wave-8.md). Read `CLAUDE.md`
in full first. The three approved plans and ADRs 0034–0036 still govern scope;
their dated session logs contain implementation and proof details.

## Package status

| Package | PR | Status |
| --- | --- | --- |
| W3 retention | #121 | Merged, `35ea75fa` |
| G7c export/budgets | #118 | Merged, `8d102646` |
| W4 proposed workflows | #119 | Merged, `f7af1c37` |
| S3 session recording | #123 | Merged, `10ee5acd` |
| G5 strict arguments | #124 | Merged, `85cf0520` |
| Audit flush barrier | #125 | Merged, `7d28f88c` |
| P5b native transport | #126 | Merged, `e7cf88a4`; distinct REST contracts remain |
| P7 construction checks | #127 | Merged, `9d7ee7a4` |
| P8 provider registration | #129 | Merged, `016bae39` |
| R3 imprint settings/keymap | #130 | Merged, `3c977dd4`; all eight hosted checks green |
| G3 remaining examples/docs | #131 | Merged, `2491df50`; hosted CI pending at merge |
| S2b interpreter gaps | #132 | Merged, `158502c2`; hosted CI pending at merge |
| Retention cutoff fixture | #133 | Merged, `d5e233b3`; no production behavior change |

All requested local gates, native proofs and normal pre-push hooks passed before
these merges. Fresh main ancestry was checked. The final G3/S2b main-only merges
changed no files; their existing verification applies to the identical trees.
Hosted CI was still queued/running on the four busy `xcode-27` runners at merge.
Two queued S2b intermediate runs were cancelled to avoid duplicate builds, then
its final push triggered fresh checks. No hook or required local gate was bypassed.

R3 migrates thirteen imprint settings and sixty shortcut bindings. Its mounted
native pane proof verified external CLI writes, listener restart/token rotation,
legacy-value preservation and native menu equivalents. It does not claim every
app-specific preference or command-palette override has migrated.

G3 covers all 479 verbs and 1,068 top-level arguments, with 403 executable Tier A
examples. The effect exception ceiling is now 145. Reference pages distinguish
headless examples from explicit Tier B examples requiring an isolated host,
device, credentials or fixture. Those prerequisites are not claimed as executed
by the headless gate. Native demo registrations now anchor their descriptors
directly; a zero-sized constructor had been folded away during native linking.

S2b adds bounded store predicates, explicit optional calls and literal template
escapes. Recording preserves nested surface templates. These use existing verbs
and the same Caller in both tiers; no record kind, schema reference, verb
argument, widget/action kind or kit dependency was added. See
[scenario steps](scenario-steps.md).

## Verification

The final isolated main run at `d5e233b3` passed **4,429 tests, zero failures,
26 ignored**, including doctests, across 223 result groups:
`cargo test --workspace --features native --no-fail-fast -- --test-threads=1`.
Log: `/tmp/impress-wave9-main-workspace-final.log`; owned workspace:
`/tmp/impress-cargo-tests.LcTtL3/workspace`. Both handoff clippy shards and every
required quick gate also passed (`/tmp/impress-wave9-handoff-*.log`).

- R3: 315 Rust tests, six Swift keymap tests, eight settings tests, 33 focused
  PMC tests, all twelve supported arm64 framework builds and imprint iOS build.
  Proof: `/private/tmp/impress-r3-proof-kkc8spwk/output/host-56007/proof.json`.
- G3: 1,413 touched-crate tests; final semantic-enabled capabilities run 44
  passed, zero failed, three ignored. Both clippy shards and quick gates pass.
  Twelve full arm64 framework builds and isolated imprint proof pass: two
  XCTest cases, one stored scenario, three surface and fourteen layout cases.
  Proof: `/tmp/impress-g5-proof-2vo19xr6`; owned host PID 4269 exited.
- S2b: final integrated run 84 passed, zero failed, three ignored. Both clippy
  shards, quick gates and all twelve supported arm64 framework builds pass.
  Native proof: `/tmp/impress-g5-proof-4pgger3v/output/gaps-run.json` and
  `proof.json`; two XCTest cases, two stored scenarios, three surface cases and
  fourteen layout cases passed. Owned host PID 32087 exited. The first full run at
  `158502c2` exposed a same-millisecond retention fixture race in impel-service;
  #133 waits for the strict age boundary. Its 52 touched-crate/capabilities
  tests, 20 repeated regression runs, both clippy shards and quick gates passed.

## Work that remains outside these completed slices

- P5b richer REST retirement needs explicit caller/contract decisions. The
  exact differences and callers are in
  [retained HTTP endpoints](p5b-retained-http-endpoints.md). Do not remove a
  route or change a verb's arguments merely because its name looks equivalent.
- Sixteen Tier B catalogue entries still use code. The three interpreter
  mechanisms are now available, but route-contract assertions, cross-case
  restoration and platform checks need deliberate treatment during conversion.
  Current catalogue IDs and assertions remain intact.
- W3 follow-up (2026-09-28, `claude/reflective-w3-discovery`): imbib now
  migrates the legacy exploration-library pointer into an internal Device
  setting and mirrors `LibraryManager` changes; retention uses it when
  `exploration_library_id` is omitted. An invalid explicit value disables
  exploration cleanup instead of falling back. The 90-second workflow
  guard and existing workflow spec remain unchanged. Focused scratch-state
  tests are added; root owns the shared gates and native verification.
- S3 nested Swift ImpelTools callbacks still lose parent identity/trace.
- R3 command-palette overrides remain D-R13's later work; appearance/modal
  editing and app-specific LaTeX/export/AI preferences retain their owners.

## Running safely and cheaply on this machine

Main now has 21 framework bundles cloned with `cp -c -R` from the verified
S2b cohort. Previous main bundles are retained under
`.claude/framework-backups-wave9`; these are ignored build artifacts.
The reviewed G3 derived-data caches and obsolete `target-audit-*`,
`target-p5b-effects`, `target-p5b-runtime` and `target-p5b-selftest` caches were
removed for disk space. Current native and P7 Cargo caches remain, as do proof
logs and result bundles in their owned temporary directories.

Use one worktree per package from fresh `origin/main`, then unset its upstream.
Clone unchanged framework bundles with `cp -c -R`; rebuild changed native Rust
and every co-linked archive embedding a changed shared crate. Use
`IMPRESS_SKIP_X86=1`, keep swiftformat off PATH and never use `--fast`. Keep
platform SQLite and hidden Rust implementation symbols; run
`scripts/check-native-sqlite.py` before launching an owned proof bundle.

Do not rebuild framework bundles while a push or app build reads them. A G3
push overlapped a rebuild and saw the temporarily absent scix framework. Finish
the cohort first. Use separate Cargo target directories for concurrent branches;
reuse a cache serially and set `CARGO_INCREMENTAL=0` to limit disk consumption.

Run both `rust-gate.sh` clippy shards, fmt, verb coverage/docs, strict kit deps,
standalone kit, Swift kit boundary, bindings, schema refs and hakari diff per PR,
plus touched crates and capabilities. Run the full native workspace on main
after merges. All Rust tests need a new owned store/workspace/device/compiler
cache before any singleton initializes; the wave-8 handoff includes the exact
environment recipe. Regenerate tables from the semantic-enabled tests' dumps;
generate `docs/verbs/` with the default-feature inventory. Never edit generated
tables manually.

The full native inventory emits the existing macOS linker warning about a
large `__eh_frame` section; it was also present in the P5b and P7 main logs.

Known test hazards: impel-tools has a process-global backend race under parallel
tests; use serial test threads for the full workspace run. The old workflow
proposal race received the FIFO audit barrier in #125. The impart CI smoke
check previously piped `launchctl list` to `grep -q` under `pipefail`; it now
reads the complete list before matching and prints it on a real absence.

Never stash, force-push or bypass the pre-push hook. Keep `IMPRESS_SKIP_INSTALL=1`
for native gates. Never touch Tom's apps, launchers or real stores. Proof runners
must use owned derived data, bundle ID, port, device ID and scratch paths, and
quit only their own host. Fresh-fetch and verify main ancestry before merging;
if permission review rejects `gh pr merge`, stop and tell Tom.
