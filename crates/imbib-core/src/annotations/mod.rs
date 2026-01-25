//! Cross-platform annotation storage
//!
//! Annotations are stored as JSON-serializable structs that can:
//! - Sync via CloudKit (native) or any backend (web)
//! - Be rendered differently per platform
//! - Support undo/redo operations

pub mod operations;
pub mod storage;
pub mod types;

#[cfg(feature = "native")]
pub use operations::*;
#[cfg(feature = "native")]
pub use storage::*;
#[cfg(feature = "native")]
pub use types::*;
