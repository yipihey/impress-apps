# Koine style: one sheet per frontend

A stylesheet is delivery. The grammar (`RenderTree`, `reduce`) still decides
which widgets exist, which one is next, and what Enter or a click means.
The sheet decides how a widget is drawn. Koine names the sheet. The frontend
applies it. Koine never imports SwiftUI or a terminal library.

This is the contract every frontend follows. Swift (`ImpressSurface`) and
the text frontend (`koine-tui`) are the first two. A third frontend is a new
arm in `crates/koine/src/style.rs`, not a private paint table beside it.

The sheet is the file `<workspace>/settings/koine-style.json`. `StyleBook`
is the in-memory book, keyed by frontend id, so a value can be set while no
window is open. A missing file is the defaults. `koine::style_file` is the
document: `wire_version`, the `frontends` map, and the refusal of a value
`set` would refuse. `koine-style-file` is the native writer that locks the
path with `impress-fs-lock`. A host with no filesystem parses the bytes and
does not link that crate. It is not a store row
(`docs/plan-koine-separation.md`): a pure crate does not take `impress-core`
to remember a colour. Swift and the text host read and write the same file,
so an edit in one process is what the other loads next.

## Rules

1. **Slot names are the grammar's.** The required names are `column`, `row`,
   `text`, `section`, `button`, `field`, `list`, `table`, `status.error`,
   `status.warning`, `status.info`, and `focus`. A frontend declares every
   one of them and no others. A private widget's paint is not a slot.
   `grid`, `tabs`, `plot`, `image`, `log`, `kv`, `divider`, `spacer`, and
   `placeholder` stay on the renderer's own defaults. `success` and `ok`
   status levels are not slots; Swift keeps them on the system green.
2. **One value kind per slot, chosen by the frontend.** The kinds are
   `color`, `spacing`, `font`, and `line`. Swift uses spacing for stacks and
   tables, font for text, and color for controls and status. The text
   frontend uses spacing for column and row indent, and a line template for
   everything it prints. A line template is never applied as a color. The
   sheet is tagged with the frontend id, and a frontend applies a sheet only
   when the id is its own.
3. **Values are tokens, not measurements from another platform.** Color
   tokens are `automatic`, `accent`, `primary`, `secondary`, `error`,
   `warning`, `info`. Font tokens are `automatic`, `body`, `title`, `mono`.
   Spacing is an integer from 0 to 64, written in canonical decimal (`8`,
   not `08`). A line is non-empty. Its placeholders are `{label}`, `{text}`,
   `{title}`, `{level}`, `{message}`, `{columns}`, and `{value}` — `{value}`
   is there because a field's line already prints the field's value. No
   other placeholder, and no unclosed `{`.
4. **`automatic` means the control's own look.** On Swift, `automatic` for a
   color or a font applies no modifier: a button is not tinted, text keeps
   the font it already had, and the focus ring stays the system accent.
   Spacing defaults are the numbers the renderer already used (Swift column
   and row are 8; the text frontend indents both by 2). Swift list and table
   default to 0, which is no extra padding, because those widgets had none.
   A default sheet must not restyle a surface that never asked.
5. **`set` refuses.** An unknown frontend, an unknown slot, a value of the
   wrong kind, an unknown token, a spacing outside 0...64, an empty line, or
   an unknown placeholder is an error. The previous value stays. `reset`
   restores that slot's default. `reset` of an unknown slot is the same
   refusal.
6. **The sheet cannot change meaning.** It cannot add a widget, hide one,
   reorder focus, or decide what a click does. On the text frontend, a
   collapsed section still ends with ` (collapsed)` after the template,
   because collapsed is grammar. An empty expansion of the focus marker is
   drawn as `>`, so a template cannot erase the cursor. What a click, a drag,
   or a direction key means is `koine::gesture`, not a slot.
