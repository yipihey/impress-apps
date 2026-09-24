# Next steps — the Mac orchestrator for wave 6

This is the operating brief for **one orchestrating Claude Code session on Tom's Mac**
that drives [plan-wave-6-tree-and-kit.md](plan-wave-6-tree-and-kit.md) to done with
**Opus 5 subagents**. The orchestrator plans, briefs, reviews, gates, commits and opens
PRs; the subagents write code. Nothing here needs Linux: every package compiles Swift,
launches an app, or both.

## Setup, once

```bash
cd ~/impress-apps            # or wherever the checkout is
git checkout main && git pull
./scripts/rust-gate.sh fmt && ./scripts/rust-gate.sh clippy auto
./scripts/build-xcframeworks.sh --fast impress-store-ffi
IMPRESS_SKIP_X86=1 crates/impel-tools/build-xcframework.sh
cd apps/imbib/PublicationManagerCore && swift build && swift test && cd ../../..
# (no tree flag since W5: every chassis app renders the layout tree)
```

Read before briefing anyone: `CLAUDE.md` (every "Definition of done" bullet and the
SwiftUI pitfalls), `docs/ADR-0031-query-addressed-panes-and-the-layout-tree.md` (D5, D6,
D7, D11), `docs/ADR-0033-agent-surfaces.md` (D2, D7), `docs/plan-layout-tree.md`,
`docs/plan-agent-surfaces.md` (the two Mac-pass entries), `docs/chassis-capability-matrix.md`
§ view kinds and § HTTP automation, `docs/keyboard-grammar.md`. Load the
`impress-swiftui-pitfalls` skill and pass its rules into every Swift brief.

## How the orchestrator works

1. **One branch and one PR per work package** (`claude/wave6-w0-tier-b`, …), from `main`.
   Never force-push. Merge `main` in, never rebase a pushed branch.
2. **One Opus 5 subagent per package**, briefed with: the package's row from the plan
   verbatim, the exact files it owns, the files it must not touch, the gate commands, and
   the proof it must produce. Two subagents run in parallel only when their file sets are
   disjoint (W0 ∥ W1a ∥ W1b ∥ W1c; nothing else).
3. **The orchestrator verifies, the subagent asserts.** Before a PR is marked ready the
   orchestrator itself runs the full gate, launches the app, and performs the live proof
   the row names, reading `/api/logs?category=layout` and `?category=surface` and the
   Tier-B report. A subagent's "verified" is a claim until reproduced.
4. **Log as you go.** Append a dated entry to the plan's session log before every push:
   what was proven live, what was found, what was left. The matrix rows are the checklist;
   flip a cell only after the proof.
5. **Commits** in the repo's voice, one per fix, ending with
   `Co-Authored-By: <model name> <noreply@anthropic.com>`. No model identifiers anywhere
   else in the tree. PR bodies follow `.github/PULL_REQUEST_TEMPLATE.md`.
6. **Mark ready, then stop the package.** A PR is ready when its row's proof is in the
   log and the PR-level checks are green (the impart app-build lane is base-red and known:
   package resolution on the hosted runner; say so once in a comment and move on). Wait
   for Tom to merge before starting the next dependent package's Swift.
7. **Ask first** on anything in the plan's "Ask first" list: stop the package, write what
   you saw in the PR, and move to a package that does not depend on the answer.

## The subagent brief template

```
You are implementing <WP> of docs/plan-wave-6-tree-and-kit.md in <checkout>, branch <branch>.
Read first: <the list above> and the plan row for <WP>, verbatim below.

<row>

You own: <files>. Do not touch: <files>. Rules: the plan's "Rules for every package";
CLAUDE.md's Definition of done bullets; the impress-swiftui-pitfalls skill (loaded).

Gates before you report: ./scripts/rust-gate.sh fmt; ./scripts/rust-gate.sh clippy auto;
cargo test -p <crates>; ./scripts/check-uniffi-bindings.sh; ./scripts/check-schema-refs.sh;
./scripts/check-kit-deps.sh; ./scripts/check-chassis-deps.sh; cd apps/imbib/PublicationManagerCore
&& swift build && swift test; the app builds (scripts/build-impress-app.sh impress Debug).

Proof: <the row's proof, as steps against the running app>. Do not commit; report the
exact files changed, the tests added and their results, every gate's result, and every
deviation from this brief with the reason.
```

## Package-specific notes for the briefs

- **W0 (Tier B)**: copy the shape of `crates/imprint-selftest`'s Tier B (auto-skip when
  the port is down; `CapabilityResult`s; the `run-selftest --tier b` verb). Drive
  `SiblingApp.impress`'s port (23125). Restore what you change: delete the layouts and
  surfaces the catalogue created, re-apply the preset that was live.
- **W1a (reprobe)**: `crates/impel-tools/src/lib.rs` — `BACKENDS` becomes a `RwLock`;
  `configure` keeps its signature; add `reprobe() -> ToolBackends`; `call_tool` reads the
  current state. impel's `CounselToolRegistry` keeps working unchanged. Regenerate
  `impel_tools.swift` (the impel-tools bindings lane checks it). Swift side in
  `apps/impress/macOS/Services/ImpressVerbHost.swift`.
- **W1b (source reason)**: the shapes are contracts — `RenderTree` (Rust `resolve.rs`,
  Swift `RenderTree.swift`), `SurfaceRenderResult` (`dto.rs`), the `/api/surface/<id>/render`
  body. Additive fields only (`reason: Option<String>` on the placeholder node,
  `source_errors: Vec<SourceError>` on the result). Re-bless the goldens with
  `UPDATE_GOLDEN=1` and read the diff: only placeholders gain a reason.
- **W1c (simulator)**: `.github/workflows/imbib-tests.yml` — after the smoke,
  `xcrun simctl terminate "$UDID" com.impress.imbib || true` and
  `xcrun simctl shutdown "$UDID" || true` in a step with `if: always()`. Grep the other
  workflows for `simctl launch` and do the same.
- **W2–W4 (leaves)**: the section's `PaneQuery` is already in `presets.rs`; the Swift work
  is the `info` factory for that record kind and the row style through
  `LayoutPaneRowMapper`. Do not port a tab by copying it — feed the existing view its
  inputs from `PaneContext`. For `source`: `PaneSessionRegistry` already exists; the
  editor's `NSTextView` is created once per `SessionId` and handed to whichever pane shows
  it. The proof for every leaf includes: h/l walks the new panes; j/k inside them; a row
  click publishes on the channel; the matrix rows for that kind.
- **W5 (deletions)**: do this as a sequence of small commits, one type at a time, building
  every app between them. `git grep -n PaneLayoutState apps/imprint/Shared` must still
  find imprint's own editor-window type — that one stays.
- **W6 (kit)**: move files with `git mv` so history follows; the registry's `builtin`
  becomes the kit's two factories plus a `register(_:)` PMC calls from `ChassisRootView`'s
  startup; `check-kit-packages.sh` is `check-chassis-deps.sh`'s pattern over
  `packages/ImpressLayout/Package.swift` and `packages/ImpressSurface/Package.swift`.

## Definition of done for the orchestrator

W0–W6 merged (or, for W6, open and ready with its lane green), the plan's session log
carrying one dated entry per package with what was proven live, the capability matrix's
view-kind rows all "rendered", `impress.layoutTree.enabled` gone, and
`scripts/check-kit-standalone.sh` green in CI. Then stop.
