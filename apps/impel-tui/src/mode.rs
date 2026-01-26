//! TUI interaction modes

use impel_helix::HelixMode;

/// The current interaction mode
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    /// Normal navigation mode (default)
    Normal,
    /// Insert mode for text editing (activated with i)
    Insert,
    /// Command entry mode (activated with :)
    Command,
    /// Multi-select mode (activated with v)
    Select,
}

impl Default for Mode {
    fn default() -> Self {
        Mode::Normal
    }
}

impl std::fmt::Display for Mode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Mode::Normal => write!(f, "NORMAL"),
            Mode::Insert => write!(f, "INSERT"),
            Mode::Command => write!(f, "COMMAND"),
            Mode::Select => write!(f, "SELECT"),
        }
    }
}

impl Mode {
    /// Returns a short code for compact display.
    pub fn short_code(&self) -> &'static str {
        match self {
            Mode::Normal => "NOR",
            Mode::Insert => "INS",
            Mode::Command => "CMD",
            Mode::Select => "SEL",
        }
    }

    /// Convert from HelixMode for text editing contexts.
    pub fn from_helix_mode(helix_mode: HelixMode) -> Self {
        match helix_mode {
            HelixMode::Normal => Mode::Normal,
            HelixMode::Insert => Mode::Insert,
            HelixMode::Select => Mode::Select,
        }
    }

    /// Convert to HelixMode for text editing contexts.
    pub fn to_helix_mode(&self) -> Option<HelixMode> {
        match self {
            Mode::Normal => Some(HelixMode::Normal),
            Mode::Insert => Some(HelixMode::Insert),
            Mode::Select => Some(HelixMode::Select),
            Mode::Command => None, // Command mode is TUI-specific
        }
    }
}
