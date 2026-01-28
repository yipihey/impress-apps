import Foundation

/// The editing mode in Vim-style modal editing.
public enum VimMode: String, Sendable, CaseIterable, EditorMode {
    /// Normal mode for navigation and commands.
    case normal
    /// Insert mode for typing text.
    case insert
    /// Visual mode for character-wise selection.
    case visual
    /// Visual line mode for line-wise selection.
    case visualLine

    /// Display name for the mode indicator.
    public var displayName: String {
        switch self {
        case .normal: return "NORMAL"
        case .insert: return "INSERT"
        case .visual: return "VISUAL"
        case .visualLine: return "V-LINE"
        }
    }

    /// Whether this mode allows direct text input.
    public var allowsTextInput: Bool {
        self == .insert
    }

    /// Whether this mode extends selections.
    public var isSelectionMode: Bool {
        self == .visual || self == .visualLine
    }
}
