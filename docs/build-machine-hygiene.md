# Build machine hygiene

Two problems on the build Mac that look cosmetic and are not: Spotlight
launching the wrong build of an app, and DerivedData growing without bound.
They share a cause — Xcode leaves a copy of every app it has ever built,
forever, at a path nobody chose.

## Spotlight must not be able to see a build directory

Every app in the suite installs its Debug build to `~/Applications`, so
Spotlight opens the newest one. That holds only while `~/Applications` is the
**only** copy Spotlight can find.

It was not. On 2026-09-08 Spotlight opened a day-old impel from a DerivedData
path. Ad-hoc signing carries no provisioning profile, so the `QG3MEYVHMS`
app-group entitlement was unauthorized and macOS prompted "would like to access
data from other apps" on every launch — while the day's work was read as having
no effect, because the running binary was the previous day's.

**The fix is one GUI step**, and it cannot be scripted — the exclusion list is
root-owned and SIP-protected:

> System Settings ▸ Siri & Spotlight ▸ Spotlight Privacy… ▸ **+** ▸ add
> `~/Library/Developer/Xcode/DerivedData` and
> `~/Library/Developer/Xcode/Archives`

That both purges what is already indexed and blocks future indexing, without
touching a single build cache. Reach the folders in the file picker with
**⇧⌘G** and paste the path — `~/Library` is hidden.

`scripts/check-app-installs.sh` reports what Spotlight can currently see, per
app, and flags the two things that bite: a copy newer than the installed one,
and any ad-hoc signature.

### Three things that look like fixes and are not

- **`.metadata_never_index` at the DerivedData root.** Tested here on
  2026-09-09: with the marker in place, an indexed bundle deleted and restored
  was re-indexed immediately. It changes nothing. (It was briefly in
  `build-impress-app.sh`; it is gone.)
- **One shared DerivedData path instead of per-project hashed ones.** Leaves
  one stale copy rather than sixty, and one is all it takes to out-rank
  `~/Applications`.
- **Excluding `~/Library/Developer/Xcode/DerivedData` alone.** `.xcarchive`
  bundles each contain a full `.app`, and archives live elsewhere — seven of
  imbib's ten Spotlight-visible copies were archives from January.

The mechanism that *does* work without the GUI is a DerivedData root whose name
ends in `.noindex`, the convention Xcode already uses for
`Build/Intermediates.noindex`. Verified 2026-09-09: a bundle inside one returns
0 `mdfind` hits, an identical copy beside it returns 1. Set it with
`defaults write com.apple.dt.Xcode IDECustomDerivedDataLocation`. It orphans
the entire build cache, which is why the Privacy list is the better trade.

## Where builds go, and what keeps them bounded

Measured 2026-10-14, when the disk filled mid-build: builds of this repo held
~3.2 TB, and the same habit made every build slow. Each new build location was
a cold build of ~900 crates that nothing ever deleted. The plan and the
numbers are in [plan-build-storage.md](plan-build-storage.md).

| What | Where | Bounded by |
|---|---|---|
| Cargo, main checkout | `target/` | `clean-build-data.sh` (150 GB or toolchain change; `target/release` kept, since signed binaries run from it) |
| Cargo, every worktree | `.claude/target-worktrees`, set by the untracked `.claude/worktrees/.cargo/config.toml` (`scripts/build-env.sh`) | same |
| Cargo, CI | `~/ci-cargo-target/runner-<name>`, one per runner (`scripts/ci-cargo-target.sh`) | 120 GB or toolchain change, checked at job start |
| Xcode app builds | DerivedData `impress-suite` | one tree, overwritten in place |
| Pre-push gate | DerivedData `impress-prepush` | one tree |
| Proof and interlock runners | DerivedData `impress-proof.noindex/<app>` | one tree per app |
| CI xcframeworks | `~/ci-xcframework-store` | entries untouched for 3 days |
| Xcode, CI (impart-apps.yml) | `~/ci-derived-data.noindex/runner-<name>/<lane>` (`scripts/ci-derived-data.sh`) | 30 GB or Xcode change, checked at job start; dirs unused for 14 days by `clean-build-data.sh` |

