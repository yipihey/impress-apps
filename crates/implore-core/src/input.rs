//! Input handling for keyboard and mouse
//!
//! Provides a unified input model that works across platforms:
//! - Keyboard shortcuts for navigation and commands
//! - Mouse events for selection and camera control
//! - Touch/trackpad gestures (macOS)

use serde::{Deserialize, Serialize};
use std::collections::HashSet;

/// Keyboard key codes
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum Key {
    // Letters
    A,
    B,
    C,
    D,
    E,
    F,
    G,
    H,
    I,
    J,
    K,
    L,
    M,
    N,
    O,
    P,
    Q,
    R,
    S,
    T,
    U,
    V,
    W,
    X,
    Y,
    Z,

    // Numbers
    Num0,
    Num1,
    Num2,
    Num3,
    Num4,
    Num5,
    Num6,
    Num7,
    Num8,
    Num9,

    // Navigation
    Up,
    Down,
    Left,
    Right,
    Home,
    End,
    PageUp,
    PageDown,

    // Function keys
    F1,
    F2,
    F3,
    F4,
    F5,
    F6,
    F7,
    F8,
    F9,
    F10,
    F11,
    F12,

    // Modifiers
    Shift,
    Control,
    Alt,
    Meta, // Cmd on macOS, Win on Windows

    // Special
    Space,
    Tab,
    Enter,
    Escape,
    Backspace,
    Delete,

    // Punctuation
    Comma,
    Period,
    Slash,
    Semicolon,
    Quote,
    BracketLeft,
    BracketRight,
    Backslash,
    Minus,
    Equal,
    Grave,

    // Unknown
    Unknown(u32),
}

/// Modifier key state
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Modifiers {
    pub shift: bool,
    pub ctrl: bool,
    pub alt: bool,
    pub meta: bool, // Cmd on macOS
}

impl Modifiers {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_shift(mut self) -> Self {
        self.shift = true;
        self
    }

    pub fn with_ctrl(mut self) -> Self {
        self.ctrl = true;
        self
    }

    pub fn with_alt(mut self) -> Self {
        self.alt = true;
        self
    }

    pub fn with_meta(mut self) -> Self {
        self.meta = true;
        self
    }

    /// Check if any modifier is pressed
    pub fn any(&self) -> bool {
        self.shift || self.ctrl || self.alt || self.meta
    }

    /// Check if no modifiers are pressed
    pub fn none(&self) -> bool {
        !self.any()
    }

    /// Check if this matches the expected modifiers exactly
    pub fn matches(&self, expected: &Modifiers) -> bool {
        self.shift == expected.shift
            && self.ctrl == expected.ctrl
            && self.alt == expected.alt
            && self.meta == expected.meta
    }
}

/// Keyboard event
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct KeyEvent {
    /// The key that was pressed/released
    pub key: Key,
    /// Whether the key was pressed (true) or released (false)
    pub pressed: bool,
    /// Modifier state at time of event
    pub modifiers: Modifiers,
    /// Whether this is a repeat event
    pub is_repeat: bool,
}

impl KeyEvent {
    pub fn pressed(key: Key, modifiers: Modifiers) -> Self {
        Self {
            key,
            pressed: true,
            modifiers,
            is_repeat: false,
        }
    }

    pub fn released(key: Key, modifiers: Modifiers) -> Self {
        Self {
            key,
            pressed: false,
            modifiers,
            is_repeat: false,
        }
    }

    pub fn with_repeat(mut self) -> Self {
        self.is_repeat = true;
        self
    }
}

/// Mouse button
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum MouseButton {
    Left,
    Right,
    Middle,
    Other(u8),
}

/// Mouse event type
#[derive(Clone, Debug, Serialize, Deserialize)]
pub enum MouseEvent {
    /// Mouse moved
    Move {
        x: f32,
        y: f32,
        modifiers: Modifiers,
    },

    /// Button pressed
    Press {
        button: MouseButton,
        x: f32,
        y: f32,
        modifiers: Modifiers,
    },

    /// Button released
    Release {
        button: MouseButton,
        x: f32,
        y: f32,
        modifiers: Modifiers,
    },

    /// Mouse wheel scrolled
    Scroll {
        delta_x: f32,
        delta_y: f32,
        x: f32,
        y: f32,
        modifiers: Modifiers,
    },

    /// Mouse entered window
    Enter { x: f32, y: f32 },

