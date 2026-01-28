import Foundation

/// Emacs editing modes.
///
/// Unlike Vim/Helix, Emacs doesn't have distinct modal states. Instead, it uses
/// chorded key combinations (Control and Meta modifiers). The "mark" system
/// provides selection functionality.
public enum EmacsMode: String, Sendable, CaseIterable, EditorMode {
    /// Normal editing mode - text is inserted directly.
    case normal

    /// Mark is active - region between mark and point is selected.
    case markActive

    /// Incremental search mode.
    case isearch

    /// Incremental search backward mode.
    case isearchBackward

    // MARK: - EditorMode

    public var displayName: String {
        switch self {
        case .normal:
            return ""  // Emacs doesn't typically show mode in normal operation
        case .markActive:
            return "Mark"
        case .isearch:
            return "I-search:"
        case .isearchBackward:
            return "I-search backward:"
        }
    }

    public var allowsTextInput: Bool {
        // Emacs is always in "insert mode" from a Vim perspective
        true
    }

    public var showsIndicator: Bool {
        // Only show indicator when mark is active or in search mode
        self != .normal
    }
}
