//! Helix editing commands.

/// A command that can be executed on text.
///
/// These commands mirror the Swift `HelixCommand` enum for cross-platform consistency.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HelixCommand {
    // Mode changes
    /// Enter insert mode at cursor.
    EnterInsertMode,
    /// Enter normal mode.
    EnterNormalMode,
    /// Enter select mode.
    EnterSelectMode,
    /// Enter search mode (forward or backward).
    EnterSearchMode { backward: bool },

    // Basic movement
    /// Move left by count characters.
    MoveLeft { count: usize },
    /// Move right by count characters.
    MoveRight { count: usize },
    /// Move up by count lines.
    MoveUp { count: usize },
    /// Move down by count lines.
    MoveDown { count: usize },

    // Word movement
    /// Move to start of next word.
    WordForward { count: usize },
    /// Move to start of previous word.
    WordBackward { count: usize },
    /// Move to end of current/next word.
    WordEnd { count: usize },

    // Line movement
    /// Move to start of line.
    LineStart,
    /// Move to end of line.
    LineEnd,
    /// Move to first non-blank character on line.
    LineFirstNonBlank,

    // Document movement
    /// Move to start of document.
    DocumentStart,
    /// Move to end of document.
    DocumentEnd,

    // Character finding
    /// Find character forward on line.
    FindCharacter { char: char, count: usize },
    /// Find character backward on line.
    FindCharacterBackward { char: char, count: usize },
    /// Move till (before) character forward.
    TillCharacter { char: char, count: usize },
    /// Move till (after) character backward.
    TillCharacterBackward { char: char, count: usize },
    /// Repeat last find operation.
    RepeatFind,
    /// Repeat last find operation in reverse.
    RepeatFindReverse,

    // Search
    /// Move to next search match.
    SearchNext { count: usize },
    /// Move to previous search match.
    SearchPrevious { count: usize },

    // Selection
    /// Select current line.
    SelectLine,
    /// Select all text.
    SelectAll,

    // Insert mode variants
    /// Append after cursor (enter insert mode after current character).
    AppendAfterCursor,
    /// Append at end of line (enter insert mode at line end).
    AppendAtLineEnd,
    /// Insert at start of line (first non-blank).
    InsertAtLineStart,
    /// Open line below and enter insert mode.
    OpenLineBelow,
    /// Open line above and enter insert mode.
    OpenLineAbove,

    // Editing
    /// Delete selection or character.
    Delete,
    /// Yank (copy) selection.
    Yank,
    /// Paste after cursor.
    PasteAfter,
    /// Paste before cursor.
    PasteBefore,
    /// Change (delete and enter insert mode).
    Change,
    /// Substitute (delete character and enter insert mode).
    Substitute,

    // Line operations
    /// Join lines.
    JoinLines,
    /// Toggle case of character/selection.
    ToggleCase,
    /// Indent line.
    Indent,
    /// Dedent (unindent) line.
    Dedent,
    /// Replace character under cursor.
    ReplaceCharacter { char: char },

    // Repeat and undo
    /// Repeat last change.
    RepeatLastChange,
    /// Undo last change.
    Undo,
    /// Redo last undone change.
    Redo,
}

impl HelixCommand {
    /// Returns whether this command extends selection in select mode.
    pub fn extends_selection(&self) -> bool {
        matches!(
            self,
            HelixCommand::MoveLeft { .. }
                | HelixCommand::MoveRight { .. }
                | HelixCommand::MoveUp { .. }
                | HelixCommand::MoveDown { .. }
                | HelixCommand::WordForward { .. }
                | HelixCommand::WordBackward { .. }
                | HelixCommand::WordEnd { .. }
                | HelixCommand::LineStart
                | HelixCommand::LineEnd
                | HelixCommand::LineFirstNonBlank
                | HelixCommand::DocumentStart
                | HelixCommand::DocumentEnd
                | HelixCommand::FindCharacter { .. }
                | HelixCommand::FindCharacterBackward { .. }
                | HelixCommand::TillCharacter { .. }
                | HelixCommand::TillCharacterBackward { .. }
                | HelixCommand::SearchNext { .. }
                | HelixCommand::SearchPrevious { .. }
        )
    }

    /// Returns whether this command can be repeated with `.`.
    pub fn is_repeatable(&self) -> bool {
        matches!(
            self,
            HelixCommand::Delete
                | HelixCommand::Change
                | HelixCommand::Substitute
                | HelixCommand::PasteAfter
                | HelixCommand::PasteBefore
                | HelixCommand::OpenLineBelow
                | HelixCommand::OpenLineAbove
                | HelixCommand::JoinLines
                | HelixCommand::ToggleCase
                | HelixCommand::Indent
                | HelixCommand::Dedent
                | HelixCommand::ReplaceCharacter { .. }
        )
    }
}

impl Default for HelixCommand {
    fn default() -> Self {
        HelixCommand::EnterNormalMode
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_extends_selection() {
        assert!(HelixCommand::MoveLeft { count: 1 }.extends_selection());
        assert!(HelixCommand::WordForward { count: 1 }.extends_selection());
        assert!(HelixCommand::SearchNext { count: 1 }.extends_selection());

        assert!(!HelixCommand::Delete.extends_selection());
        assert!(!HelixCommand::EnterInsertMode.extends_selection());
    }

    #[test]
    fn test_is_repeatable() {
        assert!(HelixCommand::Delete.is_repeatable());
        assert!(HelixCommand::Change.is_repeatable());
        assert!(HelixCommand::PasteAfter.is_repeatable());

        assert!(!HelixCommand::MoveLeft { count: 1 }.is_repeatable());
        assert!(!HelixCommand::EnterInsertMode.is_repeatable());
    }
}
