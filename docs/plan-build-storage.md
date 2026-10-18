# Plan: bounded, warm builds

Status: **executed 2026-10-14.** Measured on impress-mac with 6.8 TB of 7.3 TB
in use. After Phase 1, `df` showed 2.86 TB free, up from 38 GB.

Two things deviate from the plan:
- **2c dropped one item.** The app-side framework copies are kept, because
  `.github/actions/xcframework` caches them too. Removing them needs a
  coordinated CI change, and saves about 2 GB per checkout.
- **The janitor is not called from `build-impress-app.sh`.** The script gets the
  free-space guard instead, so a build doesn't pay for a `du`.

## Where the space is

| Location | Size | What it is |
|---|---|---|
| `~/ci-cargo-target/` | **1.3 TB** | 33 Cargo target dirs, one per CI *job*. Each is a full cold build, and most hold 5 triples. All 33 were used in the last week. |
| `.claude/worktrees/*/target-*` | **947 GB** | 111 private build dirs made by agents (`CARGO_TARGET_DIR=$PWD/target-<task>`) and by proof runners (`target-p5b-transport-<app>` and the like). |
| `.claude/worktrees/*` (other) | 515 GB | 74 worktrees, 71 of them already merged into main: their own `target/` (103 GB), `crates/*/frameworks`, package `.build` dirs and `.ci-derived`. |
| `.claude/framework-backups-*` (main) | 155 GB | 27 framework backup copies. |
| `target/` (main) | 140 GB | Includes `x86_64-apple-ios` and incremental release dirs for 4 triples. |
| `.claude/target-*` (main) | 119 GB | 7 more task target dirs. |
| CoreSimulator | 45 GB | 70 unavailable simulator devices. |
| Xcode DerivedData | 35 GB | `impress-suite`, plus per-app, hashed and proof leftovers. |

`du` counts APFS clones (`cp -c`) in full, so the real space reclaimed will be
less than the 3.2 TB sum. It should still exceed 2 TB.

## Why it grows, and why builds are slow

The same failure explains both problems: **every new build location starts cold
and is never deleted.**

1. **A new target dir per worktree, per task and per CI job.** Nothing in the
   repo says where Cargo builds go. Agents chose a fresh dir to avoid waiting on
   each other's build lock, and the plan docs recorded that as the recipe. Each
   fresh dir recompiles roughly 900 dependency crates.
2. **Release cross-builds keep a lot.** The framework scripts build with
   `CARGO_INCREMENTAL=1` for up to 5 triples. Each `.a` file is then copied 2–3
   times into `crates/*/frameworks/` staging and again into
   `apps/*/…/frameworks`. A failed run also leaks a `$TMPDIR` snapshot (no `trap`).
3. **Xcode DerivedData is keyed by path.** The pre-push dual-platform build and
   the interlock and proof runners pass no shared `-derivedDataPath`, so every
   worktree gets its own DerivedData.
4. **No janitor.** `prune-derived-data.sh` runs only from
   `build-impress-app.sh`, and only removes caches whose project is gone. Nothing
   removes merged worktrees, target dirs, framework backups, CI targets or
   simulators. Nothing checks free disk space before a build, which is how the
   last build failed with ENOSPC.

## Phase 1 — Reclaim (one-time, destructive)

Before each step: check that no session is working in the path, print the exact
list, then delete.

| # | Action | Frees |
|---|---|---|
| 1a | `git worktree remove` the **71 merged, clean** worktrees, then `git worktree prune` (one is registered but its directory is gone). Branches are kept. | ~1.3 TB |
| 1b | Keep the **3 unmerged** worktrees (`import-fixture`, `p3b-rename`, `p5c19-comment-consumers`, each 1 commit ahead) but delete their build output. | small |
| 1c | Main: delete `.claude/target-*`, all `.claude/framework-backups-*` except the newest, and all of `target/`. The next build repopulates `target/` under the new rules. | ~400 GB |
| 1d | Delete `~/ci-cargo-target/*`, **at the same time as** 2d, so CI doesn't recreate 33 dirs. | 1.3 TB |
| 1e | DerivedData: delete everything except `impress-suite`. | ~28 GB |
| 1f | `xcrun simctl delete unavailable`. | up to 45 GB |

Out of scope unless you say so: target dirs in other projects (`lilook` 107 GB,
`veusz-tauri` 20 GB, `2pt-kNN` 14 GB, and others), plus `~/.cargo` and `~/.rustup`.

