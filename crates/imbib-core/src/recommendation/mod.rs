//! Recommendation engine features (ADR-020)
//!
//! Pure computation functions for feature extraction, moved from Swift
//! for performance (batch processing) and cross-platform use.

mod features;

pub use features::*;
