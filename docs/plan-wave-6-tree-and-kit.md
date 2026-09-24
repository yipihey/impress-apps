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

- 2026-09-23 — **W0 done.** `crates/impress-layout-service/src/tier_b.rs`: seven
  capabilities plus a restore, run against a live impress on 23125 and green 8/8
  (`impress layout-selftest-service_run-selftest --tier b`, 267ms). What was actually
  proven, with the shapes that proved it: `{"op":"apply-layout","ordinal":1}` rebuilt the
  tree to three panes (outline, list, info) at version 14; `Verb::Split`/`Resize`/`Swap`
  /`Close` moved `version` 14→15→16→17→18→19 with no step standing still;
  `save-layout` → `/api/layout/layouts` → `apply-layout` by name → `delete-layout`
  round-tripped `__tier-b-selftest-layout__` and left the list empty; a `select` on tile 2
  put the id on channel 1, which is the channel tile 3's `item` parameter declares as its
  source — the list→info path, read at the one point the tree exposes it; a scratch
  surface rendered, took `{"widget":"bins","kind":"change","value":17}` and a `click`,
  and `bins-chosen` reached `/api/surface/<id>/events`; `resize-share` took tile 1 to
  1 → 0.0001 → 1, under and back over the 1e-3 hidden ceiling.
- Restoration was checked rather than assumed: `tiles`, `windows` and `channels` compared
  byte-identical before and after the run, with no layouts and no surfaces left behind.
  Only `version` moved (12 → 27), which is what monotonic means.
- Two things found on the way. **`apply-layout`'s ordinals are the union** of the shipped
  presets and the named layouts (`presets::ordinal_targets`), while
  `/api/layout/layouts` numbers saved rows from 1 on their own — so an ordinal read out of
  that list addresses something else. The restore applies by name for that reason, and
  ordinal 1 in capability 1 is impress's Default preset, which is the only preset impress
  ships. **`scripts/check-kit-deps.sh` defaults `CARGO_TARGET_DIR` to
  `/home/user/impress-apps/target`**, a Linux path that does not exist on a Mac; the gate
  passes with the variable set. Left alone — it belongs to whoever owns the script.
- The dependency question the brief left open was decided against `impress-app-client`:
  its typed clients are built on `imbib-service` and `imprint-service`, and a kit-adjacent
  crate does not take on two domain stacks to make seven loopback requests. Raw `reqwest`,
  as `imprint-selftest` does.
- Not proven here: the app was already built and running from earlier today, so this
  round did not exercise `scripts/build-impress-app.sh`. Every later package adds its
  capability to this catalogue, per the row.

- 2026-09-23 — **W2 done: all three leaves proven live, with real rows.** (Mail needs PR #50
  on `main` first; see below.)
  The row's first sentence turned out to be already true in Rust: `implore_default()`,
  `impel_default()` and `impart_default()` all build `outline` + `list` + `info` through
  `three_columns(...)` over `q::figures()` / `q::agents()` / `q::mail()`, and the string
  `legacy` does not occur anywhere in `presets.rs`. Nothing was ported and nothing was
  removed — the "preset stops naming `legacy`" half of the row had no work in it, which is
  worth recording so the next leaf does not go looking for it again.
- The whole gap was one Swift line. `LayoutInfoPaneView` hard-coded
  `DetailView(publicationID:)`, so every `info` pane in the three apps resolved a real id
  and then fell into "Detail Unavailable". The fix is a dispatch on
  `PaneContext.primaryKind` — for a detail pane that is `detail_query(list).kinds.first`,
  the list's kind scoped to `$item`, so the kind is read from the spec rather than guessed.
  **No extraction was needed anywhere:** `FigureDetailPane`, `MessageDetailPane` and
  `AgentRecordDetailPane` are already `public` and already take
  `(id, Binding<DetailTab>, topInset:)`, because a section's detail half and a tree's
  detail pane want the same two things. A plain enum switched over a plain `some View`,
  never a `@ViewBuilder` returning `(some View)?`.
- **`topInset` is NOT 0, and the first version of this entry was wrong to say so.** It
  claimed a layout pane reclaims no toolbar band. `LayoutLinearSplit` does reclaim it —
  `.ignoresSafeArea(.container, edges: .top)` on every horizontal child but the first,
  which is exactly where each preset's `info` pane sits — so with `topInset: 0` the
  Info / Source / View picker of every figure, message and task detail drew under the
  window toolbar: the record rendered, the control that switches it could not be seen or
  clicked. Screenshots of impel and impart showed the body flush under the toolbar with
  no picker. The section views' fixed 40pt is the wrong number for a tree, whose pane may
  not be under the toolbar at all, so the split now MEASURES the band it still sees as
  safe area (before any child reclaims it) and hands it down as `layoutToolbarBand`: a
  reclaiming child gets it, a first child or a vertical split's top child inherits its
  parent's, a vertical split's lower children get 0. Checked live in three positions on
  impel — info as the third column (picker clears the ~52pt toolbar, read off the screenshot), info on top of a
  vertical split inside that column (still clears it), info in that split's lower half
  (picker flush with its own top, no gap) — and on implore, which has no toolbar, only a
  title bar, where the picker sits just under it (by screenshot, not by a measured
  number).
- `LayoutPaneRowMapper` needed nothing: it reads the kind manifest out of the FFI
  (`kindManifestJson()`), and `impress_core::pane_query::builtin_manifest()` already claims
  `figure`, `message`, `task` and `agent-run`. The row style for these kinds was already
  arriving through `RecordViewerRegistry.makeListRow` — impel's list pane drew 500 task
  rows on the first launch with no change to the mapper.
- **Proven live (Mac, 2026-09-23).** implore on 23123, impel on 23124 and impart on 23122,
  each built from this branch (impart from a scratch merge of this branch with PR #50 —
  see "Not proven"), each with `impress.layoutTree.enabled` written to its OWN bundle id.
  The flag is `UserDefaults.standard` read once per launch, so it is per app, and impart's
  id is `com.imbib.impart`, not `com.impress.impart`. For all three `/api/layout/tree`
  after `{"op":"apply-layout","ordinal":1}` is four tiles — `1 outline navigator
  [collection, library]`, `2 list list [<kind>]`, `3 info detail [<kind>] params=[(item,
  <kind>)]`, `4 container linear horizontal [1,2,3]` — with **the string `legacy` nowhere
  in the document**. Tier B is **8/8, 0 skipped** against each, and afterwards the
  `layout` object is identical to before the run (compared as parsed JSON), `/api/layout/layouts` is empty and
  `/api/surface` is `{"surfaces":[]}`. Re-run on the final binaries after the two fixes
  below; same result.
