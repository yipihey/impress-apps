# Pipeline, GUI and reflective-layer handoff (2026-09-28)

This succeeds [the wave-9 handoff](next-steps-after-wave-9.md). Read CLAUDE.md
in full first. The three approved plans and ADRs 0034–0036 govern the work;
their dated session logs contain detailed verification and known limitations.
All packages listed as merged in wave 9 remain merged.

## This batch

| Package | PR | Status |
| --- | --- | --- |
| S2c surface HTTP scenarios | #135 | Merged, `e6aa61d6` |
| P5c contract proposal | #136 | Draft, approval pending; documentation only |
| S3 nested Swift callback context | #137 | Merged, `f2b2d757` |
| W3 exploration identity discovery | #138 | Merged, `cc606597` |
| S2d surface dispatch scenario | #139 | Merged, `fee1230b` |
| S2e console scenario and log cursors | #140 | Merged, `58f124a8` |
| S2f strict captured comparisons | #141 | Merged, `829728b9` |
| S2g source-pane session scenario | #142 | Merged, `56888fe7` |
| S2h version movement and bounded captures | #143 | Merged, `744f1913` |
| S2i channel selection and argument capture | #144 | Merged, `01f9251d` |
| S2j outline collection and guarded waits | #145 | Merged, `b691a33e` |
| S2k hidden shares and captured tolerance | #146 | Merged, `3c56dfbb` |

Each merged package passed its required local gates and normal pre-push hook.
Fresh origin/main ancestry and the exact remote head were checked before merge.
Hosted checks were still queued/running at merge; this is not a claim that all
hosted checks had completed. No hook was bypassed.

S3 now preserves caller, trace and parent across the blocking executor, Rust
FFI, Swift SharedVerbHost and ImpelTools. Trusted context travels separately
from domain arguments. The owned native audit proof found a human dispatch
and its actual memory-service child with the same trace and exact parent.

W3 migrates the legacy exploration-library pointer into an internal Device
setting during LibraryManager initialization and mirrors updates. Retention
uses it only when the existing explicit argument is omitted; an invalid
explicit ID does not select another library. Generated preference panes hide
the internal setting. The 90-second startup delay remains unchanged.

S2 now has nineteen of twenty-five catalogue entries in documents. The source
scenario explicitly copies the old session in its input and proves the new
pane receives a distinct session; it also checks query preservation, PDF
session absence, wrap/swap stability and preset restoration.

## Verification evidence

- S2c: 249 Rust tests, zero failures, three ignored; native proof
  `/tmp/impress-g5-proof-7_ulo7mz/output/`.
- S3: 367 combined tests, zero failures, four ignored; native audit proof
  `/tmp/impress-s3-proof-gpaxukku/output/host-48118/`.
- W3: 340 Rust tests, zero failures, three ignored; 20 isolated LibraryManager
  tests and normal macOS/iOS pre-push builds. Logs
  `/tmp/impress-w3-discovery-{final-tests,swift-tests,push}.log`.
- S2d: 146 Rust tests, zero failures, three ignored; native proof
  `/tmp/impress-g5-proof-6vwvm7kk/output/`.
- S2e: 197 Rust tests, zero failures, three ignored; native proof
  `/tmp/impress-g5-proof-t85o2luc/output/`.
- S2f: 67 final Rust tests, zero failures, three ignored, including mixed
  integer/float boundaries; `/tmp/impress-s2f-tests-final.log`.
- S2g: 177 final Rust tests, zero failures, three ignored; native proof
  `/tmp/impress-g5-proof-aw1b27dd/output/`.
- S2h: 212 Rust tests, zero failures, three ignored; native proof
  `/tmp/impress-g5-proof-gsvmopze/output/`.
- S2i: 189 Rust tests, zero failures, three ignored; final native proof
  `/tmp/impress-g5-proof-g7inzcpe/output/`. The first native run caught an extra
  channel wrapper in a JSON path; corrected to ChannelState’s transparent wire
  shape and reran all verification. Failed evidence remains at
  `/tmp/impress-g5-proof-w4m628lv/output/`.
- S2j: 193 Rust tests, zero failures, three ignored; native proof
  `/tmp/impress-g5-proof-p2tr6x4n/output/`.
