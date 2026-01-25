//! Shared collaboration infrastructure for academic resource management.
//!
//! This crate provides core collaboration primitives including:
//! - Permission management with fine-grained access control
//! - Invitation and secure link sharing for resources
//! - Real-time presence awareness for collaborative editing

pub mod invitation;
pub mod permissions;
pub mod presence;

pub use invitation::{Invitation, InvitationStatus, SecureLink};
pub use permissions::Permissions;
pub use presence::{CursorPosition, PresenceInfo, PresenceStatus};
