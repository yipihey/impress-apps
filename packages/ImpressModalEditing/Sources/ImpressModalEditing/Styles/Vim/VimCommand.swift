import Foundation

/// Commands that can be executed in Vim-style modal editing.
public enum VimCommand: Sendable, Equatable, Hashable, EditorCommand {
    // MARK: - Mode Changes
    case enterInsertMode
    case enterInsertModeAfter
    case enterInsertModeAtLineStart
    case enterInsertModeAtLineEnd
    case enterNormalMode
    case enterVisualMode
    case enterVisualLineMode
    case openLineBelow
    case openLineAbove

    // MARK: - Movement
    case moveLeft(count: Int = 1)
    case moveRight(count: Int = 1)
    case moveUp(count: Int = 1)
    case moveDown(count: Int = 1)
    case wordForward(count: Int = 1)
    case wordBackward(count: Int = 1)
    case wordEnd(count: Int = 1)
    case wordForwardWORD(count: Int = 1)
    case wordBackwardWORD(count: Int = 1)
    case wordEndWORD(count: Int = 1)
    case lineStart
    case lineEnd
    case lineFirstNonBlank
    case documentStart
    case documentEnd
    case goToLine(Int)
    case paragraphForward(count: Int = 1)
    case paragraphBackward(count: Int = 1)
    case matchingBracket

    // MARK: - Find Character
    case findCharacter(char: Character, count: Int = 1)
    case findCharacterBackward(char: Character, count: Int = 1)
    case tillCharacter(char: Character, count: Int = 1)
    case tillCharacterBackward(char: Character, count: Int = 1)
    case repeatFind
    case repeatFindReverse

    // MARK: - Search
    case enterSearchMode(backward: Bool = false)
    case searchNext(count: Int = 1)
    case searchPrevious(count: Int = 1)

    // MARK: - Editing
    case delete
    case deleteMotion(Motion)
    case deleteTextObject(TextObject)
    case deleteLine(count: Int = 1)
    case deleteToEndOfLine
    case yank
    case yankMotion(Motion)
    case yankTextObject(TextObject)
    case yankLine(count: Int = 1)
    case pasteAfter
    case pasteBefore
    case change
    case changeMotion(Motion)
    case changeTextObject(TextObject)
    case changeLine(count: Int = 1)
    case changeToEndOfLine
    case replaceCharacter(char: Character)
    case substitute
    case joinLines
    case toggleCase
    case indent
    case dedent
    case indentMotion(Motion)
    case dedentMotion(Motion)

    // MARK: - Scroll/Page
    case scrollDown(count: Int = 1)
    case scrollUp(count: Int = 1)
    case pageDown(count: Int = 1)
    case pageUp(count: Int = 1)

    // MARK: - Undo/Redo
    case undo
    case redo

    // MARK: - Repeat
    case repeatLastChange

    // MARK: - Selection
    case selectLine
    case selectAll

    /// Whether this command should extend the selection.
    public var extendsSelection: Bool {
        switch self {
        case .moveLeft, .moveRight, .moveUp, .moveDown,
             .wordForward, .wordBackward, .wordEnd,
             .wordForwardWORD, .wordBackwardWORD, .wordEndWORD,
             .lineStart, .lineEnd, .lineFirstNonBlank,
             .documentStart, .documentEnd, .goToLine,
             .paragraphForward, .paragraphBackward, .matchingBracket,
             .findCharacter, .findCharacterBackward,
             .tillCharacter, .tillCharacterBackward,
             .repeatFind, .repeatFindReverse,
             .searchNext, .searchPrevious,
             .scrollDown, .scrollUp, .pageDown, .pageUp:
            return true
        default:
            return false
        }
    }

    /// Whether this command is repeatable with `.`
    public var isRepeatable: Bool {
        switch self {
        case .delete, .deleteMotion, .deleteTextObject, .deleteLine, .deleteToEndOfLine,
             .yank, .yankMotion, .yankTextObject, .yankLine,
             .pasteAfter, .pasteBefore,
             .change, .changeMotion, .changeTextObject, .changeLine, .changeToEndOfLine,
             .replaceCharacter, .substitute,
             .joinLines, .toggleCase,
             .indent, .dedent, .indentMotion, .dedentMotion,
             .openLineBelow, .openLineAbove:
            return true
        default:
            return false
        }
    }
}
