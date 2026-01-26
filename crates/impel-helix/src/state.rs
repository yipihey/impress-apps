//! Helix state machine for modal editing.

use crate::{HelixCommand, HelixKeyHandler, HelixKeyResult, HelixMode, HelixTextEngine, KeyModifiers, PendingCharacterOperation};

/// The central state machine for Helix-style modal editing.
pub struct HelixState {
    /// The current editing mode.
    mode: HelixMode,
    /// The key handler for translating key events to commands.
    key_handler: HelixKeyHandler,
    /// Whether search mode is active.
    is_searching: bool,
    /// Whether search is backward.
    search_backward: bool,
    /// Current search query.
    search_query: String,
    /// Last repeatable command for "." functionality.
    last_repeatable_command: Option<HelixCommand>,
    /// Text inserted after last insert-mode-entering command (for repeat).
    last_inserted_text: String,
    /// Clipboard/register content.
    register_content: String,
    /// Whether register content is linewise.
    register_linewise: bool,
}

impl HelixState {
    /// Create a new Helix state machine.
    pub fn new() -> Self {
        Self {
            mode: HelixMode::Normal,
            key_handler: HelixKeyHandler::new(),
            is_searching: false,
            search_backward: false,
            search_query: String::new(),
            last_repeatable_command: None,
            last_inserted_text: String::new(),
            register_content: String::new(),
            register_linewise: false,
        }
    }

    /// Get the current mode.
    pub fn mode(&self) -> HelixMode {
        self.mode
    }

    /// Set the current mode.
    pub fn set_mode(&mut self, mode: HelixMode) {
        self.mode = mode;
        self.key_handler.reset();
    }

    /// Whether search mode is active.
    pub fn is_searching(&self) -> bool {
        self.is_searching
    }

    /// Get the current search query.
    pub fn search_query(&self) -> &str {
        &self.search_query
    }

    /// Set the search query.
    pub fn set_search_query(&mut self, query: String) {
        self.search_query = query;
    }

    /// Append to the search query.
    pub fn append_to_search_query(&mut self, char: char) {
        self.search_query.push(char);
    }

    /// Remove last character from search query.
    pub fn backspace_search_query(&mut self) {
        self.search_query.pop();
    }

    /// Whether search is backward.
    pub fn search_backward(&self) -> bool {
        self.search_backward
    }

    /// Get the pending key for display.
    pub fn pending_key(&self) -> Option<char> {
        self.key_handler.pending_key()
    }

    /// Get the count prefix for display.
    pub fn count_prefix(&self) -> Option<usize> {
        self.key_handler.count_prefix()
    }

    /// Whether awaiting a character input.
    pub fn is_awaiting_character(&self) -> bool {
        self.key_handler.is_awaiting_character()
    }

    /// Get the register content.
    pub fn register_content(&self) -> &str {
        &self.register_content
    }

    /// Yank text into the register.
    pub fn yank(&mut self, text: &str, linewise: bool) {
        self.register_content = text.to_string();
        self.register_linewise = linewise;
    }

    /// Paste from the register.
    pub fn paste(&self) -> (&str, bool) {
        (&self.register_content, self.register_linewise)
    }

    /// Record inserted text for repeat functionality.
    pub fn record_inserted_text(&mut self, text: &str) {
        self.last_inserted_text = text.to_string();
    }

    /// Get the last inserted text.
    pub fn last_inserted_text(&self) -> &str {
        &self.last_inserted_text
    }

    /// Reset the state machine to normal mode.
    pub fn reset(&mut self) {
        self.mode = HelixMode::Normal;
        self.key_handler.reset();
        self.is_searching = false;
        self.search_query.clear();
    }

    /// Enter search mode.
    pub fn enter_search(&mut self, backward: bool) {
        self.is_searching = true;
        self.search_backward = backward;
        self.search_query.clear();
    }

