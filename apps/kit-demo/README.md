# kit-demo — THROWAWAY

**Not an app. Not shipped. Not in `impress.xcworkspace`, no scheme, no CI lane.**
Delete it whenever it stops being useful.

It is the standalone proof of plan wave 6, W6 (`docs/plan-wave-6-tree-and-kit.md`):
a macOS executable that links **only `ImpressLayout` and `ImpressRustCore`**
(ImpressSurface, ImpressKeyboard and ImpressLogging come in through ImpressLayout)
and still draws a layout tree. No PublicationManagerCore, and no view kind is
registered: the kit's own kinds are all there is — `placeholder` and `surface` when
this was written, plus `console` (ImpressLogging's `ConsoleView`) since the plot/console
fix, so a `console` pane renders here too. The output below is the 2026-09-24 run.

What it does:

1. Opens a scratch `SharedStore` in a temp directory (`$TMPDIR/impress-kit-demo-<pid>`),
   never the user's workspace.
2. Creates one surface through the surface FFI (`SharedSurface.surfaceHttp`,
   `POST /api/surface`): a line of text, a slider, a button.
3. Opens `SharedLayout` for app id `impress` on that store (its Default preset is
   outline + list + info, three kinds the kit leaves to a host) and splits the
   `detail` pane with a `surface` pane over `item(<that surface>)`.
4. Renders `LayoutTreeHost` with `LayoutHostServices(openStore:)` handing it the
   scratch store, and after three seconds prints what the kit rendered.

```bash
cd apps/kit-demo && swift build && .build/debug/KitDemo
```

Expected output (2026-09-24):

```
kit-demo: surface created: 4529b182-65cc-47fe-b05e-014eebf67fcc
kit-demo: tree applied: version 1, 3 tiles changed
kit-demo: tree leaves: 4
kit-demo: kit registry: ["placeholder", "surface"]
kit-demo: tree on screen: version 0, 4 panes
kit-demo: pane 1: outline → renders placeholder
kit-demo: pane 2: list → renders placeholder
kit-demo: pane 3: info → renders placeholder
kit-demo: pane 5: surface → renders surface (single item 4529b182-65cc-47fe-b05e-014eebf67fcc)
```

`standalone.png` is the window (taken in-process by `--prove`, 2026-09-25): three "View
Kind Unavailable" panes naming their query kinds, role and tile, and the surface pane with
its text, slider, text field, a select showing "—" (nothing stored, nothing chosen), the
agent's plain day as a date, and the button.
The temp store is left in `$TMPDIR`; delete it when done.

## `--prove` (plan wave 7, T3)

With `--prove` the demo then drives its own window IN-PROCESS and prints one PASS/FAIL
line per claim: real key events typed into the surface's text field, a real mouse click
on its button, the main menu's own Edit ▸ Undo / Redo and File ▸ New Window items, and a
window close. In-process means no assistive-access grant, and nothing here can reach
another app. The surface grew a text field, a select bound to null, a date stored as
`"2026-09-25"`, and a button whose event carries the text.

The window has to be key: the text-field guard and the menu's responder chain both
start at `NSApp.keyWindow`. A bare executable launched from a background shell cannot
activate, so wrap it in a throwaway bundle and launch it through LaunchServices:

```bash
swift build
D=$TMPDIR/KitDemo.app; mkdir -p $D/Contents/MacOS && cp .build/debug/KitDemo $D/Contents/MacOS/
# Info.plist: CFBundleExecutable KitDemo, CFBundlePackageType APPL, NSPrincipalClass NSApplication
open -n -W --stdout /tmp/kitdemo.out $D --args --prove; grep PROOF /tmp/kitdemo.out
```

Output (2026-09-25; the store is removed on exit):

```
PROOF focus redraws no pane: PASS — pane resolves 4 → 4
PROOF resize redraws no pane: PASS — pane resolves 4 → 4
PROOF set-query redraws exactly one pane: PASS — pane resolves 4 → 5
PROOF select bound to null stays null after render: PASS
PROOF date-only value is not rewritten on render: PASS — day = "2026-09-25"
PROOF Edit ▸ Undo while typing undoes the typing, not the tree: PASS — "hello" → ""
PROOF typed value reaches the button: PASS — bins-chosen payload note = "hello"
PROOF select still unchosen after the click: PASS
PROOF Edit ▸ Undo undoes the focused pane's selection: PASS — selection 1 → 0
PROOF Edit ▸ Redo puts it back: PASS — selection → 1
PROOF ⌘N gives the new window its own controller: PASS — 2 live controllers
PROOF the new window is current and the host: PASS — current is second, host is second
PROOF closing it leaves the first window registered and the host: PASS — 1 live, host is first
PROOF the first window's feed is still on: PASS
PROOF summary: ALL PASS
```

The responder chain it printed, which is how Edit ▸ Undo reaches the tree:
`AppKitWindowHostingView → AppKitWindowHostingController → LayoutWindowResponder →
AppKitWindow → …`.
