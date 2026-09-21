# Flexible GUI Layout Systems — A Survey

**Status:** Survey (input to a future ADR; this document decides nothing)
**Date:** 2026-09-21
**Authors:** Claude (Fable 5.1 session), for Tom's review
**Relates to:** ADR-0018 (Thin-Twin Chassis), ADR-0019 (Legible Workspace — UI state as
attributed items), ADR-0021 (Record-kind descriptors), ADR-0022 (impress groundwork,
`RecordViewerRegistry`), `docs/chassis-capability-matrix.md`, `docs/keyboard-grammar.md`

---

## Why this survey exists

The chassis has reached the point every multi-tool environment reaches: the number of
sidebar sections, list-row kinds, detail tabs and per-app modes is growing faster than
the hand-built SwiftUI that switches between them. Today the only layout the user can
shape is six scalars in `PaneLayoutState` (three pane toggles, a detail tab, two
appearance fields), saved under a name and recalled with ⌃⌘1–9. Everything else about
*where a thing appears* is decided by the developer in `SectionContentView`, per kind,
per platform.

The proposal on the table is a proper layout layer: a docking system in which the user
(and an agent) arranges panes freely, and the chassis stops making layout decisions.
Before designing one, this document surveys the systems that have solved this well,
extracts the ideas that recur, and names the ones that are genuinely rare. It is meant to
teach, not to decide. A closing section records where impress stands against the survey
and lists the questions a design conversation has to answer.

Every factual claim below was checked by a research pass against primary sources —
source code on GitHub where the vendor docs were unreachable — and claims that could
not be confirmed are marked **unverified**. Sources are listed at the end.

---

## 1. The vocabulary: six decisions every layout system makes

Reading forty systems side by side, the differences collapse onto six axes. Naming them
first makes the rest of the survey short.

1. **Content model.** What is the unit that gets placed? A *typed component* created by a
   factory (VS Code view, Unreal tab spawner, Dockview panel), a *buffer/document* that any
   viewport can show (Emacs, Vim, Obsidian leaf), or an *area that morphs its type in
   place* (Blender editor, Houdini pane tab).
2. **Layout model.** What is the arrangement, as a data structure? A *split tree with tab
   groups at the leaves* (the majority), a *planar rectangle mesh* (Blender), a *set of
   fixed anchored slots* (JetBrains, Godot, Xcode), a *positioned grid* (Grafana), a
   *scrolling strip* (niri, PaperWM), or a *hybrid* (VS Code, Zed, JupyterLab: free tree
   in the centre, fixed slots around it).
3. **Binding.** How does layout state refer to content? By *handle* (a live widget), by
   *string identity* (`objectName`, `uniqueName`, `component`, `kind`), by *type* (Unity
   `GetWindow<T>`), by *replayable command* (JupyterLab), or by *rule/query* (Emacs
   `display-buffer-alist`, i3 `swallows`, Rerun entity queries). This axis decides whether
   a layout survives content that does not exist yet.
4. **Operations.** Split, tab, float, auto-hide, swap, maximize, close, switch type,
   undo. Few systems offer all; which ones are missing is telling.
5. **Persistence and programmability.** Is the layout a value the program can read,
   write, diff, save under a name, and rebuild — and is every user gesture also a command?
6. **Context linking.** When two panes should track the same selection, how is that
   expressed? Global selection (most), per-window scope (Blender), pinning (Blender,
   Unity), or numbered link groups (Houdini alone).

The impress principles map directly onto these: "state is legible" is axis 5, "agents can
participate" is axes 3 and 5, "keyboard-first" is axis 4 plus the command surface, and
"one window, every kind" is axis 1.

---

## 2. The map