    /// Cancel search mode.
    pub fn cancel_search(&mut self) {
        self.is_searching = false;
        self.search_query.clear();
    }

    /// Execute search.
    pub fn execute_search(&mut self) {
        self.is_searching = false;
        // Search query is preserved for n/N navigation
    }

    /// Handle a key press and optionally execute on a text engine.
    ///
    /// Returns `true` if the key was handled, `false` if it should be passed through.
    pub fn handle_key<E: HelixTextEngine>(
        &mut self,
        key: char,
        modifiers: &KeyModifiers,
        mut text_engine: Option<&mut E>,
    ) -> bool {
        // Handle search mode input
        if self.is_searching {
            return self.handle_search_input(key, text_engine);
        }

        let result = self.key_handler.handle_key(key, self.mode, modifiers);

        match result {
            HelixKeyResult::Command(command) => {
                self.execute_command(&command, text_engine);
                true
            }
            HelixKeyResult::Commands(commands) => {
                for command in &commands {
                    self.execute_command(command, text_engine.as_deref_mut());
                }
                true
            }
            HelixKeyResult::PassThrough => false,
            HelixKeyResult::Pending | HelixKeyResult::AwaitingCharacter => true,
            HelixKeyResult::Consumed => true,
            HelixKeyResult::EnterSearch { backward } => {
                self.enter_search(backward);
                true
            }
        }
    }

    fn handle_search_input<E: HelixTextEngine>(
        &mut self,
        key: char,
        text_engine: Option<&mut E>,
    ) -> bool {
        match key {
            '\x1b' => {
                // Escape - cancel search
                self.cancel_search();
            }
            '\r' | '\n' => {
                // Enter - execute search
                if let Some(engine) = text_engine {
                    if !self.search_query.is_empty() {
                        engine.perform_search(&self.search_query, self.search_backward);
                    }
                }
                self.execute_search();
            }
            '\x7f' | '\x08' => {
                // Backspace
                self.backspace_search_query();
            }
            c => {
                // Regular character
                self.append_to_search_query(c);
            }
        }
        true
    }

