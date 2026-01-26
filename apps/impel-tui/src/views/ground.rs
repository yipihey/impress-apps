//! Ground view - full event log and file browser

use ratatui::{layout::Rect, Frame};

/// Ground view showing the full event log
pub struct GroundView;

impl GroundView {
    pub fn new() -> Self {
        Self
    }
}

impl Default for GroundView {
    fn default() -> Self {
        Self::new()
    }
}