7. **The editor is one surface over `set` and `reset`.** `editor_spec`
   builds one field per slot and a Reset button beside it. The loop is in
   Rust, not in the spec. `editor_apply` treats a `change` whose widget id
   is a slot as `set`, and a `click` on `reset:<slot>` as `reset`. A native
   editor (Swift's `KoineStyleEditor`) may exist only by calling the same
   rules. Resolving the spec shows the sheet: pass `editor_state` as the
   state argument.
8. **The wire vocabulary is `crates/koine/tests/fixtures/style-vocabulary.json`.**
   `vocabulary_json()` is the Rust table. The file is that value, pretty
   printed. Swift's slot table is source of its own, and
   `KoineStyleTests` fails when the file and the Swift table disagree. A new
   frontend updates the Rust arm, the file, and its own copy in the same
   change.

`grid` on Swift takes the `column` spacing. It is not a slot. Containers the
text frontend does not have a slot for (`section` bodies, `tabs`, `grid`)
keep the two-space indent they already had; `section`'s *line* is the line
slot, and its children's indent is the old two spaces.

## What each frontend applies

| Slot | Swift | Swift default | Text | Text default |
|---|---|---|---|---|
| `column` | stack spacing | `8` | indent | `2` |
| `row` | stack spacing | `8` | indent | `2` |
| `text` | font | `automatic` | line | `text {text}` |
| `section` | font | `automatic` | line | `section {title}` |
| `button` | color | `automatic` | line | `button {label}` |
| `field` | font | `automatic` | line | `field {value}` |
| `list` | padding | `0` | line | `list` |
| `table` | padding | `0` | line | `table {columns}` |
| `status.error` | color | `error` | line | `status error: {message}` |
| `status.warning` | color | `warning` | line | `status warning: {message}` |
| `status.info` | color | `info` | line | `status info: {message}` |
| `focus` | color | `automatic` | prefix | `>` |

Swift maps tokens to the system colours it already used: `error` is red,
`warning` is orange, `info` and `secondary` are the secondary label colour,
`accent` is the accent, `primary` is the primary label. `info` is secondary
because that is the colour an unclassified status already had.

The text frontend's column and row defaults are both 2 because every level
was already indented by two spaces. They are separate slots, so a row can
be tightened later without moving columns. Shipping `1` for `row` would
restyle every row on arrival.

## Adding a frontend

1. Add its id to `FRONTENDS` and a `[Slot]` arm in `crates/koine/src/style.rs`.
   The names are `REQUIRED_SLOTS`, in that order. Each slot has one kind.
   Each default reproduces what that frontend already drew.
2. Regenerate `style-vocabulary.json` (`UPDATE_STYLE_VOCABULARY=1 cargo test
   -p koine --lib vocabulary_matches_the_committed_fixture`) and commit it.
3. Apply the sheet in the renderer. Refuse a sheet whose frontend id is not
   yours. `automatic` (where the kind has it) applies nothing on top of the
   control.
4. Edit through `editor_spec` / `editor_apply`, or a native editor that
   calls `set` and `reset` with the same checks.
5. Do not put style keys on the surface spec. Do not invent a slot for one
   screen.

## The file, and the two hosts

The sheet is a file, `<workspace>/settings/koine-style.json`, not a store
row. `koine` refuses a value `set` would refuse, and refuses a document
whose `wire_version` is not 1, whole, so one bad line cannot repaint a
window with a half-read sheet. `koine-style-file` is what locks and writes
that document on a machine that has the workspace directory. A missing file
is the defaults.

`wire_version` 1 is an object `frontends` keyed by frontend id. Each value
is the slot map. A slot that is absent keeps its default. Swift and the
text host write every slot they know, so the next reader sees the same book.

View ▸ Edit Style… (⌥⌘Y) opens the editor in every chassis app. iOS opens
the same editor from the settings sheet (`settings.koineStyle`). A color or
a font is a picker of the tokens. Spacing is a stepper. A text-frontend
line is a field. Swift's sheet is the environment `SurfaceView` already
reads, so a change repaints the open surfaces. The text sheet is the same
file; the terminal applies it when it next loads.

iOS is the `swift` frontend. It does not get its own slot table: SwiftUI is
the actuator on both platforms, and `SurfaceView` already paints
`\.koineStyle` on iOS. A generated pane is the same `SurfacePaneModel` and
the same `SurfaceView` (`ImpressSurfaceSession`, which both platforms link).
The macOS layout tree stays in `ImpressLayout`.

`koine-tui` is that terminal host:

```
koine-tui show [frontend]
koine-tui set <frontend> <slot> <value>
koine-tui reset <frontend> <slot>
koine-tui render
koine-tui edit [frontend]
```

`render` draws the paper-triage example with the saved text sheet. `edit`
reads `set` and `reset` lines from the terminal and writes the file. The
workspace is `IMPRESS_WORKSPACE`, or the suite group container's
`workspace` directory.

The service verbs `style-slots`, `style-sheet`, `style-set`, and
`style-reset` are these same functions once a host process exposes them.
They are not a separate book.