| System | Content model | Layout model | Binding | Float | Auto-hide | Named layouts | Scriptable | Linking |
|---|---|---|---|---|---|---|---|---|
| **Emacs** | buffer in any window | split tree + side windows | rules (`display-buffer-alist`) | frames | — | tabs, desktop | fully (Elisp) | dedicated windows |
| **Blender** | area morphs editor type | rectangle mesh (vertices/edges) | enum type per area | new OS window | — | workspaces, in .blend | `bpy.ops.screen.*` | per-window scene, pins |
| **Houdini** | pane tab morphs type | split tree of panes of tabs | enum type + tab name | floating panels | stow (unverified) | desktops (.desk) | full HOM | **numbered link groups** |
| **Obsidian** | leaf hosts any registered view | split/tabs tree + sidedocks | `state.type` string + state | pop-out windows | — | Workspaces plugin | `getLayout/changeLayout` | — |
| **pyqtgraph DockArea** | named Dock widget | H/V/Tab container tree | dock name | temp area window | — | `saveState` dict | small API | — |
| **Qt ADS** | `CDockWidget` | splitter tree + areas + 4 sidebars | `objectName` | yes | yes | perspectives (XML) | C++ | — |
| **KDDockWidgets** | `DockWidget` | Qt-free core: item box tree | `uniqueName` + affinities | nested | side bars | JSON, partial restore | C++/Python | — |
| **AvalonDock** | Document vs Anchorable | explicit `LayoutRoot` tree | `ContentId` | yes | yes | XML/JSON | .NET | — |
| **Dear ImGui** | window re-submitted each frame | binary dock-node tree | window-name hash | yes | — | `imgui.ini` | `DockBuilder*` | — |
| **VS Code** | views in containers; editors by `typeId` | fixed parts + two grids | string ids + serializers | aux windows | — | storage, profiles | `workbench.action.*` | — |
| **JetBrains** | tool windows | anchored sides + editor tabs | `id` in plugin.xml | yes (5 modes) | yes | Layouts (2023.1+) | Java API only | — |
| **Eclipse E4** | parts | one EMF tree for everything | `elementId` / `contributionURI` | detach | trim | perspectives | `EModelService` | — |
| **Lumino / JupyterLab** | widgets | tab-area / split-area tree + fixed areas | tracker + replayed command | — | collapse | workspaces (URL-addressable JSON) | `DockPanel` API | — |
| **Dockview / FlexLayout / Golden Layout** | component by string name | grid or row/tabset tree | `component` + params | yes, pop-out | borders | JSON | full | — |
| **Unreal Slate** | tab spawner by `FName` | area / splitter / stack tree | tab id → spawner | yes | sidebar tabs | ini-embedded JSON, versioned names | C++ builder | — |
| **Unity** | `EditorWindow` by C# type | split / dock area object graph | type | yes | — | `.wlt` files | `GetWindow<T>` | inspector lock |
| **Godot** | dock controls | 8 fixed slots + bottom panel | dock name | 4.x | — | `editor_layouts.cfg` | plugin API | — |
| **Zed** | items by `kind`; panels by name | centre pane tree + 3 docks | `persistent_name`, `kind` | — | — | — (SQLite live state) | `workspace::` actions | — |
| **egui_tiles** | generic `Pane` | Tabs / Linear / Grid tree | your enum | — | — | serde | Rust API | — |
| **egui_dock** | generic `Tab` | binary tree per surface | your enum | window surfaces | — | serde | Rust API | — |
| **Rerun blueprint** | view classes | container tree, *stored as data* | **entity query** | — | — | `.rbl`, timeline | Python API | by query |
| **Zellij** | commands, editors, WASM plugins | KDL pane tree + swap layouts | template + count constraints | floating | stacked | KDL files | `zellij action` | — |
| **tmux** | pane process | layout string | pane id | — | zoom | presets, resurrect | every op is a command | — |
| **i3 / sway** | client windows | container tree (split/tabbed/stacked) | **swallow criteria** | yes | — | `append_layout` JSON | IPC | — |
| **Kakoune** | none — delegates to the WM | — | — | — | — | — | client/server | — |
| **Photoshop** | panels | docks of panel groups | name | yes | icon collapse | workspaces | — | — |
| **DaVinci Resolve** | fixed pages | one layout per task | — | — | — | per-page presets | — | global |
| **Logic Pro** | windows | screensets 1–99 | — | all windows | — | number key | — | — |

---

## 3. Family A — any content in any slot

These systems separate *viewport* from *content* completely. They are the closest in
spirit to "impress everything: every kind, every section, one window".

### Emacs — placement as a rule engine

Emacs is the strongest precedent in the survey, and it is worth understanding precisely.

A frame holds a **window tree**; `window-tree` returns it as data: a combination node is
`(dir edges w1 w2 …)` with `dir` nil for horizontal and t for vertical. Windows are
viewports; **buffers** are content; any buffer can be shown in any live window. Around the
tree, **side windows** partition the frame into a main window and up to N slots per side
(`side` ∈ left/top/right/bottom, `slot` ordering within a side).

The distinctive idea is that **placement is a declarative rule stack, not a property of
the layout**. `display-buffer-alist` maps conditions on the *buffer* (name regexp, major
mode, derived mode, a `category` symbol, the invoking command) to *display actions*: a
list of action functions tried in turn (`display-buffer-reuse-window`,
`-in-side-window`, `-pop-up-window`, `-same-window`, `-in-direction`, `-below-selected`,
`-in-new-tab`, `-no-window`, …) plus parameters (`side`, `slot`, `window-width`,
`preserve-size`, `dedicated`). Precedence is documented: user override > user alist >
default alist > the caller's argument > base > fallback. So a program says "show the
tags list", and *the user's rules* decide it goes in a right side window at slot 0 that
is fit to content and never deleted.

Per-window constraints are first class: **dedicated** windows refuse other buffers,
**atomic** windows are rectangular groups that split/delete as one unit,
`no-delete-other-windows` and `preserve-size` are window parameters. Layout is a value:
`window-state-get` (with a `writable` flag for on-disk use) and `window-state-put`;
`winner-mode` gives layout undo with a ring of 200; `tab-bar-mode` makes each tab a named
window configuration; `desktop-save-mode` persists frames, windows and tabs.

Lessons: (1) content identity + rules beats content identity + coordinates, because a
rule keeps working for content that did not exist when the layout was saved; (2) the
layout must be a plain value with undo; (3) constraints belong on the slot. The cost is
real too — the manual itself warns that the merged action alist "may contain duplicate
entries" and the semantics are notoriously subtle. Side windows cannot be split.

### Blender — areas that change type, on a mesh rather than a tree

Blender's screen is not a tree. `bScreen` holds `ScrVert` points and `ScrEdge` edges;
each `ScrArea` references four corner vertices. The header comment in the source says it
plainly: "Screens have vertices/edges to define areas." Splitting inserts vertices and
edges; joining removes them, and historically required the shared edge to align exactly.
Current code has `screen_areas_align()` to nudge edges so a join can proceed, and a newer
`area_docking_apply()` that lets an area be dragged onto another and split into it.

Any area can become any **editor type** at any time (`Area.type` /
`Area.ui_type`), and the area remembers every editor it has ever shown (`spacedata`
list; first is active) so switching back restores state. Inside an area, **regions** are
fixed roles: header, tool header, toolbar (T), sidebar (N), main window, footer, asset
shelf. Above the screen, **workspaces** are tabs, each with its own screen layout,
object mode and an add-on filter (`owner_ids`), and each *window* owns its scene and
view layer; a workspace can pin a scene.

