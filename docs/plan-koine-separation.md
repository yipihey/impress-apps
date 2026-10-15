# Koine: the name, and the cut that is still in this repository

The layer's name is **koine**. The crate `koine` re-exports the pure grammar
(`impress-layout`, `impress-pane-query`, `impress-surface`, `impress-verb-surface`).
`koine-tui` is a text performance of `RenderTree`. The conditions below are
met. `scripts/check-kit-standalone.sh` builds that grammar in a scratch
workspace that does not contain `impress-core`. The services that open
`SqliteItemStore` stay in this repository.

ADR-0033 D7 decided the standalone line and scheduled the move for last.
`scripts/check-kit-standalone.sh` is that decision as a command. This plan is
the work that makes the move a release of a contract rather than a copy of
`impress-core`.

## K0 — the name

Done. Call the layer koine. The existing crate paths stay, so UniFFI, the
Swift packages and every `use impress_surface::` keep working. A rename of
those crates is part of the repository cut, not a precondition of it.

## K1 — layout and surface state go through a store trait

Done. `AttributedStore` (`crates/impress-item/src/store.rs`) is `ItemStore`
plus the attributed operation and the compare-and-swap. `SqliteItemStore`
in `impress-core` implements it. `LayoutStore<S: AttributedStore>` and
`SurfaceStore<S: AttributedStore>` default `S` to `SqliteItemStore`, so every
existing caller is unchanged and a second backend can host the same rows.

### K1b — the types leave `impress-core`

The types have moved. `impress-item` owns `Item`, `ItemQuery`,
`OperationSpec`, `GuardedWrite`, the `ItemStore` / `AttributedStore` traits,
and the schema-ref constants, including `impress/ui/layout` and
`impress/ui/surface`. `impress-core` keeps `SqliteItemStore` and the SQL
compiler, and re-exports the crate, so `impress_core::Item` is that `Item`.
`LayoutStore` and `SurfaceStore` name `impress-item` for the protocol.

The services that open `SqliteItemStore` stay in this repository:
`impress-layout-service`, `impress-surface-service`, `impress-store-service`,
`impress-workflow-service`, `impress-ai`, `impress-store-ffi`, and
`impress-capabilities`. They still depend on `impress-core` for the concrete
store, the pane-query compiler, and the loopback token. `check-kit-deps.sh`
allows that reach from a store-tier crate, with features `sqlite`, `schema`,
`collab`.

`check-kit-standalone.sh` copies the pure crates only. It does not copy
`impress-core` or the store tier. That scratch workspace is the grammar
leaving on its own.

### K1c — the AI and task kernels leave too

Done on branch `koine-research-os` (koine docs/plan-koine-ai-tasks.md). The
two store-tier crates whose only reason to stay was `Arc<SqliteItemStore>`
now run over the port:

- `koine-tasks` is the task state machine, the `TaskStoreApi` port,
  executors, the scheduler, spawn rules and jobs. `impel-core`'s `task_*`
  modules and `impress-core`'s `task`/`job` re-export it, and
  `impress-core::task_store` keeps SQLite's single-statement ready queue as
  its port implementation.
- `koine-ai` is `impress-ai` without the LocalModels import, with the
  verbs. `impress-ai` re-exports it and adds `AiStoreSqlite::open`.
  `impress-ai-service` submits the suite's store and workspace as the verbs'
  deployment.

`impel-taskd` runs koine's desk agent as `impress-ai`, with the
`impress-mcp` tools.

## K2 — every app hosts the kit

Done for the window. imbib's `ContentView` is the chrome (sheets, search,
onboarding, startup dedup) and its content is
`ChassisRootView(configuration: .imbib, adoptedModels:)`, using the app's
own view models. ⌘0 / ⌥⌘0 / ⌃⌘S and ⌃⌘1–9 are the tree's chords. h/l are the
tree's focus. `/api/layout`, `/api/layout/apply` and `/api/layout/save` are
no longer registered; the tree's routes are `/api/layout/tree`,
`/api/layout/verb` and `/api/layout/op`.

`PaneLayoutStore` remains the appearance mirror (app appearance, PDF dark
mode). It is not the window's pane model.

iOS imbib is still `IOSContentView`. That shell is outside this cut; the
layout tree is the macOS window. A generated surface on iOS uses
`ImpressSurfaceSession`, the same session the macOS tree re-exports, and
paints the `swift` sheet.

## K3 — one non-Swift frontend renders the same tree

Done as a mapping. `koine-tui` renders a `RenderTree` to lines and turns
j/k/Enter into an `Event`. It does not call verbs and it does not interpret
the event. `reduce` does. A terminal *program* — a tty loop that plans,
resolves, renders, and dispatches — is the next host of this mapping, the
way `ImpressSurface` is the SwiftUI host of the same tree. The mapping is
the frontend the contract required; the program is an app.

## Style

Each frontend applies a sheet. The slot names are shared and the value kind
is the frontend's. The rules, and the Swift and text implementations, are
`docs/plan-koine-style.md`. The sheet is the file
`<workspace>/settings/koine-style.json`. It is not a store record: a pure
crate does not take `impress-core` to remember a colour. `koine::style_file`
is the document. `koine-style-file` is the native writer the text host
links. Swift reads and writes the same JSON with its own file helper. A
host with no filesystem parses the bytes and does not link the writer.

## Navigation

A click, a drag, and a direction key are one `koine::gesture::Gesture`. The
frontend names the element it hit. `koine::gesture::layout_verb` is the
layout verb that gesture already determines: a tile focus, a direction, a
drag of one tile onto another, a tab click that names a known view kind.
The host applies that verb, so a split, a move, a close, and a tab reorder
stay on the arrangement or exploration ring. A button that is not a view
kind stays a surface event for `reduce`. A secondary click stays a menu.
A tab pulled out of its pane uses `split_axes`, and the host attaches the
new spec. A resize uses `resize_verb` once the host has measured the two
sides. `tab_order_verb` is a strip reorder. The cases are
`crates/koine/tests/fixtures/gesture-verbs.json`, and the Swift host is
pinned to that file. On the text frontend the box-drawing frame is the
border, the `≡` on the top edge is the grip, and tab labels share that edge
(`koine_tui::frame`). `verb_for_pointer` and `verb_for_drag` call
`layout_verb`. A drag that starts in the body stays with the pane's content.
The pointer is an SGR 1006 report. `j`/`k` and `h`/`l` are the same `Move`
a pointer step is. A sheet colours the focused frame and does not choose
the gesture.

## The repository

The pure grammar is [koine](https://github.com/yipihey/koine). This repository
depends on one `rev` of that git URL for every pure crate in the kit table.
The store services stay here, because they open `SqliteItemStore`.
`scripts/check-kit-standalone.sh` checks the pin. The koine repository's own
CI runs `cargo test`.
