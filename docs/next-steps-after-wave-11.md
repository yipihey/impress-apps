# Next steps after Wave 11 (2026-09-29)

This succeeds the [Wave 10 handoff](next-steps-after-wave-10.md). The original open packages and subsequent S2/S3/W3 follow-ups are recorded in the Wave 9/10 handoffs. Wave 11 completes the approved [P5c contracts](p5c-contract-proposal.md), consumer migrations and route retirements. All implementation packages are merged through main `2d4bf63f` (PR #170). The full native workspace integration run is in progress.

## Package status

| Package | Status |
| --- | --- |
| P5c1–13 | Merged #148–160; dated package evidence is in the pipeline plan log. |
| P5c14 tag reads | Merged #161. 1,755 Rust tests passed, zero failed, three ignored; all quick gates, full archives and final native proof passed. Includes cross-handle cache invalidation and warm-cache effect observation. |
| P5c15 library deletion | Merged #162. 95 Rust tests passed, zero failed, three ignored; all gates, full archives and native proof passed. Explicit file cleanup, deduplication and full preflight validation are covered. |
| P5c16 shared read consumers | Merged #163. 44 capability tests, six focused Swift tests, all gates and final impel native proof passed; impart artifact consumer compiled. |
| P5c17 publication consumers | Merged #164. 44 capability tests, nine focused Swift tests and all gates passed. |
| P5c18 figure export consumers | Merged #165. 44 capability tests, nine focused Swift tests and all gates passed. |
| P5c19 comment consumers | Audit-only: no external production caller exists. No unused bridge API was introduced. Audit `8cdc35c4` is carried into this handoff's plan-log update. |
| P5c20 container consumers | Merged #166. 44 capability tests, ten focused Swift tests and all gates passed. |
| P5c21 import consumers | Merged #167. 44 capability tests, fourteen focused Swift tests and all gates passed. |
| P5c22 imprint retirement | Merged #168. 44 capability tests, all quick gates and final native proof passed. |
| P5c23 figure/conversation retirement | Merged #169. 63 Rust tests, all quick gates, regenerated docs, full archives and both native proofs passed. |
| P5c24 imbib retirement | Merged #170. 95 Rust tests, all quick gates, regenerated docs, full archives, final native proof and normal macOS/iOS pre-push builds passed. |

Each consumer capability run had zero failures and three ignored tests. Every merged package passed its normal pre-push hook. When the hook selected dual-platform compilation, both builds passed; imprint-only retirement correctly selected the hook’s documented scope-based skip after formatting/schema checks. Root reviewed the changes, fetched main freshly, verified main ancestry and matched the remote head before merging. Main-only merges changed session-log entries; existing code verification applied to unchanged source. Hosted CI may still run after a local-gate-verified merge; do not confuse local evidence with all hosted checks having completed.

## Final native evidence

| Package/app | Proof output | XCTest cases / shared calls | Owned PID, exited |
| --- | --- | --- | --- |
| P5c14 imbib | `/tmp/impress-p5b-transport-xz36o8we/output/` | 3 / 37 | 51204 |
| P5c15 imbib | `/tmp/impress-p5b-transport-xqt71k0m/output/` | 4 / 37 | 57922 |
| P5c16 impel | `/tmp/impress-p5b-transport-lu8quz0f/output/` | 1 / 2 | 73083 |
| P5c22 imprint | `/tmp/impress-p5b-transport-y9waq_71/output/` | 2 / 14 | 84629 |
| P5c23 implore | `/tmp/impress-p5b-transport-z9kipzlz/output/` | 2 / 5 | 90865 |
| P5c23 impart | `/tmp/impress-p5b-transport-au01yhmg/output/` | 1 / 8 | 90909 |
| P5c24 imbib | `/tmp/impress-p5b-transport-zjp98zqt/output/` | 4 / 44 | 22731 |

SQLite ownership/linkage checks passed. Retirement proofs pair old-route 404 responses with generated behavior, retained callback effects and refusal snapshots. The P5c24 initial proof exposed a private-callback reader call and incorrect raw citation field/UUID formatting expectations; those fixtures were corrected while preserving exact identity checks. A subsequent fixture compile error used `bodyJson` on `HTTPResponse`; `0407299f` corrected it to `body`. The final proof above passed. Earlier failures remain in `/tmp/impress-p5b-transport-z9589ulo/` and `/tmp/impress-p5b-transport-kqv_82rh/`.

P5c14 final logs use `/tmp/impress-p5c14-{tests,gates,frameworks,native-proof}-verified.log`. P5c15–24 Rust/gate logs use `/tmp/impress-p5cNN-final-{verify,gates}.log`; native/archive details are recorded in the dated pipeline log. Focused Swift logs are `/tmp/impress-p5cNN-swift-tests-final.log` for N = 16, 17, 18, 20, 21. All twenty framework bundles were copied with APFS clones; changed native consumers were rebuilt with supported arm64 macOS/iOS/simulator slices, swiftformat off PATH and no `--fast`.

## Remaining integration gate

All retirement PRs are merged. Run `cargo test --workspace --features native --no-fail-fast -- --test-threads=1` on exact merged main with an isolated scratch store. Record the commit, result totals and log here. The prior Wave 10 full workspace result (`3c56dfbb`, 4,478 passed, zero failed, 26 ignored across 223 groups) is historical and does not verify this batch.

## Intentional later scope

The P5c proposal retains platform contracts whose queue, live-editor or binary semantics differ from the generated store verbs:

- Imprint queued document operations, caret-sensitive citation insertion and live-editor operations.
- Impart queued conversation writes and reserved-ID acknowledgments.
- Implore ray-grid viewer and raw SVG/render routes.
- Imbib's nested tag tree, library add-papers, tag mutations, sharing/activity/assignment and collaboration routes.
- App diagnostics and the remaining app-only account/mailbox/message, compile, e-ink, hardware and viewer operations listed in the proposal.

Four scenario cases intentionally remain in code: manuscript history, WAL health, PDF-pane reading and the Reading preset. Reachability and restoration remain runner gate/finally logic. R3 command-palette overrides are D-R13's later work; appearance/modal editing and app-specific LaTeX/export/AI preferences retain their existing owners. This batch does not claim those migrations.

## Known intermittent test and session setup

The `imbib-library-service_import-papers` example `import-fetched-record` previously produced an all-zero import summary intermittently. No ordering/concurrency cause was established. Preserve the assertion and diagnostic; do not add an exception or mark the effect unverified to obtain a green gate. Wave 10 records the earlier reproductions and focused passes.

Use one worktree per package and unset the initial upstream. Coordinate Cargo caches serially with `CARGO_INCREMENTAL=0`: `.claude/target-p7-consumer` for tests, `.claude/target-p7-schema` for gates/docs, `.claude/target-p5b-native` for archives. `/tmp/impress-cargo-test-isolated.sh` supplies owned scratch store/workspace/device/cache paths. Regenerate verb tables from capability dump tests and pages from `gen-verb-docs`; never hand-edit either.

Use owned derived data, automation port, device ID and scratch store for native proofs. Set `IMPRESS_SKIP_INSTALL=1`; never touch Tom's running apps, launchers or real store. Quit only the process launched by the proof. Preserve normal hooks, never force-push or stash, and keep build artifacts ignored. Completed old build caches were pruned after checking active processes; proof logs and result bundles were retained.

P5c22 capability tests ran directly rather than through the outer scratch wrapper. A read-only audit confirmed the persistence tests initialize unique temporary store/workspace/settings/cache roots internally before service singletons (`tests/support/example_fixtures.rs`), or use in-memory SQLite; census/descriptor/keymap tests do not invoke persistence. Remaining runs use the outer wrapper as an additional guard.
