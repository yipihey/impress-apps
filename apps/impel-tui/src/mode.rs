//! TUI interaction modes

/// The current interaction mode
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    /// Normal navigation mode (default)
    Normal,
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
            Mode::Command => write!(f, "COMMAND"),
            Mode::Select => write!(f, "SELECT"),
        }
    }
}