    /// Execute a command on the optional text engine.
    pub fn execute_command<E: HelixTextEngine>(
        &mut self,
        command: &HelixCommand,
        mut text_engine: Option<&mut E>,
    ) {
        // Track repeatable commands
        if command.is_repeatable() {
            self.last_repeatable_command = Some(command.clone());
            self.last_inserted_text.clear();
        }

        let extend_selection = self.mode == HelixMode::Select && command.extends_selection();

        // Handle mode-changing commands
        match command {
            HelixCommand::EnterInsertMode => {
                self.set_mode(HelixMode::Insert);
                return;
            }
            HelixCommand::EnterNormalMode => {
                self.set_mode(HelixMode::Normal);
                return;
            }
            HelixCommand::EnterSelectMode => {
                self.set_mode(HelixMode::Select);
                return;
            }
            HelixCommand::EnterSearchMode { backward } => {
                self.enter_search(*backward);
                return;
            }
            HelixCommand::Change => {
                if let Some(ref mut engine) = text_engine {
                    engine.delete();
                }
                self.set_mode(HelixMode::Insert);
                self.last_repeatable_command = Some(HelixCommand::Change);
                return;
            }
            HelixCommand::Substitute => {
                if let Some(ref mut engine) = text_engine {
                    engine.delete();
                }
                self.set_mode(HelixMode::Insert);
                self.last_repeatable_command = Some(HelixCommand::Substitute);
                return;
            }
            HelixCommand::OpenLineBelow => {
                if let Some(ref mut engine) = text_engine {
                    engine.open_line_below();
                }
                self.set_mode(HelixMode::Insert);
                return;
            }
            HelixCommand::OpenLineAbove => {
                if let Some(ref mut engine) = text_engine {
                    engine.open_line_above();
                }
                self.set_mode(HelixMode::Insert);
                return;
            }
            HelixCommand::AppendAfterCursor => {
                if let Some(ref mut engine) = text_engine {
                    engine.move_after_cursor();
                }
                self.set_mode(HelixMode::Insert);
                return;
            }
            HelixCommand::AppendAtLineEnd => {
                if let Some(ref mut engine) = text_engine {
                    engine.move_to_line_end(false);
                }
                self.set_mode(HelixMode::Insert);
                return;
            }
            HelixCommand::InsertAtLineStart => {
                if let Some(ref mut engine) = text_engine {
                    engine.move_to_line_first_non_blank(false);
                }
                self.set_mode(HelixMode::Insert);
                return;
            }
            HelixCommand::RepeatLastChange => {
                if let Some(last_cmd) = self.last_repeatable_command.clone() {
                    let inserted_text = self.last_inserted_text.clone();
                    // Execute the last command on the engine
                    self.execute_on_engine(&last_cmd, text_engine.as_deref_mut(), extend_selection);
                    // Replay inserted text if applicable
                    if !inserted_text.is_empty() {
                        if let Some(engine) = text_engine {
                            engine.insert_text(&inserted_text);
                        }
                    }
                }
                return;
            }
            HelixCommand::RepeatFind => {
                if let Some((char, op)) = self.key_handler.last_find_op() {
                    let repeat_cmd = match op {
                        PendingCharacterOperation::FindForward => {
                            HelixCommand::FindCharacter { char, count: 1 }
                        }
                        PendingCharacterOperation::FindBackward => {
                            HelixCommand::FindCharacterBackward { char, count: 1 }
                        }
                        PendingCharacterOperation::TillForward => {
                            HelixCommand::TillCharacter { char, count: 1 }
                        }
                        PendingCharacterOperation::TillBackward => {
                            HelixCommand::TillCharacterBackward { char, count: 1 }
                        }
                        PendingCharacterOperation::Replace => return,
                    };
                    self.execute_on_engine(&repeat_cmd, text_engine, extend_selection);
                }
                return;
            }
            HelixCommand::RepeatFindReverse => {
                if let Some((char, op)) = self.key_handler.last_find_op() {
                    let reverse_cmd = match op {
                        PendingCharacterOperation::FindForward => {
                            HelixCommand::FindCharacterBackward { char, count: 1 }
                        }
                        PendingCharacterOperation::FindBackward => {
                            HelixCommand::FindCharacter { char, count: 1 }
                        }
                        PendingCharacterOperation::TillForward => {
                            HelixCommand::TillCharacterBackward { char, count: 1 }
                        }
                        PendingCharacterOperation::TillBackward => {
                            HelixCommand::TillCharacter { char, count: 1 }
                        }
                        PendingCharacterOperation::Replace => return,
                    };
                    self.execute_on_engine(&reverse_cmd, text_engine, extend_selection);
                }
                return;
            }
            _ => {}
        }

        // Execute command on text engine
        self.execute_on_engine(command, text_engine, extend_selection);
    }