Rules:

- **Never** set `CARGO_TARGET_DIR=$PWD/target-<task>` to avoid waiting on
  another build's lock. Wait instead: a warm build that queues is faster than a
  cold one, and the private dir is never deleted.
- `scripts/clean-build-data.sh` is the janitor. It dry-runs by default, and
  `--apply` deletes. `scripts/install-build-janitor.sh` runs it every Sunday at
  03:30. It removes merged, clean worktrees idle for 2 days, and leaves alone
  anything a build touched in the last 2 hours.
- Build scripts refuse to start below 50 GB free (`IMPRESS_MIN_FREE_GB`)
  instead of failing halfway with ENOSPC.
- Self-hosted CI lanes build xcframeworks with `IMPRESS_SKIP_X86=1`
  (decided 2026-10-14). The runner Mac is arm64, and no lane links x86_64:
  Debug macOS builds use `ONLY_ACTIVE_ARCH`, every `xcodebuild` passes
  `ARCHS=arm64`, and `swift build`/`swift test` build for the host. On a store
  miss the two x86_64 slices took 36% of the Rust time (291 of 801 s across
  eight five-slice builds). Each crate's `env-extra` string is part of the
  `~/ci-xcframework-store` key, so it must match in every lane that builds
  that crate. The `*-release.yml` workflows ship universal binaries and keep
  every slice.

## The impart lane runs on the build Mac

`impart - App Builds (macOS + iOS)` (`.github/workflows/impart-apps.yml`) is
the one Swift lane with a `pull_request` trigger, so it gates PRs. Until
2026-10-14 it ran on GitHub's hosted `xcode-27` image for every event and took
**1h45–2h on almost every run**. It now runs on the self-hosted runners for
pushes to main and for PRs from branches of this repository, and on the hosted
image only for PRs from forks.

### What was measured

On hosted runs that missed the xcframework cache (runs 38620534627,
38333122147, 38324588980):

| Step | Hosted, cache miss | Self-hosted, store miss (impart-tests.yml) |
|---|---|---|
| ImpressStoreFfi | 1261–2106 s | 324–373 s |
| ImbibCore | 971–1213 s | 221–225 s |
| ImbibVerbsFfi | 745–890 s | 193–350 s |
| ImprintCore | 778–893 s | — |
| impart macOS build | 252–461 s | 153–188 s |
| impart-iOS build (+ smoke on hosted) | 1109–1304 s | 124–128 s |

The same commit (f6ea40de, a koine bump) took ~1h45 on the hosted lane and
20 min for impart-tests.yml's macOS job on the Mac, with five framework misses.
A hosted run that hit the cache for all seven frameworks (38140265201) took
26 min, all of it Swift.

### Why the cache key was not the fix

The suspected cause was the key's `crates/**/*.rs` hash. That glob is only the
fallback. The key is already scoped to each crate's own path-dependency closure
(the "Scope the cache key" step in `.github/actions/xcframework/action.yml`),
and every run in the sample used the scoped key. The keys still changed on
nearly every PR, for real reasons:

- five of the seven frameworks have `impress-core` in their closure, and
  `impress-core` depends on koine, a git dependency whose rev most PRs bump.
  That changes the root `Cargo.toml` and `Cargo.lock`. #180–#184 changed
  nothing else under `crates/`;
- every closure includes `crates/impress-workspace-hack`, the hakari crate,
  whose manifest changes whenever any crate's dependencies change.

Narrowing the key further (option b) would only rescue `impress-helix` and
`scix-client-ffi`, which take about 3 minutes together. The expensive
frameworks really do change on most PRs. The cost of a miss was the problem:
on a hosted runner it is a cold release build of 600–900 crates for each
slice.

A second waste: `actions/cache` entries are scoped to the ref that saved them.
A PR's entries were invisible to main, so the post-merge push rebuilt the keys
its PR had just built, and each merged change paid for two cold builds. The
runner's store (`~/ci-xcframework-store`) is not scoped by ref, so after a
merge the main lanes restore what the PR built.

