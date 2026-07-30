# Impress Keyboard Grammar

The cross-app shortcut convention ("Consistency Creates Capability"): the same
chord means the same thing in every impress app. The canonical machine-readable
catalog is `UniversalShortcut` in `packages/ImpressKeyboard`. Shortcuts must be
visible in menus and each app's ⌘/ reference window so mouse users can learn
them.

## Universal chords (⌘-layer)

| Chord | Semantic | imbib | imprint |
|-------|----------|-------|---------|
| ⌘1 ⌘2 ⌘3 | Switch primary view | Library / Search / Inbox | Text Only / Split View / Direct PDF |
| ⌃⌘S | Toggle leading sidebar | Sidebar | Outline sidebar |
| ⌘0 | Toggle secondary pane | Detail pane | Preview pane |
| ⌘\ | Split editor | — | Two views of the same document |
| ⌃⌘P | Open on second display | Detached PDF window (also Shift+P, guarded) | Detached PDF window |
| ⌃⌘D | All dark / all light | App + PDF together | App+editor+PDF together |
| ⌃⌘1…9 | Apply saved layout N | Layouts menu | Layouts menu |
| ⌘/ | Keyboard shortcuts reference | ✓ | ✓ |
| ⌘⇧F | Global search | Focus search | Search across manuscripts — implore/impel (which had no binding) route it to the chassis's builtin "Search Everything" store-wide surface (ADR-0022 D6, `ImpressStoreSearchCommands`); impart's ⌘⇧F stays Forward Message, so its Search Everything sidebar node is click-only |

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
| d | Dismiss selection (restore when in Dismissed) | `TriageKeyGrammar` |
| o | Open selected item's working surface | `TriageKeyGrammar` |
| / | Focus filter | `TriageKeyGrammar` |

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