- S2k: 194 Rust tests, zero failures, three ignored; native proof
  `/tmp/impress-g5-proof-05kcm8l_/output/`. Captured numeric tolerance retains
  the original hidden-share comparison; malformed/nonnumeric targets fail.

Each listed imprint proof passed both XCTest cases, the stored scenarios,
all three surface entries and all fourteen layout entries with zero skips.
Native symbol checks passed and all owned hosts exited. The S3 proof is its
separate one-XCTest callback audit proof.

The final full native workspace run on main at `3c56dfbb` passed **4,478 tests,
zero failures, 26 ignored across 223 result groups**. Command:
`cargo test --workspace --features native --no-fail-fast -- --test-threads=1`,
with the owned environment recipe below. Log:
`/tmp/impress-wave10-main-workspace.log`. The known import effects fixture
passed in this run; its intermittent failure is not claimed fixed.

The handoff branch also passed every quick gate and its capabilities suite
(44 passed, zero failures, three ignored):
`/tmp/impress-wave10-handoff-{gates,capabilities}.log`.

## Remaining work and approval

- P5c: [draft PR #136](https://github.com/yipihey/impress-apps/pull/136) contains
  the concrete contract proposal in `docs/p5c-contract-proposal.md`. Approval
  has not arrived. The user's ask-first rule covers these verb-argument
  changes. After approval, implement the contracts, prove route/caller parity,
  migrate consumers, and retire only routes with no remaining callers. Queued
  editor/conversation, caret, binary/viewer and hardware routes retain the
  separate owners and behavior identified in the proposal.
- Four platform/live-state cases remain intentionally in code: manuscript
  history, WAL health, PDF-pane reading and the Reading preset. Reachability
  and catalogue-wide restoration are the runner's gate/finally code.
- R3 command-palette overrides and the app-specific preferences listed in the
  previous handoff remain their later work; this batch does not claim them.

## Known failures and operating rules

`imbib-library-service_import-papers` example `import-fetched-record`
intermittently returned an all-zero ImportSummary during S3 and S2f verification.
Its cause remains unconfirmed. The effects fixture runner is sequential behind
one scratch-store OnceLock; no ordering or concurrency cause was established.
Six focused effects runs, three serial scenario/capabilities diagnostic runs,
and the final S2f branch run passed. The diagnostic now prints the full summary.
Preserve the assertion; do not mark the effect unverified or add an exception
to make the gate green. Logs: `/tmp/impress-import-exact-repeat-{1,2,3}.log` and
`/tmp/impress-s2f-tests.log`. Other known hazards remain in the wave-9 handoff.

Main has twenty coherent framework bundles cloned from the verified S2k
worktree using `cp -c -R`. Previous bundles are retained under the ignored
`.claude/framework-backups-*` directories. Completed S2c, S3, W3, S2d, S2e,
S2g, S2h, S2i, S2j and S2k owned app build directories were removed after their hosts exited; their
proof logs/results remain in the paths above.

For scenario/layout changes, the normal/build dependency graph reaches two
native archives: impress-store-ffi and impel-tools. Rebuild those for full
supported arm64 slices; copy unchanged coherent bundles with COW. A SQLite
linkage change still requires rebuilding the entire co-linked cohort. Keep
swiftformat off PATH, use `IMPRESS_SKIP_X86=1`, never `--fast`, and never omit
iOS. Finish framework replacement before any app build or push reads it.

Reuse these Cargo caches serially, with `CARGO_INCREMENTAL=0`:

- `.claude/target-p7-consumer`: tests and CLI.
- `.claude/target-p7-schema`: clippy, generated docs and kit gates.
- `.claude/target-p5b-native`: release native archives.

Use an owned store/workspace/device/compiler cache for Rust tests and serial
test threads. `/tmp/impress-cargo-test-isolated.sh` provides the session's
recipe; the wave-8 handoff records the environment explicitly. Regenerate
verb tables from the capability tests' dumps, never by hand. Run all quick
gates, touched crates and capabilities per PR, then the full native workspace
on main after merges. Use owned derived data, bundle, port and store for native
proofs; keep installation disabled. Never touch Tom's running apps, launchers
or real store, stash, force-push or bypass a hook. If permission review blocks
`gh pr merge`, stop and tell Tom.
