# Impress Keyboard Grammar

The cross-app shortcut convention ("Consistency Creates Capability"): the same
chord means the same thing in every impress app. The canonical machine-readable
catalog is `UniversalShortcut` in `packages/ImpressKeyboard`. Shortcuts must be
visible in menus and each app's ⌘/ reference window so mouse users can learn
them.

## Universal chords (⌘-layer)

| Chord | Semantic | imbib | imprint |
|-------|----------|-------|---------|
| ⌘1 ⌘2 ⌘3 | Switch primary view | Library / Search (the search form opened last, else the Search section's first) / Inbox | Text Only / Split View / Direct PDF |
| ⌃⌘S | Toggle leading sidebar — and nothing else, in every app (Paper ▸ Save to Library held it too until 2026-09-24; see below) | Sidebar | Outline sidebar |
| ⌘0 | Toggle secondary pane | Detail pane | Preview pane |
| ⌥⌘0 | Toggle list (middle) pane | List pane | Manuscript list |
| ⌘\ | Split editor | — | Two views of the same document |
| ⌃⌘P | Open on second display | Detached PDF window (also Shift+P, guarded) | Detached PDF window |
| ⌃⌘D | All dark / all light | App + PDF together | App+editor+PDF together |
| ⌃⌘1…9 | Apply layout N — N spans the app's layout-tree presets first, then its saved layouts (⌃⌘1 is the app's default arrangement; a `save-layout` takes the next number). imbib's own pre-chassis window keeps its View ▸ Layouts menu: the N-th saved `PaneLayoutState` | View ▸ Layouts (its own window's saved arrangements); every chassis app: View ▸ Apply Layout N (`ImpressLayoutOrdinalButtons`) | Layouts menu: the tree's ordinal N in the chassis window; the editor window's N-th saved layout while a manuscript editor window is key (`ImprintLayoutsMenu`) |
| ⌘/ | Keyboard shortcuts reference | ✓ | ✓ |
| ⌘Z ⇧⌘Z | Undo / redo — routed by the FOCUSED PANE (ADR-0031 D7): while a text view has focus, or when the focused pane is session-bearing (`source` / `editor`), the chord is the first responder's own undo manager; any other focused pane undoes on its **exploration** ring (parameter bindings + view state), and when that ring has nothing, the window's own undo manager answers (an app-level undo such as a deleted row). Edit ▸ Undo / Redo and their key equivalents route the same way: the kit puts a responder into each tree window's chain (`LayoutWindowResponder`) — no app mounts a command for it | the responder chain (imbib's own window has no tree) | every chassis window (the tree) |
| ⌥⌘Z ⌥⇧⌘Z | Undo / redo the window's **arrangement** (split / move / close / resize) — its own ring, so undoing a split never undoes typing | — (no tree in imbib's own window) | every chassis window (the tree) |
| ⌃⌘E | Toggle the reMarkable mirror mark on the selection (ADR-025) | Paper ▸ Mirror to reMarkable (also `e`, guarded); disabled until a device is configured, hidden per-row unless it is in individual mode | — |
| ⌘⇧F | Global search | Focus search | Search across manuscripts — implore/impel (which had no binding) route it to the chassis's builtin "Search Everything" store-wide surface (ADR-0022 D6, `ImpressStoreSearchCommands`); impart's ⌘⇧F stays Forward Message, so its Search Everything sidebar node is click-only |

**A manuscript's papers (ADR-0032)** — imprint has no Papers panel; the papers
are an imbib collection shown in imbib's papers window:

| Chord | Where | Semantic |
|---|---|---|
| ⌥⌘R | imprint | Papers… — sync what the manuscript cites into its imbib collection and open imbib's window on it (also the Papers button in the editor's footer bar) |
| ⇧⌘K | imprint | Insert Citation… — raise the inline palette at the caret (⌘S does the same inside the focused editor) |
| ⏎ | the papers window | Cite the selection into the manuscript, at the caret, in its own syntax |
| ⌘⏎ | the papers window | Cite, then bring imprint forward |

