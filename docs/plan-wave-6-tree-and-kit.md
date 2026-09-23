# Plan: wave 6 — the tree carries the chassis, and the kit can leave

**Status:** planned 2026-09-23, after PR #44 merged wave 5.
**Builds on:** ADR-0031 (the layout tree; D6 sessions, D11 migration), ADR-0033 (agent
surfaces; D7 the standalone cut), `docs/plan-layout-tree.md` (L0–L7 done, L8 open),
`docs/plan-agent-surfaces.md` (S0–S10, V1–V5 done).
**Executed by:** Opus 5 agents on Tom's Mac, driven by one orchestrator — see
[next-steps-mac-orchestrator.md](next-steps-mac-orchestrator.md). Every package here needs
Xcode and a running app at least once, which is why none of it was done from Linux.

## Goal

Done means: **every chassis app renders its sections as panes of the layout tree, with no
`legacy` pane left for a section the query algebra can express; the flag is gone; the
three pre-tree state types are deleted; and the layout + surface layer builds as its own
Swift package and its own Rust crate set with a pinned dependency line — so it can leave
the repository as a kit when Tom decides.** Each step leaves the apps shippable.

## What is true today

- The tree renders in impress behind `impress.layoutTree.enabled`. Five view kinds render
  (`outline`, `list`, `info`, `surface`, `legacy`); four are placeholders on purpose
  (`pdf`, `notes`, `bibtex`, `source`). The `legacy` kind hosts today's whole
  `TabContentView` inside one pane (ADR-0031 D11).
- `crates/impress-layout-service/src/presets.rs` already expresses each app's sections as
  named `PaneQuery`s, except the five in `MATERIALIZE_FIRST` (sharedWithMe, SciX
  libraries, the online search forms, tags, reviewQueue), which are not values in the
  algebra and stay `legacy`-hosted until a materialization exists.
- The Swift host is `apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Chassis/Layout/`
  (3,600 lines: `LayoutModel`, `LayoutController`(+Automation), `LayoutTreeView`,
  `ViewKindRegistry`, `PaneSessionRegistry`, `LayoutPaneRowMapper`, `LayoutSurfacePaneView`,
  `SurfaceRecordListRows`). It imports PMC-internal types in three places only: the row
  mapper (`KindTaggedRow`, `RecordViewerRegistry`), the info pane (`DetailView`) and the
  legacy pane (`TabContentView`).
- Pre-tree state that L8 deletes: `PaneLayoutState` (PMC, 9 files; imprint's editor window
  has a separate one that is NOT in scope), `SidebarComposition` (17 files), `FocusedPane`
  (6 files).
- `packages/ImpressChassis` exists (1,400 lines, no dependencies, policed to zero by
  `scripts/check-chassis-deps.sh`); `packages/ImpressSurface` is kit-grade (Keyboard,
  Theme, Logging). `scripts/check-kit-deps.sh` pins `impress-pane-query`, `impress-layout`
  and `impress-surface` away from `impress-core`; the two service crates and the FFI reach
  impress-core through the store, which D7 allows "until the store trait itself is
  generic".
- Three findings from the wave-5 Mac round are open: `impel-tools::configure` probes once
  per process; a failed surface source draws a reason-less placeholder; the imbib iOS test
  lane leaves a simulator imbib listening on 23120 with a scratch store.

## Rules for every package

- **Rust first.** Anything that decides — which panes a section is, what a placeholder
  says, whether a backend is reachable — is Rust with a test. Swift maps.
- **Sessions survive layout mutations** (ADR-0031 D6): a session-bearing pane reads its
  `NSTextView`, undo stack or compile from `PaneSessionRegistry`, never from view identity.
- **Keyboard grammar unchanged**: h/l over the tree, j/k in a pane, ⌘0 / ⌥⌘0 / ⌃⌘S as
  resizes, ⌃⌘1–9 ordinals, all under `.keyboardGuarded`.
- **A leaf is done when its capability-matrix rows are re-proven** (context menu, rename,
  delete, drag, drop, counts, select → detail) **and the Tier-B catalogue (W0) passes
  against the running app** with that leaf's preset applied.
- **The workspace gate before every push**: `./scripts/rust-gate.sh fmt`,
  `./scripts/rust-gate.sh clippy auto`, `./scripts/check-uniffi-bindings.sh`,
  `./scripts/check-schema-refs.sh`, `./scripts/check-kit-deps.sh`,
  `./scripts/check-chassis-deps.sh`; PMC `swift build && swift test`; the app builds.