Persisting a Cargo target dir with `actions/cache` (option c) cannot fit. The
first cold build here left `target/` at 8.9 GB, and on 2026-10-14 the repo
held 11.2 GB of cache entries against its 10 GB quota.

### After the move (PR #187's own runs, 2026-10-14)

| Run | Frameworks | Rust steps | Job | Wall (incl. queue) |
|---|---|---|---|---|
| Hosted baseline, Rust-touching PR (#185) | 7 misses | ~4,900 s | ~1h50 | ~1h50 |
| 38638956741: workflow-only change | 4 store hits, 3 misses | 190 s | 10.1 min | 22.5 min |
| 38641974636: comment-only edit to `impress-core` | 5 misses, 2 hits | 491 s | 12.1 min | 23.5 min |

The second run invalidated every framework with `impress-core` in its closure.
Those are the five that cost ~80 minutes on the hosted runner, and they took
8 minutes here. The Swift half fell from ~25 min to ~3.5 min: macOS build
85 s, iOS build and install smoke 128 s.

**Warm DerivedData and a kept simulator** (later commits on #187). All seven
frameworks were restored in each of these runs, so the job is almost all Swift:

| Run | Runner state | macOS build | iOS build + install + launch | Job |
|---|---|---|---|---|
| 38645030048 | before: in-checkout DerivedData, a new device per job | 79 s | 109 s | 216 s |
| 38648827300 #1 | first job on impress-mac-2: cold DerivedData, the device's first boot (5 min 24 s, overlapped) | 274 s | 157 s | 487 s |
| 38647461799 #2 | warm DerivedData, a new device per job (that commit) | 34 s | 200 s, 189 s of it the boot | 270 s |
| 38648827300 #2 | warm DerivedData on impress-mac-4, its kept device's first boot (38 s, overlapped) | 26 s | 50 s | **108 s** |

A runner pays the cold row once per Xcode change. After that, a Swift-only PR
costs about 2 minutes of job time, and one that touches `impress-core`
about 9.5 minutes, of which 8 are the Rust frameworks.

**The new cost is queueing.** Both runs waited 11–12 minutes for a runner,
because a merge to main had just queued five self-hosted lanes ahead of them.
One of the four runners had also been offline since the disk filled on
2026-10-12. Its listener crashed with `No space left on device`, and launchd
stopped restarting it. `launchctl kickstart -k gui/$(id -u)/actions.runner.yipihey-impress-apps.impress-mac`
brought it back. When a PR's run sits in "queued", check
`gh api repos/yipihey/impress-apps/actions/runners` for a runner that is
offline before blaming the lane.

### How the self-hosted path differs

- It uses `scripts/ci-cargo-target.sh`, the runner's bounded target dir.
- Its framework variants (`env-extra`) are the same strings the other lanes
  on the Mac use: `IMPRESS_SKIP_X86=1`, plus `MACOSX_DEPLOYMENT_TARGET=14.0`
  for imbib-core and imbib-verbs-ffi, which is the set impart-tests.yml's iOS
  job builds. The store is keyed by variant, so the lanes share entries. Both
  runners build arm64 only. A first version of #187 built all five slices on
  the Mac to match the lanes as they were, and #189 then moved every lane to
  arm64. If a lane changes its variant, change this one with it, or the
  sharing stops without an error.
- Its DerivedData is a per-runner dir outside the checkout
  (`scripts/ci-derived-data.sh`), shared by the macOS and iOS builds. With
  `IMPRESS_SKIP_INSTALL=1`, nothing touches the developer's DerivedData or
  `~/Applications`. An in-checkout `.ci-derived` would be deleted by
  actions/checkout's clean, and both Swift builds would start cold.
- It boots its runner's own simulator device, `ci-impart-<runner>`. The
  device is created on the runner's first job and kept. Four runners and the
  developer share the Mac's device set, and two lanes that boot the same
  device shut it down under each other. A device made fresh for each job
  re-ran its first-boot data migration every time, which took 24 s in one run
  and 189 s in the next. The device boots before the macOS build, so the boot
  overlaps that build, and the app is uninstalled before each install so that
  every launch is a first launch.
- Xcode is `latest-stable`, as on every lane on the Mac. The hosted path keeps
  its 27.0 pin.
- `concurrency` cancels a PR's superseded run, which would otherwise hold one
  of the four runners. Runs on main are never cancelled.

### Fork PRs

Fork PRs stay on the hosted runner, and they still pay the cold build. The
repo is public, and code from a fork must not run on the build Mac. The routing
expression reads `github.event.pull_request.head.repo.full_name`, which a fork
cannot set. A branch of this repository can only be pushed by someone who can
push to main, and a push to main already runs every self-hosted lane. A fork
can still edit any workflow in its own PR, this one included. What stops that
is the repository's approval policy for outside contributors
(`all_external_contributors` on 2026-10-14). Keep that setting.

## DerivedData grows without bound, and why

Xcode names each build directory after a hash of the `.xcodeproj`'s **absolute
path**, and never removes one. Two habits of this repo turn that into unbounded
growth:

- every agent session gets a throwaway git worktree under
  `.claude/worktrees/<name>/`, so the same app hashes differently in each — and
  when the worktree is deleted, its multi-gigabyte cache is not;
- `.xcodeproj` is gitignored and regenerated by xcodegen, so it exists at as
  many paths as there are checkouts.

By 2026-09-09 this had reached **137 GB**, of which 36 GB belonged to twelve
worktrees that had not existed for weeks.

```bash
scripts/prune-derived-data.sh              # dry run
scripts/prune-derived-data.sh --apply      # delete dead caches
```

The default rule needs no judgement: every Xcode-made directory records its
origin in `info.plist` as `WorkspacePath`, and if that path is gone the cache
can never be reused by anything. `--stale-days N` additionally removes caches
whose project still exists but which nothing has touched in N days; that one
costs a full rebuild next time, so it is opt-in.

`build-impress-app.sh` runs the default rule before every build. That is
deliberate — it fires exactly when new DerivedData is being created, costs one
plist read per directory, and adds no background item to a Login Items list
that took real work to make legible (see [self-hosted-runners.md](self-hosted-runners.md)).

The fixed roots are never pruned at any age, and never emptied by
`--products` either: `impress-suite` (every app build from
`build-impress-app.sh`), `impress-prepush` (the pre-push dual-platform gate)
and `impress-proof.noindex` (proof and interlock runners), plus Xcode's own
`*Cache*.noindex` dirs. `~/MyApplications/<app>.app` is a symlink straight into
`impress-suite/Build/Products/Debug/`, and `~/Applications/<app>.app` is
`ditto`'d out of it, so emptying that root dangles the alias the user launches
from. The old per-app dirs (`imbib`, `imprint`, …) predate `impress-suite` and
age out like any other cache.

## Duplicate built products, and the two routes that diverge

`--products` empties `Build/Products` everywhere except the fixed roots. What it
removes are duplicate `.app` bundles — Spotlight indexes them, and it can rank
one above `~/Applications`.

This is not hypothetical. On 2026-09-08 the Xcode-GUI cache
`imbib-ecjsivaqpogiikarpfcihhtqkqxy` held an `imbib.app` built at 18:45, four
hours **newer** than the 14:51 install. The mechanism: the post-build phase
copies from `$BUILT_PRODUCTS_DIR`, so a GUI build installs from its own hashed
path, while `scripts/build-impress-app.sh` builds to `DerivedData/<app>/` and
refreshes the symlink. Build in the GUI and `~/Applications` moves while the
alias does not; build with the script and both move together. Compare them with
`scripts/check-app-installs.sh` before believing a build took effect.

`Build/Intermediates.noindex` is kept, so the next GUI build relinks rather than
recompiling. But this is remediation, not prevention: Xcode recreates the
products on the very next build. Only the Spotlight Privacy exclusion above
stops them from mattering.

### In-tree DerivedData

`.gitignore` calls a `DerivedData/` inside a checkout "non-standard — use
Xcode's global DerivedData instead". They appear anyway, from GUI sessions that
changed their build location, and they are invisible to the pruner's normal
sweep. It reports them rather than deleting, because one checkout's script has
no business deleting another checkout's cache.
