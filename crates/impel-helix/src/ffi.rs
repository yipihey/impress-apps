//! UniFFI bindings for impel-helix.
//!
//! This module provides FFI-safe wrappers for the Helix modal editing types,
//! suitable for use from Swift, Kotlin, and other languages via UniFFI.

use crate::mode::HelixMode as InternalHelixMode;
use crate::space::SpaceCommand as InternalSpaceCommand;
use crate::text_object::{
    TextObject as InternalTextObject, TextObjectModifier as InternalModifier,
};

/// FFI-safe Helix editing mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiHelixMode {
    /// Normal mode for navigation and commands.
    Normal,
    /// Insert mode for text input.
    Insert,
    /// Select mode for extending selections.
    Select,
}

impl From<InternalHelixMode> for FfiHelixMode {
    fn from(mode: InternalHelixMode) -> Self {
        match mode {
            InternalHelixMode::Normal => FfiHelixMode::Normal,
            InternalHelixMode::Insert => FfiHelixMode::Insert,
            InternalHelixMode::Select => FfiHelixMode::Select,
        }
    }
}

impl From<FfiHelixMode> for InternalHelixMode {
    fn from(mode: FfiHelixMode) -> Self {
        match mode {
            FfiHelixMode::Normal => InternalHelixMode::Normal,
            FfiHelixMode::Insert => InternalHelixMode::Insert,
            FfiHelixMode::Select => InternalHelixMode::Select,
        }
    }
}

/// FFI-safe text object modifier.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiTextObjectModifier {
    /// Inner modifier (e.g., `iw` for inner word).
    Inner,
    /// Around modifier (e.g., `aw` for around word).
    Around,
}

impl From<InternalModifier> for FfiTextObjectModifier {
    fn from(m: InternalModifier) -> Self {
        match m {
            InternalModifier::Inner => FfiTextObjectModifier::Inner,
            InternalModifier::Around => FfiTextObjectModifier::Around,
        }
    }
}

/// FFI-safe text object type.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiTextObject {
    Word,
    BigWord,
    DoubleQuote,
    SingleQuote,
    BacktickQuote,
    Parentheses,
    SquareBrackets,
    CurlyBraces,
    AngleBrackets,
    Paragraph,
    Sentence,
    Function,
    Class,
    Comment,
    Argument,
}

impl From<InternalTextObject> for FfiTextObject {
    fn from(t: InternalTextObject) -> Self {
        match t {
            InternalTextObject::Word => FfiTextObject::Word,
            InternalTextObject::WORD => FfiTextObject::BigWord,
            InternalTextObject::DoubleQuote => FfiTextObject::DoubleQuote,
            InternalTextObject::SingleQuote => FfiTextObject::SingleQuote,
            InternalTextObject::BacktickQuote => FfiTextObject::BacktickQuote,
            InternalTextObject::Parentheses => FfiTextObject::Parentheses,
            InternalTextObject::SquareBrackets => FfiTextObject::SquareBrackets,
            InternalTextObject::CurlyBraces => FfiTextObject::CurlyBraces,
            InternalTextObject::AngleBrackets => FfiTextObject::AngleBrackets,
            InternalTextObject::Paragraph => FfiTextObject::Paragraph,
            InternalTextObject::Sentence => FfiTextObject::Sentence,
            InternalTextObject::Function => FfiTextObject::Function,
            InternalTextObject::Class => FfiTextObject::Class,
            InternalTextObject::Comment => FfiTextObject::Comment,
            InternalTextObject::Argument => FfiTextObject::Argument,
        }
    }
}

/// FFI-safe space command.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiSpaceCommand {
    // File operations
    FileOpen,
    FileRecent,
    FileSave,
    FileSaveAs,
    FileClose,
    FileCloseAll,

    // Buffer operations
    BufferPicker,
    BufferNext,
    BufferPrev,
    BufferClose,
    BufferCloseOthers,
    BufferRevert,

    // Window operations
    WindowSplitHorizontal,
    WindowSplitVertical,
    WindowClose,
    WindowOnly,
    WindowFocusLeft,
    WindowFocusDown,
    WindowFocusUp,
    WindowFocusRight,
    WindowSwapLeft,
    WindowSwapDown,
    WindowSwapUp,
    WindowSwapRight,

    // Search/Symbol
    SymbolPicker,
    WorkspaceSymbolPicker,
    GlobalSearch,
    SearchInFile,

    // Git
    GitStatus,
    GitDiff,
    GitBlame,
    GitLog,
    GitStage,
    GitUnstage,

    // Diagnostics
    DiagnosticsList,
    DiagnosticNext,
    DiagnosticPrev,

    // Code
    CodeAction,
    Rename,
    Format,

    // Help
    Help,

    // Misc
    CommandPalette,
    ToggleFileTree,
    ToggleTerminal,
}

