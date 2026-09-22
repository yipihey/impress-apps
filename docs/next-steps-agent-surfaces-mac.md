# Next steps — agent surfaces on the Mac (ADR-0033)

This is the hand-off for an agent running on Tom's Mac. Everything in
[plan-agent-surfaces.md](plan-agent-surfaces.md) that Rust could prove is proven on Linux;
what remains needs Xcode, a running app, and a second process writing the same store. Work
autonomously through the steps in order, commit after every step that changes files, push
to the branch, and stop only at the "ask first" points named below.

Branch: `claude/gui-abstraction-survey-pf2bp8` (PR opened from it). Never force-push it.

Read first: `CLAUDE.md` (Definition of done: Rust changes, UniFFI exports, schema refs;
the SwiftUI pitfalls), `docs/ADR-0033-agent-surfaces.md`, `docs/agent-surfaces.md`,
`docs/keyboard-grammar.md` § Surface panes, and the last entry of the session log in
`docs/plan-agent-surfaces.md`. Load the `impress-swiftui-pitfalls` skill before touching Swift.

## Rules that hold throughout

- **The renderer is a mapping.** Fix Swift so it compiles and behaves; do not move logic
  into it. If a RenderTree shape is awkward for SwiftUI, change nothing in Swift that
  amounts to interpreting the spec — change `impress-surface`'s `resolve` output instead,
  keep the golden test honest (`UPDATE_GOLDEN=1` re-blesses it), and say so in the log.
- **Rust shapes are contracts.** `RenderTree`, `Event`, `SurfaceDispatchResult` and the
  `/api/surface/*` bodies are what MCP callers see. Changing a field name means changing
  the Rust type, its tests, the Swift Codable and the doc together, in one commit.
- **A UniFFI change is not done until the binding is regenerated:**
  `./scripts/build-xcframeworks.sh --fast impress-store-ffi` then
  `./scripts/check-uniffi-bindings.sh`. Judge the binding diff by declarations gained and
  lost, never by diffstat. Take `swiftformat` off PATH first.
- **Keyboard:** `.keyboardGuarded` on the outermost container only; never `.focusable()`
  around a text field; j/k/Enter/Escape per the grammar.
- **Commits** in the repo's voice (a sentence about what changed and why), one per fix,
  ending with:
  ```
  Co-Authored-By: <your model name> <noreply@anthropic.com>
  ```
  No model identifiers anywhere else. Append what you verified and what you found to the
  session log in `docs/plan-agent-surfaces.md` (append-only, dated) before each push.

## Step 1 — the Rust gate, with the two things Linux could not run

```bash
git checkout claude/gui-abstraction-survey-pf2bp8 && git pull
./scripts/rust-gate.sh fmt
./scripts/rust-gate.sh clippy auto
cargo test -p impress-mcp -p impress-cli          # ort-sys downloads ONNX here; blocked on Linux
./scripts/check-uniffi-bindings.sh
./scripts/check-schema-refs.sh
./scripts/check-kit-deps.sh
```

