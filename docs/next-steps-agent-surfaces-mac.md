# Next steps — agent surfaces on the Mac, round 2 (wave 5)

This is the hand-off for an agent running on Tom's Mac. Round 1 (S0–S10, 2026-09-22/23) is
merged in PR #42; its log is the session log in [plan-agent-surfaces.md](plan-agent-surfaces.md).
Wave 5 (V1–V3) is verified on Linux — Rust tests, clippy, the binding regenerated — and what
remains needs Xcode and a running app, as before. Work autonomously through the steps in
order, commit after every step that changes files, push to the branch, and stop only at the
"ask first" points named below.

Branch: `claude/gui-abstraction-survey-pf2bp8` (restarted from `main` after PR #42 merged;
a new PR is open from it). Never force-push it.

Read first: `CLAUDE.md` (Definition of done: Rust changes, UniFFI exports; the SwiftUI
pitfalls), `docs/ADR-0033-agent-surfaces.md` D4 and its 2026-09-23 amendment, the "Wave 5"
section and the last log entry of `docs/plan-agent-surfaces.md`, and
`docs/agent-surfaces.md` § "A second worked example: paper triage". Load the
`impress-swiftui-pitfalls` skill before touching Swift.

## Rules that hold throughout

- **The renderer is a mapping.** Fix Swift so it compiles and behaves; do not move logic
  into it. If a shape is awkward, change the Rust and keep the golden honest
  (`UPDATE_GOLDEN=1`), and say so in the log.
- **Rust shapes are contracts.** `SharedVerbHost`, `RenderTree`, `SurfaceDispatchResult`
  and the `/api/surface/*` bodies are what MCP callers see.
- **A UniFFI change is not done until the binding is regenerated.** The committed
  `impress_store_ffi.swift` was regenerated on Linux for this wave (it gained the
  `SharedVerbHost` protocol, `setVerbHost`, `deleteLayout`; nothing lost). If step 2's
  rebuild rewrites it with a real declaration difference, stop and read it.
- **Commits** in the repo's voice, one per fix, ending with
  `Co-Authored-By: <your model name> <noreply@anthropic.com>`. No model identifiers
  anywhere else. Append what you verified to the session log in
  `docs/plan-agent-surfaces.md` (append-only, dated) before each push.

## Step 1 — the Rust gate

```bash
git checkout claude/gui-abstraction-survey-pf2bp8 && git pull
./scripts/rust-gate.sh fmt
./scripts/rust-gate.sh clippy auto
cargo test -p impress-mcp -p impress-cli
./scripts/check-uniffi-bindings.sh
./scripts/check-schema-refs.sh
./scripts/check-kit-deps.sh
```

Expected: all clean. The inventory grew by one verb (`layout-service_delete-layout`), so any
test pinning the tool count moves by one. One known load-sensitive test:
`impress-store-ffi`'s `a_verb_from_another_object_in_this_process_tells_the_host_the_tree_changed`
waits two seconds for the feed and missed it on Linux only while a release build ran beside
it; on a quiet machine it passes every time. If it fails for you under load, re-run it alone
before reading anything into it.

## Step 2 — rebuild the two frameworks the app now links

```bash
./scripts/build-xcframeworks.sh --fast impress-store-ffi
IMPRESS_SKIP_X86=1 crates/impel-tools/build-xcframework.sh   # ImpelTools.xcframework, macOS only
./scripts/check-uniffi-bindings.sh
```

`ImpelTools.xcframework` lives under `crates/impel-tools/frameworks/` (untracked; impel's
own build makes it). impress now links CounselEngine's new `ImpelToolsFFI` product, which
is that framework plus the committed `impel_tools.swift`.

## Step 3 — compile

```bash
cd apps/impress && xcodegen generate && cd ../..
xcodebuild -project apps/impress/impress.xcodeproj -scheme impress -configuration Debug build 2>&1 | tail -40
cd apps/imbib/PublicationManagerCore && swift build && swift test && cd ../../..
```

New Swift this wave, none of it compiled yet:

- `apps/impress/project.yml` — the `CounselEngine` package with `product: ImpelToolsFFI` on
  the macOS target only. If XcodeGen rejects the `product:` key spelling, the documented
  form is `- package: CounselEngine` / `  product: ImpelToolsFFI`; fix the YAML, not the
  package.