impl From<InternalSpaceCommand> for FfiSpaceCommand {
    fn from(cmd: InternalSpaceCommand) -> Self {
        match cmd {
            InternalSpaceCommand::FileOpen => FfiSpaceCommand::FileOpen,
            InternalSpaceCommand::FileRecent => FfiSpaceCommand::FileRecent,
            InternalSpaceCommand::FileSave => FfiSpaceCommand::FileSave,
            InternalSpaceCommand::FileSaveAs => FfiSpaceCommand::FileSaveAs,
            InternalSpaceCommand::FileClose => FfiSpaceCommand::FileClose,
            InternalSpaceCommand::FileCloseAll => FfiSpaceCommand::FileCloseAll,
            InternalSpaceCommand::BufferPicker => FfiSpaceCommand::BufferPicker,
            InternalSpaceCommand::BufferNext => FfiSpaceCommand::BufferNext,
            InternalSpaceCommand::BufferPrev => FfiSpaceCommand::BufferPrev,
            InternalSpaceCommand::BufferClose => FfiSpaceCommand::BufferClose,
            InternalSpaceCommand::BufferCloseOthers => FfiSpaceCommand::BufferCloseOthers,
            InternalSpaceCommand::BufferRevert => FfiSpaceCommand::BufferRevert,
            InternalSpaceCommand::WindowSplitHorizontal => FfiSpaceCommand::WindowSplitHorizontal,
            InternalSpaceCommand::WindowSplitVertical => FfiSpaceCommand::WindowSplitVertical,
            InternalSpaceCommand::WindowClose => FfiSpaceCommand::WindowClose,
            InternalSpaceCommand::WindowOnly => FfiSpaceCommand::WindowOnly,
            InternalSpaceCommand::WindowFocusLeft => FfiSpaceCommand::WindowFocusLeft,
            InternalSpaceCommand::WindowFocusDown => FfiSpaceCommand::WindowFocusDown,
            InternalSpaceCommand::WindowFocusUp => FfiSpaceCommand::WindowFocusUp,
            InternalSpaceCommand::WindowFocusRight => FfiSpaceCommand::WindowFocusRight,
            InternalSpaceCommand::WindowSwapLeft => FfiSpaceCommand::WindowSwapLeft,
            InternalSpaceCommand::WindowSwapDown => FfiSpaceCommand::WindowSwapDown,
            InternalSpaceCommand::WindowSwapUp => FfiSpaceCommand::WindowSwapUp,
            InternalSpaceCommand::WindowSwapRight => FfiSpaceCommand::WindowSwapRight,
            InternalSpaceCommand::SymbolPicker => FfiSpaceCommand::SymbolPicker,
            InternalSpaceCommand::WorkspaceSymbolPicker => FfiSpaceCommand::WorkspaceSymbolPicker,
            InternalSpaceCommand::GlobalSearch => FfiSpaceCommand::GlobalSearch,
            InternalSpaceCommand::SearchInFile => FfiSpaceCommand::SearchInFile,
            InternalSpaceCommand::GitStatus => FfiSpaceCommand::GitStatus,
            InternalSpaceCommand::GitDiff => FfiSpaceCommand::GitDiff,
            InternalSpaceCommand::GitBlame => FfiSpaceCommand::GitBlame,
            InternalSpaceCommand::GitLog => FfiSpaceCommand::GitLog,
            InternalSpaceCommand::GitStage => FfiSpaceCommand::GitStage,
            InternalSpaceCommand::GitUnstage => FfiSpaceCommand::GitUnstage,
            InternalSpaceCommand::DiagnosticsList => FfiSpaceCommand::DiagnosticsList,
            InternalSpaceCommand::DiagnosticNext => FfiSpaceCommand::DiagnosticNext,
            InternalSpaceCommand::DiagnosticPrev => FfiSpaceCommand::DiagnosticPrev,
            InternalSpaceCommand::CodeAction => FfiSpaceCommand::CodeAction,
            InternalSpaceCommand::Rename => FfiSpaceCommand::Rename,
            InternalSpaceCommand::Format => FfiSpaceCommand::Format,
            InternalSpaceCommand::Help => FfiSpaceCommand::Help,
            InternalSpaceCommand::CommandPalette => FfiSpaceCommand::CommandPalette,
            InternalSpaceCommand::ToggleFileTree => FfiSpaceCommand::ToggleFileTree,
            InternalSpaceCommand::ToggleTerminal => FfiSpaceCommand::ToggleTerminal,
        }
    }
}