Operations are all operators: `screen.area_split`, `area_join`, `area_swap`,
`area_dupli` (float = duplicate into a new OS window), `area_close`,
`screen_full_area` (maximize, with a "focus mode" that hides regions),
`space_type_set_or_cycle`. There is **no tabbing and no floating panel**. Layouts live
in the .blend as datablocks; "Load UI" chooses file layout vs current.

Lessons: the editor-type dropdown on every area is the single most powerful affordance
for a "one window, every kind" tool — the user never asks "where is the X panel", they
turn the pane in front of them into X. The rectangle mesh is elegant on screen and
awkward to script; the tree systems below win on programmability.

### Houdini — pane tabs and numbered link groups

A **desktop** is a recursively split tree of **panes**; each pane holds **pane tabs**;
each tab has a type (`hou.paneTabType`: SceneViewer, NetworkEditor, Parm, PythonPanel,
…) and a name so scripts can find it. A tab can change type in place
(`paneTab.setType(...)`, which returns a *new* tab object). Panes split
horizontally/vertically, swap halves (`splitSwap`), maximize one half
(`setIsSplitMaximized`), and tabs can float into floating panels. Desktops are saved as
`.desk` files (HScript text) and chosen from a menu.

The idea nobody else has: **link groups**. Every pane tab watches a "channel". The
default channel is "last selected node"; a tab can be pinned (ignore selection) or tuned
to numbered group 1, 2, 3, so a network editor, a viewer and a parameter pane in group 2
follow each other and ignore the rest. The manual's own analogy is television channels.
Blender's per-window scene and Unity's inspector lock are weaker forms of the same
need. The manual also admits linking "can be complicated and unintuitive".

Lesson: a research environment has exactly this need — "this PDF, this notes pane and
this citation list follow the *same* paper; that second pair follow a different one" —
and an explicit, small, numbered mechanism is the proven way to express it.

### Obsidian — the smallest complete tree

`WorkspaceSplit` (direction) → `WorkspaceTabs` → `WorkspaceLeaf`, plus left/right
`WorkspaceSidedock`s (constrained to split → tabs → leaf) and pop-out
`WorkspaceWindow`s. A leaf hosts *any* registered view: plugins call
`registerView(type, creator)` and a leaf becomes that type via
`leaf.setViewState({type, state})`. The whole layout is one JSON document
(`workspace.json`) where every leaf is `{ "type": "leaf", "state": { "type":
"file-explorer", "state": {...} } }`, and `workspace.getLayout()` /
`changeLayout(layout)` round-trip it. Named layouts are a core plugin.

Lesson: this is what "layout as data with string-typed leaves and opaque per-leaf state"
looks like when kept minimal, and it is enough for a very large plugin ecosystem.

---

## 4. Family B — tab-well trees (the docking mainstream)

The bulk of the field. The model is always the same: a recursive **split tree** whose
leaves are **tab groups** containing typed **panels**; plus floating windows, optionally
auto-hide side bars. The differences are in binding, persistence and API ergonomics.

### pyqtgraph DockArea — the small, transparent one

Three files. `DockArea` has one top container; containers are `HContainer`,
`VContainer` (over `QSplitter`) or `TContainer` (tab stack); leaves are `Dock`s
identified by name. `addDock(dock, position='bottom', relativeTo=None)` with position
∈ left/right/top/bottom/above/below picks the container type, wraps the neighbour if the
types differ, and inserts. Containers with one child remove themselves (`apoptose`), so
the tree stays normalized. Drag-and-drop uses five drop zones; centre means "tab".

`saveState()` returns plain tuples:
```python
{'main': ('horizontal', [('dock', 'A', {}),
                         ('vertical', [...], {'sizes': [...]})], {'sizes': [...]}),
 'float': [(<same shape>, (x, y, w, h)), ...]}
```
`restoreState` only rearranges docks that already exist (`missing='error'|'ignore'|
'create'`, `extra='bottom'|'float'`). No auto-hide, maximize, or nested containers inside
tabs; floating is a second `DockArea` in a bare window.

Lesson: this is the minimum viable model — a normalized tree, name-keyed leaves, a state
value that is trivially diffable — and it is the reason the API feels easy. Everything
richer below is this plus features.

### KDDockWidgets — a toolkit-agnostic core with multiple frontends

