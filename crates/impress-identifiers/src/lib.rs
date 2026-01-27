// Allow manual modulo checks since .is_multiple_of() is nightly-only
#![allow(clippy::manual_is_multiple_of)]

//! Identifier extraction and validation for academic publications
//!
//! This crate provides tools for working with academic publication identifiers:
//! - DOI extraction and validation
//! - arXiv ID extraction (old and new formats)
//! - ISBN extraction and checksum validation
//! - Cite key generation
//! - URL resolution for identifiers

pub mod cite_key;
pub mod extractors;
pub mod resolver;
pub mod validators;

pub use cite_key::*;
pub use extractors::*;
pub use resolver::*;
pub use validators::*;

// Setup UniFFI when the feature is enabled
#[cfg(feature = "uniffi")]
uniffi::setup_scaffolding!();
