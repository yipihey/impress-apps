import Foundation

/// Commands that can be executed in Helix-style modal editing.
public enum HelixCommand: Sendable, Equatable, Hashable {
    // MARK: - Mode Changes
    /// Enter insert mode at current position.
    case enterInsertMode
    /// Return to normal mode.
    case enterNormalMode
    /// Enter select mode (extend selection).
    case enterSelectMode
    /// Enter search mode (shows search UI).
    case enterSearchMode(backward: Bool = false)

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
    /// Move cursor to end of word.
    case wordEnd(count: Int = 1)
    /// Move cursor to start of line.
    case lineStart
    /// Move cursor to end of line.
    case lineEnd
    /// Move cursor to first non-blank character on line.
    case lineFirstNonBlank
    /// Move cursor to start of document.
    case documentStart
    /// Move cursor to end of document.
    case documentEnd
    /// Move to next paragraph.
    case paragraphForward(count: Int = 1)
    /// Move to previous paragraph.
    case paragraphBackward(count: Int = 1)
    /// Move to matching bracket.
    case matchingBracket
    /// Scroll down half page.
    case scrollDown(count: Int = 1)
    /// Scroll up half page.
    case scrollUp(count: Int = 1)
    /// Page down.
    case pageDown(count: Int = 1)
    /// Page up.
    case pageUp(count: Int = 1)

    // MARK: - Find Character
    /// Find character forward on current line.
    case findCharacter(char: Character, count: Int = 1)
    /// Find character backward on current line.
    case findCharacterBackward(char: Character, count: Int = 1)
    /// Move to character forward (till - stops before character).
    case tillCharacter(char: Character, count: Int = 1)
    /// Move to character backward (till - stops after character).
    case tillCharacterBackward(char: Character, count: Int = 1)
    /// Repeat last find character command.
    case repeatFind
    /// Repeat last find character command in reverse direction.
    case repeatFindReverse

    // MARK: - Search
    /// Search for pattern and move to next match.
    case searchNext(count: Int = 1)
    /// Search for pattern and move to previous match.
    case searchPrevious(count: Int = 1)

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
    /// Open new line below and enter insert mode.
    case openLineBelow
    /// Open new line above and enter insert mode.
    case openLineAbove
    /// Append after cursor (move right and enter insert mode).
    case appendAfterCursor
    /// Append at end of line.
    case appendAtLineEnd
    /// Insert at start of line (first non-blank).
    case insertAtLineStart
    /// Join current line with next line.
    case joinLines
    /// Toggle case of selection or character under cursor.
    case toggleCase
    /// Indent selection.
    case indent
    /// Dedent selection.
    case dedent
    /// Replace character under cursor with given character.
    case replaceCharacter(char: Character)
    /// Substitute (delete character and enter insert mode).
    case substitute

    // MARK: - Operator + Motion Combinations
    /// Delete text covered by motion.
    case deleteMotion(HelixMotion)
    /// Change text covered by motion (delete and enter insert mode).
    case changeMotion(HelixMotion)
    /// Yank text covered by motion.
    case yankMotion(HelixMotion)
    /// Indent text covered by motion.
    case indentMotion(HelixMotion)
    /// Dedent text covered by motion.
    case dedentMotion(HelixMotion)

    // MARK: - Operator + Text Object Combinations
    /// Delete text object.
    case deleteTextObject(HelixTextObject)
    /// Change text object (delete and enter insert mode).
    case changeTextObject(HelixTextObject)
    /// Yank text object.
    case yankTextObject(HelixTextObject)
    /// Indent text object.
    case indentTextObject(HelixTextObject)
    /// Dedent text object.
    case dedentTextObject(HelixTextObject)

    // MARK: - Repeat
    /// Repeat the last change command.
    case repeatLastChange

    // MARK: - Undo/Redo
    /// Undo last action.
    case undo
    /// Redo last undone action.
    case redo

    /// Whether this command should extend the selection (in select mode).
    public var extendsSelection: Bool {
        switch self {
        case .moveLeft, .moveRight, .moveUp, .moveDown,
             .wordForward, .wordBackward, .wordEnd, .lineStart, .lineEnd,
             .lineFirstNonBlank, .documentStart, .documentEnd,
             .paragraphForward, .paragraphBackward, .matchingBracket,
             .scrollDown, .scrollUp, .pageDown, .pageUp,
             .findCharacter, .findCharacterBackward, .tillCharacter, .tillCharacterBackward,
             .repeatFind, .repeatFindReverse, .searchNext, .searchPrevious:
            return true
        default:
            return false
        }
    }

    /// Whether this command is repeatable with `.`
    public var isRepeatable: Bool {
        switch self {
        case .delete, .yank, .pasteAfter, .pasteBefore, .change,
             .openLineBelow, .openLineAbove, .appendAfterCursor, .appendAtLineEnd,
             .insertAtLineStart, .joinLines, .toggleCase, .indent, .dedent,
             .replaceCharacter, .substitute,
             .deleteMotion, .changeMotion, .yankMotion, .indentMotion, .dedentMotion,
             .deleteTextObject, .changeTextObject, .yankTextObject, .indentTextObject, .dedentTextObject:
            return true
        default:
            return false
        }
    }
}
