//! Shared collaboration infrastructure for academic resource management.
//!
//! This crate provides core collaboration primitives including:
//! - Permission management with fine-grained access control
//! - Real-time presence awareness for collaborative editing

pub mod permissions;
pub mod presence;

pub use permissions::Permissions;
pub use presence::{CursorPosition, PresenceInfo, PresenceStatus};
