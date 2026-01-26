//! Team view - thread detail with agents and artifacts

use ratatui::{layout::Rect, Frame};

/// Team view showing detailed information about a selected thread
pub struct TeamView;

impl TeamView {
    pub fn new() -> Self {
        Self
    }
}

impl Default for TeamView {
    fn default() -> Self {
        Self::new()
    }
}