Inside the window every other key is imbib's own list and detail grammar —
⌘F filters, `j`/`k` move, `P` puts the PDF full screen on the second display —
because the window IS imbib's list and detail pane. The editor still answers ⌘F
only while it is first responder (`SourceEditorNSTextView.ownsKeyboardFocus`;
AppKit offers key equivalents to every view in the window, so it used to take
⌘F from every pane).

**⌥⌘0 was missing from this table until 2026-07-31**, through four apps' worth
of adoption, even though `PaneLayoutState.listPaneVisible` documented it and
every one of those apps bound it. Rule 2 below ("new universal actions go into
`UniversalShortcut` + this doc + both ⌘/ views") was followed for the catalog
and not for the doc, and nothing checked. It is checked now:
`PaneLayoutCommandsTests.testTheKeyboardGrammarDocumentsAllThreeChords` fails if
a row for ⌘0, ⌥⌘0 or ⌃⌘S leaves this table.

**⌃⌘S is Toggle Sidebar, only.** From January 2026 (cdca0b23) until
2026-09-24 imbib's Paper ▸ Save to Library ALSO carried ⌃⌘S, and a key
equivalent two menu items claim does neither reliably — in imbib's own window
the chord stopped toggling the sidebar. Save to Library keeps its menu item
and has no chord; saving from the keyboard is the inbox list's own guarded
keys: ⏎ saves, `s` saves and stars, `*` stars
(`UnifiedPublicationListWrapper`'s triage modifier). It shows no plain-key
hint in the menu, because a bare-key equivalent would fire while typing
(the command palette shows ↩). The menu item had also never SAVED: it posted
`.saveToLibrary`, which nothing observed from cdca0b23 on. The publication
list now observes it and runs the ⏎ key's save. Settings ▸ Keyboard (and
the ⌘/ window, which reads the same table) listed Save to Library at ⌃⌘S
until 2026-09-24; the row reads ↩ now, the list's own save. The table's
rows persist per user and `mergeWithDefaults` only ever ADDS rows, so a
corrected default never reached a saved table:
`KeyboardShortcutsSettings.retiredDefaults` moves a saved row that still
carries an old default to the new one at load (and saves once), and leaves
a chord the user chose alone. The same pass fixed Show Notes Tab / Show
BibTeX Tab, which the table had swapped against View ▸ (Notes is ⌘5,
BibTeX ⌘6). `KeyboardShortcutCatalogParityTests
.testMenuActionRowsShowTheMenusChords` compares every menu-backed row with
the chord `imbibApp.swift` binds.

**A chord's menu item must DO something.** Save to Library was not alone:
on 2026-09-24 seventeen more imbib menu commands posted a notification
nothing on the Mac observed — among them ⇧⌘J Dismiss from Inbox, ⌃⌘M /
⌘L / ⇧⌘L Move / Add / Remove Collection, ⌥⌘C Copy DOI/URL, ⇧⌘R Open
References, ⇧⌘N Refresh, ⌥⌘2 Focus List, ⌃N Add Note, and ⌘1 / ⌘3
(observed only by the iOS root since b748151d). Each is wired to the action
that already existed (the list's Delete-key dismiss, the sidebar drop's
move, the toolbar's Copy Link, Explore ▸ References, …).
`MenuNotificationObserverTests` scans every post in `AppCommands` and fails
on a name with no observer anywhere the Mac app links. Its `unwired` list —
the nine commands #62 left dead, each with its reason — is empty since
2026-09-25, and the test stays: a new dead menu item fails it.

**The last nine (2026-09-25)**, each checked in the running app:

| Chord | Command | What it does now |
|---|---|---|
| ⌘2 | View ▸ Show Search | Opens the search form the user opened last (`searchFormLastUsed`, beside the section's order and hidden set in `SearchFormStore`), else the first visible form in the Search section's order. macOS has no single Search tab — the section's children ARE the forms |
| ⌘[ / ⌘] | Go ▸ Back / Forward | Walks this window's sidebar selection history (`NavigationHistory<ImbibTab>`, one per sidebar; recorded where every selection route ends, `selectedTab`). Paper selection is not recorded — the store never held one. An entry whose node is gone (a deleted collection) is skipped. Both items are disabled when there is nothing to go to: the Go menu reads the key window's history through `FocusedValues.imbibNavigationHistory` |
| ⇧⌘C | Edit ▸ Copy as Citation | A formatted reference per selected paper, one per line: imprint's Typst renderer (hayagriva) typesets the store BibTeX in imprint's own default style — Typst's, IEEE — and PDFKit reads the text back; imbib's "Plain Text (APA-like)" export template is the fallback. No CSL engine was written |
| ⌥⌘1 / ⌥⌘3 | View ▸ Focus Sidebar / Focus Detail | ⌥⌘3 is Focus List's mechanism (a `@FocusState` flipped false → true) on `DetailView`'s one focusable container. ⌥⌘1 cannot be: SwiftUI focus does not reach an `NSOutlineView` inside a representable, so `SidebarOutlineView.focusRequest` (a counter, like `dataVersion`) makes the outline first responder in the key window |
| ⇧⌘F | Paper ▸ Share… | `NSSharingServicePicker` for the selection — its BibTeX as text plus each paper's DOI / arXiv / ADS URL — at the top of the key window. The toolbar's `ShareLink` cannot be triggered from code |
| ⇧⌘\ | Window ▸ Toggle PDF Filter | Toggles `has:pdf` in the list's filter text: a `LocalFilterService` post-filter on the row's has-PDF data (`-has:pdf` = none), shown in the filter bar with its count like `flag:` / `tags:` |
| ⇧⌘? | Help ▸ Search Help… | Opens the Help window if it is closed, then raises its search palette with the field focused (a request the window takes when it appears, or the post when it is already open) |

Two more #62 found, not in the list because something observed them:
**⌘G Go ▸ Go to Page…** posted no page and the observer returned — it now
asks for one in a small sheet, in the key window's PDF view only. And
**Annotate ▸ Highlight / Underline / Strikethrough** posted no file id, so the
PDF view drew the markup and never stored it (an `imbib/annotation` row's
parent IS its linked file); the view now supplies the id it is showing
(`AnnotationCommandTarget`), as its own toolbar button always did.
`PaneLayoutCommandsTests.testNoTwoImbibMenuCommandsShareAChord` scans
`imbibApp.swift` (plus the chassis's pane chords and View ▸ Layouts' ⌃⌘1–9)
and fails if any chord is registered twice. Its first run found two more:
the Console window scene held ⇧⌘C, which is Edit ▸ Copy as Citation (the
console opens with ⌃⌘C, View ▸ Show Console, as in impress and impart), and
the Keyboard Shortcuts window scene held ⌘/ beside Help ▸ Keyboard Shortcuts.
Both scene chords are gone.

**Every app binds all four (2026-09-24).** impel and implore bound none of
⌘0 / ⌥⌘0 / ⌃⌘S / ⌃⌘1–9 — a test called adding them a product decision, and
Tom made it: they mount `ImpressPaneLayoutButtons` and
`ImpressLayoutOrdinalButtons` like impress, imprint and impart. impart had
the pane toggles and not the ordinals; it mounts both now.
`PaneLayoutCommandsTests.testEveryChassisAppMountsTheLayoutOrdinals` pins it.

**⌃⌘S / ⌥⌘0 / ⌘0 act on ROLES** (ADR-0031 D5): in every chassis window —
the layout tree, the only chassis root since plan wave 6 W5 — they resize
whichever pane carries `navigator` / `list` / `detail`, wherever the user has
moved it, through `LayoutController` and nothing else (a chord that arrives
before the tree has opened is logged and ignored). The routing is in
`PaneLayoutChordRouter`, in the same file as the buttons. imbib's own window
is its pre-chassis `ContentView`, not a chassis root: there the same three
chords flip the `PaneLayoutState` Booleans that window reads — a model in
imbib's app target, handed to the chassis as `HostWindowPanes`
(`PaneLayoutChordTarget.imbibPreChassisWindow(_:)`, passed by `imbibApp.swift`
alone). h / l follow the same split: `focus_direction` over the tree in a
chassis window, `PaneFocusCycler` in imbib's own.

**The three pane toggles are one shared value.** ⌘0 / ⌥⌘0 / ⌃⌘S are
`ImpressPaneLayoutButtons` (`Chassis/Shared/PaneLayoutCommands.swift`), not four
hand-written copies — ADR-0022 X2 closes D9 finding 4. The chords are published
there as DATA (`chords()`) so this table and the code can be compared by a test
rather than by eye. imprint keeps the label "Toggle Manuscript List" on ⌥⌘0; the
chord and the state it drives are identical to everyone else's.

## Guarded single-key layer (vim grammar)

Only ever behind `.keyboardGuarded` (never fires while typing). Text-first
apps (imprint) rely on the ⌘-layer; list-first apps (imbib) use these heavily.

The triage subset is DATA: `TriageKeyGrammar` in ImpressKeyboard (ADR-0021) —
list surfaces consume the table via their executor instead of hand-rolling
`handleKey`, so the grammar is identical across every record kind. Commands
whose capability is absent for the focused kind are `.ignored`.

As of Stage 1b the table is TOTAL: pane focus (h / l) joined it, and the last
hand-rolled `press.characters == "j"` window handlers (imbib's `DetailView`,
impart's and impel's `ContentView`, impel's `ImpelChassisRoot`) now route
through `TriageKeyGrammar.command(forCharacters:)`. Pane focus is
window-scoped rather than row-scoped, so a list surface returns `.ignored` for
it and lets the event bubble to the shell that owns the split.

**Stage 4c (2026-07-30) deleted two of those handlers with their windows.**
impart's and impel's `ContentView` are gone — the chassis is now each app's only
window — so the surviving single-key grammar for both apps lives in the chassis
list wrappers (`MessageListWrapper`, `AgentRecordListWrapper`) and in impel's
`EscalationsSurface` / `SuggestionsSurface`. Three consequences worth recording:

* impart's `s` / ⇧S / `r` / `u` single keys are **no longer bound at all**. They
  were unreachable before the deletion too: `ContentView.handleKeyPress`
  consulted `ImpartKeyboardShortcutsStore` FIRST and returned `.handled` for any
  keystroke with a default binding, so every one of these posted a notification
  with no observer and the local handlers below were dead code. The chassis list
  binds `s` = star through the shared catalog, which is the catalog's own
  meaning; impart's Save/Star divergence is therefore moot for now, and
  re-introducing Save needs a store-side verb, not a keymap.
* impel's suggestion keys (⏎ accept / ⎋ dismiss) moved INTO
  `SuggestionsSurface`, next to the escalation keys already in
  `EscalationsSurface`, and now drive a visible `List` selection.
* impel's ⌘R (refresh) and impart's ⌘N / ⌘R / ⌘⇧R / ⌘⇧F / ⌘⇧U were declared with
  CAPITAL key literals, which in SwiftUI implies Shift — so the chords were one
  modifier off from the menu titles and from this document. They are lowercase
  now. impart's ⌘⇧R collision (File ▸ Check for New Mail vs Message ▸ Reply All)
  resolved in Reply All's favour, per the table below; Check for New Mail took
  ⌘⇧N (Mail.app's "Get New Mail").

| Key | Semantic | Catalog |
|-----|----------|---------|
| j / k | Navigate down / up | `TriageKeyGrammar` |
| h / l | Cycle pane focus left / right (`PaneFocusCycler`) | `TriageKeyGrammar` (`.focusPaneLeft` / `.focusPaneRight`) |
| n | Create record of the surface's kind | `TriageKeyGrammar` |
| s | Toggle star on selection (imbib parity 2026-07: was save; save moved to `*`) | `TriageKeyGrammar` |
| e | Toggle the reMarkable mirror mark on selection (ADR-025). Publications only — `TriageCapabilities.canMirrorToEink`; every other list wrapper returns `.ignored`. imbib's own `toggleEInkMirrorVim` binding, applied only while a device in individual mode is configured; pairs with ⌃⌘E | `TriageKeyGrammar` (`.toggleEinkMirror`) |
| d | Dismiss selection (restore when in Dismissed) | `TriageKeyGrammar` |
| o | Open selected item's working surface | `TriageKeyGrammar` |
| / | Focus filter | `TriageKeyGrammar` |

## Surface panes (ADR-0033)

A `surface` pane (an agent-authored `impress/ui/surface@1.0.0` document,
rendered by the `surface` view kind) is an ordinary pane, so h/l and the
universal chords above are unchanged — it is not a special case of the
layout tree. Inside the pane, widget focus follows the ADR-0033 defaults and
nothing more:

| Key | Semantic |
|-----|----------|
| j / k | Walk the RenderTree's `focus_order` (the widget ordering `surface_render` computes) |
| Enter | Activate the focused widget — a button click, a field edit, a table/list select |
| Escape | Leave a field back to widget focus |

All of this runs under `.keyboardGuarded`, so a text `field` never loses
keystrokes to j/k/Enter/Escape while it has focus — the same guard rule every
other guarded single key in this document follows.

How the keys get there (wave 7, review SK-K14): the window's layout root is
the one `.focusable()` in the window, and it forwards j / k / ⏎ / ⎋ to the
focused pane's registered handler (`LayoutController.setKeyHandler`) — a
surface pane never wraps its text fields in a focus target of its own. j / k
move only the highlight; Enter gives the highlighted widget real focus (a
field begins editing, a table's arrows and type-select take over, a button
is clicked), and Escape hands the keys back. A typed value is sent when the
field loses focus, on Return (then a `submit`), and before any other widget's
click, select or submit, so a button always acts on what is on screen.

Verified on the Mac 2026-09-25 by `apps/kit-demo --prove` (real key events
and clicks in-process): typed text reaches a button's event, and Edit ▸ Undo
while typing undoes the typing, not the tree.

## Per-surface appearance

Appearance is controlled per surface — app chrome, editor, PDF viewer — each
System/Light/Dark or "Follow App" (`appearanceMode`, `editorAppearance`,
`pdfAppearance` defaults keys in imprint; imbib's PDF dark mode is the same
concept). ⌃⌘D resets overrides and flips everything together.

## The settings binding table

The customizable, settings-visible binding list is also DATA:
`ShortcutCatalog.shared` in ImpressKeyboard holds the suite-neutral vocabulary
(keys + modifiers + category), and each app declares a *profile* that adopts
entries by semantic id — pinning its own persisted id and domain noun — and
splices in its app-specific bindings. `ShortcutCategory`, `ShortcutKey`,
`ShortcutModifiers` and `KeyboardShortcutBinding` live there too.

Before Stage 1b this list was a ~600-line literal inside imbib's
`KeyboardShortcutsSettings` — a second catalog no sibling could see — with a
third, `Impart`-prefixed copy in impart's `MessageManagerCore`; the two had
already drifted on `s`. imbib now resolves from the shared catalog and
`KeyboardShortcutCatalogParityTests` pins the resolved list to a snapshot
taken before the move. **impart has not been converted yet**: its
`ImpartShortcutCategory` carries five sections imbib has no case for
(View Modes, Message Actions, Triage, Compose, Search), so unifying the
category enum changes impart's settings section headers — a visible change
that needs its own parity gate.

## Rules for adding shortcuts

1. Check this table first; reuse the semantic chord if one fits.
2. New universal actions go into `UniversalShortcut` + this doc + both ⌘/ views.
3. New single keys go into `TriageKeyGrammar`; new settings-visible bindings
   go into `ShortcutCatalog.shared` unless they are genuinely app-domain.
4. Never bind unmodified character keys outside `.keyboardGuarded`.
5. Per-app chords must not collide with the universal layer.