    /// Mouse left window
    Leave,

    /// Double click
    DoubleClick {
        button: MouseButton,
        x: f32,
        y: f32,
        modifiers: Modifiers,
    },
}

impl MouseEvent {
    /// Get position for events that have one
    pub fn position(&self) -> Option<(f32, f32)> {
        match self {
            MouseEvent::Move { x, y, .. } => Some((*x, *y)),
            MouseEvent::Press { x, y, .. } => Some((*x, *y)),
            MouseEvent::Release { x, y, .. } => Some((*x, *y)),
            MouseEvent::Scroll { x, y, .. } => Some((*x, *y)),
            MouseEvent::Enter { x, y } => Some((*x, *y)),
            MouseEvent::DoubleClick { x, y, .. } => Some((*x, *y)),
            MouseEvent::Leave => None,
        }
    }

    /// Get modifiers for events that have them
    pub fn modifiers(&self) -> Option<Modifiers> {
        match self {
            MouseEvent::Move { modifiers, .. } => Some(*modifiers),
            MouseEvent::Press { modifiers, .. } => Some(*modifiers),
            MouseEvent::Release { modifiers, .. } => Some(*modifiers),
            MouseEvent::Scroll { modifiers, .. } => Some(*modifiers),
            MouseEvent::DoubleClick { modifiers, .. } => Some(*modifiers),
            _ => None,
        }
    }
}

/// Touch gesture
#[derive(Clone, Debug, Serialize, Deserialize)]
pub enum GestureEvent {
    /// Pinch zoom
    Pinch {
        scale: f32,    // 1.0 = no change, >1 = zoom in, <1 = zoom out
        center_x: f32, // Center of pinch
        center_y: f32,
    },

    /// Two-finger rotation
    Rotate {
        angle: f32,    // Radians
        center_x: f32, // Center of rotation
        center_y: f32,
    },

    /// Two-finger pan
    Pan { delta_x: f32, delta_y: f32 },

    /// Swipe gesture
    Swipe {
        direction: SwipeDirection,
        velocity: f32,
    },

    /// Long press
    LongPress { x: f32, y: f32 },
}

/// Swipe direction
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum SwipeDirection {
    Left,
    Right,
    Up,
    Down,
}

/// Input state tracking
#[derive(Clone, Debug, Default)]
pub struct InputState {
    /// Currently pressed keys
    pressed_keys: HashSet<Key>,

    /// Current modifier state
    pub modifiers: Modifiers,

    /// Currently pressed mouse buttons
    pressed_buttons: HashSet<MouseButton>,

    /// Current mouse position
    pub mouse_x: f32,
    pub mouse_y: f32,

    /// Previous mouse position (for delta calculation)
    pub prev_mouse_x: f32,
    pub prev_mouse_y: f32,

    /// Whether mouse is in window
    pub mouse_in_window: bool,
}

impl InputState {
    pub fn new() -> Self {
        Self::default()
    }

    /// Update state with keyboard event
    pub fn handle_key(&mut self, event: &KeyEvent) {
        if event.pressed {
            self.pressed_keys.insert(event.key);
        } else {
            self.pressed_keys.remove(&event.key);
        }
        self.modifiers = event.modifiers;
    }

    /// Update state with mouse event
    pub fn handle_mouse(&mut self, event: &MouseEvent) {
        match event {
            MouseEvent::Move { x, y, modifiers } => {
                self.prev_mouse_x = self.mouse_x;
                self.prev_mouse_y = self.mouse_y;
                self.mouse_x = *x;
                self.mouse_y = *y;
                self.modifiers = *modifiers;
            }
            MouseEvent::Press {
                button,
                x,
                y,
                modifiers,
            } => {
                self.pressed_buttons.insert(*button);
                self.mouse_x = *x;
                self.mouse_y = *y;
                self.modifiers = *modifiers;
            }
            MouseEvent::Release {
                button,
                x,
                y,
                modifiers,
            } => {
                self.pressed_buttons.remove(button);
                self.mouse_x = *x;
                self.mouse_y = *y;
                self.modifiers = *modifiers;
            }
            MouseEvent::Scroll {
                x, y, modifiers, ..
            } => {
                self.mouse_x = *x;
                self.mouse_y = *y;
                self.modifiers = *modifiers;
            }
            MouseEvent::Enter { x, y } => {
                self.mouse_in_window = true;
                self.mouse_x = *x;
                self.mouse_y = *y;
            }
            MouseEvent::Leave => {
                self.mouse_in_window = false;
            }
            MouseEvent::DoubleClick {
                x, y, modifiers, ..
            } => {
                self.mouse_x = *x;
                self.mouse_y = *y;
                self.modifiers = *modifiers;
            }
        }
    }

