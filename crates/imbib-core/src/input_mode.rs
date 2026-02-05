//! Input mode state machine for keyboard-driven triage.
//!
//! Tracks which modal input state the user is in:
//! - Triage (default): normal navigation and selection
//! - FlagInput: typing a flag command
//! - TagInput: typing a tag path with autocomplete
//! - TagDelete: selecting tags to remove
//! - Filter: typing a filter expression

use serde::{Deserialize, Serialize};

/// The current input mode.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[cfg_attr(feature = "native", derive(uniffi::Enum))]
pub enum InputMode {
    /// Default navigation and selection mode.
    #[default]
    Triage,
    /// Typing a flag command (e.g., "r", "a-h").
    FlagInput,
    /// Typing a tag path with autocomplete.
    TagInput,
    /// Selecting tags to delete (keyboard-navigable chip list).
    TagDelete,
    /// Typing a filter/search expression.
    Filter,
}

impl InputMode {
    /// Whether this mode accepts text input.
    pub fn accepts_text(&self) -> bool {
        matches!(self, Self::FlagInput | Self::TagInput | Self::Filter)
    }

    /// Whether this mode has a visible overlay.
    pub fn has_overlay(&self) -> bool {
        !matches!(self, Self::Triage)
    }

    /// Display name for mode indicator badge.
    pub fn display_name(&self) -> &'static str {
        match self {
            Self::Triage => "TRIAGE",
            Self::FlagInput => "FLAG",
            Self::TagInput => "TAG",
            Self::TagDelete => "TAG DEL",
            Self::Filter => "FILTER",
        }
    }
}

/// Check if an input mode accepts text input (FFI helper).
#[cfg(feature = "native")]
#[uniffi::export]
pub fn input_mode_accepts_text(mode: InputMode) -> bool {
    mode.accepts_text()
}

/// Get the display name for an input mode (FFI helper).
#[cfg(feature = "native")]
#[uniffi::export]
pub fn input_mode_display_name(mode: InputMode) -> String {
    mode.display_name().to_string()
}

/// Check if an input mode has a visible overlay (FFI helper).
#[cfg(feature = "native")]
#[uniffi::export]
pub fn input_mode_has_overlay(mode: InputMode) -> bool {
    mode.has_overlay()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_is_triage() {
        assert_eq!(InputMode::default(), InputMode::Triage);
    }

    #[test]
    fn text_modes() {
        assert!(!InputMode::Triage.accepts_text());
        assert!(InputMode::FlagInput.accepts_text());
        assert!(InputMode::TagInput.accepts_text());
        assert!(!InputMode::TagDelete.accepts_text());
        assert!(InputMode::Filter.accepts_text());
    }

    #[test]
    fn overlay_modes() {
        assert!(!InputMode::Triage.has_overlay());
        assert!(InputMode::FlagInput.has_overlay());
        assert!(InputMode::TagInput.has_overlay());
        assert!(InputMode::TagDelete.has_overlay());
        assert!(InputMode::Filter.has_overlay());
    }
}
