//! PDF processing with pdfium-render
//!
//! Provides:
//! - Text extraction for search indexing
//! - Thumbnail generation
//! - Page count and metadata

pub mod extract;
pub mod metadata;
pub mod thumbnails;

pub use extract::*;
pub use metadata::*;
pub use thumbnails::*;