The one directly relevant to "Swift, TypeScript, or Rust frontends". KDDW 2.x splits
every component into a **Controller** in `core/` ("pure C++ with no dependency on Qt")
and a **View** per frontend. The layouting engine (`src/core/layouting`: `Item`,
`ItemBoxContainer`, `ItemFreeContainer`) "doesn't know anything about docking or dnd";
it is a recursively nested box layout with min/max/percentage sizing. Frontends that
exist in the tree: `QtWidgets`, `QtQuick`, `Flutter` (on hold, "not ready for the general
public"). A Slint frontend does **not** exist; a 2.1 release note mentions a standalone
layouting example using Slint (unverified).

Model: per main window a `Layout` (item tree) whose leaves are `Group`s (tab groups) of
`DockWidget`s; side bars for auto-hide; an MDI mode; nested floating windows. Binding is
`uniqueName`, and **affinities** restrict which main windows a widget may dock into
(`setAffinities`), which also gives partial save/restore. Persistence is JSON
(`LayoutSaver`, serialization version 3) with keys `mainWindows`, `floatingWindows`,
`closedDockWidgets`, `allDockWidgets`, `screenInfo`; a dock widget records
`lastPosition` (last floating geometry, tab index, placeholders) so re-showing a closed
widget puts it back where it was.

Lesson: the core/frontend split is proven at production scale, and the precise cut is
instructive — *the layout engine knows sizes and nesting; the controllers know docking
semantics; the views know pixels*. The cost is a large API surface and a JSON that
couples to unique names and screen geometry.

### Qt Advanced Docking System — Visual Studio in Qt

"Docking everywhere, no central widget." `CDockManager` owns containers (main plus one
per floating window); each is a `CDockSplitter` tree with `CDockAreaWidget` leaves (tab
stacks of `CDockWidget`s); each container has four auto-hide side bars. Per-widget
feature flags (closable, movable, floatable, delete-on-close, pinnable, no-tab, force
close with area). Persistence is XML (optionally compressed) with `<Splitter
Orientation Count><Sizes>`, `<Area Tabs Current>`, `<Widget Name Closed>`, `<SideBar>`;
named perspectives are saved states in `QSettings`. Binding is `objectName`; widgets
must exist before restore.

### AvalonDock (WPF) — the document/tool distinction made explicit

An explicit serializable object model: `LayoutRoot` { `RootPanel` (nested
`LayoutPanel`s with orientation), four `LayoutAnchorSide`s (auto-hide groups),
`FloatingWindows`, `Hidden` }. Leaves are `LayoutDocument` (a document tab in a
`LayoutDocumentPane`) or `LayoutAnchorable` (a tool window that can hide, auto-hide, or
be shown as a tabbed document). The Visual Studio *document vs tool window* duality is a
type distinction here, and `LayoutDocumentPane` accepts both while
`LayoutAnchorablePane` accepts only tools. Content identity is `ContentId`; XML and
JSON serializers are pluggable.

Lesson: deciding early whether "papers" are documents and "citation list" is a tool, or
whether there is no such distinction (Eclipse E4 has none, Unreal has four tab roles),
shapes everything downstream.

### Dear ImGui docking — the immediate-mode decoupling

Windows are re-submitted every frame by name; a separate persistent tree of
`ImGuiDockNode`s (binary splits, tab bar at leaves, one central node) places them by
`DockId`. Layout lives in `imgui.ini` under `[Docking][Data]`, one indented line per
node, and each window's line records its `DockId`. The `DockBuilder*` API
(`DockBuilderSplitNode`, `DockBuilderDockWindow(name, node)`, `DockBuilderFinish`) builds
layouts programmatically, and settings for windows that were not instanced this session
are kept so the slot survives.

Lesson: **the layout tree outlives its content** — a window that is absent this frame
still has a slot next frame. That is the property a store-backed layout wants, achieved
here by the crude means of string hashes.

### Web: Dockview, FlexLayout, Golden Layout, rc-dock

All share one pattern: **layout JSON stores a string component name plus opaque params;
a factory resolves the name to a live element at load time.** Dockview (framework-agnostic
core, React/Vue/Angular wrappers) serializes a grid (same branch/leaf shape as VS Code)
plus `floatingGroups` and `popoutGroups`, and adds panels with `{ id, component, params,
position: { referencePanel, direction: 'left'|'right'|'above'|'below'|'within' } }`.
FlexLayout's model is `{ global, borders, layout }` with `row → tabset → tab` nodes and
an explicit action vocabulary (`Actions.addTab`, `moveNode`, `maximizeToggle`,
`popoutTab`, `dockFloatToLayout`, `adjustWeights`, …) applied through `model.doAction`,
which is the closest a web library comes to "every gesture is a command". Golden Layout
v2 is stable, v3 in flux.

### Lumino / JupyterLab / Theia — layout restored by replaying commands

Lumino's `DockLayout` config is the cleanest tree in the survey:
```ts
{ type: 'tab-area', widgets: Widget[], currentIndex }
{ type: 'split-area', orientation, children: AreaConfig[], sizes: number[] }
```
with ten insert modes (`split-top` … `tab-after`). JupyterLab wraps it in fixed areas
(left, right, main, top, bottom, down). Because the config holds live widgets, persistence
goes through `ILayoutRestorer`: singleton widgets are registered by name; document-like
widgets are tracked and restored by **re-running the command with the args that created
them**. Workspaces are JSON, exportable, and addressable by URL
(`/lab/workspaces/foo`, `?clone=`, `?reset`).

Lesson: "restore = replay the creating command" is elegant and agent-friendly: the
layout stores *intent* (open notebook X), not a pointer.

### VS Code — fixed parts, free editor grid, everything a command

Two `SerializableGrid`s: the workbench grid whose leaves are the fixed **parts**
(title bar, activity bar, primary side bar, panel, auxiliary side bar, editor, status
bar), and the editor grid whose leaves are editor groups. Serialized nodes are
`{type:'leaf', data, size, visible, maximized}` / `{type:'branch', data: nodes[], size}`.
**Views** live in **view containers** that can sit in the side bar, the panel or the
secondary side bar, and the user drags views between containers; extensions declare both
statically (`contributes.viewsContainers`, `contributes.views`). Editors are referenced
by `typeId` plus a registered serializer. Floating editor windows arrived in 1.85.

What makes it the reference for automation: every layout operation is a command with a
stable id (`workbench.action.splitEditorRight`, `joinAllGroups`,
`toggleMaximizeEditorGroup`, `moveView`, `alignPanelLeft`, `customizeLayout`,
`moveEditorIntoNewWindow`, …) and `IEditorGroupsService.applyLayout(...)` sets the
editor grid from a value. Weakness: a view cannot dock inside the editor grid; parts are
fixed; three separate persistence models.

### Unreal Slate — layouts reference spawners, so missing plugins degrade gracefully

`FTabManager::FLayout` → `FArea` (primary window or floating) → `FSplitter` →
`FStack` → `FTab { TabId, TabState, SidebarLocation }`. Tabs are registered as
**spawners** by `FName` (`RegisterTabSpawner(id, OnSpawnTab, CanSpawnTab)`); a layout
stores only ids; `RestoreFrom` asks spawners for content, and an id nobody registered
becomes `ETabState::InvalidTab` rather than an error. Tab roles: `MajorTab` (asset
editor), `PanelTab`, `NomadTab` ("can be placed with major tabs or minor tabs in any tab
well"), `DocumentTab`. Each asset editor gets a child tab manager, so ids are scoped.
Persistence is JSON embedded in `EditorLayout.ini`, and layout *names* are versioned
(`"MyEditor_Layout_v2"`) so stale defaults are discarded.

### egui_tiles and egui_dock — the Rust models

**egui_tiles** (rerun-io): "the fundamental unit is the `Tile`, either a `Container` or
a `Pane`"; `Container::{Tabs, Linear(Horizontal|Vertical with shares), Grid}`; the whole
state is one `Tree<Pane>` (`Tiles` arena + root id), generic over *your* pane type,
serde-serializable by default. Rendering and policy go through a `Behavior<Pane>` trait:
`pane_ui`, `tab_title_for_pane`, `is_tab_closable`, `simplification_options`,
`is_tile_draggable`, `on_edit(EditAction::{TileResized, TileDragged, TileDropped,
TabSelected})`. `simplify()` normalizes the tree (prune empty/single-child containers,
join nested linears, flatten tabs-in-tabs). No floating windows, no vertical tab bars,
recursion-depth limits.

**egui_dock**: `DockState` = several `Surface`s (`Main`, or `Window` for floating), each a
**binary** split tree of `Node::{Leaf, Vertical, Horizontal}`; a `TabViewer` trait.
Floating yes, grid no.

Elsewhere in Rust: iced has `pane_grid` (binary splits, programmatic `State`, no tabs);
Zed's `workspace` crate is bespoke (`PaneGroup { root: Member::{Axis, Pane} }` plus three
docks holding `Panel`s with `persistent_name()`, persisted to SQLite tables
`pane_groups`/`panes`/`items`, driven by `workspace::` and `pane::` actions); Makepad has
a `Dock` with splitter/tabs items; Slint has an open roadmap issue for docking; gpui,
Xilem/Masonry, Floem and Dioxus ship nothing. **The Rust model worth copying is
egui_tiles' data structure, independent of egui.**

---

## 5. Family C — fixed slots and named recall

The pragmatic end of the spectrum: no free docking, but strong "switch whole layout"
affordances.

- **JetBrains.** Tool windows have an anchor (left/right/bottom/top), a `type`
  (docked, floating, sliding, windowed — the user sees Dock Pinned/Unpinned, Undock,
  Float, Window), and a `split` flag for the second group on that side. Registered in
  `plugin.xml` with an id. Named **Layouts** since 2023.1 roam with the user. The editor
  area is a separate tab/split system. Tool windows cannot dock into the editor grid.
- **NetBeans.** "Modes" are named docking slots declared in `.wsmode` XML with
  GridBag-like constraints; `TopComponent`s dock into a mode by name.
- **Godot.** Eight fixed dock slots (left/right × upper/lower × inner/outer) plus a
  bottom panel; plugins `add_control_to_dock(slot, control)`; layouts in
  `editor_layout.cfg`. Master is moving to an `EditorDock` object with
  `available_layouts` bit flags (vertical, horizontal, floating, main screen).
- **Xcode.** Navigator (left), editor area with added panes (right/below), inspector
  (right), debug area (below): fixed roles, no re-docking, no named layouts in the
  documentation.
- **DaVinci Resolve.** Seven fixed **pages**, one per task stage, with per-page presets.
  The explicit opposite philosophy: the tool decides the layout for the task.
- **Logic Pro screensets.** Numbered 1–99; pressing a number recalls one; the current
  arrangement is stored *automatically* when you switch, no save step; a screenset can be
  locked. This is the cheapest possible keyboard-first layout switching and the closest
  analogue to impress's ⌃⌘1–9.
- **Photoshop.** Panels in groups in edge docks; named workspaces that can also capture
  keyboard shortcuts and menus.

Lesson: fixed-slot systems are what users *tolerate*; pages and screensets are what users
*love* when the tasks are genuinely distinct. A free docking system that also ships
task-shaped presets recallable by a number key gets both.

---

## 6. Family D — layout as data with late-bound content

These are the systems most worth studying for an environment whose store already models
everything as records.

### Rerun blueprint — the layout is stored next to the data, in the same store

"Blueprints are just data. They are structured using the same Entity Component System as
your recordings, but with blueprint-specific archetypes and a separate blueprint
timeline." The viewport is a root **container** (`Horizontal`, `Vertical`, `Grid`,
`Tabs`) of **views** (`Spatial3DView`, `TimeSeriesView`, `TextLogView`,
`DataframeView`, `GraphView`, …) plus panels (`BlueprintPanel`, `SelectionPanel`,
`TimePanel`, each expanded/collapsed/hidden). A view's content is an **entity query**
(`origin="/world"`, `contents="$origin/**"`, with `+`/`-` include/exclude rules; most
specific wins), not a handle. So a view survives data that has not arrived yet, and the
same blueprint applies to every recording with the same application id.