- **The dispatch, with real rows.** Tier B's own `select` sends a random `new_v4` id, so it
  proves only which branch the pane took. Each kind was then selected with a row that
  exists, via `POST /api/layout/verb {"verb":"select","target":{"ref":"id","tile":2},
  "kind":"<kind>","ids":[<id>]}`, and read back from `?category=layout` and a
  `screencapture -R` of the window:
  - **task** (impel): `pane 3 info: task detail for DCC8E5A9-…` — a live `task@1.0.0` row
    ("Backfill memory embeddings"); the pane shows its state (Done), assignee
    (impel-taskd), dates and its latest run (impel-memory/embed, 0.6 s).
  - **message** (impart): `pane 3 info: message detail for F892B51A-…` — one of the store's
    33 `chat-message` rows (impart's list pane shows the same 33); the pane shows its
    sender (`user:local`) and its date (Aug 6, 2026, 2:40 AM, matching the row's
    `created`), not "Message Unavailable". The store holds zero `email-message` rows, so
    the email half of `MailStoreReader.fetchMessage` was not exercised.
  - **figure** (implore): the store held zero `figure` rows, so one was seeded through
    implore's own verb, `POST /api/figures` (`LibraryManager.addFigure` mirrors it into the
    store as `figure`, the ref schema-refs.json lists): `pane 3 info: figure detail for
    7813BE3B-…`, and the pane showed its title, format and dates. Cleanup took two steps,
    because `DELETE /api/figures/{id}` removes the figure from implore's library JSON but
    NOT its store row (`removeFigure` never calls the store — a gap of its own, see
    below). The row was deleted with a throwaway program over `SqliteItemStore::delete`,
    which refuses any row whose schema is not `figure`; `list-items --schema-ref figure`
    is back to 0.
  - **agent-run** (impel): no preset has an `agent-run` pane, so a `split` verb added one
    beside tile 3 (`info` over `agent-run`, `item` from channel 1) and a `select` published
    a live `agent-run@1.0.0` id: `pane 5 info: agentRun detail for 0FE2885B-…`, rendering
    the run's summary, agent, model, prompt hash and duration. `apply-layout 1` restored
    the arrangement afterwards.
  The earlier version of this entry said the store held no `task`, `message` or
  `agent-run` rows. It holds 7,793, 33 and 5,748; only `figure` (and `email-message`) was
  empty. Its own line about impel drawing 500 task rows already contradicted it.
- **Publications still reach `DetailView`.** In impress (23125, a `main` build — the
  publication branch is unchanged here), a `select` of a live `imbib/bibliography-entry`
  row put the paper's authors, year, title, Explore buttons and abstract in the `info`
  pane.
- **Two bugs found by looking, both fixed on this branch.** (1) The `topInset` one above.
  (2) Before a selection, every tree `info` pane said "Select a publication to view
  details", figure, message and task panes included; seen in impel, beside an `agent-run`
  pane, as a task pane asking for a publication. `ChassisEmptyState.noRowSelection(kind:)`
  now phrases it by the pane's own kind ("Select a figure to view details", with that
  kind's section glyph), and a publication pane keeps its old state, id and all.
  RecordKindPresentationTests pins the strings. PMC `swift test` after both: 2083 XCTest,
  0 failures, 2 skipped; 112 swift-testing, green.
- That log line is new and deliberate. A leaf's conversion is otherwise invisible from
  outside the window: a figure detail and a "no publication detail" empty state occupy the
  same pixels, so the proof would have been a screenshot and a promise. It sits beside the
  `pane N display: R rows` the list pane already logs, so the two panes can be seen
  agreeing on one id.
- **Tier B now takes a base url.** W0's `tier_b::run(base_url)` was already parameterized;
  every caller just passed the impress constant. The override is the env var
  `IMPRESS_LAYOUT_SELFTEST_BASE_URL`, NOT a second argument on `run_selftest` — a verb's
  arguments are vocabulary and this plan says ask first, so the catalogue did not decide
  it alone. Default unchanged; the rule is a pure function with a test. Nothing in the
  catalogue turned out to be impress-specific: `/api/layout/*` and `/api/surface/*` are
  served by every app, and "ordinal 1 is this app's own Default" holds per app.
- **Not proven, and why.** (a) **impart on `main`.** `main` does not compile impart:
  `bookmarkCreationOptions` / `bookmarkResolutionOptions` are each declared twice in
  `apps/impart/MessageManagerCore/Sources/MessageManagerCore/Artifacts/DirectoryArtifact.swift`.
  The fix is PR #50 (`claude/impart-bookmark-dup`), still open. It is NOT on this branch:
  the mail proof above ran on a scratch branch that merged the two and was never pushed.
  Until #50 lands, an impart built from `main` + W2 does not build at all. (b) **The
  sidebar-node rows** of the matrix (`section(.figures)` / `(.mail)` / `(.agents)`: context
  menu, rename, delete, drag, drop, counts) are NOT re-proven and are not W2's: they are
  the navigator pane, which is W3. (c) **Row context menus in a `list` pane exist for NO
  kind** — there is no `.contextMenu` anywhere under `Chassis/Layout/`, publications
  included. The W2 row assumed "the section's row style and context menu come through
  `LayoutPaneRowMapper` + the row registry as `list` already does for publications"; the
  row style does, the context menu does not, for anything. Building it is a cross-leaf
  change, not this row's "map, not rewrite": **a gap for W3/W4 to own**, recorded here so
  it is not silently dropped. (d) **The `list` pane's first row sits under the toolbar**
  in all three apps — the same reclaimed band as the `topInset` bug, in
  `LayoutRowsPaneView`, which predates W2 and which this branch did not touch.
  `layoutToolbarBand` is now in the environment for it to use. (e) **implore's
  `DELETE /api/figures/{id}` leaves the store row behind**, so a deleted figure keeps
  showing in every store reader, the tree's figure list included. Pre-existing, implore's.
  (f) **`LayoutTabsView` and `LayoutGridView` pass the band through unchanged**, so a
  detail pane under a tab strip or in a grid's lower row gets clearance it may not need
  (a gap, never a hidden control). No preset builds either today. (g) **An impart wedge
  seen once and not reproduced.** At 16:39:27 local, with impart idle on this build,
  AppKit swallowed an exception (a `SOME_OTHER_THREAD_SWALLOWED_AT_LEAST_ONE_EXCEPTION`
  thread in `sample`). From then on every `@MainActor` route (`/api/layout/*`,
  `/api/logs`) hung while `/api/status` answered and the main thread sat idle in its run
  loop. The system log held nothing for the process. A relaunch plus deliberate
  cross-process store mutations (figure create, library delete, store delete) did not
  reproduce it, and neither did three more Tier B runs. Cause unknown; not attributed to
  W2.
