//! TUI views for the 4-level zoom hierarchy
//!
//! Level 1: Program View - Multi-project overview
//! Level 2: Project View - Single project focus
//! Level 3: Thread View - Thread detail
//! Level 4: Event View - Atomic event detail

mod event_view;
mod ground;
mod landscape;
mod program_view;
mod project_view;
mod team;
mod thread_view;

pub use event_view::EventView;
pub use ground::GroundView;
pub use landscape::LandscapeView;
pub use program_view::ProgramView;
pub use project_view::ProjectView;
pub use team::TeamView;
pub use thread_view::ThreadView;

use ratatui::layout::Rect;
use ratatui::Frame;

/// Trait for views
pub trait View {
    fn render(&self, frame: &mut Frame, area: Rect);
}

/// Zoom level in the 4-level hierarchy
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ZoomLevel {
    /// Level 1: Program overview (multi-project)
    Program = 1,
    /// Level 2: Project focus (threads, deliverables)
    Project = 2,
    /// Level 3: Thread detail (events, temperature)
    Thread = 3,
    /// Level 4: Event detail (atomic activity)
    Event = 4,
}

impl ZoomLevel {
    /// Get the name of this zoom level
    pub fn name(&self) -> &'static str {
        match self {
            ZoomLevel::Program => "Program",
            ZoomLevel::Project => "Project",
            ZoomLevel::Thread => "Thread",
            ZoomLevel::Event => "Event",
        }
    }

    /// Create from numeric level (1-4)
    pub fn from_level(level: u8) -> Option<Self> {
        match level {
            1 => Some(ZoomLevel::Program),
            2 => Some(ZoomLevel::Project),
            3 => Some(ZoomLevel::Thread),
            4 => Some(ZoomLevel::Event),
            _ => None,
        }
    }

    /// Zoom in one level (if possible)
    pub fn zoom_in(&self) -> Option<Self> {
        match self {
            ZoomLevel::Program => Some(ZoomLevel::Project),
            ZoomLevel::Project => Some(ZoomLevel::Thread),
            ZoomLevel::Thread => Some(ZoomLevel::Event),
            ZoomLevel::Event => None,
        }
    }

    /// Zoom out one level (if possible)
    pub fn zoom_out(&self) -> Option<Self> {
        match self {
            ZoomLevel::Program => None,
            ZoomLevel::Project => Some(ZoomLevel::Program),
            ZoomLevel::Thread => Some(ZoomLevel::Project),
            ZoomLevel::Event => Some(ZoomLevel::Thread),
        }
    }
}

impl std::fmt::Display for ZoomLevel {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.name())
    }
}
