//
//  TriageKeyGrammar.swift
//  ImpressKeyboard
//
//  The suite-wide single-key triage grammar (ADR-0021, Stage 1) as DATA —
//  the machine-readable catalog for the guarded (unmodified-character) layer,
//  sibling to `UniversalShortcut` for the ⌘ layer. Every impress list surface
//  consumes THIS table via its executor instead of hand-rolling `handleKey`,
//  so "learn one app, know them all" holds by construction.
//
//  Execution stays app-side: a command whose capability is absent for the
//  focused record kind returns `.ignored` (see PMC's TriageKeyExecutor).
//  docs/keyboard-grammar.md is the human-readable mirror of this table.
//

import Foundation

/// Semantic commands of the single-key triage layer.
public enum TriageCommand: String, CaseIterable, Sendable {
    /// Move selection down / up (j / k — arrow keys are handled by the List).
    case navigateDown
    case navigateUp
    /// Create a new record of the surface's kind (default creation affordance).
    case create
    /// Toggle star on the selection.
    case toggleStar
    /// Dismiss the selection — or restore it when already in Dismissed.
    case dismissOrRestore
    /// Open the selection's working surface (window/handoff per shell).
    case open
    /// Focus the list's filter field.
    case focusFilter
    /// Move window focus one pane to the left / right (h / l — vim pane cycling).
    ///
    /// Unlike the other commands these are *window*-scoped, not row-scoped: a
    /// surface that does not own pane focus returns `.ignored` and lets the
    /// event bubble to the shell that does (see `PaneFocusCycler`).
    case focusPaneLeft
    case focusPaneRight
}

/// The canonical key → command table. One place; no per-app copies.
public enum TriageKeyGrammar {
    /// Unmodified character keys (MUST be dispatched through `.keyboardGuarded`).
    public static let characterBindings: [Character: TriageCommand] = [
        "j": .navigateDown,
        "k": .navigateUp,
        "n": .create,
        "s": .toggleStar,
        "d": .dismissOrRestore,
        "o": .open,
        "/": .focusFilter,
        "h": .focusPaneLeft,
        "l": .focusPaneRight,
    ]

    /// Command for a key press's character string, if any.
    public static func command(forCharacters characters: String) -> TriageCommand? {
        guard characters.count == 1, let ch = characters.first else { return nil }
        return characterBindings[ch]
    }
}