- 2026-09-23 — main's impress app-build lane went red on the #44 merge (run 60): impress
  now links CounselEngine's `ImpelToolsFFI` and the lane never built `ImpelTools.xcframework`.
  Fixed in its own PR (#48: the lane builds it beside the other five). Worth knowing for
  W6: a package that declares a binary target is resolved by every project that references
  the package, whichever targets link it.

- 2026-09-23 — **W3 done: the navigator is the sidebar.** Proven live on impress (23125,
  every section) and impel (23124, one section), both built from
  `claude/wave6-w3-outline`, flag on per bundle id.
- **What was built, and the one decision that shaped it.** The row said the outline's
  rows are "the app's sections and their query-defined children", with counts from "the
  same queries the badges use today", and context menus / rename / delete / drag / drop
  "through the chassis' existing capabilities". Those are all ONE object already:
  `ImbibSidebarViewModel` behind `SidebarOutlineView`. So the `outline` view kind now
  hosts that sidebar (`LayoutOutlinePaneView`), and what changed is only what SELECTING a
  row does. `TabContentView`'s column and lifecycle — configure, store events, navigation
  notifications, the delete confirmations and sheets its menus raise — moved verbatim to
  `TabSidebar/ImbibSidebarHost.swift` and both hosts apply them; the flag-off window is
  the same view tree it was (its Delete Library confirmation re-checked live after the
  move). No builder was added, so `SidebarStoreCallRatchetTests` holds unchanged.
- **Rust decides, Swift maps.** `crates/impress-layout-service/src/outline.rs`:
  `OutlineNode` (a row, in data), `outline_target` (→ `Query` | `Legacy{section, reason}` |
  `Inert`), `outline_verbs` (→ `select` on the channel + `set-query` on the `list` role, or
  `set-pane` when that pane is not a list; `set-pane` to a scoped `legacy` pane; a detail
  `set-pane` when the list's KIND changes, because a channel carries one value per kind
  and a publication `$item` never hears a figure), `initial_selection_applies`, and
  `outline_sections` (per-app section table: named queries + the MATERIALIZE_FIRST
  sections the app shows; `every_visible_section_is_accounted_for` now also asserts the
  outline's table equals each app's `visibleSections`). 15 tests. FFI: two free
  functions, `outline_sections_json(app_id)` and `outline_row_verbs_json(app_id,
  node_json, bindings_json, list_spec_json, detail_spec_json, initial)`; binding
  regenerated, +2 declarations, 0 lost. No verb, `PaneSpec` field or `ViewKindId` was
  added — the scoped legacy pane is `view_state {section, node, reason}`.
- **Proven live, impress.** `/api/layout/tree` after each click (CGEvents): Red flag →
  `set-query flag(red)`, `pane 2 display: 2 rows` (badge 2); Tom's papers → `select
  library` + `set-query parent=cfa8e8d5…`, 153 rows (badge 153), channel 1 carries the
  library; ULDM › "State, Coherence…" → `select collection` + `set-query
  collection=446ba33c…`, 78 rows (badge 78); a list click → `pane 3 info: publication detail
  for 546E03A1…` and the pane showed that paper. Badges compared with the flag-off build
  on the same store: Save 2657★116, Dismissed 2992★71, Exploration 533, Tom's papers
  153★7, ChemistryKernels 25, ULDM 78, Any Flag 2, Red 2 — identical. SciX Search (a search
  form) → `set-pane` to `legacy` with `view_state.section = search`, and the pane showed the
  ADS Modern form alone under "search — hosted, not yet a query"; Red again → `set-pane`
  back to `list`, params kept. Matrix rows with a throwaway collection "ZZ W3 outline
  probe" in ChemistryKernels: library menu (Rename / New Collection / Add Feed… / Export… /
  Import… / Delete Library), New Collection, collection menu → Rename (`renamed … → 'ZZ W3
  outline probe'`), a paper dragged from the tree's list onto it (`filed 1/1 item(s)`, badge
  0 → 1, selecting it → 1 row), New Subcollection, the subcollection dragged onto the library
  (`reparented … → root`), Delete from the menu (`members unfiled: 0`) and ⌫ (`members
  unfiled: 1`); a throwaway library created from the Libraries header menu and deleted
  through the confirmation alert. Libraries back to 7, collections back to what they were.
  Keyboard: with the NSOutlineView first responder, l/h still walk the tree (focus 1→2,
  3→2→1) — type-select does not take them; ↓ in the outline moves the row and the list
  follows. The launch selection: with the list restored on Tom's papers, relaunch logged
  `→ query, 0 verb(s) — not applied: the list is not on the preset's query`.
- **The other four MATERIALIZE_FIRST sections** have no row in this store: the sidebar's own
  content gates hide them (no readable SciX key; `sharedWithMe` is always hidden, a TODO in
  the view model; 0 pending reviews; the Tags header is not selectable, and a tag ROW is a
  query by MATERIALIZE_FIRST's own reasoning). The scoped pane was driven for each with
  the same `set-pane` shape over `/api/layout/verb`: `pane 2 legacy: section reviewQueue
  route reviewQueue`, `section sharedWithMe route sharedLibrary(CFA8E8D5…)` (the library's
  153 papers, the chassis' own list), `section scixLibraries route scixLibrary(…BEEF)`
  (blank: no such library), `section tags` → "Nothing to Show" (a header is not a route).
- **Proven live, impel.** `outline: impel shows 2 sections from Rust (1 legacy: tags)`;
  Runs → `set-query agent-run` + detail `set-pane` (`item: agent-run`), a run clicked →
  `pane 3 info: agentRun detail for 0FE2885B…`; Failed (a task state) → scoped legacy
  (`a task's lifecycle is payload.state…`), the agents route alone; Dashboard → scoped
  legacy, impel's surface alone; Tasks → back to `task` in both panes.
- **Tier B** gained `layout.outline_collection_row`: the node goes through the same
  `outline_target` + `outline_verbs` the app calls, the verbs are posted, and the evidence
  is read back — the list pane's query is the collection, channel 1 carries it, the list
  logged `display: 0 rows` (a fresh collection; a first version matched any `display:` line
  and passed on impel with "500 rows" from the OLD query's refresh — tightened), and a
  list `select` logged `pane 3 info: … detail for <that id>`. No collection is created: a
  fresh id is a valid empty query. `IMPRESS_LAYOUT_SELFTEST_BASE_URL=…
  layout-selftest-service_run-selftest --tier b`: impress **9/9, 0 skipped** (369 ms), impel
  **9/9, 0 skipped**; `tiles`/`windows`/`channels` identical before and after on both, no
  layouts, no surfaces.
- **Also fixed:** the `list` pane's first row sat under the toolbar (W2's leftover d) —
  `LayoutRowsPaneView` pads by `layoutToolbarBand`. A content margin was tried first and
  failed at launch: the band is measured after the first layout and a growing margin left
  the scroll origin where it was. And the tree's `list` rows had no drag source, so a paper
  could not reach an outline collection; publication rows now write
  `PublicationDragPayload`, the payload `MailStylePublicationRow` already wrote, extracted
  so there is one spelling.
- **Found, not fixed (recorded in the matrix):** (a) the `inbox` named query is UNREAD in
  the Inbox (`q::inbox`) — 57 rows — where the flag-off route lists every Inbox paper (68);
  the section has no badge, so no count disagrees, but the list does; changing a named
  query's meaning is L7's table, not this row. (b) A new library/collection does not open
  its inline rename field — the flag-off sidebar on the same build does the same, so it is
  pre-existing. (c) Deleting the SELECTED collection leaves the list on its empty query (a
  nil selection sends no verb). (d) Beside a scoped legacy route the tree's `info` pane keeps
  the last selection, and the hosted route's own list|detail split is cramped in a
  list-width column. (e) Figure / manuscript rows of the tree's list are not drag sources
  yet. (f) "`layout changed elsewhere → version N`" follows most local verbs in the log,
  naming a version this controller itself applied a moment earlier; it re-reads the tree
  and draws the same thing. Not investigated, and not compared with a `main` build.
- **Not proven here:** the other four chassis apps' outlines (implore, impart, imprint)
  were not launched from this branch; the code path is the same `LayoutOutlinePaneView`
  and Rust's table covers them (`every_visible_section_is_accounted_for`).
- 2026-09-24 — **W3 follow-up: a gesture no longer redraws the tree for its own writes.** Every
  local verb was followed by one or two `layout changed elsewhere → version N` lines naming
  versions this process had just applied, each a full `reload()` and display pass. The feed
  reports every version the layout passes through, each report hops to the main actor in its
  own `Task`, so it lands after the local `apply` has adopted a later snapshot; the guard was
  `version != self.version`, so an outline library click (`select` then `set-query`, 3 → 5)
  reloaded twice more for 3 and 4. It is now `version > self.version`
  (`LayoutController.isNewer`, three FFI-free tests): exact, because the counter is one
  `AtomicU64` per `SharedLayout` that only `fetch_add`s and a change made elsewhere bumps the
  same counter. Proven live on impress built from this branch: a library click logs two verbs,
  one `pane 2 display: 153 rows` and **0** stale reloads; `impress-cli apply-layout --ordinal 1`
  from a second process still logs `layout changed elsewhere → version 6`, one display pass,
  and the list back on the Default query. PMC `swift test` 2090 XCTest, 0 failures.
- 2026-09-24 — **Correction: the package cache was never damaged.** W2 and W3 each pushed with
  `SKIP_DUAL_PLATFORM_CHECK=1`, blaming "the machine's global Swift package cache" for the
  hook's `Couldn't check out revision … unable to read tree`. The cause was the hook: git
  exports `GIT_DIR=<repo>/.git/worktrees/<name>` into a hook run from a worktree, and the git
  xcodebuild spawns for package checkouts inherited it and looked for every package's tree in
  this repository. Reproduced by checking out NetworkImage from the SwiftPM cache with and
  without that `GIT_DIR`. Fixed in #53 (the hook unsets the git environment after finding the
  repo root); this branch's follow-up push went through the full hook with no bypass.
- 2026-09-24 — **W4 pass A, step 1: `pdf`, `notes` and `bibtex` render, proven live in
  impress** (23125, built from `claude/wave6-w4-kinds`, flag on). `source` is still the
  placeholder; the session-bearing editor is pass B.
- **What they are.** `LayoutPublicationTabPaneView` renders `PDFTab`, `NotesTab` and
  `BibTeXTab` unchanged, fed the paper the way `info` resolves it (`single_item`, else
  the `item` binding), inside `publicationDetailLifecycle`, padded by `layoutToolbarBand`.
  A pane over another kind answers "Detail Unavailable" by name. Each logs
  `pane N <tab>: publication <id>`.
- **The arrangement, composed with existing verbs** (impress ships only Default; imbib's
  Reading preset is app_id `imbib`): three `split`s of the detail pane, each `new` spec a
  copy of the detail pane's (same `detail_query`, same `item` param on channel 1) with
  `view_kind` changed and no role — `pdf` beside `info` (tile 5), `notes` (6) and
  `bibtex` (8) below it — plus a `set-query` of the list onto the ULDM library. One
  click on a list row: `pane 8 bibtex / pane 6 notes / pane 5 pdf / pane 3 info:
  publication 3D087F58…`, all in the same millisecond; the next click moved all four to
  E202F3C0 (Banik & Sikivie 2013). Screenshots: the PDF (1/33 pages) in `pdf`, the same
  PDF beside the annotation fields in `notes`, the entry in `bibtex`.
- **No PDF.** Gaia GraL X (E156D69B, no DOI/arXiv/bibcode/eprint): `pdf` shows PDFTab's
  own "No PDF — No PDF is available for this paper", `notes` NotesTab's "Add a PDF to
  view it here while taking notes"; the log says `result=false`, no download attempted.
- **Notes, three points, reverted exactly.** With `notes` maximized, Key Findings enabled
  and "w4 probe hjkl" typed (the `hjkl` reached the field; no pane stole them). Save: the
  store's `note` became `---\nKey Findings: w4 probe hjkl\n---\n\nN` — label-keyed YAML
  front matter over the freeform `N`, through `PublicationNotesDocument`. Display: after
  selecting another paper and back, the pane re-parsed it (Key Findings checked, the
  text in it, `N` alone as prose). Unchecking wrote `N` back: hex `4E`, length 1, as
  before.
- **Found and fixed on the way (each would have shown as "the pane is wrong").**
  (1) `InfoTab`'s store subscription was a bare `.task {}`: after a paper switch the next
  `.structural` event reloaded the FIRST paper, so the `info` pane beside a `pdf` pane
  showed one paper's header and another's Record Info and Attachments. Keyed on the id.
  (2) An auto-download that finishes after a paper switch loaded the old paper's PDF into
  the pane now on another paper (PDFTab and NotesTab). Both now drop a completion for a
  paper they no longer show; re-proven by selecting a paper mid-download and switching
  away: `[NotesTab] PDF for 3D087F58… arrived after the tab moved on — not shown`, and the
  `pdf` pane stayed on the paper selected. (3) The tab panes read read-state from the
  store after the dwell, so four detail panes on one unread paper make one `setRead`,
  not four undoable ones (Rust already throttles `recordRecentView`).
- **Two things the proof cost, and what was put back.** impress is sandboxed and its
  container has no `imbib/Libraries`, so EVERY library PDF is "not found" from impress, in
  any host: a suite gap, not a pane one. To render a real PDF, one copy of the Banik PDF
  (sha256 matching the store's) was placed at impress's own
  `…/Containers/com.impress.impress/…/imbib/Libraries/1AD5E936…/Papers/` and removed at
  the end. And selecting Vortices (3D087F58, DOI, no file) made PDFTab auto-download it
  from arXiv — the user's own setting doing what it does in imbib — three times over the
  session; each linked file was deleted through the info pane's own Delete Attachment
  (0 children now). Left behind on that paper: `has_pdf_downloaded: false` and a
  `pdf_download_date`, where both keys were absent (no API removes a payload key); and
  `last_activity_at` "viewed" on the papers looked at, which is what viewing does.
- **Found, not fixed.** `NotesPanel` re-reads the note on any `itemsMutated` event for its
  paper and resets the visible annotation fields to the populated ones; a mouse click
  into a just-enabled, still-empty annotation field produces such an event (source not
  identified; no store operation is recorded), so the field vanishes under the cursor.
  Its guard covers only the freeform editor. Same in any host; worked around here by
  entering the freeform editor first.
- 2026-09-24 — **W4 pass A, step 2: every `list` row carries its kind's menu and drag; Tier
  B proves the reading pane.** Proven live in impress (23125, this branch, flag on); every
  mutation reverted. `origin/main` merged in (#47, #48, #53); no conflict.
- **Reuse, not rewrite.** The legacy menus moved to one definition each and both hosts call
  it: `PublicationRowContextMenu` (from `PublicationListView.contextMenuItems`) over
  `PublicationListActions.chassis` (from `UnifiedPublicationListWrapper.buildListActions`,
  whose effects on the wrapper's own state — drop rows, advance the selection, open the
  inline tag field, the drop preview — are `PublicationListActionsHost` hooks the wrapper
  fills exactly as before); `ManuscriptRowChrome` (menu, drag payload, Rename and Delete
  alerts, actions, delete sequence, from `ManuscriptListWrapper` / `ManuscriptSectionView`);
  `FigureRowChrome` (the same, from `FigureListWrapper` / `FigureSectionView`). Messages,
  tasks and agent runs show the shared `TriageMenu.items` over
  `RecordTriageActions.storeBacked`, which is all their own lists show; nothing to extract.
  In the pane the scope is read off its query (`LayoutPaneScope`, 7 tests: collection →
  `.collection`, parent → `.library` / `.inbox` / `.dismissed`, flag / starred / tag → their
  virtual scopes, everything else `.combined([])`; a figure folder is a parent scope, a
  manuscript folder a collection, as the outline files them).
- **Proven** (details in the matrix, § List-pane rows): a paper — Star/Unstar, Flag ›
  Blue/Clear, Add Tag (the pane asks with the triage "New Tag…" prompt; the legacy list's
  inline tag field has no pane equivalent); a throwaway manuscript made by the pane's own
  Duplicate — Rename… (`renamed manuscript AC123311… → 'ZZ W4 pane probe'`), dragged onto a
  folder (`sidebar dropped 1 manuscript(s) into folder f99d09b2…`), Remove from Folder in
  the folder-scoped list, Delete… through the section's confirmation (count back to 64); a
  figure seeded through implore's `POST /api/figures` — dragged onto a throwaway figure
  folder (`sidebar dropped 1 figure(s) into folder ae6a8116…`), Remove from Folder, Delete…
  (`delete figures: DBE69FE6…`), implore's own entry removed with its `DELETE`, the folder
  deleted from its menu; a task (3FCB6694…) — Star/Unstar, Flag › Red/Clear, Tags ›
  `ai/field/physics` on and off from the same submenu. Messages share the task code path and
  were not driven live.
- **Found and fixed:** the tree's `list` rows (and every menu built from them) went stale
  after a star, flag, tag, dismiss or delete: the invalidation feed watches only its own
  store handle, plus `impress/ui/` rows from other connections, and every menu writes
  through `RustStoreAdapter`'s handle. The pane now also re-reads on the store's own event
  stream, as the legacy lists do; a row revision is passed to the menus so they rebuild with
  the rows ("Unstar" after Star, without a relaunch).
- **Found, not fixed:** the publication menu has no remove-tag item in either host (the
  legacy `onRemoveTag` is an empty TODO), and Edit → Undo did not reach `addTag`'s undo
  registration in impress; the `ai` tag added by the proof was removed with the store verb
  `triage-service_remove-tag`.
- **Tier B** gained `layout.reading_pdf_pane`: apply Default, point the list at read
  papers, split a `pdf` pane beside the detail pane (its own spec, `view_kind: pdf`, no
  role), select the first read row that already has its PDF (from the list pane's compiled
  query on the shared store — so neither the read dwell nor PDFTab's auto-download writes
  anything), wait for `pane N pdf: publication <id>`, close the pane. Against impress:
  **10/10, 0 skipped** (2.3 s): `pane 5 pdf: publication 30F30B68…`; that paper's
  `modified` unchanged and no operation recorded on it; `tiles`/`windows`/`channels`
  identical before and after, no layouts, no surfaces.
- **Left as it was found:** the proof arrangement was parked as a named layout at the start
  and re-applied at the end (tiles/windows/channels identical to the first read), then
  deleted; the one PDF copy placed in impress's container was removed with the folder it
  needed.

- 2026-09-24 — **W4 pass B: `source` is a session-bearing view kind; the manuscript editor
  survives split, swap and preset change without `.id`.** Proven live in **imprint** (23121,
  built from `claude/wave6-w4-kinds`, flag on) on two throwaway manuscripts made by the list
  pane's Duplicate and deleted at the end; impress rebuilt from the branch for Tier B.
  **Nothing here was ask-first:** Rust fills in the existing `PaneSpec.session` field; no
  verb, no field, no view kind was added, and no `#[uniffi::export]` changed (the store-ffi
  xcframework was rebuilt for the new Rust; its committed binding came out byte-identical).
- **Rust decides the session id** (`impress_layout::sessions`, `tests/sessions.rs`, 13
  tests; Tier A `source-pane-sessions`). `ViewKindId::SESSION_BEARING = [source]` is the one
  list. After every verb `apply_in` runs `ensure_sessions_keeping(before.session_holders())`:
  each session-bearing pane holds a session and, on a duplicate, the pane that held it before
  keeps it — so a split's new pane gets a fresh id even when its spec is a copy of the
  target's; swap/move/resize/close/set_view_kind change nothing; `set_pane` keeps the
  replaced pane's session when the new spec names none (the outline re-points the detail pane
  that way). `apply_tree` (a preset or a saved layout) calls `adopt_sessions_by_role`, so the
  editor in the `detail` role survives ⌃⌘1/⌃⌘2; presets themselves stay sessionless and
  deterministic (`normalize` assigns nothing, `matches_shipped` still compares). A first load
  of a stored tree assigns and SAVES at once, so a second process reads the same ids.
- **The host** (`Chassis/Layout/SourcePaneSession.swift`, `Manuscript/Editor/TypstEditorHost
  .swift`). `SourcePaneSession: PaneSession` in `PaneSessionRegistry<SourcePaneSession>`
  (capacity 6 off-screen; an on-screen session is never evicted — `isPinned`, new in the
  protocol) owns a `TypstEditorHost`: scroll view, `TypstTextView`, the ONE coordinator (the
  delegate), the Helix state, and an `UndoManager` per manuscript it has shown, installed as
  `TypstTextView.documentUndoManager` (the view claims `undo:`/`redo:` only when it has one,
  so the Source tab's ⌘Z still reaches the window). The text is the manuscript's
  `ManuscriptEditorSession`; `flush()` flushes it, `abandon()` cancels its save. **Deviation
  from the brief, on contact:** the representable does not return the host's scroll view
  itself but a per-mount container it moves the editor into — SwiftUI may build the new pane
  before dismantling the old one, and only a container lets the old teardown tell whether the
  editor is still its own (here it dismantled first). And the per-document undo manager is an
  override of `TypstTextView.undoManager`, not the delegate's `undoManager(for:)`: implementing
  that delegate method would have changed the legacy editor's resolution too. The legacy path
  is unchanged: no host → `makeEditor` per mount, as before; `ManuscriptSourceTab` takes its
  session `@Bindable` rather than `@State` so it follows a new one.
- **Proof, imprint.** (1) Outline renders under the tree: `outline: imprint shows 5 sections
  from Rust (1 legacy: tags)` (its live row had been cold-started as imbib's publication
  three-column, so the outline's first selection was refused as "not on the preset's query";
  ⌃⌘1 → imprint's own Default fixed it). (2) Typed `W4B hjkl typed` (the `hjkl` reached the
  editor), then a split, a split that wrapped the editor again, a swap, and preset 1 applied:
  `ObjectIdentifier(0x0000000805a89900)` through `mounted (mount 2…5)`, ⌘Z/⇧⌘Z undid and
  redid the typing every time (store body read back), one `source session … opened` for the
  whole run, `session-ec2e2242…` unchanged in `/api/layout/tree`. (3) Two manuscripts in one
  pane: ⌘Z in each undid only its own typing. (4) D6 liveness: `impress commit-manuscript-body`
  from another process — `took an external change … in place: 0 chars at 134 replaced by 35`,
  same view; racing a keystroke still inside the save debounce, Automerge forked from one head
  and kept both (the retitle and ` U2`; later ` U3!` with the caret where it belonged). (5)
  Delete: `discarded editor session` → `abandoned manuscript … — was on screen; pending save
  cancelled, undo history dropped, nothing written`; rows=0 for 35 s after. Writing's `pdf`
  pane now shows the manuscript's compiled preview (`ManuscriptPreviewContent`, moved out of
  `ManuscriptDetailPane`'s Preview tab) instead of pass A's "Detail Unavailable".
- **Found and fixed on the way.** (a) A write from another process reaches the app only as the
  store's cross-process signal, a bare `.structural` (deferred 90 s after launch by
  `StoreMutationObserver`); the detail pane's Source tab listens only for events naming its
  manuscript. The pane answers both. (b) `absorbExternalChange`'s in-sync branch recorded the
  buffer as last persisted, marking a keystroke inside the debounce as saved; it records the
  store's text now. (c) After an in-place change the caret jumped back by the length of an
  insertion above it (the caret-jump block read the binding's stale value in the same pass).
  (d) A stale SwiftUI pass re-presented a just-deleted manuscript once (nothing written); the
  host ignores a forgotten document until a fresh session shows it. (e) Tier B's
  `outline_collection_row` waited for `pane N info:` whatever the detail kind; it waits for the
  detail pane's own kind now.
- **Tier B** gained `layout.source_pane_session`. imprint **11/11, 0 skipped**; impress
  **11/11, 0 skipped**; both restored (impress's tree identical before and after).
- **Found, not fixed:** in imprint ⌃⌘1 is claimed by the legacy `PaneLayout` menu command
  (`Layout applied: 'Writing'`), not the tree — chord routing is W5's; applying a preset also
  clears the channels, so the editor comes back on the next selection rather than at once; a
  narrow pane clips the Source tab's columns (outline 160 + editor 320 + preview 280 +
  inspector 300 minimums); `/api/manuscripts/{id}/body` (imbib) and the CLI commit post no
  `manuscript-changed`, so a sibling editor hears them only through the 90-s-gated store
  signal; the legacy detail pane's Source tab still ignores cross-process writes; `info` over a
  manuscript says "unsupported detail". The tree flag set on imprint for the proof
  (`impress.layoutTree.enabled`) was removed again; imprint's live layout row is left on its
  own Default preset.
### Open gaps and their owners (assigned 2026-09-24 by the orchestrator)

- List-pane row context menus, all kinds: W4 (pass A).
- Figure and manuscript rows as drag sources: W4 (pass A).
- The Inbox named query shows unread only (57 rows vs 68 in the flag-off list): W5. Once the flag is gone the tree is the only root, so the Inbox must match the legacy list. Parity decides the query; it is not a product question.
- Deleting the selected collection or library leaves the list on an empty query: W5. The expected behaviour is the legacy one, falling back to the parent.
- The info pane keeps its last selection beside a hosted legacy route: W5.
- implore, impart and imprint outlines not yet launched from a tree branch: imprint in W4 (pass B, which launches imprint for the editor proof) — **done in pass B** (imprint's outline renders; Tier B 11/11 on imprint); implore and impart in W5, whose proof is "Tier B green on every app".
- Nothing above is ask-first.

The first two are done in this pass (above).
- 2026-09-24 — **W4: impress offers the sibling arrangements; "apply Reading" is now a real proof.**
  Decided with Tom: impress, the shell that shows everything, lists imbib's Triage / Reading /
  Full and imprint's Writing after its own Default, so impress's ⌃⌘1–5 are Default, Triage,
  Reading, Full, Writing and a saved layout starts at ⌃⌘6. Before this, imbib's three rendered in
  no window (imbib's own is pre-chassis) and Writing only in imprint. Built as
  `presets::for_impress(sibling())`: the sibling's own function builds the tree, so there is one
  definition of each arrangement, and the row is impress's (`preset_id("impress", name)`,
  impress's named queries) because preset rows are per app family: editing Reading in impress
  never edits imbib's. Existing stores gain the four rows on the next read (`ensure_shipped`
  inserts missing rows). Two tests pin the order and the borrowed-not-redefined rule; imbib's
  and imprint's own lists are unchanged. Tier B gained `layout.reading_preset`: apply Reading
  by name, the detail pane is `pdf`, and a list selection logs
  `pane 3 pdf: publication 30F30B68-…`. Against impress rebuilt from this branch: **12/12, 0
  skipped**, restored; `list-presets --app-id impress` answers ordinals 1–5 as above. Nothing
  here is ask-first: no verb, field, view kind or schema ref changed, only preset data, and the
  decision was Tom's.

- 2026-09-24 — **W5 pass A: the flag is gone and the tree is the only chassis root.** Every
  chassis app was built from `claude/wave6-w5-flag` (scripts/build-impress-app.sh, isolated
  DerivedData) with `impress.layoutTree.enabled` deleted from every bundle first, and each
  logged `layout host: tree opened for <app>`: impress (23125), imprint (23121), implore
  (23123), impel (23124), impart (23122). imbib built too; its window is its pre-chassis
  `ContentView`, out of scope, and now says so (imbib CLAUDE.md, the matrix, keyboard-grammar).
  Pass B deletes the three types; nothing of them is deleted here.
- **What went.** `LayoutTreeFlag`, its defaults key, `AppShellConfiguration.usesLayoutTree` /
  `withLayoutTree`, `LayoutAutomation.isActive` and imbib's `treeActive` marker — each existed
  only because of the flag. The layout routes' 409 names no flag (a chassis app: the tree has
  not opened yet; imbib: its window has none). imbib's `/api/layout` routes still drive
  `PaneLayoutState`, which imbib's own window still draws, so they keep answering honestly
  with `model: "pane-layout-state"`; no chassis app serves them.
- **Chords.** `PaneLayoutChordTarget`: `.layoutTree` (every chassis app) routes ⌘0 / ⌥⌘0 /
  ⌃⌘S / ⌃⌘1–9 only through `LayoutController` — no fallback, a chord before the tree opens is
  logged and ignored; `.imbibPreChassisWindow` is passed by `imbibApp.swift` alone (a source
  scan pins it). h / l: `DetailView` and the hosted publication list answered h/l as
  `.handled` and posted `.cycleFocusLeft/Right` for imbib's `ContentView`, which no chassis
  window observed, so focus did not move from the info pane; `LayoutWindowView` now routes
  both. imprint's ⌃⌘1 bug: its Layouts menu bound ⌃⌘1–9 to the editor window's saved layouts
  unconditionally; `ImprintLayoutsMenu` gives the chord to the editor layouts only while a
  manuscript editor window is key (a new `imprintEditorWindow` focused value) and to
  `ImpressLayoutOrdinalButtons` otherwise. imprint's editor-window `PaneLayoutState` is
  untouched (`git grep -n PaneLayoutState apps/imprint/Shared` still finds it).
- **Chords live.** impress: ⌃⌘S → `resize-share(pane 1 → 0.0001)`, shares [1,2,3] →
  [0.0001,2,3]; ⌘0 → pane 3 to 0.0001; again → sibling average; shares put back to [1,2,3].
  h with the info pane focused → `focus-direction(left)`, focus 3 → 2; l → 3. imprint: ⌃⌘S and
  ⌘0 the same (versions 32, 33); **⌃⌘1 in the chassis window → `chord: apply layout 1 → layout
  tree`, `apply-layout(1) → version 34`**, shares restored, no `Layout applied: 'Writing'`; with
  a manuscript editor window key, ⌃⌘1 → `Layout applied: 'Writing'` and no tree verb (both
  halves; the editor's arrangement is left on Writing).
- **Gaps W5 owned.** (a) **Inbox**: the legacy Inbox is `queryPublications(parentId:)` with no
  read predicate (`disableUnreadFilter`; only the badge is unread), so `q::inbox` drops
  `Filter::Read` (store-backed Rust test runs both revisions). It is every imbib/impress
  preset's list query, so presets move to shipped revision 2 and `ensure_shipped` rewrites a
  row only while it is exactly revision 1 (`previous_revision`); a live list still on revision
  1 — param form, or with the Inbox id bound, which is what the outline itself wrote — counts
  as the preset's at launch (`is_superseded_list_query`; found by launching, fixed in its own
  commit). Live: launch `set-query` with `"filters":[]` → `pane 2 display: 67 rows` (57
  before). **Not 68, and that is ask-first:** the legacy query is `HasParent OR
  ReferencedBy(Contains)`; one Inbox paper (ab9c0da4, parented to Save) is in the Inbox by a
  `Contains` edge only, and `Scope::Parent` compiles to `HasParent`. Widening what
  `Scope::Parent` means (it scopes every library and figure/mail folder pane too) is a
  vocabulary change — stopped, written in the PR. (b) **Deleting the selected
  collection/library**: the legacy sidebar does NOT fall back to the parent (the gap's
  wording assumed it did) — `deleteFolder`/`deleteCollection` set the selection to nil, a
  deleted library leaves one that resolves to nothing, the content says "No Selection". Rust
  `outline_cleared_verbs` matches it; live for a collection (`… the sidebar's selection went
  to nil → 2 verb(s)`) and a library (`… its library was deleted → 2 verb(s)`), channel 1
  emptied, "Nothing Here" | "No Selection". (c) **Info beside a hosted route**: a legacy row's
  verbs end with an empty `select` of the detail's kind; live: SciX Search → `legacy, 2
  verb(s)`, the paper left the `info` pane. (d) **implore and impart outlines** launched from
  the branch: `outline: implore shows 2 sections from Rust (1 legacy: tags)`, same for impart;
  screenshots show outline | list | info in both.
- **AppShellConfiguration.** The shipped presets' `sectionBindings` moved to Rust
  (`section_bindings`, tested against the named queries; `libraries` the one documented
  exception); Swift reads it (`ShippedSectionBindings`) and a test pins the six tables to the
  literals they replaced. What stays, and why, is in the matrix beside the truth table —
  chiefly `visibleSections` (read by iOS, which has no tree) and the initializer parameter for
  unshipped shells (the Litmus kinds).
- **Tier B, every chassis app, W5 build, no flag:** impress, imprint, implore, impel, impart
  each **12/12, 0 skipped**; `tiles`/`windows`/`channels` identical before and after on all
  five, no layouts, no surfaces.
- **For pass B.** The **ADR-0019 D5 importer was never built** — nothing reads
  `PaneLayoutState` or `imbib.layout.*` into presets (only doc comments at
  `impress-layout-service/src/store.rs:229` and `impress-layout/src/preset.rs:20` name it);
  there is no code to delete. PMC `PaneLayoutState` is read by imbib's pre-chassis window
  (`imbibApp.swift` Layouts and appearance menus) and by the legacy chassis views the tree's
  `legacy` pane still hosts; `SidebarComposition` is live on impress-iOS
  (`IOSImpressHostView.swift:130`); `FocusedPane`'s only live reader is imbib's `ContentView`.
  All three deletions touch imbib's out-of-scope window or iOS: ask-first before pass B.
- **Ask-first in this pass:** one — the Inbox's `Contains`-linked paper (the algebra's Parent
  scope). Nothing else: no verb, schema ref, `PaneSpec` field or view kind changed; the two new
  FFI free functions (`outline_cleared_verbs_json`, `section_bindings_json`) are bindings of
  Rust decisions, the binding regenerated in the same commits (+2 declarations, 0 lost).
- **Left as found:** the throwaway collection and library were deleted in the proof itself;
  the one CLI-made collection was removed with the kernel `delete` (membership gone, paper
  intact); viewing papers wrote `last_activity_at` "viewed", which is what viewing does.

- 2026-09-24 — **W5 row, amended (decided by Tom): `SidebarComposition`(+Key) stays, and the
  ADR-0019 D5 importer is not deleted because it was never built.** The row above says
  pass B deletes `SidebarComposition`; W3 superseded that. W3 made the tree's `outline` pane
  host the composed chassis sidebar, which reads `SidebarComposition`, and impress-iOS, which
  has no tree, uses it (`IOSImpressHostView.swift:130`). Deleting it would remove the
  sidebar both of those draw. The row is left as written; this note is the amendment. The D5
  importer never existed in code, and only two doc comments named it
  (`impress-layout-service/src/store.rs` `all_rows`, `impress-layout/src/preset.rs`
  `ThreeColumn`). Both now say it was never built (`ec3cef56`).
- 2026-09-24 — **W5 pass B: library scope parity, and `FocusedPane` and `PaneLayoutState`
  moved into imbib's app target.** Branch `claude/wave6-w5-flag`, commits `baa4cff2`
  (compiler), `98ea085f` (`FocusedPane`), `017bd3e0` (`PaneLayoutState`), `ec3cef56` (D5
  comments), then docs. Pass A's three stops were answered by Tom on 2026-09-24. Each
  decision is recorded here as **decided by Tom**.
- **1. Library scope parity (decided by Tom).** `KindManifest` gains `contains_members`
  (container kind → the member kinds it also holds by a `Contains` edge; serde-default, so
  an older manifest JSON still decodes), and `builtin_manifest()` lists
  `library → [publication]`. The `Scope::Parent` lowering asks the manifest
  (`KindManifest::parent_includes_contains`). A declared parameter's kind decides; a literal
  id's parent is inferred as the one container whose members cover the queried kinds. A
  library parent over publications then compiles to `HasParent OR ReferencedBy(Contains)`,
  which is `in_library_predicate`, and invalidation also depends on the `Contains` edge.
  Figure folders (`collection_ops::Membership::EnvelopeParent`) and mail folders (impart
  writes a message's mailbox as its `parentId`) file by parent alone, so they keep
  `HasParent`. No Filter, verb, `PaneQuery` or `PaneSpec` field changed. Tests:
  imbib-core `a_compiled_library_pane_matches_in_library_predicate` (store-backed; Inbox and
  Save, with parented, Contains-linked and elsewhere-only papers); impress-core
  `a_parent_scope_takes_contains_edges_only_under_a_library`,
  `a_library_pane_lists_its_contains_linked_papers_too`,
  `a_figure_folder_pane_is_still_its_envelope_children` and
  `contains_members_name_known_kinds`; and pane-query's generic manifest tests. One old
  expectation encoded the bug: `scopes_compile_to_the_documented_predicates` pinned
  `HasParent` for a publication pane, and it now expects the Or. No other pane test, and
  none of Tier A (39/39), had pinned parent-only. **Live (impress, pass B build):**
  `pane 2 display: 68 rows`. The legacy predicate over the store gives 68 (67 parented plus
  ab9c0da4, parented to Save). imbib's Friends feed then imported 17 papers, and the pane
  logged `85 rows` against the predicate's 85 and imbib's own list (`rebuildRowData: 85
  rows`). The Inbox is today's only library holding a paper parented elsewhere.
- **2. `FocusedPane`, then `PaneLayoutState`, into imbib's app target (decided by Tom).** One
  type per commit, and all six apps plus imbib-iOS were built between them. **`FocusedPane`**
  is now `apps/imbib/imbib/imbib/FocusedPane.swift`. Its only reader is imbib's
  `ContentView`. The list wrapper's dead `focusedPane:` parameter, the uncalled
  `from(_:)`/`isDetailTab` and the cross-platform allowlist entry are gone, and
  `LayoutController.undo/redoForFocusedPane` became `undoInFocus`/`redoInFocus`, with the
  same behaviour. **`PaneLayoutState`/`PaneLayoutStore`/`SavedPaneLayout`** are now
  `apps/imbib/imbib/imbib/PaneLayoutStore.swift`, with the same keys and the same decoding.
  PMC keeps two hooks:
  - `HostWindowPanes`, an environment value. imbib's `ContentView` injects the store. The
    section views (publications, figures, mail, agents, manuscripts) read list/detail
    visibility from it, `SectionContentView` also mirrors the detail tab, and
    `TabContentView` reads the sidebar column and list toggle. Inside the tree nothing is
    injected, so a scoped section view shows both panes, and a whole hosted `TabContentView`
    keeps `OwnWindowPanes` in memory instead of flipping a global the tree never drew.
  - `PreChassisLayoutRoutes`, the `LayoutAutomationHost` pattern. `imbibApp.init` registers
    the store; PMC's router forwards `/api/layout` (GET and POST), `/apply` and `/save`, and
    `/api/appearance` mirrors into the host. With no host, the router answers 404 naming
    the tree's routes. That covers imbib-iOS, which answered a silent `ok` before.

  The chords pass the store as `.imbibPreChassisWindow(_:)`, and PMC maps role to pane.
  `PaneLayoutStoreTests` moved to `imbibTests`, with 3 new tests (route answers, panes
  forwarding, appearance mirror): 13/13 pass under `xcodebuild test -only-testing:imbibTests`.
  `PaneLayoutCommandsTests` stays in PMC over `OwnWindowPanes`. The census matched pass A's,
  plus comment-only hits pass A did not list: `ImpressTheme` (source and test),
  `ImpressAutomation` (source and test) and `ImpartApp.swift`. All are reworded.
  `git grep -n "PaneLayoutState\|PaneLayoutStore\|FocusedPane" -- apps/imbib/PublicationManagerCore packages`
  is empty. The code hits that remain are in `apps/imbib/imbib` and imprint's own type
  (`apps/imprint/Shared`, plus its `Tests/ThroughlineTests`). Doc comments in
  `impress-layout-service/src/presets.rs`, `impress-layout/src/shares.rs` and
  `impress-core/src/schemas/ui.rs` still name imbib's type as where the Triage and Full
  presets came from. That type still exists, so those comments are true.
- **imbib's window, live (pass B build).** ⌘0 flips `detailPaneVisible` and back (read from
  `/api/layout`). ⌥⌘0 hides the list, confirmed by screenshot. View ▸ Toggle Sidebar hides
  the sidebar (`sidebarVisible: false`, screenshot) and shows it again. ⌃⌘1 logs `Layout
  applied: 'Triage'` with the detail hidden, and ⌃⌘3 logs `'Full'`. `/api/layout` answers
  `model: "pane-layout-state"`, `/api/layout/apply {"name":"Full"}` answers `ok`, and an
  unknown name answers 404. A chassis app (impress) answers `/api/layout` with 404. **Gap,
  not from this branch:** pressing ⌃⌘S in imbib's window does nothing, because Paper ▸ Save
  to Library is bound to ⌃⌘S too (`imbibApp.swift`, since `cdca0b23`, 2026-01-29; also on
  main). The key reaches neither command. Nothing was saved: Save still holds 2657. Which
  command keeps the chord is a UX decision, so it is left for Tom.
- **Tier B, every chassis app, pass B build (isolated DerivedData `w5-flag`), no flag:**
  impress, imprint, implore, impel and impart are each **12/12, 0 skipped**, and each
  reports `layout.restored`. After one hand-driven ⌃⌘S pair, impress's shares were put back
  to [1,2,3].
- **Gates:** `rust-gate.sh fmt` and `clippy auto`; `cargo test` for impress-core (263 lib),
  impress-layout, impress-layout-service (62), impress-store-ffi (70) and impress-pane-query,
  plus imbib-core's parity test (`--features native`); `check-uniffi-bindings` (7 match; no
  export changed, and the xcframework was rebuilt for the new compiler), `check-schema-refs`,
  `check-kit-deps` and `check-chassis-deps`; PMC `swift build && swift test` (2104 XCTest,
  0 failures, 2 skipped, where 6 moved to imbibTests; 112 swift-testing); ImpressAutomation
  59. All six apps and imbib-iOS build.
- **Left as found / side effects:** the first two build rounds of this pass ran
  `build-impress-app.sh` without `IMPRESS_DERIVED`. They built this branch into the shared
  `DerivedData/impress-suite` and repointed `~/MyApplications/*.app` there. The final
  builds went to `DerivedData/w5-flag`, which the launchers now point at, as pass A left
  them. The `impress-suite` products are this branch's until the next suite build.
- **Ask-first in this pass:** none beyond Tom's three decisions. No vocabulary, schema ref,
  verb argument, `PaneSpec` field or view kind changed; `KindManifest` is the compiler's
  input and gained data that Tom's decision names.
- 2026-09-24 — **W5 verification found the impart wedge, and it was not the tree.** The
  orchestrator's own Tier B run against impart went 3/12: `/api/status` answered, every
  `@MainActor` route timed out, the connections sat half-open. It is W2's "impart wedge seen once
  and not reproduced". A sample showed an idle main run loop and a thread parked in
  `SOME_OTHER_THREAD_SWALLOWED_AT_LEAST_ONE_EXCEPTION`; a breakpoint on `objc_exception_throw`
  caught it ~90 s after launch in `ImpartSpotlightProvider.allItemIDs()`: a Core Data fetch for
  entity "Thread" in a model that names it "CDThread". The raise happened on the main actor inside
  a Swift task and the main actor never ran another job. Latent since 2026-03-05, on every launch
  (the Spotlight snapshot runs whether or not it rebuilds). Fixed in #56 (typed `fetchRequest()`,
  three tests that fail with the production exception when the old spelling is restored), merged
  into this branch. impart built from this branch then passed Tier B **12/12** at 2 min 11 s of
  uptime, past the wedge point. Pass B's earlier 12/12 on impart was genuine: it ran inside the
  first 90 s.
