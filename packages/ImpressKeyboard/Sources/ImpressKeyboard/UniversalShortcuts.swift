//
//  UniversalShortcuts.swift
//  ImpressKeyboard
//
//  The cross-app keyboard grammar ("Consistency Creates Capability"): one
//  semantic catalog of chords every impress app binds the same way, so a user
//  who learns one app has partially learned them all. Apps map each semantic
//  action onto their own concept — e.g. `toggleSidebar` is the library sidebar
//  in imbib and the outline in imprint.
//
//  See docs/keyboard-grammar.md at the repo root for the full grammar,
//  including the guarded single-key (vim) layer: j/k navigate, h/l cycle
//  panes — always behind `.keyboardGuarded`.
//

import SwiftUI

/// Semantic, app-independent shortcuts. Each app binds the subset that makes
/// sense for it, using exactly these keys/modifiers.
public enum UniversalShortcut: String, CaseIterable, Sendable {
    /// ⌘1/⌘2/⌘3 — switch the primary view or edit mode
    case primaryView1, primaryView2, primaryView3
    /// ⌃⌘S — show/hide the leading sidebar (library, outline, …)
    case toggleSidebar
    /// ⌘0 — show/hide the secondary pane (detail pane, preview pane, …)
    case toggleSecondaryPane
    /// ⌘\ — split the main editor into two views of the same content
    case splitEditor
    /// ⌃⌘P — open the document/PDF on the second display
    case openOnSecondDisplay
    /// ⌃⌘D — toggle dark mode for the whole app (per-surface overrides reset)
    case toggleDarkMode
    /// ⌃⌘1…⌃⌘9 — apply saved layout N (represented here by the first)
    case applySavedLayout
    /// ⌘/ — show the keyboard-shortcuts reference
    case shortcutsHelp

    public var key: KeyEquivalent {
        switch self {
        case .primaryView1: "1"
        case .primaryView2: "2"
        case .primaryView3: "3"
        case .toggleSidebar: "s"
        case .toggleSecondaryPane: "0"
        case .splitEditor: "\\"
        case .openOnSecondDisplay: "p"
        case .toggleDarkMode: "d"
        case .applySavedLayout: "1"
        case .shortcutsHelp: "/"
        }
    }

    public var modifiers: EventModifiers {
        switch self {
        case .primaryView1, .primaryView2, .primaryView3, .toggleSecondaryPane,
             .splitEditor, .shortcutsHelp:
            [.command]
        case .toggleSidebar, .openOnSecondDisplay, .toggleDarkMode, .applySavedLayout:
            [.command, .control]
        }
    }

    /// Human-readable chord, e.g. "⌃⌘S" — for menus, help views, and tooltips
    /// so users can learn the grammar with the mouse in hand.
    public var displayString: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + String(key.character).uppercased()
    }

    /// Generic semantic title; apps may refine ("Hide Outline" vs "Hide Sidebar").
    public var title: String {
        switch self {
        case .primaryView1: "Primary View 1"
        case .primaryView2: "Primary View 2"
        case .primaryView3: "Primary View 3"
        case .toggleSidebar: "Show/Hide Sidebar"
        case .toggleSecondaryPane: "Show/Hide Secondary Pane"
        case .splitEditor: "Split Editor"
        case .openOnSecondDisplay: "Open on Second Display"
        case .toggleDarkMode: "Toggle Dark Mode"
        case .applySavedLayout: "Apply Saved Layout 1–9"
        case .shortcutsHelp: "Keyboard Shortcuts"
        }
    }
}
