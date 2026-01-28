import Foundation

/// Commands that can be executed in Emacs mode.
///
/// Emacs commands are typically bound to chorded key combinations using
/// Control (C-) and Meta (M-) modifiers.
public enum EmacsCommand: Sendable, Equatable, Hashable, EditorCommand {
    // MARK: - Movement (Character/Line)

    /// Move forward one character (C-f).
    case forwardChar(count: Int = 1)

    /// Move backward one character (C-b).
    case backwardChar(count: Int = 1)

    /// Move to next line (C-n).
    case nextLine(count: Int = 1)

    /// Move to previous line (C-p).
    case previousLine(count: Int = 1)

    /// Move to beginning of line (C-a).
    case beginningOfLine

    /// Move to end of line (C-e).
    case endOfLine

    // MARK: - Movement (Word)

    /// Move forward one word (M-f).
    case forwardWord(count: Int = 1)

    /// Move backward one word (M-b).
    case backwardWord(count: Int = 1)

    // MARK: - Movement (Sentence/Paragraph)

    /// Move to beginning of sentence (M-a).
    case beginningOfSentence

    /// Move to end of sentence (M-e).
    case endOfSentence

    /// Move forward one paragraph (M-}).
    case forwardParagraph(count: Int = 1)

    /// Move backward one paragraph (M-{).
    case backwardParagraph(count: Int = 1)

    // MARK: - Movement (Buffer)

    /// Move to beginning of buffer (M-<).
    case beginningOfBuffer

    /// Move to end of buffer (M->).
    case endOfBuffer

    /// Go to specific line (M-g g or M-g M-g).
    case gotoLine(Int)

    // MARK: - Deletion

    /// Delete character after point (C-d).
    case deleteChar(count: Int = 1)

    /// Delete character before point (Backspace/DEL).
    case deleteBackwardChar(count: Int = 1)

    /// Kill word forward (M-d).
    case killWord(count: Int = 1)

    /// Kill word backward (M-DEL or M-Backspace).
    case backwardKillWord(count: Int = 1)

    /// Kill to end of line (C-k).
    case killLine

    /// Kill entire line.
    case killWholeLine

    /// Kill region (C-w).
    case killRegion

    /// Copy region to kill ring without deleting (M-w).
    case killRingSave

    // MARK: - Kill Ring / Yank

    /// Yank (paste) from kill ring (C-y).
    case yank

    /// Cycle through kill ring after yank (M-y).
    case yankPop

    // MARK: - Mark and Region

    /// Set mark at point (C-Space or C-@).
    case setMark

    /// Exchange point and mark (C-x C-x).
    case exchangePointAndMark

    /// Select all / Mark whole buffer (C-x h).
    case markWholeBuffer

    /// Deactivate mark (C-g when mark is active).
    case deactivateMark

    // MARK: - Search

    /// Begin incremental search forward (C-s).
    case isearchForward

    /// Begin incremental search backward (C-r).
    case isearchBackward

    /// Search for next occurrence (C-s while in isearch).
    case isearchRepeatForward

    /// Search for previous occurrence (C-r while in isearch).
    case isearchRepeatBackward

    /// Exit isearch at current position.
    case isearchExit

    /// Cancel isearch and return to starting position (C-g).
    case isearchAbort

    // MARK: - Undo

    /// Undo (C-/ or C-_ or C-x u).
    case undo

    /// Redo (typically C-g followed by undo, or C-?).
    case redo

    // MARK: - Transpose

    /// Transpose characters (C-t).
    case transposeChars

    /// Transpose words (M-t).
    case transposeWords

    /// Transpose lines (C-x C-t).
    case transposeLines

    // MARK: - Case

    /// Uppercase word (M-u).
    case upcaseWord

    /// Lowercase word (M-l).
    case downcaseWord

    /// Capitalize word (M-c).
    case capitalizeWord

    // MARK: - Other

    /// Cancel current operation (C-g).
    case keyboardQuit

    /// Insert newline (RET/Enter).
    case newline

    /// Insert newline and indent.
    case newlineAndIndent

    /// Open line - insert newline after point without moving (C-o).
    case openLine

    /// Scroll up (page down) (C-v).
    case scrollUp(count: Int = 1)

    /// Scroll down (page up) (M-v).
    case scrollDown(count: Int = 1)

    /// Recenter display (C-l).
    case recenterTopBottom

    /// Self-insert character.
    case selfInsert(Character)
}
