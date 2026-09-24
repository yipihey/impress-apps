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

`standalone.png` is the window: three "View Kind Unavailable" panes naming their
query kinds, role and tile, and the surface pane with its text, slider and button.
The temp store is left in `$TMPDIR`; delete it when done.