    /// Execute a command directly on a text engine (no mode changes).
    fn execute_on_engine<E: HelixTextEngine>(
        &mut self,
        command: &HelixCommand,
        text_engine: Option<&mut E>,
        extend_selection: bool,
    ) {
        let Some(engine) = text_engine else { return };

        match command {
            // Movement
            HelixCommand::MoveLeft { count } => engine.move_left(*count, extend_selection),
            HelixCommand::MoveRight { count } => engine.move_right(*count, extend_selection),
            HelixCommand::MoveUp { count } => engine.move_up(*count, extend_selection),
            HelixCommand::MoveDown { count } => engine.move_down(*count, extend_selection),
            HelixCommand::WordForward { count } => {
                engine.move_word_forward(*count, extend_selection)
            }
            HelixCommand::WordBackward { count } => {
                engine.move_word_backward(*count, extend_selection)
            }
            HelixCommand::WordEnd { count } => engine.move_word_end(*count, extend_selection),
            HelixCommand::LineStart => engine.move_to_line_start(extend_selection),
            HelixCommand::LineEnd => engine.move_to_line_end(extend_selection),
            HelixCommand::LineFirstNonBlank => {
                engine.move_to_line_first_non_blank(extend_selection)
            }
            HelixCommand::DocumentStart => engine.move_to_document_start(extend_selection),
            HelixCommand::DocumentEnd => engine.move_to_document_end(extend_selection),

            // Character finding
            HelixCommand::FindCharacter { char, count } => {
                engine.find_character(*char, *count, extend_selection)
            }
            HelixCommand::FindCharacterBackward { char, count } => {
                engine.find_character_backward(*char, *count, extend_selection)
            }
            HelixCommand::TillCharacter { char, count } => {
                engine.till_character(*char, *count, extend_selection)
            }
            HelixCommand::TillCharacterBackward { char, count } => {
                engine.till_character_backward(*char, *count, extend_selection)
            }

            // Search
            HelixCommand::SearchNext { count } => {
                for _ in 0..*count {
                    engine.search_next(&self.search_query, extend_selection);
                }
            }
            HelixCommand::SearchPrevious { count } => {
                for _ in 0..*count {
                    engine.search_previous(&self.search_query, extend_selection);
                }
            }

            // Selection
            HelixCommand::SelectLine => engine.select_line(),
            HelixCommand::SelectAll => engine.select_all(),

            // Editing
            HelixCommand::Delete => engine.delete(),
            HelixCommand::Yank => {
                let (text, linewise) = engine.yank();
                self.yank(&text, linewise);
            }
            HelixCommand::PasteAfter => {
                let content = self.register_content.clone();
                engine.paste_after(&content);
            }
            HelixCommand::PasteBefore => {
                let content = self.register_content.clone();
                engine.paste_before(&content);
            }

            // Line operations
            HelixCommand::JoinLines => engine.join_lines(),
            HelixCommand::ToggleCase => engine.toggle_case(),
            HelixCommand::Indent => engine.indent(),
            HelixCommand::Dedent => engine.dedent(),
            HelixCommand::ReplaceCharacter { char } => engine.replace_character(*char),

            // Undo/Redo
            HelixCommand::Undo => engine.undo(),
            HelixCommand::Redo => engine.redo(),

            // Mode changes and specials are handled in execute_command
            _ => {}
        }
    }
}

impl Default for HelixState {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_initial_state() {
        let state = HelixState::new();
        assert_eq!(state.mode(), HelixMode::Normal);
        assert!(!state.is_searching());
    }

    #[test]
    fn test_mode_changes() {
        let mut state = HelixState::new();
        state.set_mode(HelixMode::Insert);
        assert_eq!(state.mode(), HelixMode::Insert);

        state.set_mode(HelixMode::Select);
        assert_eq!(state.mode(), HelixMode::Select);

        state.reset();
        assert_eq!(state.mode(), HelixMode::Normal);
    }

    #[test]
    fn test_search_mode() {
        let mut state = HelixState::new();

        state.enter_search(false);
        assert!(state.is_searching());
        assert!(!state.search_backward());

        state.append_to_search_query('t');
        state.append_to_search_query('e');
        state.append_to_search_query('s');
        state.append_to_search_query('t');
        assert_eq!(state.search_query(), "test");

        state.backspace_search_query();
        assert_eq!(state.search_query(), "tes");

        state.execute_search();
        assert!(!state.is_searching());
        assert_eq!(state.search_query(), "tes"); // Preserved for n/N
    }

    #[test]
    fn test_register() {
        let mut state = HelixState::new();

        state.yank("hello", false);
        let (text, linewise) = state.paste();
        assert_eq!(text, "hello");
        assert!(!linewise);

        state.yank("world\n", true);
        let (text, linewise) = state.paste();
        assert_eq!(text, "world\n");
        assert!(linewise);
    }
}