- `apps/impel/Packages/CounselEngine/Package.swift` — the `ImpelToolsFFI` library product.
- `apps/impress/macOS/Services/ImpressVerbHost.swift` — `ImpelToolsVerbHost: SharedVerbHost`
  over `listTools()` / `callTool(name:argsJson:)` / `configure(imbibUrl:imprintUrl:)`, and
  `install(on:)` called from `ImpressApp` beside the HTTP server start. Its error mapping
  throws `SharedStoreError.Storage(message:)`; the protocol's spelling is
  `hasVerb(name:)` / `callVerb(name:argsJson:) throws -> String`, as the regenerated
  binding declares.
- `RustStoreAdapter.layoutSharedStore()` is now `public` so the shell can reach the one
  store every surface pane was opened on.
- `LayoutController` / `LayoutController+Automation` / `LayoutAutomation.swift` — the
  `delete-layout` operation, a mirror of `save-layout`.

## Step 4 — the loop, end to end, against the running app

```bash
defaults write com.impress.impress impress.layoutTree.enabled -bool YES
# launch impress (the flag belongs to impress, not imbib); then also launch imbib
curl -s http://localhost:23125/api/status | head -c 200
curl -s 'http://localhost:23125/api/logs?category=surface&limit=20'   # expect "impel-tools verb host: imbib=http ..."
```

Verify, and record each in the log:

1. **The host is installed and imbib is reachable.** The `surface` log shows the
   `configure` line with `imbib=http` (imbib running) and "verb host installed".
2. **A surface calls an imbib verb in the app.** Author a minimal spec whose one source
   is `{"verb": "imbib-library-service_list-libraries", "args": {}}` and a `kv` or `text`
   over `{{source.libs}}`; `surface-create` + `surface-show` from the CLI; the pane lists the
   libraries. Then quit imbib, relaunch impress, show the surface again: the source draws
   the placeholder naming "imbib is not running" — refused, not silently answered from the
   store. (Known limit, documented on `ImpelToolsVerbHost.install`: `configure` probes once
   per process, so an app started after impress stays unavailable until impress relaunches.
   Record whether that bites in practice.)
3. **`surface-validate` over HTTP accepts a host verb.** `POST /api/surface/validate` with
   that spec answers no problems while the host is installed.
4. **`delete-layout` over HTTP.** `POST /api/layout/op {"op":"save-layout","name":"Tmp"}`,
   then `{"op":"delete-layout","name":"Tmp"}`; `GET /api/layout/layouts` no longer lists
   it; a second delete answers `ok: false` with a message; `{"name":"Triage"}` is refused
   naming `reset-preset`.
5. **Paper triage renders.** `surface-examples` → the second example → create + show: a
   table of unread papers with three buttons. Selecting a row sets `state.selected` (watch
   the dispatch log). **The buttons are expected NOT to work yet**: the table's `select`
   event carries an array of ids and the triage verbs take one `id` — the vocabulary gap
   V3 recorded (see `docs/agent-surfaces.md`), which is Tom's decision, not yours. Record
   exactly what the star button's `call` effect reports.

## Step 5 — L7's Swift half

⌃⌘1–9 applies a preset or saved layout by ordinal: wire the chords to
`LayoutController` → `SharedLayout.applyLayout(nameOrOrdinal:actor:)` (the FFI already
reads a positive integer as the ordinal), guarded like every other chord in the chassis.
Verify: ⌃⌘1 is the app's default arrangement, ⌃⌘2 imbib's Triage, and a layout saved by
`save-layout` takes the next number. Update `docs/keyboard-grammar.md` if its table says
"pending".

## Ask first (stop and report instead of deciding)

- The vocabulary gap in step 4.5 (index paths, single-select tables, or list-taking
  verbs): report what you saw; do not change the vocabulary, the schema refs or a verb's
  arguments.
- Adding a dependency to `packages/ImpressSurface`.
- Anything that would make the FFI depend on a domain core (`cargo tree -p
  impress-store-ffi -e normal | grep -E '^(imprint-core|imbib-core|implore-core)'` must
  stay empty).

## Definition of done

Steps 1–4 green and logged (4.5 recorded, not fixed), step 5 done, the PR marked ready for
review with a comment listing what was verified live and what remains, and CI on the PR
green. Then stop.