- **Bindings**: any `#[uniffi::export]` change regenerates `impress_store_ffi.swift` in the
  same commit (`./scripts/build-xcframeworks.sh --fast impress-store-ffi`, swiftformat off
  PATH, judge by declarations gained and lost).
- **Never**: a `.focusable()` around a text editor; `@State` read inside a `Task`; a
  schema ref spelled from memory; a second definition of anything the chassis already
  has (the `legacy` pane exists so nothing is rebuilt to migrate it).

## Work packages

| WP | Deliverable | Depends on | Proof |
|---|---|---|---|
| **W0** | **Tier-B self-test for the tree and surfaces.** `crates/impress-layout-service` (or a new `impress-tree-selftest`) gains a `--tier b` catalogue that drives the RUNNING app over `/api/layout/*` and `/api/surface/*` (auto-skips when 23125 is down, like imprint's): apply a preset by ordinal and read the tree back; split / close / swap / resize and see `version` move; save / apply / delete a layout; select in a `list` pane and see the `info` pane's `item` follow through the channel; show a surface and dispatch an event; ⌃⌘S-style resize to `HIDDEN_SHARE` and back. Exposed as `layout-selftest-service_run-selftest --tier b` (MCP, CLI). | — | runs green against impress with the flag on; every later package adds its capability here |
| **W1** | **The three wave-5 findings.** (a) `impel-tools`: `configure` stores its result behind a lock and a `reprobe()` re-runs the reachability probe; `call_tool` refuses per the CURRENT state; impress's `ImpelToolsVerbHost` re-probes when a call is refused as unavailable, rate-limited to once a minute, and logs the transition — an app started after impress becomes reachable without a relaunch. (b) A failed source keeps its reason: `SurfaceRuntime::render` records `SourceError { name, message }` per failed fetch; `SurfaceRenderResult` (and the FFI/HTTP render body) gains `source_errors`; the placeholder a template draws for a path under a failed source names that error (a new optional `reason` on the placeholder render node, additive — the Swift `RenderTree` Codable and `SurfaceView` show it); the runtime logs the failure through the `log` facade so `?category=surface` carries it. Golden re-blessed; the signal-explorer and paper-triage goldens unchanged except where a placeholder gains a reason. (c) `imbib-tests.yml`'s iOS smoke terminates the launched app and shuts the simulator down in an `always()` step, so a runner on a dev Mac never leaves a scratch-store imbib on 23120; the same step is added to any other lane that launches a simulator app. | — | (a) impel-tools tests for reprobe + refusal; live: launch imbib after impress, the next surface call succeeds. (b) golden + a Tier-A capability whose source verb fails and whose tree carries the reason; live: imprint closed → the pane says "imprint is not running". (c) after the lane runs, `lsof -i :23120` on the runner shows only the desktop imbib |
| **W2** | **L8 leaves 1–3: figures, mail, agents.** In D11 order, the three registry-resolved sections. For each: the app's default preset in `presets.rs` declares the section as real panes (`outline` + `list` + `info` over the section's `PaneQuery`, roles `navigator`/`list`/`detail`) instead of `legacy`; the Swift `info` factory renders that kind's detail (implore's figure detail, impart's message detail, impel's task/agent-run detail) through the existing `RecordViewerRegistry` detail factories, not a rewrite; the section's row style and context menu come through `LayoutPaneRowMapper` + the row registry as `list` already does for publications. The section's `legacy` route stays reachable until the leaf's matrix rows are re-proven, then the preset stops naming it. | W0 | per leaf: matrix rows re-proven live; Tier B green with that app's preset; `/api/layout/tree` shows no `legacy` pane for the section |
| **W3** | **L8 leaf 4: the outline sidebar.** The navigator pane becomes the app's sidebar for real: an `outline` pane whose rows are the app's sections and their query-defined children (libraries, collections, smart sections, flagged, dismissed), with counts from the same queries the badges use today; selecting a row `set_query`s the `list` pane through the channel (ADR-0031 D5). The five `MATERIALIZE_FIRST` sections appear as rows that open a `legacy` pane scoped to that one section (a per-section legacy, not the whole chassis) — recorded as the remaining materialization work, not hidden. Drag/drop, rename, delete on collection rows go through the chassis' existing capabilities (`capabilities(of:)`), re-proven per matrix row. | W2 | the matrix's sidebar rows re-proven; Tier B: select a collection row → the list pane's query changes → `info` follows a selection |
| **W4** | **L8 leaves 5–6: publications and manuscripts, and the four view kinds.** The two ADR-0022 routing exceptions. `pdf`, `notes` and `bibtex` become real view kinds over `PDFTab`/`NotesTab`/`BibTeXTab` fed by the pane's `single_item` (the same resolution `info` uses), with the detail lifecycle they need supplied by the pane context rather than the old tab host; `source` becomes a session-bearing view kind whose editor and undo stack come from `PaneSessionRegistry` (L6's shipped registry, so far unused) — the manuscript editor survives every split, swap and preset change without `.id(manuscriptID)` (ADR-0018 D4 restated in D6). imbib's Triage / Reading / Full and imprint's Writing presets compose these kinds; the legacy pane stops being named by any preset except the five materialization sections. | W3 | matrix rows for pdf/notes/bibtex/source flip from "placeholder" to "rendered"; Tier B: apply Reading → the pdf pane shows the selected paper; split the editor twice → the same session (typed text and undo) is in the moved pane |
| **W5** | **Flag off, state types out.** `impress.layoutTree.enabled` is removed and the tree is the only root for the chassis apps (impress, impel, implore, impart, imprint's chassis root; imbib's own pre-chassis `ContentView` is out of scope and says so). `PaneLayoutState` (PMC), `SidebarComposition`(+Key) and `FocusedPane` are deleted with everything that read them; ⌘0 / ⌥⌘0 / ⌃⌘S / h / l route only through `LayoutController`. `AppShellConfiguration` shrinks to what the presets do not carry (bindings of `.tags` etc. become preset data where they can). The ADR-0019 D5 importer that turned `PaneLayoutState` into presets is deleted with its input type. | W4 | `git grep` for the three names is empty outside imprint's editor window; every app builds; the matrix's "flag" notes are gone; Tier B green on every app |
| **W6** | **The kit can leave.** Swift: `packages/ImpressLayout` (kit-grade: ImpressRustCore, ImpressKeyboard, ImpressTheme, ImpressLogging, ImpressSurface — nothing else, policed by `check-chassis-deps.sh`'s pattern in a new `check-kit-packages.sh`) receives `LayoutModel`, `LayoutController`(+Automation), `LayoutTreeView`, `PaneSessionRegistry`, `ViewKindRegistry` (with only the `placeholder` and `surface` factories built in) and `LayoutSurfacePaneView`; PMC keeps `LayoutPaneRowMapper`, the rows/info/pdf/notes/bibtex/source factories and registers them into the registry at startup — the kit renders a tree of placeholders on its own, which is the standalone proof. Rust: `docs/kit-manifest.md` names the crate set (`impress-service-core`, `-macros`, `impress-pane-query`, `impress-layout`, `impress-surface`, their `*-service` crates, `impress-capabilities-kit`, `impress-store-ffi`) and the one dependency the kit still has on this repository (`impress-core`'s store, behind the `sqlite` feature); `check-kit-deps.sh` extends to the service crates and the FFI with that single allowed reach, and a `scripts/check-kit-standalone.sh` copies the kit crates plus `impress-core` into a scratch workspace and `cargo check`s them, so "can leave" is a command, not a claim. | W5 | the new checks green in CI (a `kit.yml` lane); a throwaway app target that links only `ImpressLayout` + `ImpressRustCore` shows a tree of placeholders and one surface |

Order and parallelism: W0 and W1 first, in parallel (disjoint files); W2 → W3 → W4 → W5
strictly in sequence (each leaf changes the same registry, presets and matrix); W6 last.
One PR per row; the orchestrator marks each ready with a comment listing what was proven
live, and does not start the next row's Swift until the previous PR is merged (Rust-only
preparation may start earlier on a branch).

## Ask first (stop and report instead of deciding)

- Any change to the layout or surface **vocabulary**, a schema ref, or a verb's arguments.
- Materializing any of the five `MATERIALIZE_FIRST` sections (that is a design decision
  about sync, not a leaf).
- Anything that would make a kit package depend on PMC or a kit crate on a domain core.
- Deleting or replacing anything outside the three named state types and the flag.

## Session log (append-only)

- 2026-09-23 — Planned. The three findings, W0's Tier-B catalogue and the L8 order come
  from the wave-5 Mac round (`docs/plan-agent-surfaces.md` § "Mac pass, round 2") and
  ADR-0031 D11; the kit cut is ADR-0033 D7 executed last, as written.
