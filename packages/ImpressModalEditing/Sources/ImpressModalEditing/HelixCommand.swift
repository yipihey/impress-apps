import Foundation

/// Commands that can be executed in Helix-style modal editing.
public enum HelixCommand: Sendable, Equatable {
    // MARK: - Mode Changes
    /// Enter insert mode at current position.
    case enterInsertMode
    /// Return to normal mode.
    case enterNormalMode
    /// Enter select mode (extend selection).
    case enterSelectMode

    // MARK: - Movement
    /// Move cursor left by count characters.
    case moveLeft(count: Int = 1)
    /// Move cursor right by count characters.
    case moveRight(count: Int = 1)
    /// Move cursor up by count lines.
    case moveUp(count: Int = 1)
    /// Move cursor down by count lines.
    case moveDown(count: Int = 1)
    /// Move cursor to next word start.
    case wordForward(count: Int = 1)
    /// Move cursor to previous word start.
    case wordBackward(count: Int = 1)
    /// Move cursor to start of line.
    case lineStart
    /// Move cursor to end of line.
    case lineEnd
    /// Move cursor to start of document.
    case documentStart
    /// Move cursor to end of document.
    case documentEnd

    // MARK: - Selection
    /// Select entire current line.
    case selectLine
    /// Select entire document.
    case selectAll

    // MARK: - Editing
    /// Delete selection (or character if no selection in some contexts).
    case delete
    /// Yank (copy) selection.
    case yank
    /// Paste after cursor.
    case pasteAfter
    /// Paste before cursor.
    case pasteBefore
    /// Change: delete selection and enter insert mode.
    case change

    // MARK: - Undo/Redo
    /// Undo last action.
    case undo
    /// Redo last undone action.
    case redo

    /// Whether this command should extend the selection (in select mode).
    public var extendsSelection: Bool {
        switch self {
        case .moveLeft, .moveRight, .moveUp, .moveDown,
             .wordForward, .wordBackward, .lineStart, .lineEnd,
             .documentStart, .documentEnd:
            return true
        default:
            return false
        }
    }
}