    /// Check if a key is pressed
    pub fn is_key_pressed(&self, key: Key) -> bool {
        self.pressed_keys.contains(&key)
    }

    /// Check if a mouse button is pressed
    pub fn is_button_pressed(&self, button: MouseButton) -> bool {
        self.pressed_buttons.contains(&button)
    }

    /// Get mouse delta since last update
    pub fn mouse_delta(&self) -> (f32, f32) {
        (
            self.mouse_x - self.prev_mouse_x,
            self.mouse_y - self.prev_mouse_y,
        )
    }

    /// Check if dragging (button pressed + mouse moved)
    pub fn is_dragging(&self) -> bool {
        !self.pressed_buttons.is_empty() && self.mouse_delta() != (0.0, 0.0)
    }
}

/// Command that can be triggered by keyboard shortcuts
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum Command {
    // Mode switching
    CycleRenderMode,
    CycleRenderModeReverse,

    // Camera
    ResetCamera,
    FitToData,
    ToggleOrthographic,

    // View
    ToggleAxes,
    ToggleGrid,
    ToggleColorbar,
    ToggleMarginals,

    // Selection
    SelectAll,
    SelectNone,
    InvertSelection,
    DeleteSelection,

    // Data
    PreviousField,
    NextField,
    ToggleLogScale,

    // Export
    QuickExport,
    ExportDialog,

    // Session
    Save,
    SaveAs,
    Open,
    Undo,
    Redo,

    // Help
    ShowHelp,
    ShowShortcuts,

    // Quit
    Quit,
}

/// Keyboard shortcut definition
#[derive(Clone, Debug)]
pub struct Shortcut {
    pub key: Key,
    pub modifiers: Modifiers,
    pub command: Command,
}

impl Shortcut {
    pub fn new(key: Key, modifiers: Modifiers, command: Command) -> Self {
        Self {
            key,
            modifiers,
            command,
        }
    }

    /// Check if this shortcut matches a key event
    pub fn matches(&self, event: &KeyEvent) -> bool {
        event.pressed && event.key == self.key && event.modifiers.matches(&self.modifiers)
    }
}

/// Default keyboard shortcuts
pub fn default_shortcuts() -> Vec<Shortcut> {
    vec![
        // Mode switching
        Shortcut::new(Key::Tab, Modifiers::new(), Command::CycleRenderMode),
        Shortcut::new(
            Key::Tab,
            Modifiers::new().with_shift(),
            Command::CycleRenderModeReverse,
        ),
        // Camera
        Shortcut::new(Key::R, Modifiers::new(), Command::ResetCamera),
        Shortcut::new(Key::F, Modifiers::new(), Command::FitToData),
        Shortcut::new(Key::O, Modifiers::new(), Command::ToggleOrthographic),
        // View
        Shortcut::new(Key::A, Modifiers::new(), Command::ToggleAxes),
        Shortcut::new(Key::G, Modifiers::new(), Command::ToggleGrid),
        Shortcut::new(Key::C, Modifiers::new(), Command::ToggleColorbar),
        Shortcut::new(Key::M, Modifiers::new(), Command::ToggleMarginals),
        // Selection
        Shortcut::new(Key::A, Modifiers::new().with_meta(), Command::SelectAll),
        Shortcut::new(Key::D, Modifiers::new().with_meta(), Command::SelectNone),
        Shortcut::new(
            Key::I,
            Modifiers::new().with_meta(),
            Command::InvertSelection,
        ),
        Shortcut::new(Key::Backspace, Modifiers::new(), Command::DeleteSelection),
        // Data
        Shortcut::new(Key::BracketLeft, Modifiers::new(), Command::PreviousField),
        Shortcut::new(Key::BracketRight, Modifiers::new(), Command::NextField),
        Shortcut::new(Key::L, Modifiers::new(), Command::ToggleLogScale),
        // Export
        Shortcut::new(Key::E, Modifiers::new().with_meta(), Command::ExportDialog),
        Shortcut::new(
            Key::E,
            Modifiers::new().with_meta().with_shift(),
            Command::QuickExport,
        ),
        // Session
        Shortcut::new(Key::S, Modifiers::new().with_meta(), Command::Save),
        Shortcut::new(
            Key::S,
            Modifiers::new().with_meta().with_shift(),
            Command::SaveAs,
        ),
        Shortcut::new(Key::O, Modifiers::new().with_meta(), Command::Open),
        Shortcut::new(Key::Z, Modifiers::new().with_meta(), Command::Undo),
        Shortcut::new(
            Key::Z,
            Modifiers::new().with_meta().with_shift(),
            Command::Redo,
        ),
        // Help
        Shortcut::new(Key::Slash, Modifiers::new(), Command::ShowHelp),
        Shortcut::new(
            Key::Slash,
            Modifiers::new().with_shift(),
            Command::ShowShortcuts,
        ),
        // Quit
        Shortcut::new(Key::Q, Modifiers::new().with_meta(), Command::Quit),
    ]
}