## Phase 2 — Make it bounded and warm

**2a. One Cargo target dir per machine for this repo.** Every checkout and
worktree builds into the main checkout's `target/`.
- The path is resolved from `git rev-parse --git-common-dir`, never hard-coded.
- Two places set it:
  - a committed `SessionStart` hook that writes `CARGO_TARGET_DIR` to
    `$CLAUDE_ENV_FILE`, which covers every agent session in every worktree;
  - `scripts/lib/build-env.sh`, which every build script sources, for terminal use.
- Dependencies are compiled once and stay warm. Workspace crates recompile when
  you switch between worktrees, which is cheap by comparison.
- **Trade-off:** parallel agents now queue on Cargo's build lock instead of each
  doing their own cold build. A cold build costs much more than the wait, so
  queueing is cheaper. If contention gets bad, the fallback is a fixed pool of
  2–3 slots, still bounded.
- The `CARGO_TARGET_DIR=$PWD/target-<task>` recipe is removed from the plan and
  handoff docs. A check flags any new `target-*` dir in a checkout.

**2b. Fixed DerivedData roots, not keyed by path.**
- `impress-suite` stays for app builds.
- The pre-push hook gets `impress-prepush`.
- The proof and interlock runners (`prove-*.py`, `test-*-native.py`,
  `test-native-interlock.py`) share `impress-proof.noindex` instead of
  `target-<task>-<app>` and `.ci-derived` inside the worktree.
- Their `/tmp` roots are cleaned up in `finally`.

**2c. Framework builds keep one copy.**
- Delete the staging dirs once the `.xcframework` exists.
- Add a `trap` that removes the `$TMPDIR` snapshot.
- Stop copying into `apps/*/…/frameworks` where `Package.swift` already reads
  `crates/*/frameworks`. imprint and implore really do read the app copy, so they
  stay.
- Measure release `CARGO_INCREMENTAL=1` against off. Keep it for the macOS
  `--fast` loop only if it pays for itself.
- Framework backups become a single rolling `.claude/framework-backup/`.

**2d. CI: one target dir per runner, not per job.**
- Use `CARGO_TARGET_DIR=$HOME/ci-cargo-target/$RUNNER_NAME`. Jobs on one runner
  run one at a time, so there is no lock contention.
- 4 dirs instead of 33. Dependencies are shared across all jobs on that runner.

**2e. A janitor, plus a low-disk guard.**
- New `scripts/clean-build-data.sh`. It dry-runs by default and takes `--apply`.
- Each run:
  - removes merged, clean worktrees idle for 2+ days;
  - deletes build output in any remaining worktree;
  - runs `cargo clean` on any shared target dir that is over budget (main 150 GB,
    each CI runner 120 GB) or was built by an older toolchain;
  - prunes DerivedData, deletes unavailable simulators, and removes `/tmp`
    proof roots older than 3 days.
- It runs weekly from a LaunchAgent, and in its cheap form at the start of
  `build-impress-app.sh`.
- Build scripts refuse to start below 50 GB free and say why, instead of
  failing halfway with ENOSPC.

**2f. Docs.**
- The CLAUDE.md build section states the one-target rule and the janitor.
- `docs/build-machine-hygiene.md` is updated (it still describes per-app
  DerivedData dirs).
- Plus a memory entry, so future sessions stop making `target-<task>`.

## Phase 3 — Verify

- Run `scripts/build-cost.sh` before 2a and after: cold build, warm build, and
  a warm build from a second worktree.
- Record a disk report from the janitor before and after.
- Rebuild the frameworks and a signed imbib, relaunch it, and check that
  `/api/status` answers.
- Expected steady state: about 150 GB local, about 500 GB CI and a few GB of
  DerivedData. Builds from any worktree should start warm.

## Decisions (2026-10-14)

1. **Shared target dir.** Every worktree shares one dir and queues on the lock.
   - Refinement found while executing: main's `target/release` holds binaries
     that are running right now. `impress-mcp` is the MCP server in
     `~/.claude.json` and must stay signed. `vw-mcp` runs from a LaunchAgent.
     `impress` serves the SessionStart memory brief.
   - A worktree's `cargo build --release` would overwrite them with that
     branch's unsigned build. So worktrees share **`.claude/target-worktrees`**,
     and the main checkout keeps `target/`. That makes two bounded dirs, not one.