/// FFI-safe key modifiers.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, uniffi::Record)]
pub struct FfiKeyModifiers {
    pub shift: bool,
    pub control: bool,
    pub alt: bool,
}

/// An available key in the space-mode menu.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiWhichKeyItem {
    /// The key character.
    pub key: String,
    /// Description of what the key does.
    pub description: String,
}

/// Result of handling a key in the FFI wrapper.
#[derive(Debug, Clone, uniffi::Enum)]
pub enum FfiKeyResult {
    /// Key was handled, editor state updated.
    Handled,
    /// Key should be passed through to the text input.
    PassThrough,
    /// A space-mode command was triggered.
    SpaceCommand { command: FfiSpaceCommand },
    /// Space-mode menu is showing, here are the available keys.
    SpaceModePending {
        available_keys: Vec<FfiWhichKeyItem>,
    },
}

/// FFI wrapper for the Helix editor state.
#[derive(uniffi::Object)]
pub struct FfiHelixEditor {
    state: std::sync::Mutex<crate::HelixState>,
}

#[uniffi::export]
impl FfiHelixEditor {
    /// Create a new Helix editor instance.
    #[uniffi::constructor]
    pub fn new() -> Self {
        Self {
            state: std::sync::Mutex::new(crate::HelixState::new()),
        }
    }

    /// Get the current editing mode.
    pub fn mode(&self) -> FfiHelixMode {
        let state = self.state.lock().unwrap();
        state.mode().into()
    }

    /// Check if search mode is active.
    pub fn is_searching(&self) -> bool {
        let state = self.state.lock().unwrap();
        state.is_searching()
    }

    /// Get the current search query.
    pub fn search_query(&self) -> String {
        let state = self.state.lock().unwrap();
        state.search_query().to_string()
    }

    /// Check if space-mode is active.
    pub fn is_space_mode(&self) -> bool {
        let state = self.state.lock().unwrap();
        state.is_space_mode()
    }

    /// Get available keys in the current space-mode menu.
    pub fn space_mode_available_keys(&self) -> Vec<FfiWhichKeyItem> {
        let state = self.state.lock().unwrap();
        state
            .space_mode_available_keys()
            .iter()
            .map(|(key, desc)| FfiWhichKeyItem {
                key: key.display(),
                description: desc.clone(),
            })
            .collect()
    }

    /// Check if awaiting a character input (f/t/r operations).
    pub fn is_awaiting_character(&self) -> bool {
        let state = self.state.lock().unwrap();
        state.is_awaiting_character()
    }

    /// Check if awaiting a motion (operator pending, e.g., after pressing 'd').
    pub fn is_awaiting_motion(&self) -> bool {
        let state = self.state.lock().unwrap();
        state.is_awaiting_motion()
    }

    /// Get the register (clipboard) content.
    pub fn register_content(&self) -> String {
        let state = self.state.lock().unwrap();
        state.register_content().to_string()
    }

    /// Handle a key press without a text engine.
    ///
    /// Returns the result indicating what action was taken.
    pub fn handle_key(&self, key: String, modifiers: FfiKeyModifiers) -> FfiKeyResult {
        let mut state = self.state.lock().unwrap();

        let key_char = key.chars().next().unwrap_or(' ');
        let mods = crate::KeyModifiers {
            shift: modifiers.shift,
            control: modifiers.control,
            alt: modifiers.alt,
        };

        let result = state
            .handle_key_with_result::<crate::text_engine::NullTextEngine>(key_char, &mods, None);

        match result {
            crate::KeyHandleResult::Handled => FfiKeyResult::Handled,
            crate::KeyHandleResult::PassThrough => FfiKeyResult::PassThrough,
            crate::KeyHandleResult::SpaceCommand(cmd) => FfiKeyResult::SpaceCommand {
                command: cmd.into(),
            },
            crate::KeyHandleResult::SpaceModePending => FfiKeyResult::SpaceModePending {
                available_keys: state
                    .space_mode_available_keys()
                    .iter()
                    .map(|(key, desc)| FfiWhichKeyItem {
                        key: key.display(),
                        description: desc.clone(),
                    })
                    .collect(),
            },
        }
    }

    /// Reset the editor to normal mode.
    pub fn reset(&self) {
        let mut state = self.state.lock().unwrap();
        state.reset();
    }

    /// Exit space-mode.
    pub fn exit_space_mode(&self) {
        let mut state = self.state.lock().unwrap();
        state.exit_space_mode();
    }
}

impl Default for FfiHelixEditor {
    fn default() -> Self {
        Self::new()
    }
}
