//! Helix-style mode indicator widget for the TUI.

use ratatui::{
    style::{Color, Modifier, Style},
    text::Span,
    widgets::Widget,
};

use crate::mode::Mode;

/// A mode indicator widget that displays the current editing mode.
///
/// Styled to match the Helix editor's mode display with color coding:
/// - Normal: Blue
/// - Insert: Green
/// - Select: Yellow/Orange
/// - Command: Magenta
pub struct ModeIndicator {
    mode: Mode,
}

impl ModeIndicator {
    /// Create a new mode indicator for the given mode.
    pub fn new(mode: Mode) -> Self {
        Self { mode }
    }

    /// Get the display color for the current mode.
    pub fn mode_color(mode: Mode) -> Color {
        match mode {
            Mode::Normal => Color::Blue,
            Mode::Insert => Color::Green,
            Mode::Select => Color::Yellow,
            Mode::Command => Color::Magenta,
        }
    }

    /// Get the short display code for the mode.
    pub fn mode_code(mode: Mode) -> &'static str {
        mode.short_code()
    }

    /// Render as a styled span (for embedding in other widgets).
    pub fn as_span(&self) -> Span<'static> {
        let color = Self::mode_color(self.mode);
        let code = Self::mode_code(self.mode);

        Span::styled(
            format!("[{}]", code),
            Style::default()
                .fg(Color::White)
                .bg(color)
                .add_modifier(Modifier::BOLD),
        )
    }

    /// Render as a colored indicator without background.
    pub fn as_minimal_span(&self) -> Span<'static> {
        let color = Self::mode_color(self.mode);
        let code = Self::mode_code(self.mode);

        Span::styled(
            format!("[{}]", code),
            Style::default().fg(color).add_modifier(Modifier::BOLD),
        )
    }
}

impl Widget for ModeIndicator {
    fn render(self, area: ratatui::prelude::Rect, buf: &mut ratatui::prelude::Buffer) {
        let color = Self::mode_color(self.mode);
        let code = Self::mode_code(self.mode);

        let style = Style::default()
            .fg(Color::White)
            .bg(color)
            .add_modifier(Modifier::BOLD);

        let text = format!("[{}]", code);
        let x = area.x;
        let y = area.y;

        // Only render if we have space
        if area.width >= text.len() as u16 && area.height >= 1 {
            buf.set_string(x, y, &text, style);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_mode_colors() {
        assert_eq!(ModeIndicator::mode_color(Mode::Normal), Color::Blue);
        assert_eq!(ModeIndicator::mode_color(Mode::Insert), Color::Green);
        assert_eq!(ModeIndicator::mode_color(Mode::Select), Color::Yellow);
        assert_eq!(ModeIndicator::mode_color(Mode::Command), Color::Magenta);
    }

    #[test]
    fn test_mode_codes() {
        assert_eq!(ModeIndicator::mode_code(Mode::Normal), "NOR");
        assert_eq!(ModeIndicator::mode_code(Mode::Insert), "INS");
        assert_eq!(ModeIndicator::mode_code(Mode::Select), "SEL");
        assert_eq!(ModeIndicator::mode_code(Mode::Command), "CMD");
    }
}