2. **Merged branches are kept.** Only the worktree folders are removed.
3. **Framework backups:** keep the newest (`framework-backups-p5c24-imbib-routes`).
4. **Scope includes other projects.** Delete target dirs untouched for 7+ days:
   - included: `veusz-tauri`, `2pt-kNN` (and `pkvol`), `morton_code`,
     `academic-core`, `LocalModels`, `scix-client` (and its worktree),
     `sendback`, `kepler-word`, `vft-qcd/*`, `elements/wind`, `rg-map-rs`,
     `morton_cascade`. About 50 GB.
   - excluded as recently active: `lilook` (already cleaned),
     `precrossedsheet`, `hopf-cole-cosmology`.
   - `~/ci-xcframework-store` (98 GB) is CI's framework cache. It is handled
     in 2d, not deleted blind.

## Dev loop

Measured 2026-10-14 on an M5 Max (18 cores: 6 performance, 12 efficiency;
128 GB). Cargo and Xcode already use every core during a compile. The rest of
the loop was the problem: fixed per-crate overhead, and crates that were
rebuilt without any input having changed.

- **Unchanged archives are not repackaged.** Each `crates/*/build-xcframework.sh`
  writes `frameworks/.impress-stamp` as its last step. Its check
  (`impress_framework_current` in `scripts/build-env.sh`) skips
  uniffi-bindgen, lipo, `create-xcframework` and the app copies when the
  archives cargo produced are the ones already published. Size and mtime are
  compared first, content only when those moved.
- **Unaffected crates are not run.** `scripts/framework-plan.py` drops every
  crate whose stamp is newer than all of its inputs: the workspace crates in its
  dependency closure, `Cargo.lock`, the manifests, the cargo and toolchain
  config, and its own build script. An `imbib-core` edit reaches 4 of the 8
  frameworks. `build-xcframeworks.sh --force` runs and repackages everything.
- **`build-impress-app.sh` skips the provisioning-portal round trip and package
  re-resolution.** It retries with `-allowProvisioningUpdates` and automatic
  resolution only when the fast attempt fails for one of those reasons. The
  app install uses `ditto --clone`.

| Step | Before | After |
|---|---|---|
| frameworks `--fast`, no change | 28.6 s / 27.5 s | **0.6 s / 0.5 s** |
| frameworks `--fast`, `imbib-core` touched | 32.0 s | **16.5 s** |
| frameworks `--fast`, `imbib-core` edited | 30.9 s | **14.6 s** |
| frameworks `--fast`, edit reverted | 31.3 s | **14.8 s** |
| imbib app, right after a framework rebuild | 14.9 s | 11.6 s |
| imbib app, no change | 7.8 s | 7.8 s |
| imbib app, 1-line PublicationManagerCore edit | 18.6 s | 19.0 s |

The framework loop is now limited by real compilation. A touched crate's own
archive is not byte-identical after a rebuild, so it is still repackaged. Its
dependents usually come out identical and are skipped.

The app-build change does not help the steady state. A no-change build was
already about 5 s of `xcodebuild` plus about 3 s of script overhead. What it
removes is the occasional portal round trip: one no-change build measured
24 s with `-allowProvisioningUpdates` against 6 s without. A 1-line
PublicationManagerCore edit is about 19 s of Swift compile, link, sign and
install, untouched by this change. That is the next place to look, for example
narrower module boundaries in PMC, or `-jobs`/`SWIFT_ENABLE_BATCH_MODE`
experiments.

Not changed:
- Building the three slices (macOS, iOS, iOS simulator) in parallel would need
  separate target dirs per slice, and it only helps full builds.
- The linker is already Apple's fast `ld`.

## Cold build

Measured 2026-10-15 on the M5 Max. Before the run, `target/`,
`.claude/target-worktrees`, every published framework and its copies, all of
DerivedData and the SwiftPM `.build` dirs were deleted. Network caches were
kept (`~/.cargo/registry`, the SwiftPM package cache, rustup). Frameworks were
built with `IMPRESS_SKIP_X86=1`: macOS and iOS slices, the set the pre-push gate
needs. CPU is averaged over 18 cores.

| Step | Time | CPU |
|---|---|---|
| frameworks, 11 crates, macOS + iOS | 10 m 13 s | 66 % |
| imbib Debug, Xcode | 1 m 36 s | 53 % |
| clippy, `rest` shard | 59 s | 66 % |
| test build, `rest` shard | 1 m 03 s | 84 % |
| imbib Release (arm64 compile; the link needs x86 slices) | ~4 m | 40 % |
| **from nothing to a running Debug imbib** | **~12 min** | |

