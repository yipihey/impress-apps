//! Keybinding definitions

use crossterm::event::KeyCode;

/// Keybinding action
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    /// Quit the application
    Quit,
    /// Enter command mode
    EnterCommandMode,
    /// Enter select mode
    EnterSelectMode,
    /// Cancel/escape to normal mode
    Cancel,
    /// Move up in list
    MoveUp,
    /// Move down in list
    MoveDown,
    /// Switch to previous view
    PrevView,
    /// Switch to next view
    NextView,
    /// Jump to view 1 (Landscape)
    View1,
    /// Jump to view 2 (Team)
    View2,
    /// Jump to view 3 (Ground)
    View3,
    /// Toggle pause
    TogglePause,
    /// Toggle help
    ToggleHelp,
    /// Select/confirm
    Select,
}

/// Get the action for a key in normal mode
pub fn normal_mode_action(code: KeyCode) -> Option<Action> {
    match code {
        KeyCode::Char('q') => Some(Action::Quit),
        KeyCode::Char(':') => Some(Action::EnterCommandMode),
        KeyCode::Char('v') => Some(Action::EnterSelectMode),
        KeyCode::Char('?') => Some(Action::ToggleHelp),
        KeyCode::Char('j') | KeyCode::Down => Some(Action::MoveDown),
        KeyCode::Char('k') | KeyCode::Up => Some(Action::MoveUp),
        KeyCode::Char('h') | KeyCode::Left => Some(Action::PrevView),
        KeyCode::Char('l') | KeyCode::Right => Some(Action::NextView),
        KeyCode::Char('1') => Some(Action::View1),
        KeyCode::Char('2') => Some(Action::View2),
        KeyCode::Char('3') => Some(Action::View3),
        KeyCode::Char(' ') => Some(Action::TogglePause),
        KeyCode::Enter => Some(Action::Select),
        KeyCode::Esc => Some(Action::Cancel),
        _ => None,
    }
}
