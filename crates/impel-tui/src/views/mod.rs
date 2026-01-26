//! TUI views

mod ground;
mod landscape;
mod team;

pub use ground::GroundView;
pub use landscape::LandscapeView;
pub use team::TeamView;

use ratatui::Frame;
use ratatui::layout::Rect;

/// Trait for views
pub trait View {
    fn render(&self, frame: &mut Frame, area: Rect);
}
