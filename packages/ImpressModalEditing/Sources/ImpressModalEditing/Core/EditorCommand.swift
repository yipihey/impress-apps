import Foundation

/// Protocol for editor commands.
///
/// Commands represent actions that can be executed on the text engine.
/// Each editor style defines its own command enum.
public protocol EditorCommand: Hashable, Sendable {
    /// Whether this command should extend the selection when in a selection mode.
    var extendsSelection: Bool { get }

    /// Whether this command is repeatable (can be repeated with a repeat command like `.`).
    var isRepeatable: Bool { get }
}

/// Common command behaviors.
public extension EditorCommand {
    var extendsSelection: Bool { false }
    var isRepeatable: Bool { false }
}

/// A type-erased command wrapper for cross-style operations.
public enum GenericCommand: Sendable, Equatable {
    // MARK: - Movement
    case moveLeft(count: Int = 1)
    case moveRight(count: Int = 1)
    case moveUp(count: Int = 1)
    case moveDown(count: Int = 1)
    case wordForward(count: Int = 1)
    case wordBackward(count: Int = 1)
    case wordEnd(count: Int = 1)
    case lineStart
    case lineEnd
    case lineFirstNonBlank
    case documentStart
    case documentEnd
    case paragraphForward(count: Int = 1)
    case paragraphBackward(count: Int = 1)

    // MARK: - Scroll/Page
    case scrollDown(count: Int = 1)
    case scrollUp(count: Int = 1)
    case pageDown(count: Int = 1)
    case pageUp(count: Int = 1)

    // MARK: - Find/Search
    case findCharacter(char: Character, count: Int = 1)
    case findCharacterBackward(char: Character, count: Int = 1)
    case tillCharacter(char: Character, count: Int = 1)
    case tillCharacterBackward(char: Character, count: Int = 1)
    case searchNext(count: Int = 1)
    case searchPrevious(count: Int = 1)

    // MARK: - Selection
    case selectLine
    case selectAll
    case selectWord
    case selectParagraph

    // MARK: - Editing
    case delete
    case deleteMotion(Motion)
    case deleteTextObject(TextObject)
    case yank
    case yankMotion(Motion)
    case yankTextObject(TextObject)
    case pasteAfter
    case pasteBefore
    case change
    case changeMotion(Motion)
    case changeTextObject(TextObject)
    case replaceCharacter(char: Character)
    case insertNewlineBelow
    case insertNewlineAbove
    case joinLines
    case toggleCase
    case indent
    case dedent
    case indentMotion(Motion)
    case dedentMotion(Motion)

    // MARK: - Kill Ring (Emacs)
    case killToEndOfLine
    case killWord
    case killWordBackward
    case killRegion
    case copyRegion
    case yankFromKillRing
    case yankPop

    // MARK: - Undo/Redo
    case undo
    case redo

    // MARK: - Mode
    case enterInsertMode
    case exitToNormalMode
    case enterSelectionMode
    case setMark  // Emacs mark

    // MARK: - Repeat
    case repeatLastChange
    case repeatFind
    case repeatFindReverse

    // MARK: - Bracket
    case matchingBracket
}
