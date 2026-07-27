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

| Key | Semantic | Catalog |
|-----|----------|---------|
| j / k | Navigate down / up | `TriageKeyGrammar` |
| h / l | Cycle pane focus left / right (`PaneFocusCycler`) | — |
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

## Rules for adding shortcuts

1. Check this table first; reuse the semantic chord if one fits.
2. New universal actions go into `UniversalShortcut` + this doc + both ⌘/ views.
3. Never bind unmodified character keys outside `.keyboardGuarded`.
4. Per-app chords must not collide with the universal layer.
