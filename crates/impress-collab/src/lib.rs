//! Shared collaboration infrastructure for academic resource management.
//!
//! This crate provides core collaboration primitives including:
//! - Permission management with fine-grained access control
//! - Invitation and secure link sharing for resources
//! - Real-time presence awareness for collaborative editing
//! - Viewport state tracking for 3D visualization presence

pub mod invitation;
pub mod permissions;
pub mod presence;
pub mod viewport;

pub use invitation::{Invitation, InvitationStatus, SecureLink};
pub use permissions::Permissions;
pub use presence::{CursorPosition, PresenceInfo, PresenceStatus};
pub use viewport::{BoundingBox3D, Camera3DState, Point2D, ViewportMode, ViewportState};