| Warm step | Time |
|---|---|
| frameworks, no change | 1 s |
| clippy `rest`, no change | 1 s |
| frameworks after an `imbib-core` edit, macOS + iOS | 1 m 19 s |
| frameworks after an `impress-core` edit, macOS + iOS | 1 m 44 s |
| frameworks after an `imbib-core` edit, `--fast` (macOS only) | ~15 s |
| clippy `rest` / test build after an `impress-core` edit | 10 s / 23 s |
| imbib Debug after a PublicationManagerCore edit | 20–26 s |
| running the `rest` tests (stops at the first failing binary) | ~10 s |

**What a clean build exposed.** Both were fixed in #190.
- `build-xcframeworks.sh` built 8 of the 11 frameworks. `impress.xcworkspace`
  resolves every app's packages for any scheme, so a clean checkout could not
  build any app: "local binary target … does not contain a binary artifact".
  It worked only because old copies of the three `*-verbs-ffi` frameworks
  were lying around.
- The iOS slices cost about 60 s on every Rust edit. The pre-push gate now
  builds them itself, so `--fast` is the edit loop.

**Release.**
- A universal macOS imbib Release built locally in 7.4 min: frameworks for
  arm64 + x86_64 in 4 m 4 s, then the app in 3 m 20 s.
- The `imbib-release.yml` workflow on GitHub's hosted `macos-15` took 49 min
  for `imbib-core` alone.
- The four `*-release.yml` workflows had never run before 2026-10-15, and they
  are stale:
  - they build only one or two of the frameworks the app now links;
  - they compile iOS slices for a macOS DMG;
  - `implore-release.yml` calls an `apps/implore/build-rust.sh` that does not
    exist.

**CI.**
- A PR runs three workflows. #190's took 3 m 18 s, with the impart build on
  the build Mac.
- On 2026-10-14 it took 1 h 45 m – 2 h on GitHub's hosted runner.

## Gate timing (2026-10-18)

Measured on the 18-core M-series workstation, warm target dirs, after a
one-line edit low in the stack (impress-core / impress-service-core):

| Gate | Wall | Where it goes |
|---|---|---|
| pre-push, after a koine pin bump | 11–25 min | `build-xcframeworks.sh`: 11 crates × 3 targets, serial; the Xcode builds are ~1 min |
| impress Rust gate (`rust-gate.sh` fmt, clippy, test both shards, the lints) | ~9 min | `test rest` 5.8 min: ~50 s compile, ~110 s of suites run one binary at a time, and the first launch of each of ~100 fresh test binaries |
| koine gate (fmt, clippy, workspace tests, core all-features, e2e) | ~25 min before the fixes below | workspace tests 18.5 min: koine-store-dir's conformance suite 7 min, ~110 binaries' first launches ~7 min |

Fixed:

- **One feature set for the framework crates.** imbib-core and imprint-core
  resolved the shared kit (impress-core, impress-item, koine-tasks, …) with
  fewer features than the verbs-ffi crates, which get them through
  impress-store-service; impress-store-ffi and implore differed again. Each
  feature set is its own compile of every crate above it, so a koine pin
  bump compiled the kit three times per target (79 crate builds for 48
  crates on iOS). The framework crates now turn on the same features
  (`native`), and a full rebuild compiles 46 for 44 (8m50s against 11 min).
  Check with `cargo tree -e features` per crate; only imprint-core's own
  `uniffi` still differs.
- **koine-store-dir's watcher** (koine): adding both watched directories in
  one `paths_mut()` commit halves `DirStore::watch` (FSEvents restarts its
  stream per path; each start takes ~1.7 s here), and the conformance suite
  watches only in its `reopen` arm, which is the one the cross-process case
  uses: 440 s → 18 s.

Not fixable from the repository:

- **macOS scans every new executable on its first launch** (~1.3 s idle,
  ~5 s while the gate is compiling): a test binary that has already run
  starts in 0.14 s, a fresh copy of it takes 1.3 s. Every edit relinks
  ~100 test binaries per workspace, so this is several minutes of each gate.
  Adding the terminal (and the Claude app, when agents run the gates) under
  System Settings → Privacy & Security → Developer Tools exempts the
  processes they start.
- **Test binaries run one at a time.** `cargo nextest run` runs them in
  parallel; most of the ~110 s of suites, and the launch scans, would
  overlap.
