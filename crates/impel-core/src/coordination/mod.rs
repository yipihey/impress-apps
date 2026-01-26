//! Coordination state and command handling
//!
//! The coordination layer manages the aggregate state of the impel system
//! and handles commands that modify that state.

mod command;
mod state;

pub use command::Command;
pub use state::CoordinationState;
