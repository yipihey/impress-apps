//! Alert panel widget

/// Panel showing escalations sorted by priority
pub struct AlertPanel;

impl AlertPanel {
    pub fn new() -> Self {
        Self
    }
}

impl Default for AlertPanel {
    fn default() -> Self {
        Self::new()
    }
}