Expected: all clean. The MCP inventory test's tool count is 428 with `full`. If clippy
finds lints in a crate this branch touched, fix them; if it finds lints in a crate it did
not touch, note them in the log and move on (they are main's).

## Step 2 — rebuild the store xcframework

```bash
./scripts/build-xcframeworks.sh --fast impress-store-ffi
./scripts/check-uniffi-bindings.sh
```

The committed `impress_store_ffi.swift` was regenerated on Linux and matches; this step
rebuilds the header, modulemap and the archive the apps link. If the script rewrites the
`.swift` with a real declaration difference, stop and read it: it means the Mac's
uniffi-bindgen disagrees with Linux's, which has not happened before.

## Step 3 — compile the Swift

```bash
cd packages/ImpressSurface && swift build && swift test && cd ../..
cd apps/impress && [ -d impress.xcodeproj ] || xcodegen generate
xcodebuild -project impress.xcodeproj -scheme impress -configuration Debug build 2>&1 | tail -40
cd ../..
```

`packages/ImpressSurface` and `Chassis/Layout/LayoutSurfacePaneView.swift` have never
compiled. Expect errors of these kinds and fix them in place:

- Codable mismatches between `RenderTree.swift` and the Rust `RenderKind` (the source of
  truth is `crates/impress-surface/src/resolve.rs`; the fixture is
  `crates/impress-surface/tests/golden/signal-explorer.render.json`).
- UniFFI signature mismatches: the binding file is the truth; `Option<u64>` is `UInt64?`,
  `Result<String>` is `throws -> String`, callback interfaces are protocols.
- `@FocusState`/`Binding` threading through the private widget views, `Table` with dynamic
  columns, `TableColumnForEach`. Simplify rather than fight: a `List` of rows with a
  selection binding is acceptable for `table` on the first pass if `Table` will not bend.
- `PlotAutomationHandler.decodeSpec` and `renderPlotSvg` from `ImprintCore`: confirm the
  import and access level; the demo verb emits the `series` shape it reads.

Also run the PMC tests that exist (`xcodebuild test` for the scheme CI uses, or
`swift test` in `apps/imbib/PublicationManagerCore` if that is how the tests run locally)
so nothing outside the new files regressed.

## Step 4 — the loop, end to end, against the running app

```bash
defaults write com.impress.impress impress.layoutTree.enabled -bool YES
# launch the impress app you just built (open the .app from DerivedData or run the scheme)
curl -s http://localhost:23125/api/status | head -c 300
```

Now drive it from a second process, which is the whole point of ADR-0033 D6:

```bash
cargo run -p impress-cli -- --help | grep -i surface        # subcommands are the kebab method names
cargo run -p impress-cli -- surface-examples                # one spec: the signal explorer
cargo run -p impress-cli -- surface-create --spec "$(cargo run -q -p impress-cli -- surface-examples | jq -c '.examples[0]')"
# take the id it prints, then:
cargo run -p impress-cli -- surface-show --id <id> --target '{"split":{"direction":"horizontal","from_focused":true}}'
```

(If the CLI's argument spelling differs, `--help` on the subcommand is authoritative; the
MCP tool names are `impress-surface-service_surface-<verb>`.)

Verify, and record each in the log:

1. The pane appears in the running window without any HTTP call to the app: the S5
   `data_version` poll saw the CLI's write. `curl 'localhost:23125/api/logs?category=surface&limit=40'`
   shows render requested → dispatch applied → tree displayed.
2. j/k walk the widgets; Enter on the slider/field begins editing; Escape returns to
   widget focus; Enter on "Use these bins" fires a click.
3. Dragging a slider emits exactly ONE `change` on release (watch the log), not one per
   pixel.
4. The histogram renders (a line over bin centres, from `surface-demo-service_histogram`).
5. `curl localhost:23125/api/surface`, `curl localhost:23125/api/surface/<id>/render`,
   and a `POST .../dispatch` with `{"widget":"n0.1.1","kind":"change","value":40}` return
   the same shapes as the verbs.
6. From the CLI, `surface-wait --id <id> --after-seq 0 --timeout-ms 20000`, then click
   "Use these bins" in the window: the wait returns `bins-chosen` with the payload. This is
   the agent-reads-what-the-human-did direction.
7. Selecting a row in the table publishes on the pane's channel: another pane bound to
   the same channel changes. If no pane is bound, say so; that is the known gap below.

## Step 5 — the follow-ups S7 flagged, in this order, each its own commit

1. **Dispatch effects owed to the host.** `SurfaceDispatchResult.effects` are decoded but
   only a raw `select` event reaches `context.select`. Make `publish` and `open` effects
   act: the Rust executor already composes layout verbs for them when the runtime knows
   its pane, so the fix is most likely passing the pane on `render`/`dispatch` (the FFI
   takes `pane: UInt64?`) and verifying the effect outcome is `ok`. If an effect still
   reports "no pane", fix that in `impress-surface-service`'s runtime, not in Swift.
2. **List rows through the row-style registry.** `list` uses a plain `List`; route it
   through `RecordViewerRegistry` when the rows carry a record kind, keep the plain List
   as the fallback. Small; if it is not, log it and leave it.
3. **Golden alignment.** The S1 golden's `plot` value is a synthetic `{"bars": [...]}`;
   make the fixture's fake source data use the real `series` shape the demo verb emits so
   the Swift golden test exercises the real decoder. Re-bless with `UPDATE_GOLDEN=1`.
4. **Capability matrix.** Flip the `surface` row's "Mac-verified" cell to what you
   actually verified in step 4.

## Ask first (stop and report instead of deciding)

- Any change to the vocabulary in the plan's normative section, the three schema refs, or
  a verb's arguments.
- Adding a dependency to `packages/ImpressSurface` (it must stay kit-grade: Keyboard,
  Theme, Logging only).
- Anything that would make the FFI depend on a domain core (`cargo tree -p
  impress-store-ffi -e normal | grep -E '^(imprint-core|imbib-core|implore-core)'` must stay
  empty).

## Definition of done

Steps 1–4 green and logged, step 5.1 done, the PR marked ready for review with a comment
listing what was verified live and what remains, and CI on the PR green. Then stop.
