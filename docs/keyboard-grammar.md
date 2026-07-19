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
| ⌘⇧F | Global search | Focus search | Search across manuscripts |

## Guarded single-key layer (vim grammar)

Only ever behind `.keyboardGuarded` (never fires while typing). Text-first
apps (imprint) rely on the ⌘-layer; list-first apps (imbib) use these heavily.

| Key | Semantic |
|-----|----------|
| j / k | Navigate down / up |
| h / l | Cycle pane focus left / right (`PaneFocusCycler`) |
| o | Open selected item |
| / | Filter |

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
