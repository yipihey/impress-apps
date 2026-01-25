//! implore-stats - Statistical functions for scientific visualization
//!
//! This crate provides statistical primitives optimized for large datasets:
//!
//! - **ECDF**: Empirical Cumulative Distribution Function
//! - **PCDF**: Probability-integral-transform CDF (uniform [0,1] output)
//! - **FastCDF**: O(log² n) 2D joint CDF queries using range trees
//!
//! # Design Philosophy
//!
//! ECDFs and PCDFs are preferred over histograms because they:
//! - Require no bin width decisions
//! - Preserve all information in the data
//! - Enable more accurate visual comparison
//! - Support efficient quantile queries

pub mod ecdf;
pub mod fast_cdf;
pub mod pcdf;
pub mod summary;

pub use ecdf::*;
pub use fast_cdf::*;
pub use pcdf::*;
pub use summary::*;

// Setup UniFFI when the feature is enabled
#[cfg(feature = "uniffi")]
uniffi::setup_scaffolding!();
