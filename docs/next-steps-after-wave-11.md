# Next steps after Wave 11 (2026-09-29)

This succeeds the [Wave 10 handoff](next-steps-after-wave-10.md), which remains historical evidence. Main is `c4330719` and contains P5c1–13 in PRs #148–160. Wave 10's full workspace result predates these changes and does not verify Wave 11. The P5c contract decisions were authorized on 2026-09-29; [the proposal](p5c-contract-proposal.md) defines the contract baseline and the platform routes retained for this phase.

## Package status

| Package | Status at handoff |
| --- | --- |
| P5c1–13 | Merged to main as PRs #148–160. Their package verification is recorded in the dated pipeline log. |
| P5c14 tag reads | Final Rust run: 1,755 passed, 0 failed, 3 ignored; quick gates are green. Final native archive proof remains pending. |
| P5c15 library deletion | Implemented on its branch. Final integrated verification and merge remain pending. |
| P5c16–18, P5c20–21 consumers | Focused Swift bridge suites passed with 6, 9, 9, 10, and 14 tests respectively. Final cohort/native verification and merge remain pending. |
| P5c19 comment consumers | Audit-only: no production callers were found, so no migration or PR is needed. |
| P5c22–24 route retirement | Implemented on cumulative branches; final verification and merge remain pending. P5c22's isolated proof passed two XCTest cases and 14 transport calls after fixing canonical UUID casing. Rerun it with the final cohort. |

No P5c14–24 package is merged to main at this checkpoint. P5c22's earlier proof is at `/tmp/impress-p5b-transport-pqdebcjr/`; it predates the final P5c21 Rust/store baseline merge. Build-only preflights (which did not launch apps) are at `/tmp/impress-p5b-transport-asbdasbp/build.log` (P5c22 imprint), `/tmp/impress-p5b-transport-fq17dfjw/build.log` (P5c23 implore), and `/tmp/impress-p5b-transport-lg_fijol/build.log` (P5c23 impart). The P5c23 builds also predate the final baseline merge and do not replace final native proofs.

Focused Swift evidence is recorded in `/tmp/impress-p5c16-swift-tests-final.log`, `/tmp/impress-p5c17-swift-tests-final.log`, `/tmp/impress-p5c18-swift-tests-final.log`, `/tmp/impress-p5c20-swift-tests-final.log`, and `/tmp/impress-p5c21-swift-tests-final.log`. P5c14 evidence is in `/tmp/impress-p5c14-tests-final.log`, `/tmp/impress-p5c14-gates-final.log`, and `/tmp/impress-p5c14-frameworks-final.log`; P5c15's current verification record is `/tmp/impress-p5c15-final-verify.log`.

## Current branch checkpoint

P5c21 contains the final P5c14 baseline; P5c22–24 are cumulative through that P5c21 tip. The heads below are local checkpoints, not claims of PR creation or merge:

| Package | Branch head | Package | Branch head |
| --- | --- | --- | --- |
| P5c14 | `6832ede9` | P5c20 | `ee3bb1ac` |
| P5c15 | `35cd3fbf` | P5c21 | `1a18b25f` |
| P5c16 | `a6ba1405` | P5c22 | `fa09cac2` |
| P5c17 | `02048838` | P5c23 | `687f2a4f` |
| P5c18 | `47aa13ac` | P5c24 | `5e9ea9ea` |
| P5c19 | `8cdc35c4` |  |  |

## Remaining verification and integration

1. Complete P5c14–15 package gates, generated-table checks, supported native archive rebuilds, and isolated proofs. P5c14's Rust and quick-gate result does not close its archive proof.
2. Recheck P5c16–18 and P5c20–21 against the final merged baseline, then run the P5c22–24 native route-retirement proofs. For each retired URL, retain both a 404 assertion and a successful generated-verb outcome. Preserve the scratch-store refusal snapshots and route/verb behavior checks.
3. Regenerate generated verb pages/tables from the capability test dumps; never hand-edit generated `docs/verb-*.md` tables or `docs/verbs/*.md` pages. Run the quick gates, touched-crate tests, capabilities/effects checks, and supported macOS/iOS archive builds on the integrated cohort.
4. Review and merge the completed P5c packages to main. Then run the full native workspace suite on that exact main commit with `cargo test --workspace --features native --no-fail-fast -- --test-threads=1`. Record the commit, exact pass/fail/ignored counts, archive/native evidence, environment, and log paths before updating this handoff.

The Wave 10 full workspace result (`3c56dfbb`, 4,478 passed, 0 failed, 26 ignored across 223 result groups) is historical only. It is not the Wave 11 completion gate.

## Platform routes that remain intentional

P5c retires only the registrations approved after their consumers moved. Preserve the exceptions in the proposal:

- Imprint document operations that enqueue through `DocumentRegistry` and return operation acknowledgments, plus caret-sensitive citation insertion and other live-editor behavior.
- Impart conversation writes that enqueue through `ConversationRegistry` and return accepted/queued responses with reserved IDs.
- Implore ray-grid viewer routes and raw SVG/render endpoints tied to live viewer state or binary response semantics.
- Imbib's nested tag-tree formatter, `POST /api/libraries/add-papers`, tag mutations, library sharing/activity/assignment routes, and other retained collaboration behavior.
- App status/log diagnostics, accounts/mailboxes/messages, and app-only manuscript, revision, compile, e-ink, hardware, and viewer operations listed in the proposal.

Earlier route-parity tests are evidence of behavior before retirement; do not describe those HTTP paths as currently available. The P5c22–24 tests should instead pair retired-route 404s with generated behavior. Do not add queue-only verbs that bypass the native registries or weaken queued acknowledgment/live-editor semantics.

## Integration environment

Coordinate shared Cargo caches serially; use `CARGO_INCREMENTAL=0` and the owned test recipe `/tmp/impress-cargo-test-isolated.sh`. Wave 10's cache layout is `.claude/target-p7-consumer` for tests/CLI, `.claude/target-p7-schema` for clippy/generated docs/kit gates, and `.claude/target-p5b-native` for release native archives. Confirm current ownership before starting work; do not race another gate. Rebuild the supported arm64 archive cohort before using refreshed frameworks, and keep package proof derived data, ports, stores, and devices isolated. Use `IMPRESS_SKIP_INSTALL=1`; never touch the user's running apps, launchers, or real store. Preserve normal hooks and do not force-push or bypass them.