/// Find command for a key event
pub fn find_command(event: &KeyEvent, shortcuts: &[Shortcut]) -> Option<Command> {
    shortcuts
        .iter()
        .find(|s| s.matches(event))
        .map(|s| s.command.clone())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_modifiers() {
        let mods = Modifiers::new().with_shift().with_meta();
        assert!(mods.shift);
        assert!(mods.meta);
        assert!(!mods.ctrl);
        assert!(!mods.alt);
        assert!(mods.any());
    }

    #[test]
    fn test_modifiers_none() {
        let mods = Modifiers::new();
        assert!(mods.none());
    }

    #[test]
    fn test_key_event() {
        let event = KeyEvent::pressed(Key::A, Modifiers::new());
        assert!(event.pressed);
        assert_eq!(event.key, Key::A);
    }

    #[test]
    fn test_input_state_key() {
        let mut state = InputState::new();
        let event = KeyEvent::pressed(Key::W, Modifiers::new());

        state.handle_key(&event);
        assert!(state.is_key_pressed(Key::W));

        let release = KeyEvent::released(Key::W, Modifiers::new());
        state.handle_key(&release);
        assert!(!state.is_key_pressed(Key::W));
    }

    #[test]
    fn test_input_state_mouse() {
        let mut state = InputState::new();

        state.handle_mouse(&MouseEvent::Press {
            button: MouseButton::Left,
            x: 100.0,
            y: 200.0,
            modifiers: Modifiers::new(),
        });

        assert!(state.is_button_pressed(MouseButton::Left));
        assert_eq!(state.mouse_x, 100.0);
        assert_eq!(state.mouse_y, 200.0);
    }

    #[test]
    fn test_mouse_delta() {
        let mut state = InputState::new();
        state.mouse_x = 100.0;
        state.mouse_y = 100.0;

        state.handle_mouse(&MouseEvent::Move {
            x: 150.0,
            y: 120.0,
            modifiers: Modifiers::new(),
        });

        let delta = state.mouse_delta();
        assert_eq!(delta, (50.0, 20.0));
    }

    #[test]
    fn test_shortcut_matching() {
        let shortcut = Shortcut::new(Key::Tab, Modifiers::new(), Command::CycleRenderMode);

        let event = KeyEvent::pressed(Key::Tab, Modifiers::new());
        assert!(shortcut.matches(&event));

        let event_with_shift = KeyEvent::pressed(Key::Tab, Modifiers::new().with_shift());
        assert!(!shortcut.matches(&event_with_shift));
    }

    #[test]
    fn test_find_command() {
        let shortcuts = default_shortcuts();

        let event = KeyEvent::pressed(Key::Tab, Modifiers::new());
        let cmd = find_command(&event, &shortcuts);
        assert_eq!(cmd, Some(Command::CycleRenderMode));

        let event_shift = KeyEvent::pressed(Key::Tab, Modifiers::new().with_shift());
        let cmd = find_command(&event_shift, &shortcuts);
        assert_eq!(cmd, Some(Command::CycleRenderModeReverse));
    }

    #[test]
    fn test_default_shortcuts() {
        let shortcuts = default_shortcuts();

        // Should have reasonable number of shortcuts
        assert!(shortcuts.len() > 15);

        // Check some specific shortcuts exist
        let has_save = shortcuts.iter().any(|s| s.command == Command::Save);
        assert!(has_save);

        let has_quit = shortcuts.iter().any(|s| s.command == Command::Quit);
        assert!(has_quit);
    }
}