The blueprint is versioned on its own timeline (undo is an earlier revision), can be
sent from code at runtime (`rr.send_blueprint(...)`, including conditionally: "if
robot_error: send a different layout"), saved as `.rbl`, and when none is provided the
viewer generates one by heuristics. Rust and C++ SDKs cannot author blueprints yet; they
load `.rbl` files.

Lesson: this is ADR-0019 taken to its conclusion in a shipping product. Layout records
live in the same store as the data, use the same query/persist/transport machinery, are
addressed by query rather than by pointer, and are legible to programs by construction.

### Zellij — declarative layouts with count-conditioned fallbacks

Layouts are **KDL** files: `pane split_direction="vertical" { pane; pane }`, with
`pane_template` / `tab_template` and a `children` placeholder; panes host commands,
editors or WASM plugins ("a first class citizen in the workspace, just like a terminal
pane"). **Swap layouts** are a separate set of layouts with constraints
(`max_panes`, `min_panes`, `exact_panes`) that are applied automatically as panes are
opened or closed, so the arrangement adapts to count without user intervention. The
CLI round-trips: `zellij action dump-layout` emits the current layout as KDL;
`override-layout --layout-string` applies one.

Lesson: two ideas worth stealing — a human-writable layout language with templates, and
the notion that a layout can declare *how it degrades* as content count changes.

### i3 / sway — layout saved with placeholder slots that swallow content by criteria

The WM keeps one container tree (`splith | splitv | stacked | tabbed`); `i3-save-tree`
dumps a workspace as JSON, and the documentation says the output "is NOT useful until you
manually modify it — you need to tell i3 how to match windows". `append_layout` then
creates placeholder windows which **swallow** later windows matching `{"class":
"^URxvt$", "instance": "^irssi$"}`. Everything is reachable over IPC (`get_tree`
returns the JSON tree). Scrollable tilers (niri, PaperWM) replace the fit-to-screen tree
with an infinite strip of columns where opening a window never resizes the others.

Lesson: swallow criteria are the WM's `display-buffer-alist` — layout is data, content
binds late by rule. The scrolling strip is a genuine alternative geometry for very many
panes.

### tmux and Vim sessions

tmux's window layout is a re-applyable text string; every operation is a command;
`tmux-resurrect` restores layouts and re-launches programs. Vim's `:mksession` writes an
*executable script* that rebuilds tabs, windows and buffers; Neovim adds
`nvim_open_win` where a split can be reconfigured into a float. Both show the two ways to
persist: as data (tmux) or as a replayable program (Vim, JupyterLab).

### Grafana — the positioned grid

A dashboard is JSON: a flat list of panels, each `{ "type": "<plugin id>", "gridPos":
{x, y, w, h} }` on a 24-column grid with "negative gravity". Content is registered by
plugin type; layout is coordinates, not a tree. Trivially serialisable; cannot express
tabs or stacks.

### Kakoune — the null hypothesis

Kakoune deliberately has no windows: "Kakoune enables multiple windows by supporting many
clients on the same editing session, not by reimplementing tiling and tabbing. Those
responsibilities are left to the system window manager." Splits are `tmux
split-window` spawning `kak -c session`. The cost is that the editor cannot express "show
X beside Y" and has no layout state at all.

Lesson: the honest baseline. Every docking system is a bet that the app knows something
about arrangement that the OS does not. For impress the bet is justified only by
cross-pane context (linking) and by kind-aware presets; a plain "open in new window" is
already what macOS gives for free.

---

## 7. Ten lessons that recur

1. **Separate three things: the layout tree, the content registry, and the binding
   between them.** Every mature system has all three as distinct objects (Unreal: layout
   / spawners / tab ids; Dockview: grid / factory / component names; Rerun: containers /
   view classes / queries). The systems that fuse them (Qt `QMainWindow`, Unity) are the
   least portable.
2. **The layout must be a plain value.** A tree you can serialize, diff, hold in a ring
   for undo, save under a name, and rebuild from. pyqtgraph's tuples, Lumino's
   `ILayoutConfig`, Obsidian's `workspace.json`, egui_tiles' `Tree<Pane>` and Rerun's
   blueprint are the exemplars; opaque binary blobs (Qt `saveState`, Unity `.wlt`) are the
   anti-pattern.
3. **Bind content by identity or by rule, never by pointer.** String ids are the
   floor; rules or queries (Emacs, i3, Rerun) are the ceiling, because they keep working
   for content that does not exist yet and for content the user has never arranged.
4. **The tree outlives its content.** ImGui keeps settings for absent windows; Unreal
   marks unknown tabs `InvalidTab`; KDDW remembers a closed widget's last position. A
   slot must survive its occupant being missing, unloaded or not-yet-created.
5. **Normalize the tree.** pyqtgraph `apoptose`, egui_tiles `simplify`, Zed's
   single-member axis collapse. Without normalization, layouts accumulate degenerate
   nesting and every operation has to handle it.
6. **Every gesture is a command with a stable name.** VS Code, Zed, FlexLayout, tmux,
   Zellij, i3. This is what makes a layout scriptable by agents and testable without
   pixels, and it is the property impress's own principles demand.
7. **Slots carry constraints.** Dedicated/atomic windows (Emacs), per-widget feature
   flags (ADS, KDDW), affinities (KDDW), tab roles (Unreal), `available_layouts`
   (Godot). Which kinds may dock where is data on the slot, not code in the host.
8. **Type-in-place is the killer affordance for "every kind in one window".** Blender's
   editor-type menu, Houdini's `setType`, Obsidian's `setViewState`. The user turns the
   pane in front of them into the thing they need instead of hunting for a panel.
9. **Named layouts recalled by a number key are the cheapest win.** Logic screensets,
   Houdini desktops, JetBrains Layouts, VS Code profiles, impress ⌃⌘1–9. Pair free
   docking with task-shaped presets.
10. **Context linking needs an explicit, small mechanism.** Houdini's numbered groups
    are the only complete answer in the survey; pinning is the half answer everyone else
    has. A research environment where several panes follow "the current paper" while
    others follow "the current manuscript" needs this from day one.

Two rarer ideas worth keeping in view: **count-conditioned fallback layouts** (Zellij
swap layouts) and **restore by replaying the creating command** (JupyterLab).

---

## 8. The macOS reality

There is no mature docking framework for AppKit or SwiftUI. The native primitives are
`NSSplitViewController` (fixed adjacent children with sidebar/content-list/inspector
behaviours, no drag-to-rearrange), `NSTabViewController` (tabs, no tearing), SwiftUI
`NavigationSplitView` (two or three fixed columns) and `.inspector` (a trailing sidebar).
A GitHub sweep in September 2026 finds one relevant project, `almonk/bonsplit` (tab bar
plus horizontal/vertical split panes, drag tabs between panes, a layout snapshot; no
docks, floating or tear-off; macOS 14+, created January 2026, MIT). Nothing at the
Dockview or KDDW level exists.

The consequence for impress is that any docking model will be *ours*: a layout tree owned
in Rust (the egui_tiles shape, serde-serializable, exposed over UniFFI like the store),
rendered by a Swift view that walks the tree and places kind-resolved panes into
`NSSplitView`s or a custom container. That is the KDDockWidgets cut — engine and
controllers in the core, views per frontend — and it is the only way a later TypeScript
or Rust-native frontend shares the same layouts. The chassis already has the content
registry half of this (`RecordViewerRegistry`, `RecordKindDescriptor`); what it lacks is
the layout value and the binding.

---

## 9. Where impress stands against the survey

Read against the six axes:

| Axis | impress today | Nearest precedent |
|---|---|---|
| Content model | kinds via `RecordViewerRegistry`; detail tabs per descriptor; sections per preset | Unreal spawners / VS Code views |
| Layout model | fixed three-column split (`NavigationSplitView` + `HSplitView`), sidebar composed of app groups | Xcode / JetBrains |
| Binding | code in `SectionContentView`, two deliberate exceptions (publications, manuscripts) | Qt `QMainWindow` |
| Operations | show/hide three panes, pick a detail tab, detach PDF window | JetBrains |
| Persistence / commands | `PaneLayoutState` (6 fields) in UserDefaults; ⌃⌘1–9; `/api/layout` | Logic screensets |
| Linking | one selection per window | most systems |

What the survey says is already right: the registry keyed by `RecordKindID`, the
descriptor-declared detail tabs, the keyboard grammar as data, the saved layouts with a
number key, and ADR-0019's intent to make UI state attributed store items. What it says
is missing: a layout **value** (a tree), a **binding** from slots to kinds and queries, a
**command vocabulary** for every layout gesture, per-slot **constraints**, and a
**linking** mechanism.

Questions a design conversation has to answer, in the order the survey suggests they
matter:

1. **Is a pane a kind, or a query?** Rerun binds by query; Obsidian by type plus state.
   For impress, "the Info tab of the selected publication" and "flagged manuscripts in
   folder X" are both plausible pane contents, and the second is a query.
2. **Which family of layout model?** Split tree with tab groups (mainstream, egui_tiles
   shape) is the safe default; Blender's mesh is prettier and harder; a scrolling strip
   is the wildcard. Fixed slots around a free centre (VS Code, Zed) is the pragmatic
   hybrid and matches the current sidebar.
3. **Where does the layout value live?** ADR-0019 says the store, with scope by
   visibility and retention tier. Rerun is the proof that this works; the startup-guard
   discipline in ADR-0019 D6 still applies.
4. **Document/tool duality or none?** AvalonDock and Unreal say yes; Eclipse and Blender
   say no. This decides whether the editor session for a manuscript (ADR-0018 D4, an
   invariant) is a pane like any other.
5. **What is the command vocabulary?** A closed list in the style of VS Code /
   FlexLayout actions, generated as `#[impress_method]`s so MCP, CLI and impel get it for
   free, per the Rust-first rule.
6. **How is linking expressed?** Numbered groups (Houdini) on a per-pane field in the
   layout value, with "follow selection" and "pinned" as the two reserved values.
7. **What are the presets?** Reading, Triage, Writing, Reviewing — task-shaped, recalled
   by number, and shipped as store records the user can edit, so that the developer stops
   making layout decisions for the user (the stated purpose of `PaneLayoutStore` in its
   own header comment).
8. **How does a layout degrade?** When a kind is not presentable on the platform
   (`presentableKinds`), when a renderer is not linked, when the window is narrow.
   Unreal's `InvalidTab` and Zellij's swap constraints are the two answers on offer.

---

## 10. Sources checked

Primary sources read by the research pass (vendor documentation hosts were largely
unreachable from the session; the same content was verified in upstream repositories).

- pyqtgraph: `pyqtgraph/dockarea/{DockArea,Dock,Container,DockDrop}.py`
- Qt ADS: `githubuser0xFFFF/Qt-Advanced-Docking-System` README, `doc/user-guide.md`, `src/DockManager.h`, `DockContainerWidget.cpp`, `ads_globals.h`
- KDDockWidgets 2.2: `docs/book/src/architecture_and_concepts.md`, `README-porting.md` (2.0), `src/KDDockWidgets.h`, `src/LayoutSaver.h`, `src/core/{DockWidget,MainWindow}.h`, `src/core/layouting/Item_p.h`
- Qt: `qtbase/src/widgets/widgets/{qmainwindow,qdockwidget,qmainwindowlayout}.cpp`
- wxAUI: `interface/wx/aui/framemanager.h`, `src/aui/framemanager.cpp`; AvalonDock: `source/Components/AvalonDock/Layout/*.cs`; DockPanel Suite: `WinFormsUI/Docking/{Enums,DockPanel,DockPanel.Persistor}.cs`
- Dear ImGui docking branch: `imgui.h`, `imgui_internal.h`, `imgui.cpp`, wiki/Docking
- Blender: `DNA_screen_types.h`, `DNA_workspace_types.h`, `DNA_windowmanager_types.h`, `editors/screen/{screen_ops,screen_edit}.cc`, `makesrna/intern/{rna_screen,rna_space}.cc`
- Houdini: `.desk`, `.pypanel` and HOM scripts in SideFXLabs, qLib, and public pipeline repositories; manual excerpts for `panes.html`, `hou.Desktop`, `hou.Pane`, `hou.PaneTab`
- Unreal: `Runtime/Slate/Public/Framework/Docking/TabManager.h`, `Widgets/Docking/SDockTab.h`, `Docking/LayoutService.{h,cpp}` (public UE5-era mirror)
- Unity: `UnityCsReference/Editor/Mono/GUI/WindowLayout.cs`, `EditorWindow.cs`; Godot: `doc/classes/{EditorPlugin,EditorDock}.xml`, `editor/docks/editor_dock_manager.cpp`
- VS Code: `src/vs/base/browser/ui/grid/grid.ts`, `workbench/services/layout/browser/layoutService.ts`, `workbench/browser/layout.ts`, `actions/layoutActions.ts`, `parts/editor/{editorPart,editorActions}.ts`, `common/views.ts`, `api/browser/viewsExtensionPoint.ts`; vscode-docs `custom-layout.md`, `v1_85.md`
- JetBrains: intellij-sdk-docs `tool_windows.md`; intellij-community `ToolWindowType.java`, `ToolWindowAnchor.java`, `ToolWindowDefaultLayoutManager.kt`, `ToolWindowManagerState.kt`
- Eclipse: `docs/Eclipse4_RCP_FAQ.md`, `schema/{views,perspectives}.exsd`, `LegacyIDE.e4xmi`, `ResourceHandler.java`, sample `Application.e4xmi` / `fragment.e4xmi`; NetBeans `*.wsmode`
- Lumino `packages/widgets/src/{docklayout,dockpanel}.ts`; JupyterLab `packages/application/src/{shell,layoutrestorer}.ts`, `docs/source/user/{workspaces,urls}.md`; Theia `application-shell.ts`
- Dockview `packages/dockview-core/src/dockview/{options,dockviewComponent}.ts`, `api/component.api.ts`; FlexLayout `src/model/Actions.ts`; Golden Layout `src/ts/config/config.ts`; rc-dock README
- Obsidian `obsidian.d.ts`, developer docs `Views.md`, help `Workspaces.md`, a public `workspace.json`
- Zed `crates/workspace/src/{pane_group,dock,persistence}.rs`, `persistence/model.rs`, `assets/keymaps/default-macos.json`
- Apple: `NSSplitViewController`, "Configuring the Xcode project window"; `almonk/bonsplit` README; GitHub repository search
- Emacs `doc/lispref/windows.texi`, `doc/emacs/{frames,windows,misc}.texi`; Vim `runtime/doc/{windows,builtin,starting}.txt`; Neovim `runtime/doc/api.txt`; Helix `book/src/{keymap,editor}.md`, issue #401; Kakoune `doc/design.asciidoc`, `README.asciidoc`, `doc/pages/faq.asciidoc`, `rc/windowing/tmux.kak`
- tmux `tmux.1`; tmux-resurrect README; Zellij `zellij-utils/assets/layouts/{default,default.swap,compact}.kdl`, `zellij-utils/src/{cli,setup}.rs`, docs `creating-a-layout.md`, `swap-layouts.md`, `plugins.md`; WezTerm `docs/multiplexing.md`, `cli/split-pane.md`
- i3 `docs/{layout-saving,ipc,userguide}`; sway `sway-ipc.7.scd`; bspwm README; niri README and `wiki/Tabs.md`; PaperWM README
- egui_tiles `README.md`, `src/{lib,tree,tile,behavior}.rs`, `src/container/{mod,linear}.rs`; egui_dock `src/lib.rs`, `dock_state/{surface,tree/node}.rs`, `widgets/tab_viewer.rs`; iced `widget/src/pane_grid.rs`; Slint issue #1723; Makepad `widgets/src/dock.rs`; `dear-imgui-rs`
- Rerun `docs/content/concepts/visualization/{blueprints,entity-queries}.md`, `howto/visualization/build-a-blueprint-programmatically.md`, `reference/viewer/blueprints.md`, `concepts/logging-and-ingestion/rrd-format.md`, `rerun_py/rerun_sdk/rerun/blueprint/{__init__,api,containers}.py`
- Grafana `docs/sources/visualizations/dashboards/build-dashboards/view-dashboard-json-model/index.md`; FINOS Perspective issue #2093 (workspace schema undocumented)
- Photoshop, DaVinci Resolve, Logic Pro, Nuke, Maya: vendor manual excerpts only
