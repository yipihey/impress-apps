//! Comment-related logic shared across platforms.
//!
//! Store persistence for comments lives in `unified::store_api`; this module
//! holds pure logic, currently range re-anchoring for range-anchored comments.

pub mod anchor;

pub use anchor::{reanchor, AnchorResolution};
